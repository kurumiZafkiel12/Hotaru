package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"testing"
	"time"
)

func TestControlFramingRoundTripAndBounds(t *testing.T) {
	var wire bytes.Buffer
	for _, payload := range [][]byte{[]byte("ready"), bytes.Repeat([]byte("x"), 4097)} {
		if _, err := (frameWriter{&wire}).Write(payload); err != nil {
			t.Fatal(err)
		}
		actual, err := readFrame(&wire)
		if err != nil || !bytes.Equal(actual, payload) {
			t.Fatalf("frame mismatch: %v", err)
		}
	}
	for _, size := range []uint32{0, maxControlFrame + 1} {
		var header [4]byte
		binary.LittleEndian.PutUint32(header[:], size)
		if _, err := readFrame(bytes.NewReader(header[:])); err == nil {
			t.Fatal("invalid frame size accepted")
		}
	}
	for _, truncated := range [][]byte{{1, 0}, {4, 0, 0, 0, 'x'}} {
		if _, err := readFrame(bytes.NewReader(truncated)); err == nil {
			t.Fatal("truncated frame accepted")
		}
	}
}

func TestBootstrapRejectsWrongProtocolUnknownFieldsAndTrailingData(t *testing.T) {
	for _, input := range []string{
		`{"protocol":"hotaru-bootstrap-v1","config":{}}`,
		`{"protocol":"wrong","config":{}}`,
		`{"protocol":"hotaru-bootstrap-v1","config":{},"path":"fixture"}`,
		`{"protocol":"hotaru-bootstrap-v1","config":{}} {}`,
		`{"protocol":"hotaru-bootstrap-v1","config":null}`,
		`{"protocol":"hotaru-bootstrap-v1","config":[]}`,
	} {
		var wire bytes.Buffer
		_, _ = (frameWriter{&wire}).Write([]byte(input))
		actual, err := readBootstrap(&wire)
		if input == `{"protocol":"hotaru-bootstrap-v1","config":{}}` {
			if err != nil || string(actual) != "{}" {
				t.Fatalf("valid bootstrap rejected: %v", err)
			}
		} else if err == nil {
			t.Fatalf("invalid bootstrap accepted: %s", input)
		}
	}
}

func TestFramedLifecycleSharesGracefulEngineOwner(t *testing.T) {
	parent, child := net.Pipe()
	defer parent.Close()
	defer child.Close()
	_ = parent.SetDeadline(time.Now().Add(3 * time.Second))
	closed := make(chan struct{})
	result := make(chan error, 1)
	go func() {
		result <- serveFramed(context.Background(), []byte("{}"), child,
			func(_ context.Context, config []byte) (engine, error) {
				if string(config) != "{}" {
					return nil, io.ErrUnexpectedEOF
				}
				return testEngine{start: func() error { return nil }, close: func() error { close(closed); return nil }}, nil
			})
	}()
	readEvent := func(expected string, clean bool) {
		t.Helper()
		payload, err := readFrame(parent)
		if err != nil {
			t.Fatal(err)
		}
		var event hostEvent
		if json.Unmarshal(payload, &event) != nil || event.Event != expected || event.Clean != clean {
			t.Fatalf("invalid event: %s", payload)
		}
	}
	readEvent("ready", false)
	if _, err := (frameWriter{parent}).Write([]byte("stop\n")); err != nil {
		t.Fatal(err)
	}
	readEvent("stopped", true)
	select {
	case <-closed:
	default:
		t.Fatal("cleanup acknowledgement preceded engine close")
	}
	if err := <-result; err != nil {
		t.Fatal(err)
	}
}
