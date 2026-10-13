import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Diagnostics.js" as Diagnostics

// One host, in full: what ssh resolved for it, which key it will actually
// reach for, and what happened the last time we asked the host itself.
//
// Presentation only. Every value here was produced by the ssh client and
// parsed in Diagnostics.js; this file decides nothing and runs nothing. The
// buttons only say what was pressed — the panel decides what that means.
//
// Laid out the way the shell's newer panels are: the thing you came to do as
// one large button, the checks as a row of discs, the two other actions as
// tiles, and what ssh resolved as grouped lists. Groups are cards separated by
// space rather than one long column cut by rules.
Item {
  id: root

  property var host: null
  property var effective: null
  property var probe: null
  property var plan: []
  property var findings: []
  property string home: ""
  property bool probing: false
  property real now: 0

  property color foreground: Commons.Color.foreground
  property color accentColor: Commons.Color.accent
  property string fontFamily: Style.font.family

  signal connectRequested()
  signal testRequested()
  signal editRequested()
  signal removeRequested()

  // ---- Theme. The same derivations Panel.qml makes, from the same tokens.
  readonly property color surface: Commons.Color.popups.background
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color cardFill: Util.alpha(foreground, 0.06)
  readonly property color quietFill: Util.alpha(foreground, 0.12)
  readonly property color hoverFill: Style.hoverFillFor(foreground, Commons.Color.accent)
  readonly property bool rounded: Style.cornerRadius > 0
  readonly property int cardRadius: rounded ? Math.max(Style.cornerRadius * 2, Style.space(12)) : 0
  readonly property int innerRadius: Math.max(0, cardRadius - Style.space(4))
  readonly property int rowHeight: Math.max(Style.space(30), Style.font.body + Style.space(16))

  readonly property bool wildcard: !!host && host.wildcard === true
  readonly property bool loaded: !!effective && effective.loaded === true
  readonly property var checks: Diagnostics.checklist({
    effective: root.effective,
    probe: root.probe,
    plan: root.plan
  })

  // A host whose IdentityAgent names another socket gets its keys from an
  // agent nobody here asked, so an empty list is not the same as no key.
  readonly property bool otherAgent: {
    var socket = Diagnostics.identityAgent(root.effective)
    return socket !== "" && socket !== "none"
  }

  // `ssh -G` is the authority once it has answered; until then the parsed
  // config is a truthful stand-in rather than an empty table.
  function resolved(key, fallback) {
    if (root.loaded) {
      var value = Diagnostics.effectiveValue(root.effective, key, "")
      if (value !== "") return value
    }
    return fallback || ""
  }

  // Only the rows that have a value: an empty ProxyJump is not a fact worth a
  // line. ssh -G answers "hostname *" for a wildcard, which is only the
  // pattern echoed back and would read as a real address.
  readonly property var configRows: {
    var h = root.host
    var all = [
      ["HostName", root.wildcard ? "" : root.resolved("hostname", h ? h.hostName : "")],
      ["User", root.resolved("user", h ? h.user : "")],
      ["Port", root.resolved("port", h ? h.port : "")],
      ["ProxyJump", root.resolved("proxyjump", h ? h.proxy : "")],
      ["IdentityAgent", Diagnostics.shortenPath(root.resolved("identityagent", ""), root.home)]
    ]
    return all.filter(function(row) { return row[1] !== "" })
  }

  readonly property string target: {
    var user = root.resolved("user", root.host ? root.host.user : "")
    var name = root.resolved("hostname", root.host ? (root.host.hostName || root.host.name) : "")
    var port = root.resolved("port", root.host ? root.host.port : "")
    return (user ? user + "@" : "") + name + (port && port !== "22" ? " · port " + port : "")
  }

  readonly property string testSummary: {
    if (root.probing) return "Testing…"
    var badge = Diagnostics.hostBadge(root.host, root.probe)
    var age = root.probe ? Diagnostics.ageText(root.probe.at, root.now) : ""
    return age === "" ? badge.text : badge.text + " · " + age
  }

  readonly property var shortLabels: ({
    "Host reachable": "Reachable",
    "Key available": "Key",
    "Authentication": "Auth",
    "Config valid": "Config"
  })

  implicitHeight: column.implicitHeight

  // ---- Pieces.

  component Label: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
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

  // A check, as a disc: filled with the accent when it passed, with the urgent
  // color when it failed, tinted when it is a warning, and quiet when nobody
  // has asked. The glyph inside differs for each, so the four stay apart on a
  // theme whose urgent and accent are the same hue.
  component StatusDisc: Rectangle {
    id: disc
    property string check: Diagnostics.STATE_UNKNOWN
    property string glyph: Diagnostics.glyphFor(disc.check)
    property real size: Style.space(38)
    width: size
    height: size
    radius: root.rounded ? size / 2 : 0
    color: disc.check === Diagnostics.STATE_OK ? Commons.Color.accent
         : disc.check === Diagnostics.STATE_BAD ? Commons.Color.urgent
         : disc.check === Diagnostics.STATE_WARN ? Util.alpha(Commons.Color.urgent, 0.22)
         : root.quietFill

    Behavior on color { ColorAnimation { duration: Style.duration(120) } }

    Label {
      anchors.centerIn: parent
      text: disc.glyph
      color: disc.check === Diagnostics.STATE_OK || disc.check === Diagnostics.STATE_BAD ? root.surface
           : disc.check === Diagnostics.STATE_WARN ? Commons.Color.urgent
           : root.dim
      font.pixelSize: Math.round(disc.size * 0.42)
      font.bold: true
    }
  }

  // Test and Edit: the two things to do to a host besides connecting to it.
  component ActionTile: CursorSurface {
    id: tile
    property string label: ""
    property string status: ""
    property string glyph: ""
    signal activated()

    height: Style.space(12) * 2 + Style.space(38)
    radius: root.cardRadius
    color: root.cardFill
    fill: root.hoverFill
    foreground: root.foreground
    accent: Commons.Color.accent
    hasCursor: tileMouse.containsMouse

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.activated()
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Rectangle {
        width: Style.space(38)
        height: width
        radius: root.rounded ? width / 2 : 0
        color: root.quietFill

        Label {
          anchors.centerIn: parent
          text: tile.glyph
          font.pixelSize: Math.round(parent.width * 0.46)
        }
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(38) - Style.space(22)
        spacing: Style.space(1)

        Label {
          width: parent.width
          text: tile.label
          font.bold: true
          elide: Text.ElideRight
        }
        Label {
          width: parent.width
          text: tile.status
          color: root.dim
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }

  // A rule between rows of a grouped list, starting where the text does.
  component RowRule: PanelSeparator {
    property real inset: Style.space(12)
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.leftMargin: inset
    width: parent.width - inset
    foreground: root.foreground
    strength: 0.08
  }

  Column {
    id: column
    width: root.width
    spacing: Style.space(10)

    // ---- Connect: the reason anybody opened this host. A pattern is not
    //      somewhere to connect, so it says what it is instead.
    Card {
      height: heroColumn.implicitHeight + Style.space(36)

      Column {
        id: heroColumn
        anchors.centerIn: parent
        width: parent.width - Style.space(40)
        spacing: Style.space(10)

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          width: Style.space(52)
          height: width
          radius: root.rounded ? width / 2 : 0
          color: connectMouse.containsMouse && !root.wildcard ? Util.alpha(root.foreground, 0.2) : root.quietFill
          opacity: root.wildcard ? 0.45 : 1

          Behavior on color { ColorAnimation { duration: Style.duration(120) } }

          Label {
            anchors.centerIn: parent
            text: root.wildcard ? "*" : "\u{F018D}"
            font.pixelSize: Style.space(24)
          }
          MouseArea {
            id: connectMouse
            anchors.fill: parent
            enabled: !root.wildcard
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.connectRequested()
          }
        }
        Label {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.wildcard ? "A pattern, not a host" : "Connect"
          font.bold: true
          font.pixelSize: Style.font.subtitle
        }
        Label {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.wildcard
            ? "These values apply to every host it matches."
            : Diagnostics.plainLabel(root.target, 120)
          color: root.dim
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }

    // ---- The checklist, as discs. A dash means "not asked", never "fine".
    Card {
      visible: !root.wildcard
      height: checkRow.implicitHeight + Style.space(24)

      Row {
        id: checkRow
        x: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(8)

        Repeater {
          model: root.checks

          Column {
            required property var modelData
            readonly property bool waiting: root.probing
              && (modelData.label === "Host reachable" || modelData.label === "Authentication")
            width: checkRow.width / Math.max(1, root.checks.length)
            spacing: Style.space(6)

            StatusDisc {
              anchors.horizontalCenter: parent.horizontalCenter
              check: parent.waiting ? Diagnostics.STATE_UNKNOWN : parent.modelData.state
              glyph: parent.waiting ? "…" : Diagnostics.glyphFor(parent.modelData.state)
            }
            Label {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.shortLabels[parent.modelData.label] || parent.modelData.label
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              elide: Text.ElideRight
            }
            Label {
              width: parent.width
              leftPadding: Style.space(2)
              rightPadding: Style.space(2)
              horizontalAlignment: Text.AlignHCenter
              visible: text !== ""
              text: parent.waiting ? "asking…" : parent.modelData.detail
              color: parent.modelData.state === Diagnostics.STATE_BAD && !parent.waiting
                ? Commons.Color.urgent : root.dim
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }
          }
        }
      }
    }

    // ---- Findings. Only things ssh actually told us, each naming its file,
    //      and only when there are any.
    Card {
      visible: root.findings.length > 0
      height: findingList.implicitHeight + Style.space(16)

      Column {
        id: findingList
        x: Style.space(12)
        y: Style.space(8)
        width: parent.width - Style.space(24)
        spacing: Style.space(8)

        Repeater {
          model: root.findings

          Row {
            required property var modelData
            readonly property bool bad: modelData.level === Diagnostics.STATE_BAD
            width: findingList.width
            spacing: Style.space(10)

            Label {
              id: findingGlyph
              text: "\u{F0026}"
              color: parent.bad ? Commons.Color.urgent : root.dim
              font.pixelSize: Style.font.icon
            }
            Label {
              width: parent.width - findingGlyph.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              text: Diagnostics.plainLabel(parent.modelData.text, 240)
              color: parent.bad ? Commons.Color.urgent : root.foreground
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }

    // ---- Test and Edit, side by side.
    Row {
      width: parent.width
      spacing: Style.space(10)

      ActionTile {
        visible: !root.wildcard
        width: (parent.width - parent.spacing) / 2
        label: "Test"
        glyph: "\u{F0430}"
        status: root.testSummary
        onActivated: root.testRequested()
      }
      ActionTile {
        width: root.wildcard ? parent.width : (parent.width - parent.spacing) / 2
        label: "Edit"
        glyph: "\u{F03EB}"
        status: "Five fields, nothing else"
        onActivated: root.editRequested()
      }
    }

    // ---- What ssh resolved, from `ssh -G`.
    Item {
      width: parent.width
      height: Style.space(4)
    }

    Item {
      width: parent.width
      height: resolvedLabel.implicitHeight

      SectionLabel {
        id: resolvedLabel
        text: "WHAT SSH WILL USE"
      }
      SectionLabel {
        width: implicitWidth
        anchors.right: parent.right
        text: root.loaded ? "ssh -G" : "asking ssh…"
        font.bold: false
      }
    }

    Card {
      visible: root.configRows.length > 0
      height: configList.implicitHeight + Style.space(8)

      Column {
        id: configList
        x: Style.space(4)
        y: Style.space(4)
        width: parent.width - Style.space(8)

        Repeater {
          model: root.configRows

          Item {
            required property var modelData
            required property int index
            width: configList.width
            height: root.rowHeight

            RowRule { visible: parent.index > 0 }

            Label {
              id: configKey
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: parent.modelData[0]
              font.pixelSize: Style.font.bodySmall
            }
            Label {
              anchors.left: configKey.right
              anchors.leftMargin: Style.space(16)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignRight
              text: Diagnostics.plainLabel(parent.modelData[1], 160)
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideMiddle
            }
          }
        }
      }
    }

    // ---- What ssh will actually reach for, in the order it will try. This
    //      is the question `ssh -G` alone cannot answer: it lists the six
    //      default key names whether or not they exist, and says nothing
    //      about what the agent is holding.
    SectionLabel {
      visible: !root.wildcard
      topPadding: Style.space(4)
      text: "IDENTITIES SSH WILL TRY"
    }

    Card {
      visible: !root.wildcard
      height: identityList.implicitHeight + Style.space(8)

      Column {
        id: identityList
        x: Style.space(4)
        y: Style.space(4)
        width: parent.width - Style.space(8)

        Label {
          width: parent.width
          visible: root.plan.length === 0
          leftPadding: Style.space(12)
          rightPadding: Style.space(12)
          topPadding: Style.space(8)
          bottomPadding: Style.space(8)
          text: {
            if (!root.loaded) return "Asking ssh…"
            if (root.otherAgent) return "Whatever IdentityAgent holds — not listed here."
            return "No usable key — nothing on disk, nothing in an agent."
          }
          color: root.loaded && !root.otherAgent ? Commons.Color.urgent : root.dim
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Repeater {
          model: root.plan

          Item {
            id: identityRow
            required property var modelData
            required property int index
            readonly property bool missing: modelData.exists === false
            width: identityList.width
            height: Math.max(root.rowHeight, identityText.implicitHeight) + Style.space(12)

            RowRule {
              visible: identityRow.index > 0
              inset: Style.space(50)
            }

            Rectangle {
              id: identityIcon
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(28)
              height: width
              radius: root.rounded ? Style.space(7) : 0
              color: identityRow.missing ? Commons.Color.urgent : Commons.Color.accent

              Label {
                anchors.centerIn: parent
                text: identityRow.missing ? Diagnostics.glyphFor(Diagnostics.STATE_BAD) : "\u{F0306}"
                color: root.surface
                font.pixelSize: Style.font.icon
              }
            }

            Column {
              id: identityText
              anchors.left: identityIcon.right
              anchors.leftMargin: Style.space(12)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Label {
                width: parent.width
                text: Diagnostics.plainLabel(Diagnostics.shortenPath(identityRow.modelData.path, root.home), 160)
                font.bold: true
                elide: Text.ElideMiddle
              }
              Label {
                width: parent.width
                text: {
                  var key = identityRow.modelData
                  if (key.source === "agent") return "In the agent"
                  if (key.exists === false) return "Missing — no such file"
                  return key.loaded ? "On disk · in the agent" : "On disk"
                }
                color: identityRow.missing ? Commons.Color.urgent : root.dim
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }
    }

    // ---- Remove. Its own card, at the bottom, in the urgent color; the
    //      panel asks before anything is written.
    Card {
      height: removeRow.height + Style.space(8)

      CursorSurface {
        id: removeRow
        x: Style.space(4)
        y: Style.space(4)
        width: parent.width - Style.space(8)
        height: root.rowHeight + Style.space(6)
        radius: root.innerRadius
        fill: root.hoverFill
        foreground: root.foreground
        accent: Commons.Color.accent
        hasCursor: removeMouse.containsMouse

        MouseArea {
          id: removeMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.removeRequested()
        }

        Rectangle {
          id: removeIcon
          anchors.left: parent.left
          anchors.leftMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(28)
          height: width
          radius: root.rounded ? Style.space(7) : 0
          color: Util.alpha(Commons.Color.urgent, 0.18)

          Label {
            anchors.centerIn: parent
            text: "\u{F01B4}"
            color: Commons.Color.urgent
            font.pixelSize: Style.font.icon
          }
        }
        Label {
          anchors.left: removeIcon.right
          anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          text: "Remove host"
          color: Commons.Color.urgent
          font.bold: true
        }
        Label {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          text: "\u{F0142}"
          color: root.dim
          font.pixelSize: Style.font.icon
        }
      }
    }

    Label {
      width: parent.width
      visible: !!root.host
      leftPadding: Style.space(10)
      rightPadding: Style.space(10)
      text: root.host
        ? "Defined in " + Diagnostics.shortenPath(root.host.file, root.home) + ":" + root.host.line
          + ". Nothing here touches the network until you test."
        : ""
      color: root.dim
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
