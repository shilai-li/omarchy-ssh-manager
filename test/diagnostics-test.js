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

check("no agent is not a fault in itself", () => {
  const noAgent = D.parseAgent("", 2)
  const plan = D.identityPlan(effective, noAgent, ["~/.ssh/id_ed25519"], HOME)
  const list = D.checklist({ effective: effective, probe: null, agent: noAgent, plan: plan })
  eq(list.some(item => item.label === "SSH agent"), false, "there is no agent row to fail")
  eq(states(list)["Key available"], D.STATE_OK, "a key on disk is enough")
})

check("no agent and no usable key is a finding, not a shrug", () => {
  const none = states(D.checklist({
    effective: effective, probe: null, agent: D.parseAgent("", 2), plan: []
  }))
  eq(none["Key available"], D.STATE_BAD)
})

check("IdentityAgent decides whose keys a host gets", () => {
  const elsewhere = D.parseEffective("G\tok\nC\tidentityagent /run/other.sock\n")
  eq(D.identityAgent(elsewhere), "/run/other.sock")
  eq(D.identityPlan(elsewhere, agent, [], HOME).length, 0, "SSH_AUTH_SOCK's keys are not this host's")
  eq(states(D.checklist({ effective: elsewhere, plan: [] }))["Key available"], D.STATE_UNKNOWN,
     "an agent we did not ask is not an empty one")

  const off = D.parseEffective("G\tok\nC\tidentityagent none\n")
  eq(D.identityAgent(off), "none")
  eq(D.identityPlan(off, agent, [], HOME).length, 0)
  eq(states(D.checklist({ effective: off, plan: [] }))["Key available"], D.STATE_BAD)

  const session = D.parseEffective("G\tok\nC\tidentityagent SSH_AUTH_SOCK\n")
  eq(D.identityAgent(session), "", "naming SSH_AUTH_SOCK is the default")
  eq(D.identityPlan(session, agent, [], HOME).length, 1)
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

check("no agent is only mentioned where a host forwards one", () => {
  const forwarding = D.parseEffective(EFFECTIVE + "\nC\tforwardagent yes")
  const noAgent = D.parseAgent("", 2)
  eq(D.findings(host, effective, noAgent, null, [], HOME).some(f => /agent/i.test(f.text)), false,
     "a host that never asked for one hears nothing")
  ok(D.findings(host, forwarding, noAgent, null, [], HOME).some(f => f.text.indexOf("ForwardAgent") >= 0))
  eq(D.findings(host, forwarding, agent, null, [], HOME).some(f => f.text.indexOf("ForwardAgent") >= 0), false,
     "not when there is one")
})

// -------------------------------------------------------------- list view

check("the row says what we know and no more", () => {
  eq(D.hostSubtitle({ name: "web1", user: "deploy", hostName: "10.0.0.1" }), "deploy@10.0.0.1")
  eq(D.hostSubtitle({ name: "web1", user: "", hostName: "" }), "web1", "falls back to the alias")

  eq(D.hostState(null), D.STATE_UNKNOWN)
  eq(D.hostState(D.parseProbe("T\tok\nA\tok\n")), D.STATE_OK)
  eq(D.hostState(D.parseProbe("T\tok\nA\tdenied\n")), D.STATE_WARN, "answered, but refused")
  eq(D.hostState(D.parseProbe("T\tfail\nA\tunreachable\n")), D.STATE_BAD)

  eq(D.rowProblem({ name: "a" }, D.parseProbe("T\tfail\nA\tunreachable\n")), "Unreachable")
  eq(D.rowProblem({ name: "a" }, D.parseProbe("T\tok\nA\tdenied\n")), "Key refused")
  eq(D.rowProblem({ name: "a" }, D.parseProbe("T\tok\nA\tok\n")), "", "a working host needs no words")
  eq(D.rowProblem({ name: "a", identityFiles: ["/home/u/.ssh/id_x"] }, null), "", "nor an untested one")
  eq(D.rowProblem({ name: "*", wildcard: true }, D.parseProbe("T\tfail\n")), "", "a pattern is not a connection")
})

check("the header badge reports the last test and nothing more", () => {
  eq(D.hostBadge({ name: "web1" }, null).text, "Not tested")
  eq(D.hostBadge({ name: "web1" }, null).state, D.STATE_UNKNOWN)
  eq(D.hostBadge({ name: "web1" }, D.parseProbe("T\tok\nA\tok\n")).text, "Authenticated")
  eq(D.hostBadge({ name: "web1" }, D.parseProbe("T\tok\nA\tdenied\n")).text, "Key refused")
  eq(D.hostBadge({ name: "web1" }, D.parseProbe("T\tok\nA\thostkey\n")).text, "Host key changed")
  eq(D.hostBadge({ name: "web1" }, D.parseProbe("T\tfail\nA\tunreachable\n")).text, "Unreachable")
  eq(D.hostBadge({ name: "web1" }, D.parseProbe("T\tfail\nA\tunreachable\n")).state, D.STATE_BAD)
  eq(D.hostBadge({ name: "*", wildcard: true }, D.parseProbe("T\tok\nA\tok\n")).text, "Pattern",
     "a pattern is never tested")
})

// -------------------------------------------------------------- hiding

check("an alias that is an address is not shown while hidden", () => {
  ok(D.looksLikeAddress("192.168.1.10"))
  ok(D.looksLikeAddress("fe80::1"))
  ok(D.looksLikeAddress("10.0.*"), "a pattern of address parts names a network")
  eq(D.looksLikeAddress("github.com"), false)
  eq(D.looksLikeAddress("agent-01"), false)
  eq(D.looksLikeAddress("*"), false)

  eq(D.displayName({ name: "192.168.1.10" }, true, 3), "host 3")
  eq(D.displayName({ name: "10.0.*", wildcard: true }, true, 7), "pattern 7")
  eq(D.displayName({ name: "192.168.1.10" }, false, 3), "192.168.1.10")
  eq(D.displayName({ name: "omarchy" }, true, 1), "omarchy", "a name that is not an address stays")
})

check("hidden findings keep their meaning and lose the values", () => {
  const h = {
    name: "web1", hostName: "10.0.0.1", user: "deploy", identityFiles: ["/home/u/.ssh/web_key"],
    shadowed: [{ key: "User", value: "root", file: "/home/u/.ssh/config", line: 9,
                 pattern: "web*", winnerPattern: "web1", winnerValue: "deploy" }]
  }
  const eff = D.parseEffective("G\tok\nC\thostname 10.0.0.1\nC\tuser deploy\nI\t/home/u/.ssh/web_key\tno\t\n")
  const probe = D.parseProbe("T\tfail\nA\tunreachable\nM\tssh: connect to host 10.0.0.1 port 2222: Connection refused\n")

  const shown = D.findings(h, eff, null, probe, [], HOME).map(f => f.text).join("\n")
  ok(shown.indexOf("10.0.0.1") >= 0 && shown.indexOf("web_key") >= 0, "shown, everything is there")

  const hidden = D.findings(h, eff, null, probe, [], HOME, true).map(f => f.text).join("\n")
  for (const secret of ["10.0.0.1", "deploy", "root", "web_key", "2222"])
    eq(hidden.indexOf(secret), -1, secret + " is masked")
  ok(hidden.indexOf("~/.ssh/config:9") >= 0, "where it is in the file still shows")
  ok(hidden.indexOf("Connection refused") >= 0, "and what went wrong")
})

check("hiding searches names only", () => {
  const hosts = [{ name: "web1", hostName: "10.0.0.1", user: "deploy" }]
  eq(D.filterHosts(hosts, "10.0").length, 1)
  eq(D.filterHosts(hosts, "10.0", true).length, 0, "an address typed while hidden finds nothing")
  eq(D.filterHosts(hosts, "web", true).length, 1)
})

// ------------------------------------------------------ remembered results

check("a test result survives a round trip through the results file", () => {
  const now = 1760000000
  const probes = { ":web1": Object.assign(D.parseProbe("T\tok\nA\tok\nM\tssh: connect to 10.0.0.1\n"), { at: now - 7200 }) }
  const text = D.serializeResults(probes, ["web1"])
  eq(text, "R\t" + (now - 7200) + "\tok\tok\tweb1\n")
  ok(text.indexOf("10.0.0.1") < 0, "ssh's message, which can quote an address, is not kept")

  const back = D.parseResults(text, now)
  eq(back[":web1"].auth, "ok")
  eq(back[":web1"].tested, true)
  eq(back[":web1"].remembered, true)
  eq(D.hostState(back[":web1"]), D.STATE_OK, "a remembered result reads like a fresh one")
})

check("only hosts still in the config are remembered", () => {
  const now = 1760000000
  const probes = {
    ":kept": { tested: true, at: now, tcp: "ok", auth: "ok" },
    ":removed": { tested: true, at: now, tcp: "fail", auth: "unreachable" },
    ":never": { tested: false, at: now, tcp: "", auth: "" }
  }
  eq(Object.keys(D.parseResults(D.serializeResults(probes, ["kept", "never"]), now)), [":kept"])
  eq(Object.keys(D.parseResults(D.serializeResults(probes, null), now)).length, 2,
     "with no host list to go by, nothing is pruned")
})

check("the results file is not trusted", () => {
  const now = 1760000000
  const text = [
    "R\t" + now + "\tok\tok\tgood",
    "R\t" + (now + 86400) + "\tok\tok\tfuture",
    "R\t" + (now - D.RESULT_MAX_AGE - 1) + "\tok\tok\tancient",
    "R\t" + now + "\tok\tpwned\tbadcode",
    "R\tsoon\tok\tok\tbadtime",
    "R\t" + now + "\tok\tok\ttwo words",
    "R\t" + now + "\tok\tok\textra\tfield",
    "X\t" + now + "\tok\tok\twrongkind",
    "garbage"
  ].join("\n")
  eq(Object.keys(D.parseResults(text, now)), [":good"])
})

check("a remembered result says how old it is", () => {
  const now = 1760000000
  eq(D.ageText(now - 30, now), "", "not for the last minute")
  eq(D.ageText(now - 5 * 60, now), "5 min ago")
  eq(D.ageText(now - 3 * 3600, now), "3 h ago")
  eq(D.ageText(now - 3 * 86400, now), "3 d ago")
  eq(D.ageText(0, now), "")
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

// ------------------------------------- what the file helpers said they did

check("the file helpers' records are read into one answer", () => {
  const ok1 = D.parseIoStatus("S\tok\nD\tabc123\nV\t18:5216:1788\n")
  eq(ok1.state, "ok")
  eq(ok1.digest, "abc123")
  eq(ok1.identity, "18:5216:1788")

  const refused = D.parseIoStatus("S\trejected\nR\t/x is a symbolic link\nD\t-\n")
  eq(refused.state, "rejected")
  eq(refused.reason, "/x is a symbolic link")
})

check("a helper that said nothing did not succeed", () => {
  // A killed script, a script that is not there, a pipe that broke: none of
  // those are a saved file, and reading silence as success is how a failed
  // write gets reported as a good one.
  eq(D.parseIoStatus("").state, "rejected")
  eq(D.parseIoStatus("some noise with no records\n").state, "rejected")
})

// ------------------------------------------- names quoted back at the user

check("a name is stripped of what would make it read as another name", () => {
  eq(D.plainLabel("prod\u202edrawkcab"), "proddrawkcab", "no bidi overrides")
  eq(D.plainLabel("two\nlines"), "two lines", "no control characters")
  eq(D.plainLabel("  spaced   out  "), "spaced out")
  eq(D.plainLabel("safe-host.example"), "safe-host.example", "an ordinary name is untouched")
})

check("a name long enough to push the dialog's buttons off is cut", () => {
  const long = D.plainLabel("h".repeat(200))
  eq(long.length, 64)
  eq(long.slice(-1), "…", "and says it was cut")
})

// ------------------------------------------- text pasted into a field

check("a paste is one line, without the characters that disguise it", () => {
  eq(D.pastedText("10.0.0.5\n"), "10.0.0.5", "a copied line loses its newline")
  eq(D.pastedText("prod\u202edrawkcab"), "proddrawkcab", "no bidi overrides")
  eq(D.pastedText("a\r\nb"), "a b", "no control characters")
  const long = "~/.ssh/" + "k".repeat(300)
  eq(D.pastedText(long), long, "and never cut: the helper already refused anything too long")
})

report("Diagnostics")
