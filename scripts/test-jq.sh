#!/usr/bin/env bash
# Tests every jq extraction expression used in skills/elevenlabs/ (SKILL.md + references/*.md)
# against mock responses matching the documented ElevenLabs API shapes, including error cases.
#
# The jq filters below are byte-identical to the ones in the skill. They are invoked through the `j`
# wrapper purely for portability: jq builds on Windows emit CRLF, which would otherwise leave stray
# CRs in multi-record output and fail these comparisons on a developer machine but not in CI.
set -euo pipefail
cd "$(mktemp -d)"
fail() { echo "FAIL: $1"; exit 1; }
j() { jq "$@" | tr -d '\r'; }
b64d() { tr -d '\r\n' | base64 -d; }

# ---------------------------------------------------------------- shared / errors

# standard 422 error shape: .detail[].msg
echo '{"detail":[{"loc":["body","text"],"msg":"field required","type":"missing"}]}' > err.json
[ "$(j -r '.detail[].msg' err.json)" = "field required" ] || fail err

# models list: .[] | select(.can_do_text_to_speech) | .model_id
cat > models.json <<'EOF'
[{"model_id":"eleven_multilingual_v2","can_do_text_to_speech":true,"can_do_voice_conversion":false},
 {"model_id":"eleven_multilingual_sts_v2","can_do_text_to_speech":false,"can_do_voice_conversion":true},
 {"model_id":"scribe_v2","can_do_text_to_speech":false,"can_do_voice_conversion":false}]
EOF
[ "$(j -r '.[] | select(.can_do_text_to_speech==true) | .model_id' models.json)" = "eleven_multilingual_v2" ] || fail models_tts
[ "$(j -r '.[] | select(.can_do_voice_conversion==true) | .model_id' models.json)" = "eleven_multilingual_sts_v2" ] || fail models_sts

# user subscription: quota fields
echo '{"character_count":1200,"character_limit":10000,"tier":"creator","status":"active"}' > sub.json
[ "$(j -r '"\(.character_count)/\(.character_limit) chars used, tier=\(.tier), status=\(.status)"' sub.json)" = "1200/10000 chars used, tier=creator, status=active" ] || fail sub

# ---------------------------------------------------------------- speech.md

# tts with-timestamps: .audio_base64 + alignment reconstruction
b64=$(printf 'hello' | base64)
echo "{\"audio_base64\":\"$b64\",\"alignment\":{\"characters\":[\"h\",\"e\",\"l\",\"l\",\"o\"],\"character_start_times_seconds\":[0,0.1,0.2,0.3,0.4],\"character_end_times_seconds\":[0.1,0.2,0.3,0.4,0.5]}}" > tts_ts.json
[ "$(j -r '.audio_base64' tts_ts.json | b64d)" = "hello" ] || fail tts_ts_audio
[ "$(j -r '(.alignment.characters // []) | join("")' tts_ts.json)" = "hello" ] || fail tts_ts_align
# alignment can legitimately be null — the // [] guard must survive that
echo '{"audio_base64":"QUJD","alignment":null}' > tts_ts_null.json
[ "$(j -r '(.alignment.characters // []) | join("")' tts_ts_null.json)" = "" ] || fail tts_ts_null

# stream-with-timestamps: ndjson chunks concatenated with -s
printf '{"audio_base64":"QUJD"}\n{"audio_base64":"REVG"}\n' > stream_ts.ndjson
[ "$(j -rs 'map(.audio_base64) | join("")' stream_ts.ndjson | b64d)" = "ABCDEF" ] || fail stream_ts

# ---------------------------------------------------------------- transcription.md

