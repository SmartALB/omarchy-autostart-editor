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

APPS_BIN="$PWD/../bin/omarchy-autostart-apps"

write_desktop() {
    local dir="$1" file="$2"; shift 2
    mkdir -p "$dir"
    { echo "[Desktop Entry]"; printf '%s\n' "$@"; } > "$dir/$file"
}

test_apps_reads_name_exec_and_class() {
    setup_sandbox
    write_desktop "$XDG_DATA_HOME/applications" "editor.desktop" \
        "Type=Application" "Name=Editor" "Exec=editor %U" \
        "StartupWMClass=editor" "Icon=editor"
    local out; out="$(DESKTOP_DIRS="$XDG_DATA_HOME/applications" "$APPS_BIN")"
    assert_eq "apps: one entry"        "$(jq -r 'length'        <<<"$out")" "1"
    assert_eq "apps: name"             "$(jq -r '.[0].name'     <<<"$out")" "Editor"
    assert_eq "apps: raw exec kept"    "$(jq -r '.[0].exec'     <<<"$out")" "editor %U"
    assert_eq "apps: wmclass"          "$(jq -r '.[0].wmclass'  <<<"$out")" "editor"
    assert_eq "apps: icon"             "$(jq -r '.[0].icon'     <<<"$out")" "editor"
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
[{"address":"0x1","class":"editor","title":"main","workspace":{"id":6},"monitor":1}]
JSON
    local out; out="$("$WINDOWS_BIN")"
    assert_eq "windows: one window"      "$(jq -r 'length'         <<<"$out")" "1"
    assert_eq "windows: class"           "$(jq -r '.[0].class'     <<<"$out")" "editor"
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
    # line -- and that line ends in the webmail flag, so it is WRONG for the
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
 {"address":"0x2","class":"msgbox","title":"s","workspace":{"id":2},"monitor":0,"pid":1483}]
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
    fake_cmdline 1883 /tmp/.mount_modelbFjMMHD/modelbox
    cat > "$FAKE_CLIENTS" <<'JSON'
[{"address":"0x1","class":"com.example.modelbox","title":"Modelbox","workspace":{"id":8},"monitor":0,"pid":1883}]
JSON
    local out; out="$("$WINDOWS_BIN")"
    assert_eq "windows: the AppImage mount path is reported as measured" \
              "$(jq -r '.[0].command' <<<"$out")" "/tmp/.mount_modelbFjMMHD/modelbox"
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

# The other half of the envelope-wording class claim. test/harness.qml proves
# every code in Model.envelopeCodes() has wording; this proves that list IS the
# set of codes the script can answer with. Neither half alone would notice a
# code added to the script with no wording, which is exactly how three of the
# eight went unworded for two rounds.
test_envelope_codes_match_the_script() {
    # EVERY script that answers with an envelope, not just the first one. When
    # bin/omarchy-autostart-hypr was added it brought a code of its own
    # ("unreadable"), and a version of this test that named only the then-first
    # script would have let it reach the user through envelopeText's
    # unknown-code fallback. The claim is about the set of codes THE PLUGIN can
    # emit; it has to read every emitter.
    #
    # THE REMOVAL MOVED THE EMITTERS, and that is how three unworded codes were
    # found. bin/omarchy-autostart-config is gone; the writer,
    # bin/omarchy-autostart-hypr-write, is the second emitter now, and it was
    # never read by this assertion before -- so does-not-compile, is-a-symlink
    # and no-lua-compiler had been reaching the user through envelopeText's
    # unknown-code fallback. Both surviving emitters are named here.
    local scripts=("$PWD/../bin/omarchy-autostart-hypr" "$PWD/../bin/omarchy-autostart-hypr-write")
    local from_script from_model
    # Both reporters: `err "<code>"` and the hardcoded printf fallbacks that
    # stand in when jq itself cannot build the answer.
    from_script="$( { grep -h -o 'err "[a-z-]*"' "${scripts[@]}" | sed 's/err "//; s/"//'
                      grep -h -o '"error":"[a-z-]*"' "${scripts[@]}" | sed 's/"error":"//; s/"//'
                    } | sort -u | tr '\n' ' ')"
    from_model="$(sed -n '/^function envelopeCodes/,/^}/p' "$PWD/../Model.js" \
                  | grep -o '"[a-z-]*"' | tr -d '"' | sort -u | tr '\n' ' ')"
    assert_eq "envelope: Model.envelopeCodes() is exactly what the reader and the writer can emit" \
              "$from_model" "$from_script"
    assert_eq "envelope: the extraction found something at all" \
              "$([[ -n "${from_script// /}" ]] && echo yes || echo no)" "yes"
}

test_envelope_codes_match_the_script

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

# The real forms, verbatim from the user's own autostart.lua. The backslashes
# are doubled here because they are doubled ON DISK, and single-quoted printf
# passes them through unchanged.
#
# THE OTHER TWO FILES ARE STILL WRITTEN, and their role has turned around.
# They used to be inputs the reader delivered; the reader reads one file now,
# so they are NEIGHBOURS -- two of the user's files that sit in the same
# directory and that this plugin must neither read nor touch. That is what
# test_hypr_read_changes_nothing checksums them for.
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

test_hypr_read_answers_even_when_the_file_does_not_exist() {
    setup_sandbox
    local out; out="$("$HYPR_BIN" read)"
    assert_eq "hypr: a missing directory is still ok" "$(jq -r .ok <<<"$out")" "true"
    assert_eq "hypr: one entry regardless" "$(jq -r '.files | length' <<<"$out")" "1"
    assert_eq "hypr: and it is autostart.lua" \
              "$(jq -r '[.files[].name] | join(",")' <<<"$out")" "autostart.lua"
    assert_eq "hypr: an absent file is present:false, not an error" \
              "$(jq -r '.files[0].present' <<<"$out")" "false"
    assert_eq "hypr: an absent file has mtime 0" \
              "$(jq -r '.files[0].mtime' <<<"$out")" "0"
    assert_eq "hypr: an absent file has empty content" \
              "$(jq -r '.files[0].content' <<<"$out")" ""
    assert_eq "hypr: the directory it looked in is named" \
              "$(jq -r .dir <<<"$out")" "$(hypr_dir)"
    teardown_sandbox
}

