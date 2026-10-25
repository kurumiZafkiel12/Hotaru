package core

import (
	"context"
	"errors"
	"net"
	"strings"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/constant"
)

const (
	delayTestConcurrency    = 50
	defaultTestURL          = "https://www.gstatic.com/generate_204"
	defaultDelayTestTimeout = 5 * time.Second
)

var (
	delayTestSlots     = make(slots, delayTestConcurrency)
	anyDelayTestStatus utils.IntRanges[uint16]

	testURL                 atomic.Pointer[string]
	missingDelayTestProxyAt atomic.Int64
)

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

// A name the tunnel does not know is what an apply that fell back to the
// default config looks like: every node of the profile fails its test. Say so
// once a second, not once per node, so the log names the real failure.
func reportMissingDelayTestProxy(name string) {
	now := time.Now().UnixNano()
	last := missingDelayTestProxyAt.Load()
	if last != 0 && now-last < int64(time.Second) {
		return
	}
	if !missingDelayTestProxyAt.CompareAndSwap(last, now) {
		return
	}
	logError("delay test: %q is not part of the applied config", name)
}

// A nil answer means the test never got a slot, which says nothing about the proxy.
func handleTestDelay(params *TestDelayParams) *Delay {
	url := params.TestUrl
	if url == "" {
		url = currentTestURL()
	}
	result := &Delay{Name: params.ProxyName, Url: url, Value: delayFailed, UnifiedDelay: adapter.UnifiedDelay.Load()}

	proxy := lookupProxy(params.ProxyName)
	if proxy == nil {
		result.Error = "missing-proxy"
		reportMissingDelayTestProxy(params.ProxyName)
		return result
	}

	timeout := timeoutFromMillis(params.Timeout, defaultDelayTestTimeout)
	if !delayTestSlots.acquireWithin(context.Background(), timeout) {
		return nil
	}
	defer delayTestSlots.release()

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	start := time.Now()
	delay, err := proxy.URLTest(ctx, url, anyDelayTestStatus)
	result.ElapsedMs = time.Since(start).Milliseconds()
	if err != nil {
		delay = 0
		result.Error = delayErrorCategory(err)
	}
	result.Value = delayValue(delay, ctx.Err() != nil)
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
