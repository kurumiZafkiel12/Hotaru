package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
)

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
		if readStop(strings.NewReader(input)) == nil {
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
