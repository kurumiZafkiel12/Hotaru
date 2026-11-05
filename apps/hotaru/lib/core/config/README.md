# Configuration import

`ClashSubscriptionImporter` prepares provider declarations, resolves their payloads through an application-owned callback, expands group membership, then delegates protocol/rule conversion to `ClashProfileImporter`. Parsing and expansion run in isolates. No kernel or filesystem operation is performed by the importer.

The resolver receives the original URL, headers, requested outbound, relative file/cache path, refresh interval, timeout and byte limit. It must authorize file access, honor the requested route, and cancel/close its transport on timeout. An importer timeout stops scheduling additional providers; it cannot cancel a callback's underlying I/O. Automatic scheduling and persistent caching belong to the subscription owner, not this parser.

Supported provider inputs are HTTP, explicitly resolved relative files, and inline payloads. Remote/file payloads must contain only a `proxies` list. Empty/ambiguous providers and unconverted settings produce structured issues; resolution failure returns no partial profile. Provider health checks and moved cache paths are reported as conversion warnings. Consumers must present warnings and validate the resulting IR with the target builder before applying it.

Limits are 64 providers, 16 MiB per input/payload, 32 MiB of resolved payloads, 100,000 nodes and 250,000 expanded membership references. The callback must enforce its payload byte limit while reading; the importer rechecks returned data before parsing. An immutable plan exposes refresh metadata without granting filesystem or routing authority.
