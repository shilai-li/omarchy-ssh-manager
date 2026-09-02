// Reading what ssh told us, and turning it into findings.
//
// Qt- and locale-free so test/diagnostics-test.js can run it under plain
// node. Three parsers — one per record stream produced by bin/effective.sh,
// bin/probe.sh and `ssh-add -l` — and the rollup that turns them into the
// checklist the details view paints.
//
// Every claim made here traces back to something ssh itself said. Where ssh
// said nothing, the state is "unknown" and is drawn as a dash: an untested
// host is not a broken one, and a plugin that guesses is worse than one that
// admits it has not looked.

var STATE_OK = "ok"
var STATE_BAD = "bad"
var STATE_WARN = "warn"
var STATE_UNKNOWN = "unknown"

var GLYPHS = { ok: "✓", bad: "✗", warn: "!", unknown: "–" }

// The mark in front of a list row. Shape carries the meaning, not just color:
// a theme is free to define `urgent` as any color it likes — several make it
// the same green as the accent — and a status nobody can tell apart is not a
// status.
var DOTS = { ok: "●", bad: "✕", warn: "◑", unknown: "○" }

function glyphFor(state) { return GLYPHS[state] || GLYPHS.unknown }

function dotFor(state) { return DOTS[state] || DOTS.unknown }

function trim(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

function records(text) {
  var out = []
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var tab = lines[i].indexOf("\t")
    if (tab < 0) continue
    out.push({ kind: lines[i].slice(0, tab), payload: lines[i].slice(tab + 1) })
  }
  return out
}

// --------------------------------------------- what the file helpers reported

// bin/config-read.sh and bin/config-write.sh answer in the same four records:
// what happened, why when it went wrong, the digest of the bytes, and a cheap
// identity for noticing that something else has edited the file since.
//
// The digest is the version an edit was made against. A write hands it back,
// and a write whose digest no longer matches what is on disk is refused
// rather than applied: the file belongs to the user, and something else
// having edited it is a reason to reload, never a reason to overwrite.
function parseIoStatus(text) {
  var result = { state: "", reason: "", digest: "", identity: "" }
  var list = records(text)

  for (var i = 0; i < list.length; i++) {
    if (list[i].kind === "S") result.state = trim(list[i].payload)
    else if (list[i].kind === "R") result.reason = trim(list[i].payload)
    else if (list[i].kind === "D") result.digest = trim(list[i].payload)
    else if (list[i].kind === "V") result.identity = trim(list[i].payload)
  }

  // A helper that said nothing at all did not succeed, whatever else happened
  // to it. Treating silence as success is how a failed write gets reported as
  // a saved one.
  if (result.state === "") {
    result.state = "rejected"
    if (result.reason === "") result.reason = "the helper returned nothing"
  }
  return result
}

// A value out of the config, made safe to put in a sentence.
//
// Host names are the user's own text, and this plugin quotes them back —
// most sharply in the removal confirmation, which is the one place a misread
// name costs somebody a block of their file. Control characters and the
// Unicode bidi overrides can make a line on screen read as something other
// than what it says, so they come out, and a name long enough to push the
// dialog's buttons off the card is cut.
function plainLabel(value, max) {
  var text = String(value === undefined || value === null ? "" : value)
  var limit = max === undefined ? 64 : max
  var out = ""

  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i)
    if (code < 32 || code === 127 || (code >= 128 && code <= 159)) {
      out += " "
      continue
    }
    // Zero-width and directional formatting: invisible on their own, and able
    // to reorder everything around them.
    if (code >= 0x200b && code <= 0x200f) continue
    if (code >= 0x202a && code <= 0x202e) continue
    if (code >= 0x2066 && code <= 0x2069) continue
    if (code === 0xfeff || (code >= 0xfff9 && code <= 0xfffb)) continue
    out += text.charAt(i)
  }

  out = trim(out.replace(/\s+/g, " "))
  if (out.length > limit) out = out.slice(0, limit > 0 ? limit - 1 : 0) + "…"
  return out
}

// ------------------------------------------------------------- ssh -G output

// `ssh -G` prints one lowercase keyword per line, and repeats a few of them
// (identityfile, localforward). Keeping every occurrence is what lets the
// identity plan below show the order ssh will try.
function parseEffective(text) {
  var result = { ok: false, values: {}, identities: [], error: "", loaded: false }
  var list = records(text)

  for (var i = 0; i < list.length; i++) {
    var record = list[i]

    if (record.kind === "G") {
      result.ok = trim(record.payload) === "ok"
      result.loaded = true
      continue
    }

    if (record.kind === "C") {
      var body = trim(record.payload)
      if (body === "") continue
      var space = body.indexOf(" ")
      var key = space < 0 ? body : body.slice(0, space)
      var value = space < 0 ? "" : trim(body.slice(space + 1))
      var slot = ":" + key.toLowerCase()
      if (!result.values[slot]) result.values[slot] = []
      result.values[slot].push(value)
      continue
    }

    if (record.kind === "I") {
      var parts = record.payload.split("\t")
      result.identities.push({
        path: parts[0] || "",
        exists: parts[1] === "yes",
        fingerprint: trim(parts[2] || "")
      })
      continue
    }

    if (record.kind === "X") {
      result.error = result.error === "" ? trim(record.payload) : result.error + " " + trim(record.payload)
    }
  }

  return result
}

