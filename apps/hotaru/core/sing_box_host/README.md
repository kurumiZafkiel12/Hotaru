# Desktop sing-box host

This client-side host embeds the pinned upstream sing-box v1.14.4 module. It exposes the upstream clash_api and adds owned-parent lifecycle control over standard input/output. It does not patch protocol implementations.

Build from `apps/hotaru`:

```sh
go -C core/sing_box_host build -tags with_clash_api,with_quic,with_utls -o /tmp/hotaru-box-host .
go -C core/sing_box_host test -tags with_clash_api,with_quic,with_utls ./...
```

`run -c <compiled.json> --stdio-control` emits `hotaru-stdio-v1` JSON events. `ready` follows successful engine startup. The parent sends `stop\n` or closes stdin; the host calls the upstream engine's `Close` and emits `stopped` with `clean: true` only when that cleanup succeeds. A process exit alone is not a cleanup acknowledgement. The controller remains authenticated loopback HTTP; stdin is exclusively owned by the launching process.

`check -c <compiled.json>` validates through the upstream engine without starting it. `version` derives its version from Go build metadata and rejects replaced or mismatched upstream modules.

Windows TUN and privileged helper packaging are still under development. This component is not yet selected by the normal application UI. Redistribution must retain the upstream sing-box license and source obligations alongside Hotaru's license.
