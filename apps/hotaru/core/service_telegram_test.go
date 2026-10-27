package core

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

func TestTelegramHandshakeRejectsWrongNonceAndHtml(t *testing.T) {
	for _, tc := range []struct {
		name           string
		badNonce, html bool
	}{
		{name: "resPQ for this nonce"},
		{name: "another transaction", badNonce: true},
		{name: "HTML is not MTProto", html: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			client, server := net.Pipe()
			defer client.Close()
			_ = client.SetDeadline(time.Now().Add(time.Second))
			done := make(chan struct{})
			go func() {
				defer close(done)
				defer server.Close()
				request := make([]byte, 42)
				if _, err := io.ReadFull(server, request); err != nil {
					return
				}
				if tc.html {
					_, _ = server.Write([]byte("HTTP/1.1 200 OK\r\n"))
					return
				}
				response := make([]byte, 57)
				response[0] = 14
				binary.LittleEndian.PutUint32(response[17:], 36)
				binary.LittleEndian.PutUint32(response[21:], 0x05162463)
				copy(response[25:41], request[26:42])
				if tc.badNonce {
					response[25] ^= 0xff
				}
				_, _ = server.Write(response)
			}()
			err := telegramHandshake(client)
			_ = client.Close()
			<-done
			if (err != nil) != (tc.badNonce || tc.html) {
				t.Fatalf("handshake error = %v", err)
			}
		})
	}
}

func TestTelegramDcCancellationClosesTheActualConnection(t *testing.T) {
	server, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	entered, closed := make(chan struct{}), make(chan struct{})
	go func() {
		conn, err := server.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		request := make([]byte, 42)
		_, _ = io.ReadFull(conn, request)
		close(entered)
		_, _ = io.Copy(io.Discard, conn)
		close(closed)
	}()
	withProbeProxies(t, "DIRECT")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	observations := []ServiceObservation{}
	done := make(chan error, 1)
	go func() {
		done <- telegramDCProbe(serviceEnv{ctx: ctx, proxyName: "DIRECT", timeout: time.Second, hits: &hitRecorder{}, observations: &observations}, 1, server.Addr().String())
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("no MTProto request")
	}
	cancel()
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("cancel left the connection open")
	}
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled handshake succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("probe did not finish")
	}
	if len(observations) != 1 || observations[0].Error == "" || observations[0].URL != "mtproto://"+server.Addr().String()+"/DC1" {
		t.Fatalf("observations = %+v", observations)
	}
}

func TestClaudeTraceDoesNotEstablishWebAccess(t *testing.T) {
	for _, tc := range []struct {
		country    string
		code       int
		body, want string
	}{
		{"US", 200, "Welcome", serviceReachable},
		{"US", 403, "Just a moment...", serviceChallenge},
		{"HK", 403, "Forbidden", serviceUnsupportedRegion},
	} {
		trace := &ProbeResult{StatusCode: 200, Body: "loc=" + tc.country + "\n"}
		web := &ProbeResult{StatusCode: tc.code, Body: tc.body}
		if got := classifyClaude(trace, web); got.Status != tc.want || got.Region != tc.country {
			t.Fatalf("trace=%s web=%d result=%+v", tc.country, tc.code, got)
		}
	}
}