function effectiveValue(effective, key, fallback) {
  var list = effective && effective.values ? effective.values[":" + String(key).toLowerCase()] : null
  return list && list.length > 0 ? list[0] : (fallback === undefined ? "" : fallback)
}

function effectiveList(effective, key) {
  var list = effective && effective.values ? effective.values[":" + String(key).toLowerCase()] : null
  return list ? list.slice(0) : []
}

// ------------------------------------------------------------- probe output

function parseProbe(text) {
  var result = { tcp: "", auth: "", message: "", tested: false }
  var list = records(text)

  for (var i = 0; i < list.length; i++) {
    var record = list[i]
    if (record.kind === "T") { result.tcp = trim(record.payload); result.tested = true }
    else if (record.kind === "A") { result.auth = trim(record.payload); result.tested = true }
    else if (record.kind === "M") result.message = trim(record.payload)
  }

  return result
}

// ---------------------------------------------------------------- ssh-agent

// `ssh-add -l` says everything in its exit code: 0 listed keys, 1 an agent
// with nothing in it, 2 no agent to talk to. The text is only there to name
// the keys.
function parseAgent(text, exitCode) {
  var result = { running: false, keys: [], message: "", checked: true }
  var code = Number(exitCode)

  if (code === 2) {
    result.message = "no agent (SSH_AUTH_SOCK unset or dead)"
    return result
  }

  result.running = true
  if (code === 1) {
    result.message = "agent running, no keys loaded"
    return result
  }

  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = trim(lines[i])
    if (line === "") continue

    // "256 SHA256:xxxx a comment with spaces (ED25519)"
    var match = line.match(/^(\d+)\s+(\S+)\s+(.*?)\s*(?:\(([^()]+)\))?$/)
    if (!match) continue
    result.keys.push({
      bits: match[1],
      fingerprint: match[2],
      comment: trim(match[3]),
      type: match[4] || ""
    })
  }

  return result
}

function agentHasFingerprint(agent, fingerprint) {
  if (!agent || !fingerprint) return false
  for (var i = 0; i < agent.keys.length; i++) {
    if (agent.keys[i].fingerprint === fingerprint) return true
  }
  return false
}

// --------------------------------------------------------- the identity plan

// What ssh will actually reach for, in order: the identity files it was told
// about that exist on disk, then whatever the agent is holding. An identity
// file that is configured but missing is the single most common reason a
// connection that "should work" does not, so it is kept in the list and
// marked rather than filtered out.
function identityPlan(effective, agent, configuredPaths, home) {
  var plan = []
  var identities = effective && effective.identities ? effective.identities : []
  var configured = configuredPaths || []

  for (var i = 0; i < identities.length; i++) {
    var identity = identities[i]
    var explicit = false
    for (var c = 0; c < configured.length; c++) {
      if (samePath(configured[c], identity.path, home)) explicit = true
    }
    // The six default key names ssh always tries are noise unless they exist
    // or the user named them.
    if (!identity.exists && !explicit) continue

    plan.push({
      source: "file",
      path: identity.path,
      exists: identity.exists,
      explicit: explicit,
      fingerprint: identity.fingerprint,
      loaded: agentHasFingerprint(agent, identity.fingerprint)
    })
  }

  if (agent && agent.running) {
    for (var k = 0; k < agent.keys.length; k++) {
      var key = agent.keys[k]
      var already = false
      for (var p = 0; p < plan.length; p++) if (plan[p].fingerprint === key.fingerprint) already = true
      if (already) continue
      plan.push({
        source: "agent",
        path: key.comment || key.fingerprint,
        exists: true,
        explicit: false,
        fingerprint: key.fingerprint,
        loaded: true,
        type: key.type
      })
    }
  }

  return plan
}

// `~` is the only expansion worth undoing here: ssh -G reports absolute
// paths while the config file usually says ~/.ssh/something.
function samePath(a, b, home) {
  return normalizePath(a, home) === normalizePath(b, home)
}

function normalizePath(value, home) {
  var path = trim(value)
  var base = trim(home)
  if (path.indexOf("~/") === 0 && base !== "") path = base + path.slice(1)
  return path.replace(/\/+$/, "")
}

