# Voices — design, cloning, management

Read this to create a voice from a description, clone a real voice, or find/inspect existing voices.
Conventions are in `SKILL.md`.

> **Consent is not optional.** Only clone or remix a voice you have the legal right to use — your own,
> a client's with documented consent, or a licensed Voice Library voice. Never a real person's voice
> without their consent. ElevenLabs enforces identity verification on some cloning flows
> (`requires_verification`); respect it rather than routing around it.

## 1. Voice Design (create a brand-new voice from a text description)

Two steps: **design** (or **remix**) produces previews with a `generated_voice_id` — nothing is saved
yet — then **create** persists the chosen preview as a real, usable voice.

### 1a. Design

`POST /v1/text-to-voice/design` — JSON, returns previews as base64 MP3. Does not save a voice.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/text-to-voice/design \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d @- > /tmp/eleven-design.json <<'EOF'
{
  "voice_description": "Warm, calm middle-aged British male narrator, gentle pacing, radio-documentary tone",
  "auto_generate_text": true,
  "model_id": "eleven_ttv_v3",
  "loudness": 0.5,
  "guidance_scale": 5
}
EOF
jq -r '.previews[] | "\(.generated_voice_id)  \(.duration_secs)s"' /tmp/eleven-design.json
jq -r '.previews[0].audio_base_64' /tmp/eleven-design.json | base64 -d > /tmp/eleven-design-preview.mp3
file /tmp/eleven-design-preview.mp3
```

Several previews come back. **Compare them before persisting one** — save each to a file and, at
minimum, check durations; don't blindly take `previews[0]`.

| Field | Notes |
|---|---|
| `voice_description` | Required. Longer, more specific descriptions work better |
| `auto_generate_text` | `true` lets the model write the preview script. Otherwise supply `text` (100–1000 chars) |
| `model_id` | `eleven_ttv_v3` (latest v3, highest quality, 70+ langs) or `eleven_multilingual_ttv_v2` (API default) |
| `guidance_scale` | Default 5. Lower = more creative freedom; too high sounds robotic. Prefer a long prompt at low guidance |
| `loudness` | -1 to 1, default 0.5 (≈ -24 LUFS) |
| `should_enhance` | Expands a short prompt into a richer description before generating. Useful when the user's brief is one line |
| `quality` | Higher = better output, less variety between previews |
| `seed` | Same seed + same inputs reproduces the same voice |
| `reference_audio_base64` + `prompt_strength` | Condition on a reference recording. **`eleven_ttv_v3` only.** `prompt_strength` 0 = follow the audio, 1 = follow the prompt |
| `stream_previews` | Returns ids only; fetch audio from `/v1/text-to-voice/{generated_voice_id}/stream` |

### 1b. Remix (evolve an existing voice by prompt)

`POST /v1/text-to-voice/{voice_id}/remix` — same idea applied to a voice you already have. Note
`guidance_scale` defaults to **2** here, not 5.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"
curl -s "https://api.elevenlabs.io/v1/text-to-voice/$VOICE_ID/remix" \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"voice_description":"Same voice but older, more gravelly, slower pace","auto_generate_text":true}' \
  > /tmp/eleven-remix.json
jq -r '.previews[].generated_voice_id' /tmp/eleven-remix.json
```

### 1c. Create (persist the chosen preview)

`POST /v1/text-to-voice` — no audio generation, just saves the pick.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
GENERATED_VOICE_ID="<paste generated_voice_id from 1a/1b>"
jq -n --arg name "Narrator - Warm British Male" \
      --arg desc "Warm, calm middle-aged British male narrator, gentle pacing" \
      --arg gid "$GENERATED_VOICE_ID" \
  '{voice_name:$name, voice_description:$desc, generated_voice_id:$gid}' \
| curl -s https://api.elevenlabs.io/v1/text-to-voice \
    -H "xi-api-key: $KEY" -H "Content-Type: application/json" -d @- \
  > /tmp/eleven-voice-created.json
jq -r '.voice_id' /tmp/eleven-voice-created.json
```

(Built with `jq -n --arg` rather than a heredoc so `$` or backticks in a user-supplied name cannot be
shell-expanded or break the JSON — same reasoning as convention #5 in `SKILL.md`.)

The returned `voice_id` works in every TTS, dialogue and voice-changer call.

---

## 2. Instant Voice Cloning (IVC)

`POST /v1/voices/add` — multipart, one or more clean recordings of the target voice. Fast, no
training step.

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

`remove_background_noise=true` runs audio isolation on the samples first — helpful for noisy
recordings, but it can *hurt* quality on already-clean studio audio, so don't set it reflexively.
`labels` accepts a map (`language`, `accent`, `gender`, `age`) that makes the voice findable later.

`requires_verification: true` means ElevenLabs needs additional identity verification before the
clone is fully usable — tell the user, don't work around it.

---

## 3. Professional Voice Cloning (PVC) — full API flow

Higher fidelity, requires training. **The entire pipeline is API-driven** — create the voice, upload
samples, train, poll.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
# Step 1 — create the voice shell
curl -s https://api.elevenlabs.io/v1/voices/pvc \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"name":"Pro Clone - Jane","language":"en"}' > /tmp/eleven-pvc.json
jq -r '.voice_id' /tmp/eleven-pvc.json
```

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="<paste voice_id from step 1>"
# Step 2 — upload training samples (repeat -F files=@ per file)
curl -s "https://api.elevenlabs.io/v1/voices/pvc/$VOICE_ID/samples" \
  -H "xi-api-key: $KEY" \
  -F "files=@/path/to/session-01.wav" \
  -F "files=@/path/to/session-02.wav" \
  -F "remove_background_noise=false" \
  > /tmp/eleven-pvc-samples.json
