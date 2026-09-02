# Autostart Layout — Design

- **Plugin-ID:** `smartalb.autostart`
- **Anzeigename:** Autostart Layout
- **Datum:** 2026-09-02
- **Ziel:** Veröffentlichung im Omarchy-Plugin-Marketplace
- **Plattform-Vorgaben:** <https://plugins.omarchy.org/develop.html>

## 1. Zweck

Ein Omarchy-Quattro-Plugin, mit dem sich über die Bar konfigurieren lässt:

1. welche Programme beim Sitzungsstart ausgeführt werden,
2. auf welchem Workspace ein Programm erscheint,
3. auf welchem Monitor ein Workspace liegt,
4. auf welchem Monitor ein Programm erscheint (statt über den Workspace).

Heute liegen diese vier Dinge bei einem Omarchy-Nutzer in drei
handgeschriebenen Lua-Dateien (`hypr/autostart.lua`, `hypr/windowrules.lua`,
`hypr/workspaces.lua`) und sind nur mit Kenntnis der Hyprland-Syntax und der
Fensterklassen pflegbar.

## 2. Rahmenbedingungen

- Englische Oberfläche und englisches README; Monitore und Workspaces werden
  zur Laufzeit erkannt, nichts ist auf eine bestimmte Hardware verdrahtet.
- Änderungen werden **sofort** wirksam, nicht erst beim nächsten Login.
- Bedienung ausschließlich über Bar-Widget und Panel; keine zweite
  Oberfläche.
- **Keinerlei Privilegien.** Kein `sudo`, kein `pkexec`, keine
  Paketinstallation — weder im Code noch im README-Text.

## 3. Gesicherte Befunde

Alles hier Aufgeführte wurde am 02.09.2026 auf dem Zielsystem (Hyprland
0.56.2, Omarchy Quattro) nachgemessen, nicht angenommen.

| Befund | Beleg |
|---|---|
| `hyprctl keyword` ist unter der Lua-Konfiguration abgeschaltet | Antwort: `keyword can't work with non-legacy parsers. Use eval.` |
| `hyprctl eval '<lua>'` nimmt Lua an und wirkt wirklich | `hl.workspace_rule({ workspace = "99", monitor = "DP-3" })` erschien danach als Regel 99 in `hyprctl workspacerules`, obwohl sie in keiner Datei steht |
| Kein Omarchy-Kommando ruft `hyprctl reload` | `grep -rl "hyprctl reload" /usr/share/omarchy/bin/` ist leer; der Theme-Wechsel lädt nur die Shell neu |
| Hyprland bietet unter Lua eine Objekt-API | `/usr/share/hypr/stubs/hl.meta.lua`: `hl.get_windows(HL.WindowQueryFilter)`, `hl.get_monitors()`, `hl.get_workspaces()`; `HL.Window` mit `.class`, `.workspace`, `.monitor`, `.address`, `.pid` |
| `hl.window_rule()` liefert ein Objekt mit `set_enabled()`; `HL.WindowRuleSpec` hat ein `name`-Feld | ebd. |
| Dispatcher heißen `hl.dsp.window.move`, `hl.dsp.workspace.move`, `hl.dsp.focus` | Verwendung in `/usr/share/omarchy/default/hypr/bindings/tiling.lua` |
| `jq` gehört zu jeder Omarchy-Installation | steht in `/usr/share/omarchy/install/omarchy-base.packages` |
| `/usr/bin/qml` und `/usr/bin/qmltestrunner` sind Qt 5.15 und scheitern **still** mit Status 1 | `qml --version` → `Qml Runtime 5.15.19`; kein Wort auf stdout oder stderr |
| Qt6-Läufer unter `/usr/lib/qt6/bin/qml` funktioniert headless, mit sichtbarer Ausgabe und korrektem Status in **beiden** Richtungen | `QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qml harness.qml`: rote Prüfung → Status 1, entfernt → Status 0 |

### Offene Annahmen (erste Aufgaben des Implementierungsplans)

