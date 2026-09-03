#!/usr/bin/env bash
# Shell tests for the three bin/ scripts.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

# --- watchdog: the sandbox must actually contain everything -----------------
# export HOME alone does not isolate anything: in an Omarchy session
# XDG_STATE_HOME and XDG_DATA_HOME are set and keep pointing at the real
# directories. On 2026-09-02 a test run overwrote real state that way.
#
# Two assertions per variable. The VALUE assertion is the real net: it
# catches a redirect that is missing or points outside the sandbox. The
# EXPORT assertion catches a redirect written without `export` -- but it
# cannot catch a missing redirect for a variable the surrounding session
# already exports, because the variable then falls through to that
# ambient value and stays exported. Best effort, not a guarantee.
test_sandbox_contains_every_path() {
    setup_sandbox
    for var in HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_DATA_DIRS XDG_RUNTIME_DIR TMPDIR; do
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

# teardown_sandbox must put HOME/XDG_*/TMPDIR back exactly as it found them
# -- absent stays absent, set comes back verbatim -- because every test that
# runs afterwards in this same process, including this file's own
# test_generated_lua_compiles, otherwise inherits a TMPDIR pointing at a
# directory that no longer exists and mktemp fails for the rest of the run.
test_teardown_restores_the_environment() {
    local before_tmpdir="${TMPDIR-$'\x01unset'}"
    local before_home="${HOME-$'\x01unset'}"
    setup_sandbox
    teardown_sandbox
    assert_eq "teardown: TMPDIR is what it was before" "${TMPDIR-$'\x01unset'}" "$before_tmpdir"
    assert_eq "teardown: HOME is what it was before" "${HOME-$'\x01unset'}" "$before_home"
    # mktemp -u only prints a name -- it never touches the filesystem, so it
    # cannot see that TMPDIR points at a directory teardown_sandbox just
    # deleted, and this assertion would pass even with the restore loop
    # removed entirely (confirmed by probe). Create for real instead: that
    # forces mktemp to resolve TMPDIR against an actual write.
    assert_eq "teardown: mktemp works again afterwards" \
              "$(probe_file="$(mktemp 2>/dev/null)" && [[ -f "$probe_file" ]] && { rm -f "$probe_file"; echo ok; } || echo broken)" "ok"
}

test_teardown_restores_the_environment

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

test_every_path_yields_exactly_one_envelope() {
    setup_sandbox
    local f="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    local label out count
    # Each of these drives the script down a different path; every one of
    # them must answer with exactly one JSON object carrying an "ok" field.
    # "valid" closes the structural gap on the success path -- the round-trip
    # test already covers it with stronger, content-level assertions, but
    # this is the one test whose name promises every path, so it must too.
    for label in missing broken badschema groupwritable notafile valid; do
        rm -rf "$f"
        case "$label" in
            missing)        : ;;
            broken)         printf '{"schemaVersion":1,' > "$f"; chmod 600 "$f" ;;
            badschema)      printf '{"schemaVersion":9,"programs":[],"workspaces":[]}' > "$f"; chmod 600 "$f" ;;
            groupwritable)  valid_config > "$f"; chmod 664 "$f" ;;
            notafile)       mkdir -p "$f" ;;
            valid)          valid_config > "$f"; chmod 600 "$f" ;;
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
test_every_path_yields_exactly_one_envelope
test_missing_config_directory_still_answers

test_write_creates_the_file_with_0600() {
    setup_sandbox
    local out; out="$(valid_config | "$CONFIG_BIN" write --expect-mtime 0)"
    assert_eq "write: creation is ok" "$(jq -r .ok <<<"$out")" "true"
    assert_eq "write: mode is 0600" \
              "$(stat -c %a "$XDG_CONFIG_HOME/omarchy/autostart-layout.json")" "600"
    assert_eq "write: content round-trips" \
              "$(jq -r '.config.workspaces[0].monitor' <<<"$("$CONFIG_BIN" read)")" "DP-4"
    teardown_sandbox
}

test_write_refuses_a_stale_mtime() {
    setup_sandbox
    local f="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    valid_config > "$f"; chmod 600 "$f"
    local out; out="$(valid_config | "$CONFIG_BIN" write --expect-mtime 1)"
    assert_eq "write: stale mtime refused" "$(jq -r .error <<<"$out")" "stale"
    teardown_sandbox
}

test_write_refuses_an_existing_file_when_expecting_none() {
    setup_sandbox
    local f="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    valid_config > "$f"; chmod 600 "$f"
    assert_eq "write: expect-mtime 0 on an existing file refused" \
              "$(jq -r .error <<<"$(valid_config | "$CONFIG_BIN" write --expect-mtime 0)")" \
              "stale"
    teardown_sandbox
}

test_write_refuses_oversized_input() {
    setup_sandbox
    # Streamed through redirection, never through jq --arg: a 300 KiB --arg
    # value fails execve() with "Argument list too long" (kernel
    # MAX_ARG_STRLEN, 131072 bytes) before jq ever runs -- the same reason
    # test_read_refuses_an_oversized_file above avoids that pattern.
    local out
    out="$({
        printf '{"schemaVersion":1,"programs":[{"id":"p1","name":"'
        head -c 307200 /dev/zero | tr '\0' 'x'
        printf '"}],"workspaces":[]}'
    } | "$CONFIG_BIN" write --expect-mtime 0)"
    assert_eq "write: oversized input refused" "$(jq -r .error <<<"$out")" "too-large"
    assert_eq "write: nothing was created" \
              "$([[ -e "$XDG_CONFIG_HOME/omarchy/autostart-layout.json" ]] && echo yes || echo no)" \
              "no"
    teardown_sandbox
}

test_write_refuses_broken_input_and_leaves_the_old_file() {
    setup_sandbox
    local f="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    valid_config > "$f"; chmod 600 "$f"
    local mtime; mtime="$(stat -c %Y "$f")"
    local out; out="$(printf '{"schemaVersion":1,' | "$CONFIG_BIN" write --expect-mtime "$mtime")"
    assert_eq "write: broken input refused" "$(jq -r .error <<<"$out")" "not-json"
    assert_eq "write: previous content untouched" \
              "$(jq -r '.workspaces[0].monitor' "$f")" "DP-4"
    teardown_sandbox
}

test_write_leaves_no_temp_file_behind() {
    setup_sandbox
    printf '{"schemaVersion":1,' | "$CONFIG_BIN" write --expect-mtime 0 >/dev/null
    assert_eq "write: no leftover temp file" \
              "$(find "$XDG_CONFIG_HOME/omarchy" -name '.autostart-layout.json.*' | wc -l)" "0"
    teardown_sandbox
}

# The two Task 4 had to learn about after the fact: 44 assertions there looked
# only at stdout and therefore saw neither the stderr noise nor the leaked file.
test_write_is_silent_on_success() {
    setup_sandbox
    local err; err="$(valid_config | "$CONFIG_BIN" write --expect-mtime 0 2>&1 >/dev/null)"
    assert_eq "write: a successful write says nothing on stderr" "$err" ""
    teardown_sandbox
}

test_write_paths_each_yield_one_envelope() {
    setup_sandbox
    local f="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    local label out count
    for label in create stale toolarge broken; do
        rm -f "$f"
        case "$label" in
            create)   out="$(valid_config | "$CONFIG_BIN" write --expect-mtime 0)" ;;
            stale)    valid_config > "$f"; chmod 600 "$f"
                      out="$(valid_config | "$CONFIG_BIN" write --expect-mtime 1)" ;;
            # Streamed through redirection, never jq --arg: same MAX_ARG_STRLEN
            # reason as test_write_refuses_oversized_input above. This must
            # actually build an oversized payload -- the previous version
            # bound $n and never used it, so it silently drove the create
            # path a second time instead of earning the "toolarge" name.
            toolarge) out="$({
                          printf '{"schemaVersion":1,"programs":[{"id":"p1","name":"'
                          head -c 307200 /dev/zero | tr '\0' 'x'
                          printf '"}],"workspaces":[]}'
                      } | "$CONFIG_BIN" write --expect-mtime 0)" ;;
            broken)   out="$(printf '{"schemaVersion":1,' | "$CONFIG_BIN" write --expect-mtime 0)" ;;
        esac
        assert_eq "write envelope: $label exits 0" "$?" "0"
        count="$(jq -s 'length' <<<"$out" 2>/dev/null || echo BADJSON)"
        assert_eq "write envelope: $label yields exactly one JSON object" "$count" "1"
        assert_eq "write envelope: $label carries an ok field" \
                  "$(jq -r 'has("ok")' <<<"$out" 2>/dev/null)" "true"
        if [[ "$label" == "toolarge" ]]; then
            assert_eq "write envelope: toolarge actually reports too-large" \
                      "$(jq -r .error <<<"$out" 2>/dev/null)" "too-large"
        fi
    done
    teardown_sandbox
}

# The reviewer reproduced this as a real hang: with exactly one positional
# parameter left, `shift 2` is a no-op per the bash manual, so a bare
# trailing --expect-mtime left $1 unchanged and the while loop never
# terminated -- 100% CPU, nothing ever emitted. `timeout 5` on every call
# below is deliberate: a regression of this bug must fail the suite, not
# hang it.
test_write_usage_errors_terminate() {
    setup_sandbox
    local st
    timeout 5 bash -c "printf '{}' | '$CONFIG_BIN' write --expect-mtime" >/dev/null 2>&1
    st=$?
    assert_eq "write: a bare --expect-mtime exits 2 and does not hang" "$st" "2"

    timeout 5 bash -c "printf '{}' | '$CONFIG_BIN' write --nonsense 5" >/dev/null 2>&1
    assert_eq "write: an unknown flag exits 2" "$?" "2"

    timeout 5 bash -c "printf '{}' | '$CONFIG_BIN' write" >/dev/null 2>&1
    assert_eq "write: a missing --expect-mtime exits 2" "$?" "2"

    timeout 5 bash -c "printf '{}' | '$CONFIG_BIN' write --expect-mtime ''" >/dev/null 2>&1
    assert_eq "write: an empty --expect-mtime exits 2" "$?" "2"

    timeout 5 bash -c "printf '{}' | '$CONFIG_BIN' write --expect-mtime -1" >/dev/null 2>&1
    assert_eq "write: a negative --expect-mtime exits 2" "$?" "2"
    teardown_sandbox
}

# read treats a missing config directory as the first-class empty-model case
# (test_missing_config_directory_still_answers above); write has to be able
# to create that directory back, or a new user can look at an empty panel
# and then be unable to save it.
test_write_creates_a_missing_config_directory() {
    setup_sandbox
    rm -rf "$XDG_CONFIG_HOME/omarchy"
    local out; out="$(valid_config | "$CONFIG_BIN" write --expect-mtime 0)"
    assert_eq "write: a missing config directory is created" "$(jq -r .ok <<<"$out")" "true"
    assert_eq "write: and the file lands with mode 0600" \
              "$(stat -c %a "$XDG_CONFIG_HOME/omarchy/autostart-layout.json")" "600"
    teardown_sandbox
}

# check_permissions deliberately omits -L: without it, `stat -c %a` on a
# symlink reports the link's own mode (always 777), so a symlinked config is
# refused by decision, not by accident of a mode that happens to look
# writable. This pins that behaviour so it cannot silently change if -L is
# ever added.
test_write_refuses_a_symlinked_config_file() {
    setup_sandbox
    local f="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    local real="$SANDBOX/elsewhere.json"
    valid_config > "$real"; chmod 600 "$real"
    ln -s "$real" "$f"
    local out; out="$(valid_config | "$CONFIG_BIN" write --expect-mtime 0)"
    assert_eq "write: a symlinked config file is refused" \
              "$(jq -r .error <<<"$out")" "insecure-permissions"
    teardown_sandbox
}

test_write_creates_the_file_with_0600
test_write_refuses_a_stale_mtime
test_write_refuses_an_existing_file_when_expecting_none
test_write_refuses_oversized_input
test_write_refuses_broken_input_and_leaves_the_old_file
test_write_leaves_no_temp_file_behind
test_write_is_silent_on_success
test_write_paths_each_yield_one_envelope
test_write_usage_errors_terminate
test_write_creates_a_missing_config_directory
test_write_refuses_a_symlinked_config_file

APPS_BIN="$PWD/../bin/omarchy-autostart-apps"

write_desktop() {
    local dir="$1" file="$2"; shift 2
    mkdir -p "$dir"
    { echo "[Desktop Entry]"; printf '%s\n' "$@"; } > "$dir/$file"
}

