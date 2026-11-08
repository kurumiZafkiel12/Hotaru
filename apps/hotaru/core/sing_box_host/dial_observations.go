package main

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/log"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/service"
)

const dialObservationLimit = 4096

type dialOwnerKey struct{}
type dialFrameKey struct{}
type dialFrame struct {
	root   uint64
	tag    string
	origin dialOrigin
}
type dialOrigin struct {
	Inbound         string `json:"inbound"`
	Network         string `json:"network"`
	SourceIP        string `json:"source_ip"`
	SourcePort      uint16 `json:"source_port"`
	Destination     string `json:"destination"`
	DestinationPort uint16 `json:"destination_port"`
	Host            string `json:"host"`
}
type dialObservation struct {
	ID           uint64     `json:"id"`
	RootID       uint64     `json:"root_id"`
	Parent       string     `json:"parent"`
	Outbound     string     `json:"outbound"`
	OutboundType string     `json:"outbound_type"`
	Destination  string     `json:"dial_destination"`
	DNS          bool       `json:"dns"`
	Origin       dialOrigin `json:"origin"`
	StartedAt    time.Time  `json:"started_at"`
	CompletedAt  *time.Time `json:"completed_at,omitempty"`
	Succeeded    bool       `json:"succeeded"`
}
type dialObservationSnapshot struct {
	Capacity int               `json:"capacity"`
	FirstID  uint64            `json:"first_id"`
	LastID   uint64            `json:"last_id"`
	Entries  []dialObservation `json:"entries"`
}
type dialObservations struct {
	mu      sync.Mutex
	next    uint64
	entries [dialObservationLimit]dialObservation
}

func registerObserved[T any](registry *outbound.Registry, kind string, constructor outbound.ConstructorFunc[T], wrap func(adapter.Outbound) adapter.Outbound) {
	outbound.Register[T](registry, kind, func(ctx context.Context, router adapter.Router, logger log.ContextLogger, tag string, options T) (adapter.Outbound, error) {
		value, err := constructor(context.WithValue(ctx, dialOwnerKey{}, tag), router, logger, tag, options)
		if err != nil {
			return nil, err
		}
		return wrap(value), nil
	})
}

func (d *dialObservations) begin(ctx context.Context, tag, kind, network string, destination M.Socksaddr) (context.Context, uint64) {
	frame, _ := ctx.Value(dialFrameKey{}).(dialFrame)
	parent := frame.tag
	if frame.root == 0 {
		parent, _ = ctx.Value(dialOwnerKey{}).(string)
		if metadata := adapter.ContextFrom(ctx); metadata != nil {
			frame.origin = dialOrigin{Inbound: metadata.Inbound, Network: metadata.Network,
				SourceIP: metadata.Source.AddrString(), SourcePort: metadata.Source.Port,
				Destination: metadata.Destination.AddrString(), DestinationPort: metadata.Destination.Port, Host: metadata.Domain}
			if frame.origin.Network == "" {
				frame.origin.Network = N.NetworkName(network)
			}
		}
	}
	if parent == tag {
		parent = ""
	}
	fields := []string{tag, kind, parent, destination.String(), frame.origin.Inbound, frame.origin.Network,
		frame.origin.SourceIP, frame.origin.Destination, frame.origin.Host}
	for _, field := range fields {
		if len(field) > 1024 || strings.ContainsRune(field, 0) {
			return ctx, 0
		}
	}
	_, dns := adapter.DNSTransportTagFromContext(ctx)
	d.mu.Lock()
	d.next++
	id := d.next
	if frame.root == 0 {
		frame.root = id
	}
	d.entries[(id-1)%dialObservationLimit] = dialObservation{ID: id, RootID: frame.root, Parent: parent, Outbound: tag,
		OutboundType: kind, Destination: destination.String(), DNS: dns, Origin: frame.origin, StartedAt: time.Now().UTC()}
	d.mu.Unlock()
	frame.tag = tag
	return context.WithValue(ctx, dialFrameKey{}, frame), id
}

func (d *dialObservations) end(id uint64, success bool) {
	if id == 0 {
		return
	}
	now := time.Now().UTC()
	d.mu.Lock()
	defer d.mu.Unlock()
	entry := &d.entries[(id-1)%dialObservationLimit]
	if entry.ID == id {
		entry.CompletedAt = &now
		entry.Succeeded = success
	}
}

func (d *dialObservations) snapshot(budget int) *dialObservationSnapshot {
	d.mu.Lock()
	count := min(d.next, uint64(dialObservationLimit))
	entries := make([]dialObservation, 0, int(count))
	for id := d.next - count + 1; id <= d.next && count > 0; id++ {
		entries = append(entries, d.entries[(id-1)%dialObservationLimit])
	}
	d.mu.Unlock()
	cost := func(entry dialObservation) int {
		size := 512
		for _, value := range []string{entry.Parent, entry.Outbound, entry.OutboundType, entry.Destination,
			entry.Origin.Inbound, entry.Origin.Network, entry.Origin.SourceIP, entry.Origin.Destination, entry.Origin.Host} {
			size += len(value) * 6
		}
		return size
	}
	total := 0
	for _, entry := range entries {
		total += cost(entry)
	}
	for len(entries) > 0 && total > budget {
		total -= cost(entries[0])
		entries = entries[1:]
	}
	result := &dialObservationSnapshot{Capacity: dialObservationLimit, Entries: entries}
	if len(entries) > 0 {
		result.FirstID = entries[0].ID
		result.LastID = entries[len(entries)-1].ID
	}
	return result
}

func installDialObservations(ctx context.Context) *dialObservations {
	events := new(dialObservations)
	registry := service.FromContext[adapter.OutboundRegistry](ctx).(*outbound.Registry)
	registerObservedOutbounds(registry, events)
	registerObservedQUIC(registry, events)
	return events
}
