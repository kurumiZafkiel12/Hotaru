# Configuration import

`ClashSubscriptionImporter` prepares provider declarations, resolves their payloads through an application-owned callback, expands group membership, then delegates protocol/rule conversion to `ClashProfileImporter`. Parsing and expansion run in isolates. No kernel or filesystem operation is performed by the importer.

The resolver receives the original URL, headers, requested outbound, relative file/cache path, refresh interval, timeout and byte limit. It must authorize file access, honor the requested route, and cancel/close its transport on timeout. An importer timeout stops scheduling additional providers; it cannot cancel a callback's underlying I/O. Automatic scheduling and persistent caching belong to the subscription owner, not this parser.

Supported provider inputs are HTTP, explicitly resolved relative files, and inline payloads. Remote/file payloads must contain only a `proxies` list. Empty/ambiguous providers and unconverted settings produce structured issues; resolution failure returns no partial profile. Provider health checks and moved cache paths are reported as conversion warnings. Consumers must present warnings and validate the resulting IR with the target builder before applying it.

Limits are 64 providers, 16 MiB per input/payload, 32 MiB of resolved payloads, 100,000 nodes and 250,000 expanded membership references. The callback must enforce its payload byte limit while reading; the importer rechecks returned data before parsing. An immutable plan exposes refresh metadata without granting filesystem or routing authority.

## DNS conversion subset

Enabled Clash DNS can specify one upstream (UDP, TCP, TLS or HTTPS), one optional bootstrap resolver and one optional resolver for proxy hostnames. Hostname-based DNS endpoints require explicit bootstrap. `system` selects sing-box's local resolver. Endpoint fragments can name a validated outbound; recursive DNS/outbound dependencies are rejected before applying a profile. DNS queries with URL options, parallel upstream lists, fallback policies, fake-IP, DNS rule policies and forced HTTP/3 remain conversion errors. Disabled DNS is not applied and unused settings are reported.

Hosts and system-hosts behavior is not yet migrated and is reported as a warning when enabled (including Clash defaults); consumers must show this before application. Imported listener addresses never grant binding authority. `CoreListenerSpec.dnsPort` creates an optional loopback UDP/TCP DNS inbound, while `CoreTunSpec.hijackDns` explicitly enables port-53 interception on the owned TUN only. Both require a DNS specification and neither changes OS DNS settings. TUN interception defaults off. DNS configuration changes require rebuilding the owned session.

Tests validate generated JSON against pinned sing-box 1.14.4 and use independent loopback UDP/TCP upstream receipts to verify resolution, caching and the IPv6 query policy. TCP connection-reuse probes are counted separately from additional business queries. The opt-in Windows native test also verifies an IPv4 UDP DNS question through the real Helper-owned TUN against an independent upstream receipt and response address, followed by lifecycle and network-baseline cleanup checks. TLS/HTTPS wire behavior, full default-route takeover and IPv6 TUN DNS are not yet acceptance-tested.

## Rule-provider conversion subset

`ClashSubscriptionImporter.resolveRules` supplies an independent application-owned resolver for HTTP and authorized relative-file rule providers. Inline providers require no I/O. YAML payload lists and plain-text lists support `domain`, `ipcidr`, and DOMAIN/DOMAIN-SUFFIX/DOMAIN-KEYWORD/IP-CIDR/IP-CIDR6 classical entries. IP entries require `no-resolve` at the RULE-SET reference or the classical entry. Exact domains stay exact; `+.example.com` includes the apex and its subdomains. Other wildcard and suffix-only forms, MRS, GeoIP/logical entries, nested actions, unknown modifiers and unsupported settings fail conversion. They are not silently flattened into approximate routes.

Expansion retains profile order, target/reject actions and MATCH boundaries, including empty sets. Any resolution or member error yields no replacement profile. Limits are 64 declarations, 16 MiB per remote payload, 32 MiB for aggregate remote payloads and the input document, and 250,000 stored/expanded rule entries. Payload parsing and expansion are isolated from the UI. Resolver timeout stops new scheduling; callbacks must enforce byte limits while reading, authorize files, honor requested routing and cancel their own I/O. Refresh intervals are metadata; scheduling and persistent cache integration remain unfinished.

