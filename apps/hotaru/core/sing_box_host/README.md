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
