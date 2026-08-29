// SPDX-License-Identifier: MIT

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// omaperi — every peripheral in one bar widget.
//
// This file knows nothing about any device. `omaperi status` returns a list of
// devices, each with a list of controls tagged range/enum/toggle/action/
// readout/color, and the delegate below renders one QML control per tag. A new
// device is a new adapter in the CLI; nothing here changes.
Panel {
  id: root
  moduleName: "io.github.chimmy89.omaperi"
  // Panel registers open/close/toggle on this target itself; there are no
  // extra IPC methods to add, so let it manage the handler.
  ipcTarget: "omaperi"

  // The bar sizes each slot from the widget root's implicit size, so expose
  // the button row's here or the slot collapses to zero width.
  implicitWidth: slots.implicitWidth
  implicitHeight: slots.implicitHeight

  // ---- settings (shell.json layout entry) ----
  readonly property string binary: String(setting("binary", "omaperi"))
  readonly property int pollSeconds: Math.max(5, parseInt(setting("pollSeconds", 60)) || 60)
  readonly property int lowPct: Math.max(0, parseInt(setting("lowPct", 15)) || 15)
  readonly property bool showPercentage: setting("showPercentage", true) === true

  // ---- live state ----
  property var devices: []
  property var backends: []
  property string lastError: ""

  readonly property var batteryEntries: Model.batteryEntries(devices)

  // ---- process plumbing ----
  // `apply` prints the refreshed document, so a set and a poll parse the same
  // way and one round trip is enough to update the panel.
  property var pending: []

  function refresh() {
    runArgs(["status"])
  }

  function apply(deviceId, key, value) {
    runArgs(["apply", deviceId, key, String(value)])
  }

  function runArgs(args) {
    if (cli.running) {
      // Never drop a click; the queue drains in onExited.
      root.pending.push(args)
      return
    }
    cli.command = [root.binary].concat(args)
    cli.running = true
  }

  function handleOutput(text) {
    var parsed = Model.parseDocument(text)
    if (parsed.error) {
      root.lastError = parsed.error
      return
    }
    root.lastError = ""
    root.devices = parsed.devices
    root.backends = parsed.backends
  }

  Process {
    id: cli
    command: [root.binary, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleOutput(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text && String(text).trim()) root.lastError = String(text).trim()
    }
    onExited: {
      if (root.pending.length > 0) {
        var next = root.pending.shift()
        root.runArgs(next)
      }
    }
  }

  Timer {
    interval: root.pollSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: if (opened) refresh()

  // ---- bar ----
  // Grid rather than Row so a vertical bar stacks instead of overflowing.
  Grid {
    id: slots
    anchors.fill: parent
    spacing: 0
    rows: root.bar && root.bar.vertical ? (slots.children.length) : 1
    columns: root.bar && root.bar.vertical ? 1 : slots.children.length

    Repeater {
      model: root.batteryEntries
      delegate: WidgetButton {
        id: batteryButton
        required property var modelData
        bar: root.bar
        text: root.showPercentage
              ? modelData.glyph + " " + modelData.level + "%" + (modelData.charging ? " " : "")
              : modelData.glyph
        horizontalMargin: 8.75
        fontSize: Style.font.caption
        active: Model.isLow(modelData, root.lowPct)
        useActiveColor: true
        tooltipText: modelData.name + " · " + modelData.level + "%"
                     + (modelData.charging ? " · charging" : "")
        onPressed: root.toggle()
      }
    }

    // Keeps the panel reachable when nothing reports a battery — otherwise a
    // desk of wired devices would have no way in.
    WidgetButton {
      bar: root.bar
      visible: root.batteryEntries.length === 0
      text: Model.glyphFor("other")
      horizontalMargin: 8.75
      fontSize: Style.font.caption
      tooltipText: Model.tooltipFor(root.devices, root.backends)
      onPressed: root.toggle()
    }
  }

  // ---- panel ----
  // PopupCard, not KeyboardPanel: KeyboardPanel is a layer-shell window with
  // multi-monitor dismiss twins, and on a two-screen setup the second screen's
  // twin closes the panel about a second after the first screen opens it.
  // PopupCard is a plain xdg-popup with outside-click dismiss, which is all
  // this widget needs.
  PopupCard {
    id: panel
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    Item {
      id: keyCatcher
      anchors.fill: parent

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        Text {
          width: parent.width
          visible: root.devices.length === 0
          text: root.lastError !== "" ? root.lastError : "No peripherals detected"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        // ---------- one block per device ----------
        Repeater {
          model: root.devices

          delegate: Column {
            id: deviceBlock
            required property var modelData
            width: column.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: Model.glyphFor(deviceBlock.modelData.kind) + "  "
                    + deviceBlock.modelData.name
                    + (deviceBlock.modelData.battery
                       ? "  ·  " + deviceBlock.modelData.battery.level + "%"
                         + (deviceBlock.modelData.battery.charging ? " charging" : "")
                       : "")
            }

            Text {
              width: parent.width
              visible: !!deviceBlock.modelData.note
              text: deviceBlock.modelData.note || ""
              color: Color.foreground
              opacity: 0.6
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // ---------- one row per control, chosen by type ----------
            Repeater {
              model: deviceBlock.modelData.controls

              delegate: Column {
                id: ctlBlock
                required property var modelData
                readonly property var ctl: ctlBlock.modelData
                readonly property string deviceId: deviceBlock.modelData.id
                width: deviceBlock.width
                spacing: Style.space(4)

                // Label row for the types that do not carry their own label.
                Item {
                  width: parent.width
                  height: labelText.implicitHeight
                  visible: ctlBlock.ctl.type === "range" || ctlBlock.ctl.type === "readout"
                           || ctlBlock.ctl.type === "color"

                  Text {
                    id: labelText
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: ctlBlock.ctl.label
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.subtitle
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.displayValue(ctlBlock.ctl)
                    color: Color.foreground
                    opacity: 0.7
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                PanelSlider {
                  visible: ctlBlock.ctl.type === "range"
                  width: parent.width
                  bar: root.bar
                  integer: true
                  minimum: ctlBlock.ctl.min !== undefined ? ctlBlock.ctl.min : 0
                  maximum: ctlBlock.ctl.max !== undefined ? ctlBlock.ctl.max : 100
                  step: ctlBlock.ctl.step !== undefined ? ctlBlock.ctl.step : 1
                  value: ctlBlock.ctl.value !== undefined && ctlBlock.ctl.value !== null
                         ? ctlBlock.ctl.value : minimum
                  // Apply on release only: dragging would fire a subprocess per pixel.
                  onReleased: function (v) {
                    root.apply(ctlBlock.deviceId, ctlBlock.ctl.key, Math.round(v))
                  }
                }

                Dropdown {
                  visible: ctlBlock.ctl.type === "enum"
                  width: parent.width
                  label: ctlBlock.ctl.label
                  options: Model.dropdownOptions(ctlBlock.ctl)
                  value: String(ctlBlock.ctl.value)
                  onChanged: function (v) {
                    root.apply(ctlBlock.deviceId, ctlBlock.ctl.key, v)
                  }
                }

                Toggle {
                  visible: ctlBlock.ctl.type === "toggle"
                  width: parent.width
                  label: ctlBlock.ctl.label
                  checked: ctlBlock.ctl.value === true
                  onClicked: {
                    root.apply(ctlBlock.deviceId, ctlBlock.ctl.key,
                               ctlBlock.ctl.value === true ? "false" : "true")
                  }
                }

                Button {
                  visible: ctlBlock.ctl.type === "action"
                  width: parent.width
                  text: ctlBlock.ctl.label
                  onClicked: root.apply(ctlBlock.deviceId, ctlBlock.ctl.key, "1")
                }

                Row {
                  visible: ctlBlock.ctl.type === "color"
                  width: parent.width
                  spacing: Style.space(6)

                  Repeater {
                    model: Model.SWATCHES
                    delegate: Rectangle {
                      id: swatch
                      required property var modelData
                      width: Style.space(26)
                      height: Style.space(20)
                      radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                      color: swatch.modelData
                      border.width: String(ctlBlock.ctl.value).toLowerCase()
                                    === String(swatch.modelData).toLowerCase() ? 2 : 0
                      border.color: Color.foreground

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.apply(ctlBlock.deviceId, ctlBlock.ctl.key,
                                              swatch.modelData)
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // ---------- backends that are not running ----------
        Text {
          width: parent.width
          visible: Model.unavailableBackends(root.backends).length > 0
          text: "Inactive: " + Model.unavailableBackends(root.backends).join(", ")
          color: Color.foreground
          opacity: 0.5
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
