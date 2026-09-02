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