test_apps_reads_name_exec_and_class() {
    setup_sandbox
    write_desktop "$XDG_DATA_HOME/applications" "cursor.desktop" \
        "Type=Application" "Name=Cursor" "Exec=cursor %U" \
        "StartupWMClass=cursor" "Icon=cursor"
    local out; out="$(DESKTOP_DIRS="$XDG_DATA_HOME/applications" "$APPS_BIN")"
    assert_eq "apps: one entry"        "$(jq -r 'length'        <<<"$out")" "1"
    assert_eq "apps: name"             "$(jq -r '.[0].name'     <<<"$out")" "Cursor"
    assert_eq "apps: raw exec kept"    "$(jq -r '.[0].exec'     <<<"$out")" "cursor %U"
    assert_eq "apps: wmclass"          "$(jq -r '.[0].wmclass'  <<<"$out")" "cursor"
    assert_eq "apps: icon"             "$(jq -r '.[0].icon'     <<<"$out")" "cursor"
    teardown_sandbox
}

test_apps_skips_hidden_and_nondisplay_and_nonapplication() {
    setup_sandbox
    local d="$XDG_DATA_HOME/applications"
    write_desktop "$d" "a.desktop" "Type=Application" "Name=A" "Exec=a" "NoDisplay=true"
    write_desktop "$d" "b.desktop" "Type=Application" "Name=B" "Exec=b" "Hidden=true"
    write_desktop "$d" "c.desktop" "Type=Link" "Name=C" "URL=http://x"
    write_desktop "$d" "d.desktop" "Type=Application" "Name=D" "Exec=d"
    local out; out="$(DESKTOP_DIRS="$d" "$APPS_BIN")"
    assert_eq "apps: only the visible application remains" "$(jq -r 'length' <<<"$out")" "1"
    assert_eq "apps: it is D" "$(jq -r '.[0].name' <<<"$out")" "D"
    teardown_sandbox
}

test_apps_missing_exec_is_dropped() {
    setup_sandbox
    write_desktop "$XDG_DATA_HOME/applications" "e.desktop" "Type=Application" "Name=E"
    assert_eq "apps: an entry without Exec is useless and dropped" \
              "$(jq -r 'length' <<<"$(DESKTOP_DIRS="$XDG_DATA_HOME/applications" "$APPS_BIN")")" "0"
    teardown_sandbox
}

test_apps_caps_the_file_count() {
    setup_sandbox
    local d="$XDG_DATA_HOME/applications"; mkdir -p "$d"
    for i in $(seq 1 2005); do
        printf '[Desktop Entry]\nType=Application\nName=N%s\nExec=n%s\n' "$i" "$i" \
            > "$d/n$i.desktop"
    done
    assert_eq "apps: file count capped at 2000" \
              "$(jq -r 'length' <<<"$(DESKTOP_DIRS="$d" "$APPS_BIN")")" "2000"
    teardown_sandbox
}

test_apps_caps_bytes_per_file() {
    setup_sandbox
    local d="$XDG_DATA_HOME/applications"; mkdir -p "$d"
    # Name comes first, then 100 KiB of comments, then Exec. With a 64 KiB cap
    # the Exec line is never read, so the entry is dropped -- which is exactly
    # the observable effect of the byte limit.
    #
    # 102400 is an exact multiple of the fold width, so fold's last output
    # line carries no trailing newline; without an explicit "\n" here the
    # following "Exec=fat" would merge onto that last comment line and never
    # appear as a line matching /^Exec=/ at all -- masking the byte cap
    # entirely (verified: even reading the whole file with `cat` still
    # yielded 0 entries, for the wrong reason).
    { printf '[Desktop Entry]\nType=Application\nName=Fat\n'
      head -c 102400 /dev/zero | tr '\0' '#' | fold -w 80 | sed 's/^/#/'
      printf '\nExec=fat\n'; } > "$d/fat.desktop"
    assert_eq "apps: per-file byte cap keeps the tail unread" \
              "$(jq -r 'length' <<<"$(DESKTOP_DIRS="$d" "$APPS_BIN")")" "0"
    teardown_sandbox
}

test_apps_survives_a_tab_inside_a_value() {
    setup_sandbox
    local d="$XDG_DATA_HOME/applications"; mkdir -p "$d"
    printf '[Desktop Entry]\nType=Application\nName=Tabby\nExec=foo\tbar\n' > "$d/tabby.desktop"
    write_desktop "$d" "clean.desktop" "Type=Application" "Name=Clean" "Exec=clean"
    local out; out="$(DESKTOP_DIRS="$d" "$APPS_BIN")"
    assert_eq "apps: a tab in a value does not shift the later fields" \
              "$(jq -r '.[] | select(.name=="Tabby") | .wmclass' <<<"$out")" ""
    assert_eq "apps: and the tabbed value itself survives as one field" \
              "$(jq -r '.[] | select(.name=="Tabby") | .exec' <<<"$out")" "foo bar"
    assert_eq "apps: the other entry is unaffected" \
              "$(jq -r '.[] | select(.name=="Clean") | .exec' <<<"$out")" "clean"
    teardown_sandbox
}

test_apps_default_search_path_is_used_when_the_seam_is_unset() {
    setup_sandbox
    write_desktop "$XDG_DATA_HOME/applications" "defaulted.desktop" \
        "Type=Application" "Name=Defaulted" "Exec=defaulted"
    # No DESKTOP_DIRS: this exercises default_dirs() and its XDG handling.
    # No XDG_DATA_DIRS override either -- the sandbox points it at an empty
    # directory of its own, which is what keeps /usr/share/applications out.
    # Setting it to "" would NOT work: default_dirs uses ${XDG_DATA_DIRS:-...}
    # and :- substitutes the default for a set-but-empty value too, which is
    # what the XDG specification requires.
    local out; out="$("$APPS_BIN")"
    assert_eq "apps: the default search path finds the sandboxed entry" \
              "$(jq -r '.[] | select(.name=="Defaulted") | .exec' <<<"$out")" "defaulted"
    assert_eq "apps: the default search path sees only the sandbox" \
              "$(jq -r 'length' <<<"$out")" "1"
    teardown_sandbox
}

test_apps_reads_name_exec_and_class
test_apps_skips_hidden_and_nondisplay_and_nonapplication
test_apps_missing_exec_is_dropped
test_apps_caps_the_file_count
test_apps_caps_bytes_per_file
test_apps_survives_a_tab_inside_a_value
test_apps_default_search_path_is_used_when_the_seam_is_unset

WINDOWS_BIN="$PWD/../bin/omarchy-autostart-windows"

# The stand-in from lib.sh answers `eval` with ok and everything else from a
# file. Windows needs two different answers, so give it a small router.
fake_hyprctl_json() {
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    clients)  cat "$FAKE_CLIENTS";  exit 0 ;;
    monitors) cat "$FAKE_MONITORS"; exit 0 ;;
  esac
done
exit 1
FAKE
    chmod +x "$SANDBOX/bin/hyprctl"
    export HYPRCTL="$SANDBOX/bin/hyprctl"
    export FAKE_CLIENTS="$SANDBOX/clients.json"
    export FAKE_MONITORS="$SANDBOX/monitors.json"
    cat > "$FAKE_MONITORS" <<'JSON'
[{"id":0,"name":"DP-4"},{"id":1,"name":"HDMI-A-1"}]
JSON
}

test_windows_resolves_the_monitor_name() {
    setup_sandbox; fake_hyprctl_json
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"cursor","title":"main","workspace":{"id":6},"monitor":1}]
JSON
    local out; out="$("$WINDOWS_BIN")"
    assert_eq "windows: one window"      "$(jq -r 'length'         <<<"$out")" "1"
    assert_eq "windows: class"           "$(jq -r '.[0].class'     <<<"$out")" "cursor"
    assert_eq "windows: workspace"       "$(jq -r '.[0].workspace' <<<"$out")" "6"
    assert_eq "windows: monitor by name" "$(jq -r '.[0].monitor'   <<<"$out")" "HDMI-A-1"
    teardown_sandbox
}

test_windows_drops_special_workspaces() {
    setup_sandbox; fake_hyprctl_json
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"a","title":"t","workspace":{"id":-99},"monitor":0},
 {"address":"0x2","class":"b","title":"t","workspace":{"id":2},"monitor":0}]
JSON
    local out; out="$("$WINDOWS_BIN")"
    assert_eq "windows: special workspaces dropped" "$(jq -r 'length' <<<"$out")" "1"
    assert_eq "windows: the normal one stays"       "$(jq -r '.[0].class' <<<"$out")" "b"
    teardown_sandbox
}

test_windows_caps_the_count() {
    setup_sandbox; fake_hyprctl_json
    jq -nc '[range(0;520) | {address:("0x"+(.|tostring)),class:"c",title:"t",
                             workspace:{id:1},monitor:0}]' > "$FAKE_CLIENTS"
    assert_eq "windows: count capped at 500" \
              "$(jq -r 'length' <<<"$("$WINDOWS_BIN")")" "500"
    teardown_sandbox
}

test_windows_survives_an_unreachable_compositor() {
    setup_sandbox
    export HYPRCTL="$SANDBOX/bin/nope"
    assert_eq "windows: unreachable hyprctl yields an empty array, not a crash" \
              "$("$WINDOWS_BIN")" "[]"
    teardown_sandbox
}

test_windows_survives_an_array_of_non_objects() {
    setup_sandbox; fake_hyprctl_json
    printf '[1,2,3]\n' > "$FAKE_CLIENTS"
    local out; out="$("$WINDOWS_BIN")"
    assert_eq "windows: an array of non-objects yields an empty array" "$out" "[]"
    assert_eq "windows: and it is still exactly one JSON array" \
              "$(jq -s 'length' <<<"$out" 2>/dev/null || echo BADJSON)" "1"
    teardown_sandbox
}

test_windows_filters_before_capping() {
    setup_sandbox; fake_hyprctl_json
    # 100 scratchpad windows first, then 420 normal ones: 520 raw items.
    # Filter-then-cap keeps all 420 normal windows. Cap-then-filter would
    # take the first 500 raw items -- 100 special plus 400 normal -- and
    # then drop the specials, leaving 400. The count tells the two apart.
    jq -nc '[range(0;100) | {address:("0xs"+(.|tostring)),class:"s",title:"t",
                             workspace:{id:-99},monitor:0}]
            + [range(0;420) | {address:("0xn"+(.|tostring)),class:"n",title:"t",
                               workspace:{id:1},monitor:0}]' > "$FAKE_CLIENTS"
    assert_eq "windows: the special-workspace filter runs before the cap" \
              "$(jq -r 'length' <<<"$("$WINDOWS_BIN")")" "420"
    teardown_sandbox
}

test_windows_survives_a_failing_hyprctl() {
    setup_sandbox
    mkdir -p "$SANDBOX/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/hyprctl"
    chmod +x "$SANDBOX/bin/hyprctl"
    export HYPRCTL="$SANDBOX/bin/hyprctl"
    assert_eq "windows: a hyprctl that exits non-zero yields an empty array" \
              "$("$WINDOWS_BIN")" "[]"
    teardown_sandbox
}

test_windows_survives_valid_json_that_is_not_an_array() {
    setup_sandbox; fake_hyprctl_json
    printf '{"not":"an array"}\n' > "$FAKE_CLIENTS"
    assert_eq "windows: valid JSON that is not an array yields an empty array" \
              "$("$WINDOWS_BIN")" "[]"
    teardown_sandbox
}

# --- THE COMMAND LINE OF A WINDOW -------------------------------------------
#
# A window has a class, not a command, and this is the half that measures the
# command it is actually running. A sandbox cannot create /proc/<pid>/cmdline,
# so PROC_DIR is a named seam like HYPRCTL and GREP -- without it none of this
# would be testable at all, which is how it would end up untested.
fake_proc() {
    export PROC_DIR="$SANDBOX/proc"
    mkdir -p "$PROC_DIR"
}

# One fake process: fake_cmdline <pid> <arg>...  Written with real NUL
# separators, because that is what /proc/<pid>/cmdline is and turning them
# into spaces is the first thing the script has to do.
fake_cmdline() {
    local pid="$1"; shift
    mkdir -p "$PROC_DIR/$pid"
    local arg
    for arg in "$@"; do printf '%s\0' "$arg"; done > "$PROC_DIR/$pid/cmdline"
}

