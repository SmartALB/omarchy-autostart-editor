#!/usr/bin/env bash
# Binds the F1 fix (runnerOut/runnerErr must surface the producer's real
# exit status, and must not report a truncated-but-not-failed producer as a
# failure) to the actual characters in Runners.qml.
#
# Quickshell.Io does not exist outside the Quickshell runtime, so runnerOut()
# and runnerErr() cannot be called directly. extract-runner-shape.py
# tokenizes the real `return root.runner(...)` expression out of Runners.qml
# and splices in a real test command; this script runs the result through a
# real /usr/bin/bash and checks the exit code. A mutation to Runners.qml that
# removes the PIPESTATUS/$? recovery, or the 141-is-not-a-failure guard,
# changes what gets executed here -- this is not a hand-copied mirror of the
# fix that could stay green after the fix it is meant to bind is gone.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

run=0; failed=0
ok()  { run=$((run+1)); printf 'ok   %s\n' "$1"; }
bad() { run=$((run+1)); failed=$((failed+1)); printf 'FAIL %s\n       %s\n' "$1" "$2"; }

extract() {
    python3 "$SCRIPT_DIR/extract-runner-shape.py" "$1" "$2" "$3"
}

check_status() {
    local fn="$1" label="$2" test_cmd="$3" cap="$4" want="$5"
    local shape got
    shape="$(extract "$fn" "$test_cmd" "$cap")" || { bad "$fn: $label" "extraction failed (see stderr above)"; return; }
    got="$(/usr/bin/bash -c "$shape" >/dev/null 2>/dev/null; echo $?)"
    if [[ "$got" == "$want" ]]; then
        ok "$fn: $label"
    else
        bad "$fn: $label" "got exit $got, want $want -- shape was:
$shape"
    fi
}

for fn in runnerOut runnerErr; do
    # A producer that genuinely fails must still be reported as failing.
    # This is the F1 bug itself: before the fix, a bare pipe (runnerOut)
    # reported head's status (0), never the producer's.
    check_status "$fn" "a failing producer is reported as failing" "exit 7" 1000 "7"

    # A producer that succeeds must still be reported as succeeding.
    check_status "$fn" "a succeeding producer is reported as succeeding" "exit 0" 1000 "0"

    # A producer that writes MORE than the cap gets SIGPIPE once head
    # closes the read end -- that is truncation, not failure, and must not
    # surface as one. The cap is deliberately tiny (16 bytes) so this does
    # not depend on how fast `yes` can fill 256 KiB.
    if [[ "$fn" == "runnerOut" ]]; then
        over_cap_cmd="yes hello"
    else
        over_cap_cmd="yes hello >&2"
    fi
    check_status "$fn" "a producer over the cap is NOT reported as a failure" "$over_cap_cmd" 16 "0"
done

printf '\nrunners shape: total=%d failed=%d\n' "$run" "$failed"
(( failed == 0 ))
