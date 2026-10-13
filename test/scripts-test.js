// Run with: bash test/test.sh
//
// The shell scripts are the plugin's only contact with ssh and the
// filesystem, so they are tested by running them against a throwaway
// ~/.ssh — not by reading them. Nothing here connects to a host that
// exists: every probe target is a name that cannot resolve.
const { check, eq, ok, report } = require("./harness.js")
const { execFileSync, spawnSync } = require("child_process")
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

// The file scripts answer on two channels at once — bytes on stdout, records
// on stderr — so they need both back, and neither may be allowed to throw on
// a non-zero exit: refusing to read a file is an answer, not a crash.
function runIo(script, args, home, input) {
  const result = spawnSync("bash", [path.join(BIN, script)].concat(args), {
    encoding: "utf8",
    timeout: 40000,
    input: input === undefined ? "" : input,
    env: Object.assign({}, process.env, { HOME: home })
  })
  return { out: result.stdout, status: D.parseIoStatus(result.stderr + result.stdout) }
}

// What config-write.sh reads: the byte count, then the bytes.
function framed(text) {
  return C.utf8Length(text) + "\n" + text
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

// ------------------------------------------------------- scan.sh's ceilings

check("scan.sh does not follow a cycle of Includes round again", () => {
  const home = sandbox()
  const config = path.join(home, ".ssh", "config")
  fs.writeFileSync(config, "Host a\nInclude loop.conf\n")
  fs.writeFileSync(path.join(home, ".ssh", "loop.conf"), "Host b\nInclude config\n")

  const parsed = C.parseStream(run("scan.sh", [config], home))
  eq(parsed.blocks.map(b => b.criteria), ["a", "b"], "each file read once, in order")
  ok(parsed.notes.join(" ").indexOf("cycle") >= 0, "and it says the cycle was not followed")

  fs.rmSync(home, { recursive: true, force: true })
})

check("scan.sh stops at a ceiling rather than reading a config graph out", () => {
  const home = sandbox()
  const config = path.join(home, ".ssh", "config")
  let text = ""
  for (let i = 0; i < 200; i++) {
    text += "Include conf.d/f" + i + ".conf\n"
    fs.writeFileSync(path.join(home, ".ssh", "conf.d", "f" + i + ".conf"), "Host h" + i + "\n")
  }
  fs.writeFileSync(config, text)

  const parsed = C.parseStream(run("scan.sh", [config], home))
  ok(parsed.files.length <= 65, "it stopped well before the 200th file")
  ok(parsed.notes.length > 0, "and said the configuration below is unread")

  fs.rmSync(home, { recursive: true, force: true })
})

check("scan.sh will not open an included file it cannot vouch for", () => {
  const home = sandbox()
  const config = path.join(home, ".ssh", "config")
  fs.writeFileSync(config, "Include conf.d/huge.conf\nHost after\n")
  fs.writeFileSync(path.join(home, ".ssh", "conf.d", "huge.conf"), "x".repeat(2 * 1024 * 1024))

  const parsed = C.parseStream(run("scan.sh", [config], home))
  eq(parsed.blocks.map(b => b.criteria), ["after"], "the rest of the config still arrives")
  ok(parsed.notes.join(" ").indexOf("larger than") >= 0, "and the skip is reported")

  fs.rmSync(home, { recursive: true, force: true })
})

// --------------------------------------------------------- config-read.sh

check("config-read.sh returns the file byte for byte, with a digest", () => {
  const home = sandbox()
  const config = path.join(home, ".ssh", "config")
  const text = "Host a\n  User one\n# a comment with no trailing newline"
  fs.writeFileSync(config, text)

  const read = runIo("config-read.sh", [config], home)
  eq(read.status.state, "ok")
  eq(read.out, text, "not a line at a time, and nothing added or trimmed")
  eq(read.status.digest,
     require("crypto").createHash("sha256").update(text).digest("hex"),
     "the digest is of exactly those bytes")

  fs.rmSync(home, { recursive: true, force: true })
})

check("a missing ~/.ssh/config is a state, not a failure", () => {
  const home = sandbox()
  const read = runIo("config-read.sh", [path.join(home, ".ssh", "config")], home)
  eq(read.status.state, "missing")
  eq(read.out, "")
  fs.rmSync(home, { recursive: true, force: true })
})

check("config-read.sh refuses a config that is a symlink somewhere else", () => {
  const home = sandbox()
  const config = path.join(home, ".ssh", "config")
  fs.writeFileSync(path.join(home, "elsewhere"), "Host stolen\n")
  fs.symlinkSync(path.join(home, "elsewhere"), config)

  const read = runIo("config-read.sh", [config], home)
  eq(read.status.state, "rejected")
  eq(read.out, "", "and nothing of the file it pointed at came back")
  ok(read.status.reason.indexOf("symbolic link") >= 0)

  fs.rmSync(home, { recursive: true, force: true })
})

check("config-read.sh refuses a config that is a pipe, rather than waiting", () => {
  const home = sandbox()
  const config = path.join(home, ".ssh", "config")
  execFileSync("mkfifo", [config])

  // Nothing will ever write to this FIFO. An unguarded read never returns.
  const read = runIo("config-read.sh", [config], home)
  eq(read.status.state, "rejected")
  ok(read.status.reason.indexOf("regular file") >= 0)

  fs.rmSync(home, { recursive: true, force: true })
})

check("config-read.sh refuses a config too large to be one", () => {
  const home = sandbox()
  const config = path.join(home, ".ssh", "config")
  fs.writeFileSync(config, "x".repeat(2 * 1024 * 1024))

  const read = runIo("config-read.sh", [config], home)
  eq(read.status.state, "rejected")
  eq(read.out, "", "and none of it was read into the shell")

  fs.rmSync(home, { recursive: true, force: true })
})

// -------------------------------------------------------- config-write.sh

check("config-write.sh creates ~/.ssh at 0700 and the config at 0600", () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "ssh-manager-test-"))
  const config = path.join(home, ".ssh", "config")
  const text = "Host a\n  User one\n"

  const write = runIo("config-write.sh", [config, "-"], home, framed(text))
  eq(write.status.state, "ok")
  eq(fs.readFileSync(config, "utf8"), text)
  eq(fs.statSync(path.join(home, ".ssh")).mode & 0o777, 0o700)
  eq(fs.statSync(config).mode & 0o777, 0o600, "0600 before it was published, not after")

  fs.rmSync(home, { recursive: true, force: true })
})

