package main

import (
	"context"
	"net"
	"sync"
	"sync/atomic"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/bufio"
	N "github.com/sagernet/sing/common/network"
)

const processTrafficLimit = 1024
const processPathLimit = 1024

type processKey struct {
	PID  uint32
	Path string
}

type processBytes struct {
	upload   atomic.Int64
	download atomic.Int64
}

type processCounter struct {
	PID      uint32 `json:"pid"`
	Path     string `json:"path"`
	Upload   int64  `json:"upload"`
	Download int64  `json:"download"`
}

type processTrafficSnapshot struct {
	Capacity     int              `json:"capacity"`
	Overflow     bool             `json:"overflow"`
	Unattributed trafficTotals    `json:"unattributed"`
	Entries      []processCounter `json:"entries"`
}

type processTraffic struct {
	mu           sync.Mutex
	entries      map[processKey]*processBytes
	unattributed processBytes
	overflow     bool
}

func newProcessTraffic() *processTraffic {
	return &processTraffic{entries: make(map[processKey]*processBytes)}
}

func (p *processTraffic) counters(metadata adapter.InboundContext) *processBytes {
	info := metadata.ProcessInfo
	if info == nil || (info.ProcessID == 0 && info.ProcessPath == "") {
		return &p.unattributed
	}
	key := processKey{PID: info.ProcessID, Path: info.ProcessPath}
	p.mu.Lock()
	defer p.mu.Unlock()
	if entry := p.entries[key]; entry != nil {
		return entry
	}
	if len(key.Path) > processPathLimit || len(p.entries) >= processTrafficLimit {
		p.overflow = true
		return &p.unattributed
	}
	entry := new(processBytes)
	p.entries[key] = entry
	return entry
}

func (p *processTraffic) snapshot() *processTrafficSnapshot {
	p.mu.Lock()
	defer p.mu.Unlock()
	result := &processTrafficSnapshot{
		Capacity: processTrafficLimit,
		Overflow: p.overflow,
		Unattributed: trafficTotals{
			Upload: p.unattributed.upload.Load(), Download: p.unattributed.download.Load(),
		},
		Entries: make([]processCounter, 0, len(p.entries)),
	}
	for key, entry := range p.entries {
		result.Entries = append(result.Entries, processCounter{
			PID: key.PID, Path: key.Path, Upload: entry.upload.Load(), Download: entry.download.Load(),
		})
	}
	return result
}

func (p *processTraffic) RoutedConnection(_ context.Context, conn net.Conn, metadata adapter.InboundContext, _ adapter.Rule, _ adapter.Outbound) net.Conn {
	entry := p.counters(metadata)
	return bufio.NewInt64CounterConn(conn, []*atomic.Int64{&entry.upload}, []*atomic.Int64{&entry.download})
}

func (p *processTraffic) RoutedPacketConnection(_ context.Context, conn N.PacketConn, metadata adapter.InboundContext, _ adapter.Rule, _ adapter.Outbound) N.PacketConn {
	entry := p.counters(metadata)
	return bufio.NewInt64CounterPacketConn(conn, []*atomic.Int64{&entry.upload}, nil, []*atomic.Int64{&entry.download}, nil)
}

func (p *processTraffic) RoutedFlow(_ context.Context, metadata adapter.InboundContext, _ adapter.Rule, _ adapter.Outbound) tun.FlowTracker {
	return processFlow{p.counters(metadata)}
}

type processFlow struct{ counters *processBytes }

func (f processFlow) AttachFlow(tun.FlowHandle)     {}
func (f processFlow) FlowEstablished()              {}
func (f processFlow) CloseFlow(tun.FlowCloseReason) {}
func (f processFlow) CountForward(n int) {
	if n > 0 {
		f.counters.upload.Add(int64(n))
	}
}
func (f processFlow) CountReverse(n int) {
	if n > 0 {
		f.counters.download.Add(int64(n))
	}
}
