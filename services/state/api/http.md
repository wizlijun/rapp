# rapp-state HTTP API

JSON over HTTP/1.1 on 127.0.0.1. Errors: `{"error": "..."}`.

## GET /v1/health

200 `{"name":"rapp-state","v":1}`

Unknown paths: 404 `{"error":"not found"}`.
