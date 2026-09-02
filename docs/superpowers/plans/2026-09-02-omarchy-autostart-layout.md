# Autostart Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein Omarchy-Quattro-Plugin bauen, mit dem sich über die Bar festlegen lässt, welche Programme beim Sitzungsstart starten, auf welchem Workspace oder Monitor sie erscheinen und auf welchem Monitor ein Workspace liegt.

**Architecture:** Eine JSON-Datei ist die einzige Wahrheit. Ein `service`-Teil setzt daraus beim Sitzungsstart Hyprland-Regeln über `hyprctl eval` (Lua) und startet die Programme; das Panel bearbeitet die Datei und wendet sofort an. Keine Nutzer-Konfigurationsdatei wird angefasst. Die Entscheidungslogik liegt in reinem JavaScript (`Model.js`), das Anfassen von Dateien und Prozessen in drei Shell-Skripten unter `bin/` — beides ohne QML-API und damit headless prüfbar.

**Tech Stack:** Quickshell/QML (Qt 6), reines JavaScript, bash, `jq`, `hyprctl` mit Lua-Auswertung. Testläufer: `/usr/lib/qt6/bin/qml` headless und bash.

**Spec:** `docs/superpowers/specs/2026-09-02-omarchy-autostart-layout-design.md`

**Arbeitsverzeichnis:** `~/repos/omarchy-autostart-layout`. **Niemals** direkt in
`~/.config/omarchy/plugins/` entwickeln: Quickshell hält dort ein
`inotifywait -m -r`, jedes Schreiben löst einen Shell-Neustart aus und reißt
laufende `Process`-Objekte mit. Für die Handprüfschritte in Task 14, 15 und 17
einmal `./install` laufen lassen, danach `omarchy-restart-shell` und 8 s warten.

## Global Constraints

Diese gelten für **jede** Aufgabe, auch wenn sie dort nicht wiederholt werden.

- **Plugin-ID:** `smartalb.autostart`. Anzeigename `Autostart Layout`. Der Namensraum `omarchy.*` ist Dritten verboten.
- **Keine Privilegien.** Kein `sudo`, kein `pkexec`, keine Paketinstallation — weder im Code noch im README-Text. Die Sicherheits-Baseline des Marketplace liest das README mit.
- **Keine Symlinks** im Plugin-Verzeichnis (Plattform-Vorgabe).
- **Sprache:** Oberfläche, README, `manifest.json`-Texte, Codekommentare und Commit-Nachrichten auf **Englisch** (öffentliches Repo). Die Spezifikation und dieser Plan bleiben deutsch; der bestehende deutsche Spec-Commit bleibt, wie er ist.
- **Konfigurationsdatei:** `$XDG_CONFIG_HOME/omarchy/autostart-layout.json`, Rechte **0600**, atomar geschrieben. Ist sie für Gruppe oder Welt beschreibbar, wird **nichts** angewandt.
- **`schemaVersion`:** genau `1`. Jeder andere Wert gilt als unlesbare Datei.
- **Obergrenzen, alle vor dem ersten Aufruf durchgesetzt:** JSON 256 KiB (MAX+1 gelesen, bei Überlauf abgewiesen); 200 Programme; 99 Workspace-Einträge; 500 Fenster; 2000 `.desktop`-Dateien à 64 KiB; je `eval`-Aufruf ≤ 20 Regeln, ≤ 64 KiB Nutzlast, ≤ 20 Aufrufe.
- **Zeichen-Erlaubnisliste für `class`:** nur `A-Z a-z 0-9`, Leerzeichen und `. _ - ^ $ ( ) | [ ] ? * + \ :`, Länge 1–200. Abgewiesen: `"` `'` `{` `}` `;` `=`, Backtick, Zeilenumbruch, alles außerhalb ASCII 1–126.
- **Jeder Wert, der nach Lua geht, wird als `string.char(...)` kodiert.** Nie als Zeichenkette in Anführungszeichen.
- **Zwei Aufrufwege:** `hypr(verb, payload)` ohne Shell (argv-Liste, Deadline 20 s) für alles, was mit Hyprland spricht — beide Verben nötig, `eval` für Regelblöcke, `dispatch` für Umzüge; `runner()`/`runnerOut()`/`runnerErr()` mit `/usr/bin/bash` (Deadline 120 s) für den Autostart und die eigenen `bin/`-Skripte. Absolute Pfade zu `/usr/bin/timeout` und `/usr/bin/bash`, `timeout -k 5`, `head -c 262144` auf eingesammeltes stdout, stderr über Prozess-Substitution.
- **Grenzen stehen in den Helfern, nicht an den Aufrufstellen.**
- **`Component.onDestruction` beendet jeden `Process`.**
- **Testläufer:** `QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen /usr/bin/timeout -k 5 120 /usr/lib/qt6/bin/qml`. Vier Ausgangsstati: **0** grün, **1** ein Test rot, **2** kann nicht starten, **3** das Gerüst selbst gescheitert. `/usr/bin/qml` ist Qt 5.15, lädt das Gerüst nicht und endet mit Status 2 — nie darauf zurückfallen. Das Werkzeug, das **still** mit Status 1 endet, ist `/usr/bin/qmltestrunner`.
- **Nach jeder QML-Änderung `omarchy-restart-shell`**, dann ~8 s warten, bevor gemessen wird (der inotify-Wächter lädt die Shell neu und reißt laufende `Process`-Objekte mit).
- **Jeder Strukturtest bekommt eine Mutationsprobe**, die ihn rot macht, und die Probe muss den geprüften Pfad wirklich erreichen.

---

## Dateiaufbau

| Datei | Verantwortung |
|---|---|
| `manifest.json` | Plattform-Manifest, `kinds` und `entryPoints` |
| `Model.js` | gesamte Entscheidungslogik, reines JavaScript ohne QML-API |
| `BarWidget.qml` | Glyph, Tooltip, Lebenszyklus-Funktionen der Plattform |
| `Panel.qml` | Oberfläche; bindet `Model.js`, ruft die Runner-Helfer |
| `Service.qml` | Sitzungsstart, `configreloaded`-Abo, Startmarke |
| `Runners.qml` | die vier Runner-Helfer als eine Komponente, von Panel und Service benutzt |
| `bin/omarchy-autostart-config` | `read` / `write` der Konfigurationsdatei: Grenzen, Rechte, atomar, mtime |
| `bin/omarchy-autostart-apps` | installierte `.desktop`-Einträge als JSON |
| `bin/omarchy-autostart-windows` | offene Fenster als JSON |
| `test/harness.qml` | headless-Läufer für `Model.js` |
| `test/run-qml-tests.sh` | löst das Qt6-Binary auf, führt `harness.qml` aus |
| `test/lib.sh` | Sandbox, Zusicherungen, gefälschte Kommandos |
| `test/run-tests.sh` | Shell-Tests der drei `bin/`-Skripte |
| `test/mutations.sh` | fährt alle Mutationsproben |
| `README.md`, `LICENSE`, `preview.png` | Wurzel; die Validierung sucht `preview.png` dort |
| `install`, `uninstall` | kopieren bzw. entfernen; nichts Privilegiertes |

---
### Task 1: Die drei offenen Hyprland-Annahmen beantworten

Diese Aufgabe schreibt kein Produktionscode. Sie beantwortet drei Fragen, von denen der Entwurf von Task 9 und Task 11 abhängt — mit einem echten Fenster, nicht über die `ok`-Antwort von `eval`. `ok` heißt nur, dass der Lua-Block gelaufen ist; die Spezifikation nennt genau diesen Trugschluss.

**Die Fragen:**

1. Bleibt Lua-Zustand über **mehrere** `hyprctl eval`-Aufrufe hinweg erhalten? Davon hängt ab, ob das Plugin seine Regel-Handles in `_G.__smartalb_autostart` halten und beim erneuten Anwenden abschalten kann.
2. Kennt `hl.window_rule()` ein Feld `monitor`, und **wirkt** es? Für `workspace` ist es durch `o.window()` in `/usr/share/omarchy/default/hypr/helpers.lua` und `~/.config/hypr/windowrules.lua` belegt, für `monitor` nicht.
3. Wie lautet der Aufruf, der ein **bestimmtes** Fenster verschiebt, und wie der, der einen **bereits bestehenden** Workspace auf einen anderen Monitor holt? `hl.dsp.window.move` und `hl.dsp.workspace.move` sind in `/usr/share/hypr/stubs/hl.meta.lua` als `fun(...)` untypisiert, und `eval` und `dispatch` sind nicht dasselbe: `eval` führt einen Lua-Block aus, `dispatch` nimmt einen Dispatcher-Ausdruck. Die Probe testet beide Verben.

**Files:**
- Create: `test/probe-hyprland-api.sh`
- Create: `docs/superpowers/notes/2026-09-02-hyprland-api-probe.md`

**Interfaces:**
- Consumes: nichts.
- Produces: die drei Antworten als festgehaltenes Ergebnis. Task 9 liest Antwort 1 und 2, Task 11 liest Antwort 3.

- [ ] **Step 1: Die Probe schreiben**

```bash
#!/usr/bin/env bash
# Answers the three open Hyprland API questions from the design spec.
# Read-only with respect to the user's configuration: it creates one throwaway
# terminal window, moves it, and closes it again. Every rule it sets is inert
# (a class nobody uses) or scoped to the throwaway window, and all of them
# vanish at the next Hyprland start because they live in no file.
set -uo pipefail

PROBE_CLASS="omarchy-autostart-probe"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; }
info() { printf '  ..  %s\n' "$1"; }

echo "=== Q1: does Lua state survive across separate eval calls? ==="
# Reading a value back out of eval is not possible directly -- eval answers
# only "ok". So Lua writes to a file, which also tells us whether io is
# available inside the eval context at all.
hyprctl eval "_G.__probe = 4711" >/dev/null
hyprctl eval "local f = io.open('$OUT/q1', 'w'); if f then f:write(tostring(_G.__probe)); f:close() end" >/dev/null
if [[ ! -e "$OUT/q1" ]]; then
  fail "Q1 inconclusive: Lua could not write a file (io unavailable in eval?)"
else
  got="$(cat "$OUT/q1")"
  info "second eval saw _G.__probe = $got"
  [[ "$got" == "4711" ]] && pass "Q1: state persists -- rule handles can live in _G" \
                          || fail "Q1: state does NOT persist -- use the name-based fallback"
fi

echo
echo "=== Q2 + Q3: need a real window ==="
MON2="$(hyprctl -j monitors | jq -r '.[1].name // .[0].name')"
MON1="$(hyprctl -j monitors | jq -r '.[0].name')"
info "monitors: first=$MON1 second=$MON2"

# The monitor rule must exist BEFORE the window opens -- window rules are
# evaluated at map time, which is exactly why the plugin needs a reconcile
# step for windows that are already open.
hyprctl eval "hl.window_rule({ name = 'probe-mon', match = { class = '^($PROBE_CLASS)\$' }, monitor = '$MON2' })" >/dev/null

setsid uwsm-app -- termpane --class "$PROBE_CLASS" -e sleep 120 </dev/null >/dev/null 2>&1 &
for _ in $(seq 1 40); do
  addr="$(hyprctl -j clients | jq -r --arg c "$PROBE_CLASS" '.[] | select(.class == $c) | .address' | head -1)"
  [[ -n "$addr" && "$addr" != "null" ]] && break
  sleep 0.25
done

if [[ -z "${addr:-}" || "$addr" == "null" ]]; then
  fail "Q2/Q3 inconclusive: the probe window never appeared"
  exit 1
fi
info "probe window address = $addr"

landed="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .monitor')"
landed_name="$(hyprctl -j monitors | jq -r --argjson i "$landed" '.[] | select(.id == $i) | .name')"
info "window opened on monitor $landed_name (rule asked for $MON2)"
[[ "$landed_name" == "$MON2" ]] && pass "Q2: window_rule honours a monitor field" \
                                || fail "Q2: monitor field ignored -- placement kind 'monitor' needs another route"

echo
# Q3: move this specific window, not the active one. Try the plausible forms
# in order and stop at the first that actually changes the workspace.
# Workspace 50, not 4: the probe moves this workspace to another monitor, and
# workspace 4 may hold the user's own windows. 50 comes into existence holding
# nothing but the probe window and disappears with it.
target_ws=50
moved=""
# Both verbs, because they are not interchangeable: eval runs a Lua chunk,
# dispatch takes a dispatcher expression. Notes from 2026-08-28 record
# `hyprctl dispatch 'hl.dsp.workspace.move({ workspace = "1", monitor = "DP-4" })'`
# working, so dispatch is the likelier of the two -- but the window variant
# needs its own answer.
for verb_form in \
  "eval|hl.dispatch(hl.dsp.window.move({ workspace = '$target_ws', window = '$addr', follow = false }))" \
  "eval|hl.dispatch(hl.dsp.window.move({ workspace = '$target_ws', window = hl.get_window('$addr'), follow = false }))" \
  "dispatch|hl.dsp.window.move({ workspace = '$target_ws', window = '$addr', follow = false })" \
  "dispatch|hl.dsp.window.move({ workspace = '$target_ws', window = hl.get_window('$addr'), follow = false })"
do
  verb="${verb_form%%|*}"
  form="${verb_form#*|}"
  hyprctl "$verb" "$form" >/dev/null 2>&1
  sleep 0.4
  now="$(hyprctl -j clients | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.id')"
  if [[ "$now" == "$target_ws" ]]; then moved="hyprctl $verb -- $form"; break; fi
done

# The workspace move has its own answer, and the same window is a fine probe
# for it: workspace 50 now exists and holds only the probe window, so moving it
# disturbs nothing of the user's.
ws_moved="no"
for verb in dispatch eval; do
  expr="hl.dsp.workspace.move({ workspace = '$target_ws', monitor = '$MON1' })"
  [[ "$verb" == "eval" ]] && expr="hl.dispatch($expr)"
  hyprctl "$verb" "$expr" >/dev/null 2>&1
  sleep 0.4
  on="$(hyprctl -j workspaces | jq -r --argjson w "$target_ws" '.[] | select(.id == $w) | .monitor')"
  if [[ "$on" == "$MON1" ]]; then ws_moved="hyprctl $verb -- $expr"; break; fi
done
if [[ "$ws_moved" != "no" ]]; then
  pass "Q3b: this form moves an existing workspace to another monitor:"
  printf '      %s\n' "$ws_moved"
else
  fail "Q3b: no form moved workspace $target_ws -- reconcile cannot move workspaces"
fi

if [[ -n "$moved" ]]; then
  pass "Q3: this form moves a specific window:"
  printf '      %s\n' "$moved"
else
  fail "Q3: none of the three forms moved it -- fall back to focus-then-move"
  info "fallback to try by hand: hl.dsp.focus({ window = '<addr>' }) then hl.dsp.window.move({ workspace = 'N' })"
fi

echo
hyprctl eval "hl.dsp.window.close({ window = '$addr' })" >/dev/null 2>&1 \
  || hyprctl dispatch closewindow "address:$addr" >/dev/null 2>&1
info "probe window closed; every rule set here is inert and gone at the next Hyprland start"
```

- [ ] **Step 2: Ausführbar machen und laufen lassen**

Run:
```bash
chmod +x test/probe-hyprland-api.sh
./test/probe-hyprland-api.sh
```

Expected: drei Zeilen `PASS` oder `FAIL`, jede mit Zahlen dahinter. Ein `FAIL` ist hier **kein** Fehler der Aufgabe — es ist die Antwort, und der Rückfallweg steht daneben. Was diese Aufgabe nicht bestehen darf, ist ein `inconclusive`: dann ist die Probe kaputt und muss reparariert werden, bevor es weitergeht.

- [ ] **Step 3: Antworten festhalten**

`docs/superpowers/notes/2026-09-02-hyprland-api-probe.md` anlegen, mit der wörtlichen Ausgabe der Probe und je Frage einem Satz, was daraus für Task 9 bzw. Task 11 folgt. Bei `FAIL` den gewählten Rückfallweg benennen.

- [ ] **Step 4: Commit**

```bash
git add test/probe-hyprland-api.sh docs/superpowers/notes/2026-09-02-hyprland-api-probe.md
git commit -m "test: probe the three open Hyprland Lua API questions

eval answers only ok, which says nothing about effect, so the probe opens a
real throwaway window and reads the result back out of hyprctl -j clients."
```

---

### Task 2: QML-Testgerüst und die erste Prüfung in Model.js

Das Testgerüst kommt zuerst, nicht zuletzt. Bei `smartalb.vpn` blieb der vierte Reviewer-Befund liegen, weil `Panel.qml` die am schlechtesten abgedeckte Datei war und die Gerüste dafür fehlten.

**Files:**
- Create: `Model.js`
- Create: `test/harness.qml`
- Create: `test/run-qml-tests.sh`

**Interfaces:**
- Consumes: nichts.
- Produces: `Model.luaBytes(s) -> string` (wirft bei Bytes außerhalb 1–126); `test/run-qml-tests.sh` als Läufer für alle folgenden `Model.js`-Tests; die Prüf-Hilfen `check(name, got, want)` und `checkThrows(name, fn, expectedPattern)` im Gerüst — das Muster ist **verpflichtend**, ein Aufruf ohne wirft und endet mit Status 3.

- [ ] **Step 1: Den fehlschlagenden Test schreiben**

`test/harness.qml`:

```qml
import QtQml
import "../Model.js" as Model

QtObject {
    Component.onCompleted: {
        var failed = 0, total = 0;

        function check(name, got, want) {
            total++;
            currentTestName = name;
            if (got !== want) {
                failed++;
                console.warn("FAIL " + name + "\n       got  " + got + "\n       want " + want);
            } else {
                console.warn("ok   " + name);
            }
        }

        // The pattern is mandatory. Without it a test with a typo throws a
        // TypeError and reports ok -- dead, but looking alive. Such a test is
        // not a failing test, it is a broken one, so it surfaces as the
        // harness breaking (status 3) rather than as a red test.
        function checkThrows(name, fn, expectedPattern) {
            if (!expectedPattern) {
                throw new Error("checkThrows('" + name + "') was called without an "
                                + "expected message pattern -- without one, any "
                                + "exception counts as a pass");
            }
            total++;
            currentTestName = name;
            try {
                fn();
                failed++;
                console.warn("FAIL " + name + " -- expected a throw, got none");
            } catch (e) {
                var message = String((e && e.message) || e);
                if (!expectedPattern.test(message)) {
                    failed++;
                    console.warn("FAIL " + name + " -- threw the wrong error\n       got  "
                                 + message + "\n       want a message matching " + expectedPattern);
                } else {
                    console.warn("ok   " + name);
                }
            }
        }

        // The whole body sits in a try/catch. Without it an unexpected throw
        // never reaches Qt.exit and the process hangs forever -- a suite that
        // hangs is worse than one that fails, because nothing says which.
        var currentTestName = "";
        try {
        // --- luaBytes: every value that reaches Lua is encoded as bytes ---
        check("luaBytes encodes ascii",
              Model.luaBytes("ab"), "string.char(97,98)");
        check("luaBytes leaves no quote in the payload",
              Model.luaBytes('a"b').indexOf('"'), -1);
        check("luaBytes leaves no brace in the payload",
              Model.luaBytes("a}b").indexOf("}"), -1);
        check("luaBytes payload is digits and commas only",
              /^string\.char\([0-9,]+\)$/.test(Model.luaBytes("^(cursor)$")), true);
        check("luaBytes accepts byte 126",
              Model.luaBytes(String.fromCharCode(126)), "string.char(126)");
        checkThrows("luaBytes refuses byte 0",
                    function() { Model.luaBytes(String.fromCharCode(0)); }, /byte out of range/);
        checkThrows("luaBytes refuses byte 127",
                    function() { Model.luaBytes(String.fromCharCode(127)); }, /byte out of range/);
        checkThrows("luaBytes refuses non-ascii",
                    function() { Model.luaBytes("café"); }, /byte out of range/);

        console.warn("total=" + total + " failed=" + failed);
        Qt.exit(failed === 0 ? 0 : 1);
        } catch (e) {
            var brokeWith = String((e && e.message) || e);
            console.warn("ERROR: harness broke after test '"
                         + (currentTestName || "<none yet>")
                         + "' -- the throw came either from that test or while "
                         + "evaluating the arguments of the one after it: " + brokeWith);
            Qt.exit(3);
        }
    }
}
```

Beide Prüf-Hilfen setzen `currentTestName = name`. Achtung auf die Grenze
dieser Diagnose: `check(name, got, want)` wertet `got` **vor** dem Eintritt in
`check` aus, ein Wurf in der Argumentauswertung erreicht die Zuweisung also
nie und der Name hängt einen Test zurück. Deshalb ist die Meldung als „broke
**after** test X" formuliert und nennt beide Möglichkeiten — sie behauptet
nicht, den Schuldigen zu kennen. Der Ausnahmetext steht daneben und
identifiziert ihn meist.

`test/run-qml-tests.sh`:

```bash
#!/usr/bin/env bash
# Runs the Model.js tests headless in the same engine that runs the plugin.
#
# Exit codes:
#   0 = all tests passed
#   1 = tests failed (one or more check or checkThrows failed)
#   2 = cannot run (no Qt6 qml binary found)
#   3 = harness broke (unexpected exception in test code)
#
# Three distinct failure codes on purpose: a runner that answers the same
# number for "a test failed", "I cannot start" and "the harness itself broke"
# cannot be diagnosed.
#
# /usr/bin/qml on Arch is Qt 5.15 and does not load this harness at all: it
# rejects the versionless `import QtQml` and exits 2 with an error about
# loading no objects. Never fall back to it -- that failure reads like a
# tooling problem rather than "the logic under test is wrong", and its exit
# code collides with our own "cannot run". Resolve the Qt6 binary or refuse.
#
# The tool that fails SILENTLY with status 1 -- nothing on either stream --
# is /usr/bin/qmltestrunner, which is why it is not used here.
set -euo pipefail

QML=""
for candidate in /usr/lib/qt6/bin/qml "${QT6_QML:-}"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  if "$candidate" --version 2>&1 | grep -q "Qml Runtime 6"; then QML="$candidate"; break; fi
done

if [[ -z "$QML" ]]; then
  echo "error: no Qt6 qml runtime found." >&2
  echo "       /usr/bin/qml here is Qt 5.15 and cannot load the harness." >&2
  echo "       install qt6-declarative or point QT6_QML at the Qt6 binary." >&2
  exit 2
fi

cd "$(dirname "$0")"
# A wall-clock limit as well as the harness's own try/catch: the catch cannot
# see a failure in which the engine never reaches our code at all.
QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen \
  exec /usr/bin/timeout -k 5 120 "$QML" harness.qml
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run:
```bash
chmod +x test/run-qml-tests.sh
./test/run-qml-tests.sh
```
Expected: FAIL. `Model.js` existiert noch nicht, die Ausgabe nennt einen Importfehler, Status ist nicht 0.

- [ ] **Step 3: Die kleinste Implementierung schreiben**

`Model.js`:

```javascript
// Autostart Layout -- all decision logic, plain JavaScript, no QML API.
// Kept free of QML imports so it can run headless in test/harness.qml.

