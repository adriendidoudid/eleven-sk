#!/usr/bin/env bash
# Tests every jq extraction expression used in skills/elevenlabs/SKILL.md against
# mock responses matching the documented ElevenLabs API shapes, including error cases.
set -euo pipefail
cd "$(mktemp -d)"
fail() { echo "FAIL: $1"; exit 1; }

# standard 422 error shape: .detail[].msg
echo '{"detail":[{"loc":["body","text"],"msg":"field required","type":"missing"}]}' > err.json
[ "$(jq -r '.detail[].msg' err.json)" = "field required" ] || fail err

# models list: .[] | select(.can_do_text_to_speech) | .model_id
echo '[{"model_id":"eleven_multilingual_v2","can_do_text_to_speech":true},{"model_id":"scribe_v2","can_do_text_to_speech":false}]' > models.json
[ "$(jq -r '.[] | select(.can_do_text_to_speech==true) | .model_id' models.json)" = "eleven_multilingual_v2" ] || fail models

# user subscription: quota fields
echo '{"character_count":1200,"character_limit":10000,"tier":"creator","status":"active"}' > sub.json
[ "$(jq -r '"\(.character_count)/\(.character_limit) chars used, tier=\(.tier), status=\(.status)"' sub.json)" = "1200/10000 chars used, tier=creator, status=active" ] || fail sub

# tts with-timestamps: .audio_base64 + alignment reconstruction
b64=$(printf 'hello' | base64)
echo "{\"audio_base64\":\"$b64\",\"alignment\":{\"characters\":[\"h\",\"e\",\"l\",\"l\",\"o\"],\"character_start_times_seconds\":[0,0.1,0.2,0.3,0.4],\"character_end_times_seconds\":[0.1,0.2,0.3,0.4,0.5]}}" > tts_ts.json
[ "$(jq -r '.audio_base64' tts_ts.json | base64 -d)" = "hello" ] || fail tts_ts_audio
[ "$(jq -r '.alignment.characters | join("")' tts_ts.json)" = "hello" ] || fail tts_ts_align

# speech-to-text: single-channel transcript, words with speaker_id
cat > stt.json <<'EOF'
{"language_code":"eng","text":"hello there","words":[{"text":"hello","start":0.0,"end":0.4,"type":"word","speaker_id":"speaker_0"},{"text":"there","start":0.5,"end":0.9,"type":"word","speaker_id":"speaker_0"}]}
EOF
[ "$(jq -r '.text' stt.json)" = "hello there" ] || fail stt_text
[ "$(jq -r '.words[] | "\(.start)-\(.end) [\(.speaker_id)] \(.text)"' stt.json | wc -l)" = "2" ] || fail stt_words

# sound-effects / music / tts convert / voice-changer / dialogue: binary passthrough
# (no jq involved — `file` is used, which we can't meaningfully mock here; just confirm
# the command shape doesn't rely on jq for these binary endpoints)

# voice design: previews list
cat > design.json <<'EOF'
{"previews":[{"generated_voice_id":"gv_abc123","audio_base_64":"QUJD","duration_secs":3.2},{"generated_voice_id":"gv_def456","audio_base_64":"WFla","duration_secs":2.9}],"text":"Sample preview text."}
EOF
[ "$(jq -r '.previews[] | .generated_voice_id' design.json | wc -l)" = "2" ] || fail design_count
[ "$(jq -r '.previews[0].audio_base_64' design.json | base64 -d)" = "ABC" ] || fail design_audio

# create voice from preview: .voice_id
echo '{"voice_id":"v_new123","name":"Narrator"}' > voice_created.json
[ "$(jq -r '.voice_id' voice_created.json)" = "v_new123" ] || fail voice_created

# IVC create: .voice_id, .requires_verification
echo '{"voice_id":"v_ivc123","requires_verification":false}' > ivc.json
[ "$(jq -r '.voice_id, .requires_verification' ivc.json | tr '\n' ' ')" = "v_ivc123 false " ] || fail ivc

# PVC create + train
echo '{"voice_id":"v_pvc123"}' > pvc.json
[ "$(jq -r '.voice_id' pvc.json)" = "v_pvc123" ] || fail pvc_create
echo '{"status":"ok"}' > pvc_train.json
[ "$(jq -r '.status' pvc_train.json)" = "ok" ] || fail pvc_train