1. Sind Regel-Handles bzw. Regelnamen über **mehrere** `hyprctl eval`-Aufrufe
   hinweg wiederauffindbar (persistenter Lua-Zustand im Compositor)?
   Rückfallweg: Handles in einer Lua-Globalen unseres Namensraums halten
   (`_G.__smartalb_autostart`).
2. Wie lautet der Aufruf, der ein **bestimmtes** Fenster verschiebt?
   `hl.dsp.window.move` ist in den Stubs untypisiert (`fun(...)`).
   Kandidaten: `window`-Feld mit `HL.Window`/Adresse; Rückfallweg:
   `hl.dsp.focus` auf das Fenster, dann `hl.dsp.window.move`.

Beide werden mit einem echten Fenster live geprüft, nicht über die
`ok`-Antwort von `eval` — `ok` bedeutet nur, dass der Lua-Block lief.

## 4. Datenmodell

Einzige Wahrheit: `$XDG_CONFIG_HOME/omarchy/autostart-layout.json`, Rechte
0600. Das Plugin erzeugt daraus alles andere und liest nie aus Hyprland
zurück, um zu wissen, was es will.

```json
{
  "schemaVersion": 1,
  "programs": [
    {
      "id": "p1",
      "name": "Cursor",
      "enabled": true,
      "command": "cursor",
      "class": "^(cursor)$",
      "placement": { "kind": "workspace", "value": "6" }
    },
    {
      "id": "p2",
      "name": "Modelbox",
      "enabled": true,
      "command": "modelbox",
      "class": "LM[- ]?Studio",
      "placement": { "kind": "monitor", "value": "HDMI-A-1" }
    }
  ],
  "workspaces": [
    { "workspace": "1", "monitor": "DP-4" },
    { "workspace": "6", "monitor": "HDMI-A-1" }
  ]
}
```

### `placement` ist ein Entweder-oder

Ein Workspace lebt auf **genau einem** Monitor. Sagt eine Fensterregel
„Workspace 2" und eine zweite „Monitor DP-4", während Workspace 2 auf DP-3
gepinnt ist, sind das nicht zwei Wünsche mit Vorrang, sondern zwei Aussagen,
von denen eine falsch sein muss. Eine Vorrangregel würde das verstecken.

- `kind: "workspace"` — Fenster auf Workspace N; sein Monitor ergibt sich aus
  `workspaces`. Normalfall.
- `kind: "monitor"` — Fenster auf den gerade aktiven Workspace des genannten
  Monitors. Für Fälle, in denen der Bildschirm zählt und die Nummer nicht.
- `kind: "none"` — nur Autostart, keine Platzierung.

Das Panel zeigt bei `workspace` den daraus folgenden Monitor als abgeleitete,
nicht editierbare Angabe.

### Felder

| Feld | Regel |
|---|---|
| `schemaVersion` | genau `1`; jeder andere Wert gilt als unlesbare Datei (§8) |
| `id` | plugin-erzeugt, eindeutig, `[a-z0-9]{1,16}` |
| `name` | Anzeigename, ≤ 100 Zeichen, geht **nicht** nach Lua |
| `enabled` | Boolean; neu angelegte Einträge stehen immer auf `false` |
| `command` | Kommandozeile ohne `uwsm-app --`-Präfix, ≤ 500 Zeichen |
| `class` | Hyprland-Klassenregex, ≤ 200 Zeichen, Zeichen-Erlaubnisliste (§6) |
| `placement.kind` | `workspace` \| `monitor` \| `none` |
| `placement.value` | bei `workspace` Ziffern 1–99; bei `monitor` ein Name aus `hl.get_monitors()` oder ein bereits konfigurierter |

## 5. Anwendungslogik

`kinds: ["bar-widget", "panel", "service"]`.

### Beim Sitzungsstart (`Service.qml`)

1. JSON begrenzt lesen, streng prüfen, Ungültiges verwerfen und melden.
2. Rechte prüfen: ist die Datei für Gruppe oder Welt beschreibbar, wird
   **nichts** angewandt (§6).
