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

## Other

A known path with the wrong method: 405 `{"error":"method not allowed"}`.
