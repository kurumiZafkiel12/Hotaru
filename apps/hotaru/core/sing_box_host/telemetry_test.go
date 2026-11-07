package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"runtime/debug"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
)

type telemetryTestEngine struct {
	testEngine
	snapshot func() (telemetrySnapshot, error)
}

func (e telemetryTestEngine) Telemetry() (telemetrySnapshot, error) { return e.snapshot() }

func TestFramedTelemetryIsReadOnlyAndKeepsGracefulStop(t *testing.T) {
	parent, child := net.Pipe()
	defer parent.Close()
	defer child.Close()
	_ = parent.SetDeadline(time.Now().Add(5 * time.Second))
	result := make(chan error, 1)
	closed := 0
	go func() {
		result <- serveFramed(context.Background(), []byte("{}"), child, func(context.Context, []byte) (engine, error) {
			return telemetryTestEngine{testEngine{start: func() error { return nil }, close: func() error { closed++; return nil }},
				func() (telemetrySnapshot, error) { return telemetrySnapshot{Upload: 41, Download: 93}, nil }}, nil
		})
	}()
	if payload, err := readFrame(parent); err != nil || !bytes.Contains(payload, []byte(`"event":"ready"`)) {
		t.Fatalf("ready: %s %v", payload, err)
	}
	for _, id := range []int{1, 2} {
		if _, err := (frameWriter{parent}).Write([]byte(fmt.Sprintf("{\"method\":\"telemetry\",\"id\":%d}\n", id))); err != nil {
			t.Fatal(err)
		}
		payload, err := readFrame(parent)
		var response telemetryEvent
		if err != nil || json.Unmarshal(payload, &response) != nil || response.RequestID != uint32(id) || response.Event != "telemetry" || response.Error != "" {
			t.Fatalf("telemetry: %s %v", payload, err)
		}
		if response.Data == nil || response.Data.Upload != 41 {
			t.Fatalf("wrong source: %s", payload)
		}
	}
	if _, err := (frameWriter{parent}).Write([]byte("stop\n")); err != nil {
		t.Fatal(err)
	}
	payload, err := readFrame(parent)
	if err != nil || !bytes.Contains(payload, []byte(`"clean":true`)) {
		t.Fatalf("stop: %s %v", payload, err)
	}
	if err := <-result; err != nil || closed != 1 {
		t.Fatalf("close: %d %v", closed, err)
	}
}

func TestTelemetryControlsRejectAmbiguityAndBoundResponses(t *testing.T) {
	for _, request := range []string{
		`{"method":"telemetry","id":0}`, `{"method":"telemetry","id":-1}`,
		`{"method":"telemetry","id":4294967296}`, `{"method":"telemetry","id":1,"extra":true}`,
		`{"method":"telemetry","id":1} {}`, `{"method":"restart","id":1}`,
	} {
		var output bytes.Buffer
		if readControl(strings.NewReader(request+"\n"), &output, func() telemetrySource { return nil }) == nil || output.Len() != 0 {
			t.Fatalf("accepted invalid command: %s", request)
		}
	}
	var output bytes.Buffer
	if err := emitTelemetry(&output, 7, nil); err != nil || !strings.Contains(output.String(), `"error":"telemetry_unavailable"`) {
		t.Fatalf("missing source: %s %v", output.String(), err)
	}
	output.Reset()
	large := telemetryTestEngine{snapshot: func() (telemetrySnapshot, error) {
		return telemetrySnapshot{Active: []observedConnection{{Host: strings.Repeat("x", maxControlFrame+1)}}}, nil
	}}
	if err := emitTelemetry(&output, 8, large); err != nil || output.Len() > 256 || !strings.Contains(output.String(), `"error":"telemetry_too_large"`) {
		t.Fatalf("oversized response: %d %v", output.Len(), err)
	}
}