3. Regeln setzen: je Block ≤ 20 Regeln ein `hyprctl eval`, Nutzlast ≤ 64 KiB,
   höchstens 20 Aufrufe. Der Lua-Rumpf ruft `hl.workspace_rule{…}` und
   `hl.window_rule{…}`; vorher gesetzte Regeln des Plugins werden über ihren
   Namen abgeschaltet, damit sie sich nicht anhäufen (setzt offene Annahme 1
   aus §3 voraus; Rückfallweg dort benannt).
4. Autostart: für jedes `enabled`-Programm `uwsm-app -- <command>`,
   abgekoppelt mit `</dev/null >/dev/null 2>&1`. Ohne die Abkopplung reißt
   Quickshell die gestartete Anwendung beim Aufräumen seiner Pipes mit.
5. Startmarke `$XDG_RUNTIME_DIR/smartalb.autostart/$HYPRLAND_INSTANCE_SIGNATURE`
   schreiben. Existiert sie, wird Schritt 4 übersprungen — sonst startet
   `omarchy-restart-shell` die ganze Sitzung erneut. Die Bindung an die
   Instanzsignatur verhindert, dass eine echte neue Sitzung eine alte Marke
   findet.

### Bei `configreloaded`

Nur Schritte 1–3. Ein manuelles `hyprctl reload` des Nutzers wirft
Laufzeitregeln weg; dies setzt sie zurück. Programme bleiben unangetastet.

### Beim Speichern im Panel

Schritte 1–3, danach der Abgleich:

- **Workspaces:** `hl.get_workspaces()` liefert den Ist-Zustand; liegt ein
  bereits existierender Workspace auf dem falschen Monitor →
  `hl.dsp.workspace.move`. (Workspace-Regeln greifen nur beim *Anlegen*.)
- **Fenster:** die offenen Treffer werden über `grep -E` ermittelt (§5a) und
  jeder über seine **Adresse** verschoben. Der Umzug **muss** die Adresse in
  Lua erst auflösen und nur bei Erfolg verschieben:

      do local w = hl.get_window(<bytes>)
         if w then hl.dispatch(hl.dsp.window.move({ … window = w … })) end end

  **Und der Selektor darf keine Zeichenkette sein.** Ein zählendes Instrument
  (7 Versuche je Form, Abbruch beim ersten Kollateralschaden) hat am
  02.09.2026 in drei Läufen gezeigt: `hl.get_window("<hex>")` ist entweder
  wirkungslos (0/7) oder — als Objekt weitergegeben — trifft ab dem zweiten
  Versuch ein **fremdes** Fenster. Eine Auflösungswache hilft dagegen nicht,
  weil `w` nicht `nil` ist, sondern das falsche Fenster. Betroffen waren
  Chatterbox und zwei Termpane-Fenster des Benutzers.

  Deshalb wird das Fensterobjekt **aufgezählt und am Objekt verglichen**,
  nie über eine Zeichenkette adressiert:

      do for _, w in ipairs(hl.get_windows({})) do
           if w.address == <bytes> then
             hl.dispatch(hl.dsp.window.move({ … window = w … }))
           end
         end end

  Damit ist „kein Treffer" von der Bauweise her ein No-op. Diese Form ist zum
  Zeitpunkt dieser Fassung **noch nicht gemessen**; Task 1 muss sie belegen,
  bevor Task 11 sie benutzt. Belegt sie sich nicht, entfällt das Verschieben
  bereits offener Fenster ganz und die Platzierung greift erst beim nächsten
  Öffnen — als bekannte Grenze ins README.
- Der Abgleich startet **nichts**. Ein separater Knopf `[Launch missing]`
  startet die `enabled`-Programme, die noch nicht laufen. Speichern soll
  keine Fenster aufmachen.

## 5a. Dateiaufbau

```
smartalb.autostart/
|- manifest.json
|- BarWidget.qml          Glyph, Tooltip, oeffnet das Panel
|- Panel.qml              Oberflaeche; bindet Model.js, ruft die Helfer
|- Service.qml            Sitzungsstart, configreloaded-Abo, Startmarke
|- Runners.qml            die Aufruf-Helfer, von Panel und Service benutzt
|- Model.js               die gesamte Entscheidungslogik, reines JavaScript
|- bin/omarchy-autostart-config    read | write (stdin), 0600, atomar, mtime
|- bin/omarchy-autostart-apps      installierte .desktop-Eintraege als JSON
|- bin/omarchy-autostart-windows   offene Fenster, Workspaces, Klassen-Match
|- bin/omarchy-autostart-marker    Startmarke je Hyprland-Instanz beanspruchen
|- test/harness.qml, test/run-qml-tests.sh, test/run-tests.sh
|- README.md, LICENSE, preview.png, install, uninstall
```

