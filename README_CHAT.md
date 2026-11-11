# LocalSend Chat — Windows

This is an unofficial Windows chat fork of [LocalSend](https://github.com/localsend/localsend), distributed under Apache 2.0 with the original copyright notices retained.

## Use

Download either the EXE per-user installer or the ZIP portable application from [Releases](https://github.com/rick-li-1299/LocalSend-Chat/releases/latest). Keep the entire application directory together.

Double-click your own name in the chat list to rename this device. Enter or clicking outside saves; Esc cancels. Empty names are rejected. Restart to apply the name to LAN discovery.

Chat supports device conversations, shared groups, text and file transfers, history search, local nicknames, pinning, and opt-in trusted reception. There is no cloud chat account, offline delivery, or history synchronization. Local settings and history are ordinary local data, not encrypted at rest. Clearing history does not delete received files. Retry starts a new transfer.

## Updates and data

The app checks this repository's latest stable Release at launch and every six hours. The update icon also checks manually. Click **Update now** to download the expected Windows ZIP, verify GitHub's SHA-256 digest and restart. Active transfers, web sharing and unsent drafts must finish first. Offline automatic checks fail quietly.

The update helper validates and stages application files before exit, keeps a backup of replaced files and attempts rollback on failure. It preserves portable `settings.json`, installed APPDATA settings and received files. Backups are adjacent `.chat-update-backup-*` directories; logs remain in temporary `localsend-chat-update-*` directories. Use a user-writable application directory.

The first upgrade from a version without the updater is manual: close the old app, replace application files, and preserve its existing `settings.json` instead of the empty template in a new ZIP. Installed versions use `%APPDATA%\LocalSendChat\settings.json`; portable versions use `settings.json` next to the executable.

## Build

Use Flutter 3.41.9 / Dart 3.11.5 (see `.fvmrc`), Rust 1.97.1 (see `rust-toolchain.toml`), Visual Studio Desktop development with C++, Windows SDK and Inno Setup 6. Shared Dart packages and the Rust protocol/plugin source are required dependencies.

From `app/`: `flutter pub get --enforce-lockfile`, `flutter analyze`, `flutter test --concurrency=2`, then `flutter build windows --release --no-pub`. Resolve Cargokit tool dependencies in `packages/localsend_isolates/rust_builder/cargokit/build_tool` with `flutter pub get` before building.

Test the update helper with `python support/scripts/test_chat_update.py`. Package the built `app/build/windows/x64/runner/Release` using `support/scripts/compile_windows_chat.iss`, with `PayloadDir` and `ResultDir`. Installed builds deliberately do not copy portable settings.

## Publish

The sole Windows workflow analyzes, tests, builds and packages the application. Increase `chatVersion` in `app/lib/util/chat_updater.dart`, then push the matching `chat-vX.Y.Z` tag. Alternatively, run the workflow on `main` with `publish_release` enabled. It publishes one unsigned ZIP, one unsigned EXE installer, checksums and a source-build manifest after checks pass. Chat versions are independent of the upstream application version.

Only the final Windows application and required source are maintained. Other application platform runners, CLI/signaling-server projects, old release workflows and one-time source-import files are excluded from the current source tree. Existing historical Git commits remain normal version history; no old local application ZIPs or toolchain caches were uploaded.

See [validation notes](CHAT_VALIDATION.md) for the scope of checks. A cloud build is not proof of physical two-device LAN testing.
