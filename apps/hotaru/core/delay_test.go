package core

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"testing"
)

func TestDelayFailureCategoryDoesNotExposeCredentials(t *testing.T) {
	for _, item := range []struct {
		err  error
		want string
	}{
		{context.DeadlineExceeded, "timeout"},
		{&net.DNSError{Err: "lookup failed", Name: "private.example"}, "dns"},
		{errors.New("tls: private.example certificate failed"), "tls"},
		{errors.New("quic: private.example disconnected"), "udp-quic"},
		{errors.New("dial private.example: connection refused"), "connection-refused"},
		{errors.New("private.example unexpected EOF"), "connection-closed"},
		{errors.New("password=secret private.example other failure"), "unknown"},
	} {
		category := delayErrorCategory(item.err)
		if category != item.want {
			t.Fatalf("category = %s, want %s", category, item.want)
		}
		payload, err := json.Marshal(Delay{Error: category})
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(payload), "private.example") || strings.Contains(string(payload), "secret") {
			t.Fatal("private error details exposed")
		}
	}
}
