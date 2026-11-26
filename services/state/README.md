# rapp-state

Headless state-queue service. Listens on 127.0.0.1 only (default port 8102), no auth.

    cargo run -p rapp-state -- --data ./data

Options: `--port N`, `--data DIR` (omit for memory only), `--keep-days N` (default 7), `--keep-events N` (default 1000).

The HTTP API is described in `api/http.md`.
