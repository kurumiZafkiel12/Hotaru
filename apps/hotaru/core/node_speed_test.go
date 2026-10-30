package core

import (
	"testing"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/inbound"
	"github.com/metacubex/mihomo/tunnel"
)

func nodeSpeedFixture(t *testing.T, name, listen string, users inbound.AuthUsers, start bool) constant.InboundListener {
	t.Helper()
	listener, err := inbound.NewMixed(&inbound.MixedOption{BaseOption: inbound.BaseOption{NameStr: nodeSpeedListenerName, Listen: listen, Port: "0", SpecialProxy: name}, Users: users})
	if err != nil {
		t.Fatal(err)
	}
	if start {
		if err := listener.Listen(tunnel.Tunnel); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = listener.Close() })
	}
	return listener
}

func TestNodeSpeedRejectsMissingUnboundOrPublicListeners(t *testing.T) {
	previous := isRunning.Swap(true)
	t.Cleanup(func() { isRunning.Store(previous) })
	for _, tc := range []struct {
		name     string
		listener constant.InboundListener
	}{
		{"unbound", nodeSpeedFixture(t, "test-group", "127.0.0.1", inbound.AuthUsers{}, false)},
		{"not-loopback", nodeSpeedFixture(t, "test-group", "0.0.0.0", inbound.AuthUsers{}, false)},
		{"inherits-auth", nodeSpeedFixture(t, "test-group", "127.0.0.1", nil, false)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			withCurrentConfig(t, &config.Config{Listeners: map[string]constant.InboundListener{nodeSpeedListenerName: tc.listener}})
			got := handleChangeProxy(&ChangeProxyParams{ForSpeedTest: true, GroupName: "user-group", ProxyName: "node"})
			if got.Message == "" || got.SpeedTestProxy != "" {
				t.Fatalf("unexpected fallback: %+v", got)
			}
		})
	}
	withCurrentConfig(t, nil)
	if got := handleChangeProxy(&ChangeProxyParams{ForSpeedTest: true, ProxyName: "node"}); got.Message == "" {
		t.Fatal("missing config accepted")
	}
}

func TestNodeSpeedListenerReuseRetainsTheOwnedBoundAddress(t *testing.T) {
	original := nodeSpeedFixture(t, "test-group", "127.0.0.1", inbound.AuthUsers{}, true)
	replacement := nodeSpeedFixture(t, "test-group", "127.0.0.1", inbound.AuthUsers{}, false)
	previous := &config.Config{Listeners: map[string]constant.InboundListener{nodeSpeedListenerName: original}}
	next := &config.Config{Listeners: map[string]constant.InboundListener{nodeSpeedListenerName: replacement}}
	reuseNodeSpeedListener(next, previous)
	if next.Listeners[nodeSpeedListenerName] != original || next.Listeners[nodeSpeedListenerName].Address() == "" {
		t.Fatal("unchanged config lost the owned listener")
	}
	changed := nodeSpeedFixture(t, "other-group", "127.0.0.1", inbound.AuthUsers{}, false)
	next.Listeners[nodeSpeedListenerName] = changed
	reuseNodeSpeedListener(next, previous)
	if next.Listeners[nodeSpeedListenerName] != changed {
		t.Fatal("changed route retained an older listener")
	}
}

func TestNodeSpeedRejectsStoppedCoreAndMissingTarget(t *testing.T) {
	previous := isRunning.Swap(false)
	t.Cleanup(func() { isRunning.Store(previous) })
	owned := nodeSpeedFixture(t, "test-group", "127.0.0.1", inbound.AuthUsers{}, true)
	withCurrentConfig(t, &config.Config{Listeners: map[string]constant.InboundListener{nodeSpeedListenerName: owned}})
	for _, target := range []string{"node", ""} {
		got := handleChangeProxy(&ChangeProxyParams{ForSpeedTest: true, ProxyName: target})
		if got.Message == "" || got.SpeedTestProxy != "" {
			t.Fatalf("stopped or missing target accepted: %+v", got)
		}
	}
	isRunning.Store(true)
	if got := handleChangeProxy(&ChangeProxyParams{ForSpeedTest: true}); got.Message == "" {
		t.Fatal("empty target accepted while running")
	}
}