Warum überhaupt Shell-Skripte, wenn die Logik in `Model.js` liegt: Das
Auflisten von Dateien und das Abfragen von Hyprland braucht ohnehin einen
`Process`. Dann ist es besser, das Kommando ist ein benanntes, getestetes
Skript als eine Zeichenkette in QML. Und es verschiebt genau die
sicherheitstragenden Teile — Rechteprüfung, atomares Schreiben, die
Obergrenzen beim Einlesen — an die am leichtesten prüfbare Stelle des
Projekts statt an die am schwersten prüfbare. Alle drei Skripte sind reine
Leser bzw. Schreiber ihrer eigenen Datei; keines ruft `hyprctl eval`, keines
startet ein Programm. Das Marker-Skript liegt aus demselben Grund dort: ein
Fehler darin verdoppelt die Sitzung, und in der Shell ist er prüfbar.

Das Klassen-Matching liegt ebenfalls in `bin/`, und zwar zwingend: die
Erlaubnisliste lässt `+ * ( ) |` zu, also verschachtelte Quantoren. Ein
Ausdruck wie `(a+)+$` gegen 500 Fensterklassen lässt eine
backtrackende Regex-Maschine hängen, und QML bietet für JavaScript kein
Zeitlimit. Gematcht wird deshalb in `grep -E`, dessen Automat linear läuft;
verschoben wird danach über die Fensteradresse, sodass der Regex nie nach Lua
gelangt. **`class` wird nirgends mit JavaScript-`RegExp` ausgewertet.**

## 6. Sicherheit

### Lua landet im Compositor

`hyprctl eval` führt Lua im laufenden Hyprland aus. `class` ist das einzige
Freitextfeld, dessen Inhalt dort ankommt. Zwei Schichten, die unabhängig
voneinander tragen:

**Schicht 1 — Prüfung.** Erlaubt sind nur Buchstaben, Ziffern, Leerzeichen
und `. _ - ^ $ ( ) | [ ] ? * + \ :`. Abgewiesen: `"` `'` `{` `}` `;` `=`,
Backtick, Zeilenumbruch, alles außerhalb ASCII. Länge ≤ 200.

Diese Prüfung läuft an **zwei Zeitpunkten**: im Panel beim Speichern und im
Dienst beim Anwenden. Es ist dieselbe Funktion aus `Model.js` — also nicht
zwei unabhängige Implementierungen, und das soll hier auch nicht behauptet
werden. Der Gewinn liegt im zweiten Zeitpunkt: eine zwischen beiden Momenten
von Hand bearbeitete Datei wird beim Anwenden erneut geprüft. Der Dienst
verlässt sich nicht darauf, vom eigenen Panel gefüttert worden zu sein.

Unabhängig von Schicht 1 ist **Schicht 2**: sie ist eine andere
Implementierung an einer anderen Stelle und trägt auch dann, wenn Schicht 1
einen Fehler hat.

**Schicht 2 — Kodierung.** Jeder Wert, der nach Lua geht, wird als
`string.char(94,40,99,…)` erzeugt, nie als Zeichenkette in
Anführungszeichen. Die Nutzlast besteht damit nur aus Ziffern und Kommata;
ein Ausbruch ist nicht abgewehrt, sondern nicht formulierbar. Schicht 1 fängt
Unsinn früh und verständlich ab und ist nicht sicherheitstragend.

**Keine Shell dazwischen.** Der Aufruf geht als argv-Liste über
`hypr()` (§6, Obergrenzen) — `timeout` ist keine Shell, es gibt also keine
zweite Zitierfrage.

### Die Stelle, die absichtlich Code ist

