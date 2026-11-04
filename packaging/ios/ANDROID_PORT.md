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
| Touch | The native editor moves, resizes, hides and adjusts the opacity of touch buttons. Optional attack, use, sprint and drop buttons use the game's existing input actions. | Validate on physical devices; joystick schemes, arbitrary key bindings, multi-key macros and import/export of layouts are not implemented. |
| Accounts | Microsoft/Xbox device sign-in, Java ownership/profile and in-memory game session handover; the app verifies the handover before Play. The launcher can accept the owner's public app ID when no build-time ID is configured. | A project-owned app registration with Minecraft Services access and real-account/device validation are required. |
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

## Account setup

The Microsoft account flow is implemented in `Launcher/MicrosoftAccount.swift` and keeps refresh
and Minecraft tokens in iOS Keychain. The app accepts a Microsoft account which owns Java Edition;
its verified profile is used for online-mode servers. It does not automatically copy local worlds
or promise Minecraft Realms support.

The app owner must provide their own public Microsoft application (client) ID, enable consumer
accounts and public client/device-code flow, and arrange any required Minecraft Services access.
A Microsoft sign-in alone does not guarantee the Minecraft service will approve an app ID. See
[Microsoft's device authorization documentation](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
and `docs/microsoft-account.md`. Never use another launcher's application ID, and do not place
passwords or refresh tokens in repository variables or the app bundle.

For CI, set the GitHub Actions repository variable `HORIZON_MSA_CLIENT_ID` before running the iOS
workflow. For an already installed build without a bundled ID, open the launcher account panel,
expand **Developer setup**, and enter the project's own approved public ID. This does not register
or approve the app; it only configures the existing sign-in flow. Finish signing in via Microsoft
and verify a real account on a device before claiming online access works.

## Editing touch controls

Open **Settings → Customize touch controls**. Drag a button in the landscape preview; select a
button to resize it or switch it on/off. The opacity slider applies to the game's touch overlay.
Attack, use, sprint and drop are optional and start hidden. **Reset to defaults** changes the
draft; **Save** validates and writes the layout in the app's Documents folder. The hotbar stays
aligned with the game UI. Cancelling navigation leaves the previously saved layout in place.

The controls are a new Horizon implementation informed by the attached PojavLauncher iOS README's
description of customizable on-screen controls. PojavLauncher's archive is GPL-3.0; its source
code was not copied or used to implement this feature.