function shortenPath(value, home) {
  var path = trim(value)
  var base = trim(home)
  if (base !== "" && path.indexOf(base + "/") === 0) return "~" + path.slice(base.length)
  return path
}

// ---------------------------------------------------------------- checklist

function reachableState(probe) {
  if (!probe || !probe.tested) return { state: STATE_UNKNOWN, detail: "not tested" }
  if (probe.tcp === "ok") return { state: STATE_OK, detail: "" }
  if (probe.tcp === "proxy") return { state: STATE_UNKNOWN, detail: "reached through a proxy" }
  if (probe.tcp === "fail") return { state: STATE_BAD, detail: "no TCP connection" }
  return { state: STATE_UNKNOWN, detail: "" }
}

function authState(probe) {
  if (!probe || !probe.tested || probe.auth === "") return { state: STATE_UNKNOWN, detail: "not tested" }
  if (probe.auth === "ok") return { state: STATE_OK, detail: "" }
  if (probe.auth === "denied") return { state: STATE_BAD, detail: "key refused" }
  if (probe.auth === "hostkey") return { state: STATE_BAD, detail: "host key verification failed" }
  if (probe.auth === "unreachable") return { state: STATE_BAD, detail: "host not reachable" }
  return { state: STATE_BAD, detail: "failed" }
}

function agentState(agent) {
  if (!agent || !agent.checked) return { state: STATE_UNKNOWN, detail: "" }
  if (!agent.running) return { state: STATE_BAD, detail: "not running" }
  if (agent.keys.length === 0) return { state: STATE_WARN, detail: "no keys loaded" }
  return { state: STATE_OK, detail: agent.keys.length + (agent.keys.length === 1 ? " key" : " keys") }
}

function keyState(plan, agent) {
  var usable = 0
  var loaded = 0
  var missing = 0

  for (var i = 0; i < plan.length; i++) {
    if (plan[i].source === "file" && !plan[i].exists) { missing++; continue }
    usable++
    if (plan[i].loaded) loaded++
  }

  if (loaded > 0) return { state: STATE_OK, detail: "in the agent" }
  if (usable > 0) return { state: STATE_OK, detail: "on disk" }
  if (missing > 0) return { state: STATE_BAD, detail: "configured key is missing" }
  if (agent && agent.running && agent.keys.length > 0) return { state: STATE_OK, detail: "in the agent" }
  return { state: STATE_BAD, detail: "no key ssh can use" }
}

function configState(effective) {
  if (!effective || !effective.loaded) return { state: STATE_UNKNOWN, detail: "" }
  if (effective.ok) return { state: STATE_OK, detail: "" }
  return { state: STATE_BAD, detail: effective.error || "ssh could not parse the configuration" }
}

function checklist(context) {
  var effective = context ? context.effective : null
  var probe = context ? context.probe : null
  var agent = context ? context.agent : null
  var plan = context ? (context.plan || []) : []

  return [
    label("Host reachable", reachableState(probe)),
    label("SSH agent", agentState(agent)),
    label("Key available", keyState(plan, agent)),
    label("Authentication", authState(probe)),
    label("Config valid", configState(effective))
  ]
}

function label(text, result) {
  return { label: text, state: result.state, detail: result.detail, glyph: glyphFor(result.state) }
}

// ------------------------------------------------------------------ findings
//
// The things worth telling the user without being asked. Each one names what
// is wrong and where, and none of them is inferred from something we did not
// actually check.
function findings(host, effective, agent, probe, duplicates, home) {
  var out = []
  var i

  if (!host) return out

  if (host.duplicate) {
    out.push({ level: STATE_WARN, text: "Declared more than once — ssh uses the first value for each keyword" })
  }

  for (i = 0; i < (duplicates || []).length; i++) {
    var duplicate = duplicates[i]
    if (duplicate.pattern !== host.name) continue
    var places = []
    for (var p = 0; p < duplicate.places.length; p++) {
      places.push(shortenPath(duplicate.places[p].file, home) + ":" + duplicate.places[p].line)
    }
    out.push({ level: STATE_WARN, text: "Host " + duplicate.pattern + " declared at " + places.join(", ") })
  }

  var shadowed = host.shadowed || []
  for (i = 0; i < shadowed.length; i++) {
    var entry = shadowed[i]
    // A catch-all losing to a host that names itself is ssh working exactly
    // as intended — reporting it would bury the real conflicts under one
    // line per keyword `Host *` happens to set.
    if (entry.pattern === "*") continue
    out.push({
      level: STATE_WARN,
      text: entry.key + " " + entry.value + " in " + shortenPath(entry.file, home) + ":" + entry.line
        + " is ignored — " + entry.winnerPattern + " already set " + entry.winnerValue
    })
  }

  var identities = effective && effective.identities ? effective.identities : []
  var configured = host.identityFiles || []
  for (i = 0; i < identities.length; i++) {
    if (identities[i].exists) continue
    var named = false
    for (var c = 0; c < configured.length; c++) {
      if (samePath(configured[c], identities[i].path, home)) named = true
    }
    if (!named) continue
    out.push({ level: STATE_BAD, text: "IdentityFile " + shortenPath(identities[i].path, home) + " does not exist" })
  }

  if (effective && effective.loaded && !effective.ok) {
    out.push({ level: STATE_BAD, text: effective.error || "ssh could not parse the configuration" })
  }

  if (probe && probe.tested && probe.auth !== "ok" && probe.message !== "") {
    out.push({ level: STATE_BAD, text: probe.message })
  }

  if (agent && agent.checked && !agent.running) {
    out.push({ level: STATE_WARN, text: "ssh-agent is not running — only on-disk keys will be offered" })
  }

  return out
}