# speech-to-text: single-channel transcript, words with speaker_id
cat > stt.json <<'EOF'
{"language_code":"eng","text":"hello there","transcription_id":"tr_1","words":[{"text":"hello","start":0.0,"end":0.4,"type":"word","speaker_id":"speaker_0"},{"text":"there","start":0.5,"end":0.9,"type":"word","speaker_id":"speaker_0"}]}
EOF
[ "$(j -r '.text' stt.json)" = "hello there" ] || fail stt_text
[ "$(j -r '.words[] | "\(.start)-\(.end) [\(.speaker_id)] \(.text)"' stt.json | wc -l)" = "2" ] || fail stt_words

# speech-to-text additional_formats: pull the srt part out by requested_format
cat > stt_srt.json <<'EOF'
{"text":"hello there","additional_formats":[{"requested_format":"srt","file_extension":"srt","content_type":"application/x-subrip","is_base64_encoded":false,"content":"1\n00:00:00,000 --> 00:00:00,900\nhello there\n"},{"requested_format":"txt","file_extension":"txt","content_type":"text/plain","is_base64_encoded":false,"content":"hello there"}]}
EOF
[ "$(j -r '.additional_formats[] | select(.requested_format=="srt") | .content' stt_srt.json | head -1)" = "1" ] || fail stt_srt
# base64 formats must be distinguishable before writing them out
[ "$(j -r '.additional_formats[] | select(.requested_format=="srt") | .is_base64_encoded' stt_srt.json)" = "false" ] || fail stt_srt_b64

# forced alignment: words + loss
cat > align.json <<'EOF'
{"characters":[{"text":"h","start":0,"end":0.1}],"words":[{"text":"hello","start":0,"end":0.5,"loss":0.02}],"loss":0.03}
EOF
[ "$(j -r '.words[] | "\(.start)-\(.end)  \(.text)"' align.json)" = "0-0.5  hello" ] || fail align_words
[ "$(j -r '.loss' align.json)" = "0.03" ] || fail align_loss

# ---------------------------------------------------------------- music.md

# music: the song id arrives as a response *header*, not in the body
printf 'HTTP/2 200\r\ncontent-type: audio/mpeg\r\nsong-id: song_abc123\r\n\r\n' > music_headers.txt
[ "$(grep -i '^song-id:' music_headers.txt | tr -d '\r' | awk '{print $2}')" = "song_abc123" ] || fail music_song_id

# music/detailed metadata part (post multipart-split)
echo '{"song_metadata":{"title":"Retro Drive","genres":["synthwave"],"is_explicit":false}}' > music_meta.json
[ "$(j -r '.song_metadata.title, .song_metadata.genres[]' music_meta.json | tr '\n' ' ')" = "Retro Drive synthwave " ] || fail music_meta

# ---------------------------------------------------------------- voices.md

# voice design: previews list
cat > design.json <<'EOF'
{"previews":[{"generated_voice_id":"gv_abc123","audio_base_64":"QUJD","duration_secs":3.2},{"generated_voice_id":"gv_def456","audio_base_64":"WFla","duration_secs":2.9}],"text":"Sample preview text."}
EOF
[ "$(j -r '.previews[] | "\(.generated_voice_id)  \(.duration_secs)s"' design.json | wc -l)" = "2" ] || fail design_count
[ "$(j -r '.previews[0].audio_base_64' design.json | b64d)" = "ABC" ] || fail design_audio

# create voice from preview: .voice_id
echo '{"voice_id":"v_new123","name":"Narrator"}' > voice_created.json
[ "$(j -r '.voice_id' voice_created.json)" = "v_new123" ] || fail voice_created

# IVC create: .voice_id, .requires_verification
echo '{"voice_id":"v_ivc123","requires_verification":false}' > ivc.json
[ "$(j -r '.voice_id, .requires_verification' ivc.json | tr '\n' ' ')" = "v_ivc123 false " ] || fail ivc

