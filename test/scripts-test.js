// Run with: bash test/test.sh
//
// The shell scripts are the plugin's only contact with ssh and the
// filesystem, so they are tested by running them against a throwaway
// ~/.ssh — not by reading them. Nothing here connects to a host that
// exists: every probe target is a name that cannot resolve.
const { check, eq, ok, report } = require("./harness.js")
const { execFileSync } = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")

const C = require("../SshConfig.js")
const D = require("../Diagnostics.js")

const BIN = path.join(__dirname, "..", "bin")

function sandbox() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ssh-manager-test-"))
  fs.mkdirSync(path.join(dir, ".ssh", "conf.d"), { recursive: true })
  return dir
}

function run(script, args, home) {
  return execFileSync("bash", [path.join(BIN, script)].concat(args), {
    encoding: "utf8",
    timeout: 40000,
    env: Object.assign({}, process.env, { HOME: home })
  })
}

// --------------------------------------------------------------- scan.sh

check("scan.sh expands Include in place and re-attributes what follows", () => {
  const home = sandbox()
  const config = path.join(home, ".ssh", "config")
  fs.writeFileSync(config, "Host a\n  User one\nInclude conf.d/*.conf\nHost z\n  User last\n")
  fs.writeFileSync(path.join(home, ".ssh", "conf.d", "extra.conf"), "Host b\n  User two\n")

  const parsed = C.parseStream(run("scan.sh", [config], home))
  eq(parsed.blocks.map(b => b.criteria), ["a", "b", "z"], "in ssh's reading order")
  eq(path.basename(parsed.blocks[1].file), "extra.conf")
  eq(parsed.blocks[2].file, config, "the line after the Include is back in the main file")

  fs.rmSync(home, { recursive: true, force: true })
})

check("scan.sh survives what a real ~/.ssh throws at it", () => {
  const home = sandbox()
  const config = path.join(home, ".ssh", "config")
  // A glob that matches nothing, a file that is not there, and a self-include.
  fs.writeFileSync(config, [
    "Include conf.d/*.nothing",
    "Include /nonexistent/file",
    "Include config",
    "Host a",
    "  User one"
  ].join("\n"))

  const parsed = C.parseStream(run("scan.sh", [config], home))
  ok(parsed.blocks.length > 0, "it still produced the config")
  eq(parsed.blocks[parsed.blocks.length - 1].criteria, "a")

  fs.rmSync(home, { recursive: true, force: true })
})

check("scan.sh reads a path with a space in it", () => {
  const home = sandbox()
  const dir = path.join(home, ".ssh", "my configs")
  fs.mkdirSync(dir)
  fs.writeFileSync(path.join(dir, "one.conf"), "Host spaced\n  User s\n")
  const config = path.join(home, ".ssh", "config")
  // ssh's own spelling for a path with a space in it.
  fs.writeFileSync(config, 'Include "' + path.join(dir, "one.conf") + '"\n')

  const parsed = C.parseStream(run("scan.sh", [config], home))
  eq(parsed.blocks.map(b => b.criteria), ["spaced"])

  fs.rmSync(home, { recursive: true, force: true })
})

// ----------------------------------------------------------- effective.sh

check("effective.sh reports what ssh -G resolved, with the key's fingerprint", () => {
  const home = sandbox()
  const key = path.join(home, ".ssh", "id_test")
  execFileSync("ssh-keygen", ["-t", "ed25519", "-N", "", "-C", "test", "-q", "-f", key])
  const fingerprint = execFileSync("ssh-keygen", ["-l", "-f", key + ".pub"], { encoding: "utf8" }).split(" ")[1]

  fs.writeFileSync(path.join(home, ".ssh", "config"),
    "Host probe-target\n  HostName 127.0.0.1\n  User someone\n  Port 2222\n  IdentityFile " + key + "\n")

  const effective = D.parseEffective(run("effective.sh", ["probe-target", path.join(home, ".ssh", "config")], home))
  eq(effective.ok, true)
  eq(D.effectiveValue(effective, "hostname"), "127.0.0.1")
  eq(D.effectiveValue(effective, "user"), "someone")
  eq(D.effectiveValue(effective, "port"), "2222")

  const found = effective.identities.filter(i => i.path === key)
  eq(found.length, 1, "the configured key is listed")
  eq(found[0].exists, true)
  eq(found[0].fingerprint, fingerprint, "read from the public half, never the private one")

  fs.rmSync(home, { recursive: true, force: true })
})