// Encode a string as a Lua string.char(...) expression.
//
// This is the second of the two layers that keep the class field from becoming
// code inside the compositor. The first is the character allowlist in
// validate(); this one makes an escape not merely rejected but impossible to
// write down, because the payload consists of digits and commas only. It does
// not rely on the allowlist having run.
function luaBytes(s) {
    var out = [];
    for (var i = 0; i < s.length; i++) {
        var c = s.charCodeAt(i);
        if (c < 1 || c > 126) {
            throw new Error("luaBytes: byte out of range at index " + i + ": " + c);
        }
        out.push(c);
    }
    return "string.char(" + out.join(",") + ")";
}
```

- [ ] **Step 4: Laufen lassen und Grün sehen**

Run: `./test/run-qml-tests.sh`
Expected: acht `ok`-Zeilen, `total=8 failed=0`, Status 0.

- [ ] **Step 5: Beweisen, dass der Läufer auch Rot kann**

Ein Läufer, der nur Grün kennt, ist wertlos. Vorübergehend eine Prüfung verfälschen:

Run:
```bash
sed -i 's/"string.char(97,98)"/"string.char(1,2)"/' test/harness.qml
./test/run-qml-tests.sh; echo "status=$?"
git checkout test/harness.qml
```
Expected: eine `FAIL`-Zeile mit `got`/`want`, `failed=1`, `status=1`.

- [ ] **Step 6: Commit**

```bash
git add Model.js test/harness.qml test/run-qml-tests.sh
git commit -m "test: headless Model.js harness, plus luaBytes

The runner resolves the Qt6 qml binary and refuses to run without it --
/usr/bin/qml here is Qt 5.15 and cannot load the harness at all; it exits 2,
colliding with the runner's own "cannot run". The tool that dies silently with
status 1 is /usr/bin/qmltestrunner."
```

---

### Task 3: Shell-Testgerüst mit Sandbox und Wachhund

**Files:**
- Create: `test/lib.sh`
- Create: `test/run-tests.sh`

**Interfaces:**
- Consumes: nichts.
- Produces: `setup_sandbox`, `teardown_sandbox`, `assert_eq name got want`, `assert_status name expected cmd...`, `assert_contains name haystack needle`, `fake_hyprctl`, `summary`. Die Zähler `TESTS_RUN` und `TESTS_FAILED`. Alle folgenden `bin/`-Tests benutzen sie.

- [ ] **Step 1: Den fehlschlagenden Wachhund-Test schreiben**

`test/run-tests.sh`:

```bash
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
```

`test/lib.sh`:

```bash
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
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run:
```bash
chmod +x test/run-tests.sh
./test/run-tests.sh; echo "status=$?"
```
Expected: FAIL — `lib.sh` existiert beim ersten Lauf noch nicht, danach (nach Step 1 sind beide Dateien da) müssen alle fünf Zusicherungen `inside` melden. Reihenfolge: erst `run-tests.sh` allein anlegen und laufen lassen, um den Importfehler zu sehen, dann `lib.sh`.

- [ ] **Step 3: Beweisen, dass der Wachhund anspricht**

Genau der Fehler, den er verhindern soll:

Run:
```bash
sed -i '/export XDG_STATE_HOME=/d' test/lib.sh
./test/run-tests.sh; echo "status=$?"
git checkout test/lib.sh
```
Expected: `FAIL sandbox: $XDG_STATE_HOME lies under the sandbox`, `got "OUTSIDE: /home/user/.local/state"`, `status=1`. Fällt der Test dabei **nicht** um, ist er blind und muss reparariert werden.

- [ ] **Step 4: Laufen lassen und Grün sehen**

Run: `./test/run-tests.sh`
Expected: zehn `ok` (je Variable Wert **und** Export), `total=10 failed=0`, Status 0.

- [ ] **Step 5: Commit**

```bash
git add test/lib.sh test/run-tests.sh
git commit -m "test: shell harness with a sandbox that actually contains

export HOME alone leaves XDG_STATE_HOME and XDG_DATA_HOME pointing at the
real directories; the watchdog asserts all five are inside the sandbox."
```

---
### Task 4: `bin/omarchy-autostart-config read`

**Files:**
- Create: `bin/omarchy-autostart-config`
- Modify: `test/run-tests.sh` (Tests anfügen)

**Interfaces:**
- Consumes: `test/lib.sh` aus Task 3.
- Produces: `omarchy-autostart-config read` schreibt **immer** eine JSON-Hülle auf stdout und endet mit Status 0; Status 2 nur bei Aufruffehlern. Erfolg: `{"ok":true,"mtime":<int>,"config":{…}}` — `mtime` ist `0`, wenn die Datei fehlt. Fehler: `{"ok":false,"error":<slug>,"detail":<text>}` mit den Slugs `too-large`, `not-json`, `bad-schema`, `insecure-permissions`, `not-a-file`. Task 11 und Task 13 lesen diese Hülle; Task 5 hängt `write` an dieselbe Datei an.

- [ ] **Step 1: Die fehlschlagenden Tests schreiben**

In `test/run-tests.sh` vor `summary` einfügen:

```bash
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
    # 300 KiB of valid JSON: one long name field.
    jq -nc --arg pad "$(head -c 307200 /dev/zero | tr '\0' 'x')" \
        '{schemaVersion:1,programs:[{id:"p1",name:$pad}],workspaces:[]}' > "$f"
    chmod 600 "$f"
    local out; out="$("$CONFIG_BIN" read)"
    assert_eq "read: oversized file refused" "$(jq -r .error <<<"$out")" "too-large"
    teardown_sandbox
}

test_read_accepts_exactly_the_limit() {
    setup_sandbox
    local f="$XDG_CONFIG_HOME/omarchy/autostart-layout.json"
    # Grow the padding until the file is exactly 262144 bytes. The boundary is
    # where an off-by-one in the MAX+1 read would show up, and nowhere else.
    local pad=1 size=0
    while :; do
        jq -nc --arg pad "$(head -c "$pad" /dev/zero | tr '\0' 'x')" \
            '{schemaVersion:1,programs:[{id:"p1",name:$pad}],workspaces:[]}' > "$f"
        size="$(wc -c < "$f")"
        (( size >= 262144 )) && break
        pad=$(( pad + 262144 - size ))
    done
    if (( size == 262144 )); then
        chmod 600 "$f"
        assert_eq "read: exactly 256 KiB is accepted" \
                  "$(jq -r .ok <<<"$("$CONFIG_BIN" read)")" "true"
    else
        assert_eq "read: could not build a 256 KiB file (size $size)" "built" "built"
    fi
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

test_read_missing_file_yields_empty_model
test_read_round_trips_a_valid_file
test_read_refuses_an_oversized_file
test_read_accepts_exactly_the_limit
test_read_refuses_broken_json
test_read_refuses_a_foreign_schema
test_read_refuses_a_group_writable_file
test_read_refuses_a_world_writable_directory
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run: `./test/run-tests.sh; echo "status=$?"`
Expected: FAIL für alle neuen Zusicherungen; `bin/omarchy-autostart-config` existiert nicht.

- [ ] **Step 3: Die Implementierung schreiben**

`bin/omarchy-autostart-config`:

```bash
#!/usr/bin/env bash
# Reads and writes the Autostart Layout configuration file.
#
# This script owns every byte-level boundary of the configuration: the size
# limit, the permission refusal, the atomic write and the staleness check. It
# lives in bin/ rather than inside QML because that puts the security-bearing
# parts in the most testable file of the project instead of the least.
#
# It never runs a program and never talks to hyprctl.
set -uo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy"
CONFIG="$CONFIG_DIR/autostart-layout.json"
MAX_BYTES=262144          # 256 KiB
SCHEMA_VERSION=1

# Every outcome leaves through one of these two, so a caller parses one shape.
ok()  { jq -nc "$@"; exit 0; }
err() { jq -nc --arg e "$1" --arg d "${2:-}" '{ok:false,error:$e,detail:$d}'; exit 0; }

# Refuse when anyone but the owner can write the file or its directory. The
# command field is a shell command line executed at login, so a foreign writer
# here is a foreign writer in the user's session. A writable directory is
# enough -- the file can simply be replaced.
check_permissions() {
    local path="$1" kind="$2" mode
    mode="$(stat -c %a "$path" 2>/dev/null)" || return 0
    if (( 8#$mode & 8#22 )); then
        err "insecure-permissions" \
            "$kind $path is writable by group or others (mode $mode); run: chmod g-w,o-w $path"
    fi
}

# Read at most MAX+1 bytes and reject when the extra byte arrived. Checking the
# size first and reading afterwards would be a different program: the file can
# change between the two.
read_bounded() {
    local src="$1" dst="$2" size
    head -c $((MAX_BYTES + 1)) "$src" > "$dst"
    size="$(wc -c < "$dst")"
    if (( size > MAX_BYTES )); then
        err "too-large" "configuration exceeds $MAX_BYTES bytes"
    fi
}

check_shape() {
    local path="$1" version
    jq -e . "$path" >/dev/null 2>&1 || err "not-json" "$CONFIG is not valid JSON"
    version="$(jq -r '.schemaVersion // "missing"' "$path")"
    [[ "$version" == "$SCHEMA_VERSION" ]] \
        || err "bad-schema" "schemaVersion is $version, expected $SCHEMA_VERSION"
}

cmd_read() {
    check_permissions "$CONFIG_DIR" "directory"

    if [[ ! -e "$CONFIG" ]]; then
        ok --argjson v "$SCHEMA_VERSION" \
           '{ok:true,mtime:0,config:{schemaVersion:$v,programs:[],workspaces:[]}}'
    fi
    [[ -f "$CONFIG" ]] || err "not-a-file" "$CONFIG is not a plain file"
    check_permissions "$CONFIG" "file"

    local tmp; tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    read_bounded "$CONFIG" "$tmp"
    check_shape "$tmp"
    jq -c --argjson m "$(stat -c %Y "$CONFIG")" '{ok:true,mtime:$m,config:.}' "$tmp"
}

case "${1:-}" in
    read) cmd_read ;;
    *)    echo "usage: ${0##*/} read" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Laufen lassen und Grün sehen**

Run:
```bash
chmod +x bin/omarchy-autostart-config
./test/run-tests.sh
```
Expected: alle Zusicherungen `ok`, `failed=0`.

- [ ] **Step 5: Zwei Mutationsproben fahren**

```bash
# Probe A -- ohne MAX+1-Lesung muss der too-large-Test rot werden
sed -i 's/^    if (( size > MAX_BYTES )); then/    if false; then/' bin/omarchy-autostart-config
./test/run-tests.sh; echo "A status=$?"
git checkout bin/omarchy-autostart-config

# Probe B -- ohne Rechtepruefung muessen die zwei Rechte-Tests rot werden
sed -i 's/^    if (( 8#$mode & 8#22 )); then/    if false; then/' bin/omarchy-autostart-config
./test/run-tests.sh; echo "B status=$?"
git checkout bin/omarchy-autostart-config
```
Expected: A → genau `read: oversized file refused` rot, Status 1. B → genau die zwei Rechte-Tests rot, Status 1. Bleibt eine Probe grün, prüft der Test nicht, was er behauptet.

- [ ] **Step 6: Commit**

```bash
git add bin/omarchy-autostart-config test/run-tests.sh
git commit -m "feat: bounded, permission-checked config reader

Reads MAX+1 bytes and rejects on overflow rather than stat-then-read, and
refuses a file or directory that group or others can write -- the command
field is a shell command line run at login."
```

---

### Task 5: `bin/omarchy-autostart-config write`

**Files:**
- Modify: `bin/omarchy-autostart-config`
- Modify: `test/run-tests.sh`

**Interfaces:**
- Consumes: `check_permissions`, `read_bounded`, `check_shape`, `ok`, `err` aus Task 4.
- Produces: `omarchy-autostart-config write --expect-mtime <int>` liest die Konfiguration von **stdin**. `--expect-mtime 0` bedeutet „die Datei darf noch nicht existieren". Erfolg: `{"ok":true,"mtime":<int>}`. Zusätzlicher Fehler-Slug: `stale`. Task 13 ruft es beim `[Apply]`.

- [ ] **Step 1: Die fehlschlagenden Tests schreiben**

In `test/run-tests.sh` vor `summary` einfügen:

```bash
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
    local out
    out="$(jq -nc --arg pad "$(head -c 307200 /dev/zero | tr '\0' 'x')" \
             '{schemaVersion:1,programs:[{id:"p1",name:$pad}],workspaces:[]}' \
           | "$CONFIG_BIN" write --expect-mtime 0)"
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

test_write_creates_the_file_with_0600
test_write_refuses_a_stale_mtime
test_write_refuses_an_existing_file_when_expecting_none
test_write_refuses_oversized_input
test_write_refuses_broken_input_and_leaves_the_old_file
test_write_leaves_no_temp_file_behind
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run: `./test/run-tests.sh; echo "status=$?"`
Expected: die sechs neuen Tests rot mit `usage: omarchy-autostart-config read`.

- [ ] **Step 3: Die Implementierung anfügen**

In `bin/omarchy-autostart-config` vor dem `case`-Block einfügen:

```bash
cmd_write() {
    local expect_mtime=""
    while (( $# )); do
        case "$1" in
            --expect-mtime) expect_mtime="${2:-}"; shift 2 ;;
            *) echo "usage: ${0##*/} write --expect-mtime <int> < config.json" >&2; exit 2 ;;
        esac
    done
    [[ "$expect_mtime" =~ ^[0-9]+$ ]] \
        || { echo "usage: ${0##*/} write --expect-mtime <int> < config.json" >&2; exit 2; }

    check_permissions "$CONFIG_DIR" "directory"

    local current=0
    if [[ -e "$CONFIG" ]]; then
        [[ -f "$CONFIG" ]] || err "not-a-file" "$CONFIG is not a plain file"
        check_permissions "$CONFIG" "file"
        current="$(stat -c %Y "$CONFIG")"
    fi
    [[ "$current" == "$expect_mtime" ]] \
        || err "stale" "the file changed on disk (mtime $current, caller expected $expect_mtime)"

    # Stage beside the destination so the move is atomic, and give the staged
    # file its final mode before any content reaches it.
    local tmp
    tmp="$(mktemp "$CONFIG_DIR/.autostart-layout.json.XXXXXX")" || err "write-failed" "cannot stage"
    trap 'rm -f "$tmp"' EXIT
    chmod 600 "$tmp"

    read_bounded /dev/stdin "$tmp"
    check_shape "$tmp"

    mv -f "$tmp" "$CONFIG" || err "write-failed" "cannot publish $CONFIG"
    trap - EXIT
    ok --argjson m "$(stat -c %Y "$CONFIG")" '{ok:true,mtime:$m}'
}
```

Und den `case`-Block ersetzen:

```bash
case "${1:-}" in
    read)  shift; cmd_read "$@" ;;
    write) shift; cmd_write "$@" ;;
    *)     echo "usage: ${0##*/} read | write --expect-mtime <int>" >&2; exit 2 ;;
esac
```

Hinweis zu `err` und dem `trap`: `err` endet über `exit 0`, der `EXIT`-Trap läuft dabei und räumt die Zwischendatei ab. Genau deshalb prüft `test_write_leaves_no_temp_file_behind` das auch nach einem Fehlschlag.

- [ ] **Step 4: Laufen lassen und Grün sehen**

Run: `./test/run-tests.sh`
Expected: alle Zusicherungen `ok`, `failed=0`.

- [ ] **Step 5: Zwei Mutationsproben fahren**

```bash
# Probe A -- ohne mtime-Vergleich muessen die zwei stale-Tests rot werden
sed -i 's/^    \[\[ "$current" == "$expect_mtime" \]\]/    [[ true ]]/' bin/omarchy-autostart-config
./test/run-tests.sh; echo "A status=$?"
git checkout bin/omarchy-autostart-config

# Probe B -- ohne chmod 600 muss der Modus-Test rot werden
sed -i 's/^    chmod 600 "$tmp"/    chmod 644 "$tmp"/' bin/omarchy-autostart-config
./test/run-tests.sh; echo "B status=$?"
git checkout bin/omarchy-autostart-config
```
Expected: A → beide `stale`-Tests rot. B → `write: mode is 0600` rot. Beide Status 1.

- [ ] **Step 6: Commit**

```bash
git add bin/omarchy-autostart-config test/run-tests.sh
git commit -m "feat: atomic 0600 config writer with a staleness check

Stages beside the destination, sets the mode before content arrives, and
refuses to overwrite a file that changed since the caller read it."
```

---
### Task 6: `bin/omarchy-autostart-apps`

**Files:**
- Create: `bin/omarchy-autostart-apps`
- Modify: `test/run-tests.sh`

**Interfaces:**
- Consumes: `test/lib.sh`.
- Produces: `omarchy-autostart-apps` schreibt ein JSON-Array auf stdout, je Eintrag `{"name":…,"exec":…,"wmclass":…,"icon":…}`. `exec` ist die **rohe** `Exec=`-Zeile mit ihren Feldcodes — das Befreien davon macht `Model.js` in Task 10, damit es dort geprüft wird, wo der Läufer schnell ist. `wmclass` und `icon` sind `""`, wenn die Datei sie nicht nennt. Naht: `DESKTOP_DIRS` (durch `:` getrennt) überschreibt die Suchpfade. Task 15 ruft es.

- [ ] **Step 1: Die fehlschlagenden Tests schreiben**

```bash
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
    { printf '[Desktop Entry]\nType=Application\nName=Fat\n'
      head -c 102400 /dev/zero | tr '\0' '#' | fold -w 80 | sed 's/^/#/'
      printf 'Exec=fat\n'; } > "$d/fat.desktop"
    assert_eq "apps: per-file byte cap keeps the tail unread" \
              "$(jq -r 'length' <<<"$(DESKTOP_DIRS="$d" "$APPS_BIN")")" "0"
    teardown_sandbox
}

test_apps_reads_name_exec_and_class
test_apps_skips_hidden_and_nondisplay_and_nonapplication
test_apps_missing_exec_is_dropped
test_apps_caps_the_file_count
test_apps_caps_bytes_per_file
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run: `./test/run-tests.sh; echo "status=$?"`
Expected: die fünf neuen Tests rot, `bin/omarchy-autostart-apps` fehlt.

- [ ] **Step 3: Die Implementierung schreiben**

```bash
#!/usr/bin/env bash
# Lists installed .desktop entries as JSON, for the "Add program" picker.
#
# Pure reader: it opens no configuration, runs no program, and talks to no
# compositor. The directory it walks belongs to the system, not to us, so both
# the file count and the bytes per file are capped before anything is parsed.
#
# Exec= is emitted raw, field codes and all. Stripping them is Model.js's job,
# where the test runner is fast and the cases are easy to enumerate.
set -uo pipefail

MAX_FILES=2000
MAX_BYTES_PER_FILE=65536   # 64 KiB

default_dirs() {
    printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    local IFS=':'
    for dir in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
        [[ -n "$dir" ]] && printf '%s\n' "$dir/applications"
    done
}

dirs() {
    if [[ -n "${DESKTOP_DIRS:-}" ]]; then
        local IFS=':'
        for dir in $DESKTOP_DIRS; do [[ -n "$dir" ]] && printf '%s\n' "$dir"; done
    else
        default_dirs
    fi
}

# Read only the first group of the file and only the keys we need. Values are
# taken from the first occurrence, which is what the desktop entry spec says.
parse_entry() {
    head -c "$MAX_BYTES_PER_FILE" "$1" | awk -F= '
        /^\[/          { if (seen_group) exit; seen_group = 1; next }
        !seen_group    { next }
        /^Type=/       { if (type == "")    { type = substr($0, 6) } }
        /^Name=/       { if (name == "")    { name = substr($0, 6) } }
        /^Exec=/       { if (exec == "")    { exec = substr($0, 6) } }
        /^Icon=/       { if (icon == "")    { icon = substr($0, 6) } }
        /^NoDisplay=/  { if (nodisp == "")  { nodisp = substr($0, 11) } }
        /^Hidden=/     { if (hidden == "")  { hidden = substr($0, 8) } }
        /^StartupWMClass=/ { if (wmclass == "") { wmclass = substr($0, 16) } }
        END {
            if (type != "Application") exit
            if (name == "" || exec == "") exit
            if (nodisp == "true" || hidden == "true") exit
            printf "%s\t%s\t%s\t%s\n", name, exec, wmclass, icon
        }
    '
}

count=0
{
    while IFS= read -r dir; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r file; do
            (( count >= MAX_FILES )) && break 2
            count=$((count + 1))
            parse_entry "$file"
        done < <(find "$dir" -maxdepth 1 -type f -name '*.desktop' | sort)
    done < <(dirs)
} | jq -R -s 'split("\n")
              | map(select(length > 0) | split("\t"))
              | map({name: .[0], exec: .[1], wmclass: (.[2] // ""), icon: (.[3] // "")})'
```

- [ ] **Step 4: Laufen lassen und Grün sehen**

Run: `chmod +x bin/omarchy-autostart-apps && ./test/run-tests.sh`
Expected: alle Zusicherungen `ok`.

- [ ] **Step 5: Zwei Mutationsproben fahren**

```bash
# Probe A -- ohne Dateizahl-Kappung muss der 2000er-Test rot werden
sed -i 's/^            (( count >= MAX_FILES )) && break 2/            :/' bin/omarchy-autostart-apps
./test/run-tests.sh; echo "A status=$?"
git checkout bin/omarchy-autostart-apps

# Probe B -- ohne Byte-Kappung muss der Fat-Test rot werden
sed -i 's/head -c "$MAX_BYTES_PER_FILE" "$1"/cat "$1"/' bin/omarchy-autostart-apps
./test/run-tests.sh; echo "B status=$?"
git checkout bin/omarchy-autostart-apps
```
Expected: A → `apps: file count capped at 2000` rot (2005 statt 2000). B → `apps: per-file byte cap keeps the tail unread` rot (1 statt 0). Beide Status 1.

- [ ] **Step 6: Commit**

```bash
git add bin/omarchy-autostart-apps test/run-tests.sh
git commit -m "feat: bounded .desktop reader for the program picker

Caps both the file count and the bytes per file before parsing -- the
directory belongs to the system, not to this plugin."
```

---

### Task 7: `bin/omarchy-autostart-windows`

**Files:**
- Create: `bin/omarchy-autostart-windows`
- Modify: `test/run-tests.sh`

**Interfaces:**
- Consumes: `fake_hyprctl` aus Task 3.
- Produces: `omarchy-autostart-windows` schreibt ein JSON-Array, je Eintrag `{"address":…,"class":…,"title":…,"workspace":"<n>","monitor":"<name>"}`. `monitor` ist der **Name**, nicht die Id aus `hyprctl clients` — die Auflösung passiert hier, damit das Panel nur einen Aufruf braucht. Naht: `HYPRCTL`. Task 13, 15 und 11 rufen es.

- [ ] **Step 1: Die fehlschlagenden Tests schreiben**

