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

test_windows_resolves_the_monitor_name
test_windows_drops_special_workspaces
test_windows_caps_the_count
test_windows_survives_an_unreachable_compositor
test_windows_survives_an_array_of_non_objects
test_windows_filters_before_capping
test_windows_survives_a_failing_hyprctl
test_windows_survives_valid_json_that_is_not_an_array

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

summary
