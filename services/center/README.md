# rapp-center（中心服务）

Headless state-queue service. Listens on 127.0.0.1 only (default port 8102), no auth.

    cargo run -p rapp-center -- --data ./data

Options: `--port N`, `--data DIR` (omit for memory only), `--keep-days N` (default 7), `--keep-events N` (default 1000).

The HTTP API is described in `api/http.md`.

## On disk

With `--data DIR` the store lives in `DIR/state.json` (file 0600, directory 0700, created on first save). It is loaded at start, then re-limited to this run's `--keep-days` / `--keep-events` and expired. After a change it is saved at most once a second (written to `state.json.tmp`, then renamed). A file that cannot be read or parsed is moved to `state.json.bad` and the service starts empty (log `load_failed` with the error kind only). Save errors are logged as `save_failed` and do not stop the service. Without `--data` nothing is created or written.
