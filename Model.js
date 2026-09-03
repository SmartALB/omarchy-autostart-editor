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

// --- allowlists -----------------------------------------------------------
//
// The class field is the only free-text value that reaches Lua inside the
// compositor. This allowlist is layer one of two: it catches nonsense early
// and says so in words a person can act on. It is deliberately NOT the thing
// that makes injection impossible -- luaBytes() is, and it does not rely on
// this having run: every value crossing into a Lua chunk is re-encoded as
// string.char(...) bytes there, so a value this allowlist let through could
// still not close a quote or a brace. Two layers, and the second one is the
// one that holds.
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
    // A command ending in "&&", "||" or "|" is an incomplete shell command and
    // a syntax error in any context -- no wrapping can rescue it. Refusing it
    // by name is better than letting it reach the shell, where it would be one
    // more entry that fails at login with nobody watching.
    if (/(\|\||&&|\|)\s*$/.test(p.command))                return "command-incomplete";
    if (!isString(p["class"]) || !CLASS_RE.test(p["class"])) return "class-not-allowed";
    return placementProblem(p.placement);
}

function placementKey(placement) {
    if (!placement || placement.kind === "none") return "none";
    return placement.kind + ":" + placement.value;
}

function validate(config) {
    var out = { programs: [], workspaces: [], rejected: [], blocked: [] };
    var i, seenIds = Object.create(null), seenWs = Object.create(null);

    // A string has .length and bracket indexing, so a hand-edited
    // "programs": "cursor" would otherwise be walked character by character
    // and produce one meaningless rejection per letter. A present-but-wrong
    // value is named; an absent key is not an error at all.
    if (config && config.programs !== undefined && !Array.isArray(config.programs)) {
        out.rejected.push({ kind: "program", label: "programs", reason: "not-a-list" });
    }
    if (config && config.workspaces !== undefined && !Array.isArray(config.workspaces)) {
        out.rejected.push({ kind: "workspace", label: "workspaces", reason: "not-a-list" });
    }
    var programs   = (config && Array.isArray(config.programs))   ? config.programs   : [];
    var workspaces = (config && Array.isArray(config.workspaces)) ? config.workspaces : [];

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
    //
    // A plain {} is not safe as a map for strings that come from the
    // configuration: "__proto__" reads back as Object.prototype rather than
    // undefined, so the guard below would skip initialising the array and
    // .push would not exist. The class allowlist deliberately permits "_" --
    // real classes need it (nimbus-chat.example.org__-Default) -- so the map
    // has to tolerate it rather than the allowlist forbid it.
    var byClass = Object.create(null);
    for (i = 0; i < out.programs.length; i++) {
        var prog = out.programs[i];
        var key  = prog["class"];
        if (!byClass[key]) byClass[key] = [];
        byClass[key].push(prog);
    }
    for (var cls in byClass) {
        var group = byClass[cls], places = Object.create(null), labels = [];
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

// --- derived values -------------------------------------------------------

// The lowest workspace number the table does not use yet, as the string the
// schema stores. Bounded by MAX_WORKSPACES, which is why this lives here and
// not in the panel: the bound and the allowlist that has to agree with it are
// both in this file.
//
// When every number is taken it returns the last one rather than nothing. The
// row the panel then adds is a duplicate, validate() names it as
// "workspace-duplicate" and the user changes it -- a visible dead end, rather
// than a button that silently does nothing.
//
// A malformed row contributes whatever it stringifies to and therefore blocks
// no legal number; rows do not have to be valid to be counted, because this
// runs on a draft that is mid-edit by definition.
function firstFreeWorkspace(rows) {
    var used = Object.create(null), i;
    var list = rows || [];
    for (i = 0; i < list.length; i++) {
        used[String(list[i] && list[i].workspace)] = true;
    }
    for (i = 1; i <= MAX_WORKSPACES; i++) {
        if (used[String(i)] === undefined) return String(i);
    }
    return String(MAX_WORKSPACES);
}

// Every code bin/omarchy-autostart-config can answer with. Declared once so
// two halves can bind the class between them without either being a
// hand-copied claim: test/harness.qml requires every code IN HERE to have
// wording, and test/run-tests.sh requires THIS LIST to be exactly the codes
// grepped out of the script. Neither half alone would notice a code added to
// the script, and neither would notice wording quietly dropped.
// The codes the bin/ helpers can answer with, across BOTH of them:
// bin/omarchy-autostart-config and bin/omarchy-autostart-hypr. A shell
// assertion in test/run-tests.sh derives this list from the two scripts and
// fails if one turns up without wording, so this array is not allowed to be a
// hand-maintained mirror of them for long.
function envelopeCodes() {
    return ["bad-schema", "insecure-permissions", "internal", "not-a-file",
            "not-json", "stale", "too-large", "unreadable", "write-failed"];
}

// Plain wording for the envelope the bin/ helpers answer with. Every code
// bin/omarchy-autostart-config can emit has a sentence here; a shell
// assertion in test/run-tests.sh derives the code list FROM THAT SCRIPT and
// fails if one turns up without wording, so a code added there cannot reach
// the user as a bare identifier.
//
// This lived in Panel.qml one round after reasonText was moved out of it, for
// exactly the reason reasonText was moved: wording in QML is wording no suite
// in this project can execute.
//
// THE EMPTY CASE IS EXPLICIT, and it is not hypothetical. Empty stdout is what
// a missing script, a timeout kill, and any non-zero exit taken outside the
// script's own two reporters all look like from here -- the QML version
// printed the literal text "undefined: " for all of them.
function envelopeText(code, detail) {
    var extra = (detail === undefined || detail === null || String(detail) === "")
                ? "" : " " + String(detail);
    if (code === undefined || code === null || String(code) === "")
        return "The configuration helper gave no answer at all." + extra;
    if (code === "insecure-permissions")
        return "The configuration file can be written by someone else, so it was not used."
             + " Make it writable only by you." + extra;
    // Worded for both directions on purpose: read and write share
    // read_bounded in bin/omarchy-autostart-config, so this same code also
    // reaches a user who has just pressed Apply, where "too large to read"
    // would describe the wrong operation.
    if (code === "too-large")
        return "The configuration file is too large to handle." + extra;
    if (code === "not-json")
        return "The configuration file is not valid JSON, so nothing was changed." + extra;
    if (code === "bad-schema")
        return "The configuration file has a version this plugin does not understand." + extra;
    if (code === "stale")
        return "The file changed on disk since the panel read it."
             + " Close and reopen the panel, then apply again." + extra;
    if (code === "not-a-file")
        return "The configuration path is not a regular file; a symlink or a directory"
             + " there is refused." + extra;
    if (code === "write-failed")
        return "The configuration could not be written, so nothing was saved." + extra;
    if (code === "internal")
        return "The configuration helper could not build its answer." + extra;
    // bin/omarchy-autostart-hypr's own code. A file that exists but cannot be
    // read is NOT this -- that one is reported as absent, per file, so the
    // other two are still shown. This is the case where the read itself
    // failed partway through, which invalidates the whole envelope.
    if (code === "unreadable")
        return "One of your Hyprland configuration files could not be read,"
             + " so none of them is shown." + extra;
    // Named rather than shown bare, the same rule as reasonText's fallback.
    return "The configuration helper reported an unknown problem: " + String(code) + "." + extra;
}

// Plain wording for the reason codes validate() reports, so the omissions list
// is readable by the person who has to fix the entry rather than by whoever
// wrote the validator. Every code the functions above can produce has an entry
// here; test/harness.qml provokes them from real configurations and fails if
// one turns up without wording, so a new code cannot be added upstream and
// silently reach the user as a bare identifier.
//
// An unknown code is passed through unchanged rather than guessed at.
function reasonText(code) {
    if (code === "not-a-list")          return "this is not a list";
    if (code === "not-an-object")       return "this entry is not an object";
    if (code === "id-invalid")          return "the internal id is malformed";
    if (code === "id-duplicate")        return "two entries share one id";
    if (code === "name-invalid")        return "the name is empty or too long";
    if (code === "enabled-invalid")     return "the on/off value is not true or false";
    if (code === "command-invalid")     return "the command is empty or too long";
    if (code === "command-incomplete")  return "the command ends in &&, || or | and cannot run";
    if (code === "class-not-allowed")   return "the window class pattern is not allowed";
    if (code === "placement-invalid")   return "the placement is not allowed";
    if (code === "workspace-invalid")   return "the workspace number or monitor name is not allowed";
    if (code === "workspace-duplicate") return "this workspace is listed twice";
    if (code === "too-many")            return "there are too many entries";
    // The blocked channel's own reason, and the likeliest of the whole set to
    // actually happen: two entries for one window class with different places
    // is the natural mistake the either-or placement rule invites. The wording
    // has to say what to DO, because unlike every code above this one stops
    // the save rather than dropping one entry -- there is nothing the user can
    // ignore their way past.
    //
    // Worded to read after a list of labels, which is the only frame it ever
    // appears in ("Nimbus A, Nimbus B: these match ...").
    if (code === "class-conflict")
        return "these match the same window class but want different places -- "
             + "one of the two placements has to go";
    return String(code);
}

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
//
// This does not track quoting, so a field code inside a quoted argument is
// stripped too (the freedesktop specification explicitly leaves that case
// undefined) and the whitespace collapse below can turn a double space
// inside a quoted argument into a single one. Accepted: the collapse is what
// cleans up the gap a removed code leaves behind, and a deliberate double
// space inside a quoted Exec= argument is essentially unheard of.
function stripFieldCodes(exec) {
    var known = Object.create(null);
    known["f"] = 1; known["F"] = 1; known["u"] = 1; known["U"] = 1;
    known["d"] = 1; known["D"] = 1; known["n"] = 1; known["N"] = 1;
    known["i"] = 1; known["c"] = 1; known["k"] = 1; known["v"] = 1; known["m"] = 1;
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

// --- adding entries -------------------------------------------------------
//
// The three ways a program gets into the list -- picked from the installed
// application list, picked from an open window, imported from the session --
// all end here rather than in Panel.qml: every one of them derives something
// (a free id, a pattern, a command, a whole configuration), and a derivation
// in QML is a derivation no suite in this project can execute.

// The lowest free "p<n>". ID_RE is checked rather than assumed: it is the
// rule validate() will judge the entry by, and a change to it that this
// generator did not follow would otherwise produce entries the panel refuses
// the moment it creates them. What holds that claim is not this check --
// "p<n>" satisfies ID_RE whatever the check does -- but the assertion that
// walks 60 consecutive ids through validate(), which goes red the moment the
// candidate shape changes. See test/harness.qml.
//
// The list this is handed is a DRAFT's program list, which comes from a file a
// human may have edited: `null` is a shape validate() names by itself
// ("not-an-object"), so it must not throw here either. Reading `.id` off null
// is a TypeError, and it would take the whole add or import with it.
function newId(existing) {
    var used = Object.create(null), i;
    for (i = 0; i < (existing || []).length; i++) {
        var entry = existing[i];
        if (entry && typeof entry === "object") used[entry.id] = true;
    }
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
    // AN EMPTY CLASS IS REFUSED, and not because the allowlist would catch it:
    // it would not. "^()$" satisfies CLASS_RE, and as a Hyprland match it says
    // "a class that is the empty string" -- a pattern that identifies no
    // particular window and, put through a matcher, is answered by whatever
    // reports no class at all. A window can genuinely have none (Wayland
    // app_id is set by the client, or not), so this is a real input, not a
    // hypothetical one. The message says what to do instead, because this is
    // the one refusal a user reaches by clicking rather than by typing.
    if (String(windowClass) === "") {
        throw new Error("classLiteral: refusing an empty window class -- it cannot"
                        + " identify a window; type the class by hand or pick another window");
    }
    var escaped = String(windowClass).replace(/[.^$()|\[\]?*+\\:-]/g, "\\$&");
    var pattern = "^(" + escaped + ")$";
    if (!CLASS_RE.test(pattern)) {
        throw new Error("classLiteral: refusing " + windowClass);
    }
    return pattern;
}

// The command a window's class suggests, or "" when nothing does. String()
// around every value read out of the app list: the list is built from files
// this plugin does not own, and an entry whose Exec= went missing would
// otherwise throw inside stripFieldCodes and take the whole import with it.
function guessCommand(windowClass, apps) {
    var wanted = String(windowClass).toLowerCase(), i;
    var list = apps || [];
    for (i = 0; i < list.length; i++) {
        if (list[i] && list[i].wmclass && String(list[i].wmclass).toLowerCase() === wanted) {
            return stripFieldCodes(String(list[i].exec === undefined ? "" : list[i].exec));
        }
    }
    // Second pass: the leading word of Exec often IS the class.
    for (i = 0; i < list.length; i++) {
        var exec = stripFieldCodes(String((list[i] && list[i].exec) === undefined ? "" : list[i].exec));
        var first = exec.split(" ")[0];
        if (first && first.toLowerCase() === wanted) return exec;
    }
    return "";
}

// One entry built from a picked .desktop application.
//
// Everything the panel would otherwise decide for itself is here: the free
// id, the length cap the schema enforces, the field codes that must never
// reach a shell, and the class pattern. It arrives DISABLED -- putting a
// program in the list is not the same act as switching it on.
//
// An application with no usable StartupWMClass gets an EMPTY class rather
// than one guessed from its name: validate() then names the entry as left
// out and the row says so on screen, which is a dead end the user can close
// with [From window]. A guessed class would match nothing -- or something
// else -- and say nothing at all.
function programFromApp(app, existing) {
    var source = app || {};
    var pattern = "";
    if (source.wmclass) {
        try { pattern = classLiteral(source.wmclass); } catch (e) { pattern = ""; }
    }
    return {
        id: newId(existing),
        name: String(source.name === undefined ? "" : source.name).substring(0, MAX_NAME),
        enabled: false,
        command: stripFieldCodes(String(source.exec === undefined ? "" : source.exec)),
        "class": pattern,
        placement: { kind: "none" }
    };
}

// The first-run import. Everything arrives disabled: a list the user has only
// just seen must not open by itself at the next login. A window whose class
// cannot be encoded is skipped rather than aborting the whole import -- one odd
// window should not cost the other twenty.
//
// THE COMMAND IS NEVER GUESSED FROM THE CLASS. An earlier version of this
// function fell back to the class name when guessCommand found nothing, and
// that was an injection path, measured end to end: a window class is set by
// the client, so a window calling itself `$(reboot)` imported as an entry
// whose COMMAND was `$(reboot)`. The class pattern is escaped and that path is
// defended; the command cannot be, because the command field is a shell
// command line by design -- launchCommand renders it verbatim. No allowlist
// can rescue that, so the value simply never comes from the window.
//
// The entry is still imported, with an empty command. validate() names it
// "command-invalid", the row says so on screen (task 15), and the user types
// the command -- which is exactly the situation: the plugin could not map this
// window to a program, and only the user knows what started it. Dropping the
// entry instead would hide the window that most needs attention; a
// plausible-looking wrong command would hide that it was ever a guess.
function importFromSession(windows, workspacesNow, apps) {
    var config = { schemaVersion: 1, programs: [], workspaces: [] };
    // Object.create(null), not {}: a window whose class is "__proto__" would
    // read back as already-seen from a plain object and be skipped silently.
    var seen = Object.create(null), i;

    for (i = 0; i < (workspacesNow || []).length; i++) {
        var row = workspacesNow[i];
        // The same shape guard as newId's, for the same reason: a row that is
        // not an object is a shape validate() names, not one that may throw.
        if (!row || typeof row !== "object") continue;
        if (WORKSPACE_RE.test(row.workspace) && MONITOR_RE.test(row.monitor)) {
            config.workspaces.push({ workspace: row.workspace, monitor: row.monitor });
        }
    }

    for (i = 0; i < (windows || []).length; i++) {
        var window = windows[i];
        if (!window || typeof window !== "object") continue;
        if (seen[window["class"]]) continue;
        var pattern, command;
        try { pattern = classLiteral(window["class"]) } catch (e) { continue }
        // The only source for a command is the installed application list.
        // When nothing there matches, the field stays empty -- see the note
        // above this function.
        command = guessCommand(window["class"], apps);
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

// What to tell the user about an application list that did not arrive whole.
//
// Two facts, three outcomes, and they are NOT interchangeable: "too long" is
// something a user can act on and "broken" is not, and the previous round
// could only say the second one because the panel threw away the marker that
// distinguishes them. "" means nothing went wrong and nothing is said.
//
// Here rather than in Panel.qml for the reason reasonText and envelopeText are
// here: wording in QML is wording no suite in this project can execute, and
// this one is not merely wording -- it is a decision over two inputs.
//
// The substring Panel.qml looks for on stderr is Runners.qml's own truncation
// marker; test/qml-structure.sh binds those two files together so a reworded
// marker cannot silently stop being recognised.
function appsProblem(unparseable, truncated) {
    if (unparseable && truncated) {
        return "The list of installed applications is too long to read in full, so it"
             + " could not be used. Nothing else is affected.";
    }
    if (unparseable) {
        return "Could not read the list of installed applications.";
    }
    if (truncated) {
        // Parsed, but cut short: the picker works and is incomplete, which is a
        // third thing again -- saying "broken" here would be false and saying
        // nothing would leave an application mysteriously absent from the list.
        return "The list of installed applications was cut short, so an application"
             + " may be missing from it.";
    }
    return "";
}

// Is there anything in this configuration at all? The panel offers
// [Import current session] only for an empty one and refuses the import
// otherwise, and BOTH lists have to be empty for that: the import returns a
// whole configuration, workspace table included, so running it over a draft
// that has workspace rows but no programs would discard them.
//
// Here rather than in Panel.qml because it is the condition on a destructive
// action, and a condition in QML is one no suite in this project can execute.
function isEmptyConfig(config) {
    var programs   = (config && config.programs)   || [];
    var workspaces = (config && config.workspaces) || [];
    return programs.length === 0 && workspaces.length === 0;
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
    // The braces are load-bearing. The command field is a shell command
    // line, so it may contain `&&`, `;` or a pipe -- and a redirection
    // binds only to the last command of such a chain. Without the group,
    // `sleep 2 && myapp` would leave `sleep 2` holding Quickshell's
    // stdout and stderr, and Quickshell tears those down when the chain
    // ends, taking the application with it. Grouping also makes the
    // entries safe to join with `&` when several are launched at once.
    //
    // Terminated by a newline, not by "; ": a command ending in "&", ";" or a
    // trailing #comment is a legitimate shell command line, and "; }" after it
    // is a syntax error -- the group then never runs and the program never
    // starts, silently. A newline closes the list in every one of those cases.
    return "{ uwsm-app -- " + command + "\n} </dev/null >/dev/null 2>&1";
}

// Workspace rules only take effect when a workspace is CREATED, so a workspace
// that already exists has to be moved explicitly. One that does not exist yet
// is left alone -- the rule will place it when it appears.
function workspaceMoves(model, workspacesNow) {
    var wanted = (model && model.workspaces) || [];
    var now = workspacesNow || [];
    var current = Object.create(null), moves = [], i;
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

    // Object.create(null), not {} -- the same reason as everywhere else in
    // this file. ID_RE forbids the underscore in "__proto__", so a plain {}
    // would in fact be safe for this particular map today, but that safety
    // would depend on a fact living in a different function; keeping every
    // map in this file prototype-less is what makes that reasoning
    // unnecessary to redo on every read.
    var byId = Object.create(null);
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
    // Object.create(null) rather than {} -- see the note in validate(): a key
    // of "__proto__" reads back as Object.prototype from a plain object.
    var seen = Object.create(null), out = [], i;
    var hits = matches || [];
    for (i = 0; i < hits.length; i++) seen[hits[i].id] = true;
    var programs = (model && model.programs) || [];
    for (i = 0; i < programs.length; i++) {
        if (programs[i].enabled && !seen[programs[i].id]) out.push(programs[i].id);
    }
    return out;
}

// Single-quote for bash -c. Inside single quotes a shell metacharacter is
// inert; the only thing to handle is the quote itself.
function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

// ==========================================================================
// THE CUTOVER
// ==========================================================================
//
// ONE place, named once, read everywhere. The plugin's old half -- the JSON
// configuration under ~/.config/omarchy/autostart-layout.json and the
// `hyprctl eval` route that applied it at runtime -- is DISCONNECTED here,
// not deleted.
//
// Why disconnected and not deleted: the writer does not exist yet, and that
// code is the reference the writer is built from (the chunking, the byte
// encoding, the generation discipline, the start marker). Deleting it now
// would mean writing it twice.
//
// Why disconnected at all: two sources of truth for the same fact -- which
// program goes on which workspace -- is precisely what this change of
// direction exists to end. From here on the truth is the user's own
// ~/.config/hypr/*.lua, which Hyprland already applies at login by itself.
//
// WHERE THE PLUGIN'S EFFECT COMES FROM IN THE MEANTIME: from Hyprland, not
// from this plugin. hyprland.lua already requires hypr.autostart,
// hypr.workspaces and hypr.windowrules, so every rule in those files keeps
// working exactly as before, untouched. What the plugin does until the
// writer lands is show that configuration truthfully.
//
// Both readers of this flag -- Panel.qml (offers nothing) and Service.qml
// (applies nothing) -- consult THIS constant. Do not add a second switch.
var WRITE_PATH_ENABLED = false;

// ==========================================================================
// THE READER FOR THE USER'S HYPRLAND LUA FILES
// ==========================================================================
//
// Three hand-maintained files, with German section comments and factual
// notes in them. This reader NEVER writes. What it must guarantee is the
// foundation the later line surgery rests on:
//
//   * every entry carries `line` (1-based) and `raw` (the line verbatim),
//   * a line that calls a known helper in a form this code cannot take
//     apart is returned as an entry with editable:false and a filled `raw`
//     -- never guessed at, never silently dropped,
//   * a line that calls no known helper is not an entry at all. It stays
//     part of the file and is the writer's business, not the reader's.
//
// Parsing is LINE BY LINE. No regular expression here ever sees more than
// one line, and none of them nests a quantifier inside a quantifier: the
// input is a file this plugin does not own, and a parser that can be made
// to run for minutes over 31 lines is a defect, not a curiosity.
//
// The helpers are defined in /usr/share/omarchy/default/hypr/helpers.lua:
//   o.launch(c)            = "uwsm-app -- " .. c
//   o.exec_on_start(c)     runs c at hyprland.start
//   o.launch_on_start(c)   = o.exec_on_start(o.launch(c))
// which is why `o.launch_on_start("nimbus")` and
// `o.exec_on_start(o.launch("nimbus"))` are the SAME fact and are reported
// identically, with `launcher: "uwsm-app"`.

var HYPR_FILE_NAMES = ["autostart.lua", "windowrules.lua", "workspaces.lua"];

// A file this reader looks at is small and hand-written. The cap is here so
// that a pathological input costs a bounded amount of work rather than
// however much it feels like: the bin/ script already caps the bytes, this
// caps the lines it is worth turning into entries.
var MAX_HYPR_LINES = 2000;

// The window-rule options this reader can represent, and therefore the only
// ones a later writer may rewrite. Everything else -- opacity, size, tag,
// center, tile, idle_inhibit, suppress_event and the rest of Hyprland's
// vocabulary, all of which occur in Omarchy's own default configuration --
// makes the line non-editable. That is the honest answer: a rewrite that
// dropped an option it did not understand would silently change the user's
// desktop.
var WINDOW_FLAG_KEYS = ["float", "maximize", "fullscreen"];

function isWindowFlagKey(key) {
    for (var i = 0; i < WINDOW_FLAG_KEYS.length; i++) {
        if (WINDOW_FLAG_KEYS[i] === key) return true;
    }
    return false;
}

// Why an entry could not be taken apart. Codes, never shown raw -- see
// hyprReasonText, and the same two-sided guarantee the envelope codes have:
// this list is what the parsers can set, and the harness proves every one of
// them has wording.
var HYPR_REASONS = [
    "nested-call",           // o.exec_on_start(o.launch_webapp_sole(...))
    "not-a-string",          // an argument that is not a plain Lua string
    "table-match",           // o.window({ class = ..., title = ... }, ...)
    "unsupported-option",    // a rules key this reader cannot represent
    "missing-option",        // no workspace / no monitor to show
    "value-out-of-range",    // a workspace or monitor outside the allowlist
    "incomplete-call"        // the call does not end on this line
];

function hyprReasons() { return HYPR_REASONS.slice(); }

function hyprReasonText(code) {
    // THE EMPTY REASON, and it is the same defect envelopeText was fixed for:
    // falling through to the named-code fallback with nothing to name prints
    // the literal word "undefined" at the user. An entry can only reach the
    // panel with editable:false and a reason set, so this is a belt -- but it
    // is the belt whose absence was, once, the whole visible error message.
    if (code === undefined || code === null || String(code) === "") {
        return "This line cannot be represented by this panel, and no reason "
             + "was recorded for it.";
    }
    switch (code) {
    case "nested-call":
        return "This line wraps another helper call, which cannot be taken "
             + "apart into a command. It is shown exactly as it stands.";
    case "not-a-string":
        return "An argument on this line is not a plain quoted string, so it "
             + "cannot be read as a value.";
    case "table-match":
        return "This rule matches on a table of properties (class and title, "
             + "for instance) rather than on a single class pattern.";
    case "unsupported-option":
        return "This rule sets an option this panel cannot represent, so it "
             + "is left exactly as it is.";
    case "missing-option":
        return "This rule does not say which workspace or monitor it means.";
    case "value-out-of-range":
        return "A workspace number or monitor name on this line lies outside "
             + "what this panel accepts.";
    case "incomplete-call":
        return "This call does not end on its own line; only whole one-line "
             + "calls can be read.";
    }
    return "This line cannot be represented by this panel: " + String(code) + ".";
}

// --- Lua string literals --------------------------------------------------
//
// Decoded, not copied. `"(nimbus-chatgpt\\.com__-Default)"` in the file is
// the characters `(nimbus-chatgpt\.com__-Default)` in the compositor, and
// that is what the panel has to show and what CLASS_RE has to judge. The
// verbatim form is preserved anyway -- it is in `raw`.
//
// A character loop, not a regular expression. An escape-aware quoted-string
// regex is the classic place a nested quantifier goes quadratic, and this
// input is a file this plugin does not own.
//
// Returns { value: <decoded>, next: <index after the closing quote> } or
// null. Null means "this reader does not understand it", which upstream
// becomes editable:false -- never a guess.
var LUA_SIMPLE_ESCAPES = {
    "a": "\u0007", "b": "\b", "f": "\f", "n": "\n", "r": "\r",
    "t": "\t", "v": "\u000b", "\\": "\\", "\"": "\"", "'": "'"
};

function luaStringAt(line, start) {
    var quote = line.charAt(start);
    if (quote !== "\"" && quote !== "'") return null;
    var out = "";
    var i = start + 1;
    while (i < line.length) {
        var c = line.charAt(i);
        if (c === quote) return { value: out, next: i + 1 };
        if (c !== "\\") { out += c; i += 1; continue; }
        // An escape. A backslash as the last character on the line is an
        // unterminated literal or Lua's line continuation -- neither is
        // something this reader claims to understand.
        if (i + 1 >= line.length) return null;
        var e = line.charAt(i + 1);
        if (LUA_SIMPLE_ESCAPES.hasOwnProperty(e)) {
            out += LUA_SIMPLE_ESCAPES[e];
            i += 2;
            continue;
        }
        if (e === "x") {
            var hex = line.substr(i + 2, 2);
            if (!/^[0-9A-Fa-f][0-9A-Fa-f]$/.test(hex)) return null;
            out += String.fromCharCode(parseInt(hex, 16));
            i += 4;
            continue;
        }
        if (e >= "0" && e <= "9") {
            // Up to three decimal digits, Lua's \ddd.
            var digits = "";
            var j = i + 1;
            while (j < line.length && digits.length < 3
                   && line.charAt(j) >= "0" && line.charAt(j) <= "9") {
                digits += line.charAt(j);
                j += 1;
            }
            var code = parseInt(digits, 10);
            if (code > 255) return null;
            out += String.fromCharCode(code);
            i = j;
            continue;
        }
        // \z (skip whitespace), or anything Lua itself would reject.
        return null;
    }
    // Ran off the end of the line without a closing quote.
    return null;
}

// The whole of `text` as one Lua string, or null.
function luaStringWhole(text) {
    var s = String(text);
    var parsed = luaStringAt(s, 0);
    if (!parsed) return null;
    if (parsed.next !== s.length) return null;
    return parsed.value;
}

// --- flat Lua tables ------------------------------------------------------
//
// `{ workspace = "1", float = true, maximize = true }` and nothing cleverer.
// A nested table (`size = { 875, 600 }`), a positional element, a function
// call, an identifier as a value: all null, all editable:false upstream. The
// point is not to parse Lua; it is to know exactly when this reader does NOT
// understand a line.
//
// Returns an array of { key, value, type } in file order, or null.
function luaFlatTable(text) {
    var s = String(text);
    if (s.charAt(0) !== "{" || s.charAt(s.length - 1) !== "}") return null;
    var body = s.substring(1, s.length - 1);
    var out = [];
    var i = 0;
    while (i < body.length) {
        while (i < body.length && (body.charAt(i) === " " || body.charAt(i) === "\t")) i += 1;
        if (i >= body.length) break;
        // The key. Anchored and bounded, no nested quantifier.
        var keyMatch = /^[A-Za-z_][A-Za-z0-9_]{0,63}/.exec(body.substring(i));
        if (!keyMatch) return null;
        var key = keyMatch[0];
        i += key.length;
        while (i < body.length && (body.charAt(i) === " " || body.charAt(i) === "\t")) i += 1;
        if (body.charAt(i) !== "=") return null;
        i += 1;
        while (i < body.length && (body.charAt(i) === " " || body.charAt(i) === "\t")) i += 1;
        var c = body.charAt(i);
        if (c === "\"" || c === "'") {
            var str = luaStringAt(body, i);
            if (!str) return null;
            out.push({ key: key, value: str.value, type: "string" });
            i = str.next;
        } else {
            var word = /^(true|false|[0-9]{1,10})/.exec(body.substring(i));
            if (!word) return null;
            if (word[0] === "true" || word[0] === "false") {
                out.push({ key: key, value: word[0] === "true", type: "boolean" });
            } else {
                out.push({ key: key, value: parseInt(word[0], 10), type: "number" });
            }
            i += word[0].length;
        }
        while (i < body.length && (body.charAt(i) === " " || body.charAt(i) === "\t")) i += 1;
        if (i >= body.length) break;
        if (body.charAt(i) !== ",") return null;
        i += 1;
    }
    return out;
}

// --- the shape every line goes through ------------------------------------
//
// A recognised helper call must be the WHOLE statement on its line: the
// opening parenthesis right after the name, the matching close at the end,
// and nothing after it but whitespace and at most one semicolon. Anything
// else -- a call continued on the next line, a trailing `-- note` after the
// code -- becomes an entry with editable:false rather than a rewrite that
// would eat the note.
//
// Returns { name, args, reason } or null. Null means the line calls nothing
// this reader knows, and a line like that is not an entry at all.
function hyprCallOnLine(line, names) {
    var s = String(line);
    var lead = /^[ \t]*/.exec(s)[0];
    var body = s.substring(lead.length);
    var name = null;
    for (var i = 0; i < names.length; i++) {
        var candidate = names[i];
        if (body.substring(0, candidate.length) !== candidate) continue;
        if (!/^[ \t]*\(/.test(body.substring(candidate.length))) continue;
        name = candidate;
        break;
    }
    if (name === null) return null;

    var afterName = body.substring(name.length);
    var inner = afterName.substring(afterName.indexOf("(") + 1);

    // Strip the trailing `)` plus an optional `;` and whitespace. Parentheses
    // are not balance-counted: what matters is that the statement ENDS here,
    // and a call that does not is reported as incomplete rather than
    // reconstructed. The `.*` is greedy and matches within one line only, so
    // the last `)` on the line is the one taken.
    var tail = /^(.*)\)[ \t]*;?[ \t]*$/.exec(inner);
    if (!tail) return { name: name, args: null, reason: "incomplete-call" };
    return { name: name, args: tail[1].replace(/^[ \t]+/, "").replace(/[ \t]+$/, ""),
             reason: null };
}

function hyprEntry(file, lineNumber, raw, name, kind) {
    return { file: file, line: lineNumber, raw: raw, fn: name, kind: kind,
             editable: false, reason: null };
}

// Line splitting for all three parsers. `raw` is the element of THIS array
// at index line-1, which is the round-trip guarantee the writer rests on --
// comment lines and blank lines are counted like every other line, because a
// parser that skipped them would shift every entry below by however many it
// skipped.
function hyprLines(text) {
    return String(text === undefined || text === null ? "" : text).split("\n");
}

// --- autostart.lua --------------------------------------------------------
//
// Recognised, and reported as the SAME fact:
//   o.launch_on_start("notes-app")
//   o.exec_on_start(o.launch("notes-app"))     -- helpers.lua:118-120
// both give launcher "uwsm-app" and command "notes-app".
//
// Recognised as its own form:
//   o.exec_on_start("some-command")                  -- launcher "shell"
//
// Deliberately NOT editable, and this is the case the brief names:
//   o.exec_on_start(o.launch_webapp_sole("Chat", "https://chat.example.org/"))
// A nested two-argument helper whose result is a shell line built inside
// Lua. Showing it and refusing to rewrite it is the whole point.
var AUTOSTART_CALLS = ["o.launch_on_start", "o.exec_on_start"];

function parseAutostartLua(text, fileName) {
    var name = fileName || "autostart.lua";
    var lines = hyprLines(text);
    var entries = [];
    var limit = Math.min(lines.length, MAX_HYPR_LINES);
    for (var n = 0; n < limit; n++) {
        var raw = lines[n];
        var call = hyprCallOnLine(raw, AUTOSTART_CALLS);
        if (!call) continue;
        var entry = hyprEntry(name, n + 1, raw, call.name, "autostart");
        if (call.reason) { entry.reason = call.reason; entries.push(entry); continue; }

        var direct = luaStringWhole(call.args);
        if (direct !== null) {
            entry.editable = true;
            entry.command = direct;
            entry.launcher = (call.name === "o.launch_on_start") ? "uwsm-app" : "shell";
            entries.push(entry);
            continue;
        }
        // The one nested form helpers.lua makes exactly equivalent.
        var wrapped = /^o\.launch[ \t]*\((.*)\)$/.exec(call.args);
        if (call.name === "o.exec_on_start" && wrapped) {
            var inner = luaStringWhole(wrapped[1].replace(/^[ \t]+/, "").replace(/[ \t]+$/, ""));
            if (inner !== null) {
                entry.editable = true;
                entry.command = inner;
                entry.launcher = "uwsm-app";
                entries.push(entry);
                continue;
            }
        }
        entry.reason = /^o\.[A-Za-z_]/.test(call.args) ? "nested-call" : "not-a-string";
        entries.push(entry);
    }
    return entries;
}

// --- windowrules.lua ------------------------------------------------------
//
// Recognised:
//   o.window("(notes-app)", { workspace = "2" })
//   o.window("^(Playwright-E2E-Test)$", { workspace = "1", float = true, maximize = true })
//
// Deliberately NOT editable:
//   o.window({ class = "...", title = "..." }, { ... })     table-match
//   o.window(".*", { tag = "+default-opacity" })            unsupported-option
//   o.window({ title = ".*is sharing.*" }, { workspace = "special silent" })
function parseWindowRulesLua(text, fileName) {
    var name = fileName || "windowrules.lua";
    var lines = hyprLines(text);
    var entries = [];
    var limit = Math.min(lines.length, MAX_HYPR_LINES);
    for (var n = 0; n < limit; n++) {
        var raw = lines[n];
        var call = hyprCallOnLine(raw, ["o.window"]);
        if (!call) continue;
        var entry = hyprEntry(name, n + 1, raw, call.name, "window");
        if (call.reason) { entry.reason = call.reason; entries.push(entry); continue; }

        var args = call.args;
        if (args.charAt(0) === "{") { entry.reason = "table-match"; entries.push(entry); continue; }
        var first = luaStringAt(args, 0);
        if (!first) { entry.reason = "not-a-string"; entries.push(entry); continue; }
        var after = args.substring(first.next).replace(/^[ \t]+/, "");
        if (after.charAt(0) !== ",") { entry.reason = "not-a-string"; entries.push(entry); continue; }
        var rulesText = after.substring(1).replace(/^[ \t]+/, "").replace(/[ \t]+$/, "");
        var pairs = luaFlatTable(rulesText);
        if (!pairs) { entry.reason = "unsupported-option"; entries.push(entry); continue; }

        entry["class"] = first.value;
        var workspace = null, flags = {}, unsupported = false;
        for (var p = 0; p < pairs.length; p++) {
            var key = pairs[p].key;
            if (key === "workspace" && pairs[p].type === "string") {
                workspace = pairs[p].value;
            } else if (isWindowFlagKey(key) && pairs[p].type === "boolean") {
                flags[key] = pairs[p].value;
            } else {
                unsupported = true;
            }
        }
        if (unsupported) { entry.reason = "unsupported-option"; entries.push(entry); continue; }
        if (workspace === null) { entry.reason = "missing-option"; entries.push(entry); continue; }
        // The same allowlists the rest of this file judges by. A workspace
        // Hyprland accepts but this panel does not represent ("special
        // silent") is shown and left alone rather than quietly narrowed.
        if (!WORKSPACE_RE.test(workspace) || !CLASS_RE.test(first.value)) {
            entry.reason = "value-out-of-range";
            entries.push(entry);
            continue;
        }
        entry.editable = true;
        entry.workspace = workspace;
        entry.flags = flags;
        entries.push(entry);
    }
    return entries;
}

// --- workspaces.lua -------------------------------------------------------
//
// Recognised:
//   hl.workspace_rule({ workspace = "1", monitor = "DP-4" })
function parseWorkspacesLua(text, fileName) {
    var name = fileName || "workspaces.lua";
    var lines = hyprLines(text);
    var entries = [];
    var limit = Math.min(lines.length, MAX_HYPR_LINES);
    for (var n = 0; n < limit; n++) {
        var raw = lines[n];
        var call = hyprCallOnLine(raw, ["hl.workspace_rule"]);
        if (!call) continue;
        var entry = hyprEntry(name, n + 1, raw, call.name, "workspace");
        if (call.reason) { entry.reason = call.reason; entries.push(entry); continue; }

        var pairs = luaFlatTable(call.args);
        if (!pairs) { entry.reason = "not-a-string"; entries.push(entry); continue; }
        var workspace = null, monitor = null, unsupported = false;
        for (var p = 0; p < pairs.length; p++) {
            var key = pairs[p].key;
            if (key === "workspace" && pairs[p].type === "string") workspace = pairs[p].value;
            else if (key === "monitor" && pairs[p].type === "string") monitor = pairs[p].value;
            else unsupported = true;
        }
        if (unsupported) { entry.reason = "unsupported-option"; entries.push(entry); continue; }
        if (workspace === null || monitor === null) {
            entry.reason = "missing-option";
            entries.push(entry);
            continue;
        }
        if (!WORKSPACE_RE.test(workspace) || !MONITOR_RE.test(monitor)) {
            entry.reason = "value-out-of-range";
            entries.push(entry);
            continue;
        }
        entry.editable = true;
        entry.workspace = workspace;
        entry.monitor = monitor;
        entries.push(entry);
    }
    return entries;
}

function hyprParserFor(fileName) {
    if (fileName === "autostart.lua")   return parseAutostartLua;
    if (fileName === "windowrules.lua") return parseWindowRulesLua;
    if (fileName === "workspaces.lua")  return parseWorkspacesLua;
    return null;
}

// The three sections, always in file order and always all three -- a file
// the reader did not find is a section that SAYS so, not a section that is
// missing. Takes the `files` array of the bin/omarchy-autostart-hypr
// envelope; it does no I/O of its own.
function parseHyprFiles(files) {
    var given = files || [];
    var byName = {};
    for (var i = 0; i < given.length; i++) {
        if (given[i] && given[i].name) byName[String(given[i].name)] = given[i];
    }
    var sections = [];
    for (var n = 0; n < HYPR_FILE_NAMES.length; n++) {
        var fileName = HYPR_FILE_NAMES[n];
        var f = byName[fileName] || {};
        var present = f.present === true;
        var parse = hyprParserFor(fileName);
        sections.push({
            name: fileName,
            path: String(f.path || ""),
            present: present,
            truncated: f.truncated === true,
            mtime: Number(f.mtime || 0),
            lineCount: present ? hyprLines(f.content).length : 0,
            entries: present ? parse(String(f.content || ""), fileName) : []
        });
    }
    return sections;
}

// --- what the panel says about the read -----------------------------------
//
// Wording lives here, like every other decision in this project, because
// this is the file a suite can reach.
function hyprEntryCount(sections) {
    var total = 0;
    for (var i = 0; i < (sections || []).length; i++) {
        total += (sections[i].entries || []).length;
    }
    return total;
}

function hyprEditableCount(sections) {
    var total = 0;
    for (var i = 0; i < (sections || []).length; i++) {
        var entries = sections[i].entries || [];
        for (var j = 0; j < entries.length; j++) if (entries[j].editable) total += 1;
    }
    return total;
}

// The one line in the head of the panel. It says two things and no more:
// that editing is not possible yet, and which files were actually read.
function hyprHeaderText(sections) {
    var list = sections || [];
    var read = [], absent = [];
    for (var i = 0; i < list.length; i++) {
        if (list[i].present) {
            read.push(list[i].name + " (" + (list[i].entries || []).length + ")");
        } else {
            absent.push(list[i].name);
        }
    }
    var text = "Read only -- editing your Hyprland files is not possible yet. ";
    text += (read.length === 0) ? "No file was read."
                                : "Read: " + read.join(", ") + ".";
    if (absent.length > 0) text += " Not found: " + absent.join(", ") + ".";
    return text;
}

// One entry as one line of text. The line number comes first because it is
// the thing that makes the entry findable in the user's own editor. A
// non-editable entry is shown by its RAW line and nothing else -- there is
// no reading of it to offer, and inventing one is the failure this whole
// task exists to avoid.
function hyprEntryText(entry) {
    var e = entry || {};
    // `prefix`, deliberately not the obvious short word for the front of a
    // line: test/qml-structure.sh check 1 scans this file for PATH-resolved
    // tool names on a word boundary, and one of the tools it names is the
    // one that word would collide with. A local variable is free to be
    // called something else; a structural check that has to be loosened for
    // a variable name is not.
    var prefix = String(e.line || 0) + ": ";
    if (!e.editable) return prefix + String(e.raw === undefined ? "" : e.raw);
    if (e.kind === "autostart") {
        return prefix + String(e.command) + (e.launcher === "uwsm-app" ? "" : "  (shell)");
    }
    if (e.kind === "window") {
        var flags = [], f = e.flags || {};
        for (var k = 0; k < WINDOW_FLAG_KEYS.length; k++) {
            if (f[WINDOW_FLAG_KEYS[k]] === true) flags.push(WINDOW_FLAG_KEYS[k]);
        }
        return prefix + String(e["class"]) + "  \u2192  workspace " + String(e.workspace)
             + (flags.length > 0 ? "  [" + flags.join(", ") + "]" : "");
    }
    if (e.kind === "workspace") {
        return prefix + "workspace " + String(e.workspace) + "  \u2192  " + String(e.monitor);
    }
    return prefix + String(e.raw === undefined ? "" : e.raw);
}
