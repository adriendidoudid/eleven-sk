# Dubbing — translate an audio/video file into another language

This is an **async, long-running background job**. Submit, poll, download. Conventions are in
`SKILL.md`.

Dubbing re-voices existing media; it does not create video. See `SKILL.md` for what this skill cannot
do.

## Which API to use

There are two generations of the dubbing API and they behave differently:

| | **Project API** (`/v1/dubbing/project`) | **Legacy API** (`/v1/dubbing`) |
|---|---|---|
| Status | Current | Marked *Legacy* in the docs, still functional |
| Statuses | Published enums | Undocumented strings |
| Output | Dubbed **audio track** (lossless FLAC, signed URL) | Rendered file — **MP4 for video sources**, MP3 for audio-only |
| Per-language control | Yes, language targets are separate resources | Limited |
| Transcript editing | Yes, source and target segments | No |

**Default to the Project API (§1).** Switch to Legacy (§2) only when the user needs a finished
*video* file back with the dubbed audio already muxed in — the Project API returns an audio track that
you would otherwise have to remux yourself with `ffmpeg`.

---

## 1. Project API (current)

### Step 1 — create the project

`POST /v1/dubbing/project` — multipart. `target_language` is a shortcut that also queues one language
target, which is all that most requests need.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/dubbing/project \
  -H "xi-api-key: $KEY" \
  -F "file=@/path/to/source-video.mp4" \
  -F "source_language=en" \
  -F "target_language=es" \
  -F "model_id=dubbing_v2" \
  -F "reference=marketing promo Q3" \
  > /tmp/eleven-dub.json
jq -r '"project_id=\(.project_id) status=\(.status)"' /tmp/eleven-dub.json
```

- Use `-F "source_url=https://..."` instead of `file=@...` for hosted media.
- Languages are **BCP-47 tags** (`es`, `fr`, `es-MX`) — note this differs from the legacy API's
  `source_lang`/`target_lang` field names.
- Omit `source_language` to auto-detect.
- `model_id`: `dubbing_v1` or `dubbing_v2`. Omit to use the system default.
- `keyterms` biases transcription/translation toward brand or product names (≤1000 terms).
- `webhook_ids` (≤3 workspace webhooks) gets you notified instead of polling.

### Step 2 — poll the project until it is `ready`

`ready` means **transcription finished**, not that the dub is done. Paste the id — shell state does
not persist between commands. Re-run this block until the status is final.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
PROJECT_ID="<paste project_id>"
for _ in $(seq 1 9); do
  curl -s "https://api.elevenlabs.io/v1/dubbing/project/$PROJECT_ID" -H "xi-api-key: $KEY" > /tmp/eleven-dub-project.json
  STATUS=$(jq -r '.status' /tmp/eleven-dub-project.json)
  case "$STATUS" in queued|preparing|processing) sleep 10 ;; *) break ;; esac
done
echo "project status: $STATUS"
jq -r '.error.error // empty' /tmp/eleven-dub-project.json
jq -r '.language_ids[]?' /tmp/eleven-dub-project.json
jq -r '.warnings[]? | .message' /tmp/eleven-dub-project.json
```

Project status enum: `queued` | `preparing` | `processing` | `ready` | `failed`. On `failed`, read
`.error.error` for the reason.

Watch for the `voices_not_permitted` warning — it means cloning was refused for some speakers and
replacement voices were substituted. Tell the user; the dub still succeeds.

If you did not use the `target_language` shortcut, add a language target now:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
PROJECT_ID="<paste project_id>"
curl -s "https://api.elevenlabs.io/v1/dubbing/project/$PROJECT_ID/language" \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"target_language":"fr","voice_settings":{"cloning_strength":7}}' \
  | jq -r '"language_id=\(.language_id) status=\(.status)"'
```

`cloning_strength` is 0–10 (default 7) — how strongly dubbed speakers clone the source voices.

### Step 3 — poll the language target until `completed`

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
PROJECT_ID="<paste project_id>"
LANGUAGE_ID="<paste language_id from .language_ids[]>"
for _ in $(seq 1 9); do
  curl -s "https://api.elevenlabs.io/v1/dubbing/project/$PROJECT_ID/language/$LANGUAGE_ID" \
    -H "xi-api-key: $KEY" > /tmp/eleven-dub-lang.json
  STATUS=$(jq -r '.status' /tmp/eleven-dub-lang.json)
  case "$STATUS" in queued|processing) sleep 10 ;; *) break ;; esac
done
echo "language status: $STATUS"
jq -r '.error.error // empty' /tmp/eleven-dub-lang.json
jq -r '.outputs.lossless_audio // "no output yet"' /tmp/eleven-dub-lang.json
```

