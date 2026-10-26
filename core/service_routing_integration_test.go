package core

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/rules"
	"github.com/metacubex/mihomo/tunnel"
)

func TestServiceAuditObservesActualControlledExitsAndRules(t *testing.T) {
	recordRoutes(t)
	observed := make(chan string, 32)
	startExit := func(name string) constant.Proxy {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodConnect {
				http.Error(w, "CONNECT required", 400)
				return
			}
			remote, err := net.DialTimeout("tcp", r.Host, time.Second)
			if err != nil {
				http.Error(w, "origin unavailable", 502)
				return
			}
			client, buffered, err := w.(http.Hijacker).Hijack()
			if err != nil {
				remote.Close()
				return
			}
			observed <- name
			_, _ = buffered.WriteString("HTTP/1.1 200 Connection established\r\n\r\n")
			_ = buffered.Flush()
			go func() { defer remote.Close(); defer client.Close(); _, _ = io.Copy(remote, buffered) }()
			go func() { defer remote.Close(); defer client.Close(); _, _ = io.Copy(client, remote) }()
		}))
		t.Cleanup(server.Close)
		host, portText, _ := net.SplitHostPort(server.Listener.Addr().String())
		port, _ := strconv.Atoi(portText)
		proxy, err := adapter.ParseProxy(map[string]any{"name": name, "type": "http", "server": host, "port": port})
		if err != nil {
			t.Fatal(err)
		}
		return proxy
	}
	a, b := startExit("A"), startExit("B")
	inner := selectorOver(t, "Inner", b)
	daily := selectorOver(t, "Daily", a, inner)
	proxies := map[string]constant.Proxy{"A": a, "B": b, "Inner": inner, "Daily": daily, "DIRECT": namedProxy("DIRECT")}
	tunnel.UpdateProxies(proxies, nil)
	previousMode := tunnel.Mode()
	tunnel.SetMode(tunnel.Rule)
	tunnel.OnRunning()
	t.Cleanup(func() {
		tunnel.OnSuspend()
		tunnel.SetMode(previousMode)
		tunnel.UpdateProxies(nil, nil)
		tunnel.UpdateRules(nil, nil, nil)
	})
	origin := probeServer(t, func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, "controlled response") })
	setRule := func(kind, payload, target string) {
		rule, err := rules.ParseRule(kind, payload, target, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		tunnel.UpdateRules([]constant.Rule{rule}, nil, nil)
	}
	check := func(proxy string) ServiceCheckItem {
		return runServiceCheck(context.Background(), serviceChecker{name: "controlled", check: checkServiceEndpoint(origin.URL)}, proxy, time.Second)
	}
	assertExit := func(item ServiceCheckItem, exit, rule string, chain []string) {
		t.Helper()
		select {
		case actual := <-observed:
			if actual != exit {
				t.Fatalf("actual CONNECT exit = %s, want %s", actual, exit)
			}
		case <-time.After(time.Second):
			t.Fatal("no controlled exit observed")
		}
		if item.Status != serviceReachable || len(item.Observations) != 1 {
			t.Fatalf("item = %+v", item)
		}
		hit := item.Observations[0]
		if hit.Rule != rule || len(hit.Chains) != len(chain) {
			t.Fatalf("observed route = %+v, want %s %v", hit, rule, chain)
		}
		for i, name := range chain {
			if hit.Chains[i] != name {
				t.Fatalf("chain = %v, want %v", hit.Chains, chain)
			}
		}
	}
	setRule("MATCH", "", "Daily")
	assertExit(check(""), "A", "Match", []string{"A", "Daily"})
	if err := daily.Adapter().(*outboundgroup.Selector).Set("Inner"); err != nil {
		t.Fatal(err)
	}
	assertExit(check(""), "B", "Match", []string{"B", "Inner", "Daily"})
	setRule("IP-CIDR", "127.0.0.1/32", "A")
	assertExit(check(""), "A", "IPCIDR", []string{"A"})
	assertExit(check("B"), "B", "", []string{"B"})
	if daily.Adapter().(*outboundgroup.Selector).Now() != "Inner" {
		t.Fatal("audit changed the daily selection")
	}
	direct := check("DIRECT")
	if len(direct.Observations) != 1 || len(direct.Observations[0].Chains) != 1 || direct.Observations[0].Chains[0] != "DIRECT" {
		t.Fatalf("direct route = %+v", direct)
	}
	missing := check("missing-target")
	if missing.Status == serviceReachable || missing.Status == serviceAvailable {
		t.Fatalf("missing target fell back: %+v", missing)
	}
	select {
	case unexpected := <-observed:
		t.Fatalf("unexpected fallback exit %s", unexpected)
	default:
	}
}
