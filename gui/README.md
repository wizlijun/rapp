# rapp (Flutter GUI)

Client manager (`rapp`) and connection manager (`rapp --cm`), spec §4.

- Finds `rapp-hub` / `rapp-service` in `RAPP_BIN_DIR`, else next to the executable (`rapp.app/Contents/MacOS/`).
- Config dir follows §3 (`RAPP_HOME` overrides).
- `~/development/flutter/bin/flutter test`, `flutter analyze`, `flutter build macos --release`.
