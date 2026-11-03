package core

import (
	"context"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/tunnel"
)

func TestGeneratedIndependentRulesUseActualSelectedExit(t *testing.T) {
	path := os.Getenv("HOTARU_ROUTING_FIXTURE")
	if path == "" {
		t.Skip("requires the Flutter profile-builder fixture")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := config.UnmarshalRawConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	observed := make(chan string, 8)
	node := controlledHttpExit(t, "Node", observed)
	host, portText, err := net.SplitHostPort(node.Addr())
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatal(err)
	}
	for _, proxy := range raw.Proxy {
		if proxy["name"] == "Node" {
			proxy["type"], proxy["server"], proxy["port"] = "http", host, port
		}
	}
	parsed, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	recordRoutes(t)
	previous := tunnel.Mode()
	tunnel.UpdateProxies(parsed.Proxies, parsed.Providers)
	tunnel.UpdateRules(parsed.Rules, parsed.SubRules, parsed.RuleProviders)
	tunnel.SetMode(tunnel.Rule)
	tunnel.OnRunning()
	t.Cleanup(func() {
		tunnel.OnSuspend()
		tunnel.SetMode(previous)
		tunnel.UpdateProxies(nil, nil)
		tunnel.UpdateRules(nil, nil, nil)
	})
	origin := probeServer(t, func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, "independent-routing-payload") })
	result := runServiceCheck(context.Background(), serviceChecker{name: "generated-rules", check: checkServiceEndpoint(origin.URL)}, "", time.Second)
	if result.Status != serviceReachable {
		t.Fatalf("generated rules request failed: %+v", result)
	}
	select {
	case exit := <-observed:
		if exit != "Node" {
			t.Fatalf("actual CONNECT exit = %q", exit)
		}
	case <-time.After(time.Second):
		t.Fatal("selected exit received no actual traffic")
	}
	if len(result.Observations) != 1 {
		t.Fatalf("missing route receipt: %+v", result)
	}
	receipt := result.Observations[0]
	if receipt.Rule != "Match" || len(receipt.Chains) != 2 || receipt.Chains[0] != "Node" || receipt.Chains[1] != "Selected" {
		t.Fatalf("generated route = %+v", receipt)
	}
	t.Log("actual CONNECT through Node -> Selected; replaced subscription loopback REJECT did not intercept the request")
}