# PVC create + samples upload (returns a bare array) + train
echo '{"voice_id":"v_pvc123"}' > pvc.json
[ "$(j -r '.voice_id' pvc.json)" = "v_pvc123" ] || fail pvc_create
cat > pvc_samples.json <<'EOF'
[{"sample_id":"s_1","file_name":"session-01.wav","duration_secs":63.5},{"sample_id":"s_2","file_name":"session-02.wav","duration_secs":58.0}]
EOF
[ "$(j -r '.[] | "\(.sample_id)  \(.file_name)  \(.duration_secs)s"' pvc_samples.json | wc -l)" = "2" ] || fail pvc_samples
echo '{"status":"ok"}' > pvc_train.json
[ "$(j -r '.status' pvc_train.json)" = "ok" ] || fail pvc_train

# PVC fine_tuning state polling target
echo '{"voice_id":"v_pvc123","fine_tuning":{"state":{"eleven_multilingual_v2":"fine_tuning"}}}' > pvc_status.json
[ "$(j '.fine_tuning.state' pvc_status.json)" = '{
  "eleven_multilingual_v2": "fine_tuning"
}' ] || fail pvc_state

# voices list (v2): .voices[] + token pagination
cat > voices.json <<'EOF'
{"voices":[{"voice_id":"v1","name":"Rachel","category":"premade"},{"voice_id":"v2","name":"Clone","category":"cloned"}],"has_more":true,"next_page_token":"tok_2","total_count":2}
EOF
[ "$(j -r '.voices[] | "\(.voice_id)  \(.name)  \(.category)"' voices.json | wc -l)" = "2" ] || fail voices_list
[ "$(j -r 'if .has_more then "more pages: pass next_page_token=\(.next_page_token)" else "end of list" end' voices.json)" = "more pages: pass next_page_token=tok_2" ] || fail voices_paging
echo '{"voices":[],"has_more":false,"next_page_token":null}' > voices_end.json
[ "$(j -r 'if .has_more then "more" else "end of list" end' voices_end.json)" = "end of list" ] || fail voices_paging_end

# shared voice library
cat > shared.json <<'EOF'
{"voices":[{"voice_id":"lib1","name":"Sam","accent":"american","gender":"male"}],"has_more":false}
EOF
[ "$(j -r '.voices[] | "\(.voice_id)  \(.name)  \(.accent // "")  \(.gender // "")"' shared.json)" = "lib1  Sam  american  male" ] || fail shared

# ---------------------------------------------------------------- dubbing.md (project API)

# submit: project_id + status
echo '{"project_id":"proj_abc","status":"queued","language_ids":[],"warnings":[]}' > dub_create.json
[ "$(j -r '"project_id=\(.project_id) status=\(.status)"' dub_create.json)" = "project_id=proj_abc status=queued" ] || fail dub_create

# project poll loop: transient states loop, terminal state breaks
cat > dub_project_ready.json <<'EOF'
{"project_id":"proj_abc","status":"ready","language_ids":["lang_1"],"error":null,"warnings":[{"type":"voices_not_permitted","speaker_ids":["speaker_1"],"message":"Voice cloning was not permitted for speaker speaker_1, so a replacement voice was used."}]}
EOF
n=0
mockproject() { n=$((n+1)); if [ "$n" -lt 3 ]; then echo '{"status":"processing"}'; else cat dub_project_ready.json; fi; }
STATUS=""
for _ in $(seq 1 9); do
  mockproject > dub_poll.json
  STATUS=$(j -r '.status' dub_poll.json)
  case "$STATUS" in queued|preparing|processing) continue ;; *) break ;; esac
done
[ "$STATUS" = "ready" ] || fail dub_project_poll
[ "$(j -r '.language_ids[]?' dub_project_ready.json)" = "lang_1" ] || fail dub_language_ids
[ -z "$(j -r '.error.error // empty' dub_project_ready.json)" ] || fail dub_project_error_null
[ "$(j -r '.warnings[]? | .message' dub_project_ready.json | wc -l)" = "1" ] || fail dub_warnings

# project failure surfaces .error.error (nested, unlike the legacy flat .error)
echo '{"status":"failed","error":{"message_type":"error","error":"source file unreadable"}}' > dub_project_failed.json
[ "$(j -r '.error.error // empty' dub_project_failed.json)" = "source file unreadable" ] || fail dub_project_error

