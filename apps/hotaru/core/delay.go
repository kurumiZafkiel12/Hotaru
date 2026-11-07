package core

import (
	"context"
	"errors"
	"net"
	"strings"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/constant"
)

const (
	defaultTestURL          = "https://www.gstatic.com/generate_204"
	defaultDelayTestTimeout = 5 * time.Second
)

var testURL atomic.Pointer[string]

func setTestURL(url string) {
	if url == "" {
		return
	}
	constant.DefaultTestURL = url
	testURL.Store(&url)
}

func currentTestURL() string {
	if url := testURL.Load(); url != nil && *url != "" {
		return *url
	}
	return defaultTestURL
}

const (
	delayTimedOut int32 = -1
	delayFailed   int32 = -2
)

func delayValue(delay uint16, timedOut bool) int32 {
	switch {
	case delay > 0:
		return int32(delay)
	case timedOut:
		return delayTimedOut
	default:
		return delayFailed
	}
}

// A nil answer means the test never got a slot, which says nothing about the proxy.
func handleTestDelay(params *TestDelayParams) *Delay {
	url := params.TestUrl
	if url == "" {
		url = currentTestURL()
	}
	result := &Delay{Name: params.ProxyName, Url: url, Value: delayFailed, UnifiedDelay: adapter.UnifiedDelay.Load()}

	if !sbIsUp.Load() {
		result.Error = "sing-box-not-running"
		return result
	}
	timeout := timeoutFromMillis(params.Timeout, defaultDelayTestTimeout)
	start := time.Now()
	delay, err := sbTestDelay(params.ProxyName, url, timeout)
	result.ElapsedMs = time.Since(start).Milliseconds()
	switch {
	case err == nil && delay > 0:
		result.Value = delay
	case errors.Is(err, errSBTimeout):
		result.Value = delayTimedOut
		result.Error = "timeout"
	default:
		result.Value = delayFailed
		result.Error = delayErrorCategory(err)
	}
	return result
}

func delayErrorCategory(err error) string {
	if err == nil {
		return ""
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return "dns"
	}
	var timeout net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &timeout) && timeout.Timeout()) {
		return "timeout"
	}
	text := strings.ToLower(err.Error())
	for _, item := range []struct{ token, category string }{
		{"certificate", "tls"}, {"tls", "tls"},
		{"quic", "udp-quic"}, {"udp", "udp-quic"},
		{"refused", "connection-refused"}, {"authentication", "authentication"},
		{"eof", "connection-closed"},
	} {
		if strings.Contains(text, item.token) {
			return item.category
		}
	}
	return "unknown"
}
