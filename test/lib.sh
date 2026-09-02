# Shared test helpers. Sourced, never executed.
TESTS_RUN=0
TESTS_FAILED=0
SANDBOX=""

# The redirected variables, saved so teardown can put them back. Without
# this, teardown deletes the sandbox and leaves TMPDIR and the XDG paths
# pointing into it: mktemp then fails outright for anything that runs
# afterwards in the same process, and the failure reads as a mystery
# rather than as a torn-down sandbox.
declare -A SANDBOX_SAVED=()
SANDBOX_VARS=(HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME
              XDG_DATA_DIRS XDG_RUNTIME_DIR TMPDIR)

setup_sandbox() {
    # Save the current values of the seven redirected variables before
    # touching any of them, so teardown_sandbox can restore exactly this
    # state -- absent-vs-empty included -- once it is done.
    SANDBOX_SAVED=()
    local var
    for var in "${SANDBOX_VARS[@]}"; do
        if [[ -v $var ]]; then
            SANDBOX_SAVED["$var"]="${!var}"
        else
            SANDBOX_SAVED["$var"]=$'\x01was-unset'
        fi
    done

    # Belt-and-braces, not the fix: this runs before the save/restore above
    # is in effect for THIS call (there is nothing yet to restore from), so
    # a still-broken TMPDIR from a process that never went through
    # setup_sandbox at all -- or a caller that sourced lib.sh mid-session --
    # would otherwise break mktemp -d here too.
    SANDBOX="$(TMPDIR=/tmp mktemp -d)" || { echo "setup_sandbox: mktemp -d failed" >&2; return 1; }
    [[ -n "$SANDBOX" && "$SANDBOX" == /tmp/?* ]] || { echo "setup_sandbox: implausible sandbox path ${SANDBOX@Q}" >&2; SANDBOX=""; return 1; }
    export HOME="$SANDBOX/home"
    export XDG_CONFIG_HOME="$SANDBOX/config"
    export XDG_STATE_HOME="$SANDBOX/state"
    export XDG_DATA_HOME="$SANDBOX/data"
    export XDG_RUNTIME_DIR="$SANDBOX/run"
    export TMPDIR="$SANDBOX/tmp"
    # A non-empty path defeats the ${XDG_DATA_DIRS:-...} default (":-"
    # substitutes for set-but-empty too, not only unset), and an empty
    # directory contributes nothing -- so no test can reach the real
    # /usr/share/applications by accident.
    export XDG_DATA_DIRS="$SANDBOX/data-dirs"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME/omarchy" "$XDG_STATE_HOME" \
             "$XDG_DATA_HOME/applications" "$XDG_RUNTIME_DIR" "$TMPDIR" \
             "$XDG_DATA_DIRS"
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

    # Put the seven redirected variables back exactly as setup_sandbox found
    # them: unset stays unset (never comes back as an empty string), and a
    # value that was set is restored verbatim. Without this, everything that
    # runs after a teardown in the same process inherits HOME and XDG_* paths
    # -- and TMPDIR -- pointing at a directory that was just deleted.
    local var
    for var in "${SANDBOX_VARS[@]}"; do
        if [[ "${SANDBOX_SAVED[$var]-}" == $'\x01was-unset' ]]; then
            unset "$var"
        elif [[ -n "${SANDBOX_SAVED[$var]+set}" ]]; then
            export "$var=${SANDBOX_SAVED[$var]}"
        fi
    done
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

# --- the invocation guard ---------------------------------------------------
#
# EVERY test function a suite DEFINES must also be CALLED, and one that is not
# fails the run BY NAME.
#
# THE FAILURE MODE, and it is not hypothetical: on 2026-09-03 an edit to
# run-tests.sh dropped the `test_envelope_codes_match_the_script` invocation
# line. Two assertions had just been added and two had silently stopped
# running, so the suite reported the same total as before -- 154 -- and stayed
# green. A test that does not run looks exactly like a test that passes. The
# only thing that caught it was a person noticing that a number had not moved
# when it should have.
#
# It runs from summary() rather than as a test function of its own, because a
# test function is exactly the thing that can lose its invocation. A suite that
# never calls summary() prints no total at all, and that is loud.
#
# FAIL-CLOSED AT EVERY STEP: an unreadable suite file fails; a discovery that
# finds no test functions fails, because a guard over an empty set is the same
# blind shape one level up; and an invocation written in any shape but the bare
# name on its own line -- which is the form every suite here uses -- reads as
# missing rather than being waved through. The last one is deliberate: this
# cannot parse shell, so what it cannot read, it refuses.
assert_every_test_function_is_invoked() {
    local file="$1"
    if [[ ! -r "$file" ]]; then
        TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
        printf 'FAIL suite: the invocation guard can read the suite file\n       %q is not readable, so not one invocation could be verified\n' "$file"
        return
    fi
    local defined missing name
    # `tr -d '[:space:]()'` would delete the NEWLINES too and glue every name
    # into one -- measured, it reported all 58 as missing. Spaces and
    # parentheses only, one name per line.
    defined="$(grep -oE '^[[:space:]]*test_[A-Za-z0-9_]+\(\)' "$file" \
               | tr -d ' ()' | sort -u)"
    assert_eq "suite: the invocation guard found test functions to check" \
              "$([[ -n "$defined" ]] && echo found \
                 || echo 'NONE -- the discovery pattern matched nothing in '"$file")" \
              "found"
    missing=""
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        grep -qE "^[[:space:]]*${name}[[:space:]]*$" "$file" || missing="$missing $name"
    done <<<"$defined"
    assert_eq "suite: every test function defined is also invoked" \
              "${missing:- none}" " none"
}

summary() {
    # Before the total is printed, so the guard's own two assertions are part
    # of the number it reports. SUITE_FILE lets a suite name its own file; the
    # fallback works because every suite here cd's to its own directory first.
    assert_every_test_function_is_invoked "${SUITE_FILE:-./$(basename "$0")}"
    printf '\ntotal=%d failed=%d\n' "$TESTS_RUN" "$TESTS_FAILED"
    [[ "$TESTS_FAILED" -eq 0 ]]
}