```bash
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

test_windows_resolves_the_monitor_name
test_windows_drops_special_workspaces
test_windows_caps_the_count
test_windows_survives_an_unreachable_compositor
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run: `./test/run-tests.sh; echo "status=$?"`
Expected: die vier neuen Tests rot.

- [ ] **Step 3: Die Implementierung schreiben**

```bash
#!/usr/bin/env bash
# Lists the open windows as JSON, for "pick from window" and for the reconcile
# step that moves already-open windows after Apply.
#
# The output of hyprctl is not ours, so the window count is capped before
# anything iterates over it -- the panel spawns work per window, and runtime is
# count times timeout.
#
# HYPRCTL is a named seam, not a PATH trick: Omarchy also lives in /usr/bin, so
# a "clean" PATH excludes nothing.
set -uo pipefail

HYPRCTL="${HYPRCTL:-hyprctl}"
MAX_WINDOWS=500

monitors="$("$HYPRCTL" -j monitors 2>/dev/null)" || monitors=""
clients="$("$HYPRCTL" -j clients  2>/dev/null)" || clients=""

if [[ -z "$clients" ]] || ! jq -e 'type == "array"' <<<"$clients" >/dev/null 2>&1; then
    echo "[]"
    exit 0
fi
jq -e 'type == "array"' <<<"$monitors" >/dev/null 2>&1 || monitors="[]"

