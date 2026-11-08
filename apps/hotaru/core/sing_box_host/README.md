# Desktop sing-box host

This client-side host embeds the pinned upstream sing-box v1.14.4 module. It exposes the upstream clash_api and adds owned-parent lifecycle control over standard input/output. It does not patch protocol implementations.

Build from `apps/hotaru`:

```sh
go -C core/sing_box_host build -tags with_clash_api,with_quic,with_utls -o /tmp/hotaru-box-host .
go -C core/sing_box_host test -tags with_clash_api,with_quic,with_utls ./...
```

`run -c <compiled.json> --stdio-control` emits `hotaru-stdio-v1` JSON events. `ready` follows successful engine startup. The parent sends `stop\n` or closes stdin; the host calls the upstream engine's `Close` and emits `stopped` with `clean: true` only when that cleanup succeeds. A process exit alone is not a cleanup acknowledgement. The controller remains authenticated loopback HTTP; stdin is exclusively owned by the launching process.

`check -c <compiled.json>` validates through the upstream engine without starting it. `version` derives its version from Go build metadata and rejects replaced or mismatched upstream modules.

On Windows, the existing Helper can launch the host with its fixed `\\.\pipe\HotaruCore_<32 lowercase hex>` argument. The client verifies the pipe peer PID before sending an in-memory `hotaru-bootstrap-v1` configuration. Frames use the existing Rust transport's four-byte little-endian length header, capped at 16 MiB by this host. Subsequent frames carry the same host events and `stop\n` control. The pipe client requests identification-only security quality of service so the server cannot impersonate a privileged host. A ten-second bootstrap deadline prevents an unconfigured process from waiting indefinitely.

Windows TUN and privileged helper packaging are still under development. This component is not yet selected by the normal application UI. Redistribution must retain the upstream sing-box license and source obligations alongside Hotaru's license.

From `apps/hotaru` on Windows x64, `pwsh -File tool/build_sing_box_bundle.ps1 -Destination <new-directory>` builds a pinned release host, a release Helper bound to its exact SHA-256, and the engine/version/protocol manifest. Licenses and source links accompany the bundle. An existing destination is refused, and failed builds leave it untouched. This is a core/Helper development bundle; it does not build an application installer or change the normal UI backend.

## Read-only observations

After `ready`, the owned parent may send a newline-terminated `{"method":"telemetry","id":1}` control message. IDs are positive 32-bit integers and commands remain bounded to 512 bytes. The response is a `hotaru-stdio-v1` event named `telemetry`, carrying the host PID, `request_id`, and either typed `data` or an explicit error. Writers serialize complete response/event frames, and responses cannot exceed the existing 16 MiB frame limit. This channel never changes routes, resets counters, collects garbage or manages another process.

Snapshots expose upstream cumulative upload/download totals, up to 1000 active records with an explicit truncation flag, and the upstream closed-connection window (capacity 1000). That window can also be cleared by upstream garbage collection; it is not a complete traffic history. Cumulative totals retain evicted/cleared traffic. Process IDs and unmodified executable paths remain empty/zero when upstream did not resolve them. Paths do not append account names. Raw chains preserve upstream observations and do not invent missing detour hops.

The Dart pipe processes JSON/typed records in an isolate. Concurrent replies are matched to the verified PID and request ID; replacement/stop cancels pending reads. EOF is committed only after queued frame deliveries and decoding finish, so data after `stopped` cannot preserve a clean acknowledgement. The Helper remains the sole process owner. Application ranking, per-profile persistence, connection-path presentation and the ordinary GUI facade still require integration.

A clean `stopped` event can additionally include `totals: {"upload": ..., "download": ...}` captured after engine cleanup. These final absolute counters retain the bytes since the last periodic snapshot. Failed cleanup omits final totals. The application binds profile identity to the owned lease; profile IDs are not sent to the engine. Clients must wait for validated stopped output and drained EOF before persisting a final observation.
