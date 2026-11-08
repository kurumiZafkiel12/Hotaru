package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"runtime"
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

func TestMemoryObservationReportsTheHostProcessAndRuntime(t *testing.T) {
	observed := readMemorySnapshot()
	if observed == nil {
		if runtime.GOOS == "windows" || runtime.GOOS == "linux" {
			t.Fatal("native resident memory missing")
		}
		t.Skip("resident memory is unavailable on this platform")
	}
	if observed.RSS == 0 || observed.HeapInuse == 0 || observed.StackInuse == 0 {
		t.Fatalf("incomplete live memory observation: %+v", observed)
	}
	source := telemetryTestEngine{snapshot: func() (telemetrySnapshot, error) {
		return telemetrySnapshot{Upload: 7, Download: 13, Memory: observed}, nil
	}}
	var output bytes.Buffer
	if err := emitTelemetry(&output, 3, source); err != nil {
		t.Fatal(err)
	}
	var event telemetryEvent
	if err := json.Unmarshal(output.Bytes(), &event); err != nil {
		t.Fatal(err)
	}
	if event.Data == nil || event.Data.Memory == nil || *event.Data.Memory != *observed || event.Data.Upload != 7 || event.Data.Download != 13 {
		t.Fatalf("memory or traffic changed in transport: %s", output.String())
	}
}

type maintenanceTestEngine struct {
	telemetryTestEngine
	collects int
	resets   int
}

func (e *maintenanceTestEngine) CollectMemory() error       { e.collects++; return nil }
func (e *maintenanceTestEngine) ResetDNSConnections() error { e.resets++; return nil }

func TestFramedMaintenanceKeepsTrafficAndStopAcknowledgement(t *testing.T) {
	parent, child := net.Pipe()
	defer parent.Close()
	defer child.Close()
	_ = parent.SetDeadline(time.Now().Add(5 * time.Second))
	instance := &maintenanceTestEngine{telemetryTestEngine: telemetryTestEngine{
		testEngine: testEngine{start: func() error { return nil }, close: func() error { return nil }},
		snapshot:   func() (telemetrySnapshot, error) { return telemetrySnapshot{Upload: 41, Download: 93}, nil },
	}}
	result := make(chan error, 1)
	go func() {
		result <- serveFramed(context.Background(), []byte("{}"), child, func(context.Context, []byte) (engine, error) { return instance, nil })
	}()
	ready, err := readFrame(parent)
	if err != nil {
		t.Fatal(err)
	}
	var event hostEvent
	if json.Unmarshal(ready, &event) != nil || strings.Join(event.Features, ",") != "telemetry,collect_memory,reset_dns_connections" {
		t.Fatalf("wrong capability declaration: %s", ready)
	}
	for index, method := range []string{"collect_memory", "reset_dns_connections", "telemetry"} {
		if _, err := (frameWriter{parent}).Write([]byte(fmt.Sprintf("{\"method\":\"%s\",\"id\":%d}\n", method, index+1))); err != nil {
			t.Fatal(err)
		}
		payload, err := readFrame(parent)
		var response telemetryEvent
		if err != nil || json.Unmarshal(payload, &response) != nil || response.RequestID != uint32(index+1) || response.Data == nil || response.Data.Upload != 41 || response.Data.Download != 93 || response.Error != "" {
			t.Fatalf("maintenance acknowledgement: %s %v", payload, err)
		}
	}
	if _, err := (frameWriter{parent}).Write([]byte("stop\n")); err != nil {
		t.Fatal(err)
	}
	stopped, err := readFrame(parent)
	if err != nil || !bytes.Contains(stopped, []byte(`"clean":true`)) {
		t.Fatalf("stop: %s %v", stopped, err)
	}
	if err := <-result; err != nil || instance.collects != 1 || instance.resets != 1 {
		t.Fatalf("operations: %v collects=%d resets=%d", err, instance.collects, instance.resets)
	}
}