test_windows_reads_the_command_line() {
    setup_sandbox; fake_hyprctl_json; fake_proc
    fake_cmdline 1876 /usr/bin/Chatterbox
    fake_cmdline 226441 /usr/bin/termpane --working-directory=/home/user
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"org.example.chatterbox","title":"Chatterbox","workspace":{"id":3},"monitor":0,"pid":1876},
 {"address":"0x2","class":"Termpane","title":"term","workspace":{"id":1},"monitor":0,"pid":226441}]
JSON
    local out; out="$("$WINDOWS_BIN")"
    assert_eq "windows: the NUL separators become spaces" \
              "$(jq -r '.[0].command' <<<"$out")" "/usr/bin/Chatterbox"
    assert_eq "windows: an argument comes with it" \
              "$(jq -r '.[1].command' <<<"$out")" "/usr/bin/termpane --working-directory=/home/user"
    assert_eq "windows: the program is the basename of the first word" \
              "$(jq -r '.[1].program' <<<"$out")" "termpane"
    # The pid is the script's own business and must not leave it: a pid is
    # stale the moment it is read.
    assert_eq "windows: the pid does not reach the caller" \
              "$(jq -r '.[0] | has("pid")' <<<"$out")" "false"
    teardown_sandbox
}

test_windows_three_windows_of_one_process() {
    setup_sandbox; fake_hyprctl_json; fake_proc
    # His three nimbus windows, measured: three classes, one pid, one command
    # line -- and that line ends in the Webmail flag, so it is WRONG for the
    # plain browser window. The script reports what it measured; deciding
    # what it means is Model.js's job and the user's.
    fake_cmdline 1866 /opt/nimbus-bin/nimbus --password-store=gnome-libsecret \
                 --app=https://mail.example.com/mail/
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"nimbus-browser","title":"b","workspace":{"id":1},"monitor":0,"pid":1866},
 {"address":"0x2","class":"nimbus-mail.example.com__mail_-Default","title":"o","workspace":{"id":2},"monitor":0,"pid":1866},
 {"address":"0x3","class":"nimbus-chat.example.org__-Default","title":"w","workspace":{"id":3},"monitor":0,"pid":1866}]
JSON
    local out; out="$("$WINDOWS_BIN")"
    assert_eq "windows: three windows of one process stay three windows" \
              "$(jq -r 'length' <<<"$out")" "3"
    assert_eq "windows: and all three carry the identical command line" \
              "$(jq -r '[.[].command] | unique | length' <<<"$out")" "1"
    assert_eq "windows: which is the one that was measured" \
              "$(jq -r '.[0].command' <<<"$out")" \
              "/opt/nimbus-bin/nimbus --password-store=gnome-libsecret --app=https://mail.example.com/mail/"
    assert_eq "windows: their classes are what tells them apart" \
              "$(jq -r '[.[].class] | unique | length' <<<"$out")" "3"
    teardown_sandbox
}

test_windows_unreadable_proc_is_an_empty_field() {
    setup_sandbox; fake_hyprctl_json; fake_proc
    fake_cmdline 1483 /usr/lib/msgbox-desktop/msgbox-desktop
    # 4242 has no directory at all -- a window of another user, or a process
    # that exited between the two reads.
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"gone","title":"g","workspace":{"id":1},"monitor":0,"pid":4242},
 {"address":"0x2","class":"signal","title":"s","workspace":{"id":2},"monitor":0,"pid":1483}]
JSON
    local out; out="$("$WINDOWS_BIN")"
    assert_eq "windows: an unreadable /proc entry is an empty command" \
              "$(jq -r '.[0].command' <<<"$out")" ""
    assert_eq "windows: and an empty program" \
              "$(jq -r '.[0].program' <<<"$out")" ""
    assert_eq "windows: the window itself is still listed" \
              "$(jq -r '.[0].class' <<<"$out")" "gone"
    assert_eq "windows: and the other window is unaffected" \
              "$(jq -r '.[1].command' <<<"$out")" "/usr/lib/msgbox-desktop/msgbox-desktop"
    teardown_sandbox
}

test_windows_a_window_without_a_pid() {
    setup_sandbox; fake_hyprctl_json; fake_proc
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"nopid","title":"n","workspace":{"id":1},"monitor":0},
 {"address":"0x2","class":"badpid","title":"b","workspace":{"id":1},"monitor":0,"pid":"1876"}]
JSON
    local out; out="$("$WINDOWS_BIN")"
    assert_eq "windows: a window with no pid gets an empty command, not a crash" \
              "$(jq -r '.[0].command' <<<"$out")" ""
    assert_eq "windows: a pid that is a string is not looked up either" \
              "$(jq -r '.[1].command' <<<"$out")" ""
    assert_eq "windows: and both windows are still listed" \
              "$(jq -r 'length' <<<"$out")" "2"
    teardown_sandbox
}

test_windows_a_tab_in_a_command_line_does_not_shift_a_field() {
    setup_sandbox; fake_hyprctl_json; fake_proc
    # The pid and the command line travel to jq as one tab-separated line. A
    # tab surviving into the command would split that line into the wrong
    # fields -- and this project has been bitten by exactly that shape once
    # already, by a tab inside a .desktop value.
    fake_cmdline 100 "/usr/bin/odd" $'--flag=a\tb'
    fake_cmdline 101 "/usr/bin/plain"
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"odd","title":"o","workspace":{"id":1},"monitor":0,"pid":100},
 {"address":"0x2","class":"plain","title":"p","workspace":{"id":1},"monitor":0,"pid":101}]
JSON
    local out; out="$("$WINDOWS_BIN")"
    assert_eq "windows: a tab in a command line becomes a space" \
              "$(jq -r '.[0].command' <<<"$out")" "/usr/bin/odd --flag=a b"
    assert_eq "windows: and the next window keeps its own command" \
              "$(jq -r '.[1].command' <<<"$out")" "/usr/bin/plain"
    teardown_sandbox
}

test_windows_control_characters_in_a_command_line() {
    setup_sandbox; fake_hyprctl_json; fake_proc
    # A newline inside a command line is the shape that once returned a
    # foreign window address from the match query.
    fake_cmdline 100 "/usr/bin/odd" $'--flag=a\nb' $'--bell=\a'
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"odd","title":"o","workspace":{"id":1},"monitor":0,"pid":100}]
JSON
    local out; out="$("$WINDOWS_BIN")"
    assert_eq "windows: a newline in a command line becomes a space" \
              "$(jq -r '.[0].command' <<<"$out")" "/usr/bin/odd --flag=a b --bell="
    assert_eq "windows: and the output is still exactly one JSON array" \
              "$(jq -s 'length' <<<"$out" 2>/dev/null || echo BADJSON)" "1"
    teardown_sandbox
}

test_windows_a_command_line_past_the_cap() {
    setup_sandbox; fake_hyprctl_json; fake_proc
    # Past the writer cap the field is EMPTY rather than truncated: a
    # truncated command line looks like a command and is not one. The program
    # survives, because the .desktop-by-binary route needs only that word and
    # it is the route that answers the two cases /proc cannot.
    local long; long="$(printf 'x%.0s' $(seq 1 600))"
    fake_cmdline 100 "/usr/bin/verylong" "--flag=$long"
    fake_cmdline 101 "/usr/bin/short" "--flag=ok"
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"long","title":"l","workspace":{"id":1},"monitor":0,"pid":100},
 {"address":"0x2","class":"short","title":"s","workspace":{"id":1},"monitor":0,"pid":101}]
JSON
    local out; out="$("$WINDOWS_BIN")"
    assert_eq "windows: a command line past the cap arrives empty, not truncated" \
              "$(jq -r '.[0].command' <<<"$out")" ""
    assert_eq "windows: but its program survives the cap" \
              "$(jq -r '.[0].program' <<<"$out")" "verylong"
    assert_eq "windows: a command line under the cap is untouched" \
              "$(jq -r '.[1].command' <<<"$out")" "/usr/bin/short --flag=ok"
    # 500 exactly is MAX_COMMAND in Model.js: the longest command that file
    # will write. One character more could not be written even if it were
    # offered, which is why the cap sits there and not somewhere rounder.
    # 485, because "/usr/bin/e --f=" is the other 15 characters of the 500.
    local at_cap; at_cap="$(printf 'y%.0s' $(seq 1 485))"
    fake_cmdline 102 "/usr/bin/e" "--f=$at_cap"
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"atcap","title":"a","workspace":{"id":1},"monitor":0,"pid":102}]
JSON
    assert_eq "windows: a command line of exactly 500 characters still arrives" \
              "$(jq -r '.[0].command | length' <<<"$("$WINDOWS_BIN")")" "500"
    teardown_sandbox
}

test_windows_the_program_is_a_basename_not_a_path() {
    setup_sandbox; fake_hyprctl_json; fake_proc
    fake_cmdline 1883 /tmp/.mount_lm-stuFjMMHD/modelbox
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"ai.elementlabs.modelbox","title":"Modelbox","workspace":{"id":8},"monitor":0,"pid":1883}]
JSON
    local out; out="$("$WINDOWS_BIN")"
    assert_eq "windows: the AppImage mount path is reported as measured" \
              "$(jq -r '.[0].command' <<<"$out")" "/tmp/.mount_lm-stuFjMMHD/modelbox"
    assert_eq "windows: and its program is the basename alone" \
              "$(jq -r '.[0].program' <<<"$out")" "modelbox"
    teardown_sandbox
}

test_windows_reads_the_command_line
test_windows_three_windows_of_one_process
test_windows_unreadable_proc_is_an_empty_field
test_windows_a_window_without_a_pid
test_windows_a_tab_in_a_command_line_does_not_shift_a_field
test_windows_control_characters_in_a_command_line
test_windows_a_command_line_past_the_cap
test_windows_the_program_is_a_basename_not_a_path

test_windows_resolves_the_monitor_name
test_windows_drops_special_workspaces
test_windows_caps_the_count
test_windows_survives_an_unreachable_compositor
test_windows_survives_an_array_of_non_objects
test_windows_filters_before_capping
test_windows_survives_a_failing_hyprctl
test_windows_survives_valid_json_that_is_not_an_array

test_windows_workspaces_mode() {
    setup_sandbox; fake_hyprctl_json
    cat > "$SANDBOX/workspaces.json" <<'JSON'
[{"id":1,"monitor":"DP-4"},{"id":6,"monitor":"HDMI-A-1"},{"id":-99,"monitor":"DP-4"}]
JSON
    # extend the router with a third answer
    cat > "$SANDBOX/bin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    clients)    cat "$FAKE_CLIENTS";    exit 0 ;;
    monitors)   cat "$FAKE_MONITORS";   exit 0 ;;
    workspaces) cat "$FAKE_WORKSPACES"; exit 0 ;;
  esac
done
exit 1
FAKE
    chmod +x "$SANDBOX/bin/hyprctl"
    export FAKE_WORKSPACES="$SANDBOX/workspaces.json"
    local out; out="$("$WINDOWS_BIN" --workspaces)"
    assert_eq "windows --workspaces: special workspace dropped" "$(jq -r 'length' <<<"$out")" "2"
    assert_eq "windows --workspaces: workspace is a string"     "$(jq -r '.[0].workspace' <<<"$out")" "1"
    assert_eq "windows --workspaces: monitor name"              "$(jq -r '.[1].monitor' <<<"$out")" "HDMI-A-1"
    teardown_sandbox
}

test_windows_match_file() {
    setup_sandbox; fake_hyprctl_json
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"cursor","title":"a","workspace":{"id":6},"monitor":1},
 {"address":"0x2","class":"LM-Studio","title":"b","workspace":{"id":1},"monitor":0},
 {"address":"0x3","class":"firefox","title":"c","workspace":{"id":1},"monitor":0}]
JSON
    printf 'p1\t^(cursor)$\np2\tLM[- ]?Studio\n' > "$SANDBOX/match"
    local out; out="$("$WINDOWS_BIN" --match-file "$SANDBOX/match")"
    assert_eq "match: two windows matched"  "$(jq -r 'length' <<<"$out")" "2"
    assert_eq "match: p1 found cursor"      "$(jq -r '.[] | select(.id=="p1") | .address' <<<"$out")" "0x1"
    assert_eq "match: p2 found LM-Studio"   "$(jq -r '.[] | select(.id=="p2") | .address' <<<"$out")" "0x2"
    assert_eq "match: firefox matched nothing" \
              "$(jq -r '[.[] | select(.class=="firefox")] | length' <<<"$out")" "0"
    teardown_sandbox
}

