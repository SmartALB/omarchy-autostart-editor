# Shared test helpers. Sourced, never executed.
TESTS_RUN=0
TESTS_FAILED=0
SANDBOX=""

setup_sandbox() {
    SANDBOX="$(mktemp -d)" || { echo "setup_sandbox: mktemp -d failed" >&2; return 1; }
    [[ -n "$SANDBOX" && "$SANDBOX" == /tmp/?* ]] || { echo "setup_sandbox: implausible sandbox path ${SANDBOX@Q}" >&2; SANDBOX=""; return 1; }
    export HOME="$SANDBOX/home"
    export XDG_CONFIG_HOME="$SANDBOX/config"
    export XDG_STATE_HOME="$SANDBOX/state"
    export XDG_DATA_HOME="$SANDBOX/data"
    export XDG_RUNTIME_DIR="$SANDBOX/run"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME/omarchy" "$XDG_STATE_HOME" \
             "$XDG_DATA_HOME/applications" "$XDG_RUNTIME_DIR"
    export FAKE_LOG="$SANDBOX/fake.log"
    : > "$FAKE_LOG"
}

teardown_sandbox() {
    local resolved
    if [[ -z "${SANDBOX:-}" ]]; then
        SANDBOX=""
        return 0
    fi
    # A glob does not resolve "..": "/tmp/.." matches /tmp/* and would make
    # this line "rm -rf /". Resolve first, then require the resolved path to
    # be unchanged and genuinely under /tmp.
    resolved="$(realpath -m -- "$SANDBOX")"
    if [[ "$resolved" == "$SANDBOX" && "$resolved" == /tmp/?* && "$resolved" != */../* && "$resolved" != */.. ]]; then
        rm -rf -- "$SANDBOX"
    else
        printf 'teardown_sandbox: refusing to delete %q -- not a plain path under /tmp\n' "$SANDBOX" >&2
    fi
    SANDBOX=""
}

assert_eq() {
    local name="$1" got="$2" want="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$got" == "$want" ]]; then
        printf 'ok   %s\n' "$name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf 'FAIL %s\n       got  %q\n       want %q\n' "$name" "$got" "$want"
    fi
}

assert_status() {
    local name="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1
    assert_eq "$name" "$?" "$want"
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ -z "$needle" ]]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf 'FAIL %s\n       needle is empty (every string contains the empty string)\n' "$name"
    elif [[ "$haystack" == *"$needle"* ]]; then
        printf 'ok   %s\n' "$name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf 'FAIL %s\n       %q does not contain %q\n' "$name" "$haystack" "$needle"
    fi
}

# A stand-in hyprctl that records its argv, one call per line, arguments
# separated by tabs. Installed as a named seam (HYPRCTL=...), never by
# tinkering with PATH -- Omarchy also lives in /usr/bin, so a "clean" PATH
# excludes nothing.
fake_hyprctl() {
    local path="$SANDBOX/bin/hyprctl"
    mkdir -p "$SANDBOX/bin"
    cat > "$path" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$(printf '%s\t' "$@")" >> "$FAKE_LOG"
case "$1" in
  eval) echo ok ;;
  *)    cat "${FAKE_HYPRCTL_REPLY:-/dev/null}" ;;
esac
FAKE
    chmod +x "$path"
    export HYPRCTL="$path"
}

summary() {
    printf '\ntotal=%d failed=%d\n' "$TESTS_RUN" "$TESTS_FAILED"
    [[ "$TESTS_FAILED" -eq 0 ]]
}
