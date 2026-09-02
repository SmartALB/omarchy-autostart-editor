#!/usr/bin/env bash
# Shell tests for the three bin/ scripts.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

# --- watchdog: the sandbox must actually contain everything -----------------
# export HOME alone does not isolate anything: in an Omarchy session
# XDG_STATE_HOME and XDG_DATA_HOME are set and keep pointing at the real
# directories. On 2026-09-02 a test run overwrote real state that way.
test_sandbox_contains_every_path() {
    setup_sandbox
    for var in HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_RUNTIME_DIR; do
        local value="${!var-}"
        assert_eq "sandbox: \$$var lies under the sandbox" \
                  "$(case "$value" in "$SANDBOX"/*) echo inside ;; *) echo "OUTSIDE: $value" ;; esac)" \
                  "inside"
        # Exported, not merely set: a child process sees only the exported ones,
        # and the code under test always runs as a child.
        assert_eq "sandbox: \$$var is exported to child processes" \
                  "$(declare -p "$var" 2>/dev/null | grep -q '^declare -x' && echo exported || echo "NOT EXPORTED")" \
                  "exported"
    done
    teardown_sandbox
}

test_sandbox_contains_every_path
summary
