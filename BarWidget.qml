import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "SshConfig.js" as SshConfig
import "Diagnostics.js" as Diagnostics

// The bar face of SSH Manager, and the only place that runs anything.
//
// Everything this plugin knows comes from the system ssh client: `ssh -G` for
// the effective configuration, `ssh -o BatchMode=yes` for authentication,
// `ssh-add -l` for the agent. No SSH is implemented here, no credential is
// ever read, and the only file written is the user's own ~/.ssh/config.
//
// Panel.qml, Details.qml and Editor.qml are read-outs of this widget and call
// back into it, so a two-monitor desktop cannot end up with two disagreeing
// views of the same config.
//
// Two rules shape everything below, because this runs unsandboxed inside a
// shell that stays up for the length of a login session:
//
//   **Nothing is opened by name and trusted.** ~/.ssh/config, and every file
//   it Includes, can be replaced by anything running as this user — with a
//   symlink pointing elsewhere, with a FIFO that never answers, with a
//   gigabyte of text. Reads and writes go through bin/config-read.sh and
//   bin/config-write.sh, which check what a path is before they open it and
//   publish a new version as a 0600 file renamed into place against the
//   digest the edit was made from. There is no FileView here for that reason.
//
//   **Nothing runs without a ceiling.** Every helper is one of this plugin's
//   own scripts, started through an absolute /usr/bin/bash with a fixed PATH,
//   under a deadline on both sides, and torn down when this widget goes away.
BarWidget {
  id: root
  moduleName: "shilai_li.ssh-manager"

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.ssh/config"

  // The scripts ship next to this file. Deriving the directory from the QML
  // URL keeps the plugin working wherever it is installed, rather than
  // hardcoding the id under ~/.config/omarchy/plugins.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.slice(7)
    if (url.length > 1 && url.charAt(url.length - 1) === "/") url = url.slice(0, -1)
    return decodeURIComponent(url)
  }

  // Every process this widget starts is one of the scripts in bin/, started
  // by an absolute bash with a PATH of its own. The PATH this shell inherited
  // was decided by whatever launched it, possibly hours ago and possibly by
  // something the user has since forgotten they installed; `ssh`, `chmod` and
  // `bash` are not names to resolve through it. The rest of the environment
  // is passed through untouched — SSH_AUTH_SOCK is how the agent is found.
  readonly property string shellBin: "/usr/bin/bash"
  readonly property var trustedEnv: ({ "PATH": "/usr/bin:/bin" })

  function script(name) { return [root.shellBin, root.pluginDir + "/bin/" + name] }

  // ---- Configuration. `configText` is the main file, and the only thing the
  //      editor ever writes; `parsed` is the whole include chain in ssh's
  //      reading order, which is what the diagnostics need.
  property string configText: ""
  property bool configLoaded: false

  // What the file was when it was read: `configDigest` is the version any
  // edit is made against, and an empty one means the file could not be read
  // and must therefore not be written. `configIdentity` is the cheap
  // size:inode:mtime the watch compares against to notice an outside edit.
  property string configDigest: ""
  property string configIdentity: ""
  property string configState: ""

  property var parsed: SshConfig.parseStream("")
  property var hosts: []
  property var duplicates: []
  property var notes: []
  property string errorText: ""

  // ---- What ssh told us, per host. Probing touches the network, so it only
  //      ever happens when the user asks for it.
  property var agent: ({ checked: false, running: false, keys: [], message: "" })
  property var effectives: ({})
  property var probes: ({})
  property string effectiveHost: ""
  property string probingHost: ""

  readonly property int hostCount: {
    var n = 0
    for (var i = 0; i < hosts.length; i++) if (!hosts[i].wildcard) n++
    return n
  }

  function hostByName(name) {
    for (var i = 0; i < root.hosts.length; i++) if (root.hosts[i].name === name) return root.hosts[i]
    return null
  }

  // The one place a name from outside this process is turned into a name this
  // widget will act on: it has to be in the configuration as it stands right
  // now, spelled exactly, and not be a pattern. Everything reachable over IPC
  // goes through here.
  function knownAlias(name) {
    if (!name) return ""
    for (var i = 0; i < root.hosts.length; i++) {
      if (root.hosts[i].name === name && !root.hosts[i].wildcard) return root.hosts[i].name
    }
    return ""
  }

  function effectiveFor(name) {
    var entry = root.effectives[":" + name]
    return entry ? entry : null
  }

  function probeFor(name) {
    var entry = root.probes[":" + name]
    return entry ? entry : null
  }

  // ---- Reading. Three sources, each its own short-lived process.
  function refresh() {
    root.reload()
    if (!agentProc.running) agentProc.running = true
  }

  function reload() {
    if (!readProc.running && !writeProc.running) readProc.running = true
  }

  // The file, and what bin/config-read.sh made of it. A file it refused to
  // read leaves `configDigest` empty, which is what stops an edit from being
  // written on top of something we never saw.
  function applyRead(text, statusText) {
    var status = Diagnostics.parseIoStatus(statusText)
    var wasRejected = root.configState === "rejected"

    root.configLoaded = true
    root.configState = status.state
    root.configIdentity = status.identity

    if (status.state === "ok") {
      root.configText = text
      root.configDigest = status.digest
      if (wasRejected) root.errorText = ""
    } else if (status.state === "missing") {
      // No ~/.ssh/config at all is an ordinary state, not an error: the panel
      // opens empty and the first saved host creates the file.
      root.configText = ""
      root.configDigest = "-"
      if (wasRejected) root.errorText = ""
    } else {
      root.configText = ""
      root.configDigest = ""
      root.errorText = "Refusing to read " + root.configPath + ": " + status.reason
    }

    if (!scanProc.running) scanProc.running = true
  }

  function applyScan(text) {
    root.parsed = SshConfig.parseStream(text)
    root.hosts = SshConfig.hostsFrom(root.parsed)
    root.duplicates = SshConfig.duplicatesIn(root.parsed)
    root.notes = root.parsed.notes
  }

  function applyAgent(text, exitCode) {
    root.agent = Diagnostics.parseAgent(text, exitCode)
  }

  // `ssh -G` is instant and offline, so the details view asks for it on
  // arrival rather than making the user press a key to see the truth.
  function loadEffective(name) {
    if (!name || effProc.running) return
    root.effectiveHost = name
    effProc.command = root.script("effective.sh").concat([name])
    effProc.running = true
  }

  function applyEffective(text) {
    var next = ({})
    for (var key in root.effectives) next[key] = root.effectives[key]
    next[":" + root.effectiveHost] = Diagnostics.parseEffective(text)
    root.effectives = next
  }

  // The network probe. One at a time: two hosts in flight would need a second
  // Process and buy nothing — the user is looking at one host.
  function probe(name) {
    if (!name || probeProc.running) return
    root.probingHost = name
    probeProc.command = root.script("probe.sh").concat([name])
    probeProc.running = true
  }

  function applyProbe(text) {
    var next = ({})
    for (var key in root.probes) next[key] = root.probes[key]
    next[":" + root.probingHost] = Diagnostics.parseProbe(text)
    root.probes = next
    root.probingHost = ""
  }

  function planFor(name) {
    var host = root.hostByName(name)
    return Diagnostics.identityPlan(root.effectiveFor(name), root.agent,
                                    host ? host.identityFiles : [], root.home)
  }

  // ---- Writing. Every edit is a whole-file replacement built by
  //      SshConfig.upsertHost/removeHost, which copy through every line they
  //      do not have to touch, and is published by bin/config-write.sh
  //      against the digest this copy was read at.
  property string pendingWrite: ""

  function saveHost(fields, originalName) {
    var result = SshConfig.upsertHost(root.configText, fields, originalName)
    if (!result.ok) {
      root.errorText = result.errors.join(" · ")
      return false
    }
    root.errorText = ""
    return root.write(result.text)
  }

  function removeHost(name) {
    var result = SshConfig.removeHost(root.configText, name)
    if (!result.ok) {
      root.errorText = result.errors.join(" · ")
      return false
    }
    root.errorText = ""
    return root.write(result.text)
  }

  function write(text) {
    if (root.configDigest === "") {
      root.errorText = "Not writing " + root.configPath + " — it could not be read"
      return false
    }
    if (writeProc.running) {
      root.errorText = "A write is already in flight"
      return false
    }

    root.pendingWrite = text
    writeProc.command = root.script("config-write.sh").concat([root.configPath, root.configDigest])
    writeProc.running = true
    return true
  }

  function applyWrite(statusText) {
    var status = Diagnostics.parseIoStatus(statusText)
    root.pendingWrite = ""

    if (status.state === "ok") {
      root.configDigest = status.digest
      root.configIdentity = status.identity
      root.errorText = ""
    } else if (status.state === "conflict") {
      // Somebody else edited the file between the read and the save. Their
      // version wins and ours is dropped: this plugin is a way to edit the
      // user's file, not a claim on it.
      root.errorText = root.configPath + " changed on disk — your edit was not applied"
    } else {
      root.errorText = "Could not write " + root.configPath
        + (status.reason === "" ? "" : ": " + status.reason)
    }

    // Either way the truth is now on disk rather than in this process. Not
    // straight away: this runs from the write's own `exited`, and the reload
    // will not start while that process still counts as running.
    Qt.callLater(root.reload)
  }

  // ---- Connecting. The path a user would take by hand: their default
  //      terminal, running the system ssh client, against the host alias. No
  //      options are injected — whatever their config says is what happens.
  //
  // The three binaries are resolved through a fixed PATH and then run by
  // absolute path, but the terminal itself is handed the environment this
  // shell has: the user's own PATH is theirs to have inside their own shell,
  // it just does not get to decide what `ssh` means here.
  readonly property string launchScript:
    'trusted() { PATH=/usr/bin:/bin command -v -- "$1"; }\n'
    + 'term=$(trusted xdg-terminal-exec) || exit 1\n'
    + 'client=$(trusted ssh) || exit 1\n'
    + 'session=$(trusted setsid) || session=""\n'
    + 'app=$(trusted uwsm-app) || app=""\n'
    + 'if [ -n "$app" ]; then set -- "$app" -- "$term" "$client" "$1"; else set -- "$term" "$client" "$1"; fi\n'
    + 'if [ -n "$session" ]; then exec "$session" "$@"; fi\n'
    + 'exec "$@"'

  function connectTo(name) {
    var alias = root.knownAlias(name)
    if (alias === "") return false
    Quickshell.execDetached([root.shellBin, "-c", root.launchScript, "ssh-manager", alias])
    return true
  }

  // A probe opens a TCP connection and offers a key to whatever answers. That
  // is a thing to do because somebody asked for it, so a request arriving over
  // the IPC socket raises the panel and the confirmation rather than
  // connecting — see Panel.qml.
  property string probeRequest: ""

  function requestProbe(name) {
    var alias = root.knownAlias(name)
    if (alias === "") return false
    root.probeRequest = alias
    root.open()
    return true
  }

  function clearProbeRequest() { root.probeRequest = "" }

  function confirmProbe() {
    var alias = root.probeRequest
    root.probeRequest = ""
    if (alias !== "") root.probe(alias)
  }

  // What anything on this machine running as this user may ask this widget
  // for. It is deliberately less than the panel shows: the panel is on the
  // user's screen because the user opened it, and a socket is not.
  //
  // No hostnames, no usernames, no ports, no key paths, no file paths, no
  // agent fingerprints or key comments — an inventory of where this user's
  // infrastructure is and which keys open it is worth more to somebody who
  // should not have it than it is to a shell script. What is left is what a
  // script needs to drive the panel: which aliases exist, and whether they
  // are usable.
  function statusJson() {
    var list = []
    for (var i = 0; i < root.hosts.length; i++) {
      list.push({
        name: root.hosts[i].name,
        wildcard: root.hosts[i].wildcard,
        duplicate: root.hosts[i].duplicate === true
      })
    }

    return JSON.stringify({
      configPath: Diagnostics.shortenPath(root.configPath, root.home),
      configState: root.configState,
      fileCount: root.parsed.files.length,
      hostCount: root.hostCount,
      agent: { running: root.agent.running, keyCount: root.agent.keys.length },
      hosts: list
    })
  }

  // ---- Panel plumbing. Shape contract for shell.summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the bar-widget
  //      root, and the popout coordinator prefers closeForPopoutSwitch.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Same glyph and button the shell's own icon widgets use: BarIconButton
  // centers the ink optically, and the open-panel mark takes the shell's default.
  readonly property string glyph: "󰢹"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Component.onCompleted: root.refresh()

  // Nothing this widget started outlives it. A bar surface is torn down and
  // rebuilt on a monitor change, a theme reload or a plugin update, and a
  // helper left running from the last one would still be holding a pipe.
  Component.onDestruction: {
    readProc.running = false
    writeProc.running = false
    statProc.running = false
    scanProc.running = false
    agentProc.running = false
    effProc.running = false
    probeProc.running = false
  }

  // A helper that never comes back must not become a process that lives as
  // long as the session. Each script holds its own deadline; this is the one
  // that catches the case where the script itself is what is stuck — a
  // filesystem that stopped answering, a signal that went nowhere.
  component Deadline: Timer {
    id: deadline

    required property var proc
    required property string what

    interval: 60000
    repeat: false
    running: deadline.proc.running
    onTriggered: {
      deadline.proc.signal(15)
      deadline.proc.running = false
      root.errorText = deadline.what + " took too long and was stopped"
    }
  }

  Process {
    id: readProc
    command: root.script("config-read.sh").concat([root.configPath])
    environment: root.trustedEnv
    stdout: StdioCollector { id: readOut; waitForEnd: true }
    stderr: StdioCollector { id: readStatus; waitForEnd: true }
    onExited: root.applyRead(readOut.text, readStatus.text)
  }

  // The new contents go over stdin, length-prefixed — never argv, which any
  // other process on this machine can read out of /proc while it runs.
  Process {
    id: writeProc
    environment: root.trustedEnv
    stdinEnabled: true
    stdout: StdioCollector { id: writeStatus; waitForEnd: true }
    onStarted: {
      var text = root.pendingWrite
      writeProc.write(String(SshConfig.utf8Length(text)) + "\n")
      writeProc.write(text)
    }
    onExited: root.applyWrite(writeStatus.text)
  }

  // Noticing that something else edited the file. A FileView would watch it
  // for free, but only by reading it — which is the thing that has to be
  // guarded. So: a stat while the panel is up, and a reload when the file is
  // not the one we last read. Nothing runs while the panel is closed.
  Process {
    id: statProc
    command: root.script("config-read.sh").concat(["--stat", root.configPath])
    environment: root.trustedEnv
    stderr: StdioCollector { id: statStatus; waitForEnd: true }
    onExited: {
      var status = Diagnostics.parseIoStatus(statStatus.text)
      if (status.identity !== root.configIdentity) root.reload()
    }
  }

  Timer {
    interval: 3000
    repeat: true
    running: root.opened && root.configLoaded
    onTriggered: {
      if (!statProc.running && !readProc.running && !writeProc.running) statProc.running = true
    }
  }

  Process {
    id: scanProc
    command: root.script("scan.sh").concat([root.configPath])
    environment: root.trustedEnv
    stdout: StdioCollector { id: scanOut; waitForEnd: true }
    onExited: root.applyScan(scanOut.text)
  }

  Process {
    id: agentProc
    command: root.script("agent.sh")
    environment: root.trustedEnv
    stdout: StdioCollector { id: agentOut; waitForEnd: true }
    onExited: function(exitCode) { root.applyAgent(agentOut.text, exitCode) }
  }

  Process {
    id: effProc
    environment: root.trustedEnv
    stdout: StdioCollector { id: effOut; waitForEnd: true }
    onExited: root.applyEffective(effOut.text)
  }

  Process {
    id: probeProc
    environment: root.trustedEnv
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: root.applyProbe(probeOut.text)
  }

  Deadline { proc: readProc; what: "Reading " + root.configPath }
  Deadline { proc: writeProc; what: "Writing " + root.configPath }
  Deadline { proc: statProc; what: "Checking " + root.configPath }
  Deadline { proc: scanProc; what: "Reading the configuration" }
  Deadline { proc: agentProc; what: "Asking the ssh-agent" }
  Deadline { proc: effProc; what: "Asking ssh what it would do" }
  Deadline { proc: probeProc; what: "Testing the host" }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // The IPC socket is reachable by anything running as this user, and unlike
  // the panel there is nobody at a keyboard behind it. Every host name that
  // arrives here has to be an alias that is in the configuration right now
  // and is not a pattern, and the one action that touches the network asks
  // first.
  IpcHandler {
    target: "shilai_li.ssh-manager"

    function toggle(): void { root.togglePanel() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function refresh(): void { root.refresh() }

    function connect(host: string): string {
      return root.connectTo(host) ? "connecting to " + host : "no such host in " + root.configPath
    }

    function test(host: string): string {
      return root.requestProbe(host)
        ? "asking to test " + host + " — confirm in the panel"
        : "no such host in " + root.configPath
    }

    function status(): string { return root.statusJson() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: root.hostCount === 1 ? "1 SSH host" : root.hostCount + " SSH hosts"

    onPressed: function(b) { root.togglePanel() }
  }
}