test_match_is_bounded_against_a_backtracking_regex() {
    setup_sandbox; fake_hyprctl_json
    # A class regex built to blow up a backtracking engine, against a class
    # that almost matches. grep -E uses an automaton and stays linear; the
    # point of the test is that this returns at all, quickly.
    jq -nc '[{address:"0x1",class:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab",
              title:"t",workspace:{id:1},monitor:0}]' > "$FAKE_CLIENTS"
    printf 'p1\t^(a+)+$\n' > "$SANDBOX/match"
    local start elapsed
    start="$(date +%s)"
    timeout 10 "$WINDOWS_BIN" --match-file "$SANDBOX/match" >/dev/null
    assert_eq "match: a backtracking regex does not hang the matcher" "$?" "0"
    elapsed=$(( $(date +%s) - start ))
    assert_eq "match: it returned in under 5 seconds" \
              "$([[ "$elapsed" -lt 5 ]] && echo fast || echo "slow: ${elapsed}s")" "fast"
    teardown_sandbox
}

# GREP is a named seam, exactly like HYPRCTL -- a bare "grep" call would
# resolve through PATH, and on the machine this was written on that PATH
# resolves to a shell function wrapping a different regex engine than
# /usr/bin/grep. This test exercises the seam itself: a stand-in "grep" on
# $GREP records that it, not some PATH-resolved grep, is what ran, then
# delegates to the real /usr/bin/grep so the match still has to come out
# right.
test_windows_match_file_uses_the_grep_seam() {
    setup_sandbox; fake_hyprctl_json
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"cursor","title":"a","workspace":{"id":6},"monitor":1}]
JSON
    printf 'p1\t^(cursor)$\n' > "$SANDBOX/match"
    export GREP_MARKER="$SANDBOX/grep-was-here"
    cat > "$SANDBOX/bin/grep" <<'FAKE'
#!/usr/bin/env bash
: > "$GREP_MARKER"
exec /usr/bin/grep "$@"
FAKE
    chmod +x "$SANDBOX/bin/grep"
    export GREP="$SANDBOX/bin/grep"
    local out; out="$("$WINDOWS_BIN" --match-file "$SANDBOX/match")"
    assert_eq "match: the GREP seam is honoured, not a bare PATH grep" \
              "$([[ -f "$GREP_MARKER" ]] && echo used || echo "NOT USED")" "used"
    assert_eq "match: and the stand-in still finds the match" \
              "$(jq -r '.[0].address' <<<"$out")" "0x1"
    unset GREP GREP_MARKER
    teardown_sandbox
}

test_windows_match_is_not_confused_by_a_newline_in_a_class() {
    setup_sandbox; fake_hyprctl_json
    # A class with an embedded newline used to become two physical lines in
    # `classes`, shifting every later grep -n line number by one -- so a
    # match on a later, unrelated window's line pointed at the WRONG window.
    # That answer was internally consistent (well-formed address, matching
    # class), so nothing downstream could tell -- buildReconcileChunks would
    # have faithfully generated a move for a real, unrelated window. This is
    # the Task 1 incident class re-entered through text correspondence rather
    # than a Lua selector.
    jq -nc '[{address:"0xAAA",class:"weird
split",title:"t",workspace:{id:1},monitor:0},
             {address:"0xBBB",class:"match-me",title:"t",workspace:{id:1},monitor:0},
             {address:"0xCCC",class:"decoy",title:"t",workspace:{id:1},monitor:0}]' > "$FAKE_CLIENTS"
    printf 'p1\t^match-me$\n' > "$SANDBOX/match"
    local out; out="$("$WINDOWS_BIN" --match-file "$SANDBOX/match")"
    assert_eq "match: a newline in another window's class does not shift the answer" \
              "$(jq -r '.[0].address' <<<"$out")" "0xBBB"
    assert_eq "match: and the reported class is the matched one" \
              "$(jq -r '.[0].class' <<<"$out")" "match-me"
    teardown_sandbox
}

test_windows_match_file_survives_no_trailing_newline() {
    setup_sandbox; fake_hyprctl_json
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"match-me","title":"a","workspace":{"id":1},"monitor":0},
 {"address":"0x2","class":"decoy","title":"b","workspace":{"id":1},"monitor":0}]
JSON
    # No trailing newline after the last line -- printf, not a heredoc, and
    # no final \n. `read` returns failure at end-of-file-without-newline, so
    # a bare "while read; do" silently drops this last line and its program
    # shows as not running for no visible reason.
    printf 'p1\t^(match-me)$\np2\t^(decoy)$' > "$SANDBOX/match"
    local out; out="$("$WINDOWS_BIN" --match-file "$SANDBOX/match")"
    assert_eq "match: the unterminated last line is still read" \
              "$(jq -r '[.[].id] | sort | join(",")' <<<"$out")" "p1,p2"
    teardown_sandbox
}

# The other half of a class claim that spans two suites, the same
# construction as the envelope-wording pair further down.
#
# test/harness.qml proves Model.classLiteral("nimbus-chat.example.org__-Default")
# produces exactly the pattern spelled out below; this proves that pattern,
# fed through the REAL matcher, finds the window it was built from and only
# that one. Neither half alone is worth much: the harness cannot run grep, and
# a shell test cannot reach Model.js -- and what [From window] promises is
# precisely that the two agree. If the escaping changes, the harness
# assertion goes red and this one has to be brought along.
#
# Escaping every metacharacter is what makes the middle window a NON-match:
# unescaped, the dots would be wildcards and "nimbus-webXchatYcom__-Default"
# would match a pattern the user believes names one specific webapp. GNU grep
# warns about the stray "\" before "-" and ":" (the script sends grep's stderr
# to /dev/null) but honours both as literals, which is what this measures.
test_windows_match_accepts_a_class_literal_from_a_window() {
    setup_sandbox; fake_hyprctl_json
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"nimbus-chat.example.org__-Default","title":"a","workspace":{"id":6},"monitor":1},
 {"address":"0x2","class":"nimbus-webXchatYcom__-Default","title":"b","workspace":{"id":1},"monitor":0},
 {"address":"0x3","class":"a-nimbus-chat.example.org__-Default-suffix","title":"c","workspace":{"id":1},"monitor":0}]
JSON
    printf 'p1\t^(nimbus\\-web\\.chat\\.com__\\-Default)$\n' > "$SANDBOX/match"
    local out; out="$("$WINDOWS_BIN" --match-file "$SANDBOX/match")"
    assert_eq "match: a class literal from [From window] matches exactly one window" \
              "$(jq -r 'length' <<<"$out")" "1"
    assert_eq "match: and it is the window the literal was built from" \
              "$(jq -r '.[0].address' <<<"$out")" "0x1"
    assert_eq "match: the escaped dots are literal, so the near-miss is not matched" \
              "$(jq -r '[.[] | select(.address=="0x2")] | length' <<<"$out")" "0"
    assert_eq "match: and the anchors keep the longer class out" \
              "$(jq -r '[.[] | select(.address=="0x3")] | length' <<<"$out")" "0"
    teardown_sandbox
}

test_windows_workspaces_mode
test_windows_match_file
test_match_is_bounded_against_a_backtracking_regex
test_windows_match_file_uses_the_grep_seam
test_windows_match_is_not_confused_by_a_newline_in_a_class
test_windows_match_file_survives_no_trailing_newline
test_windows_match_accepts_a_class_literal_from_a_window

test_generated_lua_compiles() {
    local out_default out_many status_default status_many
    out_default="$(./lua-syntax.sh 2>&1)"; status_default=$?
    out_many="$(./lua-syntax.sh many 2>&1)"; status_many=$?
    assert_eq "lua: every chunk of the default config compiles" "$status_default" "0"
    assert_eq "lua: every chunk of the 25-program config compiles" "$status_many" "0"
    # Named for what they check, not for a number nobody verified: the
    # previous version of this test was named "at least three chunks were
    # checked" but asserted no count at all, only that the substring
    # "lua chunks: total=" appeared -- a mismatch this project has hit
    # before. The default config's five rule statements fit in one chunk, so
    # it never exercised the chunk-boundary packing a real compiler is
    # needed for; the 25-program config forces the 20-rule cap once,
    # producing a second rule chunk with its own CHUNK_PRELUDE and "end".
    assert_eq "lua: the default config compiles both of its chunks" \
              "$(sed -n 's/^lua chunks: total=\([0-9]*\) .*/\1/p' <<<"$out_default")" "2"
    assert_eq "lua: a 25-program config compiles all three of its chunks" \
              "$(sed -n 's/^lua chunks: total=\([0-9]*\) .*/\1/p' <<<"$out_many")" "3"
}

test_generated_lua_compiles

# The other half of the envelope-wording class claim. test/harness.qml proves
# every code in Model.envelopeCodes() has wording; this proves that list IS the
# set of codes the script can answer with. Neither half alone would notice a
# code added to the script with no wording, which is exactly how three of the
# eight went unworded for two rounds.
test_envelope_codes_match_the_script() {
    # BOTH scripts that answer with an envelope, not just the first one. When
    # bin/omarchy-autostart-hypr was added it brought a code of its own
    # ("unreadable"), and a version of this test that named only the config
    # script would have let it reach the user through envelopeText's
    # unknown-code fallback -- worded, but worded as a problem with the
    # configuration file rather than with a Hyprland file. The claim is about
    # the set of codes THE PLUGIN can emit; it has to read every emitter.
    local scripts=("$PWD/../bin/omarchy-autostart-config" "$PWD/../bin/omarchy-autostart-hypr")
    local from_script from_model
    # Both reporters: `err "<code>"` and the hardcoded printf fallbacks that
    # stand in when jq itself cannot build the answer.
    from_script="$( { grep -h -o 'err "[a-z-]*"' "${scripts[@]}" | sed 's/err "//; s/"//'
                      grep -h -o '"error":"[a-z-]*"' "${scripts[@]}" | sed 's/"error":"//; s/"//'
                    } | sort -u | tr '\n' ' ')"
    from_model="$(sed -n '/^function envelopeCodes/,/^}/p' "$PWD/../Model.js" \
                  | grep -o '"[a-z-]*"' | tr -d '"' | sort -u | tr '\n' ' ')"
    assert_eq "envelope: Model.envelopeCodes() is exactly what the two scripts can emit" \
              "$from_model" "$from_script"
    assert_eq "envelope: the extraction found something at all" \
              "$([[ -n "${from_script// /}" ]] && echo yes || echo no)" "yes"
}

test_envelope_codes_match_the_script

# The coupling the two halves of the class-literal claim did NOT have.
#
# test/harness.qml asserts Model.classLiteral produces one exact pattern, and
# test_windows_match_accepts_a_class_literal_from_a_window feeds that pattern
# through the real grep -E. Measured, though: dropping "-" and ":" from the
# escape set turns 2 QML assertions red and 0 shell ones -- the shell side
# carries a HAND-COPIED literal and is indifferent to what classLiteral does.
# So the two halves were about the same string only by the honour system.
#
# This closes it mechanically: the exact literal must be present in both test
# files. Change the escaping and the harness assertion goes red; update the
# harness literal alone and this goes red until the shell fixture is brought
# along. It is the same two-file binding as the envelope codes above and the
# truncation marker in qml-structure.sh.
#
# Fixed-string grep, and the two source forms are identical on purpose: inside
# the QML double-quoted literal and inside the shell printf's single quotes,
# "\\-" is the same four characters on disk.
test_class_literal_fixture_is_the_same_in_both_suites() {
    local literal='^(nimbus\\-web\\.chat\\.com__\\-Default)$'
    assert_eq "class literal: the harness names the exact pattern" \
              "$(grep -cF -- "$literal" harness.qml)" "1"
    assert_eq "class literal: and the matcher test feeds that same pattern to grep -E" \
              "$(grep -cF -- "$literal" run-tests.sh)" "2"
}

test_class_literal_fixture_is_the_same_in_both_suites

test_qml_structure() {
    local out status
    out="$(./qml-structure.sh 2>&1)"; status=$?
    assert_eq "qml: structural checks pass" "$status" "0"
    assert_contains "qml: the checks actually ran" "$out" "qml structure: total="
}

test_qml_structure

test_runners_shape() {
    local out status
    out="$(./runners-shape.sh 2>&1)"; status=$?
    assert_eq "runners shape: F1 status-passthrough checks pass" "$status" "0"
    assert_contains "runners shape: the checks actually ran" "$out" "runners shape: total="
}

