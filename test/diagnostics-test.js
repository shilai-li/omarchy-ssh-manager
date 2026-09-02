// Run with: bash test/test.sh
const { check, eq, ok, report } = require("./harness.js")
const D = require("../Diagnostics.js")

const HOME = "/home/u"

// ---------------------------------------------------------------- ssh -G

const EFFECTIVE = [
  "G\tok",
  "C\thost web1",
  "C\tuser deploy",
  "C\thostname 10.0.0.1",
  "C\tport 2222",
  "C\tidentityagent /run/agent.sock",
  "C\tidentityfile ~/.ssh/id_ed25519",
  "C\tidentityfile ~/.ssh/id_rsa",
  "I\t/home/u/.ssh/id_ed25519\tyes\tSHA256:AAA",
  "I\t/home/u/.ssh/id_rsa\tno\t"
].join("\n")

const effective = D.parseEffective(EFFECTIVE)

check("ssh -G output is read as ssh prints it", () => {
  eq(effective.ok, true)
  eq(effective.loaded, true)
  eq(D.effectiveValue(effective, "hostname"), "10.0.0.1")
  eq(D.effectiveValue(effective, "HostName"), "10.0.0.1", "keywords are case-insensitive")
  eq(D.effectiveValue(effective, "nothing", "fallback"), "fallback")
  eq(D.effectiveList(effective, "identityfile").length, 2, "repeated keywords are all kept")
  eq(effective.identities[0], { path: "/home/u/.ssh/id_ed25519", exists: true, fingerprint: "SHA256:AAA" })
  eq(effective.identities[1].exists, false)
})

check("a configuration ssh cannot parse is reported with its message", () => {
  const broken = D.parseEffective("G\tfail\nX\t/home/u/.ssh/config: line 3: Bad configuration option: nope\n")
  eq(broken.ok, false)
  eq(broken.loaded, true)
  ok(broken.error.indexOf("Bad configuration option") >= 0)
  eq(D.configState ? true : true, true)
})

// ------------------------------------------------------------------ probe

check("the probe separates 'not there' from 'will not have us'", () => {
  const reachable = D.parseProbe("T\tok\nA\tok\n")
  eq(reachable, { tcp: "ok", auth: "ok", message: "", tested: true })

  const denied = D.parseProbe("T\tok\nA\tdenied\nM\tPermission denied (publickey).\n")
  eq(denied.tcp, "ok", "the host answered")
  eq(denied.auth, "denied", "it just would not let us in")
  eq(denied.message, "Permission denied (publickey).")

  eq(D.parseProbe("").tested, false, "nothing asked, nothing claimed")
})

// ------------------------------------------------------------------ agent

check("ssh-add's exit code is the answer, its output only the detail", () => {
  const missing = D.parseAgent("", 2)
  eq(missing.running, false)
  ok(missing.message.indexOf("no agent") >= 0)

  const empty = D.parseAgent("The agent has no identities.\n", 1)
  eq(empty.running, true)
  eq(empty.keys.length, 0)

  const loaded = D.parseAgent("256 SHA256:AAA Main Dev Key (ED25519)\n3072 SHA256:BBB me@host (RSA)\n", 0)
  eq(loaded.running, true)
  eq(loaded.keys.length, 2)
  eq(loaded.keys[0], { bits: "256", fingerprint: "SHA256:AAA", comment: "Main Dev Key", type: "ED25519" })
  eq(loaded.keys[1].comment, "me@host", "a comment with an @ in it")
  ok(D.agentHasFingerprint(loaded, "SHA256:BBB"))
  ok(!D.agentHasFingerprint(loaded, "SHA256:ZZZ"))
})

// ---------------------------------------------------------- identity plan

const agent = D.parseAgent("256 SHA256:CCC agent-only-key (ED25519)\n", 0)

check("the plan is what ssh will really try, in order", () => {
  const plan = D.identityPlan(effective, agent, ["~/.ssh/id_ed25519"], HOME)
  eq(plan.map(p => p.path), ["/home/u/.ssh/id_ed25519", "agent-only-key"])
  eq(plan[0].source, "file")
  eq(plan[0].loaded, false, "on disk but not in the agent")
  eq(plan[1].source, "agent")
})