func TestNativeTelemetryRetainsClosedTrafficAndSerializesClose(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	config := []byte(fmt.Sprintf(`{"log":{"disabled":true},"inbounds":[{"type":"mixed","tag":"fixture","listen":"127.0.0.1","listen_port":%d}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"},"experimental":{"clash_api":{}}}`, port))
	instance, err := newEngineConfig(context.Background(), config)
	if err != nil {
		t.Fatal(err)
	}
	defer instance.Close()
	if err := instance.Start(); err != nil {
		t.Fatal(err)
	}
	source := instance.(telemetrySource)
	release := make(chan struct{})
	var releaseOnce sync.Once
	releaseResponse := func() { releaseOnce.Do(func() { close(release) }) }
	seen := make(chan struct{})
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "12")
		_, _ = io.WriteString(w, "native")
		w.(http.Flusher).Flush()
		close(seen)
		<-release
		_, _ = io.WriteString(w, "-proof")
	}))
	defer func() { releaseResponse(); origin.Close() }()
	proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
	transport := &http.Transport{Proxy: http.ProxyURL(proxy)}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
	response, err := client.Get(origin.URL + "/telemetry")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	select {
	case <-seen:
	case <-time.After(5 * time.Second):
		t.Fatal("origin not reached")
	}
	var active telemetrySnapshot
	for i := 0; i < 100; i++ {
		value, err := source.Telemetry()
		if err != nil {
			t.Fatal(err)
		}
		active = value
		if len(active.Active) == 1 && active.Active[0].Download > 0 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if len(active.Active) != 1 || active.Active[0].Download == 0 || active.Active[0].SourcePort == 0 || active.Active[0].Inbound != "fixture" || len(active.Active[0].Chain) != 1 || active.Active[0].Chain[0] != "direct" {
		t.Fatalf("active observation: %+v", active)
	}
	releaseResponse()
	body, err := io.ReadAll(response.Body)
	if err != nil || string(body) != "native-proof" {
		t.Fatalf("body: %s %v", body, err)
	}
	transport.CloseIdleConnections()
	var closed telemetrySnapshot
	for i := 0; i < 100; i++ {
		value, err := source.Telemetry()
		if err != nil {
			t.Fatal(err)
		}
		closed = value
		if len(closed.Closed) == 1 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if len(closed.Closed) != 1 || closed.Closed[0].ID != active.Active[0].ID || closed.Closed[0].ClosedAt.IsZero() || closed.Download < active.Download || closed.Closed[0].Download < active.Active[0].Download {
		t.Fatalf("closed observation: %+v", closed)
	}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 10; j++ {
				_, _ = source.Telemetry()
			}
		}()
	}
	_ = instance.Close()
	wg.Wait()
	if _, err := source.Telemetry(); err == nil {
		t.Fatal("closed engine returned observations")
	}
	final := instance.(*observedEngine).FinalTraffic()
	if final == nil || final.Download < closed.Download || final.Upload < closed.Upload {
		t.Fatal("final counters lost closed traffic")
	}

}

func TestNativeTelemetryHistoryCapRetainsEvictedTotals(t *testing.T) {
	previousGC := debug.SetGCPercent(-1)
	defer debug.SetGCPercent(previousGC)
	instance, err := newEngineConfig(context.Background(), []byte(`{"log":{"disabled":true},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"},"experimental":{"clash_api":{}}}`))
	if err != nil {
		t.Fatal(err)
	}
	defer instance.Close()
	if err := instance.Start(); err != nil {
		t.Fatal(err)
	}
	engine := instance.(*observedEngine)
	outbound, found := engine.Outbound().Outbound("direct")
	if !found {
		t.Fatal("outbound missing")
	}
	for i := 0; i < telemetryConnectionLimit+1; i++ {
		left, right := net.Pipe()
		tracked := engine.traffic.RoutedConnection(context.Background(), left, adapter.InboundContext{OutboundChain: []adapter.Outbound{outbound}}, nil, outbound)
		active := engine.traffic.Connections()
		if len(active) != 1 {
			t.Fatal("tracker missing")
		}
		active[0].Upload.Add(1)
		_ = tracked.Close()
		_ = right.Close()
	}
	value, err := engine.Telemetry()
	if err != nil {
		t.Fatal(err)
	}
	snapshot := value
	if len(snapshot.Closed) != telemetryConnectionLimit || len(snapshot.Active) != 0 || snapshot.Upload != telemetryConnectionLimit+1 || snapshot.HistoryCapacity != telemetryConnectionLimit {
		t.Fatalf("history=%d active=%d upload=%d capacity=%d", len(snapshot.Closed), len(snapshot.Active), snapshot.Upload, snapshot.HistoryCapacity)
	}
	engine.traffic.Clear()
	cleared, err := engine.Telemetry()
	if err != nil || len(cleared.Closed) != 0 || cleared.Upload != telemetryConnectionLimit+1 {
		t.Fatalf("cleared history lost totals: %v", err)
	}
	_ = instance.Close()
	final := engine.FinalTraffic()
	if final == nil || final.Upload != telemetryConnectionLimit+1 {
		t.Fatal("final counters lost evicted traffic")
	}

}
