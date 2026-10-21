set shell := ["bash", "-euo", "pipefail", "-c"]

app := ".build/palantir.app"

build:
    swift build

# Every layer. The e2e tests launch palantir, which can take the front for about a second each, so
# a bare `swift test` runs every layer but e2e.
test:
    PALANTIR_TEST_LAYERS=unit,integration,e2e,release swift test

test-unit:
    PALANTIR_TEST_LAYERS=unit swift test

test-integration:
    PALANTIR_TEST_LAYERS=integration swift test

test-e2e:
    PALANTIR_TEST_LAYERS=e2e swift test

test-release:
    PALANTIR_TEST_LAYERS=release swift test

fmt:
    swift format --in-place --recursive --parallel Package.swift Sources Tests

lint:
    swift format lint --strict --recursive --parallel Package.swift Sources Tests

# Assemble an ad-hoc signed palantir.app from a SwiftPM build, at `out`.
bundle config="debug" out=app:
    swift build -c {{config}}
    rm -rf {{out}}
    mkdir -p {{out}}/Contents/MacOS
    cp "$(swift build -c {{config}} --show-bin-path)/palantir" {{out}}/Contents/MacOS/
    cp Sources/App/Info.plist {{out}}/Contents/
    codesign --force --sign - {{out}}

acceptance_cache := env("PALANTIR_ACCEPT_CACHE", ".build/acceptance")

# Build what the acceptance layer replays against: the CLIs, the runner, and a debug and a release
# palantir.app.
acceptance-build:
    swift build
    {{just_executable()}} bundle
    {{just_executable()}} bundle release {{acceptance_cache}}/release/palantir.app

# Replay the check of every rule against the debug build and print one verdict per rule ID. It
# launches palantir and drives it, so it takes the desktop for about 15 s a rule.
test-acceptance *args: acceptance-build
    "$(swift build --show-bin-path)/palantir-accept" replay --all {{args}}

# One line per rule: current, missing, stale, changed, ungated or orphan.
acceptance-status:
    swift build --product palantir-accept
    "$(swift build --show-bin-path)/palantir-accept" status

# Generate checks from the spec for the rules given, or for every missing and stale one. Replays run
# behind PALANTIR_ACCEPT_REPLAY_WRAPPER when it is set.
acceptance-generate *rules: acceptance-build
    "$(swift build --show-bin-path)/palantir-accept" generate {{rules}}

# Triage the failed replay in `replay` for `rule`, such as req~heading-folding.fold~1.
acceptance-triage rule replay:
    swift build --product palantir-accept
    "$(swift build --show-bin-path)/palantir-accept" triage {{rule}} --replay {{replay}}

# Probe a feature (or every feature) around its rules and report candidate spec changes. It fails
# nothing. Its probes launch palantir, so it takes the desktop for about 10 s a probe.
acceptance-explore feature="": acceptance-build
    "$(swift build --show-bin-path)/palantir-accept" explore {{feature}}

# Replay every check in a Tart VM, with no use of this Mac's desktop.
test-acceptance-vm *args: acceptance-build
    "$(swift build --show-bin-path)/palantir-accept" vm-replay {{args}}

run: bundle
    {{app}}/Contents/MacOS/palantir

# Launch a debug palantir.app in the background with the inspector listening, and print its pid
# once it answers. It does not take focus: palantir-drive borrows it for each input.
inspect:
    #!/usr/bin/env bash
    set -euo pipefail
    {{just_executable()}} bundle >&2
    bin="$(swift build --show-bin-path)"
    inspect="$bin/palantir-inspect"
    front_pid() { lsappinfo info -only pid "$(lsappinfo front)" | sed -n 's/.*pid = \([0-9]*\).*/\1/p'; }
    palantirs() { ps -axo pid=,comm= | awk '$2 ~ /\/palantir$/ { print $1 }'; }
    before="$("$inspect" list | cut -f1 | sort)"
    front="$(front_pid)"
    running="$(palantirs)"
    pid=""
    # open -g still lets a launch take the front now and then. On every exit, a launch that never
    # answered included, the palantir it started gives the front back if it holds it: the one
    # listening, or else one in front that was not running before.
    give_back() {
      local now
      now="$(front_pid)"
      [ -n "$front" ] && [ -n "$now" ] && [ "$now" != "$front" ] || return 0
      if [ "$now" = "$pid" ] || { ! grep -qx "$now" <<< "$running" && grep -qx "$now" <<< "$(palantirs)"; }; then
        "$bin/palantir-drive" --pid "$now" restore --to "$front"
      fi
    }
    trap 'status=$?; give_back || { echo "the front did not go back to pid $front" >&2; status=1; }; exit $status' EXIT
    open -g -n {{app}} --args --inspector
    for _ in $(seq 1 100); do
      pid="$(comm -13 <(echo "$before") <("$inspect" list | cut -f1 | sort) | head -1)"
      [ -n "$pid" ] && break
      sleep 0.1
    done
    [ -n "$pid" ] || { echo "no new palantir is listening" >&2; exit 1; }
    if ! "$inspect" --pid "$pid" wait --timeout 10 >/dev/null; then
      echo "$pid"
      echo "palantir $pid did not settle; terminating it" >&2
      kill "$pid"
      for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
      exit 1
    fi
    echo "$pid"
