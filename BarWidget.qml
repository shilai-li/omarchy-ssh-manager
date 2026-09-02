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

  // ---- Configuration. `configText` is the main file, and the only thing the
  //      editor ever writes; `parsed` is the whole include chain in ssh's
  //      reading order, which is what the diagnostics need.
  property string configText: ""
  property bool configLoaded: false
  property var parsed: SshConfig.parseStream("")
  property var hosts: []
  property var duplicates: []
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
    if (!scanProc.running) scanProc.running = true
    if (!agentProc.running) agentProc.running = true
  }

  function applyScan(text) {
    root.parsed = SshConfig.parseStream(text)
    root.hosts = SshConfig.hostsFrom(root.parsed)
    root.duplicates = SshConfig.duplicatesIn(root.parsed)
  }

  function applyAgent(text, exitCode) {
    root.agent = Diagnostics.parseAgent(text, exitCode)
  }

  // `ssh -G` is instant and offline, so the details view asks for it on
  // arrival rather than making the user press a key to see the truth.
  function loadEffective(name) {
    if (!name || effProc.running) return
    root.effectiveHost = name
    effProc.command = ["bash", root.pluginDir + "/bin/effective.sh", name]
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
    probeProc.command = ["bash", root.pluginDir + "/bin/probe.sh", name]
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
  //      do not have to touch.
  property var pendingWrite: null

  function saveHost(fields, originalName) {
    var result = SshConfig.upsertHost(root.configText, fields, originalName)
    if (!result.ok) {
      root.errorText = result.errors.join(" · ")
      return false
    }
    root.errorText = ""
    root.write(result.text)
    return true
  }

  function removeHost(name) {
    var result = SshConfig.removeHost(root.configText, name)
    if (!result.ok) {
      root.errorText = result.errors.join(" · ")
      return false
    }
    root.errorText = ""
    root.write(result.text)
    return true
  }

  // ~/.ssh may not exist yet on a fresh machine, and it must be 0700 when it
  // is created — ssh refuses to use a directory anyone else can read.
  function write(text) {
    root.pendingWrite = text
    ensureDirProc.running = true
  }

  function flushWrite() {
    if (root.pendingWrite === null) return
    var text = root.pendingWrite
    root.pendingWrite = null
    root.configText = text
    configFile.setText(text)
  }

  // ---- Connecting. The path a user would take by hand: their default
  //      terminal, running the system ssh client, against the host alias. No
  //      options are injected — whatever their config says is what happens.
  readonly property string launchScript:
    'if command -v uwsm-app >/dev/null 2>&1; then exec setsid uwsm-app -- "$@"; fi\n'
    + 'exec setsid "$@"'

  function connectTo(name) {
    if (!name) return
    Quickshell.execDetached(["bash", "-lc", root.launchScript, "bash",
      "xdg-terminal-exec", "ssh", name])
  }

  function statusJson() {
    var list = []
    for (var i = 0; i < root.hosts.length; i++) {
      var host = root.hosts[i]
      var probe = root.probeFor(host.name)
      list.push({
        name: host.name,
        wildcard: host.wildcard,
        hostName: host.hostName,
        user: host.user,
        port: host.port,
        identityFile: host.identityFiles.length > 0 ? host.identityFiles[0] : "",
        file: host.file,
        line: host.line,
        duplicate: host.duplicate === true,
        lastProbe: probe ? { tcp: probe.tcp, auth: probe.auth } : null
      })
    }

    var keys = []
    for (var k = 0; k < root.agent.keys.length; k++) {
      keys.push({
        fingerprint: root.agent.keys[k].fingerprint,
        comment: root.agent.keys[k].comment,
        type: root.agent.keys[k].type
      })
    }

    return JSON.stringify({
      configPath: root.configPath,
      files: root.parsed.files,
      hostCount: root.hostCount,
      agent: { running: root.agent.running, keys: keys },
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

  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.configLoaded = true
      root.configText = configFile.text()
      root.refresh()
    }
    onFileChanged: configFile.reload()
    // A FileView does not report its own writes as file changes, so the
    // rescan that repaints the list has to be hung off `saved` — and so does
    // the chmod, which must not race the write it is fixing up.
    onSaved: {
      // An atomic write replaces the file, so the mode comes from the umask
      // rather than from what was there before. 0600 is the mode ssh_config
      // is conventionally kept at, and tightening is never the wrong
      // direction.
      chmodProc.running = true
      root.refresh()
    }
    onSaveFailed: root.errorText = "Could not write " + root.configPath
    // No ~/.ssh/config at all is an ordinary state, not an error: the panel
    // opens empty and the first saved host creates the file.
    onLoadFailed: {
      root.configLoaded = true
      root.configText = ""
      root.refresh()
    }
  }

  Process {
    id: scanProc
    command: ["bash", root.pluginDir + "/bin/scan.sh", root.configPath]
    stdout: StdioCollector { id: scanOut; waitForEnd: true }
    onExited: root.applyScan(scanOut.text)
  }

  Process {
    id: agentProc
    command: ["ssh-add", "-l"]
    stdout: StdioCollector { id: agentOut; waitForEnd: true }
    onExited: function(exitCode) { root.applyAgent(agentOut.text, exitCode) }
  }

  Process {
    id: effProc
    stdout: StdioCollector { id: effOut; waitForEnd: true }
    onExited: root.applyEffective(effOut.text)
  }

  Process {
    id: probeProc
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: root.applyProbe(probeOut.text)
  }

  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", "-m", "700", root.home + "/.ssh"]
    onExited: root.flushWrite()
  }

  Process {
    id: chmodProc
    command: ["chmod", "600", root.configPath]
  }

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

  IpcHandler {
    target: "shilai_li.ssh-manager"

    function toggle(): void { root.togglePanel() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function refresh(): void { root.refresh() }
    function connect(host: string): void { root.connectTo(host) }
    function test(host: string): void { root.probe(host) }
    function status(): string { return root.statusJson() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰢹"
    active: root.opened
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: root.hostCount === 1 ? "1 SSH host" : root.hostCount + " SSH hosts"

    onPressed: function(b) { root.togglePanel() }
  }
}