// ----------------------------------------------------------------- list view

// The one line under each host name in the list.
function hostSubtitle(host) {
  if (!host) return ""
  var target = host.hostName || host.name
  return host.user ? host.user + "@" + target : target
}

function hostDetail(host, probe, agent, home) {
  // A pattern is never connected to, so "SSH Agent" under one would be
  // claiming something about a row that cannot be tested.
  if (host && host.wildcard) return "pattern"

  if (probe && probe.tested) {
    if (probe.auth === "ok") return "Authenticated"
    if (probe.auth === "denied") return "Key refused"
    if (probe.auth === "hostkey") return "Host key changed"
    if (probe.tcp === "fail" || probe.auth === "unreachable") return "Unreachable"
    if (probe.auth === "error") return "Error"
  }
  if (host && host.identityFiles && host.identityFiles.length > 0) {
    return shortenPath(host.identityFiles[0], home)
  }
  if (agent && agent.running && agent.keys.length > 0) return "SSH Agent"
  return ""
}

// The dot in front of a row: filled once we know the host answers, hollow
// until then, and never green-by-default.
function hostState(probe) {
  if (!probe || !probe.tested) return STATE_UNKNOWN
  if (probe.auth === "ok") return STATE_OK
  if (probe.auth === "" && probe.tcp === "ok") return STATE_OK
  if (probe.tcp === "ok") return STATE_WARN
  return STATE_BAD
}

// Concrete hosts in the order the files declare them, then the wildcard
// blocks. A pattern is not somewhere to connect, but it is where a surprising
// value usually comes from, so it belongs at the bottom of the list rather
// than out of it.
function orderHosts(hosts) {
  var concrete = []
  var patterns = []
  for (var i = 0; i < (hosts || []).length; i++) {
    if (hosts[i].wildcard) patterns.push(hosts[i])
    else concrete.push(hosts[i])
  }
  return concrete.concat(patterns)
}

// Substring matching over the name, the hostname and the user — the three
// things anyone types when they are looking for a host.
function filterHosts(hosts, query) {
  var needle = trim(query).toLowerCase()
  var out = []

  for (var i = 0; i < (hosts || []).length; i++) {
    var host = hosts[i]
    if (needle === "") { out.push(host); continue }
    var haystack = [host.name, host.hostName, host.user, host.aliases ? host.aliases.join(" ") : ""]
      .join(" ").toLowerCase()
    if (haystack.indexOf(needle) >= 0) out.push(host)
  }

  return out
}

function clampIndex(index, count) {
  if (count <= 0) return 0
  var n = Number(index)
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(count - 1, Math.round(n)))
}

function moveIndex(index, delta, count) {
  if (count <= 0) return 0
  var n = clampIndex(index, count) + delta
  while (n < 0) n += count
  return n % count
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    STATE_OK: STATE_OK,
    STATE_BAD: STATE_BAD,
    STATE_WARN: STATE_WARN,
    STATE_UNKNOWN: STATE_UNKNOWN,
    glyphFor: glyphFor,
    dotFor: dotFor,
    parseIoStatus: parseIoStatus,
    plainLabel: plainLabel,
    parseEffective: parseEffective,
    effectiveValue: effectiveValue,
    effectiveList: effectiveList,
    parseProbe: parseProbe,
    parseAgent: parseAgent,
    agentHasFingerprint: agentHasFingerprint,
    identityPlan: identityPlan,
    samePath: samePath,
    normalizePath: normalizePath,
    shortenPath: shortenPath,
    checklist: checklist,
    findings: findings,
    hostSubtitle: hostSubtitle,
    hostDetail: hostDetail,
    hostState: hostState,
    orderHosts: orderHosts,
    filterHosts: filterHosts,
    clampIndex: clampIndex,
    moveIndex: moveIndex
  }
}