test_runners_shape

# --- the reader for the user's own Hyprland Lua files -----------------------
#
# The script under test here is the one that touches the USER'S OWN
# hand-maintained configuration. Every assertion below runs against
# setup_sandbox's redirected XDG_CONFIG_HOME, so "$HOME/.config/hypr" resolves
# inside the sandbox and the real ~/.config/hypr is never opened -- which is
# also asserted, once, at the end.
HYPR_BIN="$PWD/../bin/omarchy-autostart-hypr"

hypr_dir() { printf '%s/hypr' "$XDG_CONFIG_HOME"; }

# The three real forms, verbatim from the user's files. The backslashes are
# doubled here because they are doubled ON DISK: windowrules.lua contains the
# four characters `\\.` and single-quoted printf passes them through unchanged.
write_real_files() {
    mkdir -p "$(hypr_dir)"
    printf '%s\n' \
        '-- Autostart. Portiert aus autostart.conf.' \
        '' \
        '-- Dienstliche Kommunikation' \
        'o.launch_on_start("notes-app")' \
        'o.exec_on_start(o.launch_webapp_sole("Chat", "https://chat.example.org/"))' \
        > "$(hypr_dir)/autostart.lua"
    printf '%s\n' \
        '-- Workspace 8 - KI-Anwendungen' \
        'o.window("LM[- ]?Studio", { workspace = "8" })' \
        'o.window("(nimbus-chatgpt\\.com__-Default)", { workspace = "8" })' \
        > "$(hypr_dir)/windowrules.lua"
    printf '%s\n' \
        'hl.workspace_rule({ workspace = "1", monitor = "DP-4" })' \
        > "$(hypr_dir)/workspaces.lua"
}

test_hypr_read_answers_for_all_three_even_when_none_exists() {
    setup_sandbox
    local out; out="$("$HYPR_BIN" read)"
    assert_eq "hypr: a missing directory is still ok" "$(jq -r .ok <<<"$out")" "true"
    assert_eq "hypr: three entries regardless" "$(jq -r '.files | length' <<<"$out")" "3"
    assert_eq "hypr: in file order" \
              "$(jq -r '[.files[].name] | join(",")' <<<"$out")" \
              "autostart.lua,windowrules.lua,workspaces.lua"
    assert_eq "hypr: an absent file is present:false, not an error" \
              "$(jq -r '[.files[].present] | join(",")' <<<"$out")" "false,false,false"
    assert_eq "hypr: an absent file has mtime 0" \
              "$(jq -r '[.files[].mtime] | join(",")' <<<"$out")" "0,0,0"
    assert_eq "hypr: an absent file has empty content" \
              "$(jq -r '[.files[].content] | join("|")' <<<"$out")" "||"
    assert_eq "hypr: the directory it looked in is named" \
              "$(jq -r .dir <<<"$out")" "$(hypr_dir)"
    teardown_sandbox
}

# THE BYTE-FOR-BYTE CLAIM, and it is the one the later line surgery depends
# on: what the script hands over must be exactly what is on disk. `cmp`
# against the file itself, not a jq-to-jq comparison, because the whole
# hazard is in the crossing -- a `$(...)` capture eats a trailing newline and
# an unquoted expansion mangles a backslash, and windowrules.lua is full of
# backslashes.
test_hypr_read_delivers_the_bytes_unchanged() {
    setup_sandbox
    write_real_files
    local out name; out="$("$HYPR_BIN" read)"
    for name in autostart.lua windowrules.lua workspaces.lua; do
        jq -j --arg n "$name" '.files[] | select(.name == $n) | .content' <<<"$out" \
            > "$SANDBOX/$name.delivered"
        assert_eq "hypr: $name is delivered byte for byte" \
                  "$(cmp -s "$(hypr_dir)/$name" "$SANDBOX/$name.delivered" \
                     && echo identical || echo DIFFERS)" "identical"
    done
    assert_eq "hypr: the doubled backslash survives the crossing" \
              "$(jq -r '.files[1].content' <<<"$out" | grep -c 'chatgpt\\\\\.com')" "1"
    assert_eq "hypr: every present file reports a real mtime" \
              "$(jq -r '[.files[] | select(.mtime > 0)] | length' <<<"$out")" "3"
    teardown_sandbox
}

test_hypr_read_reports_a_present_file_as_present() {
    setup_sandbox
    mkdir -p "$(hypr_dir)"
    printf 'o.launch_on_start("nimbus")\n' > "$(hypr_dir)/autostart.lua"
    local out; out="$("$HYPR_BIN" read)"
    assert_eq "hypr: the one file that exists is present" \
              "$(jq -r '[.files[].present] | join(",")' <<<"$out")" "true,false,false"
    assert_eq "hypr: and it carries its full path" \
              "$(jq -r '.files[0].path' <<<"$out")" "$(hypr_dir)/autostart.lua"
    assert_eq "hypr: an empty file is present with empty content" \
              "$(: > "$(hypr_dir)/workspaces.lua"; "$HYPR_BIN" read \
                 | jq -r '.files[2] | "\(.present):\(.content)"')" "true:"
    teardown_sandbox
}

# A DIRECTORY, A SYMLINK TARGET THAT IS NOT A FILE, AND AN UNREADABLE FILE all
# read as absent rather than as an error envelope. The reason is the same in
# all three: there is nothing to show and nothing a later writer could edit,
# and reporting an error would take the OTHER TWO files off the screen with it.
test_hypr_read_treats_a_non_file_as_absent() {
    setup_sandbox
    mkdir -p "$(hypr_dir)/autostart.lua"
    local out; out="$("$HYPR_BIN" read)"
    assert_eq "hypr: a directory at the path is not an error" "$(jq -r .ok <<<"$out")" "true"
    assert_eq "hypr: a directory at the path reads as absent" \
              "$(jq -r '.files[0].present' <<<"$out")" "false"
    teardown_sandbox
}

test_hypr_read_treats_an_unreadable_file_as_absent() {
    setup_sandbox
    mkdir -p "$(hypr_dir)"
    printf 'o.launch_on_start("nimbus")\n' > "$(hypr_dir)/autostart.lua"
    chmod 000 "$(hypr_dir)/autostart.lua"
    local out; out="$("$HYPR_BIN" read)"
    # Skipped rather than asserted when the test happens to run as a user who
    # can read anything: root would read the file and the assertion would be
    # about the environment, not about the script. Reported either way, so a
    # skip is visible rather than silent.
    if [[ -r "$(hypr_dir)/autostart.lua" ]]; then
        assert_eq "hypr: an unreadable file reads as absent (skipped: readable anyway)" \
                  "skipped" "skipped"
    else
        assert_eq "hypr: an unreadable file reads as absent" \
                  "$(jq -r '.files[0].present' <<<"$out")" "false"
    fi
    assert_eq "hypr: and the envelope is still ok" "$(jq -r .ok <<<"$out")" "true"
    chmod 644 "$(hypr_dir)/autostart.lua"
    teardown_sandbox
}

# The cap, and the exactness of it. MAX+1 bytes are read to DETECT the
# overrun; MAX bytes are what may be handed on. A script that passed the
# detection byte through would give a later writer one byte of content the cap
# says is not there.
test_hypr_read_caps_and_flags_an_oversized_file() {
    setup_sandbox
    mkdir -p "$(hypr_dir)"
    # 64 KiB + 100 bytes.
    head -c $((65536 + 100)) /dev/zero | tr '\0' 'x' > "$(hypr_dir)/windowrules.lua"
    local out; out="$("$HYPR_BIN" read)"
    assert_eq "hypr: an oversized file is delivered, not refused" \
              "$(jq -r '.files[1].present' <<<"$out")" "true"
    assert_eq "hypr: an oversized file is flagged as truncated" \
              "$(jq -r '.files[1].truncated' <<<"$out")" "true"
    assert_eq "hypr: an oversized file is cut to exactly the cap" \
              "$(jq -r '.files[1].content' <<<"$out" | wc -c)" "65537"
    assert_eq "hypr: a file at the cap is NOT flagged" \
              "$(head -c 65536 /dev/zero | tr '\0' 'y' > "$(hypr_dir)/windowrules.lua"; \
                 "$HYPR_BIN" read | jq -r '.files[1].truncated')" "false"
    teardown_sandbox
}

# READ ONLY, ASSERTED. Not "the script has no write function" as prose in a
# comment: the three files are checksummed before and after a read, and the
# script is grepped for the verbs that could change one. The plugin is
# installed and live on the user's machine while this is being built, and this
# is the assertion that says so out loud.
test_hypr_read_changes_nothing() {
    setup_sandbox
    write_real_files
    local before after
    before="$(cd "$(hypr_dir)" && sha256sum autostart.lua windowrules.lua workspaces.lua)"
    "$HYPR_BIN" read >/dev/null
    "$HYPR_BIN" read >/dev/null
    after="$(cd "$(hypr_dir)" && sha256sum autostart.lua windowrules.lua workspaces.lua)"
    assert_eq "hypr: reading twice changes not one byte of the three files" "$after" "$before"
    assert_eq "hypr: nothing new appeared beside them" \
              "$(cd "$(hypr_dir)" && ls -1 | sort | tr '\n' ' ')" \
              "autostart.lua windowrules.lua workspaces.lua "
    # No subcommand but `read`, and no verb in the file that could publish
    # over one of the user's paths. `mv`, `>`-into-$HYPR_DIR and `tee` are the
    # three shapes a write would plausibly arrive in.
    assert_eq "hypr: there is no write subcommand" \
              "$(printf 'x' | "$HYPR_BIN" write --expect-mtime 1 >/dev/null 2>&1; echo $?)" "2"
    assert_eq "hypr: nothing in the script targets HYPR_DIR for writing" \
              "$(grep -cE '(>|>>|tee|mv[^|]*)[[:space:]]*"?\$HYPR_DIR' "$HYPR_BIN" || true)" "0"
    assert_eq "hypr: nothing in the script writes to \$path" \
              "$(grep -cE '(>|>>|tee)[[:space:]]*"\$path"' "$HYPR_BIN" || true)" "0"
    teardown_sandbox
}

# The seam, checked the same way the apps reader's is: the script must resolve
# its directory from XDG_CONFIG_HOME, because that redirect is the ONLY thing
# keeping every assertion above off the real ~/.config/hypr. A script that
# hardcoded the path would pass every other test in this file while reading
# the user's live configuration.
test_hypr_read_resolves_its_directory_from_the_sandbox() {
    setup_sandbox
    write_real_files
    local out; out="$("$HYPR_BIN" read)"
    assert_eq "hypr: the directory read lies inside the sandbox" \
              "$(case "$(jq -r .dir <<<"$out")" in "$SANDBOX"/*) echo inside ;; *) echo "OUTSIDE" ;; esac)" \
              "inside"
    assert_eq "hypr: no absolute /home path is baked into the script" \
              "$(grep -cE '/home/|/\.config/hypr' "$HYPR_BIN" || true)" "0"
    teardown_sandbox
}

test_hypr_read_answers_for_all_three_even_when_none_exists
test_hypr_read_delivers_the_bytes_unchanged
test_hypr_read_reports_a_present_file_as_present
test_hypr_read_treats_a_non_file_as_absent
test_hypr_read_treats_an_unreadable_file_as_absent
test_hypr_read_caps_and_flags_an_oversized_file
test_hypr_read_changes_nothing
test_hypr_read_resolves_its_directory_from_the_sandbox

# --- bin/omarchy-autostart-hypr-write --------------------------------------
#
# THE WRITER, and the file it writes RUNS AT EVERY LOGIN. A malformed
# autostart.lua means the user's programs do not start and Hyprland reports a
# Lua error when he logs in, so every refusal below also asserts that THE
# ORIGINAL IS BYTE-IDENTICAL afterwards, with `cmp` against a copy taken
# before the attempt -- not by re-reading a field the script itself produced.
#
# The content is never built here. It comes finished from
# Model.autostartApply(), whose cases are byte-exact assertions in
# test/harness.qml; this script owns only the freshness check, the
# permissions, the backup, the luac5.1 gate and the atomic rename.
#
# Every assertion runs against setup_sandbox's redirected XDG_CONFIG_HOME. The
# real ~/.config/hypr is never opened, which is asserted once at the end.
WRITE_BIN="$PWD/../bin/omarchy-autostart-hypr-write"

# The script with its whole-line comments removed. Several assertions below
# ask whether the script NAMES something, and this script's comments name
# every one of those things in order to say that it does not do them.
write_code() { grep -v '^[[:space:]]*#' "$WRITE_BIN"; }