`command` **ist** eine Kommandozeile und wird als solche ausgeführt — dieselbe
Vertrauensstufe wie `~/.config/hypr/autostart.lua`. Sie wird nicht
„abgesichert", sondern:

- als *ein* argv-Element an `/usr/bin/bash -c` übergeben, nie in eine größere
  Kommandozeile eingesetzt;
- im README ausdrücklich als solche benannt.

Daraus folgt die wichtigste Einzelmaßnahme des Entwurfs: **die
Konfigurationsdatei wird 0600 und atomar geschrieben, und der Dienst
verweigert das Anwenden, wenn sie für Gruppe oder Welt beschreibbar ist.**
Ohne diese Prüfung wäre das Plugin ein bequemer Weg, über den ein anderes
Konto auf demselben Rechner Code in die Sitzung des Nutzers bekommt.

### Obergrenzen, alle vor dem ersten Aufruf

| Grenze | Wert | Grund |
|---|---|---|
| JSON-Lesung | 256 KiB, MAX+1 gelesen, bei Überlauf abgewiesen | unabhängig in Panel *und* Dienst |
| Programme | 200 | Laufzeit = Anzahl × Timeout |
| Workspace-Einträge | 99 | folgt aus 1–99 |
| Fenster aus `get_windows` | 500, gekappt vor dem Durchlaufen | Ausgabe ist nicht unsere |
| `.desktop`-Suche | 2000 Dateien, 64 KiB je Datei; gesucht wird in `$XDG_DATA_HOME/applications` und `$XDG_DATA_DIRS/*/applications`, nicht rekursiv | Verzeichnis ist nicht unser |
| `eval`-Aufruf | ≤ 20 Regeln, ≤ 64 KiB je Aufruf, ≤ 20 Aufrufe | argv-Länge, Prozessanzahl |

Diese Grenzen stehen **nicht an den Aufrufstellen**, sondern in vier Helfern.
Zwei Aufrufwege, bewusst getrennt:

**Ohne Shell** — alles, was mit Hyprland spricht:

- `hypr(verb, payload)` — argv-Liste
  `["/usr/bin/timeout", "-k", "5", "20", "/usr/bin/hyprctl", verb, payload]`.
  Keine Shell, also keine zweite Zitierfrage. Deadline 20 s. Beide Verben sind
  nötig und nicht austauschbar: `eval` führt einen Lua-Block aus (Regeln),
  `dispatch` nimmt einen Dispatcher-Ausdruck (Umzüge).

**Mit Shell** — nur der Autostart, weil `command` eine Kommandozeile ist und
die Abkopplung eine Umleitung braucht:

- `runner(cmd)` — `/usr/bin/timeout -k 5 120 /usr/bin/bash -c <cmd>`, absolute
  Pfade, Deadline 120 s;
- `runnerOut(cmd)` — wie `runner()`, zusätzlich `| head -c 262144` auf
  eingesammeltes stdout, damit der Erzeuger begrenzt ist und die Bytes nie
  gehalten werden;
- `runnerErr(cmd)` — dasselbe für stderr über Prozess-Substitution statt
  Pipe, weil eine Pipe den Exitstatus des Kommandos ersetzen würde und der
  Aufrufer ihn liest.

`Component.onDestruction` beendet jeden `Process`. Eine Grenze, die man an
jeder Aufrufstelle erinnern muss, wird an einer vergessen.

## 7. Oberfläche

### Bar-Widget

