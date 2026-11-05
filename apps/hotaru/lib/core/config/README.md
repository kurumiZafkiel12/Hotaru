# Configuration import

`ClashSubscriptionImporter` prepares provider declarations, resolves their payloads through an application-owned callback, expands group membership, then delegates protocol/rule conversion to `ClashProfileImporter`. Parsing and expansion run in isolates. No kernel or filesystem operation is performed by the importer.

The resolver receives the original URL, headers, requested outbound, relative file/cache path, refresh interval, timeout and byte limit. It must authorize file access, honor the requested route, and cancel/close its transport on timeout. An importer timeout stops scheduling additional providers; it cannot cancel a callback's underlying I/O. Automatic scheduling and persistent caching belong to the subscription owner, not this parser.

Supported provider inputs are HTTP, explicitly resolved relative files, and inline payloads. Remote/file payloads must contain only a `proxies` list. Empty/ambiguous providers and unconverted settings produce structured issues; resolution failure returns no partial profile. Provider health checks and moved cache paths are reported as conversion warnings. Consumers must present warnings and validate the resulting IR with the target builder before applying it.

Limits are 64 providers, 16 MiB per input/payload, 32 MiB of resolved payloads, 100,000 nodes and 250,000 expanded membership references. The callback must enforce its payload byte limit while reading; the importer rechecks returned data before parsing. An immutable plan exposes refresh metadata without granting filesystem or routing authority.

## DNS conversion subset

Enabled Clash DNS can specify one upstream (UDP, TCP, TLS or HTTPS), one optional bootstrap resolver and one optional resolver for proxy hostnames. Hostname-based DNS endpoints require explicit bootstrap. `system` selects sing-box's local resolver. Endpoint fragments can name a validated outbound; recursive DNS/outbound dependencies are rejected before applying a profile. DNS queries with URL options, parallel upstream lists, fallback policies, fake-IP, DNS rule policies and forced HTTP/3 remain conversion errors. Disabled DNS is not applied and unused settings are reported.

Hosts and system-hosts behavior is not yet migrated and is reported as a warning when enabled (including Clash defaults); consumers must show this before application. Imported listener addresses never grant binding authority. `CoreListenerSpec.dnsPort` creates an optional loopback UDP/TCP DNS inbound, while `CoreTunSpec.hijackDns` explicitly enables port-53 interception on the owned TUN only. Both require a DNS specification and neither changes OS DNS settings. TUN interception defaults off. DNS configuration changes require rebuilding the owned session.

Tests validate generated JSON against pinned sing-box 1.14.4 and use independent loopback UDP/TCP upstream receipts to verify resolution, caching and the IPv6 query policy. TCP connection-reuse probes are counted separately from additional business queries. TLS/HTTPS wire behavior and DNS interception through the real Windows TUN are not yet acceptance-tested.
