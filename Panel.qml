import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "SshConfig.js" as SshConfig
import "Diagnostics.js" as Diagnostics

// The panel: a filtered list of hosts, and one host at a time in detail.
//
// Three views share one surface — list, details, editor — because they are
// three answers to the same question and swapping between them should not
// move the panel. The panel owns the cursor, the filter and which view is up;
// every host, probe and write lives on BarWidget.qml.
//
// Keys are handled here rather than by PanelKeyCatcher: typing filters the
// list, and the catcher's h/j/k/l/x bindings would make half the alphabet
// impossible to type. The editor's text fields own the keyboard outright
// while they are up.
//
// Drawn in the shell's card style: facts in the header, everything below it
// something to act on, related rows grouped on cards separated by space, and
// a card that does not apply is not drawn at all.
Panel {
  id: root
  moduleName: "shilai_li.ssh-manager"
  ipcTarget: "shilai_li.ssh-manager"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by has to be that
  // widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property var host: hostWidget

  // ---- Read-out of the host widget. Guarded throughout: the bar-widget
  //      contract instantiates this bare, before injection.
  readonly property var hosts: host ? host.hosts : []
  readonly property var agent: host ? host.agent : null
  readonly property string home: host ? host.home : ""
  readonly property string configPath: host ? host.configPath : ""
  readonly property string errorText: host ? host.errorText : ""
  readonly property var notes: host ? host.notes : []
  readonly property var duplicates: host ? host.duplicates : []
  readonly property bool configLoaded: host ? host.configLoaded === true : false
  readonly property string configState: host ? host.configState : ""

  // A test asked for over the IPC socket arrives as a name sitting here,
  // never as a connection. Nothing has touched the network yet when it does.
  readonly property string probeRequest: host ? host.probeRequest : ""

  property string view: "list"
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: true
  // What the confirmation dialog is asking about, if anything: { kind, name }.
  // Two things raise it, and they are the two things that are not undoable.
  // Removing a Host block rewrites the user's file. Testing opens a TCP
  // connection and offers a key to whatever answers — the panel is where
  // somebody is actually sitting, so the panel is where that gets agreed to,
  // whether the request came from a keystroke or from the socket.
  property var confirming: null
  property var editorFields: null
  property string editorOriginal: ""

  readonly property var rows: Diagnostics.filterHosts(Diagnostics.orderHosts(hosts), filterText)
  readonly property var currentHost: selectedIndex >= 0 && selectedIndex < rows.length ? rows[selectedIndex] : null
  readonly property string currentName: currentHost ? currentHost.name : ""
  readonly property bool connectable: !!currentHost && !currentHost.wildcard

  readonly property var currentEffective: host && currentName !== "" ? host.effectiveFor(currentName) : null
  readonly property var currentProbe: host && currentName !== "" ? host.probeFor(currentName) : null
  readonly property var currentPlan: host && currentName !== "" ? host.planFor(currentName) : []
  readonly property bool probing: !!host && host.probingHost === currentName && currentName !== ""

  // The one list of rows, drawn on two cards: hosts, then the patterns that
  // orderHosts already sorted to the bottom. Each keeps its index into `rows`,
  // so the cursor still walks a single list in the order it is drawn.
  function rowsWhere(wildcard) {
    var picked = []
    for (var i = 0; i < root.rows.length; i++)
      if (!!root.rows[i].wildcard === wildcard) picked.push({ host: root.rows[i], index: i })
    return picked
  }
  readonly property var hostRows: root.rowsWhere(false)
  readonly property var patternRows: root.rowsWhere(true)

  // Nothing to list and nothing filtered away: the panel is one card saying
  // why, and offering the way forward.
  readonly property bool emptyConfig: root.configLoaded && root.hosts.length === 0

  // ---- Theme. Nothing here names a color; the palette does.
  readonly property color contentForeground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color surface: Commons.Color.popups.background
  readonly property color dim: Qt.darker(contentForeground, 1.5)
  readonly property color accentColor: Style.selectedStateColor(contentForeground, Commons.Color.accent)
  readonly property color hoverFill: Style.hoverFillFor(contentForeground, Commons.Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(contentForeground, Commons.Color.accent)

  // Cards are a tint of the text color laid over the panel, so they sit on any
  // theme without a color of their own. Something that is on is filled with
  // the accent and carries its glyph in the panel's own color, cut out of it.
  readonly property color cardFill: Util.alpha(contentForeground, 0.06)
  readonly property color quietFill: Util.alpha(contentForeground, 0.12)

  // The theme decides whether anything is round. Square corners stay square;
  // rounded ones grow a step, because the cards here are larger than a row.
  readonly property bool rounded: Style.cornerRadius > 0
  readonly property int cardRadius: rounded ? Math.max(Style.cornerRadius * 2, Style.space(12)) : 0
  readonly property int innerRadius: Math.max(0, cardRadius - Style.space(4))

  readonly property int rowHeight: Math.max(Style.space(40), Style.font.body + Style.font.bodySmall + Style.space(18))

  readonly property bool agentHasKeys: !!agent && agent.checked && agent.running && agent.keys.length > 0
  readonly property string agentSummary: agentHasKeys
    ? "agent · " + agent.keys.length + (agent.keys.length === 1 ? " key" : " keys") : ""

  readonly property var badge: root.probing
    ? { state: Diagnostics.STATE_UNKNOWN, text: "Testing…" }
    : Diagnostics.hostBadge(root.currentHost, root.currentProbe)

  readonly property string title: {
    if (root.view === "details") return root.currentHost ? Diagnostics.plainLabel(root.currentHost.name, 64) : ""
    if (root.view === "editor") return root.editorOriginal !== ""
      ? "Edit " + Diagnostics.plainLabel(root.editorOriginal, 48) : "New host"
    return "SSH"
  }

  // The duplicates worth a card on the list. Details names every place; the
  // list only has to say that there is something to look at, and where first.
  readonly property var duplicateNote: {
    var list = root.duplicates || []
    if (list.length === 0) return null
    var first = list[0]
    var places = []
    for (var i = 0; i < first.places.length; i++)
      places.push(Diagnostics.shortenPath(first.places[i].file, root.home) + ":" + first.places[i].line)
    return {
      title: Diagnostics.plainLabel(first.pattern, 48) + " is declared " + first.places.length + " times",
      detail: "ssh reads " + places[0] + " first" + (places.length > 1 ? "; " + places.slice(1).join(", ") + " never wins" : "")
        + (list.length > 1 ? " · " + (list.length - 1) + " more" : "")
    }
  }

  readonly property string confirmMessage: {
    if (!root.confirming) return ""
    var name = Diagnostics.plainLabel(root.confirming.name)
    if (root.confirming.kind === "probe")
      return "Test Host " + name + "? This connects to it and offers your key."
    return "Remove Host " + name + " from " + Diagnostics.shortenPath(root.configPath, root.home) + "?"
  }

  readonly property string confirmAction: root.confirming && root.confirming.kind === "probe" ? "Test" : "Remove"

  // What the keys do from here, as key and meaning.
  readonly property var keyHints: {
    if (root.view === "editor") return [["tab", "next field"], ["enter", "save"], ["esc", "cancel"]]
    if (root.view === "details") {
      if (root.currentHost && root.currentHost.wildcard)
        return [["e", "edit"], ["x", "remove"], ["esc", "back"]]
      return [["c", "connect"], ["t", "test"], ["e", "edit"], ["x", "remove"], ["esc", "back"]]
    }
    if (root.emptyConfig) {
      if (root.configState === "rejected") return [["enter", "check again"], ["esc", "close"]]
      return [["enter", "new host"], ["esc", "close"]]
    }
    // The first page stays short: the keys that are not obvious from looking
    // at it. ↑↓ and ^t still work; details shows them.
    return [["enter", "connect"], ["→", "details"], ["^n", "new"], ["esc", "close"]]
  }

  // ---- Lifecycle.
  function open() {
    root.disarmPointer()
    root.showList()
    root.filterText = ""
    root.cursorActive = true
    if (root.host) root.host.refresh()
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) root.setCenterHoverRevealSuppressed(true)
    })
  }

  // The hide goes first. Everything after it is cosmetic, and this panel is
  // a full-screen layer-shell surface holding keyboard focus: a call that
  // throws before the hide lands leaves the user with no way out of it and a
  // bar that no longer answers. Nothing decorative gets to stand in front of
  // the one line that releases the screen.
  function close() {
    root.controller.hide()
    root.setCenterHoverRevealSuppressed(false)
  }

  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  //
  // The setter is the supported route: the `bar` a plugin is handed is a
  // PluginBarApi facade, where this flag is readonly and backed by a scoped
  // callback. Assigning to it throws rather than failing quietly, which is
  // why the direct write is only the fallback for a host that predates the
  // setter — and why it is now second.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // Closing on a details view and reopening should land on the list; a stale
  // editor holding half-typed fields would be worse.
  onOpenedChanged: {
    if (root.opened) {
      Qt.callLater(root.considerProbeRequest)
      return
    }
    root.showList()
    // A test that was asked for but never agreed to does not get to happen
    // behind the user's back the next time the panel comes up.
    if (root.host) root.host.clearProbeRequest()
  }

  // ---- Views.
  // Coming back to the list rebuilds its rows, and the one that appears under
  // a pointer resting on the panel gets a hover it never asked for. Disarming
  // the gate first is what keeps the cursor on the host the user just left.
  function showList() {
    root.disarmPointer()
    root.view = "list"
    root.cancelConfirm()
    root.editorFields = null
    Qt.callLater(function() {
      keys.forceActiveFocus()
      root.ensureVisible()
    })
  }

  function showDetails() {
    if (!root.currentHost) return
    root.view = "details"
    detailScroll.contentY = 0
    // `ssh -G` is offline and instant, so the details view asks for it on
    // arrival instead of making the user press a key to see the truth.
    if (root.host) root.host.loadEffective(root.currentName)
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function showEditor(fields, original) {
    root.editorFields = fields
    root.editorOriginal = original
    root.view = "editor"
    Qt.callLater(function() { editor.focusFirst() })
  }

  function editCurrent() {
    if (!root.currentHost || !root.host) return
    root.showEditor(SshConfig.fieldsFor(root.host.parsed, root.currentName), root.currentName)
  }

  function newHost() {
    root.showEditor({ Host: "", HostName: "", User: "", Port: "", IdentityFile: "" }, "")
  }

  function saveEditor(values) {
    if (!root.host) return
    if (!root.host.saveHost(values, root.editorOriginal)) return
    var saved = String(values.Host).replace(/^\s+|\s+$/g, "")
    root.showList()
    // The rescan is a process away, so follow the host by name once it lands
    // rather than by the index it used to have.
    Qt.callLater(function() { root.focusName(saved) })
  }

  function focusName(name) {
    root.disarmPointer()
    for (var i = 0; i < root.rows.length; i++) {
      if (root.rows[i].name === name) {
        root.selectedIndex = i
        root.ensureVisible()
        return
      }
    }
  }

  // ---- Actions.
  function connectCurrent() {
    if (!root.connectable || !root.host) return
    root.host.connectTo(root.currentName)
    root.close()
  }

  function testCurrent() {
    if (!root.currentHost || !root.host) return
    if (root.currentHost.wildcard) return
    root.host.probe(root.currentName)
  }

  function askRemove() {
    if (!root.currentHost) return
    root.confirming = { kind: "remove", name: root.currentName }
  }

  function cancelConfirm() {
    var pendingProbe = !!root.confirming && root.confirming.kind === "probe"
    root.confirming = null
    if (pendingProbe && root.host) root.host.clearProbeRequest()
  }

  function applyConfirm() {
    if (!root.confirming) return
    var request = root.confirming
    root.confirming = null
    if (!root.host || request.name === "") return

    if (request.kind === "probe") {
      root.host.confirmProbe()
      return
    }
    root.host.removeHost(request.name)
    root.showList()
  }

  // The empty panel's one way forward: a file that was refused is checked
  // again, and anything else gets its first host.
  function emptyAction() {
    if (root.configState === "rejected") {
      if (root.host) root.host.refresh()
    } else {
      root.newHost()
    }
  }

  // The panel has to be up before it can ask anything, and the request can
  // arrive either way round — the socket sets the name and then opens the
  // panel, and the panel can already be open when it does.
  function considerProbeRequest() {
    if (root.probeRequest === "" || !root.opened) return
    if (root.confirming) return
    root.focusName(root.probeRequest)
    root.showDetails()
    root.confirming = { kind: "probe", name: root.probeRequest }
  }

  onProbeRequestChanged: Qt.callLater(root.considerProbeRequest)

  function setFilter(text) {
    root.disarmPointer()
    root.filterText = text
    root.selectedIndex = 0
    root.cursorActive = true
    Qt.callLater(root.ensureVisible)
  }

  function moveCursor(delta) {
    if (root.rows.length === 0) return
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = Diagnostics.moveIndex(root.selectedIndex, delta, root.rows.length)
    root.ensureVisible()
  }

  // Only a pointer that has actually moved gets to choose a row. Rows that
  // reflow or are rebuilt under a stationary pointer produce hover events too,
  // and taking those at face value hands the cursor to whichever row landed
  // there — the same churn the shell's own menu and clipboard filter out.
  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: keys
  }

  // The rows sit on two cards with a heading between them, so the selected
  // row's position is asked of the row itself rather than worked out.
  function rowItem(index) {
    var repeaters = [hostRepeater, patternRepeater]
    for (var r = 0; r < repeaters.length; r++) {
      for (var i = 0; i < repeaters[r].count; i++) {
        var item = repeaters[r].itemAt(i)
        if (item && item.rowIndex === index) return item
      }
    }
    return null
  }

  function ensureVisible() {
    var item = root.rowItem(root.selectedIndex)
    if (!item) return
    var top = item.mapToItem(listContent, 0, 0).y
    var bottom = top + item.height
    if (top < listScroll.contentY) listScroll.contentY = Math.max(0, top - Style.space(8))
    else if (bottom > listScroll.contentY + listScroll.height)
      listScroll.contentY = Math.min(listScroll.contentHeight - listScroll.height, bottom - listScroll.height + Style.space(8))
  }

  onRowsChanged: root.selectedIndex = Diagnostics.clampIndex(root.selectedIndex, root.rows.length)

  // ---- Keys. One handler, three views. Anything not claimed here falls
  //      through to whatever has focus, which is how the editor's text fields
  //      keep working while this item still has Keys.priority.
  function handleKey(event) {
    if (root.confirming) return confirmDialog.handleKey(event)
    if (root.view === "editor") return false

    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0

    if (event.key === Qt.Key_Escape) {
      if (root.view === "details") root.showList()
      else if (root.filterText !== "") root.setFilter("")
      else root.close()
      return true
    }

    if (ctrl && event.key === Qt.Key_N) { root.newHost(); return true }
    if (ctrl && event.key === Qt.Key_E) { root.editCurrent(); return true }
    if (ctrl && event.key === Qt.Key_T) { root.testCurrent(); return true }
    if (ctrl && event.key === Qt.Key_R) { if (root.host) root.host.refresh(); return true }

    if (root.view === "details") {
      if (event.key === Qt.Key_Left || event.key === Qt.Key_Backspace) { root.showList(); return true }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.connectCurrent(); return true }
      if (event.text === "c") { root.connectCurrent(); return true }
      if (event.text === "t") { root.testCurrent(); return true }
      if (event.text === "e") { root.editCurrent(); return true }
      if (event.text === "n") { root.newHost(); return true }
      if (event.text === "x" || event.key === Qt.Key_Delete) { root.askRemove(); return true }
      if (event.text === "r" && root.host) { root.host.refresh(); return true }
      // Up/Down scroll the details rather than moving a cursor: everything on
      // this view has its own key, so there is nothing to walk.
      if (event.key === Qt.Key_Down) { root.scrollDetails(1); return true }
      if (event.key === Qt.Key_Up) { root.scrollDetails(-1); return true }
      return false
    }

    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
      return true
    }
    if (event.key === Qt.Key_Down) { root.moveCursor(1); return true }
    if (event.key === Qt.Key_Up) { root.moveCursor(-1); return true }
    if (event.key === Qt.Key_Right) { root.showDetails(); return true }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (root.emptyConfig) root.emptyAction()
      // A pattern is not somewhere to connect, so Enter shows what it does
      // instead of doing nothing.
      else if (root.connectable) root.connectCurrent()
      else root.showDetails()
      return true
    }
    if (event.key === Qt.Key_Delete) { root.askRemove(); return true }

    if (Util.editsFilter(event, root.filterText)) {
      root.setFilter(Util.editedFilter(event, root.filterText))
      return true
    }
    if (!ctrl && event.text && event.text.length === 1
        && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
      root.setFilter(root.filterText + event.text)
      return true
    }

    return false
  }

  function scrollDetails(direction) {
    var step = root.rowHeight * 2
    var max = Math.max(0, detailScroll.contentHeight - detailScroll.height)
    detailScroll.contentY = Math.max(0, Math.min(max, detailScroll.contentY + direction * step))
  }

  // ---- Pieces.

  component Label: Text {
    textFormat: Text.PlainText
    color: root.contentForeground
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.body
  }

  component Card: Rectangle {
    width: parent ? parent.width : 0
    radius: root.cardRadius
    color: root.cardFill
  }

  component SectionLabel: Label {
    width: parent ? parent.width : 0
    leftPadding: Style.space(10)
    rightPadding: Style.space(10)
    color: root.dim
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 0.4
  }

  // A small label in the header, beside the status.
  component Pill: Rectangle {
    id: pill
    property alias text: pillText.text
    property color textColor: root.dim
    property color dotColor: "transparent"
    property bool showDot: false
    width: pillRow.implicitWidth + Style.space(14)
    height: pillText.implicitHeight + Style.space(6)
    radius: root.rounded ? height / 2 : 0
    color: root.quietFill

    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: Style.space(5)

      Rectangle {
        visible: pill.showDot
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(6)
        height: width
        radius: width / 2
        color: pill.dotColor
      }
      Label {
        id: pillText
        color: pill.textColor
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }

  // Something worth a look before anything else: a partial read, a refused
  // write, a name declared twice. Shown as a card of its own, and only while
  // it is true.
  component AlertCard: Card {
    id: alert
    property string heading: ""
    property string detail: ""
    property bool urgent: false
    height: alertRow.implicitHeight + Style.space(20)
    color: alert.urgent ? Util.alpha(Commons.Color.urgent, 0.14) : root.cardFill

    Row {
      id: alertRow
      x: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - Style.space(24)
      spacing: Style.space(10)

      Label {
        id: alertGlyph
        text: "\u{F0026}"
        color: Commons.Color.urgent
        font.pixelSize: Style.font.icon
      }
      Column {
        width: parent.width - alertGlyph.width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Label {
          width: parent.width
          visible: alert.heading !== ""
          text: alert.heading
          font.bold: true
          wrapMode: Text.WordWrap
        }
        Label {
          width: parent.width
          visible: alert.detail !== ""
          text: alert.detail
          color: alert.heading === "" ? root.contentForeground : root.dim
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ---- One host row: what we last learned about it as a filled square, its
  //      name and user@hostname, and the same answer in words.
  component HostRow: CursorSurface {
    id: row

    required property var modelData
    required property int index
    readonly property int rowIndex: modelData.index
    readonly property var entry: modelData.host
    readonly property bool pattern: !!entry && entry.wildcard === true

    readonly property var probe: root.host && entry ? root.host.probeFor(entry.name) : null
    readonly property string hostState: row.pattern ? Diagnostics.STATE_UNKNOWN : Diagnostics.hostState(probe)
    readonly property bool testing: !!root.host && !!entry && root.host.probingHost === entry.name

    width: parent ? parent.width : 0
    height: root.rowHeight + Style.space(6)
    radius: root.innerRadius
    hasCursor: root.cursorActive && root.selectedIndex === row.rowIndex
    foreground: root.contentForeground
    accent: Commons.Color.accent
    fill: root.hoverFill
    currentFill: root.selectedFill

    PanelSeparator {
      visible: row.index > 0
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.leftMargin: Style.space(50)
      width: parent.width - Style.space(50)
      foreground: root.contentForeground
      strength: 0.08
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor

      onPositionChanged: function(mouse) { root.selectFromPointer(row.rowIndex, row, mouse) }

      onClicked: function(mouse) {
        root.selectedIndex = row.rowIndex
        if (mouse.button === Qt.RightButton) root.showDetails()
        else if (root.connectable) root.connectCurrent()
        else root.showDetails()
      }
    }

    // Filled with the accent when the last test authenticated, the urgent
    // color when it failed, tinted when it answered but refused, quiet when
    // nobody has asked. The glyph differs for each, so the four states stay
    // apart on a theme whose urgent is the same hue as its accent.
    Rectangle {
      id: mark
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(28)
      height: width
      radius: root.rounded ? Style.space(7) : 0
      color: row.testing || row.pattern ? root.quietFill
           : row.hostState === Diagnostics.STATE_OK ? Commons.Color.accent
           : row.hostState === Diagnostics.STATE_BAD ? Commons.Color.urgent
           : row.hostState === Diagnostics.STATE_WARN ? Util.alpha(Commons.Color.urgent, 0.22)
           : root.quietFill

      Behavior on color { ColorAnimation { duration: Style.duration(120) } }

      Label {
        anchors.centerIn: parent
        text: row.testing ? "…" : row.pattern ? "*" : Diagnostics.glyphFor(row.hostState)
        color: row.testing || row.pattern ? root.dim
             : row.hostState === Diagnostics.STATE_OK || row.hostState === Diagnostics.STATE_BAD ? root.surface
             : row.hostState === Diagnostics.STATE_WARN ? Commons.Color.urgent
             : root.dim
        font.pixelSize: Style.font.body
        font.bold: true
      }
    }

    Column {
      anchors.left: mark.right
      anchors.leftMargin: Style.space(12)
      anchors.right: trail.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Label {
        width: parent.width
        text: row.entry ? Diagnostics.plainLabel(row.entry.name, 96) : ""
        color: row.pattern ? root.dim : root.contentForeground
        font.bold: true
        elide: Text.ElideRight
      }
      Label {
        width: parent.width
        text: row.pattern
          ? "Applies to every host it matches"
          : Diagnostics.plainLabel(Diagnostics.hostSubtitle(row.entry), 120)
        color: root.dim
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideMiddle
      }
    }

    // Words only when something is wrong; the square has already said how
    // the last test went.
    Label {
      id: trail
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      width: text === "" ? 0 : Math.min(implicitWidth, row.width * 0.4)
      horizontalAlignment: Text.AlignRight
      text: row.testing ? "testing…" : Diagnostics.rowProblem(row.entry, row.probe)
      color: row.hostState === Diagnostics.STATE_BAD && !row.testing ? Commons.Color.urgent : root.dim
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  component KeyHint: Row {
    id: keyHint
    required property var modelData
    spacing: Style.space(4)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: keyText.implicitWidth + Style.space(8)
      height: keyText.implicitHeight + Style.space(2)
      radius: root.rounded ? Style.space(4) : 0
      color: root.quietFill

      Label {
        id: keyText
        anchors.centerIn: parent
        text: keyHint.modelData[0]
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
    Label {
      anchors.verticalCenter: parent.verticalCenter
      text: keyHint.modelData[1]
      color: root.dim
      font.pixelSize: Style.font.caption
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    Item {
      id: keys
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { event.accepted = root.handleKey(event) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        // ---- Header: where you are, and the facts about it. Nothing here
        //      is a control except the way back.
        Item {
          width: parent.width
          height: Math.max(titleRow.implicitHeight, pills.implicitHeight)

          Row {
            id: titleRow
            anchors.left: parent.left
            anchors.right: pills.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(7)

            Rectangle {
              visible: root.view !== "list"
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(24)
              height: width
              radius: root.rounded ? width / 2 : 0
              color: backMouse.containsMouse ? Util.alpha(root.contentForeground, 0.2) : root.quietFill

              Label {
                anchors.centerIn: parent
                text: "\u{F0141}"
                font.pixelSize: Style.font.icon
              }
              MouseArea {
                id: backMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showList()
              }
            }
            Label {
              visible: root.view === "list"
              anchors.verticalCenter: parent.verticalCenter
              text: "\u{F018D}"
              color: root.dim
              font.pixelSize: Style.font.icon
            }
            Label {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, titleRow.width - Style.space(40))
              text: root.title
              font.bold: true
              font.pixelSize: Style.font.subtitle
              elide: Text.ElideRight
            }
          }

          Row {
            id: pills
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            // Shown only when an agent is holding keys. No agent is not a
            // fault — keys on disk work without one — so its absence is not
            // something to announce on every open.
            Pill {
              visible: root.view === "list" && root.agentHasKeys
              text: root.agentSummary
              showDot: true
              dotColor: Commons.Color.accent
            }
            // What the last test found, which is the one thing a glance at a
            // host should never get wrong.
            Pill {
              visible: root.view === "details" && !!root.currentHost
              text: root.badge.text.toUpperCase()
              showDot: root.badge.state !== Diagnostics.STATE_UNKNOWN
              dotColor: root.badge.state === Diagnostics.STATE_OK ? Commons.Color.accent : Commons.Color.urgent
              textColor: root.badge.state === Diagnostics.STATE_OK ? root.accentColor
                       : root.badge.state === Diagnostics.STATE_UNKNOWN ? root.dim
                       : Commons.Color.urgent
              color: root.badge.state === Diagnostics.STATE_OK ? Util.alpha(Commons.Color.accent, 0.16)
                   : root.badge.state === Diagnostics.STATE_UNKNOWN ? root.quietFill
                   : Util.alpha(Commons.Color.urgent, 0.16)
            }
            Pill {
              visible: root.view === "editor"
              text: root.editorOriginal !== "" && root.currentHost
                ? Diagnostics.shortenPath(root.currentHost.file, root.home) + ":" + root.currentHost.line
                : "above Host *"
            }
          }
        }

        // ---- List: the filter, anything that needs a look, then the hosts.
        Rectangle {
          width: parent.width
          visible: root.view === "list" && !root.emptyConfig
          height: Math.max(Style.space(34), filterLabel.implicitHeight + Style.space(16))
          radius: root.rounded ? height / 2 : 0
          color: root.cardFill

          Label {
            id: filterGlyph
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: "\u{F0349}"
            color: root.dim
            font.pixelSize: Style.font.icon
          }
          Label {
            id: filterLabel
            anchors.left: filterGlyph.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText === "" ? "Type to filter hosts" : root.filterText
            color: root.filterText === "" ? root.dim : root.contentForeground
            elide: Text.ElideLeft
          }
        }

        AlertCard {
          visible: root.errorText !== "" && root.view === "list" && root.configState !== "rejected"
          urgent: true
          detail: root.errorText
        }

        // When bin/scan.sh stops early — a cycle of Includes, a file it would
        // not open, a ceiling reached — the list below is partial, and a host
        // that is missing because of that looks exactly like one that was
        // never configured. Say so rather than let it read as complete.
        AlertCard {
          visible: root.notes.length > 0 && root.view === "list"
          urgent: true
          heading: "Not everything was read"
          detail: Diagnostics.plainLabel(root.notes.join(" · "), 200)
        }

        AlertCard {
          visible: root.duplicateNote !== null && root.view === "list" && root.filterText === ""
          heading: root.duplicateNote ? root.duplicateNote.title : ""
          detail: root.duplicateNote ? root.duplicateNote.detail : ""
        }

        Label {
          width: parent.width
          visible: root.view === "list" && !root.emptyConfig && root.rows.length === 0
          leftPadding: Style.space(10)
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)
          text: "No host matches “" + Diagnostics.plainLabel(root.filterText, 48) + "”"
          color: root.dim
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Flickable {
          id: listScroll
          width: parent.width
          height: Math.min(listContent.implicitHeight, Style.space(440))
          visible: root.view === "list" && root.rows.length > 0
          contentWidth: width
          contentHeight: listContent.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: listContent
            width: listScroll.width
            spacing: Style.space(6)

            SectionLabel {
              visible: root.hostRows.length > 0
              text: "HOSTS"
            }
            Card {
              visible: root.hostRows.length > 0
              height: hostList.implicitHeight + Style.space(8)

              Column {
                id: hostList
                x: Style.space(4)
                y: Style.space(4)
                width: parent.width - Style.space(8)

                Repeater {
                  id: hostRepeater
                  model: root.view === "list" ? root.hostRows : []
                  delegate: HostRow {}
                }
              }
            }

            SectionLabel {
              visible: root.patternRows.length > 0
              topPadding: Style.space(6)
              text: "PATTERNS"
            }
            Card {
              visible: root.patternRows.length > 0
              height: patternList.implicitHeight + Style.space(8)

              Column {
                id: patternList
                x: Style.space(4)
                y: Style.space(4)
                width: parent.width - Style.space(8)

                Repeater {
                  id: patternRepeater
                  model: root.view === "list" ? root.patternRows : []
                  delegate: HostRow {}
                }
              }
            }
          }
        }

        // ---- Nothing to list. The whole panel becomes one card that says
        //      why and offers the way forward, rather than an empty list that
        //      looks like a working one.
        Column {
          width: parent.width
          visible: root.view === "list" && root.emptyConfig
          spacing: Style.space(12)

          Item { width: 1; height: Style.space(4) }

          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.space(52)
            height: width
            radius: root.rounded ? Style.space(14) : 0
            color: root.configState === "rejected" ? Commons.Color.urgent : Commons.Color.accent

            Label {
              anchors.centerIn: parent
              text: root.configState === "rejected" ? "\u{F0026}" : "\u{F018D}"
              color: root.surface
              font.pixelSize: Style.space(26)
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)

            Label {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.configState === "rejected" ? "Config not opened"
                  : root.configState === "missing" ? "No ~/.ssh/config yet"
                  : "No hosts yet"
              font.bold: true
              font.pixelSize: Style.font.heading
            }
            Label {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.configState === "rejected" ? root.errorText
                  : root.configState === "missing"
                    ? "ssh is running on its defaults. Add a host and the file is created, readable only by you."
                    : "There is no Host entry in " + Diagnostics.shortenPath(root.configPath, root.home) + " yet."
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          Card {
            height: emptyRow.height + Style.space(8)

            CursorSurface {
              id: emptyRow
              x: Style.space(4)
              y: Style.space(4)
              width: parent.width - Style.space(8)
              height: root.rowHeight + Style.space(10)
              radius: root.innerRadius
              hasCursor: true
              foreground: root.contentForeground
              accent: Commons.Color.accent
              fill: root.hoverFill
              currentFill: root.selectedFill

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.emptyAction()
              }

              Rectangle {
                id: emptyIcon
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(28)
                height: width
                radius: root.rounded ? Style.space(7) : 0
                color: root.configState === "rejected" ? root.quietFill : Commons.Color.accent

                Label {
                  anchors.centerIn: parent
                  text: root.configState === "rejected" ? "\u{F0450}" : "\u{F0415}"
                  color: root.configState === "rejected" ? root.contentForeground : root.surface
                  font.pixelSize: Style.font.icon
                }
              }
              Column {
                anchors.left: emptyIcon.right
                anchors.leftMargin: Style.space(12)
                anchors.right: emptyTrail.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Label {
                  width: parent.width
                  text: root.configState === "rejected" ? "Check again" : "New host"
                  font.bold: true
                }
                Label {
                  width: parent.width
                  text: root.configState === "rejected"
                    ? "After the file is a regular file you own"
                    : "Host, HostName, User, Port, IdentityFile"
                  color: root.dim
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }
              Label {
                id: emptyTrail
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                text: "enter"
                color: root.accentColor
                font.pixelSize: Style.font.caption
              }
            }
          }

          Label {
            width: parent.width
            leftPadding: Style.space(4)
            rightPadding: Style.space(4)
            text: "Nothing here touches the network until you test a host."
            color: root.dim
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---- Details.
        Flickable {
          id: detailScroll
          width: parent.width
          height: Math.min(details.implicitHeight, Style.space(520))
          visible: root.view === "details"
          contentWidth: width
          contentHeight: details.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Details {
            id: details
            width: detailScroll.width
            host: root.currentHost
            effective: root.currentEffective
            probe: root.currentProbe
            plan: root.currentPlan
            findings: root.host && root.currentHost
              ? Diagnostics.findings(root.currentHost, root.currentEffective, root.agent,
                                     root.currentProbe, root.host.duplicates, root.home)
              : []
            home: root.home
            probing: root.probing
            foreground: root.contentForeground
            accentColor: root.accentColor
            fontFamily: root.contentFontFamily
            onConnectRequested: root.connectCurrent()
            onTestRequested: root.testCurrent()
            onEditRequested: root.editCurrent()
            onRemoveRequested: root.askRemove()
          }
        }

        // ---- Editor.
        Editor {
          id: editor
          width: parent.width
          visible: root.view === "editor"
          fields: root.editorFields
          originalName: root.editorOriginal
          errorText: root.errorText
          foreground: root.contentForeground
          accentColor: root.accentColor
          fontFamily: root.contentFontFamily
          onSubmitted: function(values) { root.saveEditor(values) }
          onCanceled: root.showList()
        }

        PanelSeparator {
          width: parent.width
          foreground: root.contentForeground
          strength: 0.08
        }

        Flow {
          width: parent.width
          spacing: Style.space(10)

          Repeater {
            model: root.keyHints
            delegate: KeyHint {}
          }
        }
      }

      // Both things worth asking about, in one dialog. The name in the
      // question goes through plainLabel first: it is the user's own text out
      // of their config, and a name carrying a bidi override or a newline can
      // make this sentence read on screen as a different sentence than the
      // one being agreed to.
      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        opened: root.confirming !== null
        message: root.confirmMessage
        confirmText: root.confirmAction
        background: Commons.Color.popups.background
        foreground: root.contentForeground
        selectedText: root.accentColor
        fontFamily: root.contentFontFamily
        onCanceled: {
          root.cancelConfirm()
          Qt.callLater(function() { keys.forceActiveFocus() })
        }
        onConfirmed: {
          root.applyConfirm()
          Qt.callLater(function() { keys.forceActiveFocus() })
        }
      }
    }
  }
}
