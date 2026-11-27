# rapp-center（中心服务）

The center service: one port on each device for every builtin service rApp's devices share.
Listens on 127.0.0.1 only (default port 8102), no auth.

The entry answers `/v1/health`, `/v1/routes` and `/v1/watch` itself and hands every other path
to a builtin: `/<name>/v1/…` goes to builtin `<name>`. Today there is one, `state` (the state
queue: what each device's sessions are doing, the events queue and "needs you"); its old paths
at the root (`/v1/state`, `/v1/queue`, …) stay for good. Each builtin keeps its own file in the
data directory. Adding one: a module under `src/`, a line in `builtin::table`, its API in `api/`.

    cargo run -p rapp-center -- --data ./data

Options: `--port N`, `--data DIR` (omit for memory only), `--keep-days N` (default 7), `--keep-events N` (default 1000).

The HTTP API is described in `api/http.md` (state) and `api/routes.md` (the entry and its prefixes).

## On disk

With `--data DIR` each builtin has its own file there; the state queue lives in `DIR/state.json` (file 0600, directory 0700, created on first save). It is loaded at start, then re-limited to this run's `--keep-days` / `--keep-events` and expired. After a change it is saved at most once a second (written to `state.json.tmp`, then renamed). A file that cannot be read or parsed is moved to `state.json.bad` and the service starts empty (log `load_failed` with the error kind only). Save errors are logged as `save_failed` and do not stop the service. Without `--data` nothing is created or written.
