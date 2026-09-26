# Speech generation — TTS, Dialogue, Voice Changer

Read this when generating narration/voiceover, multi-speaker dialogue, or re-voicing an existing
recording. Conventions (key resolution, `file` verification, error handling) are in `SKILL.md`.

## 1. Text to Speech

### 1a. Convert (the default choice)

`POST /v1/text-to-speech/{voice_id}` — returns raw audio.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"   # find IDs with the voices/search call in references/voices.md
curl -s "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID?output_format=mp3_44100_128" \
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

`model_id` defaults to `eleven_multilingual_v2` if omitted.

**`voice_settings`** (all optional, applied only to this request — stored voice settings are used for
anything you omit):

| Field | Default | Effect |
|---|---|---|
| `stability` | 0.5 | Lower = broader emotional range and more variation between runs; higher = flatter, more repeatable |
| `similarity_boost` | 0.75 | How closely the model adheres to the original voice |
| `style` | 0 | Style exaggeration. Non-zero costs extra compute and latency |
| `use_speaker_boost` | true | Boosts similarity to the source speaker, slightly higher latency |
| `speed` | 1.0 | <1 slows delivery, >1 speeds it up |

**Other body fields worth knowing:**

- `language_code` (ISO 639-1) — enforces a language for the model and text normalization. **Ignored
  by `eleven_multilingual_v2`.**
- `seed` (0–4294967295) — best-effort determinism, not guaranteed.
- `pronunciation_dictionary_locators` — max 3, see `references/utilities.md`.
- `previous_text` / `next_text`, or `previous_request_ids` / `next_request_ids` (max 3 each) — keep
  prosody continuous when you split a long script into several requests. When both are sent, the
  `*_request_ids` form wins.
- `apply_text_normalization`: `auto` (default) | `on` | `off` — controls whether numbers, dates and
  abbreviations get spelled out.
- `apply_language_text_normalization` (default false) — currently Japanese only, and it **heavily
  increases latency**.
- `enable_logging: false` — zero-retention mode. Enterprise only, and it disables history and request
  stitching for that request.

`optimize_streaming_latency` and `use_pvc_as_ivc` are **deprecated** — do not use them in new code.

### Intelligent Model Selection: Quality vs Cost vs Speed

| Need | Recommended model | Credits / char | Latency | When to pick |
|---|---|---|---|---|
| **Lowest cost / Drafts / Multiple takes** | `eleven_flash_v2_5` | **0.5 credits (50% off)** | **~75 ms** | User asks for the cheapest option, multiple takes/variations to choose from, fast previews, or real-time voice bots (32 langs). |
| **Max expressiveness / Acting / 70+ langs** | `eleven_v3` | 1.0 credit | Normal | Emotional voiceover, storytelling, drama, character dialogue. Reads inline audio tags like `[whispering]`, `[laughs]`, `[excited]`. |
| **Long-form consistency / Audiobooks** | `eleven_multilingual_v2` | 1.0 credit | Normal | Audiobooks, corporate e-learning, long documents where cadence must stay strictly identical across chapters (29 langs). |

**Generating multiple takes (cheaply & quickly):**
When the user asks for multiple variations/takes to pick the best one, or asks for the cheapest option, naturally default to `eleven_flash_v2_5` to cut credit consumption in half:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"
for SEED in 101 202 303; do
  jq -n --arg t "Exploring multiple delivery takes for the narration." \
        --argjson s "$SEED" \
    '{text: $t, model_id: "eleven_flash_v2_5", seed: $s}' \
  | curl -s "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID" \
      -H "xi-api-key: $KEY" -H "Content-Type: application/json" -d @- \
      -o "/tmp/eleven-take-$SEED.mp3"
  file "/tmp/eleven-take-$SEED.mp3"
done
```

Move the chosen take to a real destination with a descriptive name once verified (e.g.
`public/audio/narration-01.mp3`).

### 1b. Convert with timestamps (word/character-level alignment)

`POST /v1/text-to-speech/{voice_id}/with-timestamps` — same body, but returns **JSON**, not binary:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"
curl -s "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID/with-timestamps" \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d @- > /tmp/eleven-tts-ts.json <<'EOF'
{ "text": "Timing matters for captions.", "model_id": "eleven_multilingual_v2" }
EOF
jq -r '.audio_base64' /tmp/eleven-tts-ts.json | base64 -d > /tmp/eleven-tts-ts.mp3
file /tmp/eleven-tts-ts.mp3
jq -r '(.alignment.characters // []) | join("")' /tmp/eleven-tts-ts.json   # sanity-check reconstructed text (alignment can be null)
```