Nur ein Glyph, kein Text, im Quelltext als `\u`-Escape geschrieben — ein
literales Nerd-Font-Zeichen übersteht den Weg durch Dokumente und Werkzeuge
nicht zuverlässig, und ein leerer Text ist bei `BarIconButton` nicht „Knopf
ohne Symbol", sondern kein Knopf. Tooltip nennt den Stand
(„Autostart Layout — 6 programs, 4 placements"). Kein Zähler und kein
Warnpunkt im Balken.

### Panel

Eine Ebene, drei Bereiche; die Detailbearbeitung klappt an der Zeile auf.

```
┌ Autostart Layout ────────────────────────────────────┐
│  PROGRAMS                                    [+ Add]  │
│  ┌─────────────────────────────────────────────────┐  │
│  │ ☑  ● Cursor            Workspace 6 · HDMI-A-1 ▸ │  │
│  │ ☑  ● Modelbox         Monitor HDMI-A-1       ▸ │  │
│  │ ☐  ○ Seahorse          no placement           ▸ │  │
│  └─────────────────────────────────────────────────┘  │
│  WORKSPACE → MONITOR                    [+ Add]       │
│  ┌─────────────────────────────────────────────────┐  │
│  │   1  [DP-4        ▾]      6  [HDMI-A-1    ▾]   │  │
│  │   2  [DP-3        ▾]      9  [DP-2 (gone) ▾]   │  │
│  └─────────────────────────────────────────────────┘  │
│  ○ 2 enabled programs not running   [Launch missing]  │
│  ────────────────────────────────────────────────────  │
│  4 changes pending             [Revert]      [Apply]  │
└───────────────────────────────────────────────────────┘
```

Aufgeklappte Zeile: `Command`-Feld, `Class`-Feld mit `[From window]`, die drei
Platzierungsoptionen als Radiogruppe (bei `workspace` mit dem abgeleiteten
Monitor dahinter), Laufzustand und `[Remove]`.

### Entscheidungen

1. **`[Apply]` ist ausdrücklich, nicht beim Tippen.** Anwenden schiebt echte
   Fenster über echte Bildschirme. `[Revert]` verwirft. „n changes pending"
   macht ungespeicherten Zustand sichtbar.
2. **Der abgeleitete Monitor steht grau hinter der Workspace-Wahl** und
   ändert sich mit, wenn man die Tabelle unten ändert. Dort wird das
   Entweder-oder aus §4 verständlich.
3. **Monitore nur als Auswahlliste**, gefüllt aus `hl.get_monitors()`. Ein
   Freitextfeld wäre eine zweite Injektionsfläche ohne Gegenwert.
4. **Ein nicht angeschlossener Monitor wird als `DP-2 (gone)` angezeigt und
   bleibt stehen.** Wer sein Notebook aus der Dockingstation nimmt und das
   Panel öffnet, darf nicht durch bloßes Hinsehen seine Konfiguration
   verlieren. Der Eintrag ist wählbar, wird angewandt (Hyprland ignoriert ihn
   folgenlos) und verliert das `(gone)`, sobald der Bildschirm wieder da ist.
5. **Workspaces sind ganze Zahlen 1–99.** Benannte Workspaces entfallen in
   v1; das hält die Prüfung auf „nur Ziffern" reduzierbar. Ins README als
   bekannte Grenze.
6. **`[From window]` statt Klassen raten.** Zeigt die offenen Fenster aus
   `hl.get_windows()` mit Klasse und Titel; die Auswahl schreibt `^(…)$` mit
   dem wörtlich maskierten Klassennamen. Das Feld bleibt editierbar, weil ein
   Regex wie `LM[- ]?Studio` manchmal genau richtig ist.
7. **`[+ Add]` öffnet eine Auswahl über die installierten `.desktop`-Dateien.**
   Startbefehl aus `Exec=`, von den Feldcodes (`%U`, `%F`, `%i`, `%c`, `%k`)
   befreit; Klasse aus `StartupWMClass`, falls vorhanden, sonst leer mit
   `[From window]` als sichtbarer Lücke. Angelegt wird immer mit
   `enabled: false`.

### Leerer Erststart

`[Import current session]` übernimmt die aktuelle Workspace→Monitor-Belegung
aus `hl.get_workspaces()` und legt für jedes offene Fenster einen
Programmeintrag an — Klasse wörtlich aus dem Fenster, Startbefehl über einen
Abgleich der Klasse gegen `StartupWMClass` bzw. Dateinamen der
`.desktop`-Dateien, alles `enabled: false`. Der Knopf sagt, dass die Liste
danach durchzusehen und nicht fertig ist.

Dies ist das einzige Stück in v1, das raten enthält, und damit das Erste, was
gestrichen wird, falls der Umfang drückt. Ohne es ist ein leeres Panel die
erste Antwort des Plugins an einen neuen Nutzer.

## 8. Fehlerfälle

| Fall | Verhalten |
|---|---|
| Datei fehlt | leeres Modell, `[Import current session]` angeboten |
| Datei kein gültiges JSON / falsche `schemaVersion` | **nichts anwenden**, Fehler im Panel, Datei nicht überschrieben |
| Datei zu groß | dito, eigene Meldung |
| Datei fremdbeschreibbar | **nichts anwenden**, Meldung mit dem nötigen `chmod` |
| Einzelner Eintrag ungültig | Eintrag verworfen und **namentlich** gemeldet, Rest angewandt |
| `eval` antwortet nicht `ok` | Anwenden bricht ab und meldet; Gespeichertes bleibt gespeichert |
| Programm startet nicht | gemeldet, andere laufen weiter, kein Wiederholen |
| Monitor existiert nicht | angewandt, als `(gone)` angezeigt, kein Fehler |
| Zwei Programme, gleiche Klasse, verschiedene Platzierung | Speichern blockiert, beide benannt |
| Startmarke nicht schreibbar | Autostart wird **übersprungen** — eine verdoppelte Sitzung ist schlimmer als eine nicht gestartete |
| Datei hat sich seit dem Laden geändert | Warnung statt Überschreiben; Schreiben immer daneben + `mv` |

Der Unterschied zwischen Zeile 2 und Zeile 5 ist beabsichtigt: eine kaputte
Struktur lässt nicht erkennen, was der Nutzer will — da ist keine Regel besser
als eine halbe. Ein einzelner abgewiesener Eintrag ist eine benannte,
sichtbare Auslassung.

## 9. Tests

### Dünnes QML, prüfbarer Kern

Die gesamte Entscheidungslogik liegt in `Model.js` — reines JavaScript ohne
QML-API: Feldprüfung, Erzeugung der Lua-Nutzlast, Auflösung von `placement`
zum wirksamen Monitor, Widerspruchserkennung, die Obergrenzen auf Anzahlen,
das Befreien von `Exec=` von seinen Feldcodes, Soll/Ist-Vergleich für den
Abgleich. Das Anfassen von Dateien und Prozessen liegt in den drei
`bin/`-Skripten (§5a) — samt der Obergrenzen auf Bytes und Dateizahlen.
`BarWidget.qml` und `Panel.qml` binden nur Oberfläche daran und rufen die
Runner-Helfer. Die am schlechtesten prüfbare Datei ist damit auch die
dünnste — bei `smartalb.vpn` blieb der vierte Reviewer-Befund liegen, weil
`Panel.qml` das Gegenteil war.

### Läufer

- `test/run-qml-tests.sh` —
  `QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qml test/harness.qml`.
  Das Skript löst das Qt6-Binary auf und **scheitert**, wenn es es nicht
  findet; es fällt nie auf `/usr/bin/qml` zurück (Qt 5.15, endet ohne ein
  Wort mit Status 1).
- `test/run-tests.sh` — Shell-Tests für die drei `bin/`-Skripte aus §5a
  (bash, `jq`). Hier liegen die Tests für Rechteprüfung, atomares Schreiben,
  die 256-KiB-Grenze und die Kappungen beim Einlesen.

### Sandbox und Nähte

`setup_sandbox` biegt `HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME` **und**
`XDG_RUNTIME_DIR` um, plus ein Wachhund-Test, der prüft, dass jeder Pfad, in
den die Suite schreibt, unterhalb der Sandbox liegt.

Fernhalten geschieht über benannte Nähte (`HYPRCTL="${HYPRCTL:-hyprctl}"`,
`UWSM_APP`, `DESKTOP_DIRS`), nicht über PATH-Basteln — ein aufgeräumter PATH
schützt nichts, weil Omarchy auch in `/usr/bin` liegt.

Das gefälschte `hyprctl` protokolliert sein argv. Prüfbar sind damit: genau
*n* `eval`-Aufrufe, jeder ≤ 64 KiB, kein Block über 20 Regeln, die Nutzlast
enthält kein einziges Anführungszeichen, und der Aufruf kam als argv-Liste
ohne Shell.

### Mutationsproben

| Mutation | muss rot machen |
|---|---|
| `string.char`-Kodierung entfernen | Injektionstest |
| Erlaubnisliste um `"` erweitern | Prüfungstest |
| `head -c` aus `runnerOut()` entfernen | Erzeuger-Grenze |
| `Component.onDestruction` entfernen | Abbau-Test |
| Rechteprüfung entfernen | Fremdbeschreibbar-Test |
| Startmarke entfernen | Doppelstart-Test |
| Kappung vor dem Fenster-Durchlauf entfernen | Kardinalitäts-Test |
| `placement` beides zugleich erlauben | Entweder-oder-Test |

Jede Probe muss so gebaut sein, dass der geprüfte Pfad wirklich erreicht
wird. In #4346 bestand ein Rollback-Test, weil er vor dem ersten
Schreibvorgang scheiterte — es gab nichts zurückzurollen, und der Test war
trotzdem grün.

## 10. Repo und Veröffentlichung

Repo `SmartALB/omarchy-autostart-layout`, öffentlich, `main` geschützt.

**Arbeitsverzeichnis ist `~/repos/omarchy-autostart-layout`, nicht das
Plugin-Verzeichnis.** Quickshell hält ein `inotifywait -m -r` auf
`~/.config/omarchy/plugins`; jedes Anfassen einer Datei dort löst einen
Shell-Neustart aus und reißt laufende `Process`-Objekte mit. Wer dort
entwickelt, lädt die Shell des Nutzers hundertfach neu und macht jede eigene
Messung unzuverlässig. Für die Handprüfschritte kopiert `./install` in
`~/.config/omarchy/plugins/smartalb.autostart/` — genau der Fall, für den der
Installer die Unterscheidung zwischen `SOURCE` und `TARGET` hat.

Im Wurzelverzeichnis: `manifest.json`, `README.md`, `LICENSE` (MIT) und
`preview.png` **an der Wurzel** — dort sucht die Validierung; bei
`smartalb.vpn` gab es deshalb zunächst nur die Ersatzvorschau. `install`
kopiert, `uninstall` entfernt, und es gibt **keine `--system`-Stufe**, weil
es nichts Privilegiertes zu tun gibt.

**Deinstallation.** `uninstall` entfernt das Plugin-Verzeichnis und die
Startmarke, **nicht** die Konfigurationsdatei — sie ist Nutzerdaten, und eine
Neuinstallation soll die Liste wiederfinden. Das README nennt den Pfad, damit
man sie bewusst löschen kann. Zu beachten: bereits gesetzte Laufzeitregeln
leben bis zum nächsten Hyprland-Start weiter, denn sie stehen in keiner Datei,
die man entfernen könnte; das gilt genauso für ein bloßes Deaktivieren des
Plugins. Das README sagt es, statt einen Aufräummechanismus zu erfinden, den
niemand prüfen kann.

Vor der Einreichung: `omarchy plugin validate`,
`qmllint -I "$OMARCHY_PATH/shell"`, beide Suiten, und die Handprüfliste des
Develop-Guides (öffnen/schließen, Escape, deaktivieren/aktivieren,
entfernen). Der Einreichungstext nennt den Commit-SHA und sagt ausdrücklich,
dass keine privilegierte Operation existiert. Erwartetes Ergebnis der
automatischen Sicherheits-Baseline: nur `installer`.

Zwei Entwicklungsfallen ins README:

- Nach jeder QML-Änderung ist `omarchy-restart-shell` nötig. Die Zusage des
  Develop-Guides „saved changes reload automatically" gilt für Bar-Widgets
  nicht; die compilierte Komponente bleibt gecacht, und es gibt keine
  Fehlermeldung.
- Nach dem Anfassen einer Plugin-Datei erst ~8 s warten, bevor man messt —
  der inotify-Wächter lädt die Shell neu und reißt laufende
  `Process`-Objekte mit.

## 11. Was v1 nicht kann

- benannte Workspaces (nur 1–99),
- weitere Fensterregeln wie `float` oder `maximize`,
- mehrere Fenster derselben Klasse an verschiedene Orte,
- Anwendungen, deren Klasse erst nach dem ersten Start bekannt ist — die
  brauchen einmal `[From window]`.
