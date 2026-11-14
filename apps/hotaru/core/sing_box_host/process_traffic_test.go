package main

import (
	"context"
	"io"
	"net"
	"strings"
	"sync"
	"testing"

	"github.com/sagernet/sing-box/adapter"
)

func processMetadata(pid uint32, path string) adapter.InboundContext {
	return adapter.InboundContext{ProcessInfo: &adapter.ConnectionOwner{ProcessID: pid, ProcessPath: path}}
}

func TestProcessCountersKeepClosedFlowBytesBeyondConnectionHistory(t *testing.T) {
	observed := newProcessTraffic()
	for i := 0; i < telemetryConnectionLimit+100; i++ {
		flow := observed.RoutedFlow(context.Background(), processMetadata(42, "fixture.exe"), nil, nil)
		flow.CountForward(2)
		flow.CountReverse(3)
	}
	snapshot := observed.snapshot()
	if snapshot.Capacity != processTrafficLimit || snapshot.Overflow || len(snapshot.Entries) != 1 {
		t.Fatalf("unexpected raw process snapshot: %+v", snapshot)
	}
	entry := snapshot.Entries[0]
	if entry.PID != 42 || entry.Path != "fixture.exe" || entry.Upload != 2200 || entry.Download != 3300 {
		t.Fatalf("closed flow bytes were lost: %+v", entry)
	}
}

func TestProcessCounterNetConnUsesTheSameDirectionsAsNativeTraffic(t *testing.T) {
	observed := newProcessTraffic()
	local, remote := net.Pipe()
	defer local.Close()
	defer remote.Close()
	wrapped := observed.RoutedConnection(context.Background(), local, processMetadata(7, "pipe.exe"), nil, nil)
	finished := make(chan error, 1)
	go func() {
		if _, err := remote.Write([]byte("request")); err != nil {
			finished <- err
			return
		}
		_, err := io.ReadFull(remote, make([]byte, 5))
		finished <- err
	}()
	if _, err := io.ReadFull(wrapped, make([]byte, 7)); err != nil {
		t.Fatal(err)
	}
	if _, err := wrapped.Write([]byte("reply")); err != nil {
		t.Fatal(err)
	}
	if err := <-finished; err != nil {
		t.Fatal(err)
	}
	entry := observed.snapshot().Entries[0]
	if entry.Upload != 7 || entry.Download != 5 {
		t.Fatalf("wrong byte directions: %+v", entry)
	}
}

func TestProcessLimitKeepsKnownCountersAndExplicitUnattributedOverflow(t *testing.T) {
	observed := newProcessTraffic()
	for pid := uint32(1); pid <= processTrafficLimit+1; pid++ {
		observed.RoutedFlow(context.Background(), processMetadata(pid, "app.exe"), nil, nil).CountForward(1)
	}
	observed.RoutedFlow(context.Background(), processMetadata(1, "app.exe"), nil, nil).CountForward(9)
	observed.RoutedFlow(context.Background(), adapter.InboundContext{}, nil, nil).CountReverse(7)
	observed.RoutedFlow(context.Background(), processMetadata(99, strings.Repeat("x", processPathLimit+1)), nil, nil).CountForward(4)
	snapshot := observed.snapshot()
	if len(snapshot.Entries) != processTrafficLimit || !snapshot.Overflow || snapshot.Unattributed.Upload != 5 || snapshot.Unattributed.Download != 7 {
		t.Fatalf("wrong overflow counters: %+v", snapshot)
	}
	for _, entry := range snapshot.Entries {
		if entry.PID == 1 && entry.Upload != 10 {
			t.Fatalf("existing process was lost at capacity: %+v", entry)
		}
	}
}

func TestProcessSnapshotAndUpdatesAreConcurrent(t *testing.T) {
	observed := newProcessTraffic()
	var workers sync.WaitGroup
	for i := 0; i < 32; i++ {
		workers.Add(1)
		go func(pid uint32) {
			defer workers.Done()
			flow := observed.RoutedFlow(context.Background(), processMetadata(pid, "concurrent.exe"), nil, nil)
			for j := 0; j < 100; j++ {
				flow.CountForward(2)
				flow.CountReverse(3)
				_ = observed.snapshot()
			}
		}(uint32(i + 1))
	}
	workers.Wait()
	snapshot := observed.snapshot()
	if len(snapshot.Entries) != 32 {
		t.Fatalf("lost process counters: %d", len(snapshot.Entries))
	}
	for _, entry := range snapshot.Entries {
		if entry.Upload != 200 || entry.Download != 300 {
			t.Fatalf("lost concurrent bytes: %+v", entry)
		}
	}
}
