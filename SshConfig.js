// Reading and editing ssh_config, as text.
//
// Qt- and locale-free so test/config-test.js can run it under plain node.
// Two halves, kept apart on purpose:
//
//   parse*   — what the configuration says, over the whole include stream
//   edit*    — surgery on one file's text, preserving every line it does
//              not have to touch
//
// Nothing here interprets a connection or runs a command; the shell scripts
// in bin/ do that, and `ssh -G` — not this file — is the authority on what
// ssh will actually do. This parser exists for the things `ssh -G` cannot
// tell you: which file a value came from, which entry shadowed which, and
// where in the file an edit belongs.

// The keywords the editor owns. Everything else in a block — ForwardAgent, a
// comment, a ProxyJump someone hand-wrote — is preserved untouched, because
// this plugin is a front end for the user's file, not the owner of it.
var MANAGED_KEYS = ["HostName", "User", "Port", "IdentityFile"]
var FIELD_KEYS = ["Host"].concat(MANAGED_KEYS)

var DEFAULT_INDENT = "    "

// ------------------------------------------------------------------ parsing

function trim(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

// One configuration line: keyword, then the rest. ssh also accepts `Key=value`
// and quoted arguments; the common spellings are handled and anything else is
// left to `ssh -G`, which is always shown alongside this view.
function splitLine(raw) {
  var line = String(raw === undefined || raw === null ? "" : raw)
  var body = line.replace(/^\s+/, "")
  if (body === "" || body.charAt(0) === "#") return null

  var match = body.match(/^([A-Za-z0-9_-]+)\s*(?:=\s*)?(.*)$/)
  if (!match) return null

  var value = trim(match[2]).replace(/\s+#.*$/, "")
  return { key: match[1], keyLower: match[1].toLowerCase(), value: value }
}

function splitArgs(value) {
  var out = []
  var parts = trim(value).split(/\s+/)
  for (var i = 0; i < parts.length; i++) if (parts[i] !== "") out.push(parts[i])
  return out
}

// Parse the F/L record stream that bin/scan.sh prints: the whole include
// chain, in ssh's reading order, with each line attributed to its file.
function parseStream(text) {
  var result = { files: [], blocks: [], includes: [], notes: [] }
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  var file = ""
  var lineNumber = 0
  var block = null

  function closeBlock() {
    if (block) result.blocks.push(block)
    block = null
  }

  for (var i = 0; i < lines.length; i++) {
    var record = lines[i]
    var tab = record.indexOf("\t")
    if (tab < 0) continue

    var kind = record.slice(0, tab)
    var payload = record.slice(tab + 1)

    if (kind === "F") {
      closeBlock()
      file = payload
      lineNumber = 0
      if (result.files.indexOf(file) < 0) result.files.push(file)
      continue
    }
    // bin/scan.sh says so when it skipped a file or stopped early. The panel
    // has to be able to tell the user the view is partial: a host that is
    // missing because the scan gave up looks exactly like one that is not
    // configured, and those are very different problems.
    if (kind === "E") {
      if (result.notes.indexOf(payload) < 0) result.notes.push(payload)
      continue
    }
    if (kind !== "L") continue

    lineNumber++
    var parsed = splitLine(payload)
    if (!parsed) continue

    if (parsed.keyLower === "host" || parsed.keyLower === "match") {
      closeBlock()
      var args = splitArgs(parsed.value)
      var patterns = []
      var negated = []
      for (var a = 0; a < args.length; a++) {
        if (args[a].charAt(0) === "!") negated.push(args[a].slice(1))
        else patterns.push(args[a])
      }
      block = {
        kind: parsed.keyLower,
        criteria: parsed.value,
        patterns: patterns,
        negated: negated,
        file: file,
        line: lineNumber,
        order: result.blocks.length,
        keywords: []
      }
      continue
    }

    // An Include is not a setting — bin/scan.sh has already expanded it in
    // place, and the lines it pulled in are in this stream. Recording it as a
    // global keyword would invent a `Host *` block that is not there.
    if (parsed.keyLower === "include") {
      result.includes.push({ file: file, line: lineNumber, value: parsed.value })
      continue
    }

    // A keyword before any Host block is a global default: ssh applies it to
    // everything, so it behaves exactly like `Host *` and is recorded as one.
    if (!block) {
      block = {
        kind: "host",
        criteria: "*",
        patterns: ["*"],
        negated: [],
        file: file,
        line: lineNumber,
        order: result.blocks.length,
        implicit: true,
        keywords: []
      }
    }

    block.keywords.push({
      key: parsed.key,
      keyLower: parsed.keyLower,
      value: parsed.value,
      file: file,
      line: lineNumber
    })
  }

  closeBlock()
  return result
}

// ------------------------------------------------------------------ matching

function isWildcard(pattern) {
  return String(pattern).indexOf("*") >= 0 || String(pattern).indexOf("?") >= 0
}

// ssh's pattern language is `*` and `?` only — no character classes, no
// regular expressions. Everything else is a literal, including the dots that
// a naive regex would treat as wildcards.
function patternToRegExp(pattern) {
  var out = ""
  var text = String(pattern)
  for (var i = 0; i < text.length; i++) {
    var c = text.charAt(i)
    if (c === "*") out += ".*"
    else if (c === "?") out += "."
    else out += c.replace(/[.+^${}()|[\]\\]/g, "\\$&")
  }
  return new RegExp("^" + out + "$")
}

function patternMatches(pattern, name) {
  if (!pattern || !name) return false
  return patternToRegExp(pattern).test(String(name))
}

// A negated pattern wins outright: `Host * !bastion` covers everything the
// bastion is not.
function blockMatches(block, name) {
  if (!block || block.kind !== "host") return false
  var i
  for (i = 0; i < block.negated.length; i++) {
    if (patternMatches(block.negated[i], name)) return false
  }
  for (i = 0; i < block.patterns.length; i++) {
    if (patternMatches(block.patterns[i], name)) return true
  }
  return block.patterns.length === 0 && block.negated.length > 0
}

// ------------------------------------------------------------------- hosts

// One entry per concrete Host pattern, in the order the files declare them.
// Wildcard patterns are kept separately: they are not somewhere to connect,
// they are the rules that shape everywhere else.
function hostsFrom(parsed) {
  var hosts = []
  var index = {}
  var blocks = parsed && parsed.blocks ? parsed.blocks : []

  for (var b = 0; b < blocks.length; b++) {
    var block = blocks[b]
    if (block.kind !== "host" || block.implicit) continue

    for (var p = 0; p < block.patterns.length; p++) {
      var pattern = block.patterns[p]
      var wildcard = isWildcard(pattern)
      var key = ":" + pattern

      if (index[key]) {
        // A second declaration of the same name. ssh reads both and takes the
        // first value for each keyword, which is a mistake often enough to be
        // worth naming.
        index[key].blocks.push(block)
        continue
      }

      var host = {
        name: pattern,
        wildcard: wildcard,
        file: block.file,
        line: block.line,
        aliases: block.patterns.slice(0),
        blocks: [block]
      }
      index[key] = host
      hosts.push(host)
    }
  }

  // Settings come from every matching block, not just the one that names the
  // host — that is what ssh does, and it is the only way `Host *` shows up
  // where the user will feel it.
  for (var h = 0; h < hosts.length; h++) {
    var settings = effectiveFor(parsed, hosts[h].name)
    hosts[h].values = settings.values
    hosts[h].shadowed = settings.shadowed
    hosts[h].hostName = valueOf(settings, "hostname", hosts[h].wildcard ? "" : hosts[h].name)
    hosts[h].user = valueOf(settings, "user", "")
    hosts[h].port = valueOf(settings, "port", "")
    hosts[h].identityFiles = allValuesOf(settings, "identityfile")
    hosts[h].proxy = valueOf(settings, "proxyjump", "") || valueOf(settings, "proxycommand", "")
    hosts[h].duplicate = hosts[h].blocks.length > 1
  }

  return hosts
}

function valueOf(settings, keyLower, fallback) {
  var entry = settings && settings.values ? settings.values[":" + keyLower] : null
  return entry ? entry.value : (fallback === undefined ? "" : fallback)
}

function allValuesOf(settings, keyLower) {
  var entry = settings && settings.values ? settings.values[":" + keyLower] : null
  return entry ? entry.all.slice(0) : []
}

// ssh takes the *first* value it obtains for each keyword, so a later block
// never changes a decided one. `shadowed` is every value that lost, which is
// the answer to "why is it not using what I wrote".
function effectiveFor(parsed, name) {
  var values = {}
  var shadowed = []
  var blocks = parsed && parsed.blocks ? parsed.blocks : []

  for (var b = 0; b < blocks.length; b++) {
    var block = blocks[b]
    if (!blockMatches(block, name)) continue

    for (var k = 0; k < block.keywords.length; k++) {
      var keyword = block.keywords[k]
      var slot = ":" + keyword.keyLower
      var winner = values[slot]

      if (!winner) {
        values[slot] = {
          key: keyword.key,
          keyLower: keyword.keyLower,
          value: keyword.value,
          file: keyword.file,
          line: keyword.line,
          pattern: block.criteria,
          all: [keyword.value]
        }
        continue
      }

      // IdentityFile is the exception ssh makes to first-wins: every one is
      // kept and offered in order.
      if (keyword.keyLower === "identityfile") {
        winner.all.push(keyword.value)
        continue
      }

      shadowed.push({
        key: keyword.key,
        keyLower: keyword.keyLower,
        value: keyword.value,
        file: keyword.file,
        line: keyword.line,
        pattern: block.criteria,
        winnerValue: winner.value,
        winnerFile: winner.file,
        winnerPattern: winner.pattern
      })
    }
  }

  return { values: values, shadowed: shadowed }
}

// Patterns declared by more than one Host block, wherever they live. Two
// blocks for one name is legal and occasionally deliberate; it is also the
// shape of "I edited the wrong copy", so it is surfaced, not fixed.
function duplicatesIn(parsed) {
  var seen = {}
  var out = []
  var blocks = parsed && parsed.blocks ? parsed.blocks : []

  for (var b = 0; b < blocks.length; b++) {
    var block = blocks[b]
    if (block.kind !== "host" || block.implicit) continue
    for (var p = 0; p < block.patterns.length; p++) {
      var key = ":" + block.patterns[p]
      if (!seen[key]) {
        seen[key] = { pattern: block.patterns[p], places: [] }
        out.push(seen[key])
      }
      seen[key].places.push({ file: block.file, line: block.line })
    }
  }

  return out.filter(function(entry) { return entry.places.length > 1 })
}

// ------------------------------------------------------------------ editing
//
// Everything below works on one file's raw text — the main config — and
// never on the include stream. An edit rewrites the lines it must and copies
// the rest through byte for byte.

function validateFields(fields) {
  var errors = []
  var host = trim(fields ? fields.Host : "")
  var port = trim(fields ? fields.Port : "")

  if (host === "") errors.push("Host is required")
  else if (/\s/.test(host)) errors.push("Host must be a single name")
  else if (host.charAt(0) === "#" || host.charAt(0) === "!") errors.push("Host cannot start with " + host.charAt(0))

  if (port !== "" && !/^[0-9]{1,5}$/.test(port)) errors.push("Port must be a number")
  else if (port !== "" && (Number(port) < 1 || Number(port) > 65535)) errors.push("Port must be 1-65535")

  for (var i = 0; i < MANAGED_KEYS.length; i++) {
    var key = MANAGED_KEYS[i]
    var value = trim(fields ? fields[key] : "")
    if (value !== "" && /\s/.test(value)) errors.push(key + " must not contain spaces")
    if (value.indexOf("\n") >= 0) errors.push(key + " must be a single line")
  }

  return errors
}

function blockStartsAt(line) {
  var parsed = splitLine(line)
  return !!parsed && (parsed.keyLower === "host" || parsed.keyLower === "match")
}

// The line range a Host block owns: its Host line through the last line that
// is really its own.
function findBlockRange(text, name) {
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  var start = -1

  for (var i = 0; i < lines.length; i++) {
    if (!blockStartsAt(lines[i])) continue
    var parsed = splitLine(lines[i])
    if (start >= 0) return { start: start, end: blockEnd(lines, start, i), lines: lines }
    if (parsed.keyLower !== "host") continue
    if (splitArgs(parsed.value).indexOf(name) >= 0) start = i
  }

  if (start < 0) return null
  return { start: start, end: blockEnd(lines, start, lines.length), lines: lines }
}

// Where one block stops and the gap to the next begins.
//
// A comment sitting directly above a Host line introduces *that* block, not
// the one before it — removing a host must not take the paragraph explaining
// its neighbour with it. A comment separated from the next block by a blank
// line is a trailing note on this one and stays.
function blockEnd(lines, start, stop) {
  var end = stop

  if (stop < lines.length) {
    while (end > start + 1 && trim(lines[end - 1]).charAt(0) === "#") end--
  }
  while (end > start + 1 && trim(lines[end - 1]) === "") end--

  return end
}

function indentOf(lines, start, end) {
  for (var i = start + 1; i < end; i++) {
    var match = String(lines[i]).match(/^(\s+)\S/)
    if (match) return match[1]
  }
  return DEFAULT_INDENT
}

function renderBlock(fields, indent) {
  var pad = indent || DEFAULT_INDENT
  var out = ["Host " + trim(fields.Host)]
  for (var i = 0; i < MANAGED_KEYS.length; i++) {
    var key = MANAGED_KEYS[i]
    var value = trim(fields[key])
    if (value !== "") out.push(pad + key + " " + value)
  }
  return out
}

// New blocks go above the first wildcard-only block. ssh takes the first
// value it finds, so a host appended after `Host *` would silently lose every
// keyword that block sets — the single most common way a hand-edited
// ssh_config stops doing what it looks like it does.
function insertionIndex(text) {
  var lines = String(text === undefined || text === null ? "" : text).split("\n")

  for (var i = 0; i < lines.length; i++) {
    if (!blockStartsAt(lines[i])) continue
    var parsed = splitLine(lines[i])
    if (parsed.keyLower !== "host") continue

    var args = splitArgs(parsed.value)
    var allWildcard = args.length > 0
    for (var a = 0; a < args.length; a++) if (!isWildcard(args[a])) allWildcard = false
    if (!allWildcard) continue

    // Carry any comment block sitting directly above it along with it.
    var at = i
    while (at > 0 && trim(lines[at - 1]).charAt(0) === "#") at--
    return at
  }

  return lines.length
}

function upsertHost(text, fields, originalName) {
  var errors = validateFields(fields)
  if (errors.length > 0) return { ok: false, errors: errors, text: text }

  var body = String(text === undefined || text === null ? "" : text)
  var target = trim(originalName) || trim(fields.Host)
  var range = findBlockRange(body, target)

  if (!range) {
    // A rename onto a name that already exists would leave two blocks with
    // the same Host line, which is exactly the ambiguity this plugin warns
    // about elsewhere.
    if (findBlockRange(body, trim(fields.Host))) {
      return { ok: false, errors: ["A Host entry named " + trim(fields.Host) + " already exists"], text: body }
    }

    var lines = body === "" ? [] : body.split("\n")
    var at = insertionIndex(body)
    var block = renderBlock(fields, DEFAULT_INDENT)
    var insert = block.slice(0)

    if (at >= lines.length) {
      while (lines.length > 0 && trim(lines[lines.length - 1]) === "") lines.pop()
      if (lines.length > 0) insert = [""].concat(insert)
      lines = lines.concat(insert)
    } else {
      lines = lines.slice(0, at).concat(insert, [""], lines.slice(at))
    }

    return { ok: true, errors: [], text: endWithNewline(lines.join("\n")) }
  }

  if (trim(fields.Host) !== target) {
    var clash = findBlockRange(body, trim(fields.Host))
    if (clash && clash.start !== range.start) {
      return { ok: false, errors: ["A Host entry named " + trim(fields.Host) + " already exists"], text: body }
    }
  }

  var updated = updateBlockLines(range.lines.slice(range.start, range.end), fields)
  var merged = range.lines.slice(0, range.start).concat(updated, range.lines.slice(range.end))
  return { ok: true, errors: [], text: endWithNewline(merged.join("\n")) }
}

// Rewrite only what changed. A keyword the user set by hand keeps its own
// spelling and indentation; a keyword being cleared loses its line; a new one
// is added under the ones already there.
function updateBlockLines(blockLines, fields) {
  var lines = blockLines.slice(0)
  var indent = indentOf(lines, 0, lines.length)
  var i

  var hostMatch = String(lines[0]).match(/^(\s*)([A-Za-z]+)(\s*=?\s*)(.*)$/)
  var hostIndent = hostMatch ? hostMatch[1] : ""
  var hostKeyword = hostMatch ? hostMatch[2] : "Host"
  lines[0] = hostIndent + hostKeyword + " " + trim(fields.Host)

  for (var k = 0; k < MANAGED_KEYS.length; k++) {
    var key = MANAGED_KEYS[k]
    var value = trim(fields[key])
    var lower = key.toLowerCase()
    var first = -1
    var extras = []

    for (i = 1; i < lines.length; i++) {
      var parsed = splitLine(lines[i])
      if (!parsed || parsed.keyLower !== lower) continue
      if (first < 0) first = i
      else extras.push(i)
    }

    // Later duplicates of a keyword inside one block are dead weight — ssh
    // already ignored them — and leaving them would contradict what the panel
    // now shows.
    for (i = extras.length - 1; i >= 0; i--) lines.splice(extras[i], 1)

    if (first >= 0) {
      if (value === "") {
        lines.splice(first, 1)
        continue
      }
      var line = String(lines[first])
      var match = line.match(/^(\s*)([A-Za-z]+)(\s*=?\s*)(.*)$/)
      var pad = match ? match[1] : indent
      var keyword = match ? match[2] : key
      lines[first] = pad + keyword + " " + value
      continue
    }

    if (value === "") continue
    lines.splice(lastKeywordIndex(lines) + 1, 0, indent + key + " " + value)
  }

  return lines
}

function lastKeywordIndex(lines) {
  for (var i = lines.length - 1; i >= 1; i--) {
    if (splitLine(lines[i])) return i
  }
  return 0
}

function removeHost(text, name) {
  var body = String(text === undefined || text === null ? "" : text)
  var range = findBlockRange(body, name)
  if (!range) return { ok: false, errors: ["No Host entry named " + name], text: body }

  var start = range.start
  // Take the comment block written above the entry with it: it describes the
  // host being removed, and leaving it orphaned above the next one is worse
  // than losing it.
  while (start > 0 && trim(range.lines[start - 1]).charAt(0) === "#") start--

  var kept = range.lines.slice(0, start).concat(range.lines.slice(range.end))
  return { ok: true, errors: [], text: endWithNewline(collapseBlankRun(kept).join("\n")) }
}

function collapseBlankRun(lines) {
  var out = []
  for (var i = 0; i < lines.length; i++) {
    if (trim(lines[i]) === "" && out.length > 0 && trim(out[out.length - 1]) === "") continue
    out.push(lines[i])
  }
  return out
}

// How many bytes this text becomes on the way to disk.
//
// bin/config-write.sh is told the length before it is sent the bytes, because
// the QML process on the other end of that pipe stays open for the life of
// the session and a helper waiting for end-of-file would wait forever. Qt
// writes a string to a pipe as UTF-8, so the count has to be UTF-8 bytes and
// not JavaScript's UTF-16 code units — one accented character in a comment is
// enough for the difference to matter.
function utf8Length(text) {
  var value = String(text === undefined || text === null ? "" : text)
  var bytes = 0

  for (var i = 0; i < value.length; i++) {
    var code = value.charCodeAt(i)
    if (code < 0x80) {
      bytes += 1
    } else if (code < 0x800) {
      bytes += 2
    } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length
               && value.charCodeAt(i + 1) >= 0xdc00 && value.charCodeAt(i + 1) <= 0xdfff) {
      bytes += 4
      i++
    } else {
      bytes += 3
    }
  }

  return bytes
}

function endWithNewline(text) {
  var body = String(text)
  while (body.length > 0 && body.charAt(body.length - 1) === "\n") body = body.slice(0, -1)
  return body + "\n"
}

// Read the five managed values straight out of one block, for the editor.
function fieldsFor(parsed, name) {
  var fields = { Host: name, HostName: "", User: "", Port: "", IdentityFile: "" }
  var blocks = parsed && parsed.blocks ? parsed.blocks : []

  for (var b = 0; b < blocks.length; b++) {
    var block = blocks[b]
    if (block.kind !== "host" || block.patterns.indexOf(name) < 0) continue
    for (var k = 0; k < block.keywords.length; k++) {
      var keyword = block.keywords[k]
      for (var m = 0; m < MANAGED_KEYS.length; m++) {
        if (keyword.keyLower !== MANAGED_KEYS[m].toLowerCase()) continue
        if (fields[MANAGED_KEYS[m]] === "") fields[MANAGED_KEYS[m]] = keyword.value
      }
    }
    break
  }

  return fields
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    MANAGED_KEYS: MANAGED_KEYS,
    FIELD_KEYS: FIELD_KEYS,
    splitLine: splitLine,
    splitArgs: splitArgs,
    parseStream: parseStream,
    isWildcard: isWildcard,
    patternMatches: patternMatches,
    blockMatches: blockMatches,
    hostsFrom: hostsFrom,
    effectiveFor: effectiveFor,
    duplicatesIn: duplicatesIn,
    validateFields: validateFields,
    findBlockRange: findBlockRange,
    insertionIndex: insertionIndex,
    renderBlock: renderBlock,
    utf8Length: utf8Length,
    upsertHost: upsertHost,
    removeHost: removeHost,
    fieldsFor: fieldsFor
  }
}