Use `.alignment.character_start_times_seconds[]` / `.character_end_times_seconds[]` to build
subtitle/caption timing; `.normalized_alignment.*` gives the same for the post-normalization text
(numbers/dates expanded) — that is the one that matches what you actually hear.

### 1c. Stream

`POST /v1/text-to-speech/{voice_id}/stream` — same body. For low-latency playback pipelines:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"
curl -sN "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID/stream" \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"text":"Streaming audio chunk by chunk.","model_id":"eleven_flash_v2_5"}' \
  -o /tmp/eleven-stream.mp3
file /tmp/eleven-stream.mp3
```

`output_format` here accepts mp3/pcm/ulaw/alaw/opus but **not `wav_*`** (the non-streaming convert
endpoint does accept wav).

### 1d. Stream with timestamps

`POST /v1/text-to-speech/{voice_id}/stream/with-timestamps` — note the path is `/stream/with-timestamps`,
not `/stream-with-timestamps`. It streams newline-delimited JSON objects, each carrying an
`audio_base64` chunk plus its alignment. Use it when you need captions *and* early playback; if you
only need captions for a finished file, §1b is simpler.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"
curl -sN "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID/stream/with-timestamps" \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"text":"Captions while it streams.","model_id":"eleven_multilingual_v2"}' \
  > /tmp/eleven-stream-ts.ndjson
jq -rs 'map(.audio_base64) | join("")' /tmp/eleven-stream-ts.ndjson | base64 -d > /tmp/eleven-stream-ts.mp3
file /tmp/eleven-stream-ts.mp3
```

### 1e. WebSocket (not curl-friendly)

`/v1/text-to-speech/{voice_id}/stream-input` and `/multi-stream-input` exist for input-streaming
(feeding text in as an LLM produces it) and multi-context sessions. **These are WebSocket endpoints —
plain `curl` cannot drive them.** If the user genuinely needs input-streaming, point them at the
official SDK (`@elevenlabs/elevenlabs-js` or `elevenlabs` on PyPI) rather than improvising; every
other TTS need is covered by the HTTP endpoints above.

---

## 2. Text to Dialogue (multi-speaker conversation, one call)

`POST /v1/text-to-dialogue` — up to 10 unique voices. Keep the **total** text across all inputs at or
below ~2000 characters; longer requests can terminate early or 422. Returns raw binary audio.

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

`model_id` defaults to `eleven_v3`. Bracketed cues like `[amused]`, `[whispering]`, `[sighs]` are
plain text that `eleven_v3` interprets as delivery direction.

Optional: `settings.stability` (only `stability` is supported here — not the full TTS
`voice_settings` object), `seed`, `language_code`, `pronunciation_dictionary_locators`,
`apply_text_normalization`, `previous_text` / `future_text` (max 100 chars each for prosodic
continuity), and `previous_request_ids` / `next_request_ids` (max 3 each).

The same variants as TTS exist and take the same body — `POST /v1/text-to-dialogue/stream`,
`POST /v1/text-to-dialogue/with-timestamps` and `POST /v1/text-to-dialogue/stream/with-timestamps`,
plus WebSocket forms — and they behave exactly like §1b–1e.

---

## 3. Voice Changer (speech-to-speech conversion)

`POST /v1/speech-to-speech/{voice_id}` — multipart. Transforms an input recording into another voice
while keeping its emotion, timing and delivery. Because it is multipart, `voice_settings` must be a
**JSON-encoded string**, not a nested object:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"
curl -s "https://api.elevenlabs.io/v1/speech-to-speech/$VOICE_ID" \
  -H "xi-api-key: $KEY" \
  -F "audio=@/path/to/source-performance.mp3" \
  -F "model_id=eleven_multilingual_sts_v2" \
  -F 'voice_settings={"stability":0.5,"similarity_boost":0.8}' \
  -F "remove_background_noise=false" \
  -o /tmp/eleven-voice-changed.mp3
file /tmp/eleven-voice-changed.mp3
```

Models: `eleven_english_sts_v2` (default) or `eleven_multilingual_sts_v2`. Any model you pass must
have `can_do_voice_conversion: true` in `GET /v1/models`.

Other fields: `seed`, `file_format` (`other` default, or `pcm_s16le_16` for lower latency with raw
16-bit/16kHz mono PCM input), `remove_background_noise=true` to run audio isolation on the input
first (useful for noisy source recordings).

`POST /v1/speech-to-speech/{voice_id}/stream` is the streaming variant, same fields.
