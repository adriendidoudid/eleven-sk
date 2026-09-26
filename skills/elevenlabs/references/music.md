# Music & Sound Effects

Read this for Eleven Music (compose, score a video, separate stems) and for sound-effect generation.
Conventions are in `SKILL.md`.

## 1. Sound Effects

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

- `duration_seconds` must be `0.5`–`30`; omit it to let the model choose.
- `prompt_influence` 0–1 (default 0.3): higher sticks closer to the prompt with less variation.
- `loop: true` produces a seamless loop. Only `eleven_text_to_sound_v2` supports it — which is also
  the only value `model_id` accepts, so the default is already correct.

Sound effects are cheap and fast. When a brief is vague, generate two or three variations and let the
user pick rather than shipping the first take.

---

## 2. Music — compose from a prompt

`POST /v1/music` — returns raw binary audio. The generated **song id comes back in the `song-id`
response header**, not in the body, so capture headers with `-D` whenever you might want to reuse the
song later:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/music \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -D /tmp/eleven-music-headers.txt \
  -d @- -o /tmp/eleven-music.mp3 <<'EOF'
{
  "prompt": "Upbeat lo-fi hip hop, mellow piano chords, soft vinyl crackle, chill study-session vibe",
  "music_length_ms": 30000,
  "model_id": "music_v2_5",
  "store_for_inpainting": true
}
EOF
file /tmp/eleven-music.mp3
grep -i '^song-id:' /tmp/eleven-music-headers.txt
```

- `music_length_ms`: 3000–600000. Omit to let the model choose a length from the prompt.
- `model_id`: `music_v2_5` (flagship, studio-grade, superior vocal and acoustic realism — prefer it),
  `music_v2` (previous studio-grade), or `music_v1` (legacy, API default). `music_v2` and
  `music_v2_5` always enforce `composition_plan` section durations.
- `force_instrumental: true` guarantees no vocals. Only valid alongside `prompt`.
- `seed` gives more consistent re-runs but **cannot be combined with `prompt`** — it is for
  `composition_plan` generations only.
- `store_for_inpainting: true` is what makes the returned `song-id` reusable later for inpainting or
  as a conditioning reference. Without it the id is not retained.
- `sign_with_c2pa: true` embeds C2PA provenance (MP3 output only).
- `finetune_id` selects a custom music finetune (see §6).
- Query param `output_format` defaults to `auto`, which picks `mp3_44100_128` for v1 models and
  `mp3_48000_192` for v2/v2.5. Override only for a specific delivery target.

### Composition plans (per-section control)

`prompt` and `composition_plan` are **mutually exclusive**. A plan lets you specify styles, lyrics and
duration per section (3000–120000 ms each, ≤30 lines and ≤200 chars per line, up to 6,132 chars total).
Generate a starting plan from a prompt with:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/music/plan \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"prompt":"Cinematic trailer, slow build to a big drop","music_length_ms":45000,"model_id":"music_v2_5"}' \
  > /tmp/eleven-plan.json
jq . /tmp/eleven-plan.json
```

Then edit that JSON and send it back as `composition_plan`. (`respect_sections_durations: false`
lets `music_v1` bend individual section lengths for quality while preserving the total — it is
ignored by `music_v2` and `music_v2_5`.)

## 3. Music — compose with metadata

`POST /v1/music/detailed` — same body plus `"with_timestamps": true|false`. The response is
**`multipart/mixed`** (a JSON metadata part + a binary audio part), which `curl -o` alone cannot
split, so parse it with Python's `email` module:

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

If it ever comes back as a single JSON blob instead, fall back to
`jq -r '.audio' /tmp/eleven-music-detailed.raw | base64 -d > out.mp3`.

`POST /v1/music/stream` and `POST /v1/music/detailed/stream` are the streaming variants of §2 and §3.

## 4. Video to Music (score an existing video — long-running)

`POST /v1/music/video-to-music` — multipart, up to 10 video files (combined ≤ 200 MB, ≤ 600 s),
returns audio matching the video length. **Treat as long-running**: it analyses the video before
generating, so it will not return instantly.

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

A `403` here means "Subscription required" — this endpoint is tier-gated. Tell the user; do not retry.

This transforms/scores an existing video. It does **not** generate video — see `SKILL.md`.

## 5. Stem separation

`POST /v1/music/stem-separation` — multipart, slow on long files. Returns a **ZIP** of stems:

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

`stem_variation_id`: `two_stems_v1` (vocals/instrumental) or `six_stems_v1` (default —
vocals/drums/bass/guitar/piano/other).

## 6. Upload and finetunes

- `POST /v1/music/upload` — multipart `file`, brings an existing track into ElevenLabs. Optional
  `extract_composition_plan` (pass a model id, `music_v1`, `music_v2`, or `music_v2_5`; the boolean
  form is deprecated), `with_timestamps` for word-level lyric timings, `with_waveform_visual`. Each
  option adds latency.
- `GET|POST /v1/music/finetunes` and `GET|PATCH|DELETE /v1/music/finetunes/{finetune_id}` manage
  custom music finetunes. Pass the resulting id as `finetune_id` in §2. Only reach for these if the
  user explicitly asks for a trained/custom music model.