# language target: status + signed output URL
cat > dub_lang_done.json <<'EOF'
{"language_id":"lang_1","project_id":"proj_abc","target_language":"es","status":"completed","revision":3,"output_revision":3,"outputs":{"lossless_audio":"https://storage.googleapis.com/eleven/out.flac?X-Goog-Signature=abc"}}
EOF
m=0
mocklang() { m=$((m+1)); if [ "$m" -lt 2 ]; then echo '{"status":"processing","outputs":null}'; else cat dub_lang_done.json; fi; }
STATUS=""
for _ in $(seq 1 9); do
  mocklang > dub_lang_poll.json
  STATUS=$(j -r '.status' dub_lang_poll.json)
  case "$STATUS" in queued|processing) continue ;; *) break ;; esac
done
[ "$STATUS" = "completed" ] || fail dub_lang_poll
URL=$(j -r '.outputs.lossless_audio' dub_lang_done.json)
[ -n "$URL" ] && [ "$URL" != "null" ] || fail dub_lang_url
# the "not ready yet" guard must reject a null outputs object
NOURL=$(j -r '.outputs.lossless_audio // "no output yet"' <<'EOF'
{"status":"processing","outputs":null}
EOF
)
[ "$NOURL" = "no output yet" ] || fail dub_lang_no_url
# stale detection: output_revision behind revision
echo '{"status":"stale","revision":5,"output_revision":3}' > dub_lang_stale.json
[ "$(j -r 'if .output_revision < .revision then "stale" else "current" end' dub_lang_stale.json)" = "stale" ] || fail dub_lang_stale

# ---------------------------------------------------------------- dubbing.md (legacy API)

echo '{"dubbing_id":"dub_abc123","expected_duration_sec":120}' > dub_submit.json
[ "$(j -r '"dubbing_id=\(.dubbing_id) expected_duration_sec=\(.expected_duration_sec)"' dub_submit.json)" = "dubbing_id=dub_abc123 expected_duration_sec=120" ] || fail dub_submit
echo '{"status":"dubbed","target_languages":["es"]}' > dub_done.json
k=0
mockfetch() { k=$((k+1)); if [ "$k" -lt 3 ]; then echo '{"status":"dubbing"}'; else cat dub_done.json; fi; }
STATUS=""
for _ in $(seq 1 9); do
  mockfetch > dub_poll_legacy.json
  STATUS=$(j -r '.status' dub_poll_legacy.json)
  case "$STATUS" in dubbing|pending|processing) continue ;; *) break ;; esac
done
[ "$STATUS" = "dubbed" ] || fail dub_poll_loop
echo '{"status":"failed","error":"source file unreadable"}' > dub_failed.json
[ "$(j -r '.error // empty' dub_failed.json)" = "source file unreadable" ] || fail dub_error
[ -z "$(j -r '.error // empty' dub_done.json)" ] || fail dub_error_null

# ---------------------------------------------------------------- utilities.md

# pronunciation dictionary: .id, .version_id
echo '{"id":"pd_123","name":"product-names","version_id":"ver_1","version_rules_num":2}' > dict.json
[ "$(j -r '.id, .version_id' dict.json | tr '\n' ' ')" = "pd_123 ver_1 " ] || fail dict

# history list + get-audio id
cat > history.json <<'EOF'
{"history":[{"history_item_id":"hi_1","date_unix":1720000000,"voice_name":"Rachel","text":"Hello world, this is a test."}],"has_more":false}
EOF
[ "$(j -r '.history[] | "\(.history_item_id)  \(.date_unix)  \(.voice_name // "")  \(.text // "" | .[0:60])"' history.json)" = "hi_1  1720000000  Rachel  Hello world, this is a test." ] || fail history

echo "ALL JQ / LOGIC TESTS PASSED"
