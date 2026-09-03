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
    local script="$PWD/../bin/omarchy-autostart-config"
    local from_script from_model
    # Both reporters: `err "<code>"` and the two hardcoded printf fallbacks
    # that stand in when jq itself cannot build the answer.
    from_script="$( { grep -o 'err "[a-z-]*"' "$script" | sed 's/err "//; s/"//'
                      grep -o '"error":"[a-z-]*"' "$script" | sed 's/"error":"//; s/"//'
                    } | sort -u | tr '\n' ' ')"
    from_model="$(sed -n '/^function envelopeCodes/,/^}/p' "$PWD/../Model.js" \
                  | grep -o '"[a-z-]*"' | tr -d '"' | sort -u | tr '\n' ' ')"
    assert_eq "envelope: Model.envelopeCodes() is exactly what the script can emit" \
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
             Runners.qml Model.js bin/omarchy-autostart-config; do
        assert_eq "install: $f arrived" \
                  "$([[ -f "$target/$f" ]] && echo yes || echo no)" "yes"
    done
    assert_eq "install: the bin scripts are executable at the target" \
              "$([[ -x "$target/bin/omarchy-autostart-config" ]] && echo yes || echo no)" "yes"
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
