#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"

output_dir="${1:-$performance_repo_root/.build/performance/fixtures}"
voice="${VOICE:-Samantha}"
rate="${RATE:-180}"
performance_prepare_output_dir "$output_dir" >/dev/null

performance_require_command say
performance_require_command afconvert

short_text='The quick brown fox crosses the quiet valley while a small clock marks the morning hour.'
medium_text='A careful performance test should be simple to repeat and easy to inspect. The speaker reads each sentence at a steady pace, with ordinary punctuation and familiar vocabulary. We measure model preparation separately from transcription, then compare the first run with later runs after the model is warm. Stable fixtures help reveal real changes in latency without confusing them with different words, microphones, or background noise. Every result includes the source hash, audio duration, selected model, and exact software environment.'
long_text="$medium_text $medium_text $medium_text"

printf 'name,voice,rate,duration_seconds,sample_rate,channels,sha256,text_sha256,path\n' > "$output_dir/fixtures.csv"

generate_fixture() {
  local name="$1"
  local text="$2"
  local text_path="$output_dir/$name.txt"
  local aiff_path="$output_dir/$name.aiff"
  local wav_path="$output_dir/$name.wav"

  printf '%s\n' "$text" > "$text_path"
  say -v "$voice" -r "$rate" -o "$aiff_path" -f "$text_path"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff_path" "$wav_path"

  local duration sample_rate channels audio_hash text_hash
  duration="$(afinfo "$wav_path" | awk -F': ' '/estimated duration/ { print $2; exit }' | awk '{ print $1 }')"
  sample_rate="$(afinfo "$wav_path" | awk '/Data format:/ { print $5; exit }')"
  channels="$(afinfo "$wav_path" | awk '/Data format:/ { print $3; exit }')"
  audio_hash="$(shasum -a 256 "$wav_path" | awk '{ print $1 }')"
  text_hash="$(shasum -a 256 "$text_path" | awk '{ print $1 }')"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$name" "$voice" "$rate" "$duration" "${sample_rate:-16000}" "${channels:-1}" \
    "$audio_hash" "$text_hash" "$wav_path" >> "$output_dir/fixtures.csv"
}

generate_fixture short "$short_text"
generate_fixture medium "$medium_text"
generate_fixture long "$long_text"

printf '[performance] fixtures generated at %s\n' "$output_dir"
