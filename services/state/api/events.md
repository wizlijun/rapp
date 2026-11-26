# Event format (v1)

One JSON object per line (NDJSON). Samples: `samples/term-events.ndjson` (one sender, the outbox must produce exactly these lines, compared as JSON values) and `samples/mixed.ndjson` (duplicate, second sender, relayed report, epoch change with a gap snap).

## Envelope

Required: `v` (=1), `fp` (the reported device), `epoch`, `n` (>= 1, per epoch), `at` (unix seconds), `t`.
Optional: `id` (9-digit device id), `device` (device name), `src` (`term`, `app`, `emit`), `via` (the fp of the device that reported on behalf of `fp`).
The sender is `via` when present, else `fp`. Unknown fields are kept as they are. Unknown `t` is an error.

## Kinds

| t | body |
|---|---|
| `state` | `session` (required), `name`, `state` (`working` `blocked` `done` `error` `idle`), `seq`, `since`; when present: `kind` (blocked), `app`, `msg`, `title`, `fg`, `host` |
| `gone` | `session` (required) |
| `snap` | `sessions`: array of `state` bodies (same fields); optional `gap: true` |
| `emit` | `level` (`done` `ask` `info` `clear`), `text`, optional `key`, `session` |

In `state` events and snap items, `session`, `name`, `state`, `seq`, `since` are always present; the others only when present.
`msg` and `text` are plain text, cut to 500 characters (by `char`, no ellipsis).

## Store rules

- Dedup: per sender the highest `n` of the last 4 epochs is remembered; an event with `n` not greater is dropped.
- Current state is grouped by the reported device: `devices[fp] = {fp, id, device, last, sessions}`. A row is the event body without the envelope, plus `at`, `by` (the sender) and, when the event carries one, `src`. `needs` entries carry `src` too.
  - `state` replaces the row; `gone` deletes it. A `gone` that names `via` (a proxy report) deletes the row only when its `by` is that sender; a `gone` without `via` deletes it whoever reported it.
  - `snap` deletes every row of that device whose `by` is this sender, then adds its `sessions` (`at` = snap `at`, `by` = sender). Rows by other senders stay.
- Queue: `state`, `gone`, `emit` events are queued as the original line without `v`, plus `eid` = `<sender>:<epoch>:<n>`. A `snap` with `gap:true` queues `{"t":"gap","fp","id","device","at","eid"}`; other snaps are not queued. Order by `(at, arrival)`, newest first. Capped at `keep_events` (oldest dropped); rows older than `keep_days` go on expire.
- `needs`: every row with `state == "blocked"`: `{fp, id, device, session, kind, app, msg, src, since}`. `since` is the row's own `since` field if present, else the earliest `at` since the row entered blocked with the same `seq`. Sorted by `since`, oldest first.
- A device with no message for 30 days is removed on expire (its queue rows follow the queue rules).

## Shapes

- `state()`: `{"devices":[{fp,id,device,last,sessions:[row...]}...], "desks":[{fp,device,at,sessions}...], "needs":[...], "queued": <n>}`; sessions sorted by session id, devices by fp.
- `queue(before, limit)`: `{"events":[...], "more": bool}`; default limit 50, max 200; `before` is an `eid` and returns only older rows; an unknown `eid` is `bad cursor`.