func TestNativeMaintenanceRetainsActiveTrackersAndCounters(t *testing.T) {
	instance, err := newEngineConfig(context.Background(), []byte(`{"log":{"disabled":true},"outbounds":[{"type":"direct","tag":"direct"}],"experimental":{"clash_api":{}}}`))
	if err != nil {
		t.Fatal(err)
	}
	defer instance.Close()
	if err := instance.Start(); err != nil {
		t.Fatal(err)
	}
	observed := instance.(*observedEngine)
	outbound, _ := observed.Outbound().Outbound("direct")
	left, right := net.Pipe()
	defer right.Close()
	tracked := observed.traffic.RoutedConnection(context.Background(), left, adapter.InboundContext{OutboundChain: []adapter.Outbound{outbound}}, nil, outbound)
	defer tracked.Close()
	connection := observed.traffic.Connections()[0]
	connection.Upload.Add(41)
	connection.Download.Add(93)
	if err := observed.ResetDNSConnections(); err != nil {
		t.Fatal(err)
	}
	if err := observed.CollectMemory(); err != nil {
		t.Fatal(err)
	}
	snapshot, err := observed.Telemetry()
	if err != nil || len(snapshot.Active) != 1 || snapshot.Upload != 41 || snapshot.Download != 93 {
		t.Fatalf("maintenance disturbed active data: %+v %v", snapshot, err)
	}
	_ = instance.Close()
	if !errors.Is(observed.CollectMemory(), errRuntimeMaintenanceUnavailable) || !errors.Is(observed.ResetDNSConnections(), errRuntimeMaintenanceUnavailable) {
		t.Fatal("maintenance accepted after close")
	}
}

func TestNativeMaintenancePreservesThenClosesRealProxyStreams(t *testing.T) {
	freePort := func() int {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		port := listener.Addr().(*net.TCPAddr).Port
		_ = listener.Close()
		return port
	}
	mixed, api := freePort(), freePort()
	config := []byte(fmt.Sprintf(`{"log":{"disabled":true},"inbounds":[{"type":"mixed","tag":"fixture","listen":"127.0.0.1","listen_port":%d}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"},"experimental":{"clash_api":{"external_controller":"127.0.0.1:%d","secret":"fixture"}}}`, mixed, api))
	instance, err := newEngineConfig(context.Background(), config)
	if err != nil {
		t.Fatal(err)
	}
	defer instance.Close()
	if err := instance.Start(); err != nil {
		t.Fatal(err)
	}
	observed := instance.(*observedEngine)
	proceed, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	advance := func() { once.Do(func() { close(proceed) }) }
	origin := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		_, _ = io.WriteString(writer, "held")
		writer.(http.Flusher).Flush()
		<-proceed
		_, _ = io.WriteString(writer, "more")
		writer.(http.Flusher).Flush()
		<-release
	}))
	defer origin.Close()
	defer func() { advance(); close(release) }()
	proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", mixed))
	transport := &http.Transport{Proxy: http.ProxyURL(proxy)}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
	responses := make([]*http.Response, 0, 2)
	for range 2 {
		response, err := client.Get(origin.URL)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		prefix := make([]byte, 4)
		if _, err := io.ReadFull(response.Body, prefix); err != nil || string(prefix) != "held" {
			t.Fatalf("initial payload: %q %v", prefix, err)
		}
		responses = append(responses, response)
	}
	active := observed.traffic.Connections()
	if len(active) != 2 {
		t.Fatalf("active connections: %d", len(active))
	}
	control := &http.Client{Transport: &http.Transport{}, Timeout: 3 * time.Second}
	defer control.CloseIdleConnections()
	request := func(method, path string) {
		req, _ := http.NewRequest(method, fmt.Sprintf("http://127.0.0.1:%d%s", api, path), nil)
		req.Header.Set("Authorization", "Bearer fixture")
		response, err := control.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.Copy(io.Discard, response.Body)
		_ = response.Body.Close()
		if response.StatusCode != http.StatusNoContent {
			t.Fatalf("maintenance status: %d", response.StatusCode)
		}
	}
	request("POST", "/cache/dns/flush")
	if err := observed.ResetDNSConnections(); err != nil {
		t.Fatal(err)
	}
	if err := observed.CollectMemory(); err != nil {
		t.Fatal(err)
	}
	advance()
	for _, response := range responses {
		payload := make([]byte, 4)
		if _, err := io.ReadFull(response.Body, payload); err != nil || string(payload) != "more" {
			t.Fatalf("maintenance closed data: %q %v", payload, err)
		}
	}
	ended := make(chan struct{}, 2)
	for _, response := range responses {
		go func(response *http.Response) { _, _ = io.Copy(io.Discard, response.Body); ended <- struct{}{} }(response)
	}
	request("DELETE", "/connections/"+active[0].ID.String())
	select {
	case <-ended:
	case <-time.After(3 * time.Second):
		t.Fatal("selected connection did not terminate")
	}
	remaining := observed.traffic.Connections()
	if len(remaining) != 1 || remaining[0].ID == active[0].ID {
		t.Fatal("single close disturbed the wrong connection")
	}
	request("DELETE", "/connections")
	select {
	case <-ended:
	case <-time.After(3 * time.Second):
		t.Fatal("close-all did not terminate the other connection")
	}
	if len(observed.traffic.Connections()) != 0 {
		t.Fatal("active connections survived close-all")
	}
}