# PVC fine_tuning state polling target
echo '{"voice_id":"v_pvc123","fine_tuning":{"state":{"eleven_multilingual_v2":"fine_tuning"}}}' > pvc_status.json
[ "$(jq '.fine_tuning.state' pvc_status.json)" = '{
  "eleven_multilingual_v2": "fine_tuning"
}' ] || fail pvc_state

# voices list (v2): .voices[] + has_more
cat > voices.json <<'EOF'
{"voices":[{"voice_id":"v1","name":"Rachel","category":"premade"},{"voice_id":"v2","name":"Clone","category":"cloned"}],"has_more":false,"total_count":2}
EOF
[ "$(jq -r '.voices[] | "\(.voice_id)  \(.name)  \(.category)"' voices.json | wc -l)" = "2" ] || fail voices_list

# shared voice library
cat > shared.json <<'EOF'
{"voices":[{"voice_id":"lib1","name":"Sam","accent":"american","gender":"male"}],"has_more":false}
EOF
[ "$(jq -r '.voices[] | "\(.voice_id)  \(.name)  \(.accent // "")  \(.gender // "")"' shared.json)" = "lib1  Sam  american  male" ] || fail shared

# dubbing: submit id + expected duration
echo '{"dubbing_id":"dub_abc123","expected_duration_sec":120}' > dub_submit.json
[ "$(jq -r '"dubbing_id=\(.dubbing_id) expected_duration_sec=\(.expected_duration_sec)"' dub_submit.json)" = "dubbing_id=dub_abc123 expected_duration_sec=120" ] || fail dub_submit

# dubbing: poll loop logic (pending-like states loop, terminal state breaks)
echo '{"status":"dubbed","target_languages":["es"]}' > dub_done.json
n=0
mockfetch() { n=$((n+1)); if [ "$n" -lt 3 ]; then echo '{"status":"dubbing"}'; else cat dub_done.json; fi; }
STATUS=""
for _ in $(seq 1 9); do
  mockfetch > dub_poll.json
  STATUS=$(jq -r '.status' dub_poll.json)
  case "$STATUS" in dubbing|pending|processing) continue ;; *) break ;; esac
done
[ "$STATUS" = "dubbed" ] || fail dub_poll_loop

# dubbing: error field surfaced on failure
echo '{"status":"failed","error":"source file unreadable"}' > dub_failed.json
[ "$(jq -r '.error // empty' dub_failed.json)" = "source file unreadable" ] || fail dub_error
[ -z "$(jq -r '.error // empty' dub_done.json)" ] || fail dub_error_null

# forced alignment: words + loss
cat > align.json <<'EOF'
{"characters":[{"text":"h","start":0,"end":0.1}],"words":[{"text":"hello","start":0,"end":0.5,"loss":0.02}],"loss":0.03}
EOF
[ "$(jq -r '.words[] | "\(.start)-\(.end)  \(.text)"' align.json)" = "0-0.5  hello" ] || fail align_words
[ "$(jq -r '.loss' align.json)" = "0.03" ] || fail align_loss

# pronunciation dictionary: .id, .version_id
echo '{"id":"pd_123","name":"product-names","version_id":"ver_1","version_rules_num":2}' > dict.json
[ "$(jq -r '.id, .version_id' dict.json | tr '\n' ' ')" = "pd_123 ver_1 " ] || fail dict

# history list + get-audio id
cat > history.json <<'EOF'
{"history":[{"history_item_id":"hi_1","date_unix":1720000000,"voice_name":"Rachel","text":"Hello world, this is a test."}],"has_more":false}
EOF
[ "$(jq -r '.history[] | "\(.history_item_id)  \(.date_unix)  \(.voice_name // "")  \(.text // "" | .[0:60])"' history.json)" = "hi_1  1720000000  Rachel  Hello world, this is a test." ] || fail history

# music/detailed metadata part (post multipart-split)
echo '{"song_metadata":{"title":"Retro Drive","genres":["synthwave"],"is_explicit":false}}' > music_meta.json
[ "$(jq -r '.song_metadata.title, .song_metadata.genres[]' music_meta.json | tr '\n' ' ')" = "Retro Drive synthwave " ] || fail music_meta

echo "ALL JQ / LOGIC TESTS PASSED"
