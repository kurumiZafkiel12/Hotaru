package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"runtime"
	"runtime/debug"
	"sync"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/trafficcontrol"
	"github.com/sagernet/sing/common/memory"
)

const telemetryConnectionLimit = 1000

var errTelemetryTooLarge = errors.New("telemetry_too_large")
var errRuntimeMaintenanceUnavailable = errors.New("runtime_maintenance_unavailable")

type telemetrySource interface {
	Telemetry() (telemetrySnapshot, error)
}

type observedEngine struct {
	*box.Box
	traffic *trafficcontrol.Manager
	dns     adapter.DNSRouter
	mu      sync.RWMutex
	closed  bool
}

type runtimeMaintenanceSource interface {
	telemetrySource
	CollectMemory() error
	ResetDNSConnections() error
}

var runtimeMaintenanceMethods = map[string]func(runtimeMaintenanceSource) error{
	"collect_memory":        runtimeMaintenanceSource.CollectMemory,
	"reset_dns_connections": runtimeMaintenanceSource.ResetDNSConnections,
}

type maintenanceObservation struct {
	source telemetrySource
	method string
}

func (o maintenanceObservation) Telemetry() (telemetrySnapshot, error) {
	source, ok := o.source.(runtimeMaintenanceSource)
	if !ok {
		return telemetrySnapshot{}, errRuntimeMaintenanceUnavailable
	}
	operation := runtimeMaintenanceMethods[o.method]
	if operation == nil {
		return telemetrySnapshot{}, errRuntimeMaintenanceUnavailable
	}
	if err := operation(source); err != nil {
		return telemetrySnapshot{}, err
	}
	return source.Telemetry()
}

func (e *observedEngine) CollectMemory() error {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if e.closed {
		return errRuntimeMaintenanceUnavailable
	}
	debug.FreeOSMemory()
	return nil
}

func (e *observedEngine) ResetDNSConnections() error {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if e.closed || e.dns == nil {
		return errRuntimeMaintenanceUnavailable
	}
	e.dns.ResetNetwork()
	return nil
}

func (e *observedEngine) Close() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.closed = true
	return e.Box.Close()
}

type trafficTotals struct {
	Upload   int64 `json:"upload"`
	Download int64 `json:"download"`
}

func (e *observedEngine) FinalTraffic() *trafficTotals {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if !e.closed || e.traffic == nil {
		return nil
	}
	up, down := e.traffic.Total()
	return &trafficTotals{Upload: up, Download: down}
}

func (e *observedEngine) Telemetry() (telemetrySnapshot, error) {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if e.closed || e.traffic == nil {
		return telemetrySnapshot{}, errors.New("telemetry_unavailable")
	}
	up, down := e.traffic.Total()
	closed := e.traffic.ClosedConnections()
	active := e.traffic.Connections()
	truncated := len(active) > telemetryConnectionLimit
	if truncated {
		active = active[:telemetryConnectionLimit]
	}
	result := telemetrySnapshot{
		SampledAt: time.Now().UTC(), Upload: up, Download: down,
		HistoryCapacity: telemetryConnectionLimit, ActiveTruncated: truncated,
		Active: make([]observedConnection, 0, len(active)),
		Closed: make([]observedConnection, 0, len(closed)),
		Memory: readMemorySnapshot(),
	}
	budget := maxControlFrame - 4096
	appendConnection := func(c *trafficcontrol.TrackerMetadata, closed bool) error {
		observed := observeConnection(c, closed)
		cost := 1024
		for _, field := range append([]string{observed.ID, observed.Inbound, observed.Network,
			observed.SourceIP, observed.DestinationIP, observed.Host, observed.ProcessPath,
			observed.Rule, observed.Outbound, observed.OutboundType}, observed.Chain...) {
			if len(field) > budget/6 {
				return errTelemetryTooLarge
			}
			cost += len(field)*6 + 4
		}
		budget -= cost
		if budget < 0 {
			return errTelemetryTooLarge
		}
		if closed {
			result.Closed = append(result.Closed, observed)
		} else {
			result.Active = append(result.Active, observed)
		}
		return nil
	}
	for _, connection := range active {
		if err := appendConnection(connection, false); err != nil {
			return telemetrySnapshot{}, err
		}
	}
	for _, connection := range closed {
		if err := appendConnection(connection, true); err != nil {
			return telemetrySnapshot{}, err
		}
	}
	return result, nil
}

type telemetrySnapshot struct {
	SampledAt       time.Time            `json:"sampled_at"`
	Upload          int64                `json:"upload_total"`
	Download        int64                `json:"download_total"`
	HistoryCapacity int                  `json:"history_capacity"`
	ActiveTruncated bool                 `json:"active_truncated"`
	Active          []observedConnection `json:"active"`
	Closed          []observedConnection `json:"closed"`
	Memory          *observedMemory      `json:"memory,omitempty"`
}