check("ssh's six default key names are not six findings", () => {
  const defaults = D.parseEffective([
    "G\tok",
    "I\t/home/u/.ssh/id_rsa\tno\t",
    "I\t/home/u/.ssh/id_ecdsa\tno\t"
  ].join("\n"))
  eq(D.identityPlan(defaults, null, [], HOME).length, 0, "absent and unasked-for is not worth a row")
})

check("a key the user named and does not have stays visible", () => {
  const named = D.parseEffective("G\tok\nI\t/home/u/.ssh/id_work\tno\t\n")
  const plan = D.identityPlan(named, null, ["~/.ssh/id_work"], HOME)
  eq(plan.length, 1)
  eq(plan[0].exists, false)
})

check("a key in both places is listed once", () => {
  const both = D.parseEffective("G\tok\nI\t/home/u/.ssh/id_ed25519\tyes\tSHA256:CCC\n")
  const plan = D.identityPlan(both, agent, [], HOME)
  eq(plan.length, 1)
  eq(plan[0].source, "file")
  eq(plan[0].loaded, true, "and marked as loaded")
})

// -------------------------------------------------------------- checklist

function states(list) {
  const out = {}
  for (const item of list) out[item.label] = item.state
  return out
}

check("an untested host is unknown, never fine", () => {
  const list = states(D.checklist({ effective: effective, probe: null, agent: agent, plan: [] }))
  eq(list["Host reachable"], D.STATE_UNKNOWN)
  eq(list["Authentication"], D.STATE_UNKNOWN)
  eq(list["Config valid"], D.STATE_OK)
  eq(list["SSH agent"], D.STATE_OK)
})

check("the checklist says what the probe found", () => {
  const plan = D.identityPlan(effective, agent, ["~/.ssh/id_ed25519"], HOME)
  const good = states(D.checklist({
    effective: effective, probe: D.parseProbe("T\tok\nA\tok\n"), agent: agent, plan: plan
  }))
  eq(good["Host reachable"], D.STATE_OK)
  eq(good["Authentication"], D.STATE_OK)
  eq(good["Key available"], D.STATE_OK)

  const bad = states(D.checklist({
    effective: effective, probe: D.parseProbe("T\tfail\nA\tunreachable\n"), agent: agent, plan: plan
  }))
  eq(bad["Host reachable"], D.STATE_BAD)
  eq(bad["Authentication"], D.STATE_BAD)
})

check("a proxied host is not called unreachable", () => {
  const viaProxy = states(D.checklist({ probe: D.parseProbe("T\tproxy\nA\tok\n"), agent: agent, plan: [] }))
  eq(viaProxy["Host reachable"], D.STATE_UNKNOWN, "we did not test what the jump host reaches")
  eq(viaProxy["Authentication"], D.STATE_OK)
})

check("no agent and no usable key is a finding, not a shrug", () => {
  const none = states(D.checklist({
    effective: effective, probe: null, agent: D.parseAgent("", 2), plan: []
  }))
  eq(none["SSH agent"], D.STATE_BAD)
  eq(none["Key available"], D.STATE_BAD)
})

// --------------------------------------------------------------- findings

const host = {
  name: "web1",
  file: "/home/u/.ssh/config",
  line: 2,
  identityFiles: ["~/.ssh/id_rsa"],
  duplicate: false,
  shadowed: [
    { key: "User", value: "someone-else", file: "/home/u/.ssh/conf.d/work.conf", line: 2,
      pattern: "web1", winnerValue: "deploy", winnerPattern: "web1" },
    { key: "User", value: "fallback", file: "/home/u/.ssh/config", line: 14,
      pattern: "*", winnerValue: "deploy", winnerPattern: "web1" }
  ]
}

check("an overriding include is reported, a catch-all is not", () => {
  const list = D.findings(host, effective, agent, null, [], HOME)
  const texts = list.map(f => f.text)
  eq(texts.filter(t => t.indexOf("someone-else") >= 0).length, 1, "the include that lost is named")
  eq(texts.filter(t => t.indexOf("fallback") >= 0).length, 0, "Host * losing is normal")
  ok(texts[0].indexOf("~/.ssh/conf.d/work.conf:2") >= 0, "with a file and a line")
})

check("a missing identity file the user asked for is an error", () => {
  const list = D.findings(host, effective, agent, null, [], HOME)
  ok(list.some(f => f.level === D.STATE_BAD && f.text.indexOf("~/.ssh/id_rsa") >= 0))
})

