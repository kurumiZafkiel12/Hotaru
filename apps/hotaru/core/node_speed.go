package core

import (
	"errors"
	"net"
	"strconv"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/inbound"
)

const nodeSpeedListenerName = "hotaru-speedtest"

func configuredNodeSpeedListener(cfg *config.Config) (constant.InboundListener, *inbound.MixedOption) {
	if cfg == nil {
		return nil, nil
	}
	listener := cfg.Listeners[nodeSpeedListenerName]
	if listener == nil {
		return nil, nil
	}
	options, ok := listener.Config().(*inbound.MixedOption)
	if !ok || options.Listen != "127.0.0.1" || options.SpecialProxy == "" || options.Users == nil || len(options.Users) != 0 {
		return nil, nil
	}
	return listener, options
}

func configuredNodeSpeedGroup(cfg *config.Config) string {
	_, options := configuredNodeSpeedListener(cfg)
	if options == nil {
		return ""
	}
	return options.SpecialProxy
}

func nodeSpeedRoute(cfg *config.Config) (string, string, error) {
	unavailable := errors.New("node speed-test listener unavailable")
	listener, options := configuredNodeSpeedListener(cfg)
	if listener == nil || !isRunning.Load() {
		return "", "", unavailable
	}
	host, portText, err := net.SplitHostPort(listener.Address())
	port, _ := strconv.Atoi(portText)
	if err != nil || host != "127.0.0.1" || port < 1 || port > 65535 {
		return "", "", unavailable
	}
	return options.SpecialProxy, "PROXY " + net.JoinHostPort(host, portText), nil
}

func reuseNodeSpeedListener(next, previous *config.Config) {
	old, _ := configuredNodeSpeedListener(previous)
	updated, _ := configuredNodeSpeedListener(next)
	if old != nil && updated != nil && old.Address() != "" && old.Config().Equal(updated.Config()) {
		next.Listeners[nodeSpeedListenerName] = old
	}
}
