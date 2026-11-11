# LocalSend Chat MVP

An experimental, unofficial chat-style desktop fork of [LocalSend](https://github.com/localsend/localsend). It is not an official LocalSend release. Original copyright notices and the Apache 2.0 license are retained.

## Scope

Double-click your device name below **Chats** to rename it directly. Press Enter or click outside to save, or Esc to cancel. Empty names are rejected. The saved name appears immediately in the workspace; restart the app to apply it to LAN discovery, as with the existing network setting.

Windows 10/11 x64 is the intended delivery platform; Linux is used for cloud build and test verification. The desktop workspace adds per-device conversations, text, file/folder staging and drag-and-drop, transfer status, manual retry, local history, local device nicknames, pinning, and explicit trusted-device auto-receive. The original LocalSend discovery and encrypted transfer implementation remain in use.

This is a local-network transfer interface, not a cloud messenger. There are no accounts, offline delivery, read receipts, history synchronization, or byte-offset resume. Retry starts a new transfer and requires the peer to be discovered and the source files to still exist. An unmodified official client keeps its original UI and may still ask for confirmation.

On Windows, use the new-group button next to chat search to invite two or more devices running the group-chat build with encrypted transfer enabled. Each recipient accepts the invitation once. Group members can then send text and files to each other over the LAN. Click the delivery count to see individual results and retry delivery to available members running the advanced build. Keep the original files for retries. Attachments with a local source can be forwarded from their context menu to a nearby device or an existing group.

Each group supports up to 32 devices. The owner can appoint administrators, add or remove members, and publish an announcement. An administrator can change ordinary membership and the announcement while the owner is reachable. The owner distributes group updates when other devices are discovered. The owner can use **Sync group settings** to enter a recipient's receive PIN if automatic sync is blocked. Use the advanced build on every member's device before changing group settings. The reply button quotes a message, and the **@** button opens the member picker. Mute is a local preference that switches the unread counter to a quiet dot.

## Build requirements

Use the exact Flutter version in `.fvmrc` and Rust version in `rust-toolchain.toml`. The initial baseline is commit `58955fd54ef1e18e89ec30e60f46754084a80942`, Flutter 3.41.9, Dart 3.11.5, and Rust 1.97.1. Read `AGENTS.md` for repository architecture and commands.

Use CI mode in an automated cloud build (`CI=true`, `BOT=true`, `FLUTTER_SUPPRESS_ANALYTICS=true`, `DART_SUPPRESS_ANALYTICS=true`). This uses Flutter's supported headless mode and avoids its optional cloud-instance detection probe. Tool caches must point to a writable user directory.

From `app/`:

```sh
fvm flutter pub get --enforce-lockfile
fvm flutter analyze
fvm flutter test --concurrency=2
```

Resolve `flutter pub get` once inside `packages/localsend_isolates/rust_builder/cargokit/build_tool` as upstream CI does. Test the isolate package with `fvm flutter test --concurrency=2`. Test Rust core from `packages/core` with `cargo test --locked --features full`; the core does not build with an empty feature set.

### Windows

Use a Windows machine with Visual Studio's Desktop development with C++ workload, Windows SDK, the pinned Flutter/Rust toolchains, and Inno Setup 6. The fork's `.github/workflows/build_windows_chat.yml` runs on `windows-latest`, builds the real executable, and produces an **unsigned portable ZIP and unsigned EXE installer**, checksums, and a source-commit manifest. It does not publish a release or use the upstream Azure signing credentials.

Run the workflow in your own GitHub Fork on the development branch. Fork Actions may need to be enabled by the repository owner. Successful artifact creation must be checked on the exact commit; merely adding this workflow is not proof that a Windows build passed. Windows may warn about the unsigned application. Do not disable system security to run it.

For a local Windows build, run `fvm flutter build windows --release` from `app/`, then package `app/build/windows/x64/runner/Release` using `support/scripts/compile_windows_chat.iss` with `PayloadDir` and `ResultDir`. The executable remains `localsend_app.exe` inside the independent application directory.

The unsigned fork intentionally omits the official sparse MSIX helper and associated shell extension. The ordinary executable and its separately named Send To shortcut remain available.

#### GitHub Release updates (ZIP and per-user installer)

Chat 1.0.0 and later check `rick-li-1299/LocalSend-Chat` for a stable release at launch and every six hours. The update icon at the bottom left also checks manually. Choose **Update now** to download and verify the release ZIP, then restart automatically. Offline checks fail quietly and can be retried. Transfers, web sharing and unsent drafts must finish before updating.

The updater accepts only `chat-vX.Y.Z` releases and the expected Windows x64 ZIP from this repository, with the GitHub API's SHA-256 digest. It stages and validates application files before the app exits. It preserves portable `settings.json`, installed APPDATA settings, and user files. Existing application files are kept in an adjacent `.chat-update-backup-*` directory; failed replacement attempts restore these files. Diagnostic logs remain in the temporary `localsend-chat-update-*` directory. Install into a user-writable folder. Windows-managed MSIX installations use the separate channel below.

For the first upgrade from a build without this updater, close the old app and copy the new ZIP's application files into its folder while keeping the existing `settings.json`. Subsequent releases can update in the app. Do not replace settings with the empty template in a fresh ZIP.

To release an update, increase `chatVersion` in `app/lib/util/chat_updater.dart`, commit to `main`, then push the matching `chat-vX.Y.Z` tag. The Windows workflow analyzes, tests, builds, packages and publishes a GitHub Release automatically. It uploads the unsigned portable ZIP, unsigned per-user installer, checksums and source manifest. A release is available only after that workflow succeeds. Chat release versions are independent of the upstream LocalSend version.

#### Windows-managed MSIX updates (separate optional channel)

The portable ZIP and Inno installer are independent of the update channel. To create a Windows-managed channel for Windows 10 version 2004 or later, run `support/scripts/New-LocalSendChatUpdate.ps1` with the built x64 payload directory, an output directory, a four-part version, and the permanent HTTPS URL of the `.appinstaller` file. Pass the x64 Windows SDK bin directory, the thumbprint of the code-signing certificate in `CurrentUser\My`, and an HTTPS RFC 3161 timestamp URL. Windows must trust the signing certificate on the receiving computer.

Upload the versioned signed MSIX beside the feed URL first. Upload the generated `.appinstaller` file to its permanent URL last. Open that feed with Windows App Installer once for the initial installation. Windows checks at launch and also in the background. Keep the same feed URL and publisher identity and increase the package version each time. The signed package has its own package identity. Moving from a ZIP or Inno installation is a separate first install. Keep the previous profile until its settings and history have been verified or migrated.

For packaging checks without a certificate, `-UnsignedPreview` creates an unsigned MSIX and a feed template ending in `.preview.xml`. These preview outputs are for validation only.

### Linux verification

Install Clang/LLVM (including `lld` and `llvm-ar`), CMake, Ninja, GTK 3 development libraries, and Ayatana AppIndicator development libraries, then run `fvm flutter build linux --debug` from `app/`. The fork's Linux executable is `localsend_chat`.

On Debian 13, the pinned upstream tray plugin calls an API that newer AppIndicator headers mark deprecated. The cloud baseline used the generated build-directory CMake flag `-DCMAKE_CXX_FLAGS=-Wno-error=deprecated-declarations`, retaining the warning without changing upstream source. All other errors remain errors. Upstream's Ubuntu 22.04 build environment may not need this compatibility flag.

For a release build, run `fvm flutter build linux --release --no-pub` after resolving dependencies. On the Debian 13 setup above, set `CXXFLAGS=-Wno-error=deprecated-declarations` before the first release configuration. Keep the entire output bundle together. The provided Linux release bundle was built on Debian 13 and requires compatible GTK/AppIndicator and system libraries; it is not a Windows installer or a universally portable Linux package.

## Data and coexistence

- Windows installed data: `%APPDATA%\LocalSendChat\settings.json`, with its own installer ID, install directory, Send To shortcut, and auto-start entry. Official LocalSend settings and certificates are not imported automatically.
- Linux application ID and executable are separate from the official application to avoid its data directory and legacy filename fallback.
- Portable builds use their own adjacent `settings.json`. Extract into a new directory, never over an official installation.
- Local history stores text and file metadata/paths, not extra copies of large files. It is ordinary local app data, **not encrypted at rest**. Clearing a conversation does not delete transferred files.
- Pinning does not grant trust. Trusted auto-receive is opt-in and requires a matching verified TLS certificate identity. Revoking trust affects future requests; cancel an active transfer separately.
- The default LocalSend port remains 53317. Separate installations do not guarantee simultaneous listening on the same machine/port. Test interoperability on separate LAN devices, or explicitly configure compatible network settings.

## Validation status

See `CHAT_VALIDATION.md` for the exact passed, failed, skipped, and unexecuted checks. A successful cloud build is not proof of Windows execution, live GUI behavior, or physical two-device LAN interoperability.