## IP matching and DNS semantics

IP-CIDR/IP-CIDR6 rules and `ipcidr`/classical sets support explicit `no-resolve`. The owned IR records this flag; builder validation rejects implicit resolving IP rules and rejects this flag on other rule kinds. A domain skips these IP rules and continues to later rules; a literal IPv4/IPv6 destination is matched against its prefix. Offline preview applies the same distinction without sending DNS requests. An IP-only set requires the reference flag even when empty, because the source engine can otherwise attempt resolution for an empty set.

Implicit resolution is not converted yet. Mihomo attempts one address and continues routing after DNS failure, whereas an explicit sing-box resolve action can match multiple answers and terminates the request on lookup failure. Generating only `ip_cidr`, or inserting an unconditional resolve action, would silently change behavior; such imports now report `ip_rule_resolution_not_migrated`. Even direct IR callers must declare `noResolve` for IP rules. Prefix syntax and family bounds are checked consistently during import, generation and preview; scoped/mapped IPv6 prefixes and ambiguous prefix forms are rejected pending established cross-engine semantics. This is a compatibility correction to the initial prototype, which accepted unqualified IP rules without implementing their DNS behavior.

## Preparation and conversion review

`SingBoxConfigPreparer` takes an application-owned import callback and immutable listener settings. Import errors, builder validation and complete bootstrap-envelope size checks finish before any Helper session is created. Heavy issue processing, JSON generation and encoding run in data-only isolates; importer callbacks and their native resources stay with the caller. Results distinguish a reviewable candidate, an invalid configuration and a superseded preparation. New preparations/cancel invalidate older reviews without mutating an already accepted running snapshot; cancellation does not cancel the callback's own I/O.

A candidate exposes structured conversion warnings and the encoded size for presentation. If it has warnings, the UI must obtain an acknowledgment from its explicit confirmation action and pass that candidate-bound token to `approve`. A token from another candidate is rejected even when warning counts or codes are the same. The privileged Helper composition accepts only `AcceptedSingBoxConfig`; its pipe consumes the already prepared, immutable bootstrap. PID/session/peer checks still run before credentials are transmitted.

The 16 MiB limit covers UTF-8 JSON plus the protocol envelope, excluding the transport's length prefix. Chunked encoding stops at the limit rather than first allocating arbitrarily large repeated JSON. Rule-set expansion has a separate 16 MiB text budget before joining repeated targets, in addition to its rule-count bounds. The preparation result contains no raw exception text or configuration dump.

Preparation/approval does not apply, reload, stop or replace a running session. It does not establish complete upstream engine validation, port availability or successful startup. Callers must not stop the existing core merely to prepare a replacement. Ordinary GUI application and its localized review screen remain to be integrated.


## Runtime activation and recovery

The Windows Helper composition accepts a reviewed configuration through `SingBoxDesktopCore.applyConfiguration`. Its launch plan binds bootstrap, pipe, listeners and controller credentials together. The existing `DesktopCoreLifecycle` serializes replacement with start/stop/restart/close, confirms the old lease has exited, and commits a plan only after the new process and its controller have passed ownership checks. Session-scoped API clients are recreated with the active plan's endpoint and secret.

If activation fails while replacing a running configuration, the same owner attempts to restore the last committed plan after confirming failed-process cleanup. A successful recovery leaves the core running and rejects the apply request with `configuration_rejected_previous_restored`; the rejected configuration is not committed. A failed or unconfirmed cleanup blocks recovery instead of starting a second core. Recovery failure leaves an explicit failed state and permits an explicit retry. Replacement cuts existing connections; this is a controlled restart, not seamless hot reload.

