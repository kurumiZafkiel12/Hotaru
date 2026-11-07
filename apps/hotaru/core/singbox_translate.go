package core

import (
	"fmt"
	"strings"

	"go.yaml.in/yaml/v3"
)

// Translation losses are collected, never silent: the caller logs every
// warning so a downgraded node or rule is visible in the core log.

type sbWarnings struct {
	list []string
}

func (w *sbWarnings) add(format string, args ...any) {
	w.list = append(w.list, fmt.Sprintf(format, args...))
}

func sbMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

func sbStr(v any) string {
	s, _ := v.(string)
	return s
}

func sbInt(v any) int {
	switch n := v.(type) {
	case int:
		return n
	case int64:
		return int(n)
	case float64:
		return int(n)
	}
	return 0
}

func sbBool(v any) bool {
	b, _ := v.(bool)
	return b
}

func sbStrList(v any) []string {
	items, _ := v.([]any)
	out := make([]string, 0, len(items))
	for _, item := range items {
		if s, ok := item.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func sbTLS(p map[string]any, w *sbWarnings, defaultOn bool) map[string]any {
	if !defaultOn && !sbBool(p["tls"]) && p["sni"] == nil && p["servername"] == nil {
		return nil
	}
	t := map[string]any{"enabled": true}
	if sni := sbStr(p["sni"]); sni != "" {
		t["server_name"] = sni
	} else if sn := sbStr(p["servername"]); sn != "" {
		t["server_name"] = sn
	}
	if sbBool(p["skip-cert-verify"]) {
		t["insecure"] = true
	}
	if alpn := sbStrList(p["alpn"]); len(alpn) > 0 {
		t["alpn"] = alpn
	}
	if fp := sbStr(p["client-fingerprint"]); fp != "" {
		t["utls"] = map[string]any{"enabled": true, "fingerprint": fp}
	}
	if ro := sbMap(p["reality-opts"]); ro != nil {
		t["reality"] = map[string]any{
			"enabled":    true,
			"public_key": sbStr(ro["public-key"]),
			"short_id":   sbStr(ro["short-id"]),
		}
	}
	if p["ech-opts"] != nil {
		w.add("%s: ECH options dropped by the beta translator", sbStr(p["name"]))
	}
	return t
}

func sbTransport(p map[string]any, w *sbWarnings) map[string]any {
	net := sbStr(p["network"])
	switch net {
	case "", "tcp":
		return nil
	case "ws":
		opts := sbMap(p["ws-opts"])
		tr := map[string]any{"type": "ws", "path": "/"}
		if path := sbStr(opts["path"]); path != "" {
			tr["path"] = path
		}
		if headers := sbMap(opts["headers"]); headers != nil {
			tr["headers"] = headers
		}
		if early := sbInt(opts["max-early-data"]); early > 0 {
			tr["max_early_data"] = early
			if name := sbStr(opts["early-data-header-name"]); name != "" {
				tr["early_data_header_name"] = name
			}
		}
		return tr
	case "grpc":
		opts := sbMap(p["grpc-opts"])
		return map[string]any{"type": "grpc", "service_name": sbStr(opts["grpc-service-name"])}
	case "h2", "http":
		return map[string]any{"type": "http"}
	case "httpupgrade":
		opts := sbMap(p["http-upgrade-opts"])
		tr := map[string]any{"type": "httpupgrade"}
		if path := sbStr(opts["path"]); path != "" {
			tr["path"] = path
		}
		if host := sbStr(opts["host"]); host != "" {
			tr["host"] = host
		}
		return tr
	}
	w.add("%s: transport %q not supported by the beta translator", sbStr(p["name"]), net)
	return nil
}

func sbBase(p map[string]any) map[string]any {
	return map[string]any{
		"tag":         sbStr(p["name"]),
		"server":      sbStr(p["server"]),
		"server_port": sbInt(p["port"]),
	}
}

func sbProxy(p map[string]any, w *sbWarnings) map[string]any {
	typ := sbStr(p["type"])
	name := sbStr(p["name"])
	switch typ {
	case "vless":
		o := sbBase(p)
		o["type"] = "vless"
		o["uuid"] = sbStr(p["uuid"])
		if flow := sbStr(p["flow"]); flow != "" {
			o["flow"] = flow
		}
		if tls := sbTLS(p, w, false); tls != nil {
			o["tls"] = tls
		}
		if tr := sbTransport(p, w); tr != nil {
			o["transport"] = tr
		}
		if enc := sbStr(p["packet-encoding"]); enc != "" {
			o["packet_encoding"] = enc
		}
		return o
	case "vmess":
		o := sbBase(p)
		o["type"] = "vmess"
		o["uuid"] = sbStr(p["uuid"])
		o["security"] = sbStr(p["cipher"])
		if o["security"] == "" {
			o["security"] = "auto"
		}
		o["alter_id"] = sbInt(p["alterId"])
		if tls := sbTLS(p, w, false); tls != nil {
			o["tls"] = tls
		}
		if tr := sbTransport(p, w); tr != nil {
			o["transport"] = tr
		}
		return o
	case "trojan":
		o := sbBase(p)
		o["type"] = "trojan"
		o["password"] = sbStr(p["password"])
		if tls := sbTLS(p, w, true); tls != nil {
			o["tls"] = tls
		}
		if tr := sbTransport(p, w); tr != nil {
			o["transport"] = tr
		}
		return o
	case "hysteria2":
		o := sbBase(p)
		o["type"] = "hysteria2"
		o["password"] = sbStr(p["password"])
		if obfs := sbStr(p["obfs"]); obfs != "" {
			if obfs == "salamander" {
				o["obfs"] = map[string]any{"type": "salamander", "password": sbStr(p["obfs-password"])}
			} else {
				w.add("%s: hysteria2 obfs %q unsupported", name, obfs)
			}
		}
		if tls := sbTLS(p, w, true); tls != nil {
			o["tls"] = tls
		}
		return o
	case "anytls":
		o := sbBase(p)
		o["type"] = "anytls"
		o["password"] = sbStr(p["password"])
		if tls := sbTLS(p, w, true); tls != nil {
			o["tls"] = tls
		}
		return o
	case "tuic":
		o := sbBase(p)
		o["type"] = "tuic"
		o["uuid"] = sbStr(p["uuid"])
		o["password"] = sbStr(p["password"])
		if cc := sbStr(p["congestion-controller"]); cc != "" {
			o["congestion_control"] = cc
		}
		if mode := sbStr(p["udp-relay-mode"]); mode != "" {
			o["udp_relay_mode"] = mode
		}
		if tls := sbTLS(p, w, true); tls != nil {
			o["tls"] = tls
		}
		return o
	case "ss":
		o := sbBase(p)
		o["type"] = "shadowsocks"
		o["method"] = sbStr(p["cipher"])
		o["password"] = sbStr(p["password"])
		if sbBool(p["udp-over-tcp"]) {
			o["udp_over_tcp"] = true
		}
		if plugin := sbStr(p["plugin"]); plugin != "" {
			w.add("%s: shadowsocks plugin %q not translated in beta (node may fail)", name, plugin)
		}
		return o
	case "socks", "socks5":
		o := sbBase(p)
		o["type"] = "socks"
		if u := sbStr(p["username"]); u != "" {
			o["username"] = u
		}
		if pw := sbStr(p["password"]); pw != "" {
			o["password"] = pw
		}
		return o
	case "http":
		o := sbBase(p)
		o["type"] = "http"
		if u := sbStr(p["username"]); u != "" {
			o["username"] = u
		}
		if pw := sbStr(p["password"]); pw != "" {
			o["password"] = pw
		}
		if tls := sbTLS(p, w, false); tls != nil {
			o["tls"] = tls
		}
		return o
	}
	w.add("%s: proxy type %q has no sing-box equivalent in the beta translator — dropped", name, typ)
	return nil
}

func sbGroup(g map[string]any, valid map[string]bool, w *sbWarnings) map[string]any {
	typ := sbStr(g["type"])
	name := sbStr(g["name"])
	members := make([]string, 0)
	dropped := make([]string, 0)
	for _, m := range sbStrList(g["proxies"]) {
		if valid[m] {
			members = append(members, m)
		} else {
			dropped = append(dropped, m)
		}
	}
	if len(dropped) > 0 {
		w.add("group %s: members dropped (unknown or untranslated): %s", name, strings.Join(dropped, ", "))
	}
	urlTest := func() map[string]any {
		o := map[string]any{
			"type":      "urltest",
			"tag":       name,
			"outbounds": members,
			"url":       sbStr(g["url"]),
			"interval":  fmt.Sprintf("%ds", max(sbInt(g["interval"]), 1)),
		}
		if o["url"] == "" {
			o["url"] = "https://www.gstatic.com/generate_204"
		}
		if g["interval"] == nil {
			o["interval"] = "300s"
		}
		return o
	}
	switch typ {
	case "select":
		o := map[string]any{"type": "selector", "tag": name, "outbounds": members}
		if len(members) > 0 {
			o["default"] = members[0]
		}
		return o
	case "url-test":
		o := urlTest()
		if tol := g["tolerance"]; tol != nil {
			o["tolerance"] = sbInt(tol)
		}
		return o
	case "fallback":
		w.add("group %s: fallback approximated as urltest (no exact sing-box equivalent)", name)
		return urlTest()
	case "load-balance":
		w.add("group %s: load-balance has no sing-box equivalent — approximated as urltest", name)
		return urlTest()
	}
	w.add("group %s: type %q unsupported — dropped", name, typ)
	return nil
}

const sbRuleSetBase = "https://raw.githubusercontent.com/SagerNet"

func sbRules(rawRules []any, valid map[string]bool, w *sbWarnings) (rules []any, ruleSets []any, final string) {
	sets := map[string]map[string]any{}
	resolve := func(target string) (string, bool) {
		switch target {
		case "DIRECT":
			return "direct", true
		case "REJECT":
			return "block", true
		}
		if valid[target] {
			return target, true
		}
		return "", false
	}
	for _, raw := range rawRules {
		text, _ := raw.(string)
		parts := strings.Split(text, ",")
		for i := range parts {
			parts[i] = strings.TrimSpace(parts[i])
		}
		if len(parts) < 2 {
			continue
		}
		kind := strings.ToUpper(parts[0])
		target, ok := resolve(parts[len(parts)-1])
		if !ok {
			w.add("rule %q: target %q unknown — skipped", text, parts[len(parts)-1])
			continue
		}
		switch {
		case kind == "MATCH":
			final = target
		case kind == "DOMAIN" && len(parts) >= 3:
			rules = append(rules, map[string]any{"domain": []string{parts[1]}, "outbound": target})
		case kind == "DOMAIN-SUFFIX" && len(parts) >= 3:
			rules = append(rules, map[string]any{"domain_suffix": []string{parts[1]}, "outbound": target})
		case kind == "DOMAIN-KEYWORD" && len(parts) >= 3:
			rules = append(rules, map[string]any{"domain_keyword": []string{parts[1]}, "outbound": target})
		case (kind == "IP-CIDR" || kind == "IP-CIDR6") && len(parts) >= 3:
			rules = append(rules, map[string]any{"ip_cidr": []string{parts[1]}, "outbound": target})
		case kind == "GEOIP" && len(parts) >= 3:
			tag := "geoip-" + strings.ToLower(parts[1])
			sets[tag] = map[string]any{
				"type": "remote", "tag": tag, "format": "binary",
				"url":             sbRuleSetBase + "/sing-geoip/rule-set/" + tag + ".srs",
				"download_detour": "direct",
			}
			rules = append(rules, map[string]any{"rule_set": []string{tag}, "outbound": target})
		case kind == "GEOSITE" && len(parts) >= 3:
			tag := "geosite-" + strings.ToLower(parts[1])
			sets[tag] = map[string]any{
				"type": "remote", "tag": tag, "format": "binary",
				"url":             sbRuleSetBase + "/sing-geosite/rule-set/" + tag + ".srs",
				"download_detour": "direct",
			}
			rules = append(rules, map[string]any{"rule_set": []string{tag}, "outbound": target})
		case kind == "PROCESS-NAME" && len(parts) >= 3:
			rules = append(rules, map[string]any{"process_name": []string{parts[1]}, "outbound": target})
		case kind == "SRC-IP-CIDR" && len(parts) >= 3:
			rules = append(rules, map[string]any{"source_ip_cidr": []string{parts[1]}, "outbound": target})
		case kind == "DST-PORT" && len(parts) >= 3:
			rules = append(rules, map[string]any{"port": []int{sbInt(parseNumber(parts[1]))}, "outbound": target})
		default:
			w.add("rule %q: type %q not translated in beta — skipped", text, kind)
		}
	}
	for _, set := range sets {
		ruleSets = append(ruleSets, set)
	}
	return rules, ruleSets, final
}

func parseNumber(s string) any {
	var n int
	_, err := fmt.Sscanf(s, "%d", &n)
	if err != nil {
		return 0
	}
	return n
}

// translateSingBoxConfig converts the effective Mihomo YAML document (the
// same bytes the core applies) into a sing-box configuration document.
func translateSingBoxConfig(raw []byte) (map[string]any, []string, error) {
	var cfg map[string]any
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return nil, nil, err
	}
	w := &sbWarnings{}
	out := map[string]any{
		"log": map[string]any{"level": sbStr(cfg["log-level"]), "timestamp": true},
	}
	if out["log"].(map[string]any)["level"] == "" {
		out["log"].(map[string]any)["level"] = "info"
	}

	dnsCfg := sbMap(cfg["dns"])
	servers := []any{}
	nameservers := sbStrList(dnsCfg["nameserver"])
	if len(nameservers) == 0 {
		nameservers = sbStrList(dnsCfg["default-nameserver"])
	}
	if len(nameservers) > 0 {
		first := nameservers[0]
		if strings.Contains(first, "://") {
			w.add("dns: nameserver %q needs a scheme-specific mapping in beta — replaced with 223.5.5.5", first)
		} else {
			servers = append(servers, map[string]any{"type": "udp", "tag": "dns-local", "server": first})
		}
	}
	if len(servers) == 0 {
		servers = append(servers, map[string]any{"type": "udp", "tag": "dns-local", "server": "223.5.5.5"})
	}
	if dnsCfg["fake-ip-range"] != nil || sbBool(dnsCfg["fake-ip-enabled"]) {
		w.add("dns: fake-ip is not translated in beta — sing-box resolves real IPs")
	}
	out["dns"] = map[string]any{"servers": servers, "final": "dns-local", "strategy": "ipv4_only"}

	inbounds := []any{}
	mixedPort := sbInt(cfg["mixed-port"])
	if mixedPort == 0 {
		mixedPort = sbInt(cfg["port"])
	}
	if mixedPort == 0 {
		mixedPort = 7890
	}
	inbounds = append(inbounds, map[string]any{
		"type": "mixed", "tag": "mixed-in",
		"listen": "127.0.0.1", "listen_port": mixedPort,
	})
	tun := sbMap(cfg["tun"])
	tunOn := tun != nil && sbBool(tun["enable"])
	if tunOn {
		device := sbStr(tun["device"])
		if device == "" {
			device = "Hotaru"
		}
		stack := sbStr(tun["stack"])
		if stack == "" {
			stack = "mixed"
		}
		inbounds = append(inbounds, map[string]any{
			"type": "tun", "tag": "tun-in",
			"interface_name": device,
			"address":        []string{"172.19.0.1/30"},
			"auto_route":     true,
			"strict_route":   true,
			"stack":          stack,
		})
	}
	out["inbounds"] = inbounds

	valid := map[string]bool{"DIRECT": true, "REJECT": true}
	outbounds := []any{}
	proxies, _ := cfg["proxies"].([]any)
	for _, item := range proxies {
		p := sbMap(item)
		if p == nil {
			continue
		}
		valid[sbStr(p["name"])] = true
		o := sbProxy(p, w)
		if o == nil {
			continue
		}
		if detour := sbStr(p["dialer-proxy"]); detour != "" {
			o["detour"] = detour
		}
		outbounds = append(outbounds, o)
	}
	groups, _ := cfg["proxy-groups"].([]any)
	for _, item := range groups {
		if g := sbMap(item); g != nil {
			valid[sbStr(g["name"])] = true
		}
	}
	for _, item := range groups {
		g := sbMap(item)
		if g == nil {
			continue
		}
		if o := sbGroup(g, valid, w); o != nil {
			outbounds = append(outbounds, o)
		}
	}
	outbounds = append(outbounds,
		map[string]any{"type": "direct", "tag": "direct"},
		map[string]any{"type": "block", "tag": "block"},
	)
	out["outbounds"] = outbounds

	rawRules, _ := cfg["rules"].([]any)
	rules, ruleSets, final := sbRules(rawRules, valid, w)
	routeRules := []any{
		map[string]any{"action": "sniff"},
		map[string]any{"protocol": "dns", "action": "hijack-dns"},
	}
	routeRules = append(routeRules, rules...)
	route := map[string]any{"rules": routeRules, "auto_detect_interface": true}
	if len(ruleSets) > 0 {
		route["rule_set"] = ruleSets
	}
	if final != "" {
		route["final"] = final
	} else if len(groups) > 0 {
		if first := sbMap(groups[0]); first != nil {
			route["final"] = sbStr(first["name"])
		}
	}
	out["route"] = route
	return out, w.list, nil
}
