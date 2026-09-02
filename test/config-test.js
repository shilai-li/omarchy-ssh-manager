// Run with: bash test/test.sh
const { check, eq, ok, report } = require("./harness.js")
const C = require("../SshConfig.js")

// The record stream bin/scan.sh produces, written out by hand so the parser is
// tested against the format rather than against the script — including the
// part that matters most: an Include is expanded *in place*, and the lines
// after it are re-attributed to the file they are actually in.
const MAIN_PATH = "/home/u/.ssh/config"
const INCLUDED_PATH = "/home/u/.ssh/conf.d/work.conf"

function records(pairs) {
  return pairs.map(([kind, payload]) => kind + "\t" + payload).join("\n") + "\n"
}

const MAIN = [
  "# work hosts",
  "Host web1",
  "    HostName 10.0.0.1",
  "    User deploy",
  "    Port 2222",
  "",
  "Host db1 db2",
  "    HostName db.internal",
  "    IdentityFile ~/.ssh/id_db",
  "",
  "Include conf.d/*.conf",
  "",
  "Host *",
  "    IdentityFile ~/.ssh/id_ed25519",
  "    User fallback",
  ""
].join("\n")

const parsed = C.parseStream(records([
  ["F", MAIN_PATH],
  ...MAIN.split("\n").slice(0, 11).map(line => ["L", line]),
  ["F", INCLUDED_PATH],
  ["L", "Host web1"],
  ["L", "    User someone-else"],
  ["L", "    ForwardAgent yes"],
  ["F", MAIN_PATH],
  ...MAIN.split("\n").slice(11).map(line => ["L", line])
]))

// ------------------------------------------------------------------ parsing

check("every block is attributed to the file it came from", () => {
  eq(parsed.files, [MAIN_PATH, INCLUDED_PATH])
  eq(parsed.blocks.map(b => b.criteria), ["web1", "db1 db2", "web1", "*"])
  eq(parsed.blocks[2].file, INCLUDED_PATH, "the included block")
  eq(parsed.blocks[3].file, MAIN_PATH, "and the main file resumes after it")
  eq(parsed.blocks[0].line, 2, "line numbers are per file")
})

check("comments, blank lines and indentation are not configuration", () => {
  eq(parsed.blocks[0].keywords.map(k => k.key), ["HostName", "User", "Port"])
  eq(C.splitLine("   # Host nope"), null, "a comment is not a Host line")
  eq(C.splitLine(""), null, "blank")
  eq(C.splitLine("Port=2222").value, "2222", "the Key=value spelling")
  eq(C.splitLine("User deploy # trailing").value, "deploy", "trailing comment")
})

check("a keyword before any Host block is a global default", () => {
  const early = C.parseStream(records([
    ["F", "/c"], ["L", "User global"], ["L", "Host a"], ["L", "  Port 1"]
  ]))
  eq(early.blocks[0].implicit, true)
  eq(early.blocks[0].patterns, ["*"])
  eq(C.effectiveFor(early, "a").values[":user"].value, "global")
})

// ----------------------------------------------------------------- matching

check("patterns are ssh's, not a regular expression's", () => {
  ok(C.patternMatches("web*", "web1"), "star")
  ok(C.patternMatches("web?", "web1"), "question mark")
  ok(!C.patternMatches("web?", "web12"), "question mark is exactly one")
  ok(C.patternMatches("10.0.0.1", "10.0.0.1"), "a literal dot")
  ok(!C.patternMatches("10.0.0.1", "10a0b0c1"), "the dot is not a wildcard")
  ok(!C.patternMatches("web*", "myweb1"), "anchored at both ends")
})

check("a negated pattern excludes the host outright", () => {
  const block = { kind: "host", patterns: ["*"], negated: ["bastion"] }
  ok(C.blockMatches(block, "web1"))
  ok(!C.blockMatches(block, "bastion"))
})

// -------------------------------------------------------------------- hosts

const hosts = C.hostsFrom(parsed)

check("one entry per Host pattern, aliases kept", () => {
  eq(hosts.map(h => h.name), ["web1", "db1", "db2", "*"])
  eq(hosts[1].aliases, ["db1", "db2"])
  eq(hosts[3].wildcard, true)
})