Stop/close preempt activation and recovery. A later explicit start/restart uses the last committed plan and supersedes a pending replacement; a newer apply uses its new plan. Requests for the same plan may coalesce, but different plans do not. Superseded late processes are cleaned without publishing a running session. Applying from idle starts the requested plan, but a failure does not unexpectedly start a previously stopped plan. No GUI or provider owns a separate recovery loop.

## Previewing the committed session

An accepted configuration retains the immutable IR that produced its bootstrap. Candidate summaries expose node/rule counts without decoding the compiled JSON. `SingBoxDesktopCore.previewRoute` uses that committed IR and the running session's actual selector values, rather than pending UI settings or subscription defaults. It rejects results when the session/configuration changes; relevant selectors are read again before returning so a changed selection cannot be presented as current.

Preview evaluates domain/literal rules in an isolate and only reads the local controller. It does not resolve or connect to the target, start a stopped core, or change a selector. A missing running profile, incomplete selection or unsupported rule remains explicit. This query is ready for the Windows facade; the ordinary GUI entry is not wired yet.

## Node detours

Clash `dialer-proxy` is retained as a node detour and generated as sing-box `detour`. References and cycles are checked across nodes and selectors together. Empty direct outbound detours are rejected before startup, as the pinned engine rejects them too. DNS dependency checks distinguish explicit client resolution from hostname forwarding through a detour; a remotely resolved server must not invent a local resolver cycle.

Preview keeps policy selection order in `chain`, exposes entry-to-exit node order in `hops`, and records all used selections, including detour groups, for session verification. Controlled tests require independent CONNECT receipts at the relay and exit plus the origin payload, through both the pinned CLI and Hotaru's embedded host. The upstream connection API omits the relay in this tested case: its raw `chains` is not by itself a complete physical path. In particular, historical selections of a detour group cannot be reconstructed from its current selection and must not be presented as observed connection history.

## HTTP through a specified outbound

An optional authenticated HTTP listener binds only to loopback. The compiler generates a username per known node/group and inbound-scoped `auth_user` routes before subscription rules, followed by a reject rule for unmatched probe traffic. Its port must be distinct from the mixed, controller and DNS listeners. A per-configuration random secret is required; it travels inside the existing private bootstrap, not command arguments. No second engine or mutable global selector is used.

`CoreOutboundHttp.withOutboundClient` scopes a Dart HTTP client to that listener and one outbound. The callback must finish consuming its responses before returning and must not replace the client's proxy configuration or retain the client. Completion, exceptions, timeout and session invalidation close the client; stale results are rejected. Unknown nodes and absent capabilities fail without falling back to a direct route. Credentials are registered for the exact loopback proxy before requests because the pinned engine's 407 challenge is not accepted by Dart's authentication parser. Normal origin TLS checks remain enabled. Windows verifies both controller and probe listener ownership before authenticating the session.

The wire test uses simultaneous HTTP and HTTPS requests, two independent CONNECT proxies, origin bodies, unchanged selector state and rejected unauthenticated traffic. The embedded host must acknowledge clean shutdown. A disposable Windows Helper test also queries through the restored configuration's probe listener after failed activation. These checks establish transport capability, not completion of ordinary GUI node speed/IP probe integration.

## Outbound modes

Generated configurations explicitly implement rule/global/direct routing with `clash_mode` rules. Changing the controller's mode alone does not change sing-box routes. A generated global selector defaults to the profile's final outbound and includes its existing nodes/groups; a dedicated direct outbound bypasses profile rules. Generated names use deterministic collision-free suffixes and never rename subscription nodes. DNS hijack and authenticated per-node probe rules precede mode overrides. The controller starts in rule mode; preserving a user-selected mode across apply/restart belongs to the application facade.

`CoreRoutingModes` reads the actual mode and patches it with verified readback. Session adapters reject acknowledgements from replaced processes. Preview reads the mode with the same committed profile/session as its selector snapshot and rechecks it before returning; global/direct previews bypass profile rules. The real-engine test requires separate A/B proxy receipts, direct origin access with no proxy receipts, and a pinned A probe even while direct mode is active. These checks do not claim the ordinary UI facade is already cut over.