type observedMemory struct {
	RSS          uint64 `json:"rss"`
	HeapInuse    uint64 `json:"heap_inuse"`
	HeapIdle     uint64 `json:"heap_idle"`
	StackInuse   uint64 `json:"stack_inuse"`
	RuntimeOther uint64 `json:"runtime_other"`
}

func readMemorySnapshot() *observedMemory {
	rss := memory.Total()
	if rss == 0 {
		return nil
	}
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	return &observedMemory{
		RSS: rss, HeapInuse: stats.HeapInuse, HeapIdle: stats.HeapIdle - stats.HeapReleased,
		StackInuse:   stats.StackInuse,
		RuntimeOther: stats.MSpanInuse + stats.MCacheInuse + stats.BuckHashSys + stats.GCSys + stats.OtherSys,
	}
}

type observedConnection struct {
	ID              string    `json:"id"`
	CreatedAt       time.Time `json:"created_at"`
	ClosedAt        time.Time `json:"closed_at,omitzero"`
	Upload          int64     `json:"upload"`
	Download        int64     `json:"download"`
	Inbound         string    `json:"inbound"`
	Network         string    `json:"network"`
	SourceIP        string    `json:"source_ip"`
	SourcePort      uint16    `json:"source_port"`
	DestinationIP   string    `json:"destination_ip"`
	DestinationPort uint16    `json:"destination_port"`
	Host            string    `json:"host"`
	ProcessID       uint32    `json:"process_id"`
	ProcessPath     string    `json:"process_path"`
	Chain           []string  `json:"chain"`
	Rule            string    `json:"rule"`
	Outbound        string    `json:"outbound"`
	OutboundType    string    `json:"outbound_type"`
}

func observeConnection(c *trafficcontrol.TrackerMetadata, closed bool) observedConnection {
	m := c.Metadata
	host := m.Domain
	if host == "" {
		host = m.Destination.Fqdn
	}
	rule := "final"
	if c.Rule != nil {
		rule = c.Rule.String() + " => " + c.Rule.Action().String()
	}
	result := observedConnection{
		ID: c.ID.String(), CreatedAt: c.CreatedAt, Upload: c.Upload.Load(), Download: c.Download.Load(),
		Inbound: m.Inbound, Network: m.Network, SourcePort: m.Source.Port,
		DestinationPort: m.Destination.Port, Host: host, Chain: append([]string{}, c.Chain...),
		Rule: rule, Outbound: c.Outbound, OutboundType: c.OutboundType,
	}
	if closed {
		result.ClosedAt = c.ClosedAt
	}
	if m.Source.Addr.IsValid() {
		result.SourceIP = m.Source.Addr.String()
	}
	if m.Destination.Addr.IsValid() {
		result.DestinationIP = m.Destination.Addr.String()
	}
	if m.ProcessInfo != nil {
		result.ProcessID = m.ProcessInfo.ProcessID
		result.ProcessPath = m.ProcessInfo.ProcessPath
	}
	return result
}

type telemetryEvent struct {
	Protocol  string             `json:"protocol"`
	Event     string             `json:"event"`
	PID       int                `json:"pid"`
	RequestID uint32             `json:"request_id"`
	Data      *telemetrySnapshot `json:"data,omitempty"`
	Error     string             `json:"error,omitempty"`
}

func emitTelemetry(output io.Writer, id uint32, source telemetrySource) error {
	event := telemetryEvent{Protocol: controlProtocol, Event: "telemetry", PID: os.Getpid(), RequestID: id}
	if source == nil {
		event.Error = "telemetry_unavailable"
	} else {
		var err error
		var data telemetrySnapshot
		data, err = source.Telemetry()
		event.Data = &data
		if err != nil {
			event.Data = nil
			event.Error = "telemetry_unavailable"
			if errors.Is(err, errTelemetryTooLarge) {
				event.Error = "telemetry_too_large"
			} else if errors.Is(err, errRuntimeMaintenanceUnavailable) {
				event.Error = "runtime_maintenance_unavailable"
			}
		}
	}
	var buffer boundedEventBuffer
	if err := json.NewEncoder(&buffer).Encode(event); err != nil {
		event.Data = nil
		event.Error = "telemetry_too_large"
		return json.NewEncoder(output).Encode(event)
	}
	_, err := output.Write(buffer.Bytes())
	return err
}

type boundedEventBuffer struct{ bytes.Buffer }

func (b *boundedEventBuffer) Write(p []byte) (int, error) {
	if len(p) > maxControlFrame-b.Len() {
		return 0, errors.New("telemetry frame exceeds limit")
	}
	return b.Buffer.Write(p)
}

type synchronizedWriter struct {
	io.Writer
	mu sync.Mutex
}

func (w *synchronizedWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.Writer.Write(p)
}
