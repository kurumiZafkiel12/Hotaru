# Upstream sources and licenses

Hotaru 0.5 is a GPL-3.0 fork of FlClash 0.9.2 at 7fd417fb9a9a277c6a9339a8ac87f907df7c25f7, continued from Muse branch efba2a4310091f240441fa9189c5b86cc051a587. Existing upstream copyright and dependency notices are preserved.

Bettbox at 1fb8806fdf8275a3694cda31eec7ed2062330aee is also GPL-3.0 and itself derives from FlClash. lib/common/media_unlock_checker.dart and lib/models/media_unlock.dart are adapted from its corresponding source files. Hotaru removes app-global configuration coupling, reuses its own routing, and owns cancellation in the new view. The selected service UI is Hotaru-specific. See https://github.com/appshubcc/Bettbox and LICENSE.

Mihomo is the pinned core/Clash.Meta git submodule; wrapper source is core/. The release source archive includes the submodule files. Flutter dependencies retain their license texts, including bundled plugins; plugin-specific LICENSE files remain in their directories. No Bettbox branding assets or signing credentials are reused.

The Windows guardian is continued from Hotaru 0.4.1, with explicit snapshot restoration on normal stop and ProxyOverride restoration. It is independent of the UI process and bundled beside the application.
