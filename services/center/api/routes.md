# rapp-center routes

## GET /v1/routes

200 `{"routes":[{"name":"state","kind":"builtin","v":1},{"name":"prefs","kind":"builtin","v":1}]}`

- `name`: the prefix. A builtin answers under `/<name>/v1/…`; `state` also answers at the root
  (`/v1/…`, `api/http.md`). `prefs` is the shared quick-area settings (`api/prefs.md`).
- `kind`: `builtin`, a part of `rapp-center` itself (the only kind for now).
- `v`: the version of that builtin's API.

Another method: 405 `{"error":"method not allowed"}`.

## Paths

In this order, the first that matches:

| Path | Goes to |
|---|---|
| `/v1/health`, `/v1/routes`, `/v1/watch` | the entry itself; GET only |
| any other `/v1/…` | the `state` builtin, as it is |
| `/<name>/v1/…`, `<name>` a listed builtin | that builtin, as `/v1/…` |
| anything else | 404 `{"error":"not found"}` |

The prefix is the first path segment, compared as it is: case matters and paths are not
normalised (`/STATE/v1/state` and `//v1/state` are 404). A builtin answers 404 to what it does
not know, the entry's paths included (`/state/v1/watch` is 404).

A prefix is lowercase letters, digits and `-`, and never `v1`.

## Adding a builtin

A new module under `src/`, one line in `builtin::table`, and its API in `api/`.
