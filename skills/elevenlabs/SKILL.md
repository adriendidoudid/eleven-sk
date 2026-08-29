---
name: elevenlabs
description: Call ElevenLabs' API (authenticated with ELEVENLABS_API_KEY) for text-to-speech, voice cloning and voice design, speech-to-text/transcription, sound effects, music generation, voice changing, audio isolation (noise removal), dubbing (translate audio/video files), forced alignment, and pronunciation dictionaries. Use when the user asks to generate speech/narration/voiceover, clone or design a voice, transcribe audio or video, generate a sound effect or a piece of music, change/convert a voice, remove background noise, dub/translate a video or audio file into another language, or align a transcript to audio. Note ElevenLabs has no public text-to-image or text-to-video generation endpoint — do not use this skill for "generate an image" or "generate a video from a prompt" requests.
license: MIT
compatibility: Needs curl and jq on PATH, network access to api.elevenlabs.io, and ELEVENLABS_API_KEY (or ELEVEN_API_KEY) exported. python3 is needed only for the multipart/mixed response of /v1/music/detailed; ffmpeg only to remux a dubbed audio track back into a video.
metadata:
  version: "2.0"
  api-verified: "2026-08-29"
---

# ElevenLabs API

Call the ElevenLabs API directly with `curl` — no SDK, no dependencies. Base URL:
`https://api.elevenlabs.io`.

This file holds the conventions, the model table and the three most common recipes. Anything deeper
lives in `references/` — load the one file you need, not all of them.

## What this skill does NOT do

ElevenLabs' public API has **no text-to-image and no text-to-video-from-a-prompt endpoint**. "Image &
Video" generation exists only in the ElevenCreative web app, and the underlying Studio API is
enterprise-only ("available upon request — contact sales"), not reachable with a normal
`ELEVENLABS_API_KEY`. If the user asks to *generate* an image or a video from scratch, say so plainly
— don't improvise an endpoint. If another skill for an image/video model (e.g. Grok) is available,
suggest that instead.

What ElevenLabs *does* have that touches video:

- **Dubbing** takes an existing video/audio file and re-voices it in another language.
- **Video-to-Music** takes existing video and composes a matching track.

Both transform existing media rather than creating it, both accept file uploads, and both are
**long-running background work** — see their sections for the poll pattern.

**ElevenAgents** (conversational AI agents, phone numbers, batch calling, workflows) is a large
separate surface under `/v1/convai/*`. It is deliberately out of scope here — if the user wants a
conversational agent, say this skill doesn't cover it rather than guessing at those endpoints.

## Conventions (read first)