# THE BYTE-FOR-BYTE CLAIM, and it is the one the later line surgery depends
# on: what the script hands over must be exactly what is on disk. `cmp`
# against the file itself, not a jq-to-jq comparison, because the whole
# hazard is in the crossing -- a `$(...)` capture eats a trailing newline and
# an unquoted expansion mangles a backslash, and a Lua string literal in this
# file may well carry one.
#
# THE DOUBLED-BACKSLASH CASE moved rather than went. It used to be read out of
# windowrules.lua, which is not read any more; the same four characters `\\.`
# are written into autostart.lua here instead, inside a webapp URL, which is
# where a backslash actually occurs in the file this plugin does edit.
test_hypr_read_delivers_the_bytes_unchanged() {
    setup_sandbox
    write_real_files
    printf '%s\n' 'o.launch_on_start("nimbus --app=https://web\\.chat\\.com/")' \
        >> "$(hypr_dir)/autostart.lua"
    local out; out="$("$HYPR_BIN" read)"
    jq -j '.files[0].content' <<<"$out" > "$SANDBOX/autostart.lua.delivered"
    assert_eq "hypr: autostart.lua is delivered byte for byte" \
              "$(cmp -s "$(hypr_dir)/autostart.lua" "$SANDBOX/autostart.lua.delivered" \
                 && echo identical || echo DIFFERS)" "identical"
    assert_eq "hypr: the doubled backslash survives the crossing" \
              "$(jq -r '.files[0].content' <<<"$out" | grep -c 'web\\\\\.chat')" "1"
    assert_eq "hypr: the present file reports a real mtime" \
              "$(jq -r '[.files[] | select(.mtime > 0)] | length' <<<"$out")" "1"
    teardown_sandbox
}

test_hypr_read_reports_a_present_file_as_present() {
    setup_sandbox
    mkdir -p "$(hypr_dir)"
    printf 'o.launch_on_start("nimbus")\n' > "$(hypr_dir)/autostart.lua"
    local out; out="$("$HYPR_BIN" read)"
    assert_eq "hypr: the file that exists is present" \
              "$(jq -r '.files[0].present' <<<"$out")" "true"
    assert_eq "hypr: and it carries its full path" \
              "$(jq -r '.files[0].path' <<<"$out")" "$(hypr_dir)/autostart.lua"
    # EMPTY IS NOT ABSENT, and the pair is the whole point: "" as content says
    # nothing on its own, `present` is what distinguishes a file with no lines
    # in it from a file that is not there.
    assert_eq "hypr: an empty file is present with empty content" \
              "$(: > "$(hypr_dir)/autostart.lua"; "$HYPR_BIN" read \
                 | jq -r '.files[0] | "\(.present):\(.content)"')" "true:"
    teardown_sandbox
}

# A DIRECTORY, A SYMLINK TARGET THAT IS NOT A FILE, AND AN UNREADABLE FILE all
# read as absent rather than as an error envelope. There is nothing to show and
# nothing the writer could edit, and `present: false` is a sentence the panel
# can put on screen -- an error envelope is not.
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
    head -c $((65536 + 100)) /dev/zero | tr '\0' 'x' > "$(hypr_dir)/autostart.lua"
    local out; out="$("$HYPR_BIN" read)"
    assert_eq "hypr: an oversized file is delivered, not refused" \
              "$(jq -r '.files[0].present' <<<"$out")" "true"
    assert_eq "hypr: an oversized file is flagged as truncated" \
              "$(jq -r '.files[0].truncated' <<<"$out")" "true"
    assert_eq "hypr: an oversized file is cut to exactly the cap" \
              "$(jq -r '.files[0].content' <<<"$out" | wc -c)" "65537"
    assert_eq "hypr: a file at the cap is NOT flagged" \
              "$(head -c 65536 /dev/zero | tr '\0' 'y' > "$(hypr_dir)/autostart.lua"; \
                 "$HYPR_BIN" read | jq -r '.files[0].truncated')" "false"
    teardown_sandbox
}

