# Transcription — Speech to Text, Forced Alignment

Read this when transcribing audio/video, producing subtitles, or timestamping an existing script.
Conventions are in `SKILL.md`.

## 1. Speech to Text

`POST /v1/speech-to-text` — multipart. `model_id` is **required**, and exactly one of `file` or
`source_url` must be supplied.

**Use `scribe_v2`.** `scribe_v1` has been retired and removed from the API. `scribe_v2_realtime`
exists but is WebSocket-only — see §3.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/speech-to-text \
  -H "xi-api-key: $KEY" \
  -F "model_id=scribe_v2" \
  -F "file=@/path/to/audio-or-video.mp4" \
  -F "diarize=true" \
  -F "timestamps_granularity=word" \
  -F "tag_audio_events=true" \
  > /tmp/eleven-stt.json
jq -r '.text' /tmp/eleven-stt.json
jq -r '.words[] | "\(.start)-\(.end) [\(.speaker_id)] \(.text)"' /tmp/eleven-stt.json
```

For a hosted file / YouTube / TikTok URL, replace the `file=@...` line with
`-F "source_url=https://..."`. (`cloud_storage_url` is the deprecated name for the same thing — use
`source_url`.)

Limits: local file ≤ 5 GB, `source_url` file ≤ 2 GB, minimum 100 ms of audio.

### Useful flags

| Flag | What it does |
|---|---|
| `language_code` | ISO-639-1 or -3. Omit to auto-detect (`.language_code` + `.language_probability` come back either way) |
| `num_speakers` | Hint for diarization, max 32 |
| `diarization_threshold` | 0–1, only with `diarize=true` and no `num_speakers`. Lower = more speakers predicted. Default ≈0.22 |
| `detect_speaker_roles` | Label speakers as `agent` vs `customer` instead of `speaker_0`/`speaker_1`. Requires `diarize=true`. Cannot combine with `use_multi_channel`. **+10% cost** |
| `use_speaker_library` | Matches detected speakers against registered voices in the workspace speaker library. Requires `diarize=true` |
| `keyterms` | Bias transcript toward terms (brand/product names, ≤1000 terms, <50 chars, max 5 words). Over 100 terms enforces 20s min duration. **+20% cost** |
| `entity_detection` / `entity_redaction` | `all`, or `pii`/`phi`/`pci`/`other`/`offensive_language`. Results land in `.entities[]`. **+30% cost each** |
| `entity_redaction_mode` | Formatting for redactions: `enumerated_entity_type` (default, e.g. `{EMAIL_1}`), `entity_type` (`{EMAIL}`), or `redacted` (`{REDACTED}`) |
| `no_verbatim` | Strips fillers and false starts. **`scribe_v2` only** |
| `temperature` | 0.0–2.0, default ~0. Higher = less deterministic |
| `seed` | 0–2147483647, best-effort determinism |
| `file_format` | `other` (default) or `pcm_s16le_16` for lower latency with raw 16-bit/16 kHz mono PCM |
| `use_multi_channel` | One speaker per channel, max 5. **Each channel is billed at full audio duration** |
| `multichannel_output_style` | `separate` (default → `{transcripts:[...]}`) or `combined` (one transcript, each word carries `channel_index`). `combined` needs timestamps and rules out entity detection |

### Subtitles: let the API format them

`additional_formats` exports the transcript in ready-made formats in the same call — do **not**
hand-roll SRT from `.words[]` timings.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/speech-to-text \
  -H "xi-api-key: $KEY" \
  -F "model_id=scribe_v2" \
  -F "file=@/path/to/interview.mp4" \
  -F "diarize=true" \
  -F 'additional_formats=[{"format":"srt","include_speakers":true,"max_characters_per_line":42}]' \
  > /tmp/eleven-stt-srt.json
jq -r '.additional_formats[] | select(.requested_format=="srt") | .content' /tmp/eleven-stt-srt.json > /tmp/eleven-subs.srt
head -8 /tmp/eleven-subs.srt
```

`format` is one of `srt`, `txt`, `docx`, `pdf`, `html`, `segmented_json` (max 10 entries). **There is
no `vtt`** — convert from SRT if the user needs WebVTT. Each entry accepts `include_speakers`,
`include_timestamps`, `max_characters_per_line`, `segment_on_silence_longer_than_s`,
`max_segment_duration_s`, `max_segment_chars`.

Every returned entry has `.requested_format`, `.file_extension`, `.content_type`,
`.is_base64_encoded` and `.content` — **check `is_base64_encoded`** before writing the file (`docx`
and `pdf` come back base64; `srt`/`txt`/`html` come back as text).

### Async transcription

This endpoint is **synchronous by default** — the full JSON comes back on the same request. Pass
`-F "webhook=true"` to return immediately instead; the result is then delivered to your configured
speech-to-text webhooks (`webhook_id` targets a specific one, `webhook_metadata` carries a JSON
string of your own tracking data back).

Either way the response carries a `transcription_id`, and a finished transcript can be re-fetched
later:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
TRANSCRIPTION_ID="<paste transcription_id>"
curl -s "https://api.elevenlabs.io/v1/speech-to-text/transcripts/$TRANSCRIPTION_ID" \
  -H "xi-api-key: $KEY" | jq -r '.text'
# DELETE the same path removes a stored transcript.
```

Only use `webhook=true` if the user actually has a webhook configured — otherwise stay synchronous.

---

## 2. Forced Alignment (align a known transcript to audio)

`POST /v1/forced-alignment` — multipart, both `file` and `text` required. Use this instead of STT
when the exact words are already known and only timings are missing. No diarization support here.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/forced-alignment \
  -H "xi-api-key: $KEY" \
  -F "file=@/path/to/narration.mp3" \
  -F "text=The exact transcript of the audio goes here." \
  > /tmp/eleven-align.json
jq -r '.words[] | "\(.start)-\(.end)  \(.text)"' /tmp/eleven-align.json
jq -r '.loss' /tmp/eleven-align.json   # lower = more confident alignment
```

File must be under 1 GB. `.characters[]` gives character-level timings, `.words[]` word-level (each
with its own `.loss`), and top-level `.loss` scores the whole alignment. A high `.loss` usually means
the transcript and the audio disagree — check for missing or extra passages before trusting the
timings.

---

## 3. Realtime transcription (not curl-friendly)

`/v1/speech-to-text/realtime` is a **WebSocket** endpoint (`scribe_v2_realtime`,
`scribe_v2_realtime_turbo`, `scribe_v2_realtime_lite`, ~150 ms latency). It streams
`input_audio_chunk` messages up and `partial_transcript` / `committed_transcript` messages back.

Plain `curl` cannot drive it. If the user needs live transcription, point them at the official SDK or
`POST /v1/single-use-token/batch_scribe` for browser-side auth — do not try to fake it with the
synchronous endpoint on short chunks, the quality and cost will both be worse.