check("an edit made against a file that has since changed is refused", () => {
  const home = sandbox()
  const config = path.join(home, ".ssh", "config")
  fs.writeFileSync(config, "Host a\n")

  const read = runIo("config-read.sh", [config], home)
  fs.writeFileSync(config, "Host somebody-else-was-here\n")

  const write = runIo("config-write.sh", [config, read.status.digest], home, framed("Host mine\n"))
  eq(write.status.state, "conflict")
  eq(fs.readFileSync(config, "utf8"), "Host somebody-else-was-here\n", "their edit stands")

  fs.rmSync(home, { recursive: true, force: true })
})

check("config-write.sh writes the file, not what a symlink at its name points at", () => {
  const home = sandbox()
  const config = path.join(home, ".ssh", "config")
  const target = path.join(home, "target")
  fs.writeFileSync(target, "not ours\n")
  fs.symlinkSync(target, config)

  const write = runIo("config-write.sh", [config, "-"], home, framed("Host mine\n"))
  eq(write.status.state, "rejected")
  eq(fs.readFileSync(target, "utf8"), "not ours\n", "the file it pointed at is untouched")

  fs.rmSync(home, { recursive: true, force: true })
})

check("config-write.sh leaves nothing behind when it refuses", () => {
  const home = sandbox()
  const config = path.join(home, ".ssh", "config")
  fs.writeFileSync(config, "Host a\n")

  runIo("config-write.sh", [config, "not-the-digest"], home, framed("Host mine\n"))
  eq(fs.readdirSync(path.join(home, ".ssh")).filter(n => n.indexOf(".ssh-manager") === 0), [],
     "no staging file survives a refusal")

  fs.rmSync(home, { recursive: true, force: true })
})