1. **Assume shell state does not persist between commands.** Every command block re-resolves the key
   on its first line — keep that line when running them:

   ```bash
   KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"; [ -n "$KEY" ] && echo "key: OK" || echo "key: MISSING"
   ```

   If MISSING, stop and ask the user to `export ELEVENLABS_API_KEY` (key from
   https://elevenlabs.io/app/settings/api-keys). Never guess, hardcode, echo, or commit a key.

2. **Auth header is `xi-api-key`, NOT `Authorization: Bearer`.** Every request needs
   `-H "xi-api-key: $KEY"`.

3. **Two response shapes, inconsistent per-endpoint — check before assuming:**
   - Most audio-producing endpoints return **raw binary** — pipe straight to a file with `-o`.
   - Some return **JSON with base64 audio inside** (`.../with-timestamps`, Voice Design previews) —
     decode with `jq -r '.audio_base64' | base64 -d > out.mp3`.
   - Always save the raw response to `/tmp/eleven-*.json` (or `.mp3`/`.zip` for known-binary calls)
     first, so failures can be inspected afterwards, and **verify with `file <path>`** that you got
     audio/zip/json and not an HTML error page or a 0-byte file.

4. **If a `jq` extraction prints nothing, the call failed.** Run `jq . /tmp/eleven-<step>.json` and
   read `.detail` before retrying — do not retry blindly. Standard validation error shape (HTTP 422):

   ```json
   { "detail": [ { "loc": ["body", "field_name"], "msg": "...", "type": "..." } ] }
   ```

   `jq -r '.detail[].msg'` to read it.

5. JSON payloads go through a single-quoted heredoc to stdin (`-d @-`) so apostrophes and newlines in
   prompts are always safe. When a value comes from the user and could contain `$` or backticks,
   build the JSON with `jq -n --arg` instead. File uploads use `multipart/form-data` (`-F` flags) —
   check each section for which fields are files vs text.

6. **Voice cloning/design ethics**: only clone or remix a voice you have the legal right to use — your
   own, a client's with consent, or a licensed Voice Library voice. Never a real person's voice
   without consent. ElevenLabs enforces verification on some cloning flows (`requires_verification`);
   respect it.

7. `jq` is assumed. If unavailable, parse with
   `python3 -c 'import json,sys; d=json.load(sys.stdin); ...'`.

8. Regional bases (`api.us.`, `api.eu.residency.`, `api.in.residency.`, `api.sg.residency.` +
   `.elevenlabs.io`) serve the same paths for data-residency needs — swap the host only if asked.

## Where to look

Load the reference file for the task at hand:

| The user wants… | Read |
|---|---|
| Narration, voiceover, captions/timestamps, streaming TTS, multi-speaker dialogue, re-voicing a recording | `references/speech.md` |
| A transcript, subtitles/SRT, speaker diarization, timing an existing script | `references/transcription.md` |
| Background music, a soundtrack for a video, stems, sound effects | `references/music.md` |
| A new designed voice, a voice clone (instant or professional), finding/managing voices | `references/voices.md` |
| A video or audio file translated into another language | `references/dubbing.md` |
| Noise removal, pronunciation fixes, past generations, output formats, quota | `references/utilities.md` |

The three recipes below cover the most common asks without needing any of those files.

## Models

`GET /v1/models` returns the live catalogue and is the authority. This table is the current
recommended pick per capability.

| Capability | Use | Also available | Avoid |
|---|---|---|---|
| Text to speech | `eleven_multilingual_v2` (API default, 29 langs) | `eleven_v3` (most expressive, 70+ langs), `eleven_flash_v2_5` (~75 ms, 32 langs), `eleven_flash_v2` (~75 ms, English) | `eleven_turbo_v2`, `eleven_turbo_v2_5`, `eleven_monolingual_v1`, `eleven_multilingual_v1` — all deprecated |
| Text to dialogue | `eleven_v3` (default; reads bracketed cues like `[amused]`) | `eleven_v3_conversational` (~280 ms, realtime) | |
| Speech to text | `scribe_v2` | `scribe_v2_realtime` (WebSocket only) | `scribe_v1` — deprecated, removal announced for 2026-07-09 |
| Voice changer | `eleven_multilingual_sts_v2` | `eleven_english_sts_v2` (API default, English) | |
| Sound effects | `eleven_text_to_sound_v2` (only option) | | |
| Music | `music_v2` (studio-grade) | `music_v1` (API default) | |
| Voice design | `eleven_multilingual_ttv_v2` (default) | `eleven_ttv_v3` (needed for reference-audio conditioning) | |
| Dubbing | `dubbing_v2` | `dubbing_v1` | |

Note the "API default" markers: several endpoints default to an older model than the one you should
pick, so pass `model_id` explicitly rather than relying on the default.

If a `model_id` returns 422 / "not found", it is not in your account's catalogue — re-check the live
list rather than guessing a substitute:

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

## Recipe 1 — Text to speech

`POST /v1/text-to-speech/{voice_id}` — returns raw audio. Full options in `references/speech.md`.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"   # browse voices: references/voices.md §4
curl -s "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID" \
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

Move the file to a real destination with a descriptive name once verified (e.g.
`public/audio/narration-01.mp3`).

## Recipe 2 — Sound effect

`POST /v1/sound-generation` — JSON body, returns raw MP3. More in `references/music.md`.

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

`duration_seconds` is 0.5–30 (omit to let the model choose); `prompt_influence` 0–1, default 0.3.

## Recipe 3 — Transcription

`POST /v1/speech-to-text` — multipart, `model_id` required, synchronous. Diarization, subtitle export
and async handling are in `references/transcription.md`.

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

Use `-F "source_url=https://..."` instead of `file=@...` for a hosted file, YouTube or TikTok URL.

---

## Troubleshooting

- **Empty `jq` output**: the call failed — `jq . /tmp/eleven-<step>.json` and read `.detail[].msg`
  before retrying.
- **401**: key missing/invalid — re-check `ELEVENLABS_API_KEY`; don't retry blindly.
- **403 "Subscription required"** (seen on Video-to-Music and some voice/PVC features): the account's
  tier doesn't include this capability — tell the user, don't keep retrying.
- **403 with no body, on any endpoint**: IP-allowlist restriction on the API key — check key settings
  at elevenlabs.io, not a code bug.
- **404 on an endpoint that "should" exist**: the path may have moved between API generations (dubbing
  is the big one — see `references/dubbing.md`). Confirm against
  `https://api.elevenlabs.io/openapi.json` rather than guessing a variant.
- **422**: validation error — `jq -r '.detail[].msg' /tmp/eleven-<step>.json`; almost always a missing
  required field or a bad enum (wrong `model_id` for the endpoint, `duration_seconds` outside 0.5–30,
  `music_length_ms` outside 3000–600000).
- **429**: rate limit — wait ~30 s and retry once; if persistent, tell the user (quota/billing at
  elevenlabs.io/app/subscription).
- **Downloaded file is HTML, JSON, or 0 bytes when binary was expected**: always `file <path>` after
  downloading before treating it as done.
- **A tier-gated `output_format` is refused**: fall back to `mp3_44100_128` and say why — see
  `references/utilities.md` §4.
- **Output doesn't match the brief**: refine the prompt and regenerate. For Voice Design, compare
  several previews rather than accepting the first; for sound effects, generate a couple of takes.
  Don't ship a bad take.
- **Asked to generate an image or a from-scratch video**: not possible with this API — say so, don't
  fabricate an endpoint.