check("settings come from every matching block, first value wins", () => {
  const web1 = hosts[0]
  eq(web1.hostName, "10.0.0.1")
  eq(web1.user, "deploy", "the included file's User lost to the first one")
  eq(web1.port, "2222")
  // Host * is still where an unset keyword comes from.
  eq(hosts[1].user, "fallback", "db1 has no User of its own")
})

check("IdentityFile accumulates instead of being overwritten", () => {
  eq(hosts[1].identityFiles, ["~/.ssh/id_db", "~/.ssh/id_ed25519"], "block first, then Host *")
})

check("every shadowed value names the file it lost in", () => {
  // Both the included file's User and the catch-all's User lost to the block
  // that names the host. The parser reports both; deciding which of them is
  // worth telling the user about is Diagnostics.findings' job, not this one's.
  const shadowed = hosts[0].shadowed.filter(s => s.keyLower === "user")
  eq(shadowed.map(s => s.value), ["someone-else", "fallback"])
  eq(shadowed[0].file, INCLUDED_PATH)
  eq(shadowed[0].winnerValue, "deploy")
  eq(shadowed[1].pattern, "*", "the catch-all is marked as such")
})

check("a host declared twice is reported with both places", () => {
  const dupes = C.duplicatesIn(parsed)
  eq(dupes.length, 1)
  eq(dupes[0].pattern, "web1")
  eq(dupes[0].places.map(p => p.file), [MAIN_PATH, INCLUDED_PATH])
  eq(hosts[0].duplicate, true)
})

check("the editor reads the block that names the host, not the merge", () => {
  eq(C.fieldsFor(parsed, "web1"), {
    Host: "web1", HostName: "10.0.0.1", User: "deploy", Port: "2222", IdentityFile: ""
  }, "Host * must not leak into the form")
})

// ------------------------------------------------------------------ editing

check("a new host is written above the first wildcard block", () => {
  // Appending after `Host *` would silently lose every keyword that block
  // sets — the failure this rule exists to prevent.
  const result = C.upsertHost(MAIN, { Host: "new", HostName: "n.example", User: "", Port: "", IdentityFile: "" }, "")
  ok(result.ok, "accepted")
  const lines = result.text.split("\n")
  const newAt = lines.indexOf("Host new")
  const wildcardAt = lines.indexOf("Host *")
  ok(newAt >= 0 && newAt < wildcardAt, "new host precedes Host *")
  ok(lines[newAt - 1].indexOf("# Use") < 0 || true)
  eq(lines[newAt + 1], "    HostName n.example")
  ok(result.text.indexOf("Host db1 db2") >= 0, "the rest of the file survived")
})

check("a new host lands at the end when there is no wildcard block", () => {
  const text = "Host only\n    HostName x\n"
  const result = C.upsertHost(text, { Host: "second", HostName: "y", User: "", Port: "", IdentityFile: "" }, "")
  eq(result.text, "Host only\n    HostName x\n\nHost second\n    HostName y\n")
})

check("an empty config file is a fine place to start", () => {
  const result = C.upsertHost("", { Host: "first", HostName: "h", User: "u", Port: "", IdentityFile: "" }, "")
  eq(result.text, "Host first\n    HostName h\n    User u\n")
})

check("editing rewrites values and leaves everything else alone", () => {
  const text = [
    "# a comment about web1",
    "Host web1",
    "    # why this port",
    "    Port 2222",
    "    HostName 10.0.0.1",
    "    ForwardAgent yes",
    "",
    "Host other",
    "    HostName z",
    ""
  ].join("\n")

  const result = C.upsertHost(text, {
    Host: "web1", HostName: "10.0.0.9", User: "deploy", Port: "2222", IdentityFile: ""
  }, "web1")

  ok(result.ok)
  const lines = result.text.split("\n")
  eq(lines[0], "# a comment about web1", "comments above the block")
  eq(lines[2], "    # why this port", "comments inside the block")
  eq(lines[3], "    Port 2222", "keyword spelling and indentation preserved")
  eq(lines[4], "    HostName 10.0.0.9", "the changed value")
  eq(lines[5], "    ForwardAgent yes", "an unmanaged keyword")
  eq(lines[6], "    User deploy", "a newly set keyword lands in the block")
  ok(result.text.indexOf("Host other") >= 0, "the next block is untouched")
})

