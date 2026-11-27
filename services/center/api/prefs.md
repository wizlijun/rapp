# rapp-center prefs API

The quick-area settings every app shares (spec `2026-11-27-rapp-quick-row-design.md` §10.2).
JSON over HTTP/1.1 under the `/prefs` prefix; listed in `GET /v1/routes` as
`{"name":"prefs","kind":"builtin","v":1}`. An app that does not find it there (or gets 404 for
`/v1/routes`) does not sync. Errors: `{"error": "..."}`.

Four **documents**, each `{"at": <u64>, "data": <any JSON>}`:

| Name | data |
|---|---|
| `phrases` | the phrases and commands |
| `keys` | the key actions |
| `layout` | `{"rows": …}` |
| `stars` | starred item ids, in starring order |

`at` is the writer's own time in milliseconds; the service stores it and compares it with `base`
only, never with its own clock. The service does not look inside `data` (apps check it and treat a
bad one as missing). A missing document reads as `{"at":0,"data":null}`.

**Usage** is per device: each device replaces only its own `{"at", "data"}`.

## GET /prefs/v1/all

200 `{"store":"<16 lowercase hex>","phrases":{at,data},"keys":…,"layout":…,"stars":…,"usage":{"<device>":{at,data},…}}`.
A document that is not there is left out; `usage` is left out when no device has any. A first
fetch on an empty service is just `{"store":"…"}`.

`store` is the service's identity, made at random the first time and kept in `prefs.json`. Without
a data directory it is new on every start (apps then treat it as a service they have never met).

## GET /prefs/v1/<name>

200 `{"at":…,"data":…}`, or `{"at":0,"data":null}` when it is not there. `<name>` is one of the
four; anything else is 404.

## PUT /prefs/v1/<name>

Body `{"at": <u64>, "base": <u64>, "data": <any>}`; other fields are ignored. `base` is the `at`
the writer believes the service has (0 for none).

- 204: the stored `at` (0 when there is none) equals `base`; `{at, data}` is now stored.
- 409 with the stored document (`{"at":0,"data":null}` when there is none): `base` is stale.
  Nothing changes.
- 400 `{"error":"bad request"}`: not a JSON object, `at` or `base` missing or not a
  non-negative integer, or no `data`.
- 413 `{"error":"too large"}`: `data` is over 256 KiB serialized (or the body over 256 KiB + 4 KiB).
- 404 `{"error":"not found"}`: not one of the four names.

## PUT /prefs/v1/usage/<device>

Body `{"at": <u64>, "data": <any>}`. Replaces that device's usage whole, always (whatever its
`at`), and records when the service received it. `<device>` is not empty, has no `/` and is at
most 128 characters.

- 204: stored.
- 400 `{"error":"bad request"}`: a bad `<device>`, or a body as above without `at` or `data`.
- 413 `{"error":"too large"}`: as above.

A device's usage not received again for 90 days (by the service's clock) is dropped. Documents
never expire.

## Methods

`all` and the names answer GET; the names and `usage/<device>` answer PUT. Another method on a
known path: 405 `{"error":"method not allowed"}`. `/prefs/v1/usage` itself is 404.

## GET /v1/watch

The entry's one watch (`api/http.md`) also carries, after each accepted PUT:

```
data: {"what":"prefs.<name>","doc":{"at":…,"data":…}}
data: {"what":"prefs.usage","device":"<device>","doc":{"at":…,"data":…}}
```

A refused PUT (409, 400, 413) and expired usage push nothing. Apps that do not know a `what`
ignore it. After a disconnect, fetch `GET /prefs/v1/all` again.

## On disk

With a data directory: `prefs.json` there (0600, written about a second after a change, via
`prefs.json.tmp`), `{"store":…,"docs":{"<name>":{at,data}},"usage":{"<device>":{"at","data","put_at"}}}`
with `put_at` the receive time in Unix seconds. A file that cannot be read or parsed is moved to
`prefs.json.bad` and `prefs` starts empty with a new `store` (log `load_failed`); the other
builtins' files are not touched. Without a data directory nothing is written.

Samples: `api/samples/prefs.ndjson` (a `GET /prefs/v1/all` reply, then two watch pushes).
