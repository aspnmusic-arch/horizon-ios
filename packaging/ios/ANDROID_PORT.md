# Android 0.7.7 → iOS port status

This document compares the attached `horizon-android-0.7.7.zip` with iOS commit
`94b6223a3422d9f2e5df3cc6076f3dcfbe9dffbe`. The Android archive's SHA-256 is
`a34a198ee1660ae54320080181e3c45e5da73b6f5b3ebde57e294057be870336`. Its
`LICENSE` is MIT, copyright 2026 Ludovic Marie and the Horizon contributors; the
fork identifies itself as [horizon-android](https://github.com/Vasysik/horizon-android).
The archive describes a 0.7.7 development candidate, not universal device support.

The projects share Horizon's engine but are different revisions and have different
mobile launch and input implementations. Android's Java/JNI, Vulkan/GLES and
Keystore code is not an iOS implementation. These are engineering statuses, not
a claim of device verification.

| Area | iOS state in this branch | Remaining work |
| --- | --- | --- |
| Play, worlds, servers | Existing iOS bridge is reachable from the launcher. World creation, opening, renaming, deletion and backup, plus saved/direct servers, use the engine. ZIP world import uses the Files picker and the existing checked importer. | Run the complete flows on a device, including online sessions and world transfer. |
| Game settings | Video, sound and basic controls use the engine's option descriptions and confirmed writes. | Android-specific render scale, display and resource-budget choices still need iOS engine support. |
| Packs | Existing Modrinth resource/shader search uses a SHA-512 and length check before installation and refuses to overwrite an existing file. | Test downloads and compatibility on-device. Android's full catalog and native `.hmod` management are not ported. |
| Game files | iOS retains its prepared-archive download and import paths. | Port Android's direct Mojang installer and generated engine data, validating hashes, recovery, storage and licensing. It is not implemented by these changes. |
| Touch | Existing iOS D-pad, tap/hold and system keyboard remain. | Port Android's four schemes, gesture aiming, layout editor, button settings, and contextual actions into the different iOS input pipeline. |
| Accounts | Existing iOS Microsoft account and Keychain integration remain. | Validate a project-owned app registration, ownership and server login end to end. |
| Audio/controllers | iOS has CoreAudio and GameController integrations. | Verify equivalent sound, haptics, controller and lifecycle behavior on real hardware. |
| Profiles, diagnostics, import/export | World ZIP import and engine backup are available; existing iOS Files access remains. | Per-profile isolation, full content import/export, logs and diagnostics still need adaptation. |
| Mods | iOS does not enable Android's 64-bit Wasmtime runtime or bundled mods. | Investigate an iOS-compatible execution model and port supported content without promising JIT support. |

## Verification

On macOS with Xcode 26, XcodeGen and Rust installed, generate the project and run
`LauncherPreview` tests on an iOS simulator (see `Preview/README.md`). Build the
`Horizon game` scheme for an iPhone or iPad, then test installation, launcher,
world import, settings, verified pack downloads, online sign-in, controls,
audio and suspend/resume on a real device. Keep game data and test homes separate
from actual player data. No IPA or device result is implied by a source change.
