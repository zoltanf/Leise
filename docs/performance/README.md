# Leise Performance Measurement Harness

The harness records raw evidence for the simplification plan. Run it from the
same commit, machine, power state, and app-data state for baseline and final
measurements. Do not compare a Debug baseline with a Release final result.

## Instrumentation

Debug builds emit stable `OSSignposter` Points of Interest under subsystem
`com.leise.mac`, category `Performance`. Release builds compile the wrapper to
no-ops. Current names are:

- `process_to_ui_ready`, `app_initialization`;
- `service_container_construction`, `service_container_initialization`;
- `hotkey_registration`, `hotkey_ready`, `ui_ready`;
- `built_in_component_construction`, `retained_store_opening`;
- `model_selection_restoration`, `model_preparation`;
- `audio_start`, `live_session_creation`, `final_transcription`;
- `post_processing`, `history_statistics_persistence`, `text_insertion`.

## Environment and builds

```sh
scripts/performance/capture-environment.sh .build/performance/baseline/environment
RUNS=3 scripts/performance/measure-builds.sh \
  --output .build/performance/baseline/builds
```

Package resolution is performed before timing. Clean-build timing excludes the
preceding `xcodebuild clean` action. Incremental timing touches only
`Leise/App/AppConstants.swift`; a temporary timestamp reference restores the
source modification time even if the script is interrupted.

The environment collector records power and thermal command output when macOS
provides it. Hardware serial numbers, UUIDs, and provisioning identifiers are
discarded.

## Warm launch and idle memory

Build Debug first, finish onboarding, unload Parakeet, quit the measured build,
then run:

```sh
scripts/performance/capture-launches.sh \
  --app .build/DerivedData-Performance/Build/Products/Debug/Leise.app \
  --runs 7 \
  --output .build/performance/baseline/warm-launch
```

Each launch produces untouched unified-log JSON, normalized signpost CSV, app
stdout/stderr, and a 10 Hz RSS CSV. The script terminates only the process it
launches. Run no other Debug Leise build while capturing because both builds use
the same signpost subsystem.

## Deterministic transcription fixtures

Generate the short, medium, and long fixtures locally:

```sh
scripts/performance/generate-fixtures.sh .build/performance/fixtures
```

The generator uses the macOS `Samantha` voice at rate 180 and converts its
output to 16 kHz mono PCM. It writes source text, duration, audio and text
SHA-256 hashes to `fixtures.csv`. Regenerate twice and compare hashes before
using a newly generated set as a comparison baseline.

The Debug app contains an environment-triggered, headless fixture runner. The
collector snapshots and restores the `com.leise.mac` preferences domain,
selects the requested downloaded Parakeet model before engine preparation,
disables vocabulary boosting, captures 10 Hz RSS and signposts, and exits after
the requested runs. It refuses to run while another Leise process exists.

Measure first use with seven independent model-unloaded processes:

```sh
scripts/performance/capture-fixture-scenario.sh \
  --app .build/DerivedData-Performance/Build/Products/Debug/Leise.app \
  --fixture .build/performance/fixtures/short.wav \
  --model parakeet-tdt-0.6b-v3 \
  --scenario first-use-short-v3 \
  --instances 7 \
  --runs-per-instance 1 \
  --output .build/performance/baseline/first-use-short-v3
```

Measure steady state in one process, excluding the model-loading first run:

```sh
scripts/performance/capture-fixture-scenario.sh \
  --app .build/DerivedData-Performance/Build/Products/Debug/Leise.app \
  --fixture .build/performance/fixtures/short.wav \
  --model parakeet-tdt-0.6b-v3 \
  --scenario steady-short-v3 \
  --instances 1 \
  --runs-per-instance 8 \
  --exclude-run-one \
  --output .build/performance/baseline/steady-short-v3
```

Repeat the steady command with the medium and long fixtures. Repeat first use
with `parakeet-tdt-0.6b-v2` so model-load latency and memory remain covered for
both retained models. A one-time Core ML compiler-cache warm-up must be excluded
and documented; otherwise the cache condition is not comparable.

The runner measures file loading, model preparation, local transcription, and
normalization. It does not include microphone capture, filler cleanup, history
persistence, or Accessibility insertion. Use the interactive recorder below
when those end-to-end stages are the subject of a measurement.

## Interactive dictation scenarios

Launch the exact Debug app executable and obtain its PID. Start the recorder,
then immediately perform one documented action:

```sh
scripts/performance/capture-running-scenario.sh \
  --pid 12345 \
  --scenario first-dictation-short \
  --duration 60 \
  --output .build/performance/baseline/first-dictation-short-run-01
```

Use interactive captures for microphone-to-insertion checks or for a signpost
stage the headless runner does not exercise. For model memory, record an idle
window, then start a `model-load-v2` or `model-load-v3` window immediately before
pressing Load. The RSS time series preserves both settled and peak samples.

## Cold launch

Cold-launch numbers are valid only after documenting and repeating one cache
condition, such as a reboot followed by a fixed wait and no prior Leise launch.
The harness deliberately does not purge system caches. If that condition cannot
be reproduced, report warm launch only and make no cold-launch claim.