check("a duplicate host is reported with both places", () => {
  const duplicates = [{
    pattern: "web1",
    places: [{ file: "/home/u/.ssh/config", line: 2 }, { file: "/home/u/.ssh/conf.d/work.conf", line: 1 }]
  }]
  const list = D.findings(Object.assign({}, host, { duplicate: true }), effective, agent, null, duplicates, HOME)
  ok(list.some(f => f.text.indexOf("~/.ssh/config:2, ~/.ssh/conf.d/work.conf:1") >= 0))
})

check("the probe's own message is passed through, not paraphrased", () => {
  const probe = D.parseProbe("T\tok\nA\tdenied\nM\tPermission denied (publickey).\n")
  const list = D.findings(host, effective, agent, probe, [], HOME)
  ok(list.some(f => f.text === "Permission denied (publickey)."))
})

// -------------------------------------------------------------- list view

check("the row says what we know and no more", () => {
  eq(D.hostSubtitle({ name: "web1", user: "deploy", hostName: "10.0.0.1" }), "deploy@10.0.0.1")
  eq(D.hostSubtitle({ name: "web1", user: "", hostName: "" }), "web1", "falls back to the alias")

  eq(D.hostState(null), D.STATE_UNKNOWN)
  eq(D.hostState(D.parseProbe("T\tok\nA\tok\n")), D.STATE_OK)
  eq(D.hostState(D.parseProbe("T\tok\nA\tdenied\n")), D.STATE_WARN, "answered, but refused")
  eq(D.hostState(D.parseProbe("T\tfail\nA\tunreachable\n")), D.STATE_BAD)

  eq(D.hostDetail({ identityFiles: [] }, D.parseProbe("T\tfail\nA\tunreachable\n"), null, HOME), "Unreachable")
  eq(D.hostDetail({ identityFiles: ["/home/u/.ssh/id_x"] }, null, null, HOME), "~/.ssh/id_x")
  eq(D.hostDetail({ identityFiles: [] }, null, agent, HOME), "SSH Agent")
  eq(D.hostDetail({ wildcard: true, identityFiles: [] }, null, agent, HOME), "pattern",
     "a pattern is not a connection")
})

check("state is legible without color", () => {
  // Several themes map `urgent` to the same hue as the accent, so the four
  // states have to differ in shape too.
  const marks = [D.STATE_OK, D.STATE_BAD, D.STATE_WARN, D.STATE_UNKNOWN].map(D.dotFor)
  eq(marks.length, new Set(marks).size, "four states, four different marks")
  const checks = [D.STATE_OK, D.STATE_BAD, D.STATE_WARN, D.STATE_UNKNOWN].map(D.glyphFor)
  eq(checks.length, new Set(checks).size, "and four different checklist glyphs")
})

check("filtering looks where people look", () => {
  const hosts = [
    { name: "web1", hostName: "10.0.0.1", user: "deploy", aliases: ["web1", "www"] },
    { name: "db1", hostName: "db.internal", user: "root", aliases: ["db1"] }
  ]
  eq(D.filterHosts(hosts, "web").map(h => h.name), ["web1"], "by name")
  eq(D.filterHosts(hosts, "10.0").map(h => h.name), ["web1"], "by hostname")
  eq(D.filterHosts(hosts, "root").map(h => h.name), ["db1"], "by user")
  eq(D.filterHosts(hosts, "www").map(h => h.name), ["web1"], "by alias")
  eq(D.filterHosts(hosts, "WEB").map(h => h.name), ["web1"], "case-insensitively")
  eq(D.filterHosts(hosts, "").length, 2, "an empty filter hides nothing")
})

check("patterns sort under the hosts they shape", () => {
  eq(D.orderHosts([{ name: "*", wildcard: true }, { name: "a" }, { name: "b" }]).map(h => h.name),
     ["a", "b", "*"])
})

check("the cursor wraps and survives a shrinking list", () => {
  eq(D.moveIndex(0, -1, 3), 2)
  eq(D.moveIndex(2, 1, 3), 0)
  eq(D.clampIndex(9, 3), 2)
  eq(D.clampIndex(1, 0), 0)
})

check("~ is put back the way the config file writes it", () => {
  eq(D.shortenPath("/home/u/.ssh/id_ed25519", HOME), "~/.ssh/id_ed25519")
  eq(D.shortenPath("/etc/ssh/key", HOME), "/etc/ssh/key")
  ok(D.samePath("~/.ssh/id", "/home/u/.ssh/id", HOME))
})

report("Diagnostics")
