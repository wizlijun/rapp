# rapp (Flutter GUI)

Client manager (`rapp`) and connection manager (`rapp --cm`), spec §4.

- Finds `rapp-hub` / `rapp-service` in `RAPP_BIN_DIR`, else next to the executable (`rapp.app/Contents/MacOS/`).
- Config dir follows §3 (`RAPP_HOME` overrides).
- `~/development/flutter/bin/flutter test`, `flutter analyze`, `flutter build macos --release`.

On Linux, the session bus owns one GUI process. Reopening `rapp` presents its
main window, including when hidden in the tray. `--cm` uses one separate window
in that same process; closing it leaves the main window and hub running.
`rapp-service` also claims a per-user Linux abstract socket before touching data,
independent of bundle location, `RAPP_HOME`, or configured ports. The kernel
releases ownership on exit, including crashes.

Regression checks from the repository root:

- `python3 scripts/test-linux-single-service.py [path/to/rapp-service]`
- `python3 scripts/test-linux-single-gui.py [path/to/rapp-gui]` (Omarchy/Hyprland 0.56+; temporarily opens isolated test windows)
