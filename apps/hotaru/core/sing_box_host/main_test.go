package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"
)

func TestRealListenerConflictAcknowledgesCleanup(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	port := listener.Addr().(*net.TCPAddr).Port
	configuration := []byte(fmt.Sprintf(`{"log":{"disabled":true},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":%d}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}`, port))
	input, writer := io.Pipe()
	defer input.Close()
	defer writer.Close()
	var output bytes.Buffer
	err = serve(context.Background(), "fixture", input, &output, func(ctx context.Context, _ string) (engine, error) {
		return newEngineConfig(ctx, configuration)
	})
	if err == nil {
		t.Fatal("occupied listener was accepted")
	}
	var event hostEvent
	if json.NewDecoder(&output).Decode(&event) != nil || event.Event != "stopped" || !event.Clean {
		t.Fatalf("failed startup did not confirm cleanup: %s", output.String())
	}
}

type testEngine struct {
	start func() error
	close func() error
}

func (e testEngine) Start() error { return e.start() }
func (e testEngine) Close() error { return e.close() }

func TestOwnedControlClosesEngineOnce(t *testing.T) {
	for _, input := range []string{"stop\n", ""} {
		t.Run(input, func(t *testing.T) {
			var output bytes.Buffer
			closed := 0
			err := serve(context.Background(), "fixture", strings.NewReader(input), &output,
				func(ctx context.Context, _ string) (engine, error) {
					return testEngine{start: func() error { return nil }, close: func() error { closed++; return nil }}, nil
				})
			if err != nil || closed != 1 {
				t.Fatalf("serve: %v, close count: %d", err, closed)
			}
			var event hostEvent
			decoder := json.NewDecoder(&output)
			for decoder.Decode(&event) == nil {
			}
			if event.Event != "stopped" || !event.Clean {
				t.Fatalf("missing confirmed cleanup: %+v", event)
			}
		})
	}
}

func TestCleanupFailureCannotProduceCleanAcknowledgement(t *testing.T) {
	var output bytes.Buffer
	err := serve(context.Background(), "fixture", strings.NewReader("stop\n"), &output,
		func(context.Context, string) (engine, error) {
			return testEngine{start: func() error { return nil }, close: func() error { return errors.New("close failed") }}, nil
		})
	if err == nil {
		t.Fatal("cleanup failure was discarded")
	}
	decoder := json.NewDecoder(&output)
	var event hostEvent
	for decoder.Decode(&event) == nil {
	}
	if event.Clean {
		t.Fatal("failed cleanup was acknowledged as clean")
	}
}

func TestStopDuringStartupClosesPartialInstance(t *testing.T) {
	reader, writer := io.Pipe()
	defer reader.Close()
	defer writer.Close()
	var output bytes.Buffer
	closed := 0
	err := serve(context.Background(), "fixture", reader, &output,
		func(ctx context.Context, _ string) (engine, error) {
			return testEngine{start: func() error {
				go func() { _, _ = io.WriteString(writer, "stop\n") }()
				<-ctx.Done()
				return ctx.Err()
			}, close: func() error { closed++; return nil }}, nil
		})
	if !errors.Is(err, context.Canceled) || closed != 1 || strings.Contains(output.String(), `"event":"ready"`) {
		t.Fatalf("partial startup handling: %v, %d, %s", err, closed, output.String())
	}
}

func TestInvalidControlFailsClosed(t *testing.T) {
	for _, input := range []string{"restart\n", strings.Repeat("x", 1024)} {
		if readControl(strings.NewReader(input), io.Discard, func() telemetrySource { return nil }) == nil {
			t.Fatal("invalid control was accepted")
		}
	}
}

func TestCleanupPanicNeverAcknowledgesClean(t *testing.T) {
	var output bytes.Buffer
	func() {
		defer func() { _ = recover() }()
		_ = serve(context.Background(), "fixture", strings.NewReader("stop\n"), &output,
			func(context.Context, string) (engine, error) {
				return testEngine{start: func() error { return nil }, close: func() error { panic("close panic") }}, nil
			})
	}()
	decoder := json.NewDecoder(&output)
	var event hostEvent
	for decoder.Decode(&event) == nil {
	}
	if event.Event != "stopped" || event.Clean {
		t.Fatalf("cleanup panic acknowledged incorrectly: %+v", event)
	}
}