autostart_path() { printf '%s/hypr/autostart.lua' "$XDG_CONFIG_HOME"; }
autostart_mtime() { stat -c %Y "$(autostart_path)"; }

# The user's own file, and the reason it is spelled out rather than copied
# from ~/.config/hypr: a test must never READ from there either, so that a
# change to his file cannot change what this suite asserts.
write_autostart_fixture() {
    mkdir -p "$(hypr_dir)"
    printf '%s\n' \
        '-- Autostart. Portiert aus autostart.conf.' \
        '' \
        '-- Dienstliche Kommunikation' \
        'o.launch_on_start("notes-app")' \
        'o.exec_on_start(o.launch_webapp_sole("Chat", "https://chat.example.org/"))' \
        > "$(autostart_path)"
    chmod 644 "$(autostart_path)"
    cp -p "$(autostart_path)" "$SANDBOX/before.lua"
}

# The candidate a successful write publishes: the fixture with one more line,
# which is what "add" produces.
write_good_candidate() {
    cat "$SANDBOX/before.lua"
    printf '%s\n' 'o.launch_on_start("obsidian")'
}

assert_original_untouched() {
    local name="$1"
    assert_eq "$name" \
              "$(cmp -s "$SANDBOX/before.lua" "$(autostart_path)" \
                 && echo identical || echo CHANGED)" "identical"
}

# No dotfile left beside the user's own configuration after a refusal. The
# staged replacement lives in his directory by necessity -- a rename is only
# atomic within one filesystem -- so the cleanup for it is load-bearing.
assert_nothing_staged() {
    local name="$1" left
    left="$(ls -A "$(hypr_dir)" | grep -c '^\.autostart' || true)"
    assert_eq "$name" "$left" "0"
}

test_write_publishes_a_good_candidate() {
    setup_sandbox
    write_autostart_fixture
    local out; out="$(write_good_candidate | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)")"
    assert_eq "write: it succeeds" "$(jq -r .ok <<<"$out")" "true"
    assert_eq "write: it reports the new mtime" \
              "$(jq -r .mtime <<<"$out")" "$(autostart_mtime)"
    write_good_candidate > "$SANDBOX/expected.lua"
    assert_eq "write: the published file is exactly the candidate" \
              "$(cmp -s "$SANDBOX/expected.lua" "$(autostart_path)" \
                 && echo identical || echo DIFFERENT)" "identical"
    assert_nothing_staged "write: nothing is left staged after a publish"
    assert_eq "write: the mode of the original is kept" \
              "$(stat -c %a "$(autostart_path)")" "644"
    # ATOMIC means the rename happens within one filesystem, which means the
    # staged file has to live in the DESTINATION's directory -- a $TMPDIR stage
    # would turn `mv` into a copy-then-unlink with a window in which
    # autostart.lua is half written. Nothing observable distinguishes the two
    # after the fact, so this is asserted on the code.
    assert_eq "write: the replacement is staged in the destination's own directory" \
              "$(write_code | grep -cF 'mktemp "$HYPR_DIR/' || true)" "1"
    teardown_sandbox
}

# THE ONLY WAY BACK. ~/.config/hypr is not under version control, so this copy
# is it -- and it has to hold the OLD content, not the new one.
test_write_backs_the_old_content_up() {
    setup_sandbox
    write_autostart_fixture
    write_good_candidate | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)" >/dev/null
    assert_eq "write: the backup exists" \
              "$([[ -f "$(autostart_path).bak" ]] && echo yes || echo no)" "yes"
    assert_eq "write: and it holds the content that was replaced" \
              "$(cmp -s "$SANDBOX/before.lua" "$(autostart_path).bak" \
                 && echo identical || echo DIFFERENT)" "identical"
    assert_eq "write: the answer names the backup it took" \
              "$(write_good_candidate | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)" \
                 | jq -r .backup)" "$(autostart_path).bak"
    # One step back, overwritten: after a second write the backup is the file
    # as it stood before THAT write, not the original from two writes ago.
    cp -p "$(autostart_path)" "$SANDBOX/second-before.lua"
    printf '%s\n' 'o.launch_on_start("x")' | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)" >/dev/null
    assert_eq "write: the backup is one step back, not a history" \
              "$(cmp -s "$SANDBOX/second-before.lua" "$(autostart_path).bak" \
                 && echo identical || echo DIFFERENT)" "identical"
    teardown_sandbox
}

# THE luac5.1 GATE, and it is the strongest assurance in this task: a
# candidate that would not compile never reaches the destination.
test_write_refuses_a_candidate_that_does_not_compile() {
    setup_sandbox
    write_autostart_fixture
    local out; out="$(printf 'o.launch_on_start("nimbus\n' \
                      | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)")"
    assert_eq "write: a broken candidate is refused" "$(jq -r .ok <<<"$out")" "false"
    assert_eq "write: and says which refusal it is" \
              "$(jq -r .error <<<"$out")" "does-not-compile"
    assert_contains "write: the compiler's own diagnostic is passed through" \
                    "$(jq -r .detail <<<"$out")" "unfinished string"
    assert_contains "write: and it names the file the user knows, not the staged one" \
                    "$(jq -r .detail <<<"$out")" "autostart.lua:1:"
    assert_original_untouched "write: THE ORIGINAL IS BYTE-IDENTICAL after a refused candidate"
    assert_eq "write: and no backup was taken for a write that did not happen" \
              "$([[ -e "$(autostart_path).bak" ]] && echo TAKEN || echo none)" "none"
    assert_nothing_staged "write: nothing is left staged after a refused candidate"
    teardown_sandbox
}

# The gate CHECKS and does not RUN. Measured on this machine: `luac5.1 -p` on a
# file whose body is `print(...)` plus `os.exit(7)` exits 0 and prints nothing.
# If the gate ever executed the candidate, this write would take the marker
# file with it.
test_write_never_executes_the_candidate() {
    setup_sandbox
    write_autostart_fixture
    printf '%s\n' 'local f = io.open("'"$SANDBOX"'/executed", "w") f:write("x") f:close()' \
        | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)" >/dev/null
    assert_eq "write: the gate compiled the candidate without running it" \
              "$([[ -e "$SANDBOX/executed" ]] && echo EXECUTED || echo compiled-only)" \
              "compiled-only"
    teardown_sandbox
}

# THE FRESHNESS CHECK. This is a file the user also maintains by hand: if the
# mtime is not the one the panel read, every line number the caller carries
# may now mean a different line.
test_write_refuses_a_stale_expectation() {
    setup_sandbox
    write_autostart_fixture
    local out; out="$(write_good_candidate | "$WRITE_BIN" write --expect-mtime 1)"
    assert_eq "write: a stale mtime is refused" "$(jq -r .ok <<<"$out")" "false"
    assert_eq "write: and says which refusal it is" "$(jq -r .error <<<"$out")" "stale"
    assert_contains "write: it names both mtimes" "$(jq -r .detail <<<"$out")" \
                    "caller expected 1"
    assert_original_untouched "write: THE ORIGINAL IS BYTE-IDENTICAL after a stale refusal"
    assert_nothing_staged "write: nothing is left staged after a stale refusal"
    # And a file touched between the read and the write is exactly that case.
    local mtime; mtime="$(autostart_mtime)"
    touch -d "@$((mtime + 60))" "$(autostart_path)"
    assert_eq "write: a file touched since the read is refused" \
              "$(write_good_candidate | "$WRITE_BIN" write --expect-mtime "$mtime" | jq -r .error)" \
              "stale"
    teardown_sandbox
}

test_write_refuses_what_it_must_not_write_through() {
    setup_sandbox
    write_autostart_fixture
    # A symlink, named as one rather than blamed on permissions: a link could
    # point into a directory somebody else controls.
    mv "$(autostart_path)" "$(hypr_dir)/real.lua"
    ln -s "$(hypr_dir)/real.lua" "$(autostart_path)"
    assert_eq "write: a symlink is refused" \
              "$(write_good_candidate | "$WRITE_BIN" write --expect-mtime "$(stat -Lc %Y "$(autostart_path)")" \
                 | jq -r .error)" "is-a-symlink"
    assert_eq "write: and the file it pointed at is untouched" \
              "$(cmp -s "$SANDBOX/before.lua" "$(hypr_dir)/real.lua" \
                 && echo identical || echo CHANGED)" "identical"
    rm -f "$(autostart_path)"
    mv "$(hypr_dir)/real.lua" "$(autostart_path)"

    # A group-writable file: the lines in it are command lines run at login, so
    # a foreign writer here is a foreign writer in the user's session.
    chmod g+w "$(autostart_path)"
    assert_eq "write: a group-writable file is refused" \
              "$(write_good_candidate | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)" \
                 | jq -r .error)" "insecure-permissions"
    assert_original_untouched "write: THE ORIGINAL IS BYTE-IDENTICAL after a permission refusal"
    chmod 644 "$(autostart_path)"

    # A group-writable directory is enough on its own: the file can simply be
    # replaced.
    chmod g+w "$(hypr_dir)"
    assert_eq "write: a group-writable directory is refused" \
              "$(write_good_candidate | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)" \
                 | jq -r .error)" "insecure-permissions"
    chmod 755 "$(hypr_dir)"

    # A file that is not there is not written INTO EXISTENCE: this writer does
    # surgery on bytes that were read, and Omarchy ships an autostart.lua.
    rm -f "$(autostart_path)"
    assert_eq "write: an absent file is refused rather than created" \
              "$(write_good_candidate | "$WRITE_BIN" write --expect-mtime 0 | jq -r .error)" \
              "not-a-file"
    assert_eq "write: and it was not created after all" \
              "$([[ -e "$(autostart_path)" ]] && echo CREATED || echo absent)" "absent"

    # A directory at that path is not a plain file either.
    mkdir -p "$(autostart_path)"
    assert_eq "write: a directory at that path is refused" \
              "$(write_good_candidate | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)" \
                 | jq -r .error)" "not-a-file"
    rmdir "$(autostart_path)"
    teardown_sandbox
}

test_write_refuses_an_oversized_candidate() {
    setup_sandbox
    write_autostart_fixture
    # 64 KiB + 1, and it has to be VALID Lua so that the size refusal is what
    # is being measured rather than the syntax gate. A comment line of the
    # right length compiles and is over the cap.
    local out
    out="$({ printf -- '-- '; head -c 65532 /dev/zero | tr '\0' 'x'; printf '\n'; } \
           | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)")"
    assert_eq "write: a candidate at the cap is accepted" "$(jq -r .ok <<<"$out")" "true"
    cp -p "$(autostart_path)" "$SANDBOX/before.lua"
    out="$({ printf -- '-- '; head -c 65533 /dev/zero | tr '\0' 'x'; printf '\n'; } \
           | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)")"
    assert_eq "write: one byte past the cap is refused" "$(jq -r .error <<<"$out")" "too-large"
    assert_original_untouched "write: THE ORIGINAL IS BYTE-IDENTICAL after a size refusal"
    assert_nothing_staged "write: nothing is left staged after a size refusal"
    teardown_sandbox
}

test_write_has_one_envelope_and_one_usage() {
    setup_sandbox
    write_autostart_fixture
    # Every path is exactly one JSON object on stdout, so a caller parses one
    # shape and can always tell why.
    local path
    for path in stale broken permissions; do
        local out
        case "$path" in
            stale)       out="$(write_good_candidate | "$WRITE_BIN" write --expect-mtime 1)" ;;
            broken)      out="$(printf 'o.launch(\n' | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)")" ;;
            permissions) chmod g+w "$(autostart_path)"
                         out="$(write_good_candidate | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)")"
                         chmod 644 "$(autostart_path)" ;;
        esac
        assert_eq "write: the $path path is exactly one JSON object" \
                  "$(jq -sr 'length' <<<"$out")" "1"
        assert_eq "write: the $path path exits 0 so the answer is readable" \
                  "$(jq -r 'has("ok")' <<<"$out")" "true"
    done

    # Usage errors are status 2 and NOT an envelope: they are a caller bug, not
    # an outcome of a write.
    assert_eq "write: no subcommand is a usage error" \
              "$("$WRITE_BIN" >/dev/null 2>&1; echo $?)" "2"
    assert_eq "write: a wrong subcommand is a usage error" \
              "$("$WRITE_BIN" read >/dev/null 2>&1; echo $?)" "2"
    assert_eq "write: no --expect-mtime is a usage error" \
              "$(printf 'x' | "$WRITE_BIN" write >/dev/null 2>&1; echo $?)" "2"
    assert_eq "write: a non-numeric --expect-mtime is a usage error" \
              "$(printf 'x' | "$WRITE_BIN" write --expect-mtime abc >/dev/null 2>&1; echo $?)" "2"
    # A BARE TRAILING --expect-mtime, and this is the bash detail task 4 was
    # bitten by: `shift 2` with one parameter left is a no-op, so a loop that
    # trusts it spins forever. Bounded by `timeout` so a regression fails
    # instead of hanging the suite.
    assert_eq "write: a bare trailing --expect-mtime terminates rather than spinning" \
              "$(printf 'x' | timeout 10 "$WRITE_BIN" write --expect-mtime >/dev/null 2>&1; echo $?)" "2"
    assert_original_untouched "write: no usage error touched the file"
    teardown_sandbox
}

