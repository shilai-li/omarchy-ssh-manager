import QtQuick
import qs.Commons
import qs.Ui
import "Diagnostics.js" as Diagnostics

// One host, in full: what ssh resolved for it, which key it will actually
// reach for, and what happened the last time we asked the host itself.
//
// Presentation only. Every value here was produced by the ssh client and
// parsed in Diagnostics.js; this file decides nothing and runs nothing.
Item {
  id: root

  property var host: null
  property var effective: null
  property var probe: null
  property var agent: null
  property var plan: []
  property var findings: []
  property string home: ""
  property bool probing: false

  property color foreground: Color.foreground
  property color accentColor: Color.accent
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color dimmer: Qt.darker(foreground, 2.0)

  readonly property bool loaded: !!effective && effective.loaded === true
  readonly property var checks: Diagnostics.checklist({
    effective: root.effective,
    probe: root.probe,
    agent: root.agent,
    plan: root.plan
  })

  // `ssh -G` is the authority once it has answered; until then the parsed
  // config is a truthful stand-in rather than an empty table.
  function resolved(key, fallback) {
    if (root.loaded) {
      var value = Diagnostics.effectiveValue(root.effective, key, "")
      if (value !== "") return value
    }
    return fallback || ""
  }

  function colorFor(state) {
    if (state === Diagnostics.STATE_OK) return root.accentColor
    if (state === Diagnostics.STATE_BAD) return Color.urgent
    if (state === Diagnostics.STATE_WARN) return Color.urgent
    return root.dimmer
  }

  implicitHeight: column.implicitHeight

  // A label/value row from the effective configuration.
  component Field: Item {
    id: field
    required property string label
    required property string value
    property color valueColor: root.foreground

    width: column.width
    visible: value !== ""
    implicitHeight: Math.max(name.implicitHeight, text.implicitHeight)

    Text {
      id: name
      anchors.left: parent.left
      anchors.top: parent.top
      width: Style.space(104)
      textFormat: Text.PlainText
      text: field.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: text
      anchors.left: name.right
      anchors.right: parent.right
      anchors.top: parent.top
      textFormat: Text.PlainText
      text: field.value
      color: field.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
    }
  }

  Column {
    id: column
    width: root.width
    spacing: Style.space(4)

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.host ? root.host.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      visible: !!root.host && root.host.wildcard
      textFormat: Text.PlainText
      text: "A pattern, not a host — these values apply to every host it matches."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Item { width: 1; height: Style.space(6) }

    Field {
      label: "HostName"
      // ssh -G answers "hostname *" for a wildcard, which is only the pattern
      // echoed back and would read as a real address.
      value: root.host && root.host.wildcard
        ? ""
        : root.resolved("hostname", root.host ? root.host.hostName : "")
    }

    Field {
      label: "User"
      value: root.resolved("user", root.host ? root.host.user : "")
    }

    Field {
      label: "Port"
      value: root.resolved("port", root.host ? root.host.port : "")
    }

    Field {
      label: "ProxyJump"
      value: root.resolved("proxyjump", root.host ? root.host.proxy : "")
    }

    Field {
      label: "IdentityAgent"
      value: Diagnostics.shortenPath(root.resolved("identityagent", ""), root.home)
    }

    Item { width: 1; height: Style.space(8) }

    // ---- What ssh will actually reach for, in the order it will try. This
    //      is the question `ssh -G` alone cannot answer: it lists the six
    //      default key names whether or not they exist, and says nothing
    //      about what the agent is holding.
    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "IDENTITIES SSH WILL TRY"
      color: root.dimmer
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
      font.bold: true
    }

    Text {
      width: parent.width
      visible: root.plan.length === 0
      textFormat: Text.PlainText
      text: root.loaded ? "No usable key — nothing on disk, nothing in the agent." : "Asking ssh…"
      color: root.plan.length === 0 && root.loaded ? Color.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: root.plan

      Item {
        required property var modelData
        width: column.width
        implicitHeight: identityText.implicitHeight

        Text {
          id: identityMark
          anchors.left: parent.left
          anchors.verticalCenter: identityText.verticalCenter
          width: Style.space(14)
          textFormat: Text.PlainText
          text: modelData.exists === false ? Diagnostics.glyphFor(Diagnostics.STATE_BAD) : Diagnostics.glyphFor(Diagnostics.STATE_OK)
          color: modelData.exists === false ? Color.urgent : root.accentColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: identityText
          anchors.left: identityMark.right
          anchors.right: identityTag.left
          anchors.rightMargin: Style.space(8)
          anchors.top: parent.top
          textFormat: Text.PlainText
          text: Diagnostics.shortenPath(modelData.path, root.home)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideMiddle
        }

        Text {
          id: identityTag
          anchors.right: parent.right
          anchors.verticalCenter: identityText.verticalCenter
          textFormat: Text.PlainText
          text: {
            if (modelData.source === "agent") return "in agent"
            if (modelData.exists === false) return "missing"
            return modelData.loaded ? "on disk · in agent" : "on disk"
          }
          color: root.dimmer
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Item { width: 1; height: Style.space(10) }

    PanelSeparator {
      width: parent.width
      foreground: root.foreground
    }

    Item { width: 1; height: Style.space(8) }

    // ---- The checklist. A dash means "not asked", never "fine".
    Repeater {
      model: root.checks

      Item {
        required property var modelData
        width: column.width
        implicitHeight: checkLabel.implicitHeight

        Text {
          id: checkLabel
          anchors.left: parent.left
          anchors.top: parent.top
          textFormat: Text.PlainText
          text: modelData.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          anchors.right: checkGlyph.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: checkLabel.verticalCenter
          textFormat: Text.PlainText
          text: modelData.detail
          color: root.dimmer
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: checkGlyph
          anchors.right: parent.right
          anchors.verticalCenter: checkLabel.verticalCenter
          textFormat: Text.PlainText
          text: root.probing && (modelData.label === "Host reachable" || modelData.label === "Authentication")
            ? "…"
            : modelData.glyph
          color: root.colorFor(modelData.state)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    Item { width: 1; height: Style.space(8) }

    // ---- Findings. Only things ssh actually told us, each naming its file.
    Repeater {
      model: root.findings

      Text {
        required property var modelData
        width: column.width
        textFormat: Text.PlainText
        text: (modelData.level === Diagnostics.STATE_BAD ? "✗ " : "! ") + modelData.text
        color: modelData.level === Diagnostics.STATE_BAD ? Color.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    Text {
      width: parent.width
      visible: !!root.host
      textFormat: Text.PlainText
      text: root.host
        ? "defined in " + Diagnostics.shortenPath(root.host.file, root.home) + ":" + root.host.line
        : ""
      color: root.dimmer
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
      topPadding: Style.space(6)
    }
  }
}
