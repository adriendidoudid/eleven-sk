<p align="center">
  <img src="banner.jpg" alt="eleven-sk — Agent skill for elevenlabs.io">
</p>

<p align="center">
  <a href="https://github.com/adriendidoudid/eleven-sk/actions/workflows/validate.yml"><img alt="validate" src="https://img.shields.io/github/actions/workflow/status/adriendidoudid/eleven-sk/validate.yml?branch=main&style=flat-square&label=validate&labelColor=2b2b2b&color=6e6e6e"></a>
  <a href="LICENSE"><img alt="license MIT" src="https://img.shields.io/badge/license-MIT-6e6e6e?style=flat-square&labelColor=2b2b2b"></a>
  <a href="https://agentskills.io"><img alt="Agent Skills standard" src="https://img.shields.io/badge/spec-Agent%20Skills-6e6e6e?style=flat-square&labelColor=2b2b2b"></a>
</p>

<p align="center">
  The ElevenLabs API as a portable agent skill.<br>
  Plain <code>curl</code> and <code>jq</code> — no SDK, no dependencies in your project.
</p>

---

Written against the open [Agent Skills](https://agentskills.io) standard, so it works with **any coding agent that reads skills**: Claude Code, Cursor, Codex, Gemini CLI, opencode, Amp, and others. The instructions assume no harness-specific tools.

Every endpoint and model id below is verified against ElevenLabs' live [OpenAPI document](https://api.elevenlabs.io/openapi.json) in CI, on every push and weekly.

## Capabilities

| Capability | Endpoints | Notes |
|---|---|---|
| Text to speech | `/v1/text-to-speech/{voice_id}` + `/with-timestamps`, `/stream`, `/stream/with-timestamps` | `eleven_multilingual_v2`, `eleven_v3`, `eleven_flash_v2_5` |
| Text to dialogue | `/v1/text-to-dialogue` + 3 variants | Multi-speaker in one call, `eleven_v3` |
| Speech to text | `/v1/speech-to-text` + `/transcripts/{id}` | `scribe_v2`, diarization, SRT export, YouTube/TikTok URLs |
| Sound effects | `/v1/sound-generation` | 0.5–30 s, seamless looping |
| Music | `/v1/music` + `/detailed`, `/stream`, `/plan`, `/video-to-music`, `/stem-separation`, `/upload`, `/finetunes` | `music_v1`/`music_v2`, composition plans, inpainting |
| Voice changer | `/v1/speech-to-speech/{voice_id}` + `/stream` | Preserves emotion and timing |
| Voice design and cloning | `/v1/text-to-voice/*`, `/v1/voices/add`, `/v1/voices/pvc/*` | Design, remix, instant and fully API-driven professional cloning |
| Voice discovery | `/v2/voices`, `/v1/shared-voices`, `/v1/similar-voices` | Search and filter, licensed library, find a similar voice |
| Audio isolation | `/v1/audio-isolation` + `/stream`, `/history` | Background noise removal |
| Dubbing | `/v1/dubbing/project/*` | Async. Per-language targets, transcript editing |
| Forced alignment | `/v1/forced-alignment` | Timestamp an existing transcript |
| Pronunciation dictionaries | `/v1/pronunciation-dictionaries/*` | Fix mispronunciations, full CRUD |
| History | `/v1/history/*` | Re-download or bulk-export past generations |

### Out of scope, deliberately

**No text-to-image or text-to-video generation.** ElevenLabs' public API offers neither — that lives only in the closed ElevenCreative web app and an enterprise-gated Studio API. The skill says so plainly instead of inventing an endpoint, and points at the two capabilities that do touch existing video: Dubbing and Video-to-Music, both handled as long-running background jobs.

**ElevenAgents** (conversational AI, phone numbers, batch calling) is a large separate surface. The skill declines it rather than guessing at those endpoints.

## Requirements

- An ElevenLabs API key from [elevenlabs.io/app/settings/api-keys](https://elevenlabs.io/app/settings/api-keys)
- `curl` and `jq` on your PATH
- Optional: `python3` for the `multipart/mixed` response from `/v1/music/detailed`, and `ffmpeg` to remux a dubbed audio track back into a video

Export the key, and add it to `~/.bashrc` or `~/.zshrc` to make it permanent:

```bash
export ELEVENLABS_API_KEY="..."
```

`ELEVEN_API_KEY` works as a fallback.

## Install

```bash
npx skills add adriendidoudid/eleven-sk
```

The installer asks which agent to install into and handles that agent's skills directory for you. Choose the **global** install so the skill is available in every project. Re-run the same command to update.

<details>
<summary>Manual install</summary>

Copy the skill into your agent's skills folder — Claude Code shown, other agents have their own equivalent directory:

```bash
git clone https://github.com/adriendidoudid/eleven-sk
mkdir -p ~/.claude/skills
cp -R eleven-sk/skills/elevenlabs ~/.claude/skills/elevenlabs
```

Copy the whole `elevenlabs/` directory, not just `SKILL.md`. The `references/` files beside it are what the agent loads for anything past the common recipes.

</details>

## Usage

Ask naturally in any project — the agent picks up the skill on its own. Prompts work in any language, since the triggers are semantic.

**Voiceover**

> Generate a voiceover for this landing page's hero text using ElevenLabs, warm and confident tone, and save it as `public/audio/hero.mp3`.

**Sound effect**

> Generate a 3-second "sword unsheathing" sound effect with ElevenLabs for the game's UI.

**Transcription**

> Transcribe this interview recording with ElevenLabs, with speaker labels, and give me a clean text summary per speaker.

**Dubbing**

> Dub `demo.mp4` into Spanish with ElevenLabs and save the result — this can take a few minutes, so treat it as background work and let me know when it's ready.

<details>
<summary>More example prompts</summary>

**Music**

> Compose a 30-second upbeat lo-fi background track with ElevenLabs for this app's loading screen.

**Voice design**

> Design a calm, older female narrator voice with ElevenLabs, generate a couple of previews, and use the best one for the audiobook intro.

**Voice cloning**

> Clone my voice from `samples/me-1.mp3` and `samples/me-2.mp3` with ElevenLabs so I can use it for future narration.

**Voice changer**

> Take this scratch VO take and re-voice it with ElevenLabs voice X, keeping the same delivery and timing.

**Subtitles**

> Transcribe `talk.mp4` with ElevenLabs and give me an SRT file with speaker labels.

</details>

## How the skill is structured

The skill follows the standard's [progressive disclosure](https://agentskills.io/specification#progressive-disclosure) model. The agent always loads `SKILL.md` (~3k tokens), then pulls in the single reference file the task calls for — rather than paying for every endpoint up front.

```
skills/elevenlabs/
  SKILL.md                   always loaded: conventions, models, routing, 3 common recipes
  references/
    speech.md                TTS (all variants), dialogue, voice changer
    transcription.md         speech to text, subtitles, forced alignment
    music.md                 music, composition plans, stems, sound effects
    voices.md                design, remix, IVC and PVC cloning, discovery
    dubbing.md               project API (current) and legacy API
    utilities.md             isolation, pronunciation, history, output formats

scripts/
  validate.py                spec conformance, bash and JSON syntax, references
  test-jq.sh                 jq expressions against mock API responses
  check-api-drift.py         the skill against the live ElevenLabs OpenAPI spec

.github/workflows/           validate and drift on push and PR, drift weekly, optional live smoke
```

## Testing and CI

`npx skills add` installs straight from this repo's default branch, so **every push to `main` is immediately live** for new installs — there is no separate publish step. Three checks protect that:

- **`scripts/validate.py`** — frontmatter against the Agent Skills spec, `bash -n` on every snippet, JSON validity of every payload (heredoc and inline), Python syntax of embedded blocks, existence of every referenced file, no leaked API keys, and the `SKILL.md` size budget.
- **`scripts/test-jq.sh`** — every `jq` extraction tested against mock ElevenLabs responses, including error shapes, `null` guards and both dubbing poll loops.
- **`scripts/check-api-drift.py`** — compares every endpoint path and model id the skill documents against the live OpenAPI document, and lists API surface not yet covered.

The drift check also runs **weekly**, so an endpoint that moves or a model that gets retired shows up as a failed build instead of a broken skill in someone's editor. The skill records its last verification date in `metadata.api-verified`.

An optional `live-smoke` job (manual trigger, needs an `ELEVENLABS_API_KEY` repo secret) pings the real models endpoint and diffs your account's live catalogue against the skill.

Run everything locally before pushing:

```bash
python3 scripts/validate.py && bash scripts/test-jq.sh && python3 scripts/check-api-drift.py
```

## Cost and quota

Pricing is credit-based and changes over time — check [elevenlabs.io/pricing](https://elevenlabs.io/pricing) for current rates. The skill includes a quota check (`GET /v1/user/subscription`) to read remaining characters and credits before large jobs.

It also flags the options that silently cost more, so an agent does not enable them by reflex: speech-to-text `entity_detection` and `entity_redaction` (+30% each), `keyterms` (+20%), and `use_multi_channel` (each channel billed at the full audio duration).

## License

[MIT](LICENSE)
