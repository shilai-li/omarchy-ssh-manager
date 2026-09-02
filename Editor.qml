import QtQuick
import qs.Commons
import qs.Ui

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

  property color foreground: Color.foreground
  property color accentColor: Color.accent
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property bool editing: originalName !== ""

  signal submitted(var values)
  signal canceled()

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

  onFieldsChanged: root.load()

  implicitHeight: column.implicitHeight

  // Every field behaves the same: Tab walks, Enter saves, Esc cancels.
  component Input: TextField {
    width: parent ? parent.width : 0
    foreground: root.foreground
    accent: root.accentColor

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

  // One labelled input. The label sits above the field rather than beside it
  // so a long identity path gets the whole panel width.
  component Field: Column {
    id: field
    required property string label
    property string hint: ""

    width: column.width
    spacing: Style.space(3)

    Text {
      textFormat: Text.PlainText
      text: field.label + (field.hint === "" ? "" : "   " + field.hint)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
  }

  Column {
    id: column
    width: root.width
    spacing: Style.space(10)

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.editing ? "Edit " + root.originalName : "New host"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
      elide: Text.ElideRight
    }

    Field {
      label: "HOST"
      hint: "the name you type after ssh"

      Input {
        id: hostField
        placeholderText: "web1"
      }
    }

    Field {
      label: "HOSTNAME"
      hint: "address to connect to"

      Input {
        id: hostNameField
        placeholderText: "192.168.1.10"
      }
    }

    Field {
      label: "USER"

      Input {
        id: userField
        placeholderText: "root"
      }
    }

    Field {
      label: "PORT"

      Input {
        id: portField
        placeholderText: "22"
        inputMethodHints: Qt.ImhDigitsOnly
      }
    }

    Field {
      label: "IDENTITYFILE"
      hint: "path to the private key"

      Input {
        id: identityField
        placeholderText: "~/.ssh/id_ed25519"
      }
    }

    Text {
      width: parent.width
      visible: root.errorText !== ""
      textFormat: Text.PlainText
      text: root.errorText
      color: Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Row {
      spacing: Style.space(8)

      Button {
        text: "Save"
        bordered: true
        foreground: root.foreground
        accent: root.accentColor
        fontFamily: root.fontFamily
        onClicked: root.submit()
      }

      Button {
        text: "Cancel"
        bordered: true
        foreground: root.foreground
        accent: root.accentColor
        fontFamily: root.fontFamily
        onClicked: root.canceled()
      }
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "Only these five keywords are written. Anything else already in the "
        + "block — and every comment around it — is left exactly as it is."
      color: Qt.darker(root.foreground, 2.0)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
