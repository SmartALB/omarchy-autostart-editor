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
    for var in HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_RUNTIME_DIR TMPDIR; do
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

CONFIG_BIN="$PWD/../bin/omarchy-autostart-config"

valid_config() {
    printf '{"schemaVersion":1,"programs":[],"workspaces":[{"workspace":"1","monitor":"DP-4"}]}'
}

test_read_missing_file_yields_empty_model() {
    setup_sandbox
    local out; out="$("$CONFIG_BIN" read)"
    assert_eq "read: missing file is ok"        "$(jq -r .ok      <<<"$out")" "true"
    assert_eq "read: missing file mtime is 0"   "$(jq -r .mtime   <<<"$out")" "0"
    assert_eq "read: missing file has no programs" \
              "$(jq -r '.config.programs | length' <<<"$out")" "0"
    teardown_sandbox
}

test_read_round_trips_a_valid_file() {
    setup_sandbox
    valid_config > "$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    chmod 600 "$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    local out; out="$("$CONFIG_BIN" read)"
    assert_eq "read: valid file is ok" "$(jq -r .ok <<<"$out")" "true"
    assert_eq "read: monitor survives" \
              "$(jq -r '.config.workspaces[0].monitor' <<<"$out")" "DP-4"
    assert_eq "read: mtime is not zero" \
              "$(jq -r 'if .mtime > 0 then "nonzero" else "zero" end' <<<"$out")" "nonzero"
    teardown_sandbox
}

test_read_refuses_an_oversized_file() {
    setup_sandbox
    local f="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    # 300 KiB of valid JSON: one long name field. Streamed through redirection,
    # never through jq --arg: the kernel caps a single execve() argument at
    # MAX_ARG_STRLEN (32 pages = 131072 bytes on a 4 KiB-page system), well
    # under 300 KiB, independent of the much larger total ARG_MAX. A jq --arg
    # with a 300 KiB value fails "Argument list too long" on any Linux box,
    # not just a sandboxed one -- confirmed here by binary search (threshold
    # exactly 131072) and by reproducing the failure with sandboxing off.
    {
        printf '{"schemaVersion":1,"programs":[{"id":"p1","name":"'
        head -c 307200 /dev/zero | tr '\0' 'x'
        printf '"}],"workspaces":[]}'
    } > "$f"
    chmod 600 "$f"
    local out; out="$("$CONFIG_BIN" read)"
    assert_eq "read: oversized file refused" "$(jq -r .error <<<"$out")" "too-large"
    teardown_sandbox
}