jq -r '.[] | "\(.sample_id)  \(.file_name)  \(.duration_secs)s"' /tmp/eleven-pvc-samples.json
```

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="<paste voice_id>"
# Step 3 — start training
curl -s "https://api.elevenlabs.io/v1/voices/pvc/$VOICE_ID/train" \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{}' > /tmp/eleven-pvc-train.json
jq -r '.status' /tmp/eleven-pvc-train.json   # "ok" = training started
```

`train` optionally takes `{"model_id":"..."}` to train against a specific model.

**Training is long-running** (one of the two true background jobs in this skill, along with dubbing).
There is no dedicated poll endpoint — read `.fine_tuning.state` from the voice, which is a per-model
map with values `not_started` | `queued` | `fine_tuning` | `fine_tuned` | `failed` | `delayed`:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="<paste voice_id>"
curl -s "https://api.elevenlabs.io/v1/voices/$VOICE_ID" -H "xi-api-key: $KEY" \
  | jq '.fine_tuning.state'
```

Other PVC endpoints, if the samples need work:

| Endpoint | Purpose |
|---|---|
| `GET /v1/voices/pvc/{voice_id}` | Read the PVC voice, including `fine_tuning.state` |
| `DELETE /v1/voices/pvc/{voice_id}/samples/{sample_id}` | Remove a sample |
| `GET /v1/voices/pvc/{voice_id}/samples/{sample_id}/audio` | Fetch a sample back |
| `GET /v1/voices/pvc/{voice_id}/samples/{sample_id}/waveform` | Sample waveform |
| `POST /v1/voices/pvc/{voice_id}/samples/{sample_id}/separate-speakers` | Split a multi-speaker recording |
| `GET /v1/voices/pvc/{voice_id}/samples/{sample_id}/speakers` | Speaker-separation status and results |
| `GET /v1/voices/pvc/{voice_id}/samples/{sample_id}/speakers/{speaker_id}/audio` | One separated speaker's audio |
| `POST /v1/voices/pvc/{voice_id}/verification` | Request manual identity verification |
| `GET /v1/voices/pvc/{voice_id}/captcha` | Verification captcha flow |

---

## 4. Voices management

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"

# List/search your voices (note: this one is /v2/, not /v1/)
curl -s "https://api.elevenlabs.io/v2/voices?page_size=20&voice_type=personal&search=narrator" \
  -H "xi-api-key: $KEY" > /tmp/eleven-voices.json
jq -r '.voices[] | "\(.voice_id)  \(.name)  \(.category)"' /tmp/eleven-voices.json
jq -r 'if .has_more then "more pages: pass next_page_token=\(.next_page_token)" else "end of list" end' /tmp/eleven-voices.json
```

The older `GET /v1/voices` still works but is superseded — it has no search, no filtering and no
token pagination. Use `/v2/voices`.

`GET /v2/voices` filters: `search` (name/description/labels/category), `voice_type`
(`personal`|`community`|`default`|`workspace`|`non-default`|`non-community`|`saved`), `category`
(`premade`|`cloned`|`generated`|`professional`), `fine_tuning_state`, `gender`, `age`, `accent`,
`language`, `use_cases`, `collection_id`, `voice_ids` (lookup up to 100), `sort` +
`sort_direction`, `page_size` (max 100). **Paginate with `next_page_token` + `has_more`**, not a page
index. `include_total_count=false` speeds up large listings.

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
VOICE_ID="21m00Tcm4TlvDq8ikWAM"

# Get one voice / its settings
curl -s "https://api.elevenlabs.io/v1/voices/$VOICE_ID" -H "xi-api-key: $KEY" | jq '{voice_id,name,category,settings}'
curl -s "https://api.elevenlabs.io/v1/voices/$VOICE_ID/settings" -H "xi-api-key: $KEY" | jq .

# Browse the shared Voice Library (prefer a licensed library voice over cloning)
curl -s "https://api.elevenlabs.io/v1/shared-voices?category=professional&language=en&page_size=10" \
  -H "xi-api-key: $KEY" | jq -r '.voices[] | "\(.voice_id)  \(.name)  \(.accent // "")  \(.gender // "")"'

# Delete a voice (irreversible — confirm with the user first)
# curl -s -X DELETE "https://api.elevenlabs.io/v1/voices/$VOICE_ID" -H "xi-api-key: $KEY" | jq .
```

Also available:

- `POST /v1/voices/add/{public_user_id}/{voice_id}` — add a shared library voice to your own
  collection under a `new_name`, so it gets a stable id you control.
- `POST /v1/similar-voices` — multipart `audio_file`, returns library voices that sound like the
  sample (`top_k` 1–100, `similarity_threshold` 0–2 where smaller is stricter). A good ethical
  alternative when a user wants "a voice like X": find a licensed match instead of cloning X.
- `POST /v1/voices/{voice_id}/settings/edit` — persist default settings on a voice.
- `POST /v1/voices/{voice_id}/edit` — rename a voice, change its labels, or add sample files.
- `GET /v1/voices/settings/default` — the platform default voice settings.
- `GET /v1/voices/accents` — the accent values the library and filters recognise.
- `GET|DELETE /v1/voices/{voice_id}/samples/{sample_id}` and
  `GET /v1/voices/{voice_id}/samples/{sample_id}/audio` — inspect or remove the samples behind a
  cloned voice.
- `POST /v1/text-to-voice/create-previews` and `GET /v1/text-to-voice/{generated_voice_id}/stream` —
  the older preview-generation endpoint and the streaming fetch used with `stream_previews` in §1a.
- `POST /v1/voices/{voice_id}/replicate-to-isolated-environment` — copy an IVC or designed voice to
  another workspace in the same billing group.