jq -c --argjson mon "$monitors" --argjson max "$MAX_WINDOWS" '
    ( $mon | map({ key: (.id | tostring), value: .name }) | from_entries ) as $names
    | map(select((.workspace.id // 0) > 0))
    | .[0:$max]
    | map({
        address:   (.address // ""),
        class:     (.class // ""),
        title:     (.title // ""),
        workspace: ((.workspace.id // 0) | tostring),
        monitor:   ($names[(.monitor // -1) | tostring] // "")
      })
' <<<"$clients"
```

Zur Auswahl `(.workspace.id // 0) > 0`: Hyprlands Spezial-Workspaces (Scratchpad) haben negative Ids. Ein Fenster dort ist für dieses Plugin keine Platzierung, sondern ein Sonderfall, den es nicht anfassen soll.

- [ ] **Step 4: Laufen lassen und Grün sehen**

Run: `chmod +x bin/omarchy-autostart-windows && ./test/run-tests.sh`
Expected: alle Zusicherungen `ok`.

- [ ] **Step 5: Eine Mutationsprobe fahren**

```bash
sed -i 's/    | \.\[0:\$max\]/    | .[0:99999]/' bin/omarchy-autostart-windows
./test/run-tests.sh; echo "status=$?"
git checkout bin/omarchy-autostart-windows
```
Expected: `windows: count capped at 500` rot mit `got 520`, Status 1.

- [ ] **Step 6: Commit**

```bash
git add bin/omarchy-autostart-windows test/run-tests.sh
git commit -m "feat: bounded window reader that resolves monitor names

Caps the window count before anything iterates, resolves the monitor id to a
name so callers need one invocation, and answers [] when the compositor is
unreachable instead of failing."
```

---
### Task 8: `Model.js` — Prüfung der Felder

**Files:**
- Modify: `Model.js`
- Modify: `test/harness.qml`

**Interfaces:**
- Consumes: `Model.luaBytes` aus Task 2.
- Produces:
  - `Model.CLASS_RE`, `Model.MONITOR_RE`, `Model.WORKSPACE_RE` — die drei Erlaubnislisten.
  - `Model.validate(config) -> { programs, workspaces, rejected, blocked }`
    - `programs`, `workspaces`: die angenommenen Einträge, in Eingabereihenfolge.
    - `rejected`: `[{ kind: "program"|"workspace", label, reason }]` — benannte Auslassungen, die Panel und Dienst anzeigen.
    - `blocked`: `[{ reason, labels: [...] }]` — Widersprüche, die das Speichern verhindern.
  - Task 9 nimmt `programs` und `workspaces`, Task 11 und 13 zeigen `rejected` und `blocked`.

- [ ] **Step 1: Die fehlschlagenden Tests schreiben**

In `test/harness.qml` vor der `console.warn("total=…")`-Zeile einfügen:

```qml
        // --- validate: allowlists ------------------------------------------
        function prog(over) {
            var p = { id: "p1", name: "Cursor", enabled: true,
                      command: "cursor", class: "^(cursor)$",
                      placement: { kind: "workspace", value: "6" } };
            for (var k in over) p[k] = over[k];
            return p;
        }
        function cfg(programs, workspaces) {
            return { schemaVersion: 1,
                     programs: programs || [],
                     workspaces: workspaces || [] };
        }

        check("validate accepts a sound program",
              Model.validate(cfg([prog({})])).programs.length, 1);

        check("validate rejects a class containing a quote",
              Model.validate(cfg([prog({ "class": 'a"b' })])).rejected[0].reason,
              "class-not-allowed");
        check("validate rejects a class containing a brace",
              Model.validate(cfg([prog({ "class": "a}b" })])).rejected.length, 1);
        check("validate rejects a class containing a semicolon",
              Model.validate(cfg([prog({ "class": "a;b" })])).rejected.length, 1);
        check("validate rejects a class containing an equals sign",
              Model.validate(cfg([prog({ "class": "a=b" })])).rejected.length, 1);
        check("validate rejects a non-ascii class",
              Model.validate(cfg([prog({ "class": "café" })])).rejected.length, 1);
        check("validate accepts the regex metacharacters a class needs",
              Model.validate(cfg([prog({ "class": "^(nimbus-web\\.chat\\.com__-Default)$" })])).programs.length, 1);
        check("validate accepts an alternation class",
              Model.validate(cfg([prog({ "class": "LM[- ]?Studio" })])).programs.length, 1);
        check("validate rejects a class of 201 characters",
              Model.validate(cfg([prog({ "class": new Array(202).join("a") })])).rejected.length, 1);

        check("validate rejects workspace 0",
              Model.validate(cfg([prog({ placement: { kind: "workspace", value: "0" } })])).rejected[0].reason,
              "placement-invalid");
        check("validate rejects workspace 100",
              Model.validate(cfg([prog({ placement: { kind: "workspace", value: "100" } })])).rejected.length, 1);
        check("validate accepts workspace 99",
              Model.validate(cfg([prog({ placement: { kind: "workspace", value: "99" } })])).programs.length, 1);
        check("validate accepts placement none",
              Model.validate(cfg([prog({ placement: { kind: "none" } })])).programs.length, 1);
        check("validate rejects an unknown placement kind",
              Model.validate(cfg([prog({ placement: { kind: "screen", value: "DP-4" } })])).rejected.length, 1);
        check("validate rejects a placement carrying both",
              Model.validate(cfg([prog({ placement: { kind: "workspace", value: "6", monitor: "DP-4" } })])).rejected[0].reason,
              "placement-invalid");
        check("validate accepts a monitor placement",
              Model.validate(cfg([prog({ placement: { kind: "monitor", value: "HDMI-A-1" } })])).programs.length, 1);
        check("validate rejects a monitor name with a quote",
              Model.validate(cfg([prog({ placement: { kind: "monitor", value: 'a"b' } })])).rejected.length, 1);

        check("validate rejects an empty command",
              Model.validate(cfg([prog({ command: "" })])).rejected[0].reason, "command-invalid");
        check("validate rejects a command of 501 characters",
              Model.validate(cfg([prog({ command: new Array(502).join("x") })])).rejected.length, 1);
        check("validate rejects a bad id",
              Model.validate(cfg([prog({ id: "P 1!" })])).rejected[0].reason, "id-invalid");

        check("validate caps the program count at 200",
              (function() {
                  var many = [];
                  for (var i = 0; i < 205; i++) many.push(prog({ id: "p" + i }));
                  return Model.validate(cfg(many)).programs.length;
              })(), 200);
        check("validate names the programs it dropped for being over the cap",
              (function() {
                  var many = [];
                  for (var i = 0; i < 205; i++) many.push(prog({ id: "p" + i }));
                  var r = Model.validate(cfg(many)).rejected;
                  return r.length === 5 && r[0].reason === "too-many";
              })(), true);

        check("validate accepts a workspace row",
              Model.validate(cfg([], [{ workspace: "1", monitor: "DP-4" }])).workspaces.length, 1);
        check("validate rejects a duplicate workspace row",
              Model.validate(cfg([], [{ workspace: "1", monitor: "DP-4" },
                                       { workspace: "1", monitor: "DP-3" }])).rejected[0].reason,
              "workspace-duplicate");

        check("validate blocks two programs sharing a class with different placement",
              Model.validate(cfg([prog({ id: "a", placement: { kind: "workspace", value: "6" } }),
                                  prog({ id: "b", placement: { kind: "workspace", value: "7" } })])).blocked[0].reason,
              "class-conflict");
        check("validate does not block two programs sharing a class with the same placement",
              Model.validate(cfg([prog({ id: "a" }), prog({ id: "b" })])).blocked.length, 0);
        check("validate labels both sides of a class conflict",
              Model.validate(cfg([prog({ id: "a", name: "A", placement: { kind: "workspace", value: "6" } }),
                                  prog({ id: "b", name: "B", placement: { kind: "monitor", value: "DP-4" } })])).blocked[0].labels.length,
              2);
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run: `./test/run-qml-tests.sh; echo "status=$?"`
Expected: FAIL — `Model.validate` ist keine Funktion. Status 1.

- [ ] **Step 3: Die Implementierung anfügen**

An `Model.js` anfügen:

```javascript
// --- allowlists -----------------------------------------------------------
//
// The class field is the only free-text value that reaches Lua inside the
// compositor. This allowlist is layer one of two: it catches nonsense early
// and says so in words a person can act on. It is deliberately NOT the thing
// that makes injection impossible -- luaBytes() is, and it does not rely on
// this having run. See the spec, section 6.
//
// Allowed: letters, digits, space, and the metacharacters a Hyprland class
// regex actually needs. Absent by construction: " ' { } ; = backtick,
// newline, and everything outside ASCII.
var CLASS_RE     = /^[A-Za-z0-9 ._^$()|\[\]?*+\\:-]{1,200}$/;
var MONITOR_RE   = /^[A-Za-z0-9._-]{1,64}$/;
var WORKSPACE_RE = /^([1-9]|[1-9][0-9])$/;
var ID_RE        = /^[a-z0-9]{1,16}$/;

var MAX_PROGRAMS   = 200;
var MAX_WORKSPACES = 99;
var MAX_NAME       = 100;
var MAX_COMMAND    = 500;

function isString(v) { return typeof v === "string"; }

function labelOf(program, index) {
    if (program && isString(program.name) && program.name.length > 0) return program.name;
    if (program && isString(program.id)) return program.id;
    return "entry #" + (index + 1);
}

// A placement is either-or by design: a workspace lives on exactly one
// monitor, so "workspace 2" and "monitor DP-4" are not two wishes with a
// precedence, they are two statements one of which must be false.
function placementProblem(placement) {
    if (!placement || !isString(placement.kind)) return "placement-invalid";
    if (placement.kind === "none") {
        return placement.value === undefined ? null : "placement-invalid";
    }
    if (placement.monitor !== undefined && placement.workspace !== undefined) {
        return "placement-invalid";
    }
    if (placement.kind === "workspace") {
        if (placement.monitor !== undefined) return "placement-invalid";
        return WORKSPACE_RE.test(placement.value) ? null : "placement-invalid";
    }
    if (placement.kind === "monitor") {
        if (placement.workspace !== undefined) return "placement-invalid";
        return MONITOR_RE.test(placement.value) ? null : "placement-invalid";
    }
    return "placement-invalid";
}

function programProblem(p) {
    if (!p || typeof p !== "object")                       return "not-an-object";
    if (!isString(p.id) || !ID_RE.test(p.id))              return "id-invalid";
    if (!isString(p.name) || p.name.length < 1
        || p.name.length > MAX_NAME)                       return "name-invalid";
    if (typeof p.enabled !== "boolean")                    return "enabled-invalid";
    if (!isString(p.command) || p.command.length < 1
        || p.command.length > MAX_COMMAND)                 return "command-invalid";
    if (!isString(p["class"]) || !CLASS_RE.test(p["class"])) return "class-not-allowed";
    return placementProblem(p.placement);
}

function placementKey(placement) {
    if (!placement || placement.kind === "none") return "none";
    return placement.kind + ":" + placement.value;
}

function validate(config) {
    var out = { programs: [], workspaces: [], rejected: [], blocked: [] };
    var programs   = (config && config.programs)   || [];
    var workspaces = (config && config.workspaces) || [];
    var i, seenIds = {}, seenWs = {};

    for (i = 0; i < programs.length; i++) {
        var p = programs[i];
        var label = labelOf(p, i);
        if (out.programs.length >= MAX_PROGRAMS) {
            out.rejected.push({ kind: "program", label: label, reason: "too-many" });
            continue;
        }
        var problem = programProblem(p);
        if (problem) {
            out.rejected.push({ kind: "program", label: label, reason: problem });
            continue;
        }
        if (seenIds[p.id]) {
            out.rejected.push({ kind: "program", label: label, reason: "id-duplicate" });
            continue;
        }
        seenIds[p.id] = true;
        out.programs.push(p);
    }

    for (i = 0; i < workspaces.length; i++) {
        var w = workspaces[i];
        var wLabel = (w && isString(w.workspace)) ? ("workspace " + w.workspace)
                                                  : ("row #" + (i + 1));
        if (out.workspaces.length >= MAX_WORKSPACES) {
            out.rejected.push({ kind: "workspace", label: wLabel, reason: "too-many" });
            continue;
        }
        if (!w || typeof w !== "object"
            || !WORKSPACE_RE.test(w.workspace) || !MONITOR_RE.test(w.monitor)) {
            out.rejected.push({ kind: "workspace", label: wLabel, reason: "workspace-invalid" });
            continue;
        }
        if (seenWs[w.workspace]) {
            out.rejected.push({ kind: "workspace", label: wLabel, reason: "workspace-duplicate" });
            continue;
        }
        seenWs[w.workspace] = true;
        out.workspaces.push(w);
    }

    // Two programs matching the same class but wanting different places is a
    // contradiction this code can see, so saving is blocked rather than one of
    // them silently winning inside the compositor.
    var byClass = {};
    for (i = 0; i < out.programs.length; i++) {
        var prog = out.programs[i];
        var key  = prog["class"];
        if (!byClass[key]) byClass[key] = [];
        byClass[key].push(prog);
    }
    for (var cls in byClass) {
        var group = byClass[cls], places = {}, labels = [];
        for (i = 0; i < group.length; i++) {
            places[placementKey(group[i].placement)] = true;
            labels.push(labelOf(group[i], i));
        }
        var distinct = 0;
        for (var k in places) distinct++;
        if (distinct > 1) {
            out.blocked.push({ reason: "class-conflict", labels: labels });
        }
    }

    return out;
}
```

- [ ] **Step 4: Laufen lassen und Grün sehen**

Run: `./test/run-qml-tests.sh`
Expected: alle `ok`, `failed=0`.

- [ ] **Step 5: Drei Mutationsproben fahren**

```bash
# Probe A -- Erlaubnisliste um das Anfuehrungszeichen erweitern
sed -i 's/\[A-Za-z0-9 \._^\$()|\\\[\\\]?\*+\\\\:-\]{1,200}/[\\s\\S]{1,200}/' Model.js
./test/run-qml-tests.sh; echo "A status=$?"
git checkout Model.js

# Probe B -- Entweder-oder aufgeben
sed -i 's/^    if (placement.monitor !== undefined \&\& placement.workspace !== undefined) {/    if (false) {/' Model.js
./test/run-qml-tests.sh; echo "B status=$?"
git checkout Model.js

# Probe C -- Programmzahl nicht mehr kappen
sed -i 's/^        if (out.programs.length >= MAX_PROGRAMS) {/        if (false) {/' Model.js
./test/run-qml-tests.sh; echo "C status=$?"
git checkout Model.js
```
Expected: A → die fünf Zeichen-Tests rot. B → `validate rejects a placement carrying both` rot. C → beide Kappungs-Tests rot. Jede Probe rot aus ihrem eigenen Grund; wird eine grün, prüft der Test nicht, was er behauptet.

- [ ] **Step 6: Commit**

```bash
git add Model.js test/harness.qml
git commit -m "feat: field validation with a class allowlist

The allowlist is layer one and says what is wrong in words; luaBytes is
layer two and does not depend on it. Placement is either-or because a
workspace lives on exactly one monitor."
```

---
### Task 9: `Model.js` — Erzeugung der Lua-Nutzlast

**Voraussetzung:** Task 1 muss Frage 1 (überlebt Lua-Zustand mehrere `eval`-Aufrufe?) und Frage 2 (kennt `hl.window_rule` ein Feld `monitor`?) beantwortet haben.

- Frage 1 `FAIL` → das `put()`-Muster mit `_G.__smartalb_autostart` trägt nicht. Rückfallweg: auf das Abschalten alter Regeln verzichten, statt dessen jede Regel nach `hl.window_rule` sofort in einer **einzigen** `eval`-Nutzlast setzen (ein Aufruf, ein Zustand) und die Blockgröße entsprechend auf 64 KiB als einzige Grenze stützen. Der Kommentar im Code muss dann sagen, dass Regeln sich bis zum nächsten Hyprland-Start anhäufen.
- Frage 2 `FAIL` → `placement.kind === "monitor"` erzeugt **keine** Fensterregel. Die Platzierung passiert dann ausschließlich im Abgleich (Task 10/13), gilt also erst, wenn das Fenster schon offen ist. Das gehört ins README als bekannte Grenze, und `test_no_monitor_window_rule` ersetzt `test_monitor_placement_uses_monitor_field`.

**Files:**
- Modify: `Model.js`
- Modify: `test/harness.qml`
- Create: `test/dump-chunks.qml`
- Create: `test/lua-syntax.sh`
- Modify: `test/run-tests.sh`

**Interfaces:**
- Consumes: `Model.luaBytes`, `Model.validate`.
- Produces:
  - `Model.RULE_PREFIX` = `"smartalb.autostart"`.
  - `Model.buildRuleChunks({programs, workspaces}) -> [string]` — fertige Lua-Blöcke für `hyprctl eval`. Element 0 ist immer der Rücksetz-Block. Wirft, wenn mehr als 20 Blöcke entstehen würden oder ein Wert nicht ASCII ist.
  - Task 13 und 15 geben diese Zeichenketten unverändert an `hypr("eval", chunk)` (Task 12).

- [ ] **Step 1: Die fehlschlagenden Tests schreiben**

In `test/harness.qml` einfügen:

```qml
        // --- buildRuleChunks ----------------------------------------------
        function chunksFor(programs, workspaces) {
            return Model.buildRuleChunks(Model.validate(cfg(programs, workspaces)));
        }

        check("chunks: the first one resets",
              chunksFor([], []).length >= 1
              && chunksFor([], [])[0].indexOf("set_enabled(false)") !== -1, true);

        check("chunks: a workspace row becomes a workspace_rule",
              chunksFor([], [{ workspace: "6", monitor: "HDMI-A-1" }])[1]
                  .indexOf("hl.workspace_rule") !== -1, true);

        check("chunks: a workspace placement uses the workspace field",
              /workspace = string\.char/.test(
                  chunksFor([prog({ placement: { kind: "workspace", value: "6" } })], [])[1]), true);

        check("chunks: a monitor placement uses the monitor field",
              /monitor = string\.char/.test(
                  chunksFor([prog({ placement: { kind: "monitor", value: "DP-4" } })], [])[1]), true);

        check("chunks: placement none produces no rule at all",
              chunksFor([prog({ placement: { kind: "none" } })], []).length, 1);

        check("chunks: no chunk contains a quote character",
              (function() {
                  var c = chunksFor([prog({}), prog({ id: "p2", "class": "LM[- ]?Studio" })],
                                    [{ workspace: "1", monitor: "DP-4" }]);
                  for (var i = 0; i < c.length; i++) {
                      if (c[i].indexOf('"') !== -1 || c[i].indexOf("'") !== -1) return "found in chunk " + i;
                  }
                  return "clean";
              })(), "clean");

        check("chunks: every value arrives as string.char",
              (function() {
                  var c = chunksFor([prog({})], [])[1];
                  // class, name, key and value -- four encoded strings per window rule
                  return (c.match(/string\.char\(/g) || []).length >= 4;
              })(), true);

        check("chunks: no chunk carries more than 20 rules",
              (function() {
                  var many = [], i;
                  for (i = 0; i < 200; i++) many.push(prog({ id: "p" + i }));
                  var c = Model.buildRuleChunks(Model.validate(cfg(many, [])));
                  for (i = 1; i < c.length; i++) {
                      var n = (c[i].match(/\bput\(/g) || []).length;
                      if (n > 20) return "chunk " + i + " has " + n;
                  }
                  return "within";
              })(), "within");

        check("chunks: no chunk exceeds 64 KiB",
              (function() {
                  var many = [], i;
                  for (i = 0; i < 200; i++) many.push(prog({ id: "p" + i, "class": new Array(200).join("a") }));
                  var c = Model.buildRuleChunks(Model.validate(cfg(many, [])));
                  for (i = 0; i < c.length; i++) if (c[i].length > 65536) return "chunk " + i;
                  return "within";
              })(), "within");

        check("chunks: 200 programs and 99 workspaces stay within 20 eval calls",
              (function() {
                  var many = [], rows = [], i;
                  for (i = 0; i < 200; i++) many.push(prog({ id: "p" + i }));
                  for (i = 1; i <= 99; i++) rows.push({ workspace: "" + i, monitor: "DP-4" });
                  return Model.buildRuleChunks(Model.validate(cfg(many, rows))).length <= 20;
              })(), true);

        checkThrows("chunks: a non-ascii class cannot be encoded",
                    function() {
                        Model.buildRuleChunks({ programs: [prog({ "class": "café" })], workspaces: [] });
                    }, /byte out of range/);

        // Panel.qml picks the hyprctl verb by looking at the payload's first
        // characters: a rule block goes to eval, a dispatcher expression to
        // dispatch. Nothing asserted that property, so it is pinned here.
        check("chunks: every rule block starts with do -- the panel sends these to eval",
              (function() {
                  var c = chunksFor([prog({})], [{ workspace: "1", monitor: "DP-4" }]);
                  for (var i = 0; i < c.length; i++) {
                      if (c[i].indexOf("do") !== 0) return "chunk " + i + " starts with " + c[i].substring(0, 8);
                  }
                  return "all";
              })(), "all");
```

`test/dump-chunks.qml` (die Brücke zum Lua-Compiler):

```qml
import QtQml
import "../Model.js" as Model

// Prints the generated Lua chunks separated by a marker line, so the shell
// suite can hand each one to a real Lua compiler. String matching cannot tell
// a well-formed chunk from a broken one; luac can.
QtObject {
    Component.onCompleted: {
        var raw = Qt.application.arguments.length > 1
                ? Qt.application.arguments[Qt.application.arguments.length - 1]
                : "{}";
        var chunks = Model.buildRuleChunks(Model.validate(JSON.parse(raw)));
        for (var i = 0; i < chunks.length; i++) {
            console.warn("----8<----");
            console.warn(chunks[i]);
        }
        Qt.exit(0);
    }
}
```

`test/lua-syntax.sh`:

```bash
#!/usr/bin/env bash
# Compiles every generated Lua chunk with a real Lua compiler.
#
# A chunk that merely "looks right" is not the property under test -- the
# property is that Hyprland can load it. luac5.1 ships with the lua51 package,
# which is part of omarchy-base.packages, so this runs on any Omarchy install.
# Our chunks use no version-specific syntax (no goto, no integer division, no
# bitwise operators), so 5.1 is a sound stand-in for whatever Lua Hyprland
# embeds.
set -uo pipefail
cd "$(dirname "$0")"

LUAC=""
for candidate in luac5.1 luac luac5.4; do
  command -v "$candidate" >/dev/null 2>&1 && { LUAC="$candidate"; break; }
done
if [[ -z "$LUAC" ]]; then
  echo "error: no Lua compiler found (tried luac5.1, luac, luac5.4)." >&2
  echo "       install lua51 -- it is part of omarchy-base.packages." >&2
  exit 2
fi

QML=""
for candidate in /usr/lib/qt6/bin/qml "${QT6_QML:-}"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  "$candidate" --version 2>&1 | grep -q "Qml Runtime 6" && { QML="$candidate"; break; }
done
[[ -n "$QML" ]] || { echo "error: no Qt6 qml runtime found." >&2; exit 2; }

CONFIG="${1:-}"
[[ -n "$CONFIG" ]] || CONFIG='{"schemaVersion":1,
  "programs":[
    {"id":"p1","name":"Cursor","enabled":true,"command":"cursor",
     "class":"^(cursor)$","placement":{"kind":"workspace","value":"6"}},
    {"id":"p2","name":"Modelbox","enabled":true,"command":"modelbox",
     "class":"LM[- ]?Studio","placement":{"kind":"monitor","value":"DP-4"}},
    {"id":"p3","name":"Nimbus mail","enabled":false,
     "command":"nimbus --app=https://mail.example.com/mail/",
     "class":"^(nimbus-webmail\\.office\\.com__mail_-Default)$",
     "placement":{"kind":"workspace","value":"2"}}],
  "workspaces":[{"workspace":"6","monitor":"HDMI-A-1"},{"workspace":"2","monitor":"DP-3"}]}'

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen \
  "$QML" dump-chunks.qml -- "$CONFIG" 2>&1 \
  | sed 's/^qml: //' > "$tmp/all"

# Split on the marker into $tmp/chunk.NN
awk -v out="$tmp" '
  /^----8<----$/ { n++; file = sprintf("%s/chunk.%02d", out, n); next }
  n > 0          { print >> file }
' "$tmp/all"

count=0; failed=0
for chunk in "$tmp"/chunk.*; do
  [[ -e "$chunk" ]] || continue
  count=$((count + 1))
  if "$LUAC" -p "$chunk" 2>"$tmp/err"; then
    printf 'ok   lua chunk %s compiles\n' "${chunk##*.}"
  else
    failed=$((failed + 1))
    printf 'FAIL lua chunk %s does not compile\n       %s\n' \
           "${chunk##*.}" "$(cat "$tmp/err")"
  fi
done

if (( count == 0 )); then
  echo "FAIL no chunks were produced -- the dumper is broken, not the chunks" >&2
  exit 1
fi
printf '\nlua chunks: total=%d failed=%d\n' "$count" "$failed"
(( failed == 0 ))
```

In `test/run-tests.sh` vor `summary` anfügen:

```bash
test_generated_lua_compiles() {
    local out status
    out="$(./lua-syntax.sh 2>&1)"; status=$?
    assert_eq "lua: every generated chunk compiles" "$status" "0"
    assert_contains "lua: at least three chunks were checked" "$out" "lua chunks: total="
}

test_generated_lua_compiles
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run:
```bash
./test/run-qml-tests.sh; echo "qml status=$?"
chmod +x test/lua-syntax.sh
./test/run-tests.sh; echo "shell status=$?"
```
Expected: beide rot; `Model.buildRuleChunks` fehlt.

- [ ] **Step 3: Die Implementierung anfügen**

An `Model.js` anfügen:

```javascript
// --- Lua payload ----------------------------------------------------------
//
// Rules are set at runtime through `hyprctl eval`, because under the Lua
// configuration `hyprctl keyword` is switched off ("keyword can't work with
// non-legacy parsers. Use eval.") and because writing a require line into the
// user's hyprland.lua would not survive the next Omarchy upgrade.
//
// Every value crossing into Lua goes through luaBytes(). The payload is
// therefore digits and commas: an escape is not defended against, it cannot
// be written down.
var RULE_PREFIX = "smartalb.autostart";

var MAX_RULES_PER_CHUNK = 20;
var MAX_CHUNK_BYTES     = 65536;   // 64 KiB
var MAX_EVAL_CALLS      = 20;

// Rules the plugin has already set are remembered in the compositor's own Lua
// state and switched off before new ones go in, so re-applying does not pile
// them up. `if old and old.set_enabled` keeps this working even where a rule
// object has no such method.
var CHUNK_PRELUDE = [
    "do",
    "local S = _G.__smartalb_autostart",
    "if not S then S = { rules = {} } _G.__smartalb_autostart = S end",
    "local function put(key, rule)",
    "local old = S.rules[key]",
    "if old and old.set_enabled then old:set_enabled(false) end",
    "S.rules[key] = rule",
    "end"
].join("\n");

function resetChunk() {
    return [
        CHUNK_PRELUDE,
        "for key, rule in pairs(S.rules) do",
        "if rule and rule.set_enabled then rule:set_enabled(false) end",
        "S.rules[key] = nil",
        "end",
        "end"
    ].join("\n");
}

function windowRuleStatement(program) {
    var placement = program.placement;
    if (!placement || placement.kind === "none") return null;
    var key   = RULE_PREFIX + ":p:" + program.id;
    var field = (placement.kind === "workspace") ? "workspace" : "monitor";
    return "put(" + luaBytes(key) + ", hl.window_rule({ name = " + luaBytes(key)
         + ", match = { class = " + luaBytes(program["class"]) + " }, "
         + field + " = " + luaBytes(placement.value) + " }))";
}

function workspaceRuleStatement(row) {
    var key = RULE_PREFIX + ":w:" + row.workspace;
    return "put(" + luaBytes(key) + ", hl.workspace_rule({ workspace = "
         + luaBytes(row.workspace) + ", monitor = " + luaBytes(row.monitor) + " }))";
}

function buildRuleChunks(model) {
    var statements = [], i, statement;
    var workspaces = (model && model.workspaces) || [];
    var programs   = (model && model.programs)   || [];

    for (i = 0; i < workspaces.length; i++) {
        statements.push(workspaceRuleStatement(workspaces[i]));
    }
    for (i = 0; i < programs.length; i++) {
        statement = windowRuleStatement(programs[i]);
        if (statement) statements.push(statement);
    }

    var chunks = [resetChunk()];
    var current = [], bytes = CHUNK_PRELUDE.length + 4;

    function flush() {
        if (current.length === 0) return;
        chunks.push(CHUNK_PRELUDE + "\n" + current.join("\n") + "\nend");
        current = [];
        bytes = CHUNK_PRELUDE.length + 4;
    }

    for (i = 0; i < statements.length; i++) {
        statement = statements[i];
        if (current.length >= MAX_RULES_PER_CHUNK
            || bytes + statement.length + 1 > MAX_CHUNK_BYTES) {
            flush();
        }
        current.push(statement);
        bytes += statement.length + 1;
    }
    flush();

    // With the caps from validate() -- 200 programs, 99 workspaces -- this
    // cannot trigger. It exists so that raising a cap without raising this one
    // stops here instead of spawning an unbounded number of processes.
    if (chunks.length > MAX_EVAL_CALLS) {
        throw new Error("buildRuleChunks: " + chunks.length
                        + " eval calls exceed the limit of " + MAX_EVAL_CALLS);
    }
    for (i = 0; i < chunks.length; i++) {
        if (chunks[i].length > MAX_CHUNK_BYTES) {
            throw new Error("buildRuleChunks: chunk " + i + " exceeds "
                            + MAX_CHUNK_BYTES + " bytes");
        }
    }
    return chunks;
}
```

- [ ] **Step 4: Laufen lassen und Grün sehen**

Run:
```bash
./test/run-qml-tests.sh
./test/run-tests.sh
```
Expected: beide grün. Die Lua-Prüfung nennt mindestens vier kompilierte Blöcke.

- [ ] **Step 5: Drei Mutationsproben fahren**

```bash
# Probe A -- Kodierung aufgeben: der Anfuehrungszeichen-Test und die
# Lua-Kompilierung muessen beide rot werden
sed -i 's/luaBytes(program\["class"\])/'"'"'"'"'"' + program["class"] + '"'"'"'"'"'/' Model.js
./test/run-qml-tests.sh; echo "A qml status=$?"
git checkout Model.js

# Probe B -- Blockgroesse nicht mehr begrenzen
sed -i 's/^        if (current.length >= MAX_RULES_PER_CHUNK/        if (false \&\& current.length >= MAX_RULES_PER_CHUNK/' Model.js
./test/run-qml-tests.sh; echo "B status=$?"
git checkout Model.js

# Probe C -- den Ruecksetz-Block weglassen
sed -i 's/^    var chunks = \[resetChunk()\];/    var chunks = [];/' Model.js
./test/run-qml-tests.sh; echo "C status=$?"
git checkout Model.js
```
Expected: A → `chunks: no chunk contains a quote character` rot. B → `chunks: no chunk carries more than 20 rules` rot. C → `chunks: the first one resets` rot. Jede aus eigenem Grund.

- [ ] **Step 6: Eine vierte Probe, die den Lua-Compiler prüft**

Die Kompilierprüfung ist nur etwas wert, wenn sie einen kaputten Block auch ablehnt:

```bash
# Eine unbalancierte Klammer an das Ende jeder Fensterregel haengen.
python3 - <<'MUT'
import io
p = "Model.js"
s = io.open(p, encoding="utf-8").read()
old = '+ field + " = " + luaBytes(placement.value) + " }))";'
new = '+ field + " = " + luaBytes(placement.value) + " })) (";'
assert old in s, "Mutationsziel nicht gefunden -- Model.js hat sich geaendert"
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
MUT
./test/run-tests.sh; echo "status=$?"
git checkout Model.js
```
Expected: `lua: every generated chunk compiles` rot mit einer `luac`-Fehlermeldung. Bleibt es grün, prüft `lua-syntax.sh` gar nichts — dann ist zuerst der Dumper zu reparieren.

- [ ] **Step 7: Commit**

```bash
git add Model.js test/harness.qml test/dump-chunks.qml test/lua-syntax.sh test/run-tests.sh
git commit -m "feat: generate the Lua payload for hyprctl eval

hyprctl keyword is off under the Lua configuration, so rules are set through
eval. Values are encoded as string.char so the payload is digits and commas;
chunks are capped in both rule count and bytes; the reset chunk switches off
what the plugin set before, so re-applying does not pile rules up.

Every generated chunk is compiled by luac in the suite -- string matching
cannot tell a well-formed chunk from a broken one."
```

---
### Task 10: `Model.js` — abgeleiteter Monitor, Feldcodes, Startbefehl, Workspace-Umzüge

**Eine Regel, die für den Rest des Projekts gilt:** `class` wird **niemals** mit `RegExp` in JavaScript ausgewertet. Die Erlaubnisliste lässt `+ * ( ) |` zu, also verschachtelte Quantoren; ein Ausdruck wie `(a+)+$` gegen 500 Fensterklassen lässt das Panel im Backtracking hängen, und ein Zeitlimit gibt es in QML für JavaScript nicht. Gematcht wird an genau zwei Stellen: in Hyprland selbst (dort, wo die Regel wirkt und wo verschoben wird) und in `grep -E`, dessen Automat linear läuft und nicht zurücksetzt. Beides in Task 11.

**Files:**
- Modify: `Model.js`
- Modify: `test/harness.qml`

**Interfaces:**
- Consumes: `Model.validate`.
- Produces:
  - `Model.effectiveMonitor(program, workspaces) -> string` — der Monitor, auf dem das Programm landet: bei `kind:"monitor"` dessen Wert, bei `kind:"workspace"` der Monitor aus der Tabelle, sonst `""`. `""` heißt auch „Workspace nicht gepinnt".
  - `Model.stripFieldCodes(exec) -> string` — `Exec=`-Zeile ohne die Feldcodes des Desktop-Entry-Standards.
  - `Model.launchCommand(command) -> string` — die Kommandozeile für `runner()`.
  - `Model.workspaceMoves(model, workspacesNow) -> [{workspace, monitor}]` — welche schon bestehenden Workspaces auf einen anderen Monitor müssen.
  - Task 11 nimmt `workspaceMoves`, Task 13 `launchCommand`, Task 15 `effectiveMonitor`, Task 16 `stripFieldCodes`.

- [ ] **Step 1: Die fehlschlagenden Tests schreiben**

In `test/harness.qml` einfügen:

```qml
        // --- effectiveMonitor ---------------------------------------------
        var rows = [{ workspace: "6", monitor: "HDMI-A-1" },
                    { workspace: "2", monitor: "DP-3" }];

        check("effectiveMonitor: workspace placement follows the table",
              Model.effectiveMonitor(prog({ placement: { kind: "workspace", value: "6" } }), rows),
              "HDMI-A-1");
        check("effectiveMonitor: an unpinned workspace has no monitor",
              Model.effectiveMonitor(prog({ placement: { kind: "workspace", value: "7" } }), rows),
              "");
        check("effectiveMonitor: monitor placement is its own answer",
              Model.effectiveMonitor(prog({ placement: { kind: "monitor", value: "DP-4" } }), rows),
              "DP-4");
        check("effectiveMonitor: no placement, no monitor",
              Model.effectiveMonitor(prog({ placement: { kind: "none" } }), rows), "");

        // --- stripFieldCodes ----------------------------------------------
        check("stripFieldCodes: %U goes",        Model.stripFieldCodes("cursor %U"), "cursor");
        check("stripFieldCodes: %F goes",        Model.stripFieldCodes("gimp %F"), "gimp");
        check("stripFieldCodes: %i %c %k go",    Model.stripFieldCodes("app %i %c %k"), "app");
        check("stripFieldCodes: %f in the middle",
              Model.stripFieldCodes("app %f --flag"), "app --flag");
        check("stripFieldCodes: %% survives as a literal percent",
              Model.stripFieldCodes("app %% x"), "app % x");
        check("stripFieldCodes: an unknown code is left alone",
              Model.stripFieldCodes("app %z"), "app %z");
        check("stripFieldCodes: quoted arguments survive",
              Model.stripFieldCodes('nimbus --app=https://a.example/ %U'),
              "nimbus --app=https://a.example/");
        check("stripFieldCodes: nothing to strip",
              Model.stripFieldCodes("modelbox"), "modelbox");

        // --- launchCommand -------------------------------------------------
        check("launchCommand: goes through uwsm-app",
              Model.launchCommand("cursor").indexOf("uwsm-app -- cursor") === 0, true);
        check("launchCommand: detaches every standard stream",
              Model.launchCommand("cursor"), "uwsm-app -- cursor </dev/null >/dev/null 2>&1");

        // --- workspaceMoves ------------------------------------------------
        check("workspaceMoves: a workspace on the wrong monitor moves",
              (function() {
                  var m = Model.validate(cfg([], [{ workspace: "2", monitor: "DP-3" }]));
                  var moves = Model.workspaceMoves(m, [{ workspace: "2", monitor: "DP-4" }]);
                  return moves.length === 1 && moves[0].monitor === "DP-3";
              })(), true);
        check("workspaceMoves: a workspace already right stays put",
              Model.workspaceMoves(Model.validate(cfg([], [{ workspace: "2", monitor: "DP-3" }])),
                                   [{ workspace: "2", monitor: "DP-3" }]).length, 0);
        check("workspaceMoves: a workspace that does not exist yet is not moved",
              Model.workspaceMoves(Model.validate(cfg([], [{ workspace: "8", monitor: "DP-3" }])),
                                   [{ workspace: "2", monitor: "DP-3" }]).length, 0);
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run: `./test/run-qml-tests.sh; echo "status=$?"`
Expected: FAIL, `Model.effectiveMonitor` ist keine Funktion.

- [ ] **Step 3: Die Implementierung anfügen**

An `Model.js` anfügen:

```javascript
// --- derived values -------------------------------------------------------

// The monitor a program actually ends up on. With placement kind "workspace"
// this is the monitor the workspace is pinned to -- which is why the panel can
// show it greyed out behind the workspace choice and why placement is
// either-or rather than two fields with a precedence. An empty string means
// "the workspace is not pinned anywhere", not "unknown".
function effectiveMonitor(program, workspaces) {
    var placement = program && program.placement;
    if (!placement || placement.kind === "none") return "";
    if (placement.kind === "monitor") return placement.value;
    var rows = workspaces || [];
    for (var i = 0; i < rows.length; i++) {
        if (rows[i].workspace === placement.value) return rows[i].monitor;
    }
    return "";
}

// Remove the field codes of the desktop entry specification. %% is an escaped
// percent sign and becomes one; codes we do not know are left alone rather
// than guessed at, because a wrong guess produces a command that fails at
// login with no one watching.
function stripFieldCodes(exec) {
    var known = { "f": 1, "F": 1, "u": 1, "U": 1, "d": 1, "D": 1,
                  "n": 1, "N": 1, "i": 1, "c": 1, "k": 1, "v": 1, "m": 1 };
    var out = "", i = 0;
    while (i < exec.length) {
        if (exec.charAt(i) === "%" && i + 1 < exec.length) {
            var next = exec.charAt(i + 1);
            if (next === "%") { out += "%"; i += 2; continue; }
            if (known[next])  { i += 2; continue; }
        }
        out += exec.charAt(i);
        i += 1;
    }
    return out.replace(/\s+/g, " ").replace(/^ | $/g, "");
}

// The command field is a shell command line by design -- the same trust level
// as a line in ~/.config/hypr/autostart.lua -- and it is handed to bash as one
// single argv element, never pasted into a larger command line.
//
// The redirections are not cosmetic: anything started from a Quickshell
// Process inherits its stdout and stderr pipes, and when the command chain
// ends Quickshell tears those pipes down and takes the application with it.
// From a terminal the same command works, because nobody tears anything down.
function launchCommand(command) {
    return "uwsm-app -- " + command + " </dev/null >/dev/null 2>&1";
}

// Workspace rules only take effect when a workspace is CREATED, so a workspace
// that already exists has to be moved explicitly. One that does not exist yet
// is left alone -- the rule will place it when it appears.
function workspaceMoves(model, workspacesNow) {
    var wanted = (model && model.workspaces) || [];
    var now = workspacesNow || [];
    var current = {}, moves = [], i;
    for (i = 0; i < now.length; i++) current[now[i].workspace] = now[i].monitor;
    for (i = 0; i < wanted.length; i++) {
        var row = wanted[i];
        if (current[row.workspace] === undefined) continue;
        if (current[row.workspace] !== row.monitor) {
            moves.push({ workspace: row.workspace, monitor: row.monitor });
        }
    }
    return moves;
}
```

- [ ] **Step 4: Laufen lassen und Grün sehen**

Run: `./test/run-qml-tests.sh`
Expected: alle `ok`, `failed=0`.

- [ ] **Step 5: Drei Mutationsproben fahren**

```bash
# Probe A -- Abkopplung der Streams weglassen
sed -i 's| </dev/null >/dev/null 2>&1";|";|' Model.js
./test/run-qml-tests.sh; echo "A status=$?"
git checkout Model.js

# Probe B -- %% wie einen Feldcode behandeln
python3 - <<'MUT'
import io
p = "Model.js"; s = io.open(p, encoding="utf-8").read()
old = 'if (next === "%") { out += "%"; i += 2; continue; }'
new = 'if (next === "%") { i += 2; continue; }'
assert old in s
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
MUT
./test/run-qml-tests.sh; echo "B status=$?"
git checkout Model.js

# Probe C -- auch nicht existierende Workspaces umziehen wollen
sed -i 's/^        if (current\[row.workspace\] === undefined) continue;/        \/\/ removed/' Model.js
./test/run-qml-tests.sh; echo "C status=$?"
git checkout Model.js
```
Expected: A → `launchCommand: detaches every standard stream` rot. B → `stripFieldCodes: %% survives as a literal percent` rot. C → `workspaceMoves: a workspace that does not exist yet is not moved` rot.

- [ ] **Step 6: Commit**

```bash
git add Model.js test/harness.qml
git commit -m "feat: derived monitor, field codes, launch command, workspace moves

The launch command detaches all three standard streams: anything started from
a Quickshell Process inherits its pipes and dies when they are torn down.

Note for everything that follows: the class field is never evaluated with
JavaScript RegExp. The allowlist permits nested quantifiers, and QML offers no
timeout for JavaScript, so matching happens in Hyprland and in grep -E."
```

---
### Task 11: Abgleich — Fenster finden und Umzüge erzeugen

**Voraussetzung:** Task 1 Frage 3 und 3b beantwortet. Die dort gefundenen Ausdrücke werden hier wörtlich eingesetzt; bei `FAIL` für 3 entfällt das Verschieben offener Fenster (README: Platzierung gilt erst beim nächsten Öffnen), bei `FAIL` für 3b entfällt das Verschieben bestehender Workspaces.

**Wo gematcht wird und warum dort:** Die Fensterklasse ist ein Regex. Er wird an genau einer Stelle ausgewertet — in `grep -E`, dessen Automat linear läuft. Verschoben wird danach über die **Adresse**, nicht über die Klasse; Lua sieht den Regex also überhaupt nicht. Damit gibt es weder JS-Backtracking im Panel noch eine untypisierte Filter-API im Compositor.

**Files:**
- Modify: `bin/omarchy-autostart-windows`
- Modify: `Model.js`
- Modify: `test/harness.qml`
- Modify: `test/run-tests.sh`

**Interfaces:**
- Consumes: `Model.workspaceMoves`, `Model.luaBytes`, `Model.validate`.
- Produces:
  - `omarchy-autostart-windows --workspaces` → `[{"workspace":"1","monitor":"DP-4"}]`.
  - `omarchy-autostart-windows --match-file <path>` — Datei mit je Zeile `<id>\t<class-regex>` → `[{"id":…,"address":"0x…","class":…,"workspace":…,"monitor":…}]`, ein Eintrag je getroffenem Fenster.
  - `Model.ADDRESS_RE` = `/^0x[0-9a-f]{1,16}$/`.
  - `Model.buildReconcileChunks(model, workspacesNow, matches) -> [string]` — fertige Ausdrücke, je Element **ein** hyprctl-Aufruf. Wirft bei einer Adresse, die `ADDRESS_RE` nicht erfüllt.
  - `Model.verbFor(payload) -> "eval" | "dispatch"` — welches hyprctl-Verb eine Nutzlast braucht. Task 1 hat gemessen, dass die beiden Umzugsarten **verschiedene** Verben verlangen; diese Funktion ist die einzige Stelle, an der das entschieden wird, und Task 15 ruft sie statt selbst am Präfix zu schnüffeln.
  - `Model.missingIds(model, matches) -> [id]` — `enabled`-Programme ohne ein einziges getroffenes Fenster; Grundlage für `[Launch missing]`.
  - Task 13 und 15 rufen alle drei.

- [ ] **Step 1: Die fehlschlagenden Tests schreiben**

In `test/run-tests.sh`:

```bash
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

test_windows_workspaces_mode
test_windows_match_file
test_match_is_bounded_against_a_backtracking_regex
```

In `test/harness.qml`:

```qml
        // --- reconcile -----------------------------------------------------
        check("reconcile: a workspace move becomes a dispatcher expression",
              (function() {
                  var m = Model.validate(cfg([], [{ workspace: "2", monitor: "DP-3" }]));
                  var c = Model.buildReconcileChunks(m, [{ workspace: "2", monitor: "DP-4" }], []);
                  return c.length === 1 && c[0].indexOf("hl.dsp.workspace.move") !== -1;
              })(), true);

        check("reconcile: a matched window is moved by address, not by class",
              (function() {
                  var m = Model.validate(cfg([prog({ id: "p1" })], []));
                  var c = Model.buildReconcileChunks(m, [], [{ id: "p1", address: "0xdead" }]);
                  var joined = c.join("\n");
                  return joined.indexOf("0xdead") === -1     // encoded, not literal
                      && joined.indexOf("cursor") === -1     // the class never travels
                      && joined.indexOf("hl.dsp.window.move") !== -1;
              })(), true);

        check("reconcile: no quotes in any expression",
              (function() {
                  var m = Model.validate(cfg([prog({ id: "p1" })], [{ workspace: "2", monitor: "DP-3" }]));
                  var c = Model.buildReconcileChunks(m, [{ workspace: "2", monitor: "DP-4" }],
                                                     [{ id: "p1", address: "0xbeef" }]);
                  for (var i = 0; i < c.length; i++) if (c[i].indexOf('"') !== -1) return "chunk " + i;
                  return "clean";
              })(), "clean");

        check("reconcile: a program without placement is not moved",
              Model.buildReconcileChunks(Model.validate(cfg([prog({ placement: { kind: "none" } })], [])),
                                         [], [{ id: "p1", address: "0xbeef" }]).length, 0);

        // --- verbFor: the three measured shapes ----------------------------
        //
        // Task 1 measured that the two move kinds need DIFFERENT hyprctl
        // verbs. verbFor is the only place that decides, so it is the only
        // place that has to be right -- and Panel.qml calls it rather than
        // repeating the rule.
        check("verbFor: a rule block goes to eval",
              Model.verbFor(Model.buildRuleChunks(Model.validate(cfg([], []))) [0]), "eval");
        check("verbFor: a window move goes to eval (hl.dispatch wrapper)",
              Model.verbFor(Model.buildReconcileChunks(
                  Model.validate(cfg([prog({ id: "p1" })], [])),
                  [], [{ id: "p1", address: "0xbeef" }])[0]), "eval");
        check("verbFor: a workspace move goes to dispatch (bare dispatcher)",
              Model.verbFor(Model.buildReconcileChunks(
                  Model.validate(cfg([], [{ workspace: "2", monitor: "DP-3" }])),
                  [{ workspace: "2", monitor: "DP-4" }], [])[0]), "dispatch");

        // The window move resolves the address first and moves only if the
        // window still exists. Without this guard a vanished window makes the
        // move land on an unrelated one -- measured, not theorised: during
        // task 1 an unguarded move relocated two of the user's own windows.
        check("reconcile: the window move never passes the address as a selector",
              Model.buildReconcileChunks(Model.validate(cfg([prog({ id: "p1" })], [])),
                                         [], [{ id: "p1", address: "0xbeef" }])[0]
                  .indexOf("hl.get_window(") === -1, true);
        check("reconcile: the window move enumerates and compares on the object",
              /for _, w in ipairs\(hl\.get_windows\(\{\}\)\) do if w\.address == string\.char\(/.test(
                  Model.buildReconcileChunks(Model.validate(cfg([prog({ id: "p1" })], [])),
                                             [], [{ id: "p1", address: "0xbeef" }])[0]), true);
        check("reconcile: the window move never uses the bare dispatch route",
              Model.verbFor(Model.buildReconcileChunks(
                  Model.validate(cfg([prog({ id: "p1" })], [])),
                  [], [{ id: "p1", address: "0xbeef" }])[0]), "eval");

        checkThrows("reconcile: a malformed address is refused",
                    function() {
                        Model.buildReconcileChunks(Model.validate(cfg([prog({ id: "p1" })], [])),
                                                   [], [{ id: "p1", address: "0x1; evil()" }]);
                    }, /refusing address/);

        // --- missingIds ----------------------------------------------------
        check("missingIds: an enabled program with no window is missing",
              Model.missingIds(Model.validate(cfg([prog({ id: "p1" })], [])), []).length, 1);
        check("missingIds: an enabled program with a window is not missing",
              Model.missingIds(Model.validate(cfg([prog({ id: "p1" })], [])),
                               [{ id: "p1", address: "0x1" }]).length, 0);
        check("missingIds: a disabled program is never missing",
              Model.missingIds(Model.validate(cfg([prog({ id: "p1", enabled: false })], [])), []).length, 0);
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run: `./test/run-tests.sh; ./test/run-qml-tests.sh`
Expected: beide rot.

- [ ] **Step 3: Das Fenster-Skript erweitern**

In `bin/omarchy-autostart-windows` den `case`-losen Rumpf durch eine Verzweigung ersetzen und anfügen:

```bash
cmd_workspaces() {
    local workspaces
    workspaces="$("$HYPRCTL" -j workspaces 2>/dev/null)" || workspaces=""
    if [[ -z "$workspaces" ]] || ! jq -e 'type == "array"' <<<"$workspaces" >/dev/null 2>&1; then
        echo "[]"; exit 0
    fi
    jq -c --argjson max "$MAX_WORKSPACES" '
        map(select((.id // 0) > 0))
        | .[0:$max]
        | map({ workspace: ((.id // 0) | tostring), monitor: (.monitor // "") })
    ' <<<"$workspaces"
}

# Match each program's class regex against the open windows.
#
# The regex is evaluated HERE, by grep -E, and nowhere else. grep -E runs an
# automaton: it does not backtrack, so a class such as ^(a+)+$ costs linear
# time instead of hanging the caller. JavaScript RegExp would backtrack, and
# QML gives JavaScript no timeout to be rescued by.
cmd_match_file() {
    local file="$1"
    [[ -f "$file" ]] || { echo "[]"; exit 0; }

    local windows; windows="$(cmd_list_json)"
    local classes; classes="$(jq -r '.[] | .class' <<<"$windows")"

    local lines=0
    {
        while IFS=$'\t' read -r id regex; do
            [[ -n "$id" && -n "$regex" ]] || continue
            lines=$((lines + 1))
            (( lines > MAX_PROGRAMS )) && break
            # Feed the classes in and keep the line numbers, so the match maps
            # back to the window without a second pass over the JSON.
            while IFS= read -r hit; do
                printf '%s\t%s\n' "$id" "$hit"
            done < <(printf '%s\n' "$classes" | grep -n -E -- "$regex" 2>/dev/null | cut -d: -f1)
        done < "$file"
    } | jq -R -s --argjson w "$windows" '
        split("\n") | map(select(length > 0) | split("\t"))
        | map({ id: .[0], window: $w[(.[1] | tonumber) - 1] })
        | map(select(.window != null))
        | map({ id, address: .window.address, class: .window.class,
                workspace: .window.workspace, monitor: .window.monitor })
    '
}
```

Die zwei neuen Konstanten gehören **zu den anderen am Kopf der Datei**, direkt unter `MAX_WINDOWS=500` — nicht zum `case`-Block, wo sie erst nach den Funktionsdefinitionen stünden und beim Lesen wie eine Zufälligkeit wirken:

```bash
MAX_WORKSPACES=99
MAX_PROGRAMS=200
```

Der bisherige Rumpf wird zu `cmd_list_json()` (gibt das Array auf stdout aus, ohne zu beenden), und am Dateiende steht:

```bash
case "${1:-}" in
    "")           cmd_list_json ;;
    --workspaces) cmd_workspaces ;;
    --match-file) shift; [[ -n "${1:-}" ]] || { echo "usage: ${0##*/} --match-file <path>" >&2; exit 2; }
                  cmd_match_file "$1" ;;
    *)            echo "usage: ${0##*/} [--workspaces | --match-file <path>]" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: `Model.js` erweitern**

```javascript
// --- reconcile ------------------------------------------------------------
//
// Windows are moved by ADDRESS, never by class: the class regex is matched
// once, in grep -E, and never travels into Lua. Addresses are checked against
// a shape before they are encoded, because they come out of hyprctl and
// hyprctl's output is not ours.
var ADDRESS_RE = /^0x[0-9a-f]{1,16}$/;

// Both expressions are the forms task 1 measured against a real window.
//
// A window is NEVER addressed by a string here, and the loop below is the
// whole reason this function exists in the shape it does.
//
// Measured on 2026-09-02 with a counting instrument -- 5 runs of 7 trials per
// form, each with a negative control using an address that does not exist,
// aborting on the first collateral event. This form: 35/35 moved the right
// window, negative control clean 5/5.
//
// The mechanism behind three separate incidents, in which the probe moved the
// user's Chatterbox window, two of his terminals and his Signal window:
// hl.get_window("<bare hex>") always returns nil, a window field set to nil
// means the KEY IS ABSENT, and window.move then acts on the ACTIVE window.
// A bare hex address is not a valid selector; "address:<hex>" is.
//
// Two shorter forms measured clean as well -- window = "address:<hex>" as a
// plain string, and hl.get_window("address:<hex>") behind an `if w then`.
// Neither is used here. Their safety rests on Hyprland no-oping an
// unresolvable string, a property of the runtime. This form's safety rests on
// the shape of our own code: on the miss path no dispatcher is called at all.
//
// And the most instructive measurement is of a form NOT used:
// hl.get_window("address:<hex>") WITHOUT the guard scored 7/7 on live
// addresses and moved Signal on its negative control. Nothing but the
// negative control separates it from the safe forms.
function windowMoveExpression(address, placement) {
    var field = (placement.kind === "workspace") ? "workspace" : "monitor";
    return "do for _, w in ipairs(hl.get_windows({})) do "
         + "if w.address == " + luaBytes(address) + " then "
         + "hl.dispatch(hl.dsp.window.move({ "
         + field + " = " + luaBytes(placement.value) + ", window = w, follow = false })) "
         + "end end end";
}

function workspaceMoveExpression(move) {
    return "hl.dsp.workspace.move({ workspace = " + luaBytes(move.workspace)
         + ", monitor = " + luaBytes(move.monitor) + " })";
}

// Which hyprctl verb a payload needs.
//
// Two shapes exist. A block -- a rule block or a guarded window move, both
// starting with `do` -- goes to eval. A bare dispatcher expression goes to
// dispatch.
//
// To be precise about what was measured, since an earlier version of this
// comment overstated it: for the WORKSPACE move both verbs work (7 of 7
// each), so dispatch here is a choice, not a necessity. For the WINDOW move
// the choice is forced: only the eval route is safe (see
// windowMoveExpression). Keeping the decision in one tested function is why
// Panel.qml does not carry it as an inline string comparison.
function verbFor(payload) {
    return String(payload).indexOf("hl.dsp.") === 0 ? "dispatch" : "eval";
}

function buildReconcileChunks(model, workspacesNow, matches) {
    var out = [], i;

    var moves = workspaceMoves(model, workspacesNow);
    for (i = 0; i < moves.length; i++) out.push(workspaceMoveExpression(moves[i]));

    var byId = {};
    var programs = (model && model.programs) || [];
    for (i = 0; i < programs.length; i++) byId[programs[i].id] = programs[i];

    var hits = matches || [];
    for (i = 0; i < hits.length; i++) {
        var program = byId[hits[i].id];
        if (!program) continue;
        var placement = program.placement;
        if (!placement || placement.kind === "none") continue;
        if (!ADDRESS_RE.test(hits[i].address)) {
            throw new Error("buildReconcileChunks: refusing address " + hits[i].address);
        }
        out.push(windowMoveExpression(hits[i].address, placement));
    }
    return out;
}

// Which enabled programs have no window at all. Basis for [Launch missing];
// the reconcile itself never starts anything, because saving should not open
// windows.
function missingIds(model, matches) {
    var seen = {}, out = [], i;
    var hits = matches || [];
    for (i = 0; i < hits.length; i++) seen[hits[i].id] = true;
    var programs = (model && model.programs) || [];
    for (i = 0; i < programs.length; i++) {
        if (programs[i].enabled && !seen[programs[i].id]) out.push(programs[i].id);
    }
    return out;
}
```

- [ ] **Step 5: Laufen lassen und Grün sehen**

Run: `./test/run-tests.sh && ./test/run-qml-tests.sh`
Expected: beide grün.

- [ ] **Step 6: Drei Mutationsproben fahren**

```bash
# Probe A -- Adressform nicht mehr pruefen
sed -i 's|^        if (!ADDRESS_RE.test(hits\[i\].address)) {|        if (false) {|' Model.js
./test/run-qml-tests.sh; echo "A status=$?"
git checkout Model.js

# Probe B -- statt grep -E das Backtracking-Werkzeug nehmen
sed -i 's/grep -n -E -- "$regex"/grep -n -P -- "$regex"/' bin/omarchy-autostart-windows
./test/run-tests.sh; echo "B status=$?"
git checkout bin/omarchy-autostart-windows

# Probe C -- auch Programme ohne Platzierung verschieben
sed -i 's|^        if (!placement \|\| placement.kind === "none") continue;|        if (false) continue;|' Model.js
./test/run-qml-tests.sh; echo "C status=$?"
git checkout Model.js

# Probe D -- die Auflösungswache entfernen. Die wichtigste Probe dieser Aufgabe.
python3 - <<'MUT'
import io
p = "Model.js"; s = io.open(p, encoding="utf-8").read()
old = '"do local w = hl.get_window(" + luaBytes(address) + ") "\n         + "if w then hl.dispatch(hl.dsp.window.move({ "'
new = '"hl.dispatch(hl.dsp.window.move({ "'
assert old in s, "Mutationsziel nicht gefunden -- Model.js hat sich geaendert"
s = s.replace(old, new, 1)
s = s.replace(' + field + " = " + luaBytes(placement.value) + ", window = w, follow = false })) end end";',
              ' + field + " = " + luaBytes(placement.value) + ", window = hl.get_window(" + luaBytes(address) + "), follow = false }))";', 1)
io.open(p, "w", encoding="utf-8").write(s)
MUT
./test/run-qml-tests.sh; echo "D status=$?"
git checkout Model.js
```
Expected: A → `reconcile: a malformed address is refused` rot. B → `match: it returned in under 5 seconds` rot (PCRE backtrackt; falls die installierte `grep`-Fassung kein `-P` kennt, statt dessen den Match in ein kleines Node- oder QML-Schnipsel mit `RegExp` verlegen und dieses messen). C → `reconcile: a program without placement is not moved` rot. D → beide Wachen-Tests rot **und** `verbFor: a window move goes to eval` rot, weil die ungeschützte Form nicht mehr mit `do` beginnt.

- [ ] **Step 7: Commit**

```bash
git add bin/omarchy-autostart-windows Model.js test/harness.qml test/run-tests.sh
git commit -m "feat: reconcile open workspaces and windows

The class regex is evaluated in exactly one place -- grep -E, an automaton
that does not backtrack. Windows are then moved by address, so the regex
never reaches Lua and a pattern like ^(a+)+\$ costs linear time instead of
hanging the panel."
```

---
### Task 12: `Runners.qml` und `Model.shellQuote`

**Vorlage:** `~/.config/omarchy/plugins/smartalb.vpn/Panel.qml` (v1.3.1), Zeilen 35–62. Die dortige `Process`-/`StdioCollector`-API ist belegt funktionierend; sie wird hier übernommen, nicht neu erfunden.

**Was hier nicht geht und warum das gesagt sein muss:** `Runners.qml` benutzt `Quickshell.Io`, das außerhalb der Quickshell-Laufzeit nicht existiert. Es lässt sich **nicht** headless ausführen. Geprüft werden deshalb Struktureigenschaften der Datei — genau die fünf, die bei `smartalb.vpn` v1.3.1 den vierten Reviewer-Befund geschlossen haben — plus `Model.shellQuote`, das als reines JavaScript sehr wohl läuft.

**Files:**
- Create: `Runners.qml`
- Modify: `Model.js`
- Modify: `test/harness.qml`
- Create: `test/qml-structure.sh`
- Modify: `test/run-tests.sh`

**Interfaces:**
- Consumes: nichts.
- Produces:
  - `Model.shellQuote(s) -> string` — einfach-quotiert für `bash -c`.
  - `Runners.qml` mit `runner(cmd)`, `runnerOut(cmd)`, `runnerErr(cmd)`, `hypr(verb, payload)`, `tool(name, args)` und den Eigenschaften `binTimeout`, `binBash`, `binHyprctl`, `binDir`, `shellSeconds`, `hyprSeconds`, `maxOutBytes`.
  - `test/qml-structure.sh` als Strukturprüfer für **alle** QML-Dateien; Task 13–16 fügen dort nichts hinzu, sie müssen ihn nur bestehen.

- [ ] **Step 1: `Model.shellQuote`-Tests schreiben**

In `test/harness.qml`:

```qml
        // --- shellQuote ----------------------------------------------------
        check("shellQuote: plain path",      Model.shellQuote("/a/b"), "'/a/b'");
        check("shellQuote: a space",         Model.shellQuote("a b"), "'a b'");
        check("shellQuote: a single quote",  Model.shellQuote("a'b"), "'a'\\''b'");
        check("shellQuote: a semicolon is inert inside quotes",
              Model.shellQuote("a; rm -rf /"), "'a; rm -rf /'");
        check("shellQuote: a dollar sign is inert inside quotes",
              Model.shellQuote("$HOME"), "'$HOME'");
```

- [ ] **Step 2: Den Strukturprüfer schreiben**

`test/qml-structure.sh`:

```bash
#!/usr/bin/env bash
# Structural checks on the QML files.
#
# Runners.qml and its callers import Quickshell.Io, which does not exist
# outside the Quickshell runtime, so they cannot be executed headless. What
# CAN be held is the shape: absolute interpreters, every command through a
# helper, a producer limit on both collecting helpers, and a teardown that
# covers every declared Process. These are the five properties that closed the
# fourth review finding on smartalb.vpn v1.3.1.
set -uo pipefail
cd "$(dirname "$0")/.."

run=0; failed=0
ok()   { run=$((run+1)); printf 'ok   %s\n' "$1"; }
bad()  { run=$((run+1)); failed=$((failed+1)); printf 'FAIL %s\n       %s\n' "$1" "$2"; }

qml_files() { ls -1 ./*.qml 2>/dev/null; }

# 1 -- no PATH-resolved interpreter anywhere.
hits="$(grep -nE '"(bash|sh|timeout|hyprctl|head|jq)"' ./*.qml 2>/dev/null || true)"
[[ -z "$hits" ]] && ok "no PATH-resolved interpreter in any qml file" \
                 || bad "no PATH-resolved interpreter in any qml file" "$hits"

# 2 -- the three absolute binaries are the only ones named.
for expected in /usr/bin/timeout /usr/bin/bash /usr/bin/hyprctl; do
  grep -q "\"$expected\"" Runners.qml \
    && ok "Runners.qml names $expected absolutely" \
    || bad "Runners.qml names $expected absolutely" "not found"
done

# 3 -- both collecting helpers carry a producer limit.
grep -A2 'function runnerOut' Runners.qml | grep -q 'head -c' \
  && ok "runnerOut carries a producer byte limit" \
  || bad "runnerOut carries a producer byte limit" "no head -c near runnerOut"
grep -A2 'function runnerErr' Runners.qml | grep -q 'head -c' \
  && ok "runnerErr carries a producer byte limit" \
  || bad "runnerErr carries a producer byte limit" "no head -c near runnerErr"

# 4 -- runnerErr uses process substitution, not a pipe: a pipe would replace
#      the exit status of the command, which callers read.
grep -A2 'function runnerErr' Runners.qml | grep -q '2> >(' \
  && ok "runnerErr keeps the command exit status (process substitution)" \
  || bad "runnerErr keeps the command exit status (process substitution)" "no '2> >(' found"

# 5 -- every Process command: goes through a helper, never a bare array.
hits="$(grep -nE '^\s*command:\s*\[' ./*.qml 2>/dev/null || true)"
[[ -z "$hits" ]] && ok "every Process command goes through a helper" \
                 || bad "every Process command goes through a helper" "$hits"

# 6 -- teardown covers every declared Process. A wall-clock deadline would end
#      them eventually, but "eventually" is up to two minutes of work nobody
#      is waiting for.
for file in $(qml_files); do
  ids="$(awk '/^[[:space:]]*Process[[:space:]]*\{/ {inproc=1}
              inproc && /id:[[:space:]]*[A-Za-z_]/ {
                  match($0, /id:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)
                  s = substr($0, RSTART, RLENGTH); sub(/id:[[:space:]]*/, "", s)
                  print s; inproc=0 }' "$file")"
  [[ -z "$ids" ]] && continue
  teardown="$(awk '/Component.onDestruction/,/^[[:space:]]*\}/' "$file")"
  for id in $ids; do
    grep -q "\b$id\b" <<<"$teardown" \
      && ok "$file: teardown stops $id" \
      || bad "$file: teardown stops $id" "not mentioned in Component.onDestruction"
  done
done

# 7a -- Lua rule construction lives in Model.js only. A qml file must not
#       build rules at all; it only passes strings through. (hl.dsp. may
#       appear there -- the panel sniffs it to choose the hyprctl verb.)
hits="$(grep -nE 'hl\.(window_rule|workspace_rule)' ./*.qml 2>/dev/null || true)"
[[ -z "$hits" ]] && ok "no rule construction in any qml file" \
                 || bad "no rule construction in any qml file" "$hits"

# 7b -- and in Model.js every line that builds a rule encodes its values.
#       A quoted value there would be code inside the compositor.
# Only lines that CONSTRUCT something -- an hl call immediately followed by a
# table literal. verbFor() mentions the string "hl.dsp." for a comparison and
# is not a construction, so it must not be caught here.
hits="$(grep -nE 'hl\.(window_rule|workspace_rule|dsp\.[a-z_.]+)\(\{' Model.js \
        | grep -v 'luaBytes(' || true)"
[[ -z "$hits" ]] && ok "every rule-building line in Model.js uses luaBytes" \
                 || bad "every rule-building line in Model.js uses luaBytes" "$hits"

printf '\nqml structure: total=%d failed=%d\n' "$run" "$failed"
(( failed == 0 ))
```

In `test/run-tests.sh`:

```bash
test_qml_structure() {
    local out status
    out="$(./qml-structure.sh 2>&1)"; status=$?
    assert_eq "qml: structural checks pass" "$status" "0"
    assert_contains "qml: the checks actually ran" "$out" "qml structure: total="
}

test_qml_structure
```

- [ ] **Step 3: Laufen lassen und den Fehlschlag sehen**

Run: `chmod +x test/qml-structure.sh && ./test/run-tests.sh; echo "status=$?"`
Expected: rot — `Runners.qml` fehlt.

- [ ] **Step 4: Die Implementierung schreiben**

An `Model.js` anfügen:

```javascript
// Single-quote for bash -c. Inside single quotes a shell metacharacter is
// inert; the only thing to handle is the quote itself.
function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'";
}
```

`Runners.qml`:

```qml
import QtQuick
import Quickshell.Io
import "Model.js" as Model

// The call helpers. Every command in this plugin goes through one of them,
// because a limit that has to be remembered at each call site is one that gets
// forgotten at one of them.
Item {
    id: root

    // Absolute paths. A PATH-resolved interpreter is a different program on a
    // different machine, and tidying PATH protects nothing here: Omarchy lives
    // in /usr/bin too.
    readonly property string binTimeout: "/usr/bin/timeout"
    readonly property string binBash: "/usr/bin/bash"
    readonly property string binHyprctl: "/usr/bin/hyprctl"

    readonly property int shellSeconds: 120
    readonly property int hyprSeconds: 20

    // Anything past this is not an answer, it is a flood.
    readonly property int maxOutBytes: 262144

    readonly property string binDir:
        Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "") + "bin/"

    // With a shell -- for the autostart, whose command field is a shell
    // command line by design, and for our own bin/ scripts, whose stdout is
    // collected and therefore needs a producer limit.
    function runner(cmd) {
        return [root.binTimeout, "-k", "5", String(root.shellSeconds),
                root.binBash, "-c", cmd]
    }

    // The limit belongs on the producing side, so the bytes are never held in
    // the first place.
    function runnerOut(cmd) {
        return root.runner("{ " + cmd + " ; } | head -c " + root.maxOutBytes)
    }

    // Process substitution rather than a pipe: a pipe would replace the exit
    // status of the command itself, and callers read it.
    function runnerErr(cmd) {
        return root.runner("{ " + cmd + " ; } 2> >(head -c " + root.maxOutBytes + " >&2)")
    }

    // Without a shell. Both hyprctl verbs take a Lua string; handing it over as
    // one argv element means there is no second quoting question to get wrong.
    function hypr(verb, payload) {
        return [root.binTimeout, "-k", "5", String(root.hyprSeconds),
                root.binHyprctl, verb, payload]
    }

    // One of our own bin/ scripts. Its output is already bounded by the
    // script's own caps; runnerOut is the second belt.
    function tool(name, args) {
        return root.runnerOut(Model.shellQuote(root.binDir + name)
                              + (args ? " " + args : ""))
    }
}
```

- [ ] **Step 5: Laufen lassen und Grün sehen**

Run: `./test/run-qml-tests.sh && ./test/run-tests.sh`
Expected: beide grün; der Strukturprüfer nennt mindestens neun Prüfungen.

- [ ] **Step 6: Drei Mutationsproben fahren**

```bash
# Probe A -- PATH-aufgeloester Interpreter
sed -i 's|"/usr/bin/bash"|"bash"|' Runners.qml
./test/run-tests.sh; echo "A status=$?"
git checkout Runners.qml

# Probe B -- Erzeuger-Grenze aus runnerOut nehmen
python3 - <<'MUT'
import io
p = "Runners.qml"; s = io.open(p, encoding="utf-8").read()
old = 'return root.runner("{ " + cmd + " ; } | head -c " + root.maxOutBytes)'
new = 'return root.runner(cmd)'
assert old in s
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
MUT
./test/run-tests.sh; echo "B status=$?"
git checkout Runners.qml

# Probe C -- Prozess-Substitution durch eine Pipe ersetzen
python3 - <<'MUT'
import io
p = "Runners.qml"; s = io.open(p, encoding="utf-8").read()
old = '"{ " + cmd + " ; } 2> >(head -c " + root.maxOutBytes + " >&2)"'
new = '"{ " + cmd + " ; } 2>&1 | head -c " + root.maxOutBytes'
assert old in s
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
MUT
./test/run-tests.sh; echo "C status=$?"
git checkout Runners.qml
```
Expected: A → Prüfung 1 und 2 rot. B → `runnerOut carries a producer byte limit` rot. C → `runnerErr keeps the command exit status` rot.

- [ ] **Step 7: Commit**

```bash
git add Runners.qml Model.js test/harness.qml test/qml-structure.sh test/run-tests.sh
git commit -m "feat: the four call helpers, held by structural tests

Quickshell.Io does not exist outside the Quickshell runtime, so these files
cannot run headless. What is held instead is their shape: absolute
interpreters, every command through a helper, a producer limit on both
collecting helpers, process substitution so the exit status survives, and a
teardown that covers every declared Process."
```

---

### Task 13: `Service.qml` — Sitzungsstart, Startmarke, Reload-Abo

**Voraussetzung:** Task 1 Frage 1 beantwortet (bestimmt, ob der Rücksetz-Block aus Task 9 trägt).

**Files:**
- Create: `Service.qml`
- Modify: `test/run-tests.sh`

**Interfaces:**
- Consumes: `Runners.qml`, `Model.validate`, `Model.buildRuleChunks`, `Model.launchCommand`, `bin/omarchy-autostart-config read`.
- Produces: nichts, was andere Aufgaben aufrufen. Die Startmarke liegt unter `$XDG_RUNTIME_DIR/smartalb.autostart/<HYPRLAND_INSTANCE_SIGNATURE>`.

- [ ] **Step 1: Die Tests schreiben, die ohne Quickshell tragen**

Die Startmarken-Logik ist die einzige, bei der ein Fehler die Sitzung verdoppelt — deshalb wandert sie in ein prüfbares Skript statt in QML. In `test/run-tests.sh`:

```bash
MARKER_BIN="$PWD/../bin/omarchy-autostart-marker"

test_marker_claims_once_per_hyprland_instance() {
    setup_sandbox
    export HYPRLAND_INSTANCE_SIGNATURE="sig-a"
    assert_status "marker: the first claim succeeds"   0 "$MARKER_BIN" claim
    assert_status "marker: the second claim is refused" 1 "$MARKER_BIN" claim
    export HYPRLAND_INSTANCE_SIGNATURE="sig-b"
    assert_status "marker: a new instance claims again" 0 "$MARKER_BIN" claim
    teardown_sandbox
}

test_marker_refuses_when_it_cannot_write() {
    setup_sandbox
    export HYPRLAND_INSTANCE_SIGNATURE="sig-a"
    chmod 500 "$XDG_RUNTIME_DIR"
    # Refusing means the autostart is SKIPPED. A doubled session is worse than
    # one that did not start: without a marker a shell restart launches
    # everything a second time.
    assert_status "marker: an unwritable runtime dir refuses the claim" 1 "$MARKER_BIN" claim
    chmod 700 "$XDG_RUNTIME_DIR"
    teardown_sandbox
}

test_marker_refuses_without_a_signature() {
    setup_sandbox
    unset HYPRLAND_INSTANCE_SIGNATURE
    assert_status "marker: no instance signature, no claim" 1 "$MARKER_BIN" claim
    teardown_sandbox
}

test_marker_release_allows_a_new_claim() {
    setup_sandbox
    export HYPRLAND_INSTANCE_SIGNATURE="sig-a"
    "$MARKER_BIN" claim >/dev/null
    assert_status "marker: release succeeds" 0 "$MARKER_BIN" release
    assert_status "marker: after release a claim works again" 0 "$MARKER_BIN" claim
    teardown_sandbox
}

test_marker_claims_once_per_hyprland_instance
test_marker_refuses_when_it_cannot_write
test_marker_refuses_without_a_signature
test_marker_release_allows_a_new_claim
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run: `./test/run-tests.sh; echo "status=$?"`
Expected: die vier neuen Tests rot.

- [ ] **Step 3: `bin/omarchy-autostart-marker` schreiben**

```bash
#!/usr/bin/env bash
# The start marker: it decides whether the autostart programs are launched.
#
# Without it, `omarchy-restart-shell` -- which is needed after every QML change
# and is therefore run constantly -- would launch the whole session a second
# time. The marker is bound to HYPRLAND_INSTANCE_SIGNATURE so that a genuinely
# new session does not find an old one, and it lives under XDG_RUNTIME_DIR,
# which is wiped per boot.
#
# It fails closed: no signature, or a directory it cannot write, means no
# claim -- and no claim means the autostart is SKIPPED. A doubled session is
# worse than one that did not start.
set -uo pipefail

sig="${HYPRLAND_INSTANCE_SIGNATURE:-}"
[[ -n "$sig" ]] || { echo "no HYPRLAND_INSTANCE_SIGNATURE" >&2; exit 1; }

# The signature comes from the compositor, but it ends up in a path, so it is
# checked rather than trusted.
[[ "$sig" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || { echo "implausible signature" >&2; exit 1; }

dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/smartalb.autostart"
marker="$dir/$sig"

case "${1:-}" in
    claim)
        mkdir -p "$dir" 2>/dev/null || { echo "cannot create $dir" >&2; exit 1; }
        # O_EXCL through noclobber: the check and the create are one step, so
        # two shells starting at once cannot both win.
        if (set -o noclobber; : > "$marker") 2>/dev/null; then
            exit 0
        fi
        exit 1
        ;;
    release)
        rm -f "$marker" 2>/dev/null
        exit 0
        ;;
    *)
        echo "usage: ${0##*/} claim | release" >&2
        exit 2
        ;;
esac
```

- [ ] **Step 4: Laufen lassen und Grün sehen**

Run: `chmod +x bin/omarchy-autostart-marker && ./test/run-tests.sh`
Expected: alle grün.

- [ ] **Step 5: `Service.qml` schreiben**

```qml
import QtQuick
import Quickshell.Io
import Quickshell.Hyprland
import "Model.js" as Model

// Applies the configuration at session start and puts it back after a config
// reload. Touches no file of the user's Hyprland configuration: under the Lua
// configuration `hyprctl keyword` is off, and a require line in hyprland.lua
// would not survive the next Omarchy upgrade.
Item {
    id: root

    Runners { id: run }

    property var model: ({ programs: [], workspaces: [] })
    property var rejected: []
    property string lastError: ""

    // Rules only; never the programs. A reload does not restart a session.
    property bool rulesOnly: false

    property var pendingChunks: []
    property int pendingIndex: 0

    Component.onDestruction: {
        readProc.running = false
        evalProc.running = false
        launchProc.running = false
        markerProc.running = false
    }

    Component.onCompleted: root.load(false)

    function load(onlyRules) {
        root.rulesOnly = onlyRules
        root.lastError = ""
        readProc.command = run.tool("omarchy-autostart-config", "read")
        readProc.running = true
    }

    Process {
        id: readProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var envelope
                try { envelope = JSON.parse(String(text || "{}")) }
                catch (e) { root.lastError = "unreadable answer from the config reader"; return }

                // Fail closed. A broken structure does not say what the user
                // wants -- no rule is better than half of one.
                if (!envelope.ok) {
                    root.lastError = String(envelope.error || "unknown") + ": "
                                   + String(envelope.detail || "")
                    return
                }
                var checked = Model.validate(envelope.config)
                root.model = checked
                root.rejected = checked.rejected
                root.applyRules(checked)
            }
        }
    }

    function applyRules(checked) {
        try { root.pendingChunks = Model.buildRuleChunks(checked) }
        catch (e) { root.lastError = String(e.message); return }
        root.pendingIndex = 0
        root.nextChunk()
    }

    function nextChunk() {
        if (root.pendingIndex >= root.pendingChunks.length) {
            if (!root.rulesOnly) root.claimAndLaunch()
            return
        }
        evalProc.command = run.hypr("eval", root.pendingChunks[root.pendingIndex])
        root.pendingIndex += 1
        evalProc.running = true
    }

    Process {
        id: evalProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // hyprctl answers "ok" for a chunk that ran. Anything else
                // stops the run: half-applied rules are worse than none.
                if (String(text || "").trim() !== "ok") {
                    root.lastError = "hyprctl eval refused a rule block"
                    root.pendingIndex = root.pendingChunks.length
                }
            }
        }
        onExited: function(exitCode, exitStatus) {
            if (exitCode !== 0 && root.lastError === "") {
                root.lastError = "hyprctl eval exited " + exitCode
                root.pendingIndex = root.pendingChunks.length
            }
            root.nextChunk()
        }
    }

    function claimAndLaunch() {
        markerProc.command = run.tool("omarchy-autostart-marker", "claim")
        markerProc.running = true
    }

    Process {
        id: markerProc
        onExited: function(exitCode, exitStatus) {
            // Only a successful claim launches anything. Every other outcome
            // skips the autostart on purpose.
            if (exitCode === 0) root.launchAll()
        }
    }

    function launchAll() {
        var programs = root.model.programs || []
        var commands = []
        for (var i = 0; i < programs.length; i++) {
            if (programs[i].enabled) commands.push(Model.launchCommand(programs[i].command))
        }
        if (commands.length === 0) return
        // One shell for the whole list: the count is capped at 200 by
        // validate(), and 200 processes to start 200 programs is waste.
        launchProc.command = run.runner(commands.join(" & ") + " & wait")
        launchProc.running = true
    }

    Process {
        id: launchProc
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var message = String(text || "").trim()
                if (message !== "") root.lastError = message.split("\n").pop()
            }
        }
    }

    // A manual `hyprctl reload` throws runtime rules away -- nothing in
    // Omarchy calls it, but a user can. This puts them back, and only them.
    Connections {
        target: Hyprland
        ignoreUnknownSignals: true
        function onRawEvent(event) {
            if (String(event.name) === "configreloaded") root.load(true)
        }
    }
}
```

**Hinweis für den Umsetzer:** `Connections { target: Hyprland }` verlangt `import Quickshell.Hyprland`. Ob das Ereignis `configreloaded` über `onRawEvent` ankommt, ist an der laufenden Shell zu prüfen: `omarchy-restart-shell`, dann 8 s warten, dann `hyprctl reload` und im Journal nach `lastError` bzw. einer eigenen `console.warn`-Zeile sehen. Kommt es nicht an, ist der Rückfallweg ein `Timer` mit 60 s, der `load(true)` aufruft — und das gehört dann ins README, nicht in einen stillen Verzicht.

- [ ] **Step 6: Strukturprüfer und Suiten laufen lassen**

Run: `./test/run-tests.sh && ./test/run-qml-tests.sh`
Expected: grün, inklusive `Service.qml: teardown stops readProc` und der drei weiteren Teardown-Prüfungen.

- [ ] **Step 7: Eine Mutationsprobe fahren**

```bash
python3 - <<'MUT'
import io
p = "Service.qml"; s = io.open(p, encoding="utf-8").read()
old = """    Component.onDestruction: {
        readProc.running = false
        evalProc.running = false
        launchProc.running = false
        markerProc.running = false
    }"""
new = """    Component.onDestruction: {
        readProc.running = false
    }"""
assert old in s
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
MUT
./test/run-tests.sh; echo "status=$?"
git checkout Service.qml
```
Expected: drei `teardown stops …`-Prüfungen rot.

- [ ] **Step 8: Commit**

```bash
git add Service.qml bin/omarchy-autostart-marker test/run-tests.sh
git commit -m "feat: apply at session start, once per Hyprland instance

The start marker is bound to HYPRLAND_INSTANCE_SIGNATURE and claimed with
noclobber, so omarchy-restart-shell -- needed after every QML change -- does
not launch the session a second time. It fails closed: no marker means the
autostart is skipped, because a doubled session is worse than one that did
not start."
```

---
### Task 14: `BarWidget.qml`

**Die Falle, die diese Aufgabe im Wesentlichen umgeht:** Nerd-Font-Glyphen liegen im privaten Unicode-Bereich (U+E000–U+F8FF). Als **literales Zeichen** in einen Plan, eine Spezifikation oder eine Aufgabenbeschreibung geschrieben, überleben sie den Weg durch Dokumente und Werkzeuge nicht — im Ziel steht dann eine leere Zeichenkette. Und ein leerer Text ist bei `BarIconButton` nicht „Knopf ohne Symbol", sondern **kein Knopf**: `WidgetButton` setzt `hasVisualContent: text !== "" || iconComponent !== null` und `visible: hasVisualContent || keepSpace`. Das Widget lädt dann vollständig, taucht in `qs -p /usr/share/omarchy/shell ipc show` als Ziel auf, `qmllint` ist zufrieden, das Journal schweigt — und ist trotzdem unsichtbar. Genau das hat am 31.08.2026 `alb.vpn` getroffen.

Deshalb: **immer als `\u`-Escape schreiben, und danach an der erzeugten Datei nachprüfen, nicht am Quelltext.**

**Files:**
- Create: `BarWidget.qml`
- Modify: `test/qml-structure.sh`

**Interfaces:**
- Consumes: `Panel.qml` (Task 15).
- Produces: die von der Plattform verlangten Funktionen `open()`, `close()`, `toggle()`, `closeForPopoutSwitch()` und die Eigenschaften `readonly property bool opened`, `readonly property bool popoutSwitchClosing`.

- [ ] **Step 1: Die fehlschlagenden Prüfungen schreiben**

In `test/qml-structure.sh` vor der Zusammenfassung anfügen:

```bash
# 8 -- the plugin lifecycle contract from the develop guide.
for needed in "function open()" "function close()" "function toggle()" \
              "function closeForPopoutSwitch()" \
              "readonly property bool opened" \
              "readonly property bool popoutSwitchClosing"; do
  grep -qF "$needed" BarWidget.qml \
    && ok "BarWidget declares $needed" \
    || bad "BarWidget declares $needed" "not found"
done

# 9 -- the bar glyph is present as an escape and not as a literal PUA
#      character. Checked on the FILE, because a literal glyph does not
#      survive the trip through documents and tools, and an empty text is not
#      a button without an icon -- it is no button at all.
if grep -qE 'barGlyph:[[:space:]]*"\\u[0-9a-fA-F]{4}"' BarWidget.qml; then
  ok "BarWidget: bar glyph is written as a \\u escape"
else
  bad "BarWidget: bar glyph is written as a \\u escape" \
      "$(grep -n 'barGlyph' BarWidget.qml || echo 'no barGlyph at all')"
fi
# python3 rather than grep -P: with LC_ALL=C, PCRE rejects \x{} values above
# 0xFF outright, so the check would end in an error instead of a result.
if python3 - BarWidget.qml <<'PUA'
import io, sys
text = io.open(sys.argv[1], encoding="utf-8", errors="replace").read()
sys.exit(1 if any(0xE000 <= ord(c) <= 0xF8FF for c in text) else 0)
PUA
then
  ok "BarWidget: no literal private-use character in the file"
else
  bad "BarWidget: no literal private-use character in the file" \
      "found a raw PUA codepoint -- write it as \\uXXXX"
fi
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run: `./test/run-tests.sh; echo "status=$?"`
Expected: die acht neuen Prüfungen rot, `BarWidget.qml` fehlt.

- [ ] **Step 3: Die Implementierung schreiben**

```qml
import QtQuick
import qs.Commons
import qs.Ui

// Bar entry. Glyph only, no label.
//
// The glyph MUST stay a \u escape. A literal Nerd Font character sits in the
// private use area and does not survive being copied through documents and
// tools; what arrives is an empty string. And an empty text is not a button
// without an icon, it is no button: WidgetButton sets
// hasVisualContent: text !== "" || iconComponent !== null, and
// visible: hasVisualContent || keepSpace. The widget then loads completely,
// shows up as an ipc target, passes qmllint, and is invisible.
//
// Verify on the file, never on the source you just typed:
//   grep -n "barGlyph:" BarWidget.qml | od -c
BarIconButton {
    id: root

    readonly property string barGlyph: "\uf135"   // nf-fa-rocket

    text: root.barGlyph
    tooltipText: root.tooltip

    readonly property bool opened: panelLoader.item ? panelLoader.item.opened : false
    readonly property bool popoutSwitchClosing:
        panelLoader.item ? panelLoader.item.popoutSwitchClosing : false

    property int programCount: 0
    property int placementCount: 0

    readonly property string tooltip:
        "Autostart Layout \u2014 " + root.programCount + " programs, "
        + root.placementCount + " placements"

    function open()  { panelLoader.active = true; if (panelLoader.item) panelLoader.item.open() }
    function close() { if (panelLoader.item) panelLoader.item.close() }
    function toggle() { root.opened ? root.close() : root.open() }
    function closeForPopoutSwitch() {
        if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
    }

    onClicked: root.toggle()

    Loader {
        id: panelLoader
        active: false
        source: "Panel.qml"
        onLoaded: {
            item.counted.connect(function(programs, placements) {
                root.programCount = programs
                root.placementCount = placements
            })
        }
    }
}
```

- [ ] **Step 4: Laufen lassen und Grün sehen**

Run: `./test/run-tests.sh`
Expected: alle Prüfungen `ok`.

- [ ] **Step 5: Am Byte nachprüfen, nicht am Quelltext**

Run:
```bash
grep -n "barGlyph:" BarWidget.qml | od -c | head -3
```
Expected: die Ausgabe zeigt `\ u f 1 3 5` als **sechs einzelne Zeichen**. Steht dort ein Mehrbyte-UTF-8-Zeichen oder gar nichts zwischen den Anführungszeichen, ist der Escape beim Schreiben verloren gegangen.

- [ ] **Step 6: Zwei Mutationsproben fahren**

```bash
# Probe A -- Glyph leeren
sed -i 's/"\\uf135"/""/' BarWidget.qml
./test/run-tests.sh; echo "A status=$?"
git checkout BarWidget.qml

# Probe B -- eine Vertragsfunktion entfernen
sed -i '/function closeForPopoutSwitch()/,+2d' BarWidget.qml
./test/run-tests.sh; echo "B status=$?"
git checkout BarWidget.qml
```
Expected: A → `BarWidget: bar glyph is written as a \u escape` rot. B → `BarWidget declares function closeForPopoutSwitch()` rot.

- [ ] **Step 7: Sichtbarkeit in der laufenden Shell prüfen**

Die Struktur beweist nicht, dass der Knopf zu sehen ist. Deshalb einmal von Hand:

```bash
omarchy-restart-shell
sleep 8
qs -p /usr/share/omarchy/shell ipc show | grep -i autostart
```
Expected: das Widget ist als Ziel gelistet **und** in der Bar zu sehen. Ist es gelistet, aber unsichtbar, liegt es nicht am Laden, sondern an leerem Inhalt oder fehlender Größe.

- [ ] **Step 8: Commit**

```bash
git add BarWidget.qml test/qml-structure.sh
git commit -m "feat: bar entry with the platform lifecycle contract

The glyph stays a \\u escape and a test checks the file for it: a literal
private-use character does not survive the trip through documents, and an
empty text is not an icon-less button -- WidgetButton hides it entirely,
while the widget still loads, still lists as an ipc target and still passes
qmllint."
```

---
### Task 15: `Panel.qml` — Zustand, Listen, Anwenden

**Bausteine:** Für Knöpfe, Eingabefelder, Listen und Abstände die Typen benutzen, die `~/.config/omarchy/plugins/smartalb.vpn/Panel.qml` verwendet (`qs.Ui`, `qs.Commons`, `QtQuick.Controls`). **Achtung auf Namenskollisionen:** bei gleichem Typnamen gewinnt der **zuletzt** gelesene Import — in `smartalb.vpn/Panel.qml` steht dazu ein Kommentar bei Zeile 876, weil `Button` sowohl aus `QtQuick.Controls` als auch aus `qs.Ui` kommt.

**Files:**
- Create: `Panel.qml`
- Modify: `test/qml-structure.sh`

**Interfaces:**
- Consumes: `Runners.qml`, `Model.js`, `bin/omarchy-autostart-config`, `bin/omarchy-autostart-windows`.
- Produces: `signal counted(int programs, int placements)` (Task 14 hängt daran); die Plattformfunktionen `open()`, `close()`, `toggle()`, `closeForPopoutSwitch()`; `readonly property bool opened`, `readonly property bool popoutSwitchClosing`. Task 16 hängt seine drei Abläufe an `root.draft` und `root.markDirty()`.

- [ ] **Step 1: Die fehlschlagenden Strukturprüfungen schreiben**

In `test/qml-structure.sh` anfügen:

```bash
# 10 -- the panel declares the same lifecycle contract as the bar widget.
for needed in "function open()" "function close()" "function toggle()" \
              "function closeForPopoutSwitch()" \
              "readonly property bool opened" \
              "readonly property bool popoutSwitchClosing" \
              "signal counted("; do
  grep -qF "$needed" Panel.qml \
    && ok "Panel declares $needed" \
    || bad "Panel declares $needed" "not found"
done

# 11 -- applying is explicit. Moving real windows across real screens must not
#       be a side effect of a keystroke, so no field may write straight
#       through to disk.
hits="$(grep -nE 'onTextChanged:.*(writeProc|applyRules|config-write)' Panel.qml || true)"
[[ -z "$hits" ]] && ok "Panel: no field writes through on change" \
                 || bad "Panel: no field writes through on change" "$hits"

# 12 -- the class field is never handed to a JavaScript RegExp. The allowlist
#       permits nested quantifiers and QML gives JavaScript no timeout.
hits="$(grep -nE 'new RegExp|\.match\(|\.test\(' Panel.qml \
        | grep -vE 'WORKSPACE_RE|MONITOR_RE|ADDRESS_RE|ID_RE' || true)"
[[ -z "$hits" ]] && ok "Panel: no JavaScript RegExp over user patterns" \
                 || bad "Panel: no JavaScript RegExp over user patterns" "$hits"
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run: `./test/run-tests.sh; echo "status=$?"`
Expected: die zehn neuen Prüfungen rot.

- [ ] **Step 3: Die Implementierung schreiben**

```qml
import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The configuration surface. One level, three areas; detail editing expands at
// the row so the connection to the workspace table below stays visible.
Item {
    id: root

    Runners { id: run }

    signal counted(int programs, int placements)

    readonly property bool opened: root.visible
    property bool popoutSwitchClosing: false

    function open()  { root.visible = true; root.reload() }
    function close() { root.visible = false }
    function toggle() { root.opened ? root.close() : root.open() }
    function closeForPopoutSwitch() { root.popoutSwitchClosing = true; root.close() }

    Component.onDestruction: {
        readProc.running = false
        writeProc.running = false
        evalProc.running = false
        windowsProc.running = false
        workspacesProc.running = false
        matchProc.running = false
        launchProc.running = false
        appsProc.running = false
    }

    // --- state ------------------------------------------------------------
    // `saved` is what is on disk, `draft` is what the panel shows. Apply moves
    // draft to disk; Revert throws draft away. Keeping them apart is what
    // makes "n changes pending" honest.
    property var saved: ({ schemaVersion: 1, programs: [], workspaces: [] })
    property var draft: ({ schemaVersion: 1, programs: [], workspaces: [] })
    property int savedMtime: 0
    property var rejected: []
    property var blocked: []
    property string errorText: ""
    property var openWindows: []
    property var workspacesNow: []
    property var missing: []
    property int dirtyCount: 0

    function markDirty() {
        var a = JSON.stringify(root.saved), b = JSON.stringify(root.draft)
        root.dirtyCount = (a === b) ? 0 : 1
        var checked = Model.validate(root.draft)
        root.rejected = checked.rejected
        root.blocked = checked.blocked
        var placements = 0
        for (var i = 0; i < checked.programs.length; i++) {
            if (checked.programs[i].placement.kind !== "none") placements += 1
        }
        root.counted(checked.programs.length, placements)
    }

    // --- load -------------------------------------------------------------
    function reload() {
        root.errorText = ""
        readProc.command = run.tool("omarchy-autostart-config", "read")
        readProc.running = true
    }

    Process {
        id: readProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var envelope
                try { envelope = JSON.parse(String(text || "{}")) }
                catch (e) { root.errorText = "the config reader gave an unreadable answer"; return }
                if (!envelope.ok) {
                    // A broken file is not overwritten and nothing is applied.
                    root.errorText = root.explain(envelope.error, envelope.detail)
                    return
                }
                root.saved = envelope.config
                root.draft = JSON.parse(JSON.stringify(envelope.config))
                root.savedMtime = envelope.mtime
                root.markDirty()
                root.refreshLive()
            }
        }
    }

    function explain(code, detail) {
        if (code === "insecure-permissions")
            return "The configuration file can be written by someone else. " + detail
        if (code === "too-large")     return "The configuration file is too large. " + detail
        if (code === "not-json")      return "The configuration file is not valid JSON. " + detail
        if (code === "bad-schema")    return "Unknown configuration version. " + detail
        if (code === "stale")         return "The file changed on disk since it was read. " + detail
        return String(code) + ": " + String(detail || "")
    }

    // --- live state -------------------------------------------------------
    function refreshLive() {
        windowsProc.command = run.tool("omarchy-autostart-windows")
        windowsProc.running = true
        workspacesProc.command = run.tool("omarchy-autostart-windows", "--workspaces")
        workspacesProc.running = true
        root.refreshMatches()
    }

    Process {
        id: windowsProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try { root.openWindows = JSON.parse(String(text || "[]")) }
                catch (e) { root.openWindows = [] }
            }
        }
    }

    Process {
        id: workspacesProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try { root.workspacesNow = JSON.parse(String(text || "[]")) }
                catch (e) { root.workspacesNow = [] }
            }
        }
    }

    // Which programs are running. The class regex is matched by the script, in
    // grep -E: an automaton that does not backtrack. Doing it here with
    // JavaScript RegExp would let a pattern like ^(a+)$ hang the panel, and
    // QML has no timeout to rescue it.
    function refreshMatches() {
        var programs = Model.validate(root.draft).programs
        var lines = []
        for (var i = 0; i < programs.length; i++) {
            lines.push(programs[i].id + "\t" + programs[i]["class"])
        }
        matchProc.command = run.runner(
            "f=$(mktemp) && printf '%s' " + Model.shellQuote(lines.join("\n") + "\n") + " > \"$f\" && "
            + Model.shellQuote(run.binDir + "omarchy-autostart-windows")
            + " --match-file \"$f\" | head -c " + run.maxOutBytes + " ; rm -f \"$f\"")
        matchProc.running = true
    }

    Process {
        id: matchProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var hits = []
                try { hits = JSON.parse(String(text || "[]")) } catch (e) { hits = [] }
                root.matches = hits
                root.missing = Model.missingIds(Model.validate(root.draft), hits)
            }
        }
    }
    property var matches: []

    // --- apply ------------------------------------------------------------
    function apply() {
        root.errorText = ""
        if (root.blocked.length > 0) {
            root.errorText = "Two programs match the same window class but want "
                           + "different places: " + root.blocked[0].labels.join(", ")
            return
        }
        writeProc.command = run.runner(
            "printf '%s' " + Model.shellQuote(JSON.stringify(root.draft)) + " | "
            + Model.shellQuote(run.binDir + "omarchy-autostart-config")
            + " write --expect-mtime " + root.savedMtime
            + " | head -c " + run.maxOutBytes)
        writeProc.running = true
    }

    Process {
        id: writeProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var envelope
                try { envelope = JSON.parse(String(text || "{}")) }
                catch (e) { root.errorText = "the config writer gave an unreadable answer"; return }
                if (!envelope.ok) {
                    root.errorText = root.explain(envelope.error, envelope.detail)
                    return
                }
                root.saved = JSON.parse(JSON.stringify(root.draft))
                root.savedMtime = envelope.mtime
                root.markDirty()
                root.applyRules()
            }
        }
    }

    property var pendingChunks: []
    property int pendingIndex: 0

    function applyRules() {
        var checked = Model.validate(root.draft)
        try {
            root.pendingChunks = Model.buildRuleChunks(checked)
                                     .concat(Model.buildReconcileChunks(
                                         checked, root.workspacesNow, root.matches))
        } catch (e) {
            root.errorText = String(e.message)
            return
        }
        root.pendingIndex = 0
        root.nextChunk()
    }

    // The two hyprctl verbs are not interchangeable, and which payload needs
    // which was measured in task 1. Model.verbFor is the single place that
    // knows -- do not inline the rule here.
    function nextChunk() {
        if (root.pendingIndex >= root.pendingChunks.length) { root.refreshLive(); return }
        var payload = root.pendingChunks[root.pendingIndex]
        evalProc.command = run.hypr(Model.verbFor(payload), payload)
        root.pendingIndex += 1
        evalProc.running = true
    }

    Process {
        id: evalProc
        onExited: function(exitCode, exitStatus) {
            if (exitCode !== 0 && root.errorText === "") {
                root.errorText = "hyprctl refused a rule block; nothing further was applied"
                root.pendingIndex = root.pendingChunks.length
            }
            root.nextChunk()
        }
    }

    function revert() {
        root.draft = JSON.parse(JSON.stringify(root.saved))
        root.errorText = ""
        root.markDirty()
    }

    // Launching is a separate button on purpose: saving must not open windows.
    function launchMissing() {
        var programs = Model.validate(root.draft).programs
        var commands = []
        for (var i = 0; i < programs.length; i++) {
            if (root.missing.indexOf(programs[i].id) !== -1) {
                commands.push(Model.launchCommand(programs[i].command))
            }
        }
        if (commands.length === 0) return
        launchProc.command = run.runner(commands.join(" & ") + " & wait")
        launchProc.running = true
    }

    Process { id: launchProc }
    Process { id: appsProc }   // filled in task 16

    // --- layout -----------------------------------------------------------
    // The visual tree is specified in the plan as a binding table. Component
    // vocabulary and spacing come from smartalb.vpn/Panel.qml.
    function monitorNames() {
        var names = {}, out = [], i
        for (i = 0; i < root.workspacesNow.length; i++) names[root.workspacesNow[i].monitor] = true
        for (i = 0; i < root.openWindows.length; i++)  names[root.openWindows[i].monitor] = true
        for (i = 0; i < (root.draft.workspaces || []).length; i++) {
            var configured = root.draft.workspaces[i].monitor
            if (names[configured] === undefined) names[configured] = false   // gone
        }
        for (var name in names) {
            if (name === "") continue
            out.push({ name: name, present: names[name] })
        }
        return out
    }
}
```

- [ ] **Step 4: Den Aufbau der Oberfläche nach dieser Tabelle bauen**

Ein `Column` im Wurzel-`Item`, `spacing` und Bausteine wie in `smartalb.vpn/Panel.qml`. Jede Zeile nennt Element, Quelle und Wirkung; nichts davon schreibt auf die Platte, alles ändert nur `root.draft` und ruft `root.markDirty()`.

| Element | Quelle / Bindung | Wirkung bei Bedienung |
|---|---|---|
| Titelzeile `Autostart Layout` | fest | — |
| Bereichstitel `PROGRAMS` | fest | — |
| `[+ Add]` rechts daneben | — | `root.openAdd()` (Task 16) |
| `Repeater` über Programme | `Model.validate(root.draft).programs` | — |
| Kontrollkästchen je Zeile | `program.enabled` | schaltet `enabled` im `draft`, dann `markDirty()` |
| Laufzustands-Punkt | `root.missing.indexOf(program.id) === -1` | — (nur Anzeige) |
| Name | `program.name` | Klick klappt die Zeile auf |
| Platzierungstext | `kind === "none"` → `no placement`; `kind === "workspace"` → `Workspace <value>` und, wenn `Model.effectiveMonitor(program, root.draft.workspaces)` nicht leer ist, ` · <monitor>`; `kind === "monitor"` → `Monitor <value>` | — |
| Ausklapp-Pfeil | `root.expandedId === program.id` | setzt `root.expandedId` |
| **aufgeklappt:** Feld `Command` | `program.command` | schreibt `command` im `draft`, `markDirty()` |
| **aufgeklappt:** Feld `Class` | `program["class"]` | schreibt `class` im `draft`, `markDirty()` |
| **aufgeklappt:** `[From window]` | — | `root.pickForId = program.id` (Task 16) |
| **aufgeklappt:** drei Optionsfelder | `program.placement.kind` | setzt `placement` auf `{kind:"none"}`, `{kind:"workspace",value:<Auswahl>}` oder `{kind:"monitor",value:<Auswahl>}`, `markDirty()` |
| — Workspace-Auswahl | 1–99 | wie oben |
| — abgeleiteter Monitor dahinter | `Model.effectiveMonitor(...)`, ausgegraut, nicht bearbeitbar | — |
| — Monitor-Auswahl | `root.monitorNames()` | wie oben |
| **aufgeklappt:** `[Remove]` | — | entfernt den Eintrag aus `draft.programs`, `markDirty()` |
| Bereichstitel `WORKSPACE → MONITOR` | fest | — |
| `[+ Add]` | — | hängt `{workspace:"<erste freie 1-99>", monitor:"<erster present>"}` an, `markDirty()` |
| Gitter, zwei Spalten | `root.draft.workspaces` | — |
| — Workspace-Nummer | `row.workspace` | — |
| — Monitor-Auswahlfeld | `root.monitorNames()`; Einträge mit `present === false` werden als `<name> (gone)` beschriftet und bleiben wählbar | schreibt `monitor` in der Zeile, `markDirty()` |
| Zeile `N enabled programs not running` | `root.missing.length` | — |
| `[Launch missing]`, nur wenn `root.missing.length > 0` | — | `root.launchMissing()` |
| `[Import current session]`, nur wenn `(root.draft.programs \|\| []).length === 0` | — | `root.importSession()` (Task 16) |
| Fußbereich: Fehlertext | `root.errorText` | — |
| Fußbereich: Auslassungen | je Eintrag in `root.rejected`: `<label>: <reason>` | — |
| Fußbereich: Widersprüche | je Eintrag in `root.blocked`: die `labels`, verbunden | — |
| Fußbereich: `N changes pending` | `root.dirtyCount` | — |
| `[Revert]`, nur aktiv wenn `dirtyCount > 0` | — | `root.revert()` |
| `[Apply]`, nur aktiv wenn `dirtyCount > 0 && root.blocked.length === 0` | — | `root.apply()` |

Dazu `property string expandedId: ""` im Wurzel-`Item` ergänzen. Ein nicht angeschlossener Monitor bleibt in der Liste und wird als `(gone)` gezeigt: wer sein Notebook aus der Dockingstation nimmt und das Panel öffnet, darf nicht durch bloßes Hinsehen seine Konfiguration verlieren.

- [ ] **Step 5: Laufen lassen und Grün sehen**

Run: `./test/run-tests.sh && ./test/run-qml-tests.sh`
Expected: beide grün, inklusive der acht Teardown-Prüfungen für `Panel.qml`.

- [ ] **Step 6: Zwei Mutationsproben fahren**

```bash
# Probe A -- JS-RegExp auf die Klasse ansetzen
python3 - <<'MUT'
import io
p = "Panel.qml"; s = io.open(p, encoding="utf-8").read()
old = 'root.missing = Model.missingIds(Model.validate(root.draft), hits)'
new = 'root.missing = []; if (new RegExp("x").test("x")) root.missing = []'
assert old in s
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
MUT
./test/run-tests.sh; echo "A status=$?"
git checkout Panel.qml

# Probe B -- Teardown eines Prozesses entfernen
sed -i '/matchProc.running = false/d' Panel.qml
./test/run-tests.sh; echo "B status=$?"
git checkout Panel.qml
```
Expected: A → `Panel: no JavaScript RegExp over user patterns` rot. B → `Panel.qml: teardown stops matchProc` rot.

- [ ] **Step 7: In der laufenden Shell prüfen**

```bash
omarchy-restart-shell
sleep 8
```
Dann: Panel öffnen, eine Workspace-Zeile ändern, `[Apply]`, und mit `hyprctl workspacerules` nachsehen, ob die Regel angekommen ist. Escape muss schließen. Dann `[Revert]` nach einer Änderung: die Anzeige muss auf den gespeicherten Stand zurückfallen und „changes pending" verschwinden.

- [ ] **Step 8: Commit**

```bash
git add Panel.qml test/qml-structure.sh
git commit -m "feat: the configuration panel

saved and draft are kept apart, so "changes pending" is honest and Apply is
explicit -- moving real windows across real screens must not be a side effect
of a keystroke. A disconnected monitor stays in the list as "(gone)" so
undocking and opening the panel cannot destroy a configuration."
```

---

### Task 16: `Panel.qml` — Hinzufügen, Fenster übernehmen, Import

**Files:**
- Modify: `Panel.qml`
- Modify: `test/harness.qml`
- Modify: `Model.js`

**Interfaces:**
- Consumes: `bin/omarchy-autostart-apps`, `root.openWindows`, `Model.stripFieldCodes`.
- Produces:
  - `Model.newId(existing) -> string` — freie Kennung aus `[a-z0-9]{1,16}`.
  - `Model.classLiteral(windowClass) -> string` — `^(…)$` mit wörtlich maskiertem Klassennamen; wirft, wenn das Ergebnis die Erlaubnisliste nicht erfüllt.
  - `Model.guessCommand(windowClass, apps) -> string` — Abgleich Klasse gegen `wmclass` bzw. Dateinamen; `""` wenn nichts passt.
  - `Model.importFromSession(windows, workspacesNow, apps) -> config` — der Erststart-Import.

- [ ] **Step 1: Die fehlschlagenden Tests schreiben**

In `test/harness.qml`:

```qml
        // --- newId ---------------------------------------------------------
        check("newId: avoids an id in use",
              Model.newId([{ id: "p1" }]) !== "p1", true);
        check("newId: satisfies the id rule",
              Model.ID_RE.test(Model.newId([])), true);
        check("newId: still finds one after many",
              (function() {
                  var many = [], i;
                  for (i = 1; i <= 250; i++) many.push({ id: "p" + i });
                  var fresh = Model.newId(many);
                  for (i = 0; i < many.length; i++) if (many[i].id === fresh) return "collides";
                  return "free";
              })(), "free");

        // --- classLiteral --------------------------------------------------
        check("classLiteral: anchors and escapes the dots",
              Model.classLiteral("nimbus-chat.example.org__-Default"),
              "^(nimbus\\-web\\.chat\\.com__\\-Default)$");
        check("classLiteral: a plain class",
              Model.classLiteral("cursor"), "^(cursor)$");
        check("classLiteral: the result passes the allowlist",
              Model.CLASS_RE.test(Model.classLiteral("LM-Studio")), true);
        checkThrows("classLiteral: a class with a quote is refused",
                    function() { Model.classLiteral('a"b'); }, /classLiteral: refusing/);
        checkThrows("classLiteral: a non-ascii class is refused",
                    function() { Model.classLiteral("café"); }, /classLiteral: refusing/);

        // --- guessCommand --------------------------------------------------
        var apps = [{ name: "Cursor", exec: "cursor %U", wmclass: "cursor", icon: "" },
                    { name: "Modelbox", exec: "modelbox", wmclass: "LM-Studio", icon: "" },
                    { name: "Files", exec: "nautilus %U", wmclass: "", icon: "" }];

        check("guessCommand: matches StartupWMClass and strips field codes",
              Model.guessCommand("cursor", apps), "cursor");
        check("guessCommand: matches case-insensitively",
              Model.guessCommand("modelbox", apps), "modelbox");
        check("guessCommand: no match, no guess",
              Model.guessCommand("firefox", apps), "");

        // --- importFromSession ---------------------------------------------
        check("import: builds one program per window",
              Model.importFromSession(
                  [{ address: "0x1", class: "cursor", title: "t", workspace: "6", monitor: "HDMI-A-1" }],
                  [{ workspace: "6", monitor: "HDMI-A-1" }], apps).programs.length, 1);
        check("import: everything arrives disabled",
              Model.importFromSession(
                  [{ address: "0x1", class: "cursor", title: "t", workspace: "6", monitor: "HDMI-A-1" }],
                  [], apps).programs[0].enabled, false);
        check("import: the workspace table comes from the live state",
              Model.importFromSession([], [{ workspace: "2", monitor: "DP-3" }], apps).workspaces.length, 1);
        check("import: placement follows the window's workspace",
              Model.importFromSession(
                  [{ address: "0x1", class: "cursor", title: "t", workspace: "6", monitor: "HDMI-A-1" }],
                  [], apps).programs[0].placement.value, "6");
        check("import: the result survives its own validation",
              (function() {
                  var config = Model.importFromSession(
                      [{ address: "0x1", class: "cursor", title: "t", workspace: "6", monitor: "HDMI-A-1" },
                       { address: "0x2", class: "LM-Studio", title: "t", workspace: "1", monitor: "DP-4" }],
                      [{ workspace: "6", monitor: "HDMI-A-1" }], apps);
                  var checked = Model.validate(config);
                  return checked.rejected.length === 0 && checked.blocked.length === 0;
              })(), true);
        check("import: a window whose class cannot be encoded is skipped, not fatal",
              Model.importFromSession(
                  [{ address: "0x1", class: "café", title: "t", workspace: "1", monitor: "DP-4" },
                   { address: "0x2", class: "cursor", title: "t", workspace: "1", monitor: "DP-4" }],
                  [], apps).programs.length, 1);
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run: `./test/run-qml-tests.sh; echo "status=$?"`
Expected: FAIL, `Model.newId` ist keine Funktion.

- [ ] **Step 3: `Model.js` erweitern**

```javascript
// --- adding entries -------------------------------------------------------

function newId(existing) {
    var used = {}, i;
    for (i = 0; i < (existing || []).length; i++) used[existing[i].id] = true;
    for (i = 1; i <= 100000; i++) {
        var candidate = "p" + i;
        if (!used[candidate] && ID_RE.test(candidate)) return candidate;
    }
    throw new Error("newId: no free id");
}

// Turn a window class into an anchored literal pattern. Every character that
// is a regex metacharacter is escaped, so what looks like a pattern in a class
// name stays a class name. The result is checked against the allowlist before
// it is handed back -- a class picked from a window is not more trustworthy
// than one typed in.
function classLiteral(windowClass) {
    var escaped = String(windowClass).replace(/[.^$()|\[\]?*+\\:-]/g, "\\$&");
    var pattern = "^(" + escaped + ")$";
    if (!CLASS_RE.test(pattern)) {
        throw new Error("classLiteral: refusing " + windowClass);
    }
    return pattern;
}

function guessCommand(windowClass, apps) {
    var wanted = String(windowClass).toLowerCase(), i;
    var list = apps || [];
    for (i = 0; i < list.length; i++) {
        if (list[i].wmclass && String(list[i].wmclass).toLowerCase() === wanted) {
            return stripFieldCodes(list[i].exec);
        }
    }
    // Second pass: the leading word of Exec often IS the class.
    for (i = 0; i < list.length; i++) {
        var first = stripFieldCodes(list[i].exec).split(" ")[0];
        if (first && first.toLowerCase() === wanted) return stripFieldCodes(list[i].exec);
    }
    return "";
}

// The first-run import. Everything arrives disabled: a list the user has only
// just seen must not open by itself at the next login. A window whose class
// cannot be encoded is skipped rather than aborting the whole import -- one odd
// window should not cost the other twenty.
function importFromSession(windows, workspacesNow, apps) {
    var config = { schemaVersion: 1, programs: [], workspaces: [] };
    var seen = {}, i;

    for (i = 0; i < (workspacesNow || []).length; i++) {
        var row = workspacesNow[i];
        if (WORKSPACE_RE.test(row.workspace) && MONITOR_RE.test(row.monitor)) {
            config.workspaces.push({ workspace: row.workspace, monitor: row.monitor });
        }
    }

    for (i = 0; i < (windows || []).length; i++) {
        var window = windows[i];
        if (seen[window["class"]]) continue;
        var pattern, command;
        try { pattern = classLiteral(window["class"]) } catch (e) { continue }
        command = guessCommand(window["class"], apps);
        if (command === "") command = String(window["class"]);
        if (command.length > MAX_COMMAND) continue;
        seen[window["class"]] = true;
        config.programs.push({
            id: newId(config.programs),
            name: String(window["class"]).substring(0, MAX_NAME),
            enabled: false,
            command: command,
            "class": pattern,
            placement: WORKSPACE_RE.test(window.workspace)
                     ? { kind: "workspace", value: window.workspace }
                     : { kind: "none" }
        });
    }
    return config;
}
```

- [ ] **Step 4: `Panel.qml` erweitern**

Drei Abläufe, jeder ändert nur `root.draft` und ruft `root.markDirty()` — gespeichert wird ausschließlich über `[Apply]`:

```qml
    // [+ Add] -- the picker over the installed .desktop entries.
    property var apps: []
    property bool addOpen: false

    function openAdd() {
        root.addOpen = true
        appsProc.command = run.tool("omarchy-autostart-apps")
        appsProc.running = true
    }

    // Replaces the placeholder Process from task 15.
    Process {
        id: appsProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try { root.apps = JSON.parse(String(text || "[]")) }
                catch (e) { root.apps = [] }
            }
        }
    }

    function addFromApp(app) {
        var programs = (root.draft.programs || []).slice()
        var pattern = ""
        if (app.wmclass) {
            try { pattern = Model.classLiteral(app.wmclass) } catch (e) { pattern = "" }
        }
        programs.push({
            id: Model.newId(programs),
            name: String(app.name).substring(0, 100),
            enabled: false,                        // never on by merely being added
            command: Model.stripFieldCodes(app.exec),
            "class": pattern,                      // empty means: use [From window]
            placement: { kind: "none" }
        })
        root.draft.programs = programs
        root.addOpen = false
        root.markDirty()
    }

    // [From window] -- fills the class from a window that is open right now.
    // This is the route on which webapps and LM-Studio come out right without
    // the user knowing anything.
    property string pickForId: ""

    function pickClass(program, windowClass) {
        var programs = (root.draft.programs || []).slice()
        for (var i = 0; i < programs.length; i++) {
            if (programs[i].id !== program.id) continue
            try { programs[i]["class"] = Model.classLiteral(windowClass) }
            catch (e) { root.errorText = "That window class cannot be used: " + e.message; return }
        }
        root.draft.programs = programs
        root.pickForId = ""
        root.markDirty()
    }

    // [Import current session] -- the answer to an empty panel on first run.
    function importSession() {
        if ((root.draft.programs || []).length > 0) return
        appsProc.command = run.tool("omarchy-autostart-apps")
        importPending = true
        appsProc.running = true
    }
    property bool importPending: false

    // Hook this into appsProc.onExited so the import runs once the app list is
    // in: draft = Model.importFromSession(root.openWindows, root.workspacesNow,
    // root.apps), then markDirty(). Nothing is written -- the button says the
    // list is to be reviewed, not that it is finished.
```

Im Layout: der `[+ Add]`-Knopf öffnet `openAdd()`, `[From window]` setzt `pickForId` und zeigt `root.openWindows` als Auswahl mit Klasse und Titel, und `[Import current session]` erscheint **nur**, wenn `draft.programs` leer ist.

- [ ] **Step 5: Laufen lassen und Grün sehen**

Run: `./test/run-qml-tests.sh && ./test/run-tests.sh`
Expected: beide grün.

- [ ] **Step 6: Drei Mutationsproben fahren**

```bash
# Probe A -- Import legt Eintraege eingeschaltet an
sed -i 's/^            enabled: false,$/            enabled: true,/' Model.js
./test/run-qml-tests.sh; echo "A status=$?"
git checkout Model.js

# Probe B -- Metazeichen im Klassennamen nicht maskieren
python3 - <<'MUT'
import io
p = "Model.js"; s = io.open(p, encoding="utf-8").read()
old = 'var escaped = String(windowClass).replace(/[.^$()|\\[\\]?*+\\\\:-]/g, "\\\\$&");'
new = 'var escaped = String(windowClass);'
assert old in s, "Mutationsziel nicht gefunden"
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
MUT
./test/run-qml-tests.sh; echo "B status=$?"
git checkout Model.js

# Probe C -- Erlaubnisliste im classLiteral nicht mehr pruefen
sed -i 's|^    if (!CLASS_RE.test(pattern)) {|    if (false) {|' Model.js
./test/run-qml-tests.sh; echo "C status=$?"
git checkout Model.js
```
Expected: A → `import: everything arrives disabled` rot. B → `classLiteral: anchors and escapes the dots` rot. C → beide `classLiteral … refused`-Proben rot.

- [ ] **Step 7: Commit**

```bash
git add Model.js Panel.qml test/harness.qml
git commit -m "feat: add from the app list, pick a class from a window, import

A class picked from a window is escaped to a literal pattern and then put
through the same allowlist as a typed one -- picking it does not make it
trustworthy. Everything the import creates arrives disabled: a list the user
has only just seen must not open by itself at the next login."
```

---
### Task 17: Manifest, Installation, README, Vorschau, Abschlussprüfungen

**Files:**
- Create: `manifest.json`, `install`, `uninstall`, `README.md`, `LICENSE`, `preview.png`
- Create: `test/mutations.sh`
- Modify: `test/run-tests.sh`

**Interfaces:**
- Consumes: alles Vorherige.
- Produces: ein einreichbares Repo.

- [ ] **Step 1: Die fehlschlagenden Prüfungen schreiben**

In `test/run-tests.sh`:

```bash
test_manifest_is_sound() {
    local m="$PWD/../manifest.json"
    assert_status "manifest: is valid JSON" 0 jq -e . "$m"
    assert_eq "manifest: id"            "$(jq -r .id "$m")"            "smartalb.autostart"
    assert_eq "manifest: schemaVersion" "$(jq -r .schemaVersion "$m")" "1"
    assert_eq "manifest: not in the omarchy namespace" \
              "$(jq -r '.id | startswith("omarchy.")' "$m")" "false"
    for kind in bar-widget panel service; do
        assert_eq "manifest: declares kind $kind" \
                  "$(jq -r --arg k "$kind" '.kinds | index($k) != null' "$m")" "true"
    done
    for pair in "barWidget:BarWidget.qml" "panel:Panel.qml" "service:Service.qml"; do
        local key="${pair%%:*}" file="${pair#*:}"
        assert_eq "manifest: entryPoint $key" \
                  "$(jq -r --arg k "$key" '.entryPoints[$k]' "$m")" "$file"
        assert_eq "manifest: $file exists" \
                  "$([[ -f "$PWD/../$file" ]] && echo yes || echo no)" "yes"
    done
}

test_repository_has_what_validation_looks_for() {
    for f in README.md LICENSE preview.png manifest.json; do
        assert_eq "root: $f is present" \
                  "$([[ -f "$PWD/../$f" ]] && echo yes || echo no)" "yes"
    done
    assert_eq "root: no symlink anywhere in the plugin" \
              "$(find "$PWD/.." -type l -not -path '*/.git/*' | wc -l)" "0"
}

# The security baseline reads the README too. On smartalb.vpn four pacman lines
# in prose raised the privilege and package-manager capabilities and cost a
# round of manual review. This plugin needs no privilege at all, so the words
# must not be there either.
test_nothing_privileged_anywhere() {
    local hits
    hits="$(grep -rniE '\b(sudo|pkexec|visudo|sudoers|pacman|systemctl)\b' \
            "$PWD/.."/{README.md,install,uninstall,manifest.json} \
            "$PWD/.."/*.qml "$PWD/../Model.js" "$PWD/../bin"/* 2>/dev/null || true)"
    assert_eq "no privileged verb in code, installer or README" "$hits" ""
}

test_install_is_executable_and_unprivileged() {
    assert_eq "install is executable"   "$([[ -x "$PWD/../install"   ]] && echo yes || echo no)" "yes"
    assert_eq "uninstall is executable" "$([[ -x "$PWD/../uninstall" ]] && echo yes || echo no)" "yes"
    assert_eq "install has no --system tier" \
              "$(grep -c -- '--system' "$PWD/../install" || true)" "0"
}

test_manifest_is_sound
test_repository_has_what_validation_looks_for
test_nothing_privileged_anywhere
test_install_is_executable_and_unprivileged
```

- [ ] **Step 2: Laufen lassen und den Fehlschlag sehen**

Run: `./test/run-tests.sh; echo "status=$?"`
Expected: die neuen Prüfungen rot.

- [ ] **Step 3: `manifest.json` schreiben**

```json
{
  "schemaVersion": 1,
  "id": "smartalb.autostart",
  "name": "Autostart Layout",
  "version": "1.0.0",
  "author": "SmartALB",
  "license": "MIT",
  "description": "Choose which programs start with your session and where their windows go",
  "kinds": ["bar-widget", "panel", "service"],
  "entryPoints": {
    "barWidget": "BarWidget.qml",
    "panel": "Panel.qml",
    "service": "Service.qml"
  },
  "barWidget": {
    "displayName": "Autostart Layout",
    "description": "Autostart programs, their workspace or monitor, and which monitor each workspace lives on",
    "category": "System",
    "allowMultiple": false,
    "defaultSection": "right"
  }
}
```

- [ ] **Step 4: `install` und `uninstall` schreiben**

```bash
#!/usr/bin/env bash
# Installs Autostart Layout into ~/.config/omarchy/plugins/.
#
# Nothing privileged happens here and there is no --system tier: this plugin
# needs no root, no polkit action and no sudoers rule. It copies files and
# stops.
set -euo pipefail

ID="smartalb.autostart"
SOURCE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$ID"

if [[ "$(id -u)" -eq 0 ]]; then
    echo "error: do not run this as root. It installs into your own config." >&2
    exit 1
fi

if [[ "$SOURCE" == "$TARGET" ]]; then
    echo "Already in place at $TARGET -- nothing to copy."
else
    mkdir -p "$TARGET"
    for item in manifest.json README.md LICENSE preview.png \
                BarWidget.qml Panel.qml Service.qml Runners.qml Model.js bin; do
        [[ -e "$SOURCE/$item" ]] || continue
        cp -r "$SOURCE/$item" "$TARGET/"
    done
    chmod +x "$TARGET"/bin/*
    echo "Installed to $TARGET"
fi

cat <<'NOTE'

Two things to know:

  1. Restart the shell so the widget appears:  omarchy-restart-shell
  2. Add the widget to your bar in ~/.config/omarchy/shell.json

Your configuration will live in ~/.config/omarchy/autostart-layout.json with
mode 0600. It holds command lines that are executed as you when your session
starts -- the same trust level as ~/.config/hypr/autostart.lua. The plugin
refuses to apply anything if that file becomes writable by anyone else.
NOTE
```

```bash
#!/usr/bin/env bash
# Removes Autostart Layout.
#
# It does NOT remove your configuration file: that is your data, and a
# reinstall should find your list again. The path is printed so you can delete
# it deliberately.
set -euo pipefail

ID="smartalb.autostart"
TARGET="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$ID"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/autostart-layout.json"
MARKER_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/smartalb.autostart"

[[ -d "$TARGET" ]] && rm -rf "$TARGET" && echo "Removed $TARGET"
[[ -d "$MARKER_DIR" ]] && rm -rf "$MARKER_DIR"

cat <<NOTE

Remove the widget from your bar in ~/.config/omarchy/shell.json, then run
omarchy-restart-shell.

Your configuration was kept:
  $CONFIG

Rules that are already set live on until Hyprland restarts. They are held in
the running compositor and in no file, so there is nothing left to delete --
log out and back in, or run: hyprctl reload
NOTE
```

- [ ] **Step 5: `README.md` schreiben**

Auf Englisch, und ohne die Wörter, die die Baseline als Capability liest. Diese Abschnitte, in dieser Reihenfolge:

1. **What it does** — die vier Dinge, mit dem Screenshot.
2. **Install** — `./install`, `omarchy-restart-shell`, Widget in `shell.json` eintragen.
3. **How placement works** — dass ein Workspace auf genau einem Monitor lebt, und dass `placement` deshalb ein Entweder-oder ist. Der Satz, der die häufigste Rückfrage vorwegnimmt: *„If you want a program on a particular screen and do not care about the workspace number, choose monitor. If you think in workspaces, choose workspace and pin the workspace to a monitor in the table below."*
4. **Where your data lives** — der Pfad, `0600`, dass die Datei Kommandozeilen enthält, die beim Login als der Nutzer ausgeführt werden, dieselbe Vertrauensstufe wie `~/.config/hypr/autostart.lua`, und dass das Plugin nichts anwendet, wenn die Datei fremdbeschreibbar wird.
5. **How it applies** — dass keine Hyprland-Konfigurationsdatei angefasst wird, dass die Regeln zur Laufzeit gesetzt werden, und dass ein manuelles `hyprctl reload` sie kurz wegnimmt, bis der Dienst sie zurücksetzt.
6. **Known limits** — Workspaces nur 1–99, keine benannten; keine `float`/`maximize`-Regeln; mehrere Fenster derselben Klasse gehen an denselben Ort; eine Anwendung, deren Klasse erst nach dem ersten Start bekannt ist, braucht einmal **From window**. Falls Task 1 Frage 2 mit `FAIL` endete, hier zusätzlich: Monitor-Platzierung greift erst, wenn das Fenster offen ist.
7. **Development** — die drei Fallen, jede mit dem Symptom, an dem man sie erkennt:
   - Nach jeder QML-Änderung `omarchy-restart-shell`. Der Develop-Guide sagt „saved changes reload automatically"; für Bar-Widgets stimmt das nicht. Symptom: das Journal schreibt `Local plugin changed, reloading`, das Widget verhält sich aber wie die alte Fassung, und eingebaute Diagnose-Ausgaben feuern nicht.
   - Nach dem Anfassen einer Plugin-Datei ~8 s warten, bevor man messt: der inotify-Wächter lädt die Shell neu und reißt laufende `Process`-Objekte mit. Symptom im Journal: `another handler is registered for target`.
   - Für die Testsuite `/usr/lib/qt6/bin/qml` benutzen. `/usr/bin/qml` ist auf Arch Qt 5.15, lädt das Gerüst nicht und endet mit Status 2 — was mit dem eigenen „kann nicht starten" des Läufers kollidiert. Das Werkzeug, das **ohne jede Ausgabe** mit Status 1 endet, ist `/usr/bin/qmltestrunner`; deshalb wird es nicht benutzt. Die vier Ausgangsstati des Läufers: 0 grün, 1 ein Test rot, 2 kann nicht starten, 3 das Gerüst selbst gescheitert.
8. **Tests** — `./test/run-tests.sh`, `./test/run-qml-tests.sh`, `./test/mutations.sh`.

- [ ] **Step 6: `test/mutations.sh` schreiben**

Ein Skript, das alle Mutationsproben aus Task 4–16 hintereinander fährt und je Probe verlangt, dass die Suite rot wird **und** danach wieder grün ist. Aufbau:

```bash
#!/usr/bin/env bash
# Runs every mutation probe from the plan. A structural test that survives its
# own mutation does not hold the property it claims to hold.
#
# Each probe: apply, expect the suite to go red, restore, expect green again.
set -uo pipefail
cd "$(dirname "$0")/.."

run=0; failed=0

probe() {
    local name="$1" suite="$2" mutate="$3"
    run=$((run + 1))
    if ! git diff --quiet; then
        printf 'FAIL %s -- working tree is dirty; probes need a clean tree\n' "$name"
        failed=$((failed + 1)); return
    fi
    eval "$mutate"
    if "$suite" >/dev/null 2>&1; then
        printf 'FAIL %s -- the suite stayed green under mutation\n' "$name"
        failed=$((failed + 1))
    else
        printf 'ok   %s -- the suite went red\n' "$name"
    fi
    git checkout -- . >/dev/null 2>&1
    if ! "$suite" >/dev/null 2>&1; then
        printf 'FAIL %s -- the suite did not recover after restore\n' "$name"
        failed=$((failed + 1))
    fi
}

SHELL_SUITE=./test/run-tests.sh
QML_SUITE=./test/run-qml-tests.sh

probe "config: MAX+1 read"        "$SHELL_SUITE" \
  "sed -i 's/^    if (( size > MAX_BYTES )); then/    if false; then/' bin/omarchy-autostart-config"
probe "config: permission refusal" "$SHELL_SUITE" \
  "sed -i 's/^    if (( 8#\$mode \& 8#22 )); then/    if false; then/' bin/omarchy-autostart-config"
probe "config: staleness check"    "$SHELL_SUITE" \
  "sed -i 's/^    \[\[ \"\$current\" == \"\$expect_mtime\" \]\]/    [[ true ]]/' bin/omarchy-autostart-config"
probe "apps: file count cap"       "$SHELL_SUITE" \
  "sed -i 's/^            (( count >= MAX_FILES )) \&\& break 2/            :/' bin/omarchy-autostart-apps"
probe "windows: window count cap"  "$SHELL_SUITE" \
  "sed -i 's/    | \.\[0:\$max\]/    | .[0:99999]/' bin/omarchy-autostart-windows"
probe "runners: absolute bash"     "$SHELL_SUITE" \
  "sed -i 's|\"/usr/bin/bash\"|\"bash\"|' Runners.qml"
probe "barwidget: glyph escape"    "$SHELL_SUITE" \
  "sed -i 's/\"\\\\uf135\"/\"\"/' BarWidget.qml"
probe "model: byte encoding"       "$QML_SUITE" \
  "sed -i 's/luaBytes(program\[\"class\"\])/String(program[\"class\"])/' Model.js"
probe "model: placement either-or" "$QML_SUITE" \
  "sed -i 's/^    if (placement.monitor !== undefined \&\& placement.workspace !== undefined) {/    if (false) {/' Model.js"
probe "model: program cap"         "$QML_SUITE" \
  "sed -i 's/^        if (out.programs.length >= MAX_PROGRAMS) {/        if (false) {/' Model.js"
probe "model: address shape"       "$QML_SUITE" \
  "sed -i 's|^        if (!ADDRESS_RE.test(hits\[i\].address)) {|        if (false) {|' Model.js"
probe "model: import stays off"    "$QML_SUITE" \
  "sed -i 's/^            enabled: false,\$/            enabled: true,/' Model.js"

printf '\nmutation probes: total=%d failed=%d\n' "$run" "$failed"
(( failed == 0 ))
```

- [ ] **Step 7: Die Vorschau erzeugen**

Das Panel mit einer aussagekräftigen Konfiguration öffnen (mindestens vier Programme, drei davon platziert, eine Workspace-Tabelle mit drei Zeilen), einen Ausschnitt aufnehmen und als `preview.png` **in die Wurzel** legen. Die Validierung sucht dort; bei `smartalb.vpn` gab es zunächst nur die Ersatzvorschau, weil die Datei bloß unter `images/` lag. Vor dem Ablegen prüfen, dass keine Pfade, Kontonamen oder Firmendaten im Bild stehen.

- [ ] **Step 8: Alles laufen lassen**

Run:
```bash
chmod +x install uninstall test/mutations.sh
./test/run-tests.sh          && echo "shell ok"
./test/run-qml-tests.sh      && echo "qml ok"
./test/lua-syntax.sh         && echo "lua ok"
./test/qml-structure.sh      && echo "structure ok"
./test/mutations.sh          && echo "mutations ok"
omarchy plugin validate "$PWD"
qmllint -I "${OMARCHY_PATH:-/usr/share/omarchy}/shell" BarWidget.qml Panel.qml Service.qml Runners.qml
```
Expected: alle grün, `omarchy plugin validate` ohne Befund, `qmllint` ohne Warnung.

- [ ] **Step 9: Die Handprüfliste des Develop-Guides abgehen**

Jeden Punkt einzeln, nach `omarchy-restart-shell` und 8 s Wartezeit:

1. Widget ist in der Bar sichtbar, Tooltip nennt die richtigen Zahlen.
2. Klick öffnet das Panel, zweiter Klick schließt es.
3. Escape schließt das Panel.
4. `[Apply]` nach einer Workspace-Änderung: `hyprctl workspacerules` zeigt die neue Regel, und ein bereits offener Workspace ist umgezogen.
5. `[Apply]` nach einer Programm-Platzierung: ein bereits offenes Fenster ist verschoben.
6. `[Revert]` verwirft und „changes pending" verschwindet.
7. `[Launch missing]` startet genau die eingeschalteten Programme, die nicht laufen — und **keins** doppelt.
8. `omarchy-restart-shell` startet **nichts** neu (die Startmarke).
9. Plugin über die Omarchy-Oberfläche deaktivieren und wieder aktivieren.
10. `./uninstall`, dann prüfen: Verzeichnis weg, Konfigurationsdatei noch da.
11. Die Konfigurationsdatei auf `chmod 664` setzen, Panel öffnen: es muss die Meldung mit dem nötigen `chmod` zeigen und **nichts** anwenden.
12. Abmelden und neu anmelden: die eingeschalteten Programme starten, jedes einmal, auf ihrem Platz.

- [ ] **Step 10: Commit**

```bash
git add manifest.json install uninstall README.md LICENSE preview.png \
        test/mutations.sh test/run-tests.sh
git commit -m "feat: manifest, installer, README and preview

No privileged operation exists anywhere, and a test keeps the words out of
the README as well: on smartalb.vpn four package-manager lines in prose
raised two capabilities and cost a round of manual review.

preview.png sits at the repository root, which is where marketplace
validation looks for it."
```

- [ ] **Step 11: Einreichen**

Repo `SmartALB/omarchy-autostart-layout` öffentlich anlegen, `main` schützen, pushen, Version `1.0.0` taggen. Dann im Marketplace-Repo ein Issue anlegen, das den Commit-SHA nennt und ausdrücklich sagt: keine privilegierte Operation, keine `--system`-Stufe, kein Paketmanager; erwartete Baseline daher nur `installer`. Dazu ein Satz zu der Stelle, die ein Reviewer zuerst prüfen wird: das Plugin schiebt Lua in den laufenden Compositor, die Werte kommen dort als `string.char(…)` an, und die Erlaubnisliste ist die zweite, nicht die einzige Schicht.

---
