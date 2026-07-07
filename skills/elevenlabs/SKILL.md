---
name: elevenlabs
description: Call ElevenLabs' API (authenticated with ELEVENLABS_API_KEY) for text-to-speech, voice cloning and voice design, speech-to-text/transcription, sound effects, music generation, voice changing, audio isolation (noise removal), dubbing (translate audio/video files), forced alignment, and pronunciation dictionaries. Use when the user asks to generate speech/narration/voiceover, clone or design a voice, transcribe audio or video, generate a sound effect or a piece of music, change/convert a voice, remove background noise, dub/translate a video or audio file into another language, or align a transcript to audio. Note ElevenLabs has no public text-to-image or text-to-video generation endpoint — do not use this skill for "generate an image" or "generate a video from a prompt" requests.
---

# ElevenLabs API

Call the ElevenLabs API directly with `curl` — no SDK, no dependencies. Base URL: `https://api.elevenlabs.io`.

## What this skill does NOT do

ElevenLabs' public API has **no text-to-image and no text-to-video-from-a-prompt endpoint**. "Image & Video" generation exists only in the ElevenCreative web app, and the underlying Studio API is enterprise-only ("only available upon request — contact sales"), not reachable with a normal `ELEVENLABS_API_KEY`. If the user asks to *generate* an image or a video from scratch, say so plainly — don't improvise an endpoint. If another skill for an image/video model (e.g. Grok) is available, suggest that instead.

What ElevenLabs *does* have that touches video/images:
- **Dubbing** (§11) takes an existing video/audio file and re-voices it in another language — it does not create video, it transforms one.
- **Video-to-Music** (§5c) takes existing video file(s) and composes a matching music track — again, transforms/scores, doesn't generate video.

Both of the above accept file uploads, can take real time to process, and are the two capabilities in this skill to treat as **long-running/background work** (see their sections for the poll pattern) — matching the same "long generation → don't block" logic you'd apply to video generation elsewhere.

## Conventions (read first)

