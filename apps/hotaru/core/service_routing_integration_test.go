package core

import (
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strconv"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	adapterInbound "github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/auth"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	listenerFactory "github.com/metacubex/mihomo/listener"
	authStore "github.com/metacubex/mihomo/listener/auth"
	"github.com/metacubex/mihomo/listener/inbound"
	"github.com/metacubex/mihomo/rules"
	"github.com/metacubex/mihomo/tunnel"
)

func TestServiceAuditObservesActualControlledExitsAndRules(t *testing.T) {
	recordRoutes(t)
	observed := make(chan string, 32)

	a, b := controlledHttpExit(t, "A", observed), controlledHttpExit(t, "B", observed)
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

func controlledHttpExit(t *testing.T, name string, observed chan<- string) constant.Proxy {
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

func TestNodeBandwidthListenerPinsActualTrafficInEveryMode(t *testing.T) {
	recordRoutes(t)
	previousAuth := authStore.Default.Authenticator()
	previousAllowed := adapterInbound.AllowedIPs()
	previousSkip := adapterInbound.SkipAuthPrefixes()
	authStore.Default.SetAuthenticator(auth.NewAuthenticator([]auth.AuthUser{{User: "lan-user", Pass: "test-password"}}))
	adapterInbound.SetAllowedIPs([]netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")})
	adapterInbound.SetSkipAuthPrefixes(nil)
	t.Cleanup(func() {
		authStore.Default.SetAuthenticator(previousAuth)
		adapterInbound.SetAllowedIPs(previousAllowed)
		adapterInbound.SetSkipAuthPrefixes(previousSkip)
	})
	observed := make(chan string, 32)
	a := controlledHttpExit(t, "A", observed)
	b := controlledHttpExit(t, "B", observed)
	daily := selectorOver(t, "Daily", a, b)
	global := selectorOver(t, "GLOBAL", a, b)
	selected := selectorOver(t, "HOTARU-SPEEDTEST-2", a, b)
	userGroup := selectorOver(t, "HOTARU-SPEEDTEST", a, b)
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"A": a, "B": b, "Daily": daily, "GLOBAL": global, "HOTARU-SPEEDTEST-2": selected, "HOTARU-SPEEDTEST": userGroup, "DIRECT": namedProxy("DIRECT"),
	}, nil)
	previousMode := tunnel.Mode()
	tunnel.OnRunning()
	t.Cleanup(func() {
		tunnel.OnSuspend()
		tunnel.SetMode(previousMode)
		tunnel.UpdateProxies(nil, nil)
		tunnel.UpdateRules(nil, nil, nil)
	})
	rule, err := rules.ParseRule("MATCH", "", "Daily", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	tunnel.UpdateRules([]constant.Rule{rule}, nil, nil)
	raw, err := config.UnmarshalRawConfig([]byte(`listeners:
  - name: hotaru-speedtest
    type: mixed
    listen: 127.0.0.1
    port: 0
    proxy: HOTARU-SPEEDTEST-2
    users: []
`))
	if err != nil {
		t.Fatal(err)
	}
	listener, err := listenerFactory.ParseListener(raw.Listeners[0])
	if err != nil {
		t.Fatal(err)
	}
	if err = listener.Listen(tunnel.Tunnel); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	withCurrentConfig(t, &config.Config{Listeners: map[string]constant.InboundListener{nodeSpeedListenerName: listener}})
	previousRunning := isRunning.Swap(true)
	t.Cleanup(func() { isRunning.Store(previousRunning) })
	if got := handleGetProxies().SpeedTestGroup; got != "HOTARU-SPEEDTEST-2" {
		t.Fatalf("declared speed-test group=%s", got)
	}

	address, err := url.Parse("http://" + listener.Address())
	if err != nil {
		t.Fatal(err)
	}
	payload := bytes.Repeat([]byte("controlled-bandwidth-payload"), 4096)
	originHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(payload) })
	origin := probeServer(t, originHandler)
	secureOrigin := httptest.NewTLSServer(originHandler)
	t.Cleanup(secureOrigin.Close)
	legacy, err := inbound.NewMixed(&inbound.MixedOption{BaseOption: inbound.BaseOption{NameStr: "legacy-speedtest", Listen: "127.0.0.1", Port: "0", SpecialProxy: "HOTARU-SPEEDTEST"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := legacy.Listen(tunnel.Tunnel); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = legacy.Close() })
	legacyAddress, err := url.Parse("http://" + legacy.Address())
	if err != nil {
		t.Fatal(err)
	}
	legacyTransport := &http.Transport{Proxy: http.ProxyURL(legacyAddress)}
	t.Cleanup(legacyTransport.CloseIdleConnections)
	legacyResponse, err := (&http.Client{Transport: legacyTransport, Timeout: time.Second}).Get(origin.URL)
	if err != nil {
		t.Fatal(err)
	}
	legacyResponse.Body.Close()
	if legacyResponse.StatusCode != http.StatusProxyAuthRequired {
		t.Fatalf("legacy listener status=%d, want 407", legacyResponse.StatusCode)
	}
	t.Log("control: inherited proxy authentication returned HTTP 407 before reaching either exit")
	transport := &http.Transport{Proxy: http.ProxyURL(address), DisableKeepAlives: true,
		TLSClientConfig: secureOrigin.Client().Transport.(*http.Transport).TLSClientConfig,
	}
	t.Cleanup(transport.CloseIdleConnections)
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
	for _, mode := range []tunnel.TunnelMode{tunnel.Rule, tunnel.Global, tunnel.Direct} {
		tunnel.SetMode(mode)
		for _, node := range []string{"B", "A"} {
			t.Run(mode.String()+"/"+node, func(t *testing.T) {
				change := handleChangeProxy(&ChangeProxyParams{GroupName: "HOTARU-SPEEDTEST", ProxyName: node, ForSpeedTest: true})
				if change.Message != "" || change.SpeedTestProxy != "PROXY "+listener.Address() {
					t.Fatalf("prepare=%+v", change)
				}
				for _, endpoint := range []string{origin.URL, secureOrigin.URL} {
					response, err := client.Get(endpoint + "/download?mode=" + mode.String() + "&node=" + node)
					if err != nil {
						t.Fatal(err)
					}
					received, err := io.ReadAll(response.Body)
					response.Body.Close()
					if err != nil || !bytes.Equal(received, payload) {
						t.Fatalf("download bytes=%d err=%v", len(received), err)
					}
					select {
					case actual := <-observed:
						if actual != node {
							t.Fatalf("actual wire exit=%s, selected node=%s", actual, node)
						}
					case <-time.After(time.Second):
						t.Fatal("download bypassed the selected proxy")
					}
					select {
					case extra := <-observed:
						t.Fatalf("unexpected additional exit %s", extra)
					default:
					}
				}
				if daily.Adapter().(*outboundgroup.Selector).Now() != "A" || global.Adapter().(*outboundgroup.Selector).Now() != "A" || userGroup.Adapter().(*outboundgroup.Selector).Now() != "A" {
					t.Fatal("per-node bandwidth test changed the daily/global selection")
				}
			})
		}
	}
}
