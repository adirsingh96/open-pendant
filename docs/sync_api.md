# Later sync API (sketch)

Not implemented. On-device SQLite is the source of truth in v1.

## Clips

`POST /v1/clips`

```json
{
  "id": "uuid",
  "started_at": "2026-08-18T13:32:01.000Z",
  "duration_s": 8.0,
  "full_text": "this is just to check if its working or not",
  "stt_model": "whisper-1",
  "checksum": "sha256-of-wav-optional",
  "segments": [
    {
      "start_s": 0.0,
      "end_s": 3.2,
      "spoken_at": "2026-08-18T13:32:01.000Z",
      "text": "this is just to check"
    }
  ]
}
```

`GET /v1/clips?since=2026-08-18T00:00:00Z` — list clips (segments optional via `?include=segments`).

Audio upload is optional and separate (`PUT /v1/clips/{id}/audio`) so transcripts can sync without shipping WAV.
