import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Diagnostics.js" as Diagnostics

// Add or change one Host entry.
//
// Five fields, because those are the five this plugin claims to manage. Every
// other keyword in the block — ForwardAgent, ProxyJump, a comment someone
// wrote — is preserved by SshConfig.upsertHost and deliberately not shown
// here: a form that displays a subset must never be the thing that decides
// what the file keeps.
Item {
  id: root

  property var fields: null
  property string originalName: ""
  property string errorText: ""
  // While details are hidden, the four fields that say where and as whom are
  // echoed like passwords. Typing still works; ^h shows them.
  property bool hidden: false

  property color foreground: Commons.Color.foreground
  property color accentColor: Commons.Color.accent
  property string fontFamily: Style.font.family

  // ---- Theme. The same derivations Panel.qml makes, from the same tokens.
  readonly property color surface: Commons.Color.popups.background
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color cardFill: Util.alpha(foreground, 0.06)
  readonly property color quietFill: Util.alpha(foreground, 0.12)
  readonly property bool rounded: Style.cornerRadius > 0
  readonly property int cardRadius: rounded ? Math.max(Style.cornerRadius * 2, Style.space(12)) : 0
  readonly property int buttonHeight: Math.max(Style.space(36), Style.font.body + Style.space(20))

  readonly property bool editing: originalName !== ""

  signal submitted(var values)
  signal canceled()
  // A paste is read by the widget, in a helper with a ceiling and a deadline,
  // and arrives later through paste(). The field asked for is remembered so
  // the text lands where the user pressed the keys, or nowhere if they have
  // since moved on.
  signal pasteRequested()
  property var pasteTarget: null

  function load() {
    var values = root.fields || {}
    hostField.text = values.Host || ""
    hostNameField.text = values.HostName || ""
    userField.text = values.User || ""
    portField.text = values.Port || ""
    identityField.text = values.IdentityFile || ""
  }

  function collect() {
    return {
      Host: hostField.text,
      HostName: hostNameField.text,
      User: userField.text,
      Port: portField.text,
      IdentityFile: identityField.text
    }
  }

  function submit() { root.submitted(root.collect()) }

  function focusFirst() { hostField.forceActiveFocus() }

  // Tab walks the five fields and wraps. Qt's own tab-focus chain would leave
  // the panel entirely, and KeyNavigation cannot be checked by qmllint
  // against a type it cannot resolve, so the order is spelled out here.
  readonly property var order: [hostField, hostNameField, userField, portField, identityField]

  function focusStep(delta) {
    for (var i = 0; i < root.order.length; i++) {
      if (!root.order[i].activeFocus) continue
      root.order[(i + delta + root.order.length) % root.order.length].forceActiveFocus()
      return
    }
    root.order[0].forceActiveFocus()
  }

  // ---- Editing, by hand. Every field is read-only to Qt (see Input below),
  //      which keeps cursor movement, selection and copy native and leaves
  //      changing the text to these.

  function replaceSelection(field, text) {
    var start = Math.min(field.selectionStart, field.selectionEnd)
    var end = Math.max(field.selectionStart, field.selectionEnd)
    var at = start === end ? field.cursorPosition : start
    if (start !== end) field.remove(start, end)
    field.insert(at, text)
    field.cursorPosition = at + text.length
  }

  // Backspace and Delete, with ctrl taking a word: the run of letters and
  // digits next to the cursor, after any punctuation in between, the way a
  // shell does it. A selection is removed whole instead.
  function erase(field, forward, word) {
    var start = Math.min(field.selectionStart, field.selectionEnd)
    var end = Math.max(field.selectionStart, field.selectionEnd)
    if (start === end) {
      var text = field.text
      var at = field.cursorPosition
      var isWord = function(c) { return /[A-Za-z0-9_]/.test(c) }
      start = end = at
      if (forward) {
        if (word) {
          while (end < text.length && !isWord(text.charAt(end))) end++
          while (end < text.length && isWord(text.charAt(end))) end++
        } else if (end < text.length) end++
      } else {
        if (word) {
          while (start > 0 && !isWord(text.charAt(start - 1))) start--
          while (start > 0 && isWord(text.charAt(start - 1))) start--
        } else if (start > 0) start--
      }
    }
    if (start === end) return
    field.remove(start, end)
    field.cursorPosition = start
  }

  // True when the key was an edit and has been made. Everything else — the
  // arrows, Home and End, shift-selection, select-all, copy, Enter — goes on
  // to the field's own handling, or past it to the panel.
  function edit(field, event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var alt = (event.modifiers & (Qt.AltModifier | Qt.MetaModifier)) !== 0

    if (event.matches(StandardKey.Paste)) {
      root.pasteTarget = field
      root.pasteRequested()
      return true
    }
    // Qt will not copy out of a field echoed as a password, so a cut there
    // would only delete; it does nothing, as Qt's own cut does.
    if (event.matches(StandardKey.Cut)) {
      if (field.echoMode === TextInput.Normal && field.selectionStart !== field.selectionEnd) {
        field.copy()
        root.erase(field, false, false)
      }
      return true
    }
    if (event.key === Qt.Key_Backspace) { root.erase(field, false, ctrl); return true }
    if (event.key === Qt.Key_Delete) { root.erase(field, true, ctrl); return true }

    // A printable character with no ctrl, alt or super held. Ctrl combinations
    // arrive as control characters and fail the test on their own.
    var text = event.text
    if (ctrl || alt || text.length === 0) return false
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i)
      if (code < 32 || code === 127) return false
    }
    root.replaceSelection(field, text)
    return true
  }

  function paste(text) {
    var field = root.pasteTarget
    root.pasteTarget = null
    if (!field || !field.activeFocus || text === "") return
    root.replaceSelection(field, text)
  }

  onFieldsChanged: root.load()
  // The panel builds this form on demand, with fields already set, and an
  // initial value is not a change.
  Component.onCompleted: root.load()

  implicitHeight: column.implicitHeight

  component Label: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  // Every field behaves the same: Tab walks, Enter saves, Esc cancels.
  //
  // No field is ever writable to Qt. A writable Qt text field fetches the
  // full clipboard on every change anywhere on the desktop, focused or not,
  // just to know whether a paste would be possible — inside this shell, with
  // no limit on size or time. A read-only one does not ask. So typing goes
  // through edit() above, a paste through bin/clipboard.sh, and the cursor is
  // shown by hand, since Qt hides it on a read-only field.
  component Input: TextField {
    id: input

    foreground: root.foreground
    accent: root.accentColor
    readOnly: true
    cursorVisible: input.activeFocus
    // Qt still places a delegate cursor on a read-only field, it only stops
    // painting its own. Steady rather than blinking: the blink is Qt's too.
    cursorDelegate: Rectangle {
      width: Style.spacing.hairline
      color: input.color
      visible: input.cursorVisible
    }

    Keys.onPressed: function(event) {
      if (root.edit(input, event)) event.accepted = true
    }

    onAccepted: root.submit()
    Keys.onEscapePressed: root.canceled()
    Keys.onTabPressed: function(event) {
      root.focusStep(1)
      event.accepted = true
    }
    Keys.onBacktabPressed: function(event) {
      root.focusStep(-1)
      event.accepted = true
    }
  }

  // One row of the grouped form: the keyword on the left, exactly as it is
  // spelled in the file, and its field taking the rest of the width.
  component FieldRow: Item {
    id: fieldRow
    required property string label
    property bool first: false
    default property alias input: slot.data

    width: parent ? parent.width : 0
    height: slot.childrenRect.height + Style.space(12)

    PanelSeparator {
      visible: !fieldRow.first
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      width: parent.width - Style.space(12)
      foreground: root.foreground
      strength: 0.08
    }

    Label {
      id: fieldLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(96)
      text: fieldRow.label
      font.pixelSize: Style.font.bodySmall
    }

    Item {
      id: slot
      anchors.left: fieldLabel.right
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      height: childrenRect.height
    }
  }

  // A full-width button. The one that saves is filled with the text color —
  // the accent is kept for things that are on, and saving is not a state.
  component ActionButton: Rectangle {
    id: button
    property string label: ""
    property bool primary: false
    signal activated()

    height: root.buttonHeight
    radius: root.rounded ? height / 2 : 0
    color: button.primary
      ? (buttonMouse.containsMouse ? Qt.darker(root.foreground, 1.1) : root.foreground)
      : (buttonMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : root.cardFill)

    Behavior on color { ColorAnimation { duration: Style.duration(120) } }

    Label {
      anchors.centerIn: parent
      text: button.label
      color: button.primary ? root.surface : root.foreground
      font.bold: true
    }
    MouseArea {
      id: buttonMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: button.activated()
    }
  }

  Column {
    id: column
    width: root.width
    spacing: Style.space(10)

    // A refused save says so first, before the fields, because the fields may
    // now hold what the other writer put there rather than what was typed.
    Rectangle {
      width: parent.width
      visible: root.errorText !== ""
      height: errorRow.implicitHeight + Style.space(20)
      radius: root.cardRadius
      color: Util.alpha(Commons.Color.urgent, 0.14)

      Row {
        id: errorRow
        x: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(24)
        spacing: Style.space(10)

        Label {
          id: errorGlyph
          text: "\u{F0026}"
          color: Commons.Color.urgent
          font.pixelSize: Style.font.icon
        }
        Label {
          width: parent.width - errorGlyph.width - parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          text: root.errorText
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }

    Label {
      width: parent.width
      leftPadding: Style.space(10)
      text: "ENTRY"
      color: root.dim
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 0.4
    }

    Rectangle {
      width: parent.width
      height: form.implicitHeight + Style.space(8)
      radius: root.cardRadius
      color: root.cardFill

      Column {
        id: form
        x: Style.space(4)
        y: Style.space(4)
        width: parent.width - Style.space(8)

        FieldRow {
          label: "Host"
          first: true
          Input {
            id: hostField
            width: parent.width
            password: root.hidden && Diagnostics.looksLikeAddress(root.originalName)
            placeholderText: "the name you type after ssh"
          }
        }
        FieldRow {
          label: "HostName"
          Input {
            id: hostNameField
            width: parent.width
            password: root.hidden
            placeholderText: "address or DNS name"
          }
        }
        FieldRow {
          label: "User"
          Input {
            id: userField
            width: parent.width
            password: root.hidden
            placeholderText: "your local user"
          }
        }
        FieldRow {
          label: "Port"
          Input {
            id: portField
            width: parent.width
            password: root.hidden
            placeholderText: "22"
            inputMethodHints: Qt.ImhDigitsOnly
          }
        }
        FieldRow {
          label: "IdentityFile"
          Input {
            id: identityField
            width: parent.width
            password: root.hidden
            placeholderText: "ssh's defaults"
          }
        }
      }
    }

    Label {
      width: parent.width
      leftPadding: Style.space(10)
      rightPadding: Style.space(10)
      text: root.hidden
        ? "Where and as whom are masked like passwords while details are hidden. "
          + "Typing still works; ^h shows them before you save."
        : root.editing
        ? "Only these five keywords change. Everything else in the block, and every "
          + "comment around it, is left exactly as it is."
        : "Written above the first Host * block, so its defaults cannot override what "
          + "you set here. Leave a field empty to let ssh decide."
      color: root.dim
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Row {
      width: parent.width
      spacing: Style.space(10)

      ActionButton {
        width: (parent.width - parent.spacing) / 2
        label: "Cancel"
        onActivated: root.canceled()
      }
      ActionButton {
        width: (parent.width - parent.spacing) / 2
        label: "Save"
        primary: true
        onActivated: root.submit()
      }
    }
  }
}