check("effective.sh reports a config ssh refuses to parse", () => {
  const home = sandbox()
  fs.writeFileSync(path.join(home, ".ssh", "config"), "Host bad\n  NotAKeyword yes\n")

  const effective = D.parseEffective(run("effective.sh", ["bad", path.join(home, ".ssh", "config")], home))
  eq(effective.ok, false)
  ok(effective.error.indexOf("Bad configuration option") >= 0, "with ssh's own words")

  fs.rmSync(home, { recursive: true, force: true })
})

check("an encrypted key is fingerprinted without asking for anything", () => {
  const home = sandbox()
  const key = path.join(home, ".ssh", "id_locked")
  execFileSync("ssh-keygen", ["-t", "ed25519", "-N", "a-passphrase", "-q", "-f", key])
  fs.unlinkSync(key + ".pub")   // force the private-file path
  fs.writeFileSync(path.join(home, ".ssh", "config"),
    "Host locked\n  HostName 127.0.0.1\n  IdentityFile " + key + "\n")

  // If this ever tried to prompt for the passphrase it would hang on a
  // closed stdin rather than pass.
  const effective = D.parseEffective(run("effective.sh", ["locked", path.join(home, ".ssh", "config")], home))
  const found = effective.identities.filter(i => i.path === key)
  eq(found.length, 1)
  eq(found[0].exists, true)
  ok(found[0].fingerprint.indexOf("SHA256:") === 0, "fingerprint from the embedded public key")

  fs.rmSync(home, { recursive: true, force: true })
})

// --------------------------------------------------------------- probe.sh

check("probe.sh classifies a host that does not resolve", () => {
  const home = sandbox()
  fs.writeFileSync(path.join(home, ".ssh", "config"),
    "Host nowhere\n  HostName no-such-host.invalid\n  ConnectTimeout 3\n")

  const probe = D.parseProbe(run("probe.sh", ["nowhere", path.join(home, ".ssh", "config")], home))
  eq(probe.tcp, "fail")
  eq(probe.auth, "unreachable")
  ok(probe.message.length > 0, "and says why, in ssh's words")

  fs.rmSync(home, { recursive: true, force: true })
})

check("probe.sh does not claim to have tested a proxied host's TCP", () => {
  const home = sandbox()
  fs.writeFileSync(path.join(home, ".ssh", "config"),
    "Host behind\n  HostName 10.255.255.1\n  ProxyJump nowhere\n  ConnectTimeout 2\n")

  const probe = D.parseProbe(run("probe.sh", ["behind", path.join(home, ".ssh", "config")], home))
  eq(probe.tcp, "proxy", "the jump host is what reaches it")

  fs.rmSync(home, { recursive: true, force: true })
})

check("probe.sh answers rather than waiting for a human", () => {
  const home = sandbox()
  fs.writeFileSync(path.join(home, ".ssh", "config"),
    "Host nowhere\n  HostName no-such-host.invalid\n  ConnectTimeout 3\n")

  // BatchMode is not optional. Without it ssh would block on a prompt with no
  // terminal attached, and this would time out instead of returning.
  const out = execFileSync("bash", [path.join(BIN, "probe.sh"), "nowhere", path.join(home, ".ssh", "config")], {
    encoding: "utf8",
    timeout: 30000,
    stdio: ["ignore", "pipe", "pipe"],
    env: Object.assign({}, process.env, { HOME: home })
  })
  ok(out.indexOf("A\t") >= 0)

  fs.rmSync(home, { recursive: true, force: true })
})

report("scripts")