# READ ONLY, ASSERTED. Not "the script has no write function" as prose in a
# comment: every file in the directory is checksummed before and after a read,
# and the script is grepped for the verbs that could change one. The plugin is
# installed and live on the user's machine while this is being built, and this
# is the assertion that says so out loud.
#
# ALL THREE FILES ARE STILL CHECKSUMMED, and that is deliberate now that the
# reader opens one of them. windowrules.lua and workspaces.lua are neighbours
# this plugin has no business touching, and a checksum over the whole directory
# is what says it does not.
test_hypr_read_changes_nothing() {
    setup_sandbox
    write_real_files
    local before after
    before="$(cd "$(hypr_dir)" && sha256sum autostart.lua windowrules.lua workspaces.lua)"
    "$HYPR_BIN" read >/dev/null
    "$HYPR_BIN" read >/dev/null
    after="$(cd "$(hypr_dir)" && sha256sum autostart.lua windowrules.lua workspaces.lua)"
    assert_eq "hypr: reading twice changes not one byte of any file in the directory" \
              "$after" "$before"
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

test_hypr_read_answers_even_when_the_file_does_not_exist
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
# Lua error at the next login, so every refusal below also asserts that THE
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

# OUR dated backups, and only ours: the glob carries the author segment, so a
# legacy autostart.lua.bak and Omarchy's .pre-apply.*.bak are outside every
# helper below by construction -- which is what lets the assertions say
# "backups" and mean the ones this plugin took.
#
# Sorted by NAME, not by mtime, for the reason the writer documents: `cp -p`
# gives each backup the mtime of the CONTENT it holds, not of the moment it
# was taken, so mtime order is the wrong order. YYYYMMDD-HHMMSS sorts
# lexicographically the way it sorts chronologically.
our_backups() {
    local f out=()
    for f in "$(hypr_dir)"/autostart.lua.smartalb-autostart.*.bak; do
        [[ -e "$f" ]] || continue
        out+=("$f")
    done
    (( ${#out[@]} > 0 )) || return 0
    printf '%s\n' "${out[@]}" | sort
}
backup_count()  { our_backups | grep -c . || true; }

# ONE WRITE AT A STAMP WE CHOOSE. The dated names need to differ, and the
# obvious way to make them differ is to sleep a second between writes -- which
# is what this did first, and it cost about seventeen seconds per run of this
# suite. mutations.sh runs the suite once per shell probe, so that was minutes
# of sleeping for nothing. The stamp seam makes the same writes distinct and
# deterministic at no cost, which is a second reason for it to exist.
write_at_stamp() {
    local stamp="$1" content="$2"
    printf '%s\n' "$content" \
        | OMARCHY_AUTOSTART_STAMP="$stamp" "$WRITE_BIN" write \
            --expect-mtime "$(autostart_mtime)"
}
newest_backup() { our_backups | tail -1; }
oldest_backup() { our_backups | head -1; }

# The user's own file, and the reason it is spelled out rather than copied
# from ~/.config/hypr: a test must never READ from there either, so that a
# change to the user's own file cannot change what this suite asserts.
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
# staged replacement lives in that directory by necessity -- a rename is only
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
    # BOTH stamps pinned, and the order matters: these backups are compared by
    # NAME order, so a first write left on the clock would sort AFTER a second
    # write given an explicit low stamp and "newest" would name the wrong one.
    local answer
    answer="$(write_at_stamp "20260903-000001" "$(write_good_candidate)")"
    assert_eq "write: a backup exists" \
              "$([[ -f "$(newest_backup)" ]] && echo yes || echo no)" "yes"
    assert_eq "write: and it holds the content that was replaced" \
              "$(cmp -s "$SANDBOX/before.lua" "$(newest_backup)" \
                 && echo identical || echo DIFFERENT)" "identical"
    # The envelope names the file it actually wrote, checked against the file
    # on disk rather than against a name this test rebuilds -- a test that
    # recomputed the dated name would be asserting its own arithmetic.
    assert_eq "write: the answer names the backup it took" \
              "$(jq -r .backup <<<"$answer")" "$(newest_backup)"
    assert_eq "write: and that one write took exactly one backup" \
              "$(backup_count)" "1"
    # THE LEGACY NAME IS NOT WRITTEN ANY MORE, and not touched either: an
    # autostart.lua.bak on a user's disk was written by an older version of
    # this script and is a state they may still want.
    assert_eq "write: the legacy autostart.lua.bak is not created" \
              "$([[ -e "$(autostart_path).bak" ]] && echo CREATED || echo absent)" "absent"
    # A HISTORY, NOT ONE STEP BACK, and this assertion is the inverse of the
    # one it replaces. "the backup is one step back, not a history" held while
    # a single autostart.lua.bak was overwritten by each write; two writes in
    # a row then left only the second-to-last state recoverable, which is what
    # made the 2026-09-03 incident hard to reason about. Each write now takes
    # its own dated copy and BOTH states survive.
    cp -p "$(autostart_path)" "$SANDBOX/second-before.lua"
    write_at_stamp "20260903-000002" 'o.launch_on_start("x")' >/dev/null
    assert_eq "write: a second write leaves TWO backups, not one" \
              "$(backup_count)" "2"
    assert_eq "write: the newest holds the state before the second write" \
              "$(cmp -s "$SANDBOX/second-before.lua" "$(newest_backup)" \
                 && echo identical || echo DIFFERENT)" "identical"
    assert_eq "write: and the older one still holds the original" \
              "$(cmp -s "$SANDBOX/before.lua" "$(oldest_backup)" \
                 && echo identical || echo DIFFERENT)" "identical"
    # The name carries the author, so a reader of that directory can tell our
    # backups from Omarchy's and from the user's own.
    assert_eq "write: the backup names this plugin as its author" \
              "$(basename "$(newest_backup)" | grep -cE '^autostart\.lua\.smartalb-autostart\.[0-9]{8}-[0-9]{6}(-[0-9]+)?\.bak$')" "1"
    teardown_sandbox
}

# THE CAP. Unbounded dated backups turn ~/.config/hypr into a junk drawer, so
# the newest few are kept and the rest pruned. Nine writes against a cap of
# five, and the assertion is on WHICH five survive, not merely how many: a
# pruner that kept the oldest would satisfy a bare count.
test_write_keeps_only_the_newest_backups() {
    setup_sandbox
    write_autostart_fixture
    local i
    for i in 1 2 3 4 5 6 7 8 9; do
        write_at_stamp "20260903-00000$i" "o.launch_on_start(\"p$i\")" >/dev/null
    done
    assert_eq "write: the number of backups is capped" "$(backup_count)" "5"
    # The five that survive are the five most recent. Each backup holds the
    # content from BEFORE its write, so after nine writes the newest backup
    # holds p8 and the oldest surviving one holds p4.
    assert_eq "write: the newest surviving backup is the most recent state" \
              "$(grep -c 'p8' "$(newest_backup)" || true)" "1"
    assert_eq "write: and the oldest surviving one is five steps back, not the first" \
              "$(grep -c 'p4' "$(oldest_backup)" || true)" "1"
    assert_eq "write: the earliest states really are gone, not merely unlisted" \
              "$(grep -l 'p1' "$(hypr_dir)"/autostart.lua.smartalb-autostart.*.bak 2>/dev/null | wc -l)" "0"
    teardown_sandbox
}

# THE PRUNER DELETES FILES IN THE USER'S CONFIGURATION DIRECTORY, so it gets
# the same treatment as the installer's scratch removal: it may only ever
# remove a file whose name matches OUR exact pattern, and it must refuse
# rather than guess.
#
# THIS IS THE POINT OF THE CHANGE; the dating itself is trivial. Two of the
# names below are real files that exist in the user's directory right now --
# autostart.lua.bak, written by an older version of this very script, and
# Omarchy's autostart.lua.pre-apply.20260828-144312.bak -- and deleting either
# would destroy a state nobody can get back.
#
# The two guarded functions are lifted out of the script and asked directly,
# because nothing an ordinary write does hands them a name they would refuse:
# the pruner derives its candidates from its own glob. A guard nobody has seen
# refuse anything is a guard nobody knows works, which is exactly what the
# install probe taught earlier in this task.
test_the_pruner_refuses_every_name_that_is_not_ours() {
    setup_sandbox
    local fn
    fn="$(sed -n '/^BACKUP_AUTHOR=/,/^MAX_BACKUPS=/p;/^is_our_backup() {/,/^}/p;/^remove_our_backup() {/,/^}/p' "$WRITE_BIN")"
    assert_eq "pruner: the guards could be read out of the script" \
              "$([[ -n "$fn" ]] && grep -q 'rm -f' <<<"$fn" && grep -q 'BACKUP_RE=' <<<"$fn" \
                 && echo found || echo NOT-FOUND)" "found"

    local d="$SANDBOX/hypr"
    mkdir -p "$d"
    # The names that must be refused, and every one of them is a real shape.
    local ours="autostart.lua.smartalb-autostart.20260903-101810.bak"
    local ours2="autostart.lua.smartalb-autostart.20260903-101810-2.bak"
    printf 'x\n' > "$d/autostart.lua"
    printf 'x\n' > "$d/autostart.lua.bak"                                    # ours, but the LEGACY name
    printf 'x\n' > "$d/autostart.lua.pre-apply.20260828-144312.bak"          # Omarchy's
    printf 'x\n' > "$d/windowrules.lua"                                      # another file of theirs
    printf 'x\n' > "$d/$ours.save"                                           # CONTAINS our pattern
    printf 'x\n' > "$d/x.$ours"                                              # contains it, prefixed
    printf 'x\n' > "$d/autostart.lua.smartalb-autostart.2026090-101810.bak"  # a digit short
    printf 'x\n' > "$d/autostart.lua.smartalb-autostart.20260903-101810.BAK" # wrong case
    mkdir -p "$d/autostart.lua.smartalb-autostart.20260903-999999.bak"        # a DIRECTORY named like ours
    # A FIFO, and it is the one that makes the "plain file" guard observable:
    # `rm -f` refuses a directory on its own, but it REMOVES a fifo, so
    # without the -f test this one would be deleted.
    mkfifo "$d/autostart.lua.smartalb-autostart.20260903-777777.bak"
    ln -s "$d/autostart.lua" "$d/autostart.lua.smartalb-autostart.20260903-888888.bak"  # a SYMLINK named like ours
    # ... and the two that must be accepted.
    printf 'x\n' > "$d/$ours"
    printf 'x\n' > "$d/$ours2"

    local verdicts
    verdicts="$(
        HYPR_DIR="$d"
        eval "$fn"
        for n in "autostart.lua" \
                 "autostart.lua.bak" \
                 "autostart.lua.pre-apply.20260828-144312.bak" \
                 "windowrules.lua" \
                 "$ours.save" \
                 "x.$ours" \
                 "autostart.lua.smartalb-autostart.2026090-101810.bak" \
                 "autostart.lua.smartalb-autostart.20260903-101810.BAK" \
                 "autostart.lua.smartalb-autostart.20260903-999999.bak" \
                 "autostart.lua.smartalb-autostart.20260903-888888.bak" \
                 "autostart.lua.smartalb-autostart.20260903-777777.bak" \
                 "../autostart.lua" \
                 "" \
                 "$ours" \
                 "$ours2"; do
            if remove_our_backup "$n" 2>/dev/null; then echo removed; else echo refused; fi
        done
    )"
    local expected="refused refused refused refused refused refused refused refused refused refused refused refused refused removed removed"
    assert_eq "pruner: every name that is not ours is refused, and both of ours accepted" \
              "$(tr '\n' ' ' <<<"$verdicts" | sed 's/ *$//')" "$expected"

    # A refusal is a refusal, not a deletion that reported failure. The two
    # files a user could never get back are named individually, because those
    # are the two that matter.
    assert_eq "pruner: the user's own autostart.lua is still there" \
              "$([[ -f "$d/autostart.lua" ]] && echo intact || echo DELETED)" "intact"
    assert_eq "pruner: the LEGACY autostart.lua.bak is still there" \
              "$([[ -f "$d/autostart.lua.bak" ]] && echo intact || echo DELETED)" "intact"
    assert_eq "pruner: Omarchy's own pre-apply backup is still there" \
              "$([[ -f "$d/autostart.lua.pre-apply.20260828-144312.bak" ]] && echo intact || echo DELETED)" "intact"
    assert_eq "pruner: every other refused name is still there" \
              "$([[ -f "$d/windowrules.lua" && -f "$d/$ours.save" && -f "$d/x.$ours" \
                 && -f "$d/autostart.lua.smartalb-autostart.2026090-101810.bak" \
                 && -f "$d/autostart.lua.smartalb-autostart.20260903-101810.BAK" ]] \
                 && echo intact || echo DELETED)" "intact"
    assert_eq "pruner: the directory named like ours was not removed" \
              "$([[ -d "$d/autostart.lua.smartalb-autostart.20260903-999999.bak" ]] && echo intact || echo DELETED)" "intact"
    assert_eq "pruner: the symlink named like ours was not removed" \
              "$([[ -h "$d/autostart.lua.smartalb-autostart.20260903-888888.bak" ]] && echo intact || echo DELETED)" "intact"
    assert_eq "pruner: the fifo named like ours was not removed either" \
              "$([[ -p "$d/autostart.lua.smartalb-autostart.20260903-777777.bak" ]] && echo intact || echo DELETED)" "intact"
    assert_eq "pruner: and what it points at was not removed either" \
              "$([[ -f "$d/autostart.lua" ]] && echo intact || echo DELETED)" "intact"
    assert_eq "pruner: the two backups of ours ARE gone" \
              "$([[ -e "$d/$ours" || -e "$d/$ours2" ]] && echo still-there || echo gone)" "gone"
    teardown_sandbox
}

# A BACKUP THAT CANNOT BE TAKEN STILL ABORTS THE WRITE, and this is the
# reachable half of that guarantee.
#
# The `cp` itself cannot be made to fail from a test: the script has already
# established that the directory is writable (it staged a file there) and that
# the source is readable, so a probe on that branch reports green for want of
# an input rather than for want of a guard. What CAN be forced is the other
# refusal through the same `err`: every candidate backup name taken, so no
# free name exists. The write must then change nothing at all.
test_write_aborts_when_no_backup_can_be_taken() {
    setup_sandbox
    write_autostart_fixture
    # The stamp is pinned through the script's own seam, so the second the
    # clock happens to be in cannot decide whether this test passes. The
    # first version of this test read `date` itself and raced the writer.
    local stamp="20991231-235959" n
    : > "$(hypr_dir)/autostart.lua.smartalb-autostart.$stamp.bak"
    for (( n = 2; n <= 50; n++ )); do
        : > "$(hypr_dir)/autostart.lua.smartalb-autostart.$stamp-$n.bak"
    done
    # Fail-closed FIRST: if the fixture did not take every candidate name, the
    # write below would succeed for an ordinary reason and every assertion
    # after it would be about the wrong thing.
    assert_eq "write: the fixture really did take every candidate name" \
              "$(find "$(hypr_dir)" -maxdepth 1 -name "autostart.lua.smartalb-autostart.$stamp*.bak" | wc -l)" "50"
    local before answer
    before="$(sha256sum < "$(autostart_path)")"
    answer="$(printf '%s\n' 'o.launch_on_start("blocked")' \
              | OMARCHY_AUTOSTART_STAMP="$stamp" "$WRITE_BIN" write \
                  --expect-mtime "$(autostart_mtime)")"
    assert_eq "write: with no free backup name the write is refused" \
              "$(jq -r .ok <<<"$answer")" "false"
    assert_eq "write: and it says the write failed" \
              "$(jq -r .error <<<"$answer")" "write-failed"
    assert_eq "write: the file is byte for byte what it was" \
              "$(sha256sum < "$(autostart_path)")" "$before"
    assert_eq "write: and nothing was staged and left behind" \
              "$(find "$(hypr_dir)" -maxdepth 1 -name '.autostart.lua.*' | wc -l)" "0"
    teardown_sandbox
}

# THE SEAM ITSELF CANNOT WIDEN ANYTHING. It exists so the test above is
# possible, so what it accepts has to be pinned: a value that is not a
# timestamp must be refused rather than used, or the seam would be a way to
# name a backup path outside our own pattern.
test_the_stamp_seam_accepts_nothing_but_a_timestamp() {
    setup_sandbox
    write_autostart_fixture
    local bad answer
    for bad in "../escape" "20260903-101810/x" "notadate" "2026090-101810" "" "20260903-1018100"; do
        # The prefix goes on the WRITER, not on the assignment: a bare
        # `VAR=x answer=$(...)` sets VAR in this shell without exporting it,
        # so the child never sees it -- which is how the first version of this
        # test reported the seam as accepting everything.
        answer="$(printf '%s\n' 'o.launch_on_start("x")' \
                  | OMARCHY_AUTOSTART_STAMP="$bad" "$WRITE_BIN" write \
                      --expect-mtime "$(autostart_mtime)")"
        if [[ -z "$bad" ]]; then
            # Empty means "no override", which is the ordinary path: the clock
            # is used and the write succeeds.
            assert_eq "stamp seam: an empty override falls back to the clock" \
                      "$(jq -r .ok <<<"$answer")" "true"
            assert_eq "stamp seam: and the backup it took is one of ours" \
                      "$(basename "$(jq -r .backup <<<"$answer")" \
                         | grep -cE '^autostart\.lua\.smartalb-autostart\.[0-9]{8}-[0-9]{6}(-[0-9]+)?\.bak$')" "1"
            continue
        fi
        assert_eq "stamp seam: '$bad' is refused, not used" \
                  "$(jq -r .ok <<<"$answer")" "false"
    done
    # And nothing outside our pattern was created by any of those attempts.
    assert_eq "stamp seam: no file outside our own pattern was created" \
              "$(find "$(hypr_dir)" -maxdepth 1 -type f \
                 ! -name 'autostart.lua' \
                 ! -name 'autostart.lua.smartalb-autostart.*.bak' | wc -l)" "0"
    teardown_sandbox
}

# The pruning must never reach a neighbouring file through the real write
# path either, not only through the guard in isolation.
test_writing_never_touches_a_backup_that_is_not_ours() {
    setup_sandbox
    write_autostart_fixture
    printf 'legacy\n'  > "$(hypr_dir)/autostart.lua.bak"
    printf 'omarchy\n' > "$(hypr_dir)/autostart.lua.pre-apply.20260828-144312.bak"
    local i
    for i in 1 2 3 4 5 6 7; do
        write_at_stamp "20260903-00000$i" "o.launch_on_start(\"q$i\")" >/dev/null
    done
    assert_eq "write: seven writes past the cap left five of ours" "$(backup_count)" "5"
    assert_eq "write: the legacy autostart.lua.bak is byte for byte what it was" \
              "$(cat "$(hypr_dir)/autostart.lua.bak")" "legacy"
    assert_eq "write: and Omarchy's pre-apply backup too" \
              "$(cat "$(hypr_dir)/autostart.lua.pre-apply.20260828-144312.bak")" "omarchy"
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
test_write_keeps_only_the_newest_backups
test_the_pruner_refuses_every_name_that_is_not_ours
test_write_aborts_when_no_backup_can_be_taken
test_the_stamp_seam_accepts_nothing_but_a_timestamp
test_writing_never_touches_a_backup_that_is_not_ours
test_write_refuses_a_candidate_that_does_not_compile
test_write_never_executes_the_candidate
test_write_refuses_a_stale_expectation
test_write_refuses_what_it_must_not_write_through
test_write_refuses_an_oversized_candidate
test_write_has_one_envelope_and_one_usage
test_write_touches_only_autostart_lua
test_write_refuses_when_there_is_no_lua_compiler

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
# "service" WAS required and is now refused, and the pair is the reason this
# matters. shell.qml:289-290 creates a service only when `kinds` carries
# "service" AND `entryPoints.service` exists; the same pair guards the loop at
# :329-330. There is no Service.qml any more -- nothing in this plugin runs at
# login, nothing applies anything, nothing is started -- so declaring either
# half would name a file that does not exist. It joins the negative list below
# rather than merely disappearing from the positive one: a manifest that
# quietly regrows the kind is exactly the shape that installs, enables,
# validates clean and does nothing.
test_manifest_is_sound() {
    local root="$PWD/.." m="$PWD/../manifest.json"
    assert_status "manifest: is valid JSON" 0 jq -e . "$m"
    assert_eq "manifest: id"            "$(jq -r .id "$m")"            "smartalb.autostart"
    assert_eq "manifest: schemaVersion is the number 1, not the string" \
              "$(jq -r '.schemaVersion == 1' "$m")" "true"
    assert_eq "manifest: name"          "$(jq -r .name "$m")"          "Autostart Editor"
    assert_eq "manifest: version"       "$(jq -r .version "$m")"       "1.0.0"
    assert_eq "manifest: license"       "$(jq -r .license "$m")"       "MIT"
    assert_eq "manifest: not in the omarchy namespace" \
              "$(jq -r '.id | startswith("omarchy.")' "$m")" "false"

    # The positive half.
    for kind in bar-widget; do
        assert_eq "manifest: declares kind $kind" \
                  "$(jq -r --arg k "$kind" '.kinds | index($k) != null' "$m")" "true"
    done
    for pair in "barWidget:BarWidget.qml"; do
        local key="${pair%%:*}" file="${pair#*:}"
        assert_eq "manifest: entryPoint $key" \
                  "$(jq -r --arg k "$key" '.entryPoints[$k]' "$m")" "$file"
        assert_eq "manifest: $file exists" \
                  "$([[ -f "$root/$file" ]] && echo yes || echo no)" "yes"
    done

    # The negative half, which is the half that matters. Four of these five
    # kinds would move this plugin off the bar-widget route; the fifth,
    # "service", would name a Service.qml that no longer exists.
    for kind in panel overlay menu bar service; do
        assert_eq "manifest: does NOT declare kind $kind" \
                  "$(jq -r --arg k "$kind" '.kinds | index($k) != null' "$m")" "false"
    done
    assert_eq "manifest: declares no kind beyond the one" \
              "$(jq -r '.kinds | sort | join(",")' "$m")" "bar-widget"
    for key in panel service; do
        assert_eq "manifest: entryPoints has no $key key either" \
                  "$(jq -r --arg k "$key" '.entryPoints | has($k)' "$m")" "false"
    done
    assert_eq "manifest: and it declares exactly one entry point" \
              "$(jq -r '.entryPoints | keys | join(",")' "$m")" "barWidget"
    assert_eq "manifest: no Service.qml is shipped for one to point at" \
              "$([[ -e "$root/Service.qml" ]] && echo present || echo gone)" "gone"
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
    # THIS IS THE ASSERTION THE REMOVAL HAD TO KEEP SHARP. Dropping Service.qml
    # while leaving either half of its pair in the manifest is the mistake that
    # once meant the plugin's whole purpose was silently absent while
    # `omarchy plugin validate` still exited 0.
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
    assert_eq "manifest: the pair check actually examined the declared kind" \
              "$(jq -r --argjson t "$kind_table" '[.kinds[] | select($t[.] != null)] | length' "$m")" \
              "1"

    assert_eq "manifest: defaultSection is one the registry accepts" \
              "$(jq -r '.barWidget.defaultSection' "$m")" "right"
    assert_eq "manifest: allowMultiple is off" \
              "$(jq -r '.barWidget.allowMultiple' "$m")" "false"
}

# THE DISPLAYED BUILD MUST BE THE BUILD, and this is the assertion that makes
# the panel's footer trustworthy.
#
# The panel shows Model.versionText(), which is "v" + Model.VERSION. The
# manifest carries `version` independently, and the platform requires it
# (PluginRegistry.validateManifest lists it among the required keys). Two
# copies of one fact, so they are pinned to each other by EXACT EQUALITY in
# both directions -- not a substring, not a prefix.
#
# WHY THIS IS THE BINDING RATHER THAN A RUNTIME READ: reading manifest.json
# from Panel.qml would make drift impossible, but the reading code would live
# in the one file no suite here can execute, and a read that silently fails
# shows an empty footer on the machine where nobody is watching. See the
# comment on VERSION in Model.js for the full argument. Drift is therefore
# refused HERE, at release, in the repository -- and since `install` replaces
# the plugin directory rather than copying into it, the installed
# manifest.json and the installed Model.js are provably from one source tree,
# which is what makes a repository-bound assertion bind the artifact too.
#
# FAIL-CLOSED ON BOTH EXTRACTIONS: an empty value on either side would make
# the equality vacuously true if the other were empty too, and "" == "" is
# exactly the green-over-nothing shape this project keeps a record of.
test_the_displayed_version_is_the_manifest_version() {
    local root="$PWD/.." m="$PWD/../manifest.json"
    local from_model from_manifest
    from_model="$(sed -n 's/^var VERSION *= *"\([^"]*\)";$/\1/p' "$root/Model.js")"
    from_manifest="$(jq -r '.version // ""' "$m")"

    assert_eq "version: Model.js declares a version at all" \
              "$([[ -n "$from_model" ]] && echo yes || echo no)" "yes"
    assert_eq "version: the manifest declares one at all" \
              "$([[ -n "$from_manifest" ]] && echo yes || echo no)" "yes"
    assert_eq "version: Model.VERSION is exactly the manifest's version" \
              "$from_model" "$from_manifest"
    # Exactly one declaration, so a second `var VERSION` further down cannot
    # be the one the panel actually reads while this test pins the first.
    assert_eq "version: Model.js declares it exactly once" \
              "$(grep -cE '^var VERSION *=' "$root/Model.js")" "1"
    # And the panel spells no version of its own. The structural suite owns
    # this claim too; it is repeated here because this is the test that would
    # be read by someone bumping a release.
    assert_eq "version: Panel.qml spells no version literal of its own" \
              "$(grep -cE '"[0-9]+\.[0-9]+\.[0-9]+"' "$root/Panel.qml" || true)" "0"
}

test_the_displayed_version_is_the_manifest_version

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
    for f in manifest.json README.md LICENSE BarWidget.qml Panel.qml \
             Runners.qml Model.js bin/omarchy-autostart-apps \
             bin/omarchy-autostart-windows \
             bin/omarchy-autostart-hypr bin/omarchy-autostart-hypr-write; do
        assert_eq "install: $f arrived" \
                  "$([[ -f "$target/$f" ]] && echo yes || echo no)" "yes"
    done
    # And the two files of the removed half are NOT carried along by a copy
    # list that still names them: `cp` skips what is absent from the source
    # without a word, so an installer left pointing at a deleted file is
    # silent, not broken.
    for f in Service.qml bin/omarchy-autostart-config bin/omarchy-autostart-marker; do
        assert_eq "install: $f is not installed" \
                  "$([[ -e "$target/$f" ]] && echo copied || echo absent)" "absent"
    done
    assert_eq "install: the bin scripts are executable at the target" \
              "$([[ -x "$target/bin/omarchy-autostart-hypr" ]] && echo yes || echo no)" "yes"
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

# AN UPGRADE MUST NOT LEAVE A REMOVED FILE BEHIND, and this is the assertion
# every existing one about `install` was missing.
#
# THE DEFECT, measured on the user's own machine. `install` copied its file
# list over whatever was already at the target, so a file DELETED from the
# plugin lived on in the installed copy forever. Installing the build that
# removed the old half left Service.qml (695 lines, still carrying the apply
# path that once put 347 rules into the running compositor),
# bin/omarchy-autostart-config and bin/omarchy-autostart-marker sitting in the
# user's plugin directory -- and every assertion this file had about `install`
# passed over that directory, because all of them asked only whether the NEW
# files had ARRIVED. "Present" and "the only thing present" are not the same
# claim, and the second is the one that matters.
#
# What kept it harmless was luck bounded by a good platform design: a service
# is created only when `kinds` contains "service" AND `entryPoints.service`
# exists (shell.qml:289-290), and the freshly copied manifest had dropped
# both. A manifest copied a moment later, or a future version declaring a
# service kind for another reason, would have loaded a Service.qml from a
# design that no longer exists.
#
# So the test installs an OLDER file set first -- the three files by their
# real names, plus a fourth under bin/ to prove a nested removal is covered
# too -- and then requires them GONE. The last assertion is the general form:
# `diff -r` against a reference built from install's own list, so the target
# is exactly that list and nothing else, whatever the list becomes later.
test_install_removes_what_the_plugin_no_longer_ships() {
    setup_sandbox
    local root; root="$(cd "$PWD/.." && pwd)"
    local plugins="$XDG_CONFIG_HOME/omarchy/plugins"
    local target="$plugins/smartalb.autostart"

    # The previous version, as it really stood on disk.
    mkdir -p "$target/bin"
    printf '// the apply path of a design that no longer exists\n' > "$target/Service.qml"
    printf '#!/usr/bin/env bash\n' > "$target/bin/omarchy-autostart-config"
    printf '#!/usr/bin/env bash\n' > "$target/bin/omarchy-autostart-marker"
    printf '{"kinds":["bar-widget","service"]}\n' > "$target/manifest.json"

    # Fail-closed: if the fixture did not actually land, every assertion below
    # would be about an empty directory and would pass for the wrong reason.
    assert_eq "upgrade: the older file set really is in place first" \
              "$([[ -f "$target/Service.qml" \
                 && -f "$target/bin/omarchy-autostart-config" \
                 && -f "$target/bin/omarchy-autostart-marker" ]] && echo staged || echo NOT-STAGED)" \
              "staged"

    "$root/install" >/dev/null 2>&1

    # THE ASSERTION THE OLD SHAPE COULD NOT PASS. One per file, by name, so a
    # failure says which one survived.
    local stale
    for stale in Service.qml bin/omarchy-autostart-config bin/omarchy-autostart-marker; do
        assert_eq "upgrade: $stale is GONE after installing over it" \
                  "$([[ -e "$target/$stale" ]] && echo SURVIVED || echo gone)" "gone"
    done

    # And the new content is there, so "gone" was not achieved by installing
    # nothing at all.
    assert_eq "upgrade: and the current files did arrive" \
              "$([[ -f "$target/Panel.qml" && -f "$target/Model.js" \
                 && -f "$target/bin/omarchy-autostart-hypr-write" ]] && echo yes || echo no)" \
              "yes"
    assert_eq "upgrade: the manifest is the new one, not the one that was there" \
              "$(jq -r '.kinds | join(",")' "$target/manifest.json")" "bar-widget"

    # THE GENERAL FORM. A reference directory built from install's own list,
    # compared whole: what is installed is exactly that list. This keeps
    # holding when the list changes, which the per-file assertions above do
    # not -- they name today's three.
    local ref="$SANDBOX/reference"
    mkdir -p "$ref"
    local item
    for item in manifest.json README.md LICENSE CHECKLIST.md preview.png \
                BarWidget.qml Panel.qml Runners.qml Model.js bin; do
        [[ -e "$root/$item" ]] || continue
        cp -r "$root/$item" "$ref/"
    done
    assert_eq "upgrade: the installed directory is file-for-file the source list" \
              "$(diff -r "$ref" "$target" >/dev/null 2>&1 && echo identical || echo DIFFERS)" \
              "identical"

    # The scratch directory install stages into is BESIDE the target, so it
    # would be visible here if it were ever left behind.
    assert_eq "upgrade: no scratch directory is left in the plugins directory" \
              "$(find "$plugins" -maxdepth 1 -name '.smartalb.autostart.*' | wc -l)" "0"

    # Installing twice in a row is the ordinary case and must be idempotent.
    "$root/install" >/dev/null 2>&1
    assert_eq "upgrade: installing again leaves the same directory" \
              "$(diff -r "$ref" "$target" >/dev/null 2>&1 && echo identical || echo DIFFERS)" \
              "identical"
    teardown_sandbox
}

# THE PATH THAT REACHES `rm -rf` IS CHECKED, in both scripts. `rm -rf` against
# an assembled path is the shape that once became `rm -rf /` in this project's
# own test sandbox, so neither script may reach it on a path it has not
# resolved and placed. Two directions, and both are probed rather than argued:
#
#   * install may delete ONLY a directory it made itself -- named with its own
#     ".<id>." prefix, directly inside the plugins directory. The installed
#     target can never satisfy that, which is what stops the installer from
#     deleting inside a directory whose path came from a variable.
#   * uninstall must refuse a target that does not resolve to
#     <plugins>/<id>. With an empty id it would otherwise be the plugins
#     directory itself, and the removal would take EVERY installed plugin.
test_neither_script_deletes_a_path_it_has_not_placed() {
    setup_sandbox
    local root; root="$(cd "$PWD/.." && pwd)"
    local plugins="$XDG_CONFIG_HOME/omarchy/plugins"

    # A neighbour plugin, and a leftover scratch directory of install's own.
    "$root/install" >/dev/null 2>&1
    mkdir -p "$plugins/other.plugin" "$plugins/.smartalb.autostart.new.leftovr"
    printf 'not ours\n' > "$plugins/other.plugin/keep-me"

    "$root/uninstall" >/dev/null 2>&1
    assert_eq "paths: uninstall removed our plugin" \
              "$([[ -e "$plugins/smartalb.autostart" ]] && echo still-there || echo gone)" "gone"
    assert_eq "paths: and its own leftover scratch directory" \
              "$([[ -e "$plugins/.smartalb.autostart.new.leftovr" ]] && echo still-there || echo gone)" \
              "gone"
    assert_eq "paths: and touched NOTHING belonging to another plugin" \
              "$([[ -f "$plugins/other.plugin/keep-me" ]] && echo kept || echo DELETED)" "kept"

    # The id emptied: the target is then the plugins directory itself. A canary
    # inside it says whether the guard held, because "the directory is still
    # there" would also be true if only its contents had gone.
    mkdir -p "$plugins/canary"
    sed 's/^ID="smartalb.autostart"$/ID=""/' "$root/uninstall" > "$SANDBOX/uninstall-empty-id"
    chmod +x "$SANDBOX/uninstall-empty-id"
    local out status
    out="$("$SANDBOX/uninstall-empty-id" 2>&1)"; status=$?
    assert_eq "paths: uninstall with an empty id refuses and exits non-zero" \
              "$([[ "$status" -ne 0 ]] && echo refused || echo "ACCEPTED ($status)")" "refused"
    assert_contains "paths: and says what it refused" "$out" "refusing to remove"
    assert_eq "paths: every other plugin is still there" \
              "$([[ -d "$plugins/canary" && -f "$plugins/other.plugin/keep-me" ]] && echo kept || echo DELETED)" \
              "kept"

    # INSTALL'S OWN GUARD, HANDED THE PATHS IT MUST REFUSE.
    #
    # Nothing an ordinary install does reaches remove_scratch with a path it
    # would refuse -- the installer only ever passes it directories it made
    # itself -- so the guard is defence against a future edit, and a mutation
    # probe proved that disarming it changed no observable behaviour at all.
    # A guard nobody has seen refuse anything is a guard nobody knows works.
    #
    # So the function is lifted out of the script and asked directly. The
    # extraction is fail-closed: if the function cannot be found, that is a
    # failure rather than a silently empty test.
    local fn; fn="$(sed -n '/^remove_scratch() {/,/^}/p' "$root/install")"
    assert_eq "paths: install's remove_scratch could be read out of the script" \
              "$([[ -n "$fn" ]] && grep -q 'rm -rf' <<<"$fn" && echo found || echo NOT-FOUND)" "found"
    # A harness that defines the two globals the function reads, then asks it
    # to remove three paths it must refuse and one it must accept.
    local probe_dir="$SANDBOX/guard"
    mkdir -p "$probe_dir/plugins/smartalb.autostart" \
             "$probe_dir/plugins/other.plugin" \
             "$probe_dir/plugins/.smartalb.autostart.new.abc123" \
             "$probe_dir/outside"
    local guard_out
    guard_out="$(
        ID="smartalb.autostart"
        PLUGINS_REAL="$(realpath -m -- "$probe_dir/plugins")"
        eval "$fn"
        for candidate in "$probe_dir/plugins/smartalb.autostart" \
                         "$probe_dir/plugins/other.plugin" \
                         "$probe_dir/plugins/../outside" \
                         "$probe_dir/plugins/.smartalb.autostart.new.abc123"; do
            if remove_scratch "$candidate" 2>/dev/null; then echo "removed"; else echo "refused"; fi
        done
    )"
    assert_eq "paths: the installed plugin directory is refused" \
              "$(sed -n 1p <<<"$guard_out")" "refused"
    assert_eq "paths: another plugin's directory is refused" \
              "$(sed -n 2p <<<"$guard_out")" "refused"
    assert_eq "paths: a '..' walk out of the plugins directory is refused" \
              "$(sed -n 3p <<<"$guard_out")" "refused"
    assert_eq "paths: and the installer's own scratch directory IS removed" \
              "$(sed -n 4p <<<"$guard_out")" "removed"
    # The refusals were refusals, not deletions that reported failure.
    assert_eq "paths: all three refused directories are still on disk" \
              "$([[ -d "$probe_dir/plugins/smartalb.autostart" \
                 && -d "$probe_dir/plugins/other.plugin" \
                 && -d "$probe_dir/outside" ]] && echo intact || echo DELETED)" "intact"
    assert_eq "paths: and the accepted one is gone" \
              "$([[ -e "$probe_dir/plugins/.smartalb.autostart.new.abc123" ]] && echo still-there || echo gone)" \
              "gone"

    # Fail-closed on the guard being reachable at all: a script that resolves
    # no path cannot be checking one, and both behavioural halves above would
    # then be passing for some other reason.
    local script
    for script in install uninstall; do
        assert_eq "paths: $script resolves a path with realpath before deleting one" \
                  "$([[ "$(grep -c 'realpath -m --' "$root/$script")" -ge 1 ]] && echo yes || echo no)" \
                  "yes"
    done
    teardown_sandbox
}

# There is no configuration of this plugin's own left to keep: the JSON file
# went with the removed half, and the only file it ever wrote is the user's own
# ~/.config/hypr/autostart.lua. So the property has turned around -- what
# uninstall must do is remove the plugin AND TOUCH NOTHING ELSE, and the
# autostart.lua in the sandbox is what proves the second half.
test_uninstall_removes_the_plugin_and_touches_nothing_else() {
    setup_sandbox
    local root; root="$(cd "$PWD/.." && pwd)"
    local target="$XDG_CONFIG_HOME/omarchy/plugins/smartalb.autostart"
    "$root/install" >/dev/null 2>&1
    mkdir -p "$XDG_CONFIG_HOME/hypr"
    printf 'o.launch_on_start("nimbus")\n' > "$XDG_CONFIG_HOME/hypr/autostart.lua"
    local before; before="$(sha256sum < "$XDG_CONFIG_HOME/hypr/autostart.lua")"
    local out; out="$("$root/uninstall" 2>&1)"
    assert_eq "uninstall: the plugin directory is gone" \
              "$([[ -e "$target" ]] && echo still-there || echo gone)" "gone"
    assert_eq "uninstall: the user's own autostart.lua is still there" \
              "$([[ -f "$XDG_CONFIG_HOME/hypr/autostart.lua" ]] && echo kept || echo DELETED)" "kept"
    assert_eq "uninstall: and byte for byte what it was" \
              "$(sha256sum < "$XDG_CONFIG_HOME/hypr/autostart.lua")" "$before"
    assert_contains "uninstall: it says the autostart entries keep working" \
                    "$out" "keep working without this plugin"
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
test_install_removes_what_the_plugin_no_longer_ships
test_neither_script_deletes_a_path_it_has_not_placed
test_uninstall_removes_the_plugin_and_touches_nothing_else

summary
