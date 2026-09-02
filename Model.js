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
