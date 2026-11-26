# rapp-state HTTP API

JSON over HTTP/1.1 on 127.0.0.1. Errors: `{"error": "..."}`.

## GET /v1/health

200 `{"name":"rapp-state","v":1}`

Unknown paths: 404 `{"error":"not found"}`.

## POST /v1/events

Body: NDJSON (format in `events.md`); blank lines are ignored.

- 204: every line was taken (a repeated event is counted once).
- 400 `{"error":"line <k>: <reason>"}`: line `k` (1-based, blank lines counted) did not parse; **nothing** from the batch is taken.
- 413 `{"error":"too many events"}`: more than 50 events or a body over 256 KiB.

## GET /v1/state

200: the current state of every device and session.

## GET /v1/queue?before=<eid>&limit=<n>

200: a page `{"events":[...],"more":bool}`, newest first. `before` is an event id from an earlier page; `limit` defaults to 50, at most 200.

- 400 `{"error":"bad cursor"}`, 400 `{"error":"bad limit"}` (not a non-negative integer).

## PUT /v1/seen

Marks something as looked at, with the service's own clock. Body is one of `{"fp":"<fp>","session":"<id>"}` (a session row) or `{"eid":"<eid>"}` (a queue row), plus an optional `"handled":true` (only kept for a queue row).

- 204: marked.
- 404 `{"error":"unknown session"}` or `{"error":"unknown eid"}`.
- 400 `{"error":"bad request"}`: not JSON, or neither shape.

A marked session row in `GET /v1/state` carries `"seen": <Unix seconds>`; it stays through later states of that session and goes when the session is gone. A marked queue row in `GET /v1/queue` carries `"seen"`, and `"handled": true` when set.

## GET /v1/watch

200 `content-type: text/event-stream`, a reply that stays open and pushes what changes (Server-Sent Events). Every frame is one line followed by a blank line:

- First `data: {"what":"hello"}`.
- `: ping` every 15 seconds (a comment line; skip it, but count it as "still alive").
- One `data: <one-line JSON>` per change, with `what` one of:

```
data: {"what":"session","fp":"<fp>","id":"<device id>","device":"<device name>","session":"<id>","row":{"session":"<id>","state":"working","seq":1,"since":1764130010,"at":1764130010,"by":"<fp>"}}
data: {"what":"session","fp":"<fp>","id":"<device id>","device":"<device name>","session":"<id>","row":null}
data: {"what":"queue","row":{"fp":"<fp>","epoch":"e1","n":3,"at":1764130020,"t":"state","session":"<id>","state":"blocked","seq":2,"eid":"<fp>:e1:3"}}
data: {"what":"need","needs":[{"fp":"<fp>","session":"<id>","since":1764130020,"kind":"permission"}]}
data: {"what":"seen","fp":"<fp>","session":"<id>","at":1764130100}
data: {"what":"seen","eid":"<eid>","at":1764130100,"handled":true}
```

- `session`: a session row as in `GET /v1/state`; `row: null` means the session is gone. `id` and `device` are that device's, as its entry in `GET /v1/state` carries them (left out when the device never sent them), so a watcher can place a device it did not have at its last fetch.
- `queue`: a new queue row, as in `GET /v1/queue`.
- `need`: the whole `needs` list of `GET /v1/state`, sent whenever it changes.
- `seen`: a `PUT /v1/seen` mark; `handled` only when true.

A watcher that falls more than 256 changes behind is disconnected. After any disconnect, fetch `GET /v1/state` and `GET /v1/queue` again before watching again: changes made while away are not replayed.

## Other

A known path with the wrong method: 405 `{"error":"method not allowed"}`.