Language status enum: `queued` | `processing` | `completed` | `stale` | `failed`.

`stale` means the source or transcript changed after this output was generated — the old output is
still there. Compare `.output_revision` against `.revision`: equal means up to date, lower means the
output predates the latest edit. Regenerate with
`POST /v1/dubbing/project/{project_id}/language/{language_id}/transcript/regenerate`.

Still not finished after ~10 minutes of polling: stop and report the `project_id` and `language_id`
to the user rather than looping forever. Long videos legitimately take a while.

### Step 4 — download

`.outputs.lossless_audio` is a **pre-signed URL** — fetch it directly, with no `xi-api-key` header:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
PROJECT_ID="<paste project_id>"
LANGUAGE_ID="<paste language_id>"
URL=$(curl -s "https://api.elevenlabs.io/v1/dubbing/project/$PROJECT_ID/language/$LANGUAGE_ID" \
  -H "xi-api-key: $KEY" | jq -r '.outputs.lossless_audio')
[ -n "$URL" ] && [ "$URL" != "null" ] || { echo "no output URL — target not completed"; exit 1; }
curl -sL "$URL" -o /tmp/eleven-dubbed.flac
file /tmp/eleven-dubbed.flac
```

To deliver a **video** with this audio, remux it yourself:

```bash
ffmpeg -y -i /path/to/source-video.mp4 -i /tmp/eleven-dubbed.flac \
  -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac /tmp/eleven-dubbed.mp4
```

If `ffmpeg` is unavailable, say so and offer the Legacy API (§2) instead — don't silently hand back an
audio file when the user asked for a dubbed video.

### Editing the transcript before dubbing

The Project API exposes the source and target transcripts, so a user can correct a mis-transcription
or a translation before generating:

| Endpoint | Purpose |
|---|---|
| `GET /v1/dubbing/project/{project_id}/transcript` | Source transcript segments |
| `POST /v1/dubbing/project/{project_id}/transcript/segment` | Add a source segment |
| `PATCH /v1/dubbing/project/{project_id}/transcript/segment/{segment_id}` | Edit one source segment |
| `PATCH /v1/dubbing/project/{project_id}/transcript/segments` | Batch update source segments |
| `GET /v1/dubbing/project/{project_id}/language/{language_id}/transcript` | Read the translation |
| `PATCH /v1/dubbing/project/{project_id}/language/{language_id}/transcript/segment/{segment_id}` | Edit one translated segment |
| `PATCH /v1/dubbing/project/{project_id}/language/{language_id}/transcript/segments` | Batch update the translation |
| `POST /v1/dubbing/project/{project_id}/language/{language_id}/transcript/regenerate` | Re-dub after edits |

Every edit bumps `.revision` and marks existing outputs `stale`.

---

## 2. Legacy API — when a muxed video file is required

Still functional, and the only path that returns a ready-to-ship video.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/dubbing \
  -H "xi-api-key: $KEY" \
  -F "file=@/path/to/source-video.mp4" \
  -F "target_lang=es" \
  -F "source_lang=auto" \
  > /tmp/eleven-dub-legacy.json
jq -r '"dubbing_id=\(.dubbing_id) expected_duration_sec=\(.expected_duration_sec)"' /tmp/eleven-dub-legacy.json
```

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
DUBBING_ID="<paste dubbing_id>"
for _ in $(seq 1 9); do
  curl -s "https://api.elevenlabs.io/v1/dubbing/$DUBBING_ID" -H "xi-api-key: $KEY" > /tmp/eleven-dub-status.json
  STATUS=$(jq -r '.status' /tmp/eleven-dub-status.json)
  case "$STATUS" in dubbing|pending|processing) sleep 10 ;; *) break ;; esac
done
echo "status: $STATUS"
jq -r '.error // empty' /tmp/eleven-dub-status.json
```

The legacy status field has **no published enum** — `"dubbed"` is the documented completed value.
Treat anything else as still running unless `.error` is populated.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
DUBBING_ID="<paste dubbing_id>"
TARGET_LANG="es"
curl -s "https://api.elevenlabs.io/v1/dubbing/$DUBBING_ID/audio/$TARGET_LANG" \
  -H "xi-api-key: $KEY" -o /tmp/eleven-dubbed-output
file /tmp/eleven-dubbed-output   # MP4 for video sources, MP3 for audio-only sources
```

Legacy also exposes transcripts: `GET /v1/dubbing/{dubbing_id}/transcript/{language_code}` and
`GET /v1/dubbing/{dubbing_id}/transcripts/{language_code}/format/{format_type}` (for subtitle
formats).