1. **Assume shell state does not persist between commands.** Every command block below re-resolves the key on its first line — keep that line when running them:

   ```bash
   KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"; [ -n "$KEY" ] && echo "key: OK" || echo "key: MISSING"
   ```

   If MISSING, stop and ask the user to `export ELEVENLABS_API_KEY` (key from https://elevenlabs.io/app/settings/api-keys). Never guess, hardcode, echo, or commit a key.

2. **Auth header is `xi-api-key`, NOT `Authorization: Bearer`.** Every request needs `-H "xi-api-key: $KEY"`.

3. **Two response shapes, and they're inconsistent per-endpoint — check before assuming:**
   - Most audio-producing endpoints return **raw binary** (`application/octet-stream`) — pipe straight to a file with `-o`.
   - Some return **JSON with base64 audio inside** (`.../with-timestamps`, Voice Design previews) — decode with `jq -r '.audio_base64' | base64 -d > out.mp3`.
   - Always save the raw response to `/tmp/eleven-*.json` (or `.mp3`/`.zip` for known-binary calls) first, so failures can be inspected afterward, and **verify with `file <path>`** that you got audio/zip/json and not an HTML error page or a 0-byte file.

4. **If a `jq` extraction prints nothing, the call failed.** Run `jq . /tmp/eleven-<step>.json` and read `.detail` before retrying — do not retry blindly. Standard validation error shape (HTTP 422) everywhere:
   ```json
   { "detail": [ { "loc": ["body", "field_name"], "msg": "...", "type": "..." } ] }
   ```
   `jq -r '.detail[].msg'` to read it.

5. Payloads go through a single-quoted heredoc to stdin (`-d @-`) for JSON bodies, so apostrophes/newlines in prompts are always safe. File uploads use `multipart/form-data` (`-F` flags) — check each section for which fields are files vs text.

6. **Voice cloning/design ethics**: only clone or remix a voice you have the legal right to use (your own voice, a client's with consent, or a licensed Voice Library voice) — never a real person's voice without consent. ElevenLabs enforces verification on some cloning flows (`requires_verification` field); respect it.

7. `jq` is assumed. If unavailable, parse with `python3 -c 'import json,sys; d=json.load(sys.stdin); ...'`.

8. Every endpoint below also has regional bases (`api.us.`, `api.eu.residency.`, `api.in.residency.`, `api.sg.residency.` + `.elevenlabs.io`) for data-residency needs — same paths, swap the host only if the user asks for a specific region.

## Models (confirmed IDs — `GET /v1/models` returns the live, current catalog; these are the ones referenced by name in the API docs)

| Capability | Model(s) | Notes |
|---|---|---|
| Text to speech (default) | `eleven_multilingual_v2` | Default for convert / with-timestamps / stream |
| Text to dialogue (multi-speaker) | `eleven_v3` | Supports bracketed cues in text, e.g. `[giggling]` |
| Speech to text | `scribe_v1`, `scribe_v2` | `no_verbatim` option needs `scribe_v2` |
| Voice changer (speech-to-speech) | `eleven_english_sts_v2` (default), `eleven_multilingual_sts_v2` | Must support voice conversion |
| Sound effects | `eleven_text_to_sound_v2` | `loop: true` needs this model |
| Music | `music_v1` (default), `music_v2` | `music_v2` always enforces section durations |
| Voice design (text-to-voice) | `eleven_multilingual_ttv_v2` (default), `eleven_ttv_v3` | Reference-audio conditioning needs `eleven_ttv_v3` |

If a `model_id` returns 422/"not found", re-check the live list:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/models -H "xi-api-key: $KEY" > /tmp/eleven-models.json
jq -r '.[] | select(.can_do_text_to_speech==true) | .model_id' /tmp/eleven-models.json
```

## Check quota before large jobs

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/user/subscription -H "xi-api-key: $KEY" > /tmp/eleven-sub.json
jq -r '"\(.character_count)/\(.character_limit) chars used, tier=\(.tier), status=\(.status)"' /tmp/eleven-sub.json
```

---

## 1. Text to speech

### 1a. Convert (simple, most common)

`POST /v1/text-to-speech/{voice_id}` — returns raw audio.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"   # find IDs with the voices/search call in §9
curl -s https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d @- -o /tmp/eleven-tts.mp3 <<'EOF'
{
  "text": "The quick brown fox jumps over the lazy dog.",
  "model_id": "eleven_multilingual_v2",
  "voice_settings": { "stability": 0.5, "similarity_boost": 0.75, "style": 0, "use_speaker_boost": true, "speed": 1.0 }
}
EOF
file /tmp/eleven-tts.mp3
```

Key optional body fields: `language_code` (ISO 639-1, ignored by multilingual_v2), `seed` (0–4294967295, best-effort determinism), `pronunciation_dictionary_locators` (max 3), `previous_text`/`next_text` or `previous_request_ids`/`next_request_ids` (max 3 each) for continuity across concatenated chunks. Query param `output_format` (default `mp3_44100_128`; also `pcm_*`, `wav_*` — Pro tier+ for 44.1kHz PCM/WAV, Creator tier+ for `mp3_44100_192`; `ulaw_8000` for Twilio).

Move the file to a real destination with a descriptive name once verified (e.g. `public/audio/narration-01.mp3`).

### 1b. Convert with timestamps (word/character-level alignment)

`POST /v1/text-to-speech/{voice_id}/with-timestamps` — same body, but returns **JSON**, not binary:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"
curl -s https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID/with-timestamps \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d @- > /tmp/eleven-tts-ts.json <<'EOF'
{ "text": "Timing matters for captions.", "model_id": "eleven_multilingual_v2" }
EOF
jq -r '.audio_base64' /tmp/eleven-tts-ts.json | base64 -d > /tmp/eleven-tts-ts.mp3
file /tmp/eleven-tts-ts.mp3
jq -r '(.alignment.characters // []) | join("")' /tmp/eleven-tts-ts.json   # sanity-check reconstructed text (alignment can be null)
```

Use `.alignment.character_start_times_seconds[]` / `.character_end_times_seconds[]` to build subtitle/caption timing; `.normalized_alignment.*` gives the same for the post-normalization text (numbers/dates expanded).

### 1c. Stream

`POST /v1/text-to-speech/{voice_id}/stream` — same body (no `wav_*` in `output_format` here). For low-latency playback pipelines:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"
curl -sN https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID/stream \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"text":"Streaming audio chunk by chunk.","model_id":"eleven_flash_v2_5"}' \
  -o /tmp/eleven-stream.mp3
```

If `eleven_flash_v2_5` 422s, it's not in your account's catalog — check `GET /v1/models` and fall back to `eleven_multilingual_v2`.

---

## 2. Text to Dialogue (multi-speaker conversation, one call)

`POST /v1/text-to-dialogue` — up to 10 unique voices, keep total text ≤ ~2000 chars for reliability. Returns raw binary audio.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/text-to-dialogue \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d @- -o /tmp/eleven-dialogue.mp3 <<'EOF'
{
  "model_id": "eleven_v3",
  "inputs": [
    { "voice_id": "21m00Tcm4TlvDq8ikWAM", "text": "[amused] Knock knock." },
    { "voice_id": "AZnzlk1XvdvUeBnXmlld", "text": "[curious] Who's there?" }
  ]
}
EOF
file /tmp/eleven-dialogue.mp3
```

Bracketed cues like `[amused]`, `[whispering]` are plain text that `eleven_v3` interprets as delivery direction. Optional: `settings.stability`, `seed`, `pronunciation_dictionary_locators`, `apply_text_normalization`.

---

## 3. Speech to Text (transcription — audio or video, incl. YouTube/TikTok URLs)

`POST /v1/speech-to-text` — multipart, `model_id` required (`scribe_v1` or `scribe_v2`), and exactly one of `file` or `source_url`.

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

For a hosted file / YouTube / TikTok URL instead of a local file, replace the `file=@...` line with `-F "source_url=https://..."`. Useful flags: `num_speakers` (hint, max 32), `language_code` (else auto-detect), `entity_detection`/`entity_redaction` (`pii`|`phi`|`pci`|`other`|`offensive_language`, +30% cost surcharge each), `keyterms` (bias transcription, array of strings, +20% surcharge), `no_verbatim` (strips fillers, `scribe_v2` only), `use_multi_channel` (each channel a separate speaker, max 5 — response becomes `{transcripts: [...]}` instead of a flat object, one per channel).

This is **synchronous by default** (full JSON back on the same request). Only pass `-F "webhook=true"` to make it async (fire-and-forget — result pushed to your configured webhook; there is no poll endpoint for this, so don't use `webhook=true` unless the user actually has a webhook configured).

---

## 4. Sound Effects

`POST /v1/sound-generation` — JSON body, returns raw MP3.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/sound-generation \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d @- -o /tmp/eleven-sfx.mp3 <<'EOF'
{
  "text": "Heavy wooden door creaking open slowly, then a distant echo",
  "duration_seconds": 4,
  "prompt_influence": 0.4
}
EOF
file /tmp/eleven-sfx.mp3
```

`duration_seconds` must be `0.5`–`30` (omit to let the model pick). `loop: true` makes a seamless loop but only works with `eleven_text_to_sound_v2` (the default). `prompt_influence` (0–1, default 0.3): higher = sticks closer to the prompt, less variation.

---

## 5. Music (Eleven Music)

### 5a. Compose (simple prompt)

`POST /v1/music` — returns raw binary audio; the generated `song_id` (needed for stem separation / inpainting later) comes back in a **response header**, not the JSON body — capture it with `-D`:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/music \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -D /tmp/eleven-music-headers.txt \
  -d @- -o /tmp/eleven-music.mp3 <<'EOF'
{
  "prompt": "Upbeat lo-fi hip hop, mellow piano chords, soft vinyl crackle, chill study-session vibe",
  "music_length_ms": 30000,
  "model_id": "music_v1"
}
EOF
file /tmp/eleven-music.mp3
grep -i 'song' /tmp/eleven-music-headers.txt || echo "no song-id-like header found — dump the full file: cat /tmp/eleven-music-headers.txt"
```

The exact header name isn't confirmed by the API docs (only that it exists) — if the grep above finds nothing, inspect the full header dump yourself rather than assuming the song ID is unavailable.

`music_length_ms` 3000–600000 (omit to let the model pick). `force_instrumental: true` guarantees no vocals. For fine-grained multi-section control, replace `prompt` with `composition_plan` (mutually exclusive) — see the API's `MusicPrompt`/`CompositionPlan` schema if the user needs per-section lyrics/styles/duration; `POST /v1/music/create-composition-plan` can also generate a starting plan from a prompt.

### 5b. Compose with metadata (title, genre, lyrics breakdown)

`POST /v1/music/detailed` — same body plus `"with_timestamps": true|false`. **Response is `multipart/mixed`** (a JSON metadata part + a binary audio part), which `curl -o` alone can't split — parse it with Python's `email` module:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/music/detailed \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -D /tmp/eleven-music-d-headers.txt \
  -d '{"prompt":"Driving synthwave, retro 80s arpeggios, energetic","music_length_ms":20000}' \
  -o /tmp/eleven-music-detailed.raw
python3 - <<'PYEOF'
import email, email.policy, pathlib
headers = pathlib.Path("/tmp/eleven-music-d-headers.txt").read_text()
ctype_line = next(l for l in headers.splitlines() if l.lower().startswith("content-type"))
ctype_value = ctype_line.split(":", 1)[1].strip()
raw = f"Content-Type: {ctype_value}\r\n\r\n".encode() + pathlib.Path("/tmp/eleven-music-detailed.raw").read_bytes()
msg = email.message_from_bytes(raw, policy=email.policy.default)
if not msg.is_multipart():
    raise SystemExit("response wasn't multipart/mixed as expected — inspect /tmp/eleven-music-detailed.raw directly")
for part in msg.iter_parts():
    if part.get_content_type() == "application/json":
        pathlib.Path("/tmp/eleven-music-meta.json").write_bytes(part.get_payload(decode=True))
    else:
        pathlib.Path("/tmp/eleven-music-detailed.mp3").write_bytes(part.get_payload(decode=True))
PYEOF
jq -r '.song_metadata.title, .song_metadata.genres[]' /tmp/eleven-music-meta.json
file /tmp/eleven-music-detailed.mp3
```

If this ever comes back as a single JSON blob instead (API behavior can drift from the docs' placeholder schema), just `jq -r '.audio' /tmp/eleven-music-detailed.raw | base64 -d > out.mp3` instead of the multipart parse.

### 5c. Video to Music (score an existing video — background/long-running)

`POST /v1/music/video-to-music` — multipart, up to 10 video files (combined ≤ 200MB, ≤ 600s total), returns audio matching the video length. **Treat as long-running**: this combines/analyzes video before generating, so don't assume it returns instantly.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/music/video-to-music \
  -H "xi-api-key: $KEY" \
  -F "videos=@/path/to/clip.mp4" \
  -F "description=Energetic cinematic trailer score, building tension" \
  -F "tags=cinematic" -F "tags=trailer" \
  -o /tmp/eleven-video-music.mp3
file /tmp/eleven-video-music.mp3
```

A `403` here means "Subscription required" — this endpoint is gated to certain tiers; tell the user rather than retrying.

### 5d. Stem separation

`POST /v1/music/stem-separation` — multipart, may be slow for long files. Returns a **ZIP** of separated stems, not a single audio file:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/music/stem-separation \
  -H "xi-api-key: $KEY" \
  -F "file=@/tmp/eleven-music.mp3" \
  -F "stem_variation_id=six_stems_v1" \
  -o /tmp/eleven-stems.zip
file /tmp/eleven-stems.zip
mkdir -p /tmp/eleven-stems && unzip -o /tmp/eleven-stems.zip -d /tmp/eleven-stems
```

`stem_variation_id`: `two_stems_v1` (vocals/instrumental) or `six_stems_v1` (default — vocals/drums/bass/guitar/piano/other).

---

## 6. Voice Changer (speech-to-speech conversion)

`POST /v1/speech-to-speech/{voice_id}` — multipart, transforms an input audio's voice while keeping its emotion/timing/delivery. Note `voice_settings` must be sent as a **JSON-encoded string**, not a nested object, because this is a multipart request:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"
curl -s https://api.elevenlabs.io/v1/speech-to-speech/$VOICE_ID \
  -H "xi-api-key: $KEY" \
  -F "audio=@/path/to/source-performance.mp3" \
  -F "model_id=eleven_multilingual_sts_v2" \
  -F 'voice_settings={"stability":0.5,"similarity_boost":0.8}' \
  -F "remove_background_noise=false" \
  -o /tmp/eleven-voice-changed.mp3
file /tmp/eleven-voice-changed.mp3
```

Set `remove_background_noise=true` to run audio isolation on the input first (useful for noisy source recordings).

---

## 7. Voice Design (create a brand-new voice from a text description)

Two-step flow: **design** (or **remix** an existing voice) generates preview(s) with a `generated_voice_id` — nothing is saved yet — then **create** persists your chosen preview as a real, usable voice.

### 7a. Design

`POST /v1/text-to-voice/design` — JSON, returns previews as base64 MP3 (does not save a voice):

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/text-to-voice/design \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d @- > /tmp/eleven-design.json <<'EOF'
{
  "voice_description": "Warm, calm middle-aged British male narrator, gentle pacing, radio-documentary tone",
  "auto_generate_text": true,
  "model_id": "eleven_multilingual_ttv_v2",
  "loudness": 0.5,
  "guidance_scale": 5
}
EOF
jq -r '.previews[] | .generated_voice_id' /tmp/eleven-design.json
jq -r '.previews[0].audio_base_64' /tmp/eleven-design.json | base64 -d > /tmp/eleven-design-preview.mp3
file /tmp/eleven-design-preview.mp3
```

`text` (100–1000 chars) can be supplied instead of `auto_generate_text: true` if the user wants specific preview words spoken. `guidance_scale` (default 5): lower = more creative freedom, higher = sticks to the prompt (can sound robotic if too high with short prompts — prefer longer, detailed prompts at lower guidance). Listen to (or at least check duration of) each preview before picking one — don't persist the first preview blind if several were generated.

### 7b. Remix (evolve an existing voice by prompt instead of designing from scratch)

`POST /v1/text-to-voice/{voice_id}/remix` — same idea, applied to an existing voice (`guidance_scale` default is 2 here, not 5):

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"
curl -s https://api.elevenlabs.io/v1/text-to-voice/$VOICE_ID/remix \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"voice_description":"Same voice but older, more gravelly, slower pace","auto_generate_text":true}' \
  > /tmp/eleven-remix.json
jq -r '.previews[].generated_voice_id' /tmp/eleven-remix.json
```

### 7c. Create (persist the chosen preview as a real voice)

`POST /v1/text-to-voice` — JSON, no audio generation here, just saves the pick:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
GENERATED_VOICE_ID="<paste generated_voice_id from 7a/7b>"
jq -n --arg name "Narrator - Warm British Male" \
      --arg desc "Warm, calm middle-aged British male narrator, gentle pacing" \
      --arg gid "$GENERATED_VOICE_ID" \
  '{voice_name:$name, voice_description:$desc, generated_voice_id:$gid}' \
| curl -s https://api.elevenlabs.io/v1/text-to-voice \
    -H "xi-api-key: $KEY" -H "Content-Type: application/json" -d @- \
  > /tmp/eleven-voice-created.json
jq -r '.voice_id' /tmp/eleven-voice-created.json
```

(Built with `jq -n --arg` rather than a heredoc so `$`/backtick characters the user puts in the name or description can't be shell-expanded or break the JSON — same reasoning as convention #5.)

The returned `voice_id` is now usable in every TTS/dialogue/voice-changer call above.

---

## 8. Voice Cloning

### 8a. Instant Voice Cloning (IVC) — fast, from a few samples

`POST /v1/voices/add` — multipart, one or more audio files of the target voice:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/voices/add \
  -H "xi-api-key: $KEY" \
  -F "name=My Cloned Voice" \
  -F "files=@/path/to/sample1.mp3" \
  -F "files=@/path/to/sample2.mp3" \
  -F "remove_background_noise=true" \
  -F "description=Cloned from consented sample recordings" \
  > /tmp/eleven-ivc.json
jq -r '.voice_id, .requires_verification' /tmp/eleven-ivc.json
```

Only clone a voice with the speaker's consent (see Conventions §6). `requires_verification: true` means ElevenLabs needs additional identity verification before the clone is fully usable — tell the user if so.

### 8b. Professional Voice Cloning (PVC) — higher fidelity, needs training

Two calls (create the shell, then start training) — **note: sample upload for PVC is not exposed via a documented endpoint in this reference; the ElevenLabs web app is the reliable path to add training samples today.** If the user needs a fully API-driven PVC pipeline, check https://elevenlabs.io/docs/api-reference/voices/pvc for any newer samples endpoint before promising this end-to-end.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/voices/pvc \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"name":"Pro Clone - Jane","language":"en"}' > /tmp/eleven-pvc.json
VOICE_ID=$(jq -r '.voice_id' /tmp/eleven-pvc.json)
echo "voice_id: $VOICE_ID"

# after samples have been added (web app), start training:
curl -s https://api.elevenlabs.io/v1/voices/pvc/$VOICE_ID/train \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{}' > /tmp/eleven-pvc-train.json
jq -r '.status' /tmp/eleven-pvc-train.json   # "ok" = training started
```

**Training is long-running** (this is the other true background job in this skill besides Dubbing). There's no dedicated poll endpoint — check progress via `GET /v1/voices/{voice_id}` and read `.fine_tuning.state` (per-model map, values `not_started`|`queued`|`fine_tuning`|`fine_tuned`|`failed`|`delayed`). Paste the `voice_id` from the create step above — it does not persist between commands:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="<paste voice_id from the create step above>"
curl -s https://api.elevenlabs.io/v1/voices/$VOICE_ID -H "xi-api-key: $KEY" | jq '.fine_tuning.state'
```

---

## 9. Voices management

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"

# List/search your voices (note: this one is /v2/, not /v1/)
curl -s "https://api.elevenlabs.io/v2/voices?page_size=20&category=cloned" \
  -H "xi-api-key: $KEY" > /tmp/eleven-voices.json
jq -r '.voices[] | "\(.voice_id)  \(.name)  \(.category)"' /tmp/eleven-voices.json

# Get one voice
VOICE_ID="21m00Tcm4TlvDq8ikWAM"
curl -s https://api.elevenlabs.io/v1/voices/$VOICE_ID -H "xi-api-key: $KEY" | jq '{voice_id,name,category,settings}'

# Get/inspect default settings for a voice
curl -s https://api.elevenlabs.io/v1/voices/$VOICE_ID/settings -H "xi-api-key: $KEY" | jq .

# Browse the shared Voice Library (pick a premade/professional/famous voice instead of cloning)
curl -s "https://api.elevenlabs.io/v1/shared-voices?category=professional&language=en&page_size=10" \
  -H "xi-api-key: $KEY" | jq -r '.voices[] | "\(.voice_id)  \(.name)  \(.accent // "")  \(.gender // "")"'

# Delete a voice (irreversible — confirm with the user first)
# curl -s -X DELETE https://api.elevenlabs.io/v1/voices/$VOICE_ID -H "xi-api-key: $KEY" | jq .
```

---

## 10. Audio Isolation (remove background noise / isolate speech)

`POST /v1/audio-isolation` — multipart. **The documented response schema is an empty placeholder (`{}`) despite this being an audio-transform endpoint** — treat the actual response as unconfirmed binary-or-JSON and check both:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/audio-isolation \
  -H "xi-api-key: $KEY" \
  -F "audio=@/path/to/noisy-recording.mp3" \
  -o /tmp/eleven-isolated.out
file /tmp/eleven-isolated.out
# if `file` reports audio data, just rename with the right extension:
# mv /tmp/eleven-isolated.out /tmp/eleven-isolated.mp3
# if `file` reports JSON/ASCII text instead, inspect it:
# jq . /tmp/eleven-isolated.out
```

---

## 11. Dubbing (translate a video/audio file — ASYNC, background job)

The one true async/poll workflow in this skill, and the closest thing to "video" work available: submit a file, poll, download.

**Step 1 — submit:**

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/dubbing \
  -H "xi-api-key: $KEY" \
  -F "file=@/path/to/source-video.mp4" \
  -F "target_lang=es" \
  -F "source_lang=auto" \
  > /tmp/eleven-dub.json
jq -r '"dubbing_id=\(.dubbing_id) expected_duration_sec=\(.expected_duration_sec)"' /tmp/eleven-dub.json
```

(Use `-F "source_url=https://..."` instead of `file=@...` for a hosted video URL.)

**Step 2 — poll.** Paste the id printed above (it does not persist between commands). This block fits typical per-command timeouts — **re-run it until status looks final**:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
DUBBING_ID="<paste dubbing_id here>"
for _ in $(seq 1 9); do
  curl -s https://api.elevenlabs.io/v1/dubbing/$DUBBING_ID -H "xi-api-key: $KEY" > /tmp/eleven-dub-status.json
  STATUS=$(jq -r '.status' /tmp/eleven-dub-status.json)
  case "$STATUS" in dubbing|pending|processing) sleep 10 ;; *) break ;; esac
done
echo "status: $STATUS"
jq -r '.error // empty' /tmp/eleven-dub-status.json
```

The API docs only confirm the example value `"dubbed"` for a completed status (no formal enum is published) — treat any other value as still-in-progress unless `.error` is populated (failure) or the loop's `sleep`-triggering cases (`dubbing`/`pending`/`processing`) don't match, in which case inspect the raw JSON to see what state it's actually in. Still not done after ~10 min total: stop and report the `dubbing_id` to the user rather than looping forever — dubbing longer videos can take a while.

**Step 3 — download** once status is final and no `.error`:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
DUBBING_ID="<paste dubbing_id here>"
TARGET_LANG="es"
curl -s https://api.elevenlabs.io/v1/dubbing/$DUBBING_ID/audio/$TARGET_LANG \
  -H "xi-api-key: $KEY" -o /tmp/eleven-dubbed-output
file /tmp/eleven-dubbed-output   # MP4 for video sources, MP3 for audio-only sources
```

---

## 12. Forced Alignment (align an existing transcript to audio, get timestamps)

`POST /v1/forced-alignment` — multipart, both `file` and `text` required. Note: no diarization support here.

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

---

## 13. Pronunciation Dictionaries

`POST /v1/pronunciation-dictionaries/add-from-rules` — fix mispronunciations for names/jargon before using them in TTS:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/pronunciation-dictionaries/add-from-rules \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d @- > /tmp/eleven-dict.json <<'EOF'
{
  "name": "product-names",
  "rules": [
    { "type": "alias", "string_to_replace": "ElevenLabs", "alias": "eleven labs" },
    { "type": "phoneme", "string_to_replace": "nginx", "phoneme": "ˈɛndʒɪnˈɛks", "alphabet": "ipa" }
  ]
}
EOF
jq -r '.id, .version_id' /tmp/eleven-dict.json
```

Reference the resulting `id` (as `pronunciation_dictionary_id`) + `version_id` in any TTS call's `pronunciation_dictionary_locators` (max 3 per request).

---

## 14. History (past generations)

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s "https://api.elevenlabs.io/v1/history?page_size=20" -H "xi-api-key: $KEY" > /tmp/eleven-history.json
jq -r '.history[] | "\(.history_item_id)  \(.date_unix)  \(.voice_name // "")  \(.text // "" | .[0:60])"' /tmp/eleven-history.json

# re-download a past generation's audio
HISTORY_ITEM_ID="<paste history_item_id>"
curl -s https://api.elevenlabs.io/v1/history/$HISTORY_ITEM_ID/audio -H "xi-api-key: $KEY" -o /tmp/eleven-history-item.mp3
```

---

## Troubleshooting

- **Empty `jq` output**: the call failed — `jq . /tmp/eleven-<step>.json` and read `.detail[].msg` before retrying.
- **401**: key missing/invalid — re-check `ELEVENLABS_API_KEY`; don't retry blindly.
- **403 "Subscription required"** (seen on Video-to-Music and some voice/PVC features): the account's tier doesn't include this capability — tell the user, don't keep retrying.
- **403 with no body, on any endpoint**: IP-allowlist restriction on the API key — check key settings at elevenlabs.io, not a code bug.
- **422**: validation error — `jq -r '.detail[].msg' /tmp/eleven-<step>.json`; almost always a missing required field or bad enum value (e.g. wrong `model_id` for the endpoint, `duration_seconds` out of 0.5–30 range, `music_length_ms` out of 3000–600000 range).
- **429**: rate limit — wait ~30s and retry once; if persistent, tell the user (quota/billing at elevenlabs.io/app/subscription).
- **Downloaded file is HTML, JSON error, or 0 bytes when binary was expected**: always `file <path>` after downloading before treating it as done — the raw response may be an error page, not media.
- **Sound/voice output doesn't match the brief**: refine the prompt/`voice_description` and regenerate — for Voice Design, generate a couple of previews and compare rather than accepting the first one; don't ship a bad take.
- **Asked to generate an image or a from-scratch video**: not possible with this API (see "What this skill does NOT do" above) — say so, don't fabricate an endpoint.
