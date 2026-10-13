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

  // ---- Theme. Nothing here names a color; the palette does.
  readonly property color contentForeground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(contentForeground, 1.5)
  readonly property color dimmer: Qt.darker(contentForeground, 2.0)
  readonly property color accentColor: Style.selectedStateColor(contentForeground, Commons.Color.accent)
  readonly property color hoverFill: Style.hoverFillFor(contentForeground, Commons.Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(contentForeground, Commons.Color.accent)

  readonly property int rowHeight: Math.max(Style.space(38), Style.font.body + Style.font.caption + Style.space(16))
  readonly property int listHeight: Math.max(rowHeight, Math.min(rows.length * rowHeight, rowHeight * 7))

  readonly property string agentSummary: {
    if (!agent || !agent.checked) return "checking agent…"
    if (!agent.running) return "no ssh-agent"
    if (agent.keys.length === 0) return "ssh-agent: no keys"
    return "ssh-agent: " + agent.keys.length + (agent.keys.length === 1 ? " key" : " keys")
  }

  readonly property string confirmMessage: {
    if (!root.confirming) return ""
    var name = Diagnostics.plainLabel(root.confirming.name)
    if (root.confirming.kind === "probe")
      return "Test Host " + name + "? This connects to it and offers your key."
    return "Remove Host " + name + " from " + Diagnostics.shortenPath(root.configPath, root.home) + "?"
  }

  readonly property string confirmAction: root.confirming && root.confirming.kind === "probe" ? "Test" : "Remove"

  readonly property string keyRail: {
    if (root.view === "editor") return "tab field   enter save   esc cancel"
    if (root.view === "details") return "c connect   t test   e edit   x remove   esc back"
    return "↑↓ move   enter connect   → details   ^t test   ^n new   type to filter   esc close"
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

  // Rows are a fixed height, so the position of the selected one is
  // arithmetic rather than a lookup into the Repeater's items.
  function ensureVisible() {
    var top = root.selectedIndex * root.rowHeight
    var bottom = top + root.rowHeight
    if (top < listScroll.contentY) listScroll.contentY = top
    else if (bottom > listScroll.contentY + listScroll.height) listScroll.contentY = bottom - listScroll.height
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
      // Up/Down are left alone so a long details view still scrolls.
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
      // A pattern is not somewhere to connect, so Enter shows what it does
      // instead of doing nothing.
      if (root.connectable) root.connectCurrent()
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

  // ---- One host row: state dot, name, user@hostname, and whatever we last
  //      learned about it.
  component HostRow: CursorSurface {
    id: row

    required property int index
    required property var modelData

    readonly property var probe: root.host && modelData ? root.host.probeFor(modelData.name) : null
    readonly property string state: Diagnostics.hostState(probe)

    width: parent ? parent.width : 0
    height: root.rowHeight
    hasCursor: root.cursorActive && root.selectedIndex === index
    foreground: root.contentForeground
    accent: Commons.Color.accent
    fill: root.hoverFill
    currentFill: root.selectedFill

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor

      onPositionChanged: function(mouse) { root.selectFromPointer(row.index, row, mouse) }

      onClicked: function(mouse) {
        root.selectedIndex = row.index
        if (mouse.button === Qt.RightButton) root.showDetails()
        else if (root.connectable) root.connectCurrent()
        else root.showDetails()
      }
    }

    Text {
      id: dot
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(14)
      textFormat: Text.PlainText
      text: Diagnostics.dotFor(row.state)
      color: {
        if (row.state === Diagnostics.STATE_OK) return root.accentColor
        if (row.state === Diagnostics.STATE_BAD) return Commons.Color.urgent
        if (row.state === Diagnostics.STATE_WARN) return Commons.Color.urgent
        return root.dimmer
      }
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Column {
      anchors.left: dot.right
      anchors.leftMargin: Style.space(4)
      anchors.right: detail.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: row.modelData ? Diagnostics.plainLabel(row.modelData.name, 96) : ""
        color: root.contentForeground
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: row.modelData && row.modelData.wildcard
          ? "pattern · applies to matching hosts"
          : Diagnostics.hostSubtitle(row.modelData)
        color: root.dim
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }

    Text {
      id: detail
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, row.width * 0.38)
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: root.host && root.host.probingHost === (row.modelData ? row.modelData.name : "")
        ? "testing…"
        : Diagnostics.hostDetail(row.modelData, row.probe, root.agent, root.home)
      color: row.state === Diagnostics.STATE_BAD ? Commons.Color.urgent : root.dimmer
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(520))
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
        spacing: Style.space(8)

        // ---- Header: title, and the filter doubling as the search box.
        Item {
          width: parent.width
          implicitHeight: title.implicitHeight

          Text {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "SSH Manager"
            color: root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
            font.bold: true
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.agentSummary
            // A fact about the session, not a fault: keys on disk work without one.
            color: root.dimmer
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          visible: root.view === "list"
          textFormat: Text.PlainText
          text: root.filterText === "" ? "Search hosts…" : root.filterText
          color: root.filterText === "" ? root.dimmer : root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        PanelSeparator {
          width: parent.width
          foreground: root.contentForeground
        }

        // ---- List.
        Text {
          width: parent.width
          visible: root.view === "list" && root.rows.length === 0
          textFormat: Text.PlainText
          text: root.hosts.length === 0
            ? "No Host entries in " + Diagnostics.shortenPath(root.configPath, root.home) + ". Press ^n to add one."
            : "No host matches “" + root.filterText + "”"
          color: root.dim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)
        }

        Flickable {
          id: listScroll
          width: parent.width
          height: root.listHeight
          visible: root.view === "list" && root.rows.length > 0
          contentWidth: width
          contentHeight: root.rows.length * root.rowHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            width: listScroll.width

            Repeater {
              model: root.view === "list" ? root.rows : []
              delegate: HostRow {}
            }
          }
        }

        // ---- Details.
        Flickable {
          id: detailScroll
          width: parent.width
          height: Math.min(details.implicitHeight, Style.space(400))
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
        }

        Text {
          width: parent.width
          visible: root.errorText !== "" && root.view !== "editor"
          textFormat: Text.PlainText
          text: root.errorText
          color: Commons.Color.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // When bin/scan.sh stops early — a cycle of Includes, a file it would
        // not open, a ceiling reached — the list below is partial, and a host
        // that is missing because of that looks exactly like one that was
        // never configured. Say so rather than let it read as complete.
        Text {
          width: parent.width
          visible: root.notes.length > 0 && root.view !== "editor"
          textFormat: Text.PlainText
          text: Diagnostics.plainLabel(root.notes.join(" · "), 200)
          color: Commons.Color.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.keyRail
          color: root.dimmer
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
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