check("a round trip through both scripts is byte-identical", () => {
  const home = sandbox()
  const config = path.join(home, ".ssh", "config")
  const original = "# top\n\nHost a\n  User one\n\nHost *\n  ServerAliveInterval 30\n"
  fs.writeFileSync(config, original)

  const read = runIo("config-read.sh", [config], home)
  const added = C.upsertHost(read.out, { Host: "tmp", HostName: "h", User: "", Port: "", IdentityFile: "" }, "")
  const write = runIo("config-write.sh", [config, read.status.digest], home, framed(added.text))
  eq(write.status.state, "ok")

  const back = runIo("config-read.sh", [config], home)
  const removed = C.removeHost(back.out, "tmp")
  const final = runIo("config-write.sh", [config, back.status.digest], home, framed(removed.text))
  eq(final.status.state, "ok")
  eq(fs.readFileSync(config, "utf8"), original, "add then remove leaves the file it started as")

  fs.rmSync(home, { recursive: true, force: true })
})

// ------------------------------------------------------------ results.sh

function stateHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "ssh-manager-test-"))
  fs.mkdirSync(path.join(home, ".local", "state"), { recursive: true, mode: 0o755 })
  return { home, file: path.join(home, ".local", "state", "shilai_li.ssh-manager", "results") }
}

check("results.sh remembers results at 0600 in a 0700 directory", () => {
  const { home, file } = stateHome()
  const text = "R\t1760000000\tok\tok\tweb1\n"

  const write = runIo("results.sh", ["write", file], home, framed(text))
  eq(write.status.state, "ok")
  eq(fs.statSync(path.dirname(file)).mode & 0o777, 0o700)
  eq(fs.statSync(file).mode & 0o777, 0o600)

  const read = runIo("results.sh", ["read", file], home)
  eq(read.status.state, "ok")
  eq(read.out, text, "byte for byte")

  fs.rmSync(home, { recursive: true, force: true })
})

check("nothing remembered yet is a state, not a failure", () => {
  const { home, file } = stateHome()
  const read = runIo("results.sh", ["read", file], home)
  eq(read.status.state, "missing")
  eq(read.out, "")
  fs.rmSync(home, { recursive: true, force: true })
})

check("results.sh neither reads nor writes through a symlink", () => {
  const { home, file } = stateHome()
  fs.mkdirSync(path.dirname(file), { mode: 0o700 })
  const target = path.join(home, "target")
  fs.writeFileSync(target, "R\t1760000000\tok\tok\tplanted\n")
  fs.symlinkSync(target, file)

  const read = runIo("results.sh", ["read", file], home)
  eq(read.status.state, "rejected")
  eq(read.out, "", "nothing of the target leaks out")

  const write = runIo("results.sh", ["write", file], home, framed("R\t1\tok\tok\tmine\n"))
  eq(write.status.state, "rejected", "as config-write.sh does")
  eq(fs.readFileSync(target, "utf8"), "R\t1760000000\tok\tok\tplanted\n", "the file it pointed at is untouched")

  fs.rmSync(home, { recursive: true, force: true })
})

check("results.sh refuses a directory it does not own outright", () => {
  const { home, file } = stateHome()
  fs.mkdirSync(path.dirname(file), { mode: 0o777 })
  fs.chmodSync(path.dirname(file), 0o777)
  const write = runIo("results.sh", ["write", file], home, framed("R\t1\tok\tok\tmine\n"))
  eq(write.status.state, "rejected")
  ok(!fs.existsSync(file))
  fs.rmSync(home, { recursive: true, force: true })
})

check("results.sh will not read or write past its ceiling", () => {
  const { home, file } = stateHome()
  fs.mkdirSync(path.dirname(file), { mode: 0o700 })
  fs.writeFileSync(file, "x".repeat(512 * 1024), { mode: 0o600 })
  eq(runIo("results.sh", ["read", file], home).status.state, "rejected")

  const write = runIo("results.sh", ["write", file], home, (1024 * 1024) + "\n")
  eq(write.status.state, "rejected")
  eq(fs.readdirSync(path.dirname(file)).filter(n => n.indexOf(".results") === 0), [],
     "no staging file survives a refusal")
  fs.rmSync(home, { recursive: true, force: true })
})

report("scripts")