# The two files this plugin does NOT write, and the two things this script
# does NOT do.
test_write_touches_only_autostart_lua() {
    setup_sandbox
    write_real_files
    cp -p "$(hypr_dir)/windowrules.lua" "$SANDBOX/wr.before"
    cp -p "$(hypr_dir)/workspaces.lua" "$SANDBOX/ws.before"
    printf '%s\n' 'o.launch_on_start("x")' \
        | "$WRITE_BIN" write --expect-mtime "$(autostart_mtime)" >/dev/null
    assert_eq "write: windowrules.lua is untouched" \
              "$(cmp -s "$SANDBOX/wr.before" "$(hypr_dir)/windowrules.lua" \
                 && echo identical || echo CHANGED)" "identical"
    assert_eq "write: workspaces.lua is untouched" \
              "$(cmp -s "$SANDBOX/ws.before" "$(hypr_dir)/workspaces.lua" \
                 && echo identical || echo CHANGED)" "identical"
    # There is no path in this script that can be pointed at another file, and
    # no compositor call of any kind: a change takes effect at the next login.
    #
    # THE CODE, NOT THE PROSE. These four greps read write_code, which drops
    # whole-line `#` comments -- the script EXPLAINS in comments that it never
    # calls hyprctl and that the other two files are read-only, and a grep
    # over the raw file counts those sentences as hits. That is the same trap
    # test/qml-structure.sh's strip_comments exists for, one language over:
    # a check a comment can satisfy -- or defeat -- is not a check.
    assert_eq "write: it names no second file to write" \
              "$(write_code | grep -cE 'windowrules|workspaces' || true)" "0"
    assert_eq "write: it never calls hyprctl" \
              "$(write_code | grep -cE 'hyprctl' || true)" "0"
    assert_eq "write: it takes no --file option" \
              "$(write_code | grep -cE -- '--file' || true)" "0"
    # The real ~/.config/hypr is unreachable from here: the path is resolved
    # from XDG_CONFIG_HOME and no absolute home path is spelled anywhere.
    assert_eq "write: no absolute path into a real home directory" \
              "$(write_code | grep -cE '/home/|/\.config/hypr' || true)" "0"
    # The stripper itself has to be doing something, or all four above are
    # vacuous: the raw file DOES contain those words, in its comments.
    assert_eq "write: the comment stripper actually removes lines" \
              "$([[ "$(write_code | wc -l)" -lt "$(wc -l < "$WRITE_BIN")" ]] \
                 && echo stripped || echo NOTHING-STRIPPED)" "stripped"
    assert_eq "write: and the prose it removes really does mention hyprctl" \
              "$(grep -cE '^[[:space:]]*#.*hyprctl' "$WRITE_BIN" || true)" "1"
    teardown_sandbox
}

# The gate is a REFUSAL when the compiler is missing, never a silent skip.
# Skipping it is the one failure mode this script exists to prevent.
test_write_refuses_when_there_is_no_lua_compiler() {
    setup_sandbox
    write_autostart_fixture
    # The resolution loop names three absolute candidates and verifies each by
    # running it, so the only honest way to simulate absence is to make each
    # one fail its own check. A copy of the script with the candidate list
    # pointed at the sandbox does exactly that and changes nothing else.
    sed 's#for candidate in /usr/bin/luac5.1 /usr/bin/luac /usr/bin/luac5.4; do#for candidate in "$SANDBOX/no-luac"; do#' \
        "$WRITE_BIN" > "$SANDBOX/write-no-luac"
    chmod +x "$SANDBOX/write-no-luac"
    assert_eq "write: the substitution actually took" \
              "$(grep -c 'SANDBOX/no-luac' "$SANDBOX/write-no-luac")" "1"
    local out; out="$(write_good_candidate \
                      | SANDBOX="$SANDBOX" "$SANDBOX/write-no-luac" write --expect-mtime "$(autostart_mtime)")"
    assert_eq "write: no compiler is a refusal, not a skipped gate" \
              "$(jq -r .error <<<"$out")" "no-lua-compiler"
    assert_original_untouched "write: THE ORIGINAL IS BYTE-IDENTICAL when the gate cannot run"
    teardown_sandbox
}

test_write_publishes_a_good_candidate
test_write_backs_the_old_content_up
test_write_refuses_a_candidate_that_does_not_compile
test_write_never_executes_the_candidate
test_write_refuses_a_stale_expectation
test_write_refuses_what_it_must_not_write_through
test_write_refuses_an_oversized_candidate
test_write_has_one_envelope_and_one_usage
test_write_touches_only_autostart_lua
test_write_refuses_when_there_is_no_lua_compiler

MARKER_BIN="$PWD/../bin/omarchy-autostart-marker"

# The marker script has six branches: no signature, an implausible (but
# non-empty) signature, mkdir failing, a claim winning the noclobber race, a
# claim losing it, and release. A mutation probe found the original four
# tests here bound only mutual exclusion: dropping the empty-signature
# check, the signature regex, or the mkdir guard left all four green,
# because each of those three guards' removal still falls through to
# ANOTHER guard that also exits 1 -- same status, different (or no) reason.
# Every test below checks the REASON, not just the exit status: the exact
# stderr text for the three guards that print one, and marker-file
# existence for the two branches (claim-wins, release) that print nothing at
# all. That is what makes "turn off exactly this guard" turn exactly one
# test red -- see the per-guard mutation table in task-13-report.md.
marker_dir() { printf '%s/smartalb.autostart' "$XDG_RUNTIME_DIR"; }
marker_path() { printf '%s/%s' "$(marker_dir)" "$1"; }
marker_stderr() { "$MARKER_BIN" "$@" 2>&1 1>/dev/null; }

test_marker_refuses_without_a_signature() {
    setup_sandbox
    unset HYPRLAND_INSTANCE_SIGNATURE
    assert_status "marker: no instance signature, no claim" 1 "$MARKER_BIN" claim
    assert_eq     "marker: no-signature reason is exact, not incidental" \
                  "$(marker_stderr claim)" "no HYPRLAND_INSTANCE_SIGNATURE"
    teardown_sandbox
}

test_marker_refuses_an_implausible_signature() {
    setup_sandbox
    # Non-empty, so this exercises the REGEX guard specifically -- the
    # empty-signature guard above it would not fire for this input, and if
    # the regex guard itself were removed this would fall through to
    # mkdir/noclobber and very likely succeed instead of refusing.
    export HYPRLAND_INSTANCE_SIGNATURE="bad sig/with space"
    assert_status "marker: an implausible signature refuses the claim" 1 "$MARKER_BIN" claim
    assert_eq     "marker: implausible-signature reason is exact, not incidental" \
                  "$(marker_stderr claim)" "implausible signature"
    teardown_sandbox
}

test_marker_refuses_when_it_cannot_write() {
    setup_sandbox
    export HYPRLAND_INSTANCE_SIGNATURE="sig-a"
    chmod 500 "$XDG_RUNTIME_DIR"
    local expected_dir; expected_dir="$(marker_dir)"
    # Refusing means the autostart is SKIPPED. A doubled session is worse than
    # one that did not start: without a marker a shell restart launches
    # everything a second time.
    assert_status "marker: an unwritable runtime dir refuses the claim" 1 "$MARKER_BIN" claim
    assert_eq     "marker: cannot-write reason is exact, not incidental" \
                  "$(marker_stderr claim)" "cannot create $expected_dir"
    chmod 700 "$XDG_RUNTIME_DIR"
    teardown_sandbox
}

test_marker_claim_creates_the_marker_file() {
    setup_sandbox
    export HYPRLAND_INSTANCE_SIGNATURE="sig-a"
    assert_status "marker: the first claim succeeds" 0 "$MARKER_BIN" claim
    assert_eq     "marker: a successful claim leaves the marker file behind" \
                  "$([[ -e "$(marker_path sig-a)" ]] && echo present || echo missing)" "present"
    teardown_sandbox
}

test_marker_claims_once_per_hyprland_instance() {
    setup_sandbox
    export HYPRLAND_INSTANCE_SIGNATURE="sig-a"
    "$MARKER_BIN" claim >/dev/null
    assert_status "marker: the second claim is refused" 1 "$MARKER_BIN" claim
    # Branch 5 (noclobber lost the race) prints NOTHING to stderr, unlike
    # every other refusal above -- that silence is what tells it apart from
    # falling through into one of the earlier, message-printing guards. A
    # mutation that turns `claim` into a bare `exit 0` (skip the noclobber
    # check entirely) is caught by the status assertion above; a mutation
    # that instead made a LOST race print a message would be caught here.
    assert_eq     "marker: a lost claim race is silent, not a reused message" \
                  "$(marker_stderr claim)" ""
    export HYPRLAND_INSTANCE_SIGNATURE="sig-b"
    assert_status "marker: a new instance claims again" 0 "$MARKER_BIN" claim
    teardown_sandbox
}

test_marker_release_removes_the_marker_file() {
    setup_sandbox
    export HYPRLAND_INSTANCE_SIGNATURE="sig-a"
    "$MARKER_BIN" claim >/dev/null
    assert_status "marker: release succeeds" 0 "$MARKER_BIN" release
    assert_eq     "marker: release actually removes the marker file" \
                  "$([[ -e "$(marker_path sig-a)" ]] && echo present || echo missing)" "missing"
    assert_status "marker: after release a claim works again" 0 "$MARKER_BIN" claim
    teardown_sandbox
}

test_marker_refuses_without_a_signature
test_marker_refuses_an_implausible_signature
test_marker_refuses_when_it_cannot_write
test_marker_claim_creates_the_marker_file
test_marker_claims_once_per_hyprland_instance
test_marker_release_removes_the_marker_file

