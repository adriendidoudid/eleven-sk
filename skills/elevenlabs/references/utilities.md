# Utilities — audio isolation, pronunciation, history, formats

Smaller endpoints plus the shared reference tables. Conventions are in `SKILL.md`.

## 1. Audio Isolation (remove background noise / isolate speech)

`POST /v1/audio-isolation` — multipart. **The documented response schema is still an empty
placeholder (`{}`)** even though this is an audio-transform endpoint, so treat the response as
unconfirmed binary-or-JSON and check both:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/audio-isolation \
  -H "xi-api-key: $KEY" \
  -F "audio=@/path/to/noisy-recording.mp3" \
  -o /tmp/eleven-isolated.out
file /tmp/eleven-isolated.out
# if `file` reports audio data, rename with the right extension:
# mv /tmp/eleven-isolated.out /tmp/eleven-isolated.mp3
# if `file` reports JSON/ASCII text instead, inspect it:
# jq . /tmp/eleven-isolated.out
```

Optional `file_format=pcm_s16le_16` (raw 16-bit/16 kHz mono PCM input, lower latency).
`POST /v1/audio-isolation/stream` streams the result back instead.

Past isolations: `GET /v1/audio-isolation/history`, and
`DELETE /v1/audio-isolation/history/{history_item_id}` to remove one.

---

## 2. Pronunciation Dictionaries

Fix mispronounced names, jargon and product terms before they reach TTS.

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

Two rule types: `alias` (respell the word in plain text — works with every model, start here) and
`phoneme` (`ipa` or `cmu` alphabet — precise, but silently ignored by some models). Prefer `alias`
unless the user needs exact phonetics.

Reference the resulting `id` as `pronunciation_dictionary_id` plus `version_id` in any TTS or dialogue
call's `pronunciation_dictionary_locators` (**max 3 per request**, applied in order). Omitting
`version_id` uses the latest version.

Managing dictionaries:

| Endpoint | Purpose |
|---|---|
| `GET /v1/pronunciation-dictionaries` | List (`cursor` + `page_size` pagination, `sort`, `include_archived`) |
| `GET|PATCH /v1/pronunciation-dictionaries/{id}` | Read / rename an existing dictionary |
| `POST /v1/pronunciation-dictionaries/add-from-file` | Create from a `.pls` lexicon file |
| `POST /v1/pronunciation-dictionaries/{id}/add-rules` | Add rules (same `string_to_replace` replaces the old rule) |
| `POST /v1/pronunciation-dictionaries/{id}/remove-rules` | Remove rules by `string_to_replace` |
| `POST /v1/pronunciation-dictionaries/{id}/set-rules` | Replace the whole rule set |
| `GET /v1/pronunciation-dictionaries/{dictionary_id}/{version_id}/download` | Download a version as PLS |

Each mutation creates a **new `version_id`** — re-read it and update your locators, or generations
will keep using the old rules.

---

## 3. History (past generations)

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s "https://api.elevenlabs.io/v1/history?page_size=20" -H "xi-api-key: $KEY" > /tmp/eleven-history.json
jq -r '.history[] | "\(.history_item_id)  \(.date_unix)  \(.voice_name // "")  \(.text // "" | .[0:60])"' /tmp/eleven-history.json

# re-download one past generation
HISTORY_ITEM_ID="<paste history_item_id>"
curl -s "https://api.elevenlabs.io/v1/history/$HISTORY_ITEM_ID/audio" -H "xi-api-key: $KEY" -o /tmp/eleven-history-item.mp3
file /tmp/eleven-history-item.mp3
```

Bulk download — one id returns a single audio file, several return a **ZIP**:

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
curl -s https://api.elevenlabs.io/v1/history/download \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"history_item_ids":["hi_1","hi_2"],"output_format":"wav"}' \
  -o /tmp/eleven-history-bulk.zip
file /tmp/eleven-history-bulk.zip
```

`DELETE /v1/history/{history_item_id}` removes an item permanently — confirm with the user first.

History is unavailable for requests made with `enable_logging: false` (zero-retention mode).

---

## 4. Output formats

`output_format` is a **query parameter**, written `codec_samplerate_bitrate`. Default is
`mp3_44100_128` everywhere except `/v1/music`, where it is `auto` (which resolves to `mp3_44100_128`
for `music_v1` and `mp3_48000_192` for `music_v2`).

| Family | Values | Notes |
|---|---|---|
| MP3 | `mp3_22050_32`, `mp3_24000_48`, `mp3_44100_32/64/96/128/192` | `mp3_44100_192` needs **Creator tier+** |
| PCM | `pcm_8000/16000/22050/24000/32000/44100/48000` | `pcm_44100`+ needs **Pro tier+** |
| WAV | `wav_8000` … `wav_48000` | **Not available on streaming endpoints** |
| Opus | `opus_48000_32/64/96/128/192` | |
| Telephony | `ulaw_8000`, `alaw_8000` | μ-law is what Twilio expects |

Music additionally offers `mp3_48000_128/192/240/320`.

Tier-gated formats fail with a `403`/`422` rather than silently downgrading — if a format is refused,
fall back to `mp3_44100_128` and tell the user why.

---

## 5. Account, models and regions

```bash
KEY="${ELEVENLABS_API_KEY:-$ELEVEN_API_KEY}"
# Live model catalogue — authoritative, use it when a model_id is rejected
curl -s https://api.elevenlabs.io/v1/models -H "xi-api-key: $KEY" > /tmp/eleven-models.json
jq -r '.[] | select(.can_do_text_to_speech==true) | .model_id' /tmp/eleven-models.json
jq -r '.[] | select(.can_do_voice_conversion==true) | .model_id' /tmp/eleven-models.json

# Quota / tier
curl -s https://api.elevenlabs.io/v1/user/subscription -H "xi-api-key: $KEY" > /tmp/eleven-sub.json
jq -r '"\(.character_count)/\(.character_limit) chars used, tier=\(.tier), status=\(.status)"' /tmp/eleven-sub.json

# Account info (workspace, xi_api_key metadata)
curl -s https://api.elevenlabs.io/v1/user -H "xi-api-key: $KEY" | jq '{subscription_tier: .subscription.tier}'
```

**Data residency.** Every endpoint in this skill is also served from regional bases — same paths, only
the host changes. Swap the host only when the user asks for a specific region:

- `https://api.us.elevenlabs.io`
- `https://api.eu.residency.elevenlabs.io`
- `https://api.in.residency.elevenlabs.io`
- `https://api.sg.residency.elevenlabs.io`
