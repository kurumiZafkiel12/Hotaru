package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	boxHTTP "github.com/sagernet/sing-box/protocol/http"
	"github.com/sagernet/sing-box/protocol/vless"
	"github.com/sagernet/sing/common"
	M "github.com/sagernet/sing/common/metadata"
)

var (
	_ adapter.InterfaceUpdateListener = (*observedVLESS)(nil)
	_ adapter.OutboundWithMultiplex   = (*observedVLESS)(nil)
	_ adapter.IdleConnectionKeeper    = (*observedVLESS)(nil)
)

func TestDialObservationContextBoundsAndNativeSurface(t *testing.T) {
	native := new(vless.Outbound)
	wrapped := &observedVLESS{Outbound: native, events: new(dialObservations)}
	if original, ok := common.Cast[*vless.Outbound](wrapped); !ok || original != native {
		t.Fatal("native outbound surface lost")
	}
	if _, ok := common.Cast[*boxHTTP.Outbound](&observedHTTP{Outbound: new(boxHTTP.Outbound)}); !ok {
		t.Fatal("HTTP native surface lost")
	}
	metadata := adapter.InboundContext{Inbound: "mixed", Network: "tcp", Source: M.ParseSocksaddr("127.0.0.1:12345"), Destination: M.ParseSocksaddr("example.com:443")}
	ctx := adapter.WithContext(context.Background(), &metadata)
	events := new(dialObservations)
	root, first := events.begin(ctx, "exit", "http", "tcp", metadata.Destination)
	_, second := events.begin(root, "relay", "http", "tcp", M.ParseSocksaddr("127.0.0.1:8080"))
	events.end(second, true)
	events.end(first, true)
	snapshot := events.snapshot(1 << 20)
	if len(snapshot.Entries) != 2 || snapshot.Entries[1].Parent != "exit" || snapshot.Entries[1].RootID != first || snapshot.Entries[1].Origin.SourcePort != 12345 || !snapshot.Entries[1].Succeeded {
		t.Fatalf("call context lost: %+v", snapshot)
	}
	for i := 0; i < dialObservationLimit; i++ {
		events.begin(ctx, "next", "http", "tcp", metadata.Destination)
	}
	events.end(first, false)
	snapshot = events.snapshot(1 << 24)
	if len(snapshot.Entries) != dialObservationLimit || snapshot.FirstID != 3 || snapshot.LastID != dialObservationLimit+2 || snapshot.Entries[0].CompletedAt != nil {
		t.Fatal("bounded history or stale completion broken")
	}
	bounded := events.snapshot(4096)
	if len(bounded.Entries) >= len(snapshot.Entries) || bounded.LastID-bounded.FirstID+1 != uint64(len(bounded.Entries)) {
		t.Fatal("budget must retain a contiguous recent suffix")
	}
}

func TestRealDetourDialObservationsMatchTwoIndependentProxies(t *testing.T) {
	release := make(chan struct{})
	var once sync.Once
	unlock := func() { once.Do(func() { close(release) }) }
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "12")
		_, _ = io.WriteString(w, "native")
		w.(http.Flusher).Flush()
		<-release
		_, _ = io.WriteString(w, "-proof")
	}))
	defer origin.Close()
	newProxy := func() (*httptest.Server, chan string) {
		seen := make(chan string, 4)
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != "CONNECT" {
				http.Error(w, "CONNECT required", 400)
				return
			}
			target, err := net.Dial("tcp", r.Host)
			if err != nil {
				http.Error(w, "target unavailable", 502)
				return
			}
			downstream, buffer, err := w.(http.Hijacker).Hijack()
			if err != nil {
				target.Close()
				return
			}
			defer downstream.Close()
			defer target.Close()
			seen <- r.Host
			_, _ = buffer.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
			_ = buffer.Flush()
			done := make(chan struct{})
			go func() { _, _ = io.Copy(target, buffer); target.Close(); close(done) }()
			_, _ = io.Copy(downstream, target)
			downstream.Close()
			<-done
		}))
		return server, seen
	}
	exit, exitSeen := newProxy()
	defer exit.Close()
	relay, relaySeen := newProxy()
	defer relay.Close()
	port := func() int {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer listener.Close()
		return listener.Addr().(*net.TCPAddr).Port
	}
	mixed, controller := port(), port()
	endpoint := func(server *httptest.Server) int {
		u, _ := url.Parse(server.URL)
		value, _ := strconv.Atoi(u.Port())
		return value
	}
	configuration := []byte(fmt.Sprintf(`{"log":{"disabled":true},"inbounds":[{"type":"mixed","tag":"mixed","listen":"127.0.0.1","listen_port":%d}],"outbounds":[{"type":"http","tag":"relay","server":"127.0.0.1","server_port":%d},{"type":"http","tag":"exit","server":"127.0.0.1","server_port":%d,"detour":"relay"}],"route":{"final":"exit"},"experimental":{"clash_api":{"external_controller":"127.0.0.1:%d","secret":"fixture"}}}`, mixed, endpoint(relay), endpoint(exit), controller))
	instance, err := newEngineConfig(context.Background(), configuration)
	if err != nil {
		t.Fatal(err)
	}
	if err = instance.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { unlock(); _ = instance.Close() }()
	proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", mixed))
	transport := &http.Transport{Proxy: http.ProxyURL(proxy)}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	response, err := client.Get(origin.URL + "/path")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if target := <-relaySeen; target != fmt.Sprintf("127.0.0.1:%d", endpoint(exit)) {
		t.Fatalf("relay target %s", target)
	}
	if target := <-exitSeen; target != fmt.Sprintf("127.0.0.1:%d", endpoint(origin)) {
		t.Fatalf("exit target %s", target)
	}
	snapshot, err := instance.(pathTelemetrySource).PathTelemetry()
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Active) != 1 || snapshot.Dials == nil || len(snapshot.Dials.Entries) != 2 {
		t.Fatalf("missing observed path: %+v", snapshot)
	}
	first, second := snapshot.Dials.Entries[0], snapshot.Dials.Entries[1]
	if first.Outbound != "exit" || first.Parent != "" || second.Outbound != "relay" || second.Parent != "exit" || first.RootID != second.RootID || first.Origin.SourcePort != snapshot.Active[0].SourcePort || !first.Succeeded || !second.Succeeded {
		t.Fatalf("observations differ from independent receipts: %+v", snapshot.Dials)
	}
	unlock()
	body, err := io.ReadAll(response.Body)
	if err != nil || string(body) != "native-proof" {
		t.Fatalf("forwarding changed: %s %v", body, err)
	}
}
