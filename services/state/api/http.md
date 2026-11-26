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

## Other

A known path with the wrong method: 405 `{"error":"method not allowed"}`.