test_read_accepts_exactly_the_limit() {
    setup_sandbox
    local f="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    # Build a file of exactly 262144 bytes. The boundary is where an off-by-one
    # in the MAX+1 read would show up, and nowhere else. The pad is streamed
    # through redirection rather than jq --arg, for the same MAX_ARG_STRLEN
    # reason as the oversized-file test above -- a single 256 KiB argv entry
    # would fail execve() before jq ever ran.
    local prefix='{"schemaVersion":1,"programs":[{"id":"p1","name":"'
    local suffix='"}],"workspaces":[]}'
    local pad=$(( 262144 - ${#prefix} - ${#suffix} ))
    {
        printf '%s' "$prefix"
        head -c "$pad" /dev/zero | tr '\0' 'x'
        printf '%s' "$suffix"
    } > "$f"
    local size; size="$(wc -c < "$f")"
    assert_eq "read: built file is exactly 256 KiB" "$size" "262144"
    chmod 600 "$f"
    assert_eq "read: exactly 256 KiB is accepted" \
              "$(jq -r .ok <<<"$("$CONFIG_BIN" read)")" "true"
    teardown_sandbox
}

test_read_refuses_broken_json() {
    setup_sandbox
    local f="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    printf '{"schemaVersion":1,' > "$f"; chmod 600 "$f"
    assert_eq "read: broken json refused" \
              "$(jq -r .error <<<"$("$CONFIG_BIN" read)")" "not-json"
    teardown_sandbox
}

test_read_refuses_a_foreign_schema() {
    setup_sandbox
    local f="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    printf '{"schemaVersion":2,"programs":[],"workspaces":[]}' > "$f"; chmod 600 "$f"
    assert_eq "read: schemaVersion 2 refused" \
              "$(jq -r .error <<<"$("$CONFIG_BIN" read)")" "bad-schema"
    teardown_sandbox
}

test_read_refuses_a_group_writable_file() {
    setup_sandbox
    local f="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    valid_config > "$f"; chmod 664 "$f"
    assert_eq "read: group-writable file refused" \
              "$(jq -r .error <<<"$("$CONFIG_BIN" read)")" "insecure-permissions"
    teardown_sandbox
}

test_read_refuses_a_world_writable_directory() {
    setup_sandbox
    local d="$XDG_CONFIG_HOME/omarchy"
    valid_config > "$d/autostart-layout.json"; chmod 600 "$d/autostart-layout.json"
    chmod 777 "$d"
    assert_eq "read: world-writable directory refused" \
              "$(jq -r .error <<<"$("$CONFIG_BIN" read)")" "insecure-permissions"
    chmod 755 "$d"
    teardown_sandbox
}

test_read_is_silent_on_success() {
    setup_sandbox
    valid_config > "$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    chmod 600 "$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    local err; err="$("$CONFIG_BIN" read 2>&1 >/dev/null)"
    assert_eq "read: a successful read writes nothing to stderr" "$err" ""
    teardown_sandbox
}

test_read_leaves_no_temp_file() {
    setup_sandbox
    valid_config > "$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    chmod 600 "$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    local before after
    before="$(find "$TMPDIR" -maxdepth 1 -type f | wc -l)"
    "$CONFIG_BIN" read >/dev/null 2>&1
    "$CONFIG_BIN" read >/dev/null 2>&1
    after="$(find "$TMPDIR" -maxdepth 1 -type f | wc -l)"
    assert_eq "read: two reads leave no temp file behind" "$after" "$before"
    teardown_sandbox
}

test_every_error_path_yields_exactly_one_envelope() {
    setup_sandbox
    local f="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    local label out count
    # Each of these drives the script down a different path; every one of
    # them must answer with exactly one JSON object carrying an "ok" field.
    for label in missing broken badschema groupwritable notafile; do
        rm -rf "$f"
        case "$label" in
            missing)        : ;;
            broken)         printf '{"schemaVersion":1,' > "$f"; chmod 600 "$f" ;;
            badschema)      printf '{"schemaVersion":9,"programs":[],"workspaces":[]}' > "$f"; chmod 600 "$f" ;;
            groupwritable)  valid_config > "$f"; chmod 664 "$f" ;;
            notafile)       mkdir -p "$f" ;;
        esac
        out="$("$CONFIG_BIN" read 2>/dev/null)"
        assert_eq "envelope: $label exits 0" "$?" "0"
        count="$(jq -s 'length' <<<"$out" 2>/dev/null || echo BADJSON)"
        assert_eq "envelope: $label yields exactly one JSON object" "$count" "1"
        assert_eq "envelope: $label carries an ok field" \
                  "$(jq -r 'has("ok")' <<<"$out" 2>/dev/null)" "true"
    done
    rm -rf "$f"
    teardown_sandbox
}

test_missing_config_directory_still_answers() {
    setup_sandbox
    rm -rf "$XDG_CONFIG_HOME/omarchy"
    local out; out="$("$CONFIG_BIN" read)"
    assert_eq "read: a missing config directory yields the empty model" \
              "$(jq -r .ok <<<"$out")" "true"
    assert_eq "read: and its mtime is 0" "$(jq -r .mtime <<<"$out")" "0"
    teardown_sandbox
}

test_read_missing_file_yields_empty_model
test_read_round_trips_a_valid_file
test_read_refuses_an_oversized_file
test_read_accepts_exactly_the_limit
test_read_refuses_broken_json
test_read_refuses_a_foreign_schema
test_read_refuses_a_group_writable_file
test_read_refuses_a_world_writable_directory
test_read_is_silent_on_success
test_read_leaves_no_temp_file
test_every_error_path_yields_exactly_one_envelope
test_missing_config_directory_still_answers

summary