# --- the submission set: manifest, installer, README, preview --------------
#
# DEVIATION FROM THE TASK BRIEF, and it is the whole point of these checks.
#
# The brief's Step 1 asserted `kinds: ["bar-widget", "panel", "service"]` with
# an `entryPoints.panel`. Read against the platform installed on this machine,
# that is wrong twice over:
#
#   * /usr/share/omarchy/shell/shell.qml:429-436 (isBarWidgetPanelPlugin)
#     routes summon/hide/toggle to the live bar instance ONLY for a plugin
#     that declares "bar-widget" and none of panel/overlay/menu. Declaring
#     "panel" hands the plugin to the panel loader instead, and the bar entry
#     stops answering the hotkeys.
#   * computePanelEntries() (shell.qml:585-601) then builds a SECOND Loader
#     for entryPoints.panel, so Panel.qml is instantiated twice: once by
#     BarWidget.qml's own Loader and once by the shell.
#
# The shipped plugin that has exactly our shape confirms it:
# /usr/share/omarchy/shell/plugins/panels/clock/manifest.json ships a
# Panel.qml, declares kinds ["bar-widget"] alone, and reaches its panel
# through the widget's Loader.
#
# "service", by contrast, IS required and is NOT one of the harmful kinds:
# nothing in this plugin instantiates Service.qml, so without the kind and
# its entry point the autostart never runs at login (shell.qml:265-341,
# _syncServices). It is absent from the loaderKinds list, so it does not
# divert the bar routing.
test_manifest_is_sound() {
    local root="$PWD/.." m="$PWD/../manifest.json"
    assert_status "manifest: is valid JSON" 0 jq -e . "$m"
    assert_eq "manifest: id"            "$(jq -r .id "$m")"            "smartalb.autostart"
    assert_eq "manifest: schemaVersion is the number 1, not the string" \
              "$(jq -r '.schemaVersion == 1' "$m")" "true"
    assert_eq "manifest: name"          "$(jq -r .name "$m")"          "Autostart Layout"
    assert_eq "manifest: version"       "$(jq -r .version "$m")"       "1.0.0"
    assert_eq "manifest: license"       "$(jq -r .license "$m")"       "MIT"
    assert_eq "manifest: not in the omarchy namespace" \
              "$(jq -r '.id | startswith("omarchy.")' "$m")" "false"

    # The positive half.
    for kind in bar-widget service; do
        assert_eq "manifest: declares kind $kind" \
                  "$(jq -r --arg k "$kind" '.kinds | index($k) != null' "$m")" "true"
    done
    for pair in "barWidget:BarWidget.qml" "service:Service.qml"; do
        local key="${pair%%:*}" file="${pair#*:}"
        assert_eq "manifest: entryPoint $key" \
                  "$(jq -r --arg k "$key" '.entryPoints[$k]' "$m")" "$file"
        assert_eq "manifest: $file exists" \
                  "$([[ -f "$root/$file" ]] && echo yes || echo no)" "yes"
    done

    # The negative half, which is the half that matters. Each of these four
    # kinds would move this plugin off the bar-widget route.
    for kind in panel overlay menu bar; do
        assert_eq "manifest: does NOT declare kind $kind" \
                  "$(jq -r --arg k "$kind" '.kinds | index($k) != null' "$m")" "false"
    done
    assert_eq "manifest: declares no kind beyond those two" \
              "$(jq -r '.kinds | sort | join(",")' "$m")" "bar-widget,service"
    assert_eq "manifest: entryPoints has no panel key either" \
              "$(jq -r '.entryPoints | has("panel")' "$m")" "false"
    # ... and Panel.qml is still shipped, because the widget's own Loader
    # opens it. A manifest with no panel kind and no Panel.qml on disk is a
    # plugin whose button does nothing.
    assert_eq "manifest: Panel.qml ships anyway, for the widget's Loader" \
              "$([[ -f "$root/Panel.qml" ]] && echo yes || echo no)" "yes"

    # KIND AND ENTRY POINT ARE ONE FACT, NOT TWO. `shell.qml:289-290` needs
    # BOTH to instantiate a service -- the kind gates it, the entry point
    # supplies the file -- and the same pair guards the loop at :329-330. A
    # manifest carrying one without the other installs, enables, validates
    # clean, and does nothing: that is why the assertions above pin each half
    # by name AND this one refuses the inconsistent pair in either direction.
    #
    # `omarchy plugin validate` checks only kind -> entryPoint. The reverse
    # direction is a real gap: an `entryPoints.overlay` with no overlay kind
    # passes every other assertion in this function (it is not `panel`, and
    # the kinds list is unchanged) and passes the platform validator too.
    # It is inert at runtime, and it is one edit away from being read as an
    # intent to declare the kind.
    local kind_table='{"bar":"bar","bar-widget":"barWidget","menu":"menu","overlay":"overlay","panel":"panel","service":"service"}'
    local pair_program='
      . as $m
      | [ $m.kinds[]
          | select($t[.] != null) as $k
          | select(($m.entryPoints | has($t[$k])) | not)
          | "kind \($k) declares no entryPoints.\($t[$k])" ]
      + [ ($m.entryPoints | keys[]) as $ep
          | ($t | to_entries | map(select(.value == $ep)) | .[0].key) as $k
          | select($k != null)
          | select(($m.kinds | index($k)) == null)
          | "entryPoints.\($ep) declares no kind \($k)" ]
      | join("; ")'
    assert_eq "manifest: every kind has its entry point and every entry point its kind" \
              "$(jq -r --argjson t "$kind_table" "$pair_program" "$m")" ""
    # Fail-closed: a table that recognises none of this manifest's kinds would
    # make the assertion above vacuously green, which is the blind shape one
    # level up.
    assert_eq "manifest: the pair check actually examined both declared kinds" \
              "$(jq -r --argjson t "$kind_table" '[.kinds[] | select($t[.] != null)] | length' "$m")" \
              "2"

    assert_eq "manifest: defaultSection is one the registry accepts" \
              "$(jq -r '.barWidget.defaultSection' "$m")" "right"
    assert_eq "manifest: allowMultiple is off" \
              "$(jq -r '.barWidget.allowMultiple' "$m")" "false"
}

test_repository_has_what_validation_looks_for() {
    local root="$PWD/.."
    for f in README.md LICENSE CHECKLIST.md manifest.json; do
        assert_eq "root: $f is present" \
                  "$([[ -f "$root/$f" ]] && echo yes || echo no)" "yes"
    done
    assert_eq "root: no symlink anywhere in the plugin" \
              "$(find "$root" -name .git -prune -o -type l -print | wc -l)" "0"
}

# preview.png CANNOT be produced by anything in this project: it is a
# screenshot of the running panel, and nothing here may load the panel into a
# live shell. A test that simply demands the file would therefore be a test
# that can only be satisfied by fabricating one, and a fabricated screenshot
# is worse than a missing one.
#
# So this asserts the honest property instead, and it holds in BOTH states:
# either the file is there and is a real PNG, or it is not there and the
# shipped checklist still names it as owed. What it refuses is the third
# state -- gone from disk AND gone from the checklist -- which is how an
# obligation quietly disappears.
test_the_preview_is_either_taken_or_still_owed() {
    local root="$PWD/.." state
    if [[ -f "$root/preview.png" ]]; then
        if [[ "$(od -An -tx1 -N8 < "$root/preview.png" | tr -d ' \n')" == "89504e470d0a1a0a" ]]; then
            state="present as a real PNG"
        else
            state="PRESENT BUT NOT A PNG -- a placeholder is not a screenshot"
        fi
    elif grep -q 'preview\.png' "$root/CHECKLIST.md" 2>/dev/null; then
        state="absent, and the checklist names it as owed"
    else
        state="ABSENT AND UNRECORDED -- neither taken nor owed by anyone"
    fi
    case "$state" in
        "present as a real PNG"|"absent, and the checklist names it as owed")
            state="accounted for" ;;
    esac
    assert_eq "preview: the screenshot is either taken or still owed in writing" \
              "$state" "accounted for"

    # AND THE README MUST BE CORRECT IN WHICHEVER STATE THAT IS. The README
    # shipped for a while with `![...](preview.png)` at line 6 pointing at a
    # file that did not exist: every suite green, and a broken image as the
    # first thing on the first page a marketplace reviewer opens. The
    # assertion above passes in both states by design, so on its own it could
    # never have caught that.
    #
    # So the two are coupled, and the coupling holds in both directions:
    # no file means no reference, and a file that exists must be shown.
    # CHECKLIST.md A1 carries the exact line to paste when the screenshot is
    # taken, which is what makes the second direction satisfiable.
    local refs coupling
    refs="$(grep -c '](preview\.png)' "$root/README.md" || true)"
    if [[ -f "$root/preview.png" ]]; then
        [[ "$refs" -ge 1 ]] && coupling="consistent" \
            || coupling="preview.png exists but README.md never shows it"
    else
        [[ "$refs" -eq 0 ]] && coupling="consistent" \
            || coupling="README.md links preview.png ($refs time(s)) but the file does not exist -- a broken image on the first page"
    fi
    assert_eq "preview: the README matches whether the screenshot exists" \
              "$coupling" "consistent"
}

# The security baseline reads the README too. On smartalb.vpn four pacman lines
# in prose raised the privilege and package-manager capabilities and cost a
# round of manual review. This plugin needs no privilege at all, so the words
# must not be there either.
test_nothing_privileged_anywhere() {
    local root="$PWD/.." hits
    hits="$(grep -rniE '\b(sudo|pkexec|visudo|sudoers|pacman|systemctl|polkit)\b' \
            "$root"/{README.md,CHECKLIST.md,LICENSE,install,uninstall,manifest.json} \
            "$root"/*.qml "$root/Model.js" "$root/bin"/* 2>/dev/null || true)"
    assert_eq "no privileged verb in code, installer, README or checklist" "$hits" ""
}

test_install_is_executable_and_unprivileged() {
    local root="$PWD/.."
    assert_eq "install is executable"   "$([[ -x "$root/install"   ]] && echo yes || echo no)" "yes"
    assert_eq "uninstall is executable" "$([[ -x "$root/uninstall" ]] && echo yes || echo no)" "yes"
    assert_eq "mutations.sh is executable" \
              "$([[ -x "$root/test/mutations.sh" ]] && echo yes || echo no)" "yes"
    assert_eq "install has no --system tier" \
              "$(grep -c -- '--system' "$root/install" || true)" "0"
    # A refusal, not a request: run as root it must stop, because it installs
    # into a per-user config directory and root's copy would help nobody.
    assert_eq "install refuses to run as root" \
              "$(grep -c 'id -u' "$root/install" || true)" "1"
}

# install and uninstall are exercised against a SANDBOX, never against the
# real ~/.config/omarchy/plugins. setup_sandbox redirects XDG_CONFIG_HOME and
# XDG_RUNTIME_DIR, which is exactly what both scripts resolve their target
# from -- so the round trip is real and lands nowhere near the live shell.
test_install_copies_the_plugin_into_the_sandbox() {
    setup_sandbox
    local root; root="$(cd "$PWD/.." && pwd)"
    local target="$XDG_CONFIG_HOME/omarchy/plugins/smartalb.autostart"
    local out; out="$("$root/install" 2>&1)"
    assert_eq "install: the target directory was created" \
              "$([[ -d "$target" ]] && echo yes || echo no)" "yes"
    for f in manifest.json README.md LICENSE BarWidget.qml Panel.qml Service.qml \
             Runners.qml Model.js bin/omarchy-autostart-config \
             bin/omarchy-autostart-hypr bin/omarchy-autostart-hypr-write; do
        assert_eq "install: $f arrived" \
                  "$([[ -f "$target/$f" ]] && echo yes || echo no)" "yes"
    done
    assert_eq "install: the bin scripts are executable at the target" \
              "$([[ -x "$target/bin/omarchy-autostart-config" ]] && echo yes || echo no)" "yes"
    assert_eq "install: the autostart.lua writer is executable at the target too" \
              "$([[ -x "$target/bin/omarchy-autostart-hypr-write" ]] && echo yes || echo no)" "yes"
    # The install must not carry the development tree along: test/ holds a
    # harness that imports nothing the shell provides, and .git is a
    # checkout, not plugin content.
    assert_eq "install: the test directory is NOT copied into the plugin" \
              "$([[ -e "$target/test" ]] && echo copied || echo left-behind)" "left-behind"
    assert_contains "install: it says where it put things" "$out" "$target"
    assert_contains "install: it names the restart the widget needs" "$out" "omarchy-restart-shell"
    teardown_sandbox
}

test_uninstall_removes_the_plugin_but_keeps_the_configuration() {
    setup_sandbox
    local root; root="$(cd "$PWD/.." && pwd)"
    local target="$XDG_CONFIG_HOME/omarchy/plugins/smartalb.autostart"
    local config="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    "$root/install" >/dev/null 2>&1
    printf '{"schemaVersion":1,"programs":[],"workspaces":[]}' > "$config"
    chmod 600 "$config"
    mkdir -p "$XDG_RUNTIME_DIR/smartalb.autostart"
    local out; out="$("$root/uninstall" 2>&1)"
    assert_eq "uninstall: the plugin directory is gone" \
              "$([[ -e "$target" ]] && echo still-there || echo gone)" "gone"
    assert_eq "uninstall: the start marker directory is gone" \
              "$([[ -e "$XDG_RUNTIME_DIR/smartalb.autostart" ]] && echo still-there || echo gone)" "gone"
    # The configuration is the user's data. A reinstall must find the list
    # again, so removing the plugin may not remove it.
    assert_eq "uninstall: the configuration file is KEPT" \
              "$([[ -f "$config" ]] && echo kept || echo DELETED)" "kept"
    assert_contains "uninstall: it prints the path it kept" "$out" "$config"
    # Twice in a row must be quiet, not an error: nothing left to remove is
    # the normal state of a second run.
    assert_status "uninstall: running it again succeeds" 0 "$root/uninstall"
    teardown_sandbox
}

test_manifest_is_sound
test_repository_has_what_validation_looks_for
test_the_preview_is_either_taken_or_still_owed
test_nothing_privileged_anywhere
test_install_is_executable_and_unprivileged
test_install_copies_the_plugin_into_the_sandbox
test_uninstall_removes_the_plugin_but_keeps_the_configuration

summary