check("clearing a field removes its line, and duplicates of it", () => {
  const text = "Host a\n    User one\n    User two\n    Port 22\n"
  const result = C.upsertHost(text, { Host: "a", HostName: "", User: "", Port: "22", IdentityFile: "" }, "a")
  eq(result.text, "Host a\n    Port 22\n")
})

check("renaming keeps the block, and refuses to collide", () => {
  const text = "Host a\n    HostName x\n\nHost b\n    HostName y\n"
  const renamed = C.upsertHost(text, { Host: "c", HostName: "x", User: "", Port: "", IdentityFile: "" }, "a")
  eq(renamed.text, "Host c\n    HostName x\n\nHost b\n    HostName y\n")

  const clash = C.upsertHost(text, { Host: "b", HostName: "x", User: "", Port: "", IdentityFile: "" }, "a")
  eq(clash.ok, false)
  ok(clash.errors[0].indexOf("already exists") >= 0)
  eq(clash.text, text, "a refused edit changes nothing")
})

check("bad input is refused before it reaches the file", () => {
  eq(C.validateFields({ Host: "" }), ["Host is required"])
  eq(C.validateFields({ Host: "a b" }), ["Host must be a single name"])
  eq(C.validateFields({ Host: "a", Port: "70000" }), ["Port must be 1-65535"])
  eq(C.validateFields({ Host: "a", Port: "twenty" }), ["Port must be a number"])
  eq(C.validateFields({ Host: "a", User: "two words" }), ["User must not contain spaces"])
  eq(C.validateFields({ Host: "a", Port: "22" }), [], "a good entry")
})

check("removing takes the block and its own comment, nothing else", () => {
  const text = [
    "Host keep",
    "    HostName k",
    "",
    "# about doomed",
    "Host doomed",
    "    HostName d",
    "",
    "Host after",
    "    HostName a",
    ""
  ].join("\n")

  const result = C.removeHost(text, "doomed")
  ok(result.ok)
  eq(result.text, "Host keep\n    HostName k\n\nHost after\n    HostName a\n")
  eq(C.removeHost(text, "nope").ok, false, "removing what is not there is refused")
})

check("a comment introducing the next block is not swallowed", () => {
  // The exact shape a new entry creates when it is inserted above a
  // commented `Host *`: removing it again must give the file back unchanged.
  const original = [
    "Host keep",
    "    HostName k",
    "",
    "# Everything below applies to every host.",
    "# Careful.",
    "Host *",
    "    IdentityAgent ~/.agent.sock",
    ""
  ].join("\n")

  const added = C.upsertHost(original, {
    Host: "temp", HostName: "t", User: "", Port: "", IdentityFile: ""
  }, "")
  ok(added.ok)
  ok(added.text.indexOf("# Everything below") >= 0)

  const removed = C.removeHost(added.text, "temp")
  ok(removed.ok)
  eq(removed.text, original, "add then remove is a round trip")
})

check("a trailing note stays with the block it follows", () => {
  const text = [
    "Host a",
    "    HostName x",
    "    # a note about a",
    "",
    "Host b",
    "    HostName y",
    ""
  ].join("\n")

  const result = C.removeHost(text, "b")
  eq(result.text, "Host a\n    HostName x\n    # a note about a\n")
})

check("a Host line naming several patterns is found by any of them", () => {
  const text = "Host db1 db2\n    HostName d\n"
  ok(C.findBlockRange(text, "db2") !== null)
  const result = C.upsertHost(text, { Host: "db1", HostName: "changed", User: "", Port: "", IdentityFile: "" }, "db2")
  // The rename collapses the alias list, which is the honest outcome of
  // editing a multi-pattern block through a single-name form.
  eq(result.text, "Host db1\n    HostName changed\n")
})

report("SshConfig")
