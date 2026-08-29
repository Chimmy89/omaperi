// SPDX-License-Identifier: MIT

import QtQuick
import QtQuick.Controls
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
  // "summary" keeps one fixed slot; "pills" gives each battery-bearing device
  // its own.
  readonly property string barMode: String(setting("barMode", "summary"))

  // ---- live state ----
  property var devices: []
  property var backends: []
  property string lastError: ""
  property string selectedId: ""

  readonly property var selectedDevice: Model.findDevice(devices, selectedId)
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent)
                                            : "transparent"

  readonly property var batteryEntries: Model.batteryEntries(devices)

  // ---- process plumbing ----
  // `apply` prints the refreshed document, so a set and a poll parse the same
  // way and one round trip is enough to update the panel.
  property var pending: []

  // Which control has a command in flight, as "deviceId/key". Applies are fast
  // now, but OpenRGB still costs about a second, and a click with no feedback
  // reads as a click that did nothing.
  property string busyKey: ""

  function refresh() {
    runArgs(["status"])
  }

  function apply(deviceId, key, value) {
    runArgs(["apply", deviceId, key, String(value)])
  }

  function runArgs(args) {
    if (cli.running) {
      // Never drop a click; the queue drains after the running call exits.
      root.pending.push(args)
      return
    }
    // Set here rather than in apply(), so a queued command marks its own
    // control busy when it finally starts rather than when it was clicked.
    root.busyKey = args[0] === "apply" ? (args[1] + "/" + args[2]) : ""
    cli.command = [root.binary].concat(args)
    cli.running = true
  }

  // `running` is still true inside onExited, so draining directly from there
  // pushes the queued call straight back onto `pending` and it is never run --
  // every action after the first one is silently swallowed. Defer until the
  // process object has settled.
  function drainPending() {
    if (cli.running || root.pending.length === 0) return
    runArgs(root.pending.shift())
  }

  function handleOutput(text) {
    // A failed run prints nothing on stdout; leave lastError alone so stderr's
    // message survives instead of being replaced by "unreadable output".
    if (!String(text || "").trim()) return
    var parsed = Model.parseDocument(text)
    if (parsed.error) {
      root.lastError = parsed.error
      return
    }
    root.lastError = ""
    root.devices = parsed.devices
    root.backends = parsed.backends
    root.selectedId = Model.resolveSelection(parsed.devices, root.selectedId)
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
    onExited: function (exitCode) {
      root.busyKey = ""
      if (exitCode !== 0 && root.lastError === "") {
        root.lastError = "omaperi exited with status " + exitCode
      }
      Qt.callLater(root.drainPending)
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
    rows: root.bar && root.bar.vertical ? 99 : 1
    columns: root.bar && root.bar.vertical ? 1 : 99

    // Summary: one slot that never moves or disappears.
    WidgetButton {
      bar: root.bar
      visible: root.barMode !== "pills"
      text: Model.summaryText(root.devices, root.showPercentage)
      horizontalMargin: 8.75
      fontSize: Style.font.caption
      active: Model.anyLow(root.devices, root.lowPct)
      useActiveColor: true
      tooltipText: Model.tooltipFor(root.devices, root.backends)
      onPressed: root.toggle()
    }

    // Pills: the widget glyph always first, so the click target stays put even
    // when every device is asleep, then one slot per reporting battery.
    // Wider than summary, and it changes width as devices wake and sleep.
    WidgetButton {
      bar: root.bar
      visible: root.barMode === "pills"
      text: Model.glyphFor("other")
      horizontalMargin: 8.75
      fontSize: Style.font.caption
      tooltipText: Model.tooltipFor(root.devices, root.backends)
      onPressed: root.toggle()
    }

    Repeater {
      model: root.barMode === "pills" ? root.batteryEntries : []
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

    // No key handling here on purpose: the bar is a layer-shell surface with
    // WlrLayershell.keyboardFocus = None (Bar.qml:1168), and this card is an
    // xdg-popup parented to it, so it can never receive a key event. Keyboard
    // support would mean being a layer-shell surface of our own, the way
    // KeyboardPanel is -- see README.
    Item {
      id: keyCatcher
      anchors.fill: parent

      // fittedContentHeight caps the card to what fits on screen, so a tall
      // device -- the webcam has ten controls -- was simply cut off with no
      // way to reach the rest. Scroll instead, and only when it overflows.
      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        ScrollIndicator.vertical: ScrollIndicator {}

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(14)

        // Errors used to render only when the device list was empty, so a
        // failed apply showed nothing at all. Clears on the next good poll.
        Rectangle {
          width: parent.width
          visible: root.lastError !== ""
          implicitHeight: errorText.implicitHeight + Style.space(14)
          height: visible ? implicitHeight : 0
          radius: Style.cornerRadius
          color: "transparent"
          border.width: 1
          border.color: Color.urgent

          Text {
            id: errorText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            text: root.lastError
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Text {
          width: parent.width
          visible: root.devices.length === 0 && root.lastError === ""
          text: "No peripherals detected"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        // ---------- one tab per device ----------
        Flow {
          width: parent.width
          spacing: Style.space(8)
          visible: root.devices.length > 0

          Repeater {
            model: root.devices

            delegate: Rectangle {
              id: tab
              required property var modelData
              width: tabLabel.implicitWidth + Style.space(20)
              height: Style.space(32)
              radius: Style.cornerRadius
              color: tab.modelData.id === root.selectedId ? root.selectedFill : "transparent"
              border.width: 1
              border.color: Color.popups.border

              Text {
                id: tabLabel
                anchors.centerIn: parent
                text: Model.tabLabel(root.devices, tab.modelData)
                color: root.barForeground
                // A device that cannot report right now still gets a tab, but
                // dimmed, so the panel does not pretend it is live.
                opacity: tab.modelData.note ? 0.55 : 1.0
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectedId = tab.modelData.id
              }
            }
          }
        }

        // ---------- the selected device ----------
        Column {
          id: deviceBlock
          visible: root.selectedDevice !== null
          width: column.width
          spacing: Style.space(8)

          // Never null, so the bindings below stay valid for the one frame
          // between a poll clearing the list and the tab strip catching up.
          readonly property var device: root.selectedDevice || ({ controls: [] })

          PanelSectionHeader {
            width: parent.width
            text: (deviceBlock.device.name || "")
                  + (deviceBlock.device.battery
                     ? "  ·  " + deviceBlock.device.battery.level + "%"
                       + (deviceBlock.device.battery.charging ? " charging" : "")
                     : "")
          }

          Text {
            width: parent.width
            visible: !!deviceBlock.device.note
            text: deviceBlock.device.note || ""
            color: Color.foreground
            opacity: 0.6
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---------- one row per control, chosen by type ----------
          Repeater {
            model: deviceBlock.device.controls

            delegate: Column {
              id: ctlBlock
              required property var modelData
              readonly property var ctl: ctlBlock.modelData
              readonly property string deviceId: root.selectedId
              readonly property bool busy: root.busyKey !== ""
                                           && root.busyKey === ctlBlock.deviceId + "/" + ctlBlock.ctl.key
              width: deviceBlock.width
              spacing: Style.space(4)
              opacity: ctlBlock.busy ? 0.45 : 1.0
              enabled: !ctlBlock.busy

              Behavior on opacity { NumberAnimation { duration: 90 } }

                // Label row for the types that do not carry their own label.
                Item {
                  width: parent.width
                  height: labelText.implicitHeight
                  visible: ctlBlock.ctl.type === "range" || ctlBlock.ctl.type === "readout"
                           || ctlBlock.ctl.type === "color" || ctlBlock.ctl.type === "enum"

                  Text {
                    id: labelText
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: ctlBlock.ctl.label
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.subtitle
                  }

                  Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)

                    // No colour can be read back from OpenRGB without its SDK
                    // server, so this chip shows what omaperi last set --
                    // which is why it is worth showing at all.
                    Rectangle {
                      visible: ctlBlock.ctl.type === "color"
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(14)
                      height: Style.space(14)
                      radius: Style.cornerRadius > 0 ? Style.space(3) : 0
                      color: String(ctlBlock.ctl.value || "#000000")
                      border.width: 1
                      border.color: Color.popups.border
                    }

                    // A 100-30000 slider cannot land on an exact figure, and
                    // DPI is a number people know and want to type.
                    NumberField {
                      visible: ctlBlock.ctl.editable === true
                      anchors.verticalCenter: parent.verticalCenter
                      value: ctlBlock.ctl.value !== undefined && ctlBlock.ctl.value !== null
                             ? ctlBlock.ctl.value : 0
                      from: ctlBlock.ctl.min !== undefined ? ctlBlock.ctl.min : 0
                      to: ctlBlock.ctl.max !== undefined ? ctlBlock.ctl.max : 100000
                      stepSize: ctlBlock.ctl.step !== undefined ? ctlBlock.ctl.step : 1
                      onModified: function (v) {
                        root.apply(ctlBlock.deviceId, ctlBlock.ctl.key, v)
                      }
                    }

                    Text {
                      visible: ctlBlock.ctl.editable !== true
                      anchors.verticalCenter: parent.verticalCenter
                      text: Model.displayValue(ctlBlock.ctl)
                      color: Color.foreground
                      opacity: 0.7
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                Loader {
                  width: parent.width
                  active: ctlBlock.ctl.type === "range"
                  visible: active
                  sourceComponent: Component {
                  PanelSlider {
                    width: parent.width
                    bar: root.bar
                    integer: true
                    minimum: ctlBlock.ctl.min !== undefined ? ctlBlock.ctl.min : 0
                    maximum: ctlBlock.ctl.max !== undefined ? ctlBlock.ctl.max : 100
                    step: ctlBlock.ctl.step !== undefined ? ctlBlock.ctl.step : 1
                    value: ctlBlock.ctl.value !== undefined && ctlBlock.ctl.value !== null
                           ? ctlBlock.ctl.value : minimum
                    // Dragging emits moved(), not released(), so a drag is one
                    // apply. The scroll wheel is the problem: PanelSlider fires
                    // released() on every tick, so a flick of the wheel would be
                    // one subprocess per notch. Coalesce into the last value.
                    onReleased: function (v) { commit.pending = Math.round(v); commit.restart() }

                    Timer {
                      id: commit
                      property int pending: 0
                      interval: 140
                      repeat: false
                      onTriggered: root.apply(ctlBlock.deviceId, ctlBlock.ctl.key, commit.pending)
                    }
                  }
                  }
                }

                // Pills, not a dropdown: qs.Ui.Dropdown opens a Popup pinned
                // below its trigger, and that Popup is confined to this panel
                // window. On a short card a six-entry list showed two entries
                // and no way to reach the rest. A wrapped row is always fully
                // visible and matches the tab strip and swatches.
                Loader {
                  width: parent.width
                  active: ctlBlock.ctl.type === "enum"
                  visible: active
                  sourceComponent: Component {
                    Flow {
                      width: parent.width
                      spacing: Style.space(6)

                      Repeater {
                        model: Model.dropdownOptions(ctlBlock.ctl)

                        delegate: Rectangle {
                          id: option
                          required property var modelData
                          width: optionLabel.implicitWidth + Style.space(18)
                          height: Style.space(28)
                          radius: Style.cornerRadius
                          color: option.modelData.value === String(ctlBlock.ctl.value)
                                 ? root.selectedFill : "transparent"
                          border.width: 1
                          border.color: Color.popups.border

                          Text {
                            id: optionLabel
                            anchors.centerIn: parent
                            text: option.modelData.label
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.body
                          }

                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.apply(ctlBlock.deviceId, ctlBlock.ctl.key,
                                                  option.modelData.value)
                          }
                        }
                      }
                    }
                  }
                }

                Loader {
                  width: parent.width
                  active: ctlBlock.ctl.type === "toggle"
                  visible: active
                  sourceComponent: Component {
                  Toggle {
                    width: parent.width
                    label: ctlBlock.ctl.label
                    checked: ctlBlock.ctl.value === true
                    onClicked: {
                      root.apply(ctlBlock.deviceId, ctlBlock.ctl.key,
                                 ctlBlock.ctl.value === true ? "false" : "true")
                    }
                  }
                  }
                }

                Loader {
                  width: parent.width
                  active: ctlBlock.ctl.type === "action"
                  visible: active
                  sourceComponent: Component {
                  Button {
                    width: parent.width
                    text: ctlBlock.ctl.label
                    onClicked: root.apply(ctlBlock.deviceId, ctlBlock.ctl.key, "1")
                  }
                  }
                }

                Loader {
                  width: parent.width
                  active: ctlBlock.ctl.type === "color"
                  visible: active
                  sourceComponent: Component {
                  Row {
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

                // Anything between the swatches. Full saturation and value on
                // purpose: the swatch row is where white and the muted picks
                // live, so one slider is enough here.
                Loader {
                  width: parent.width
                  active: ctlBlock.ctl.type === "color"
                  visible: active
                  sourceComponent: Component {
                  PanelSlider {
                    visible: ctlBlock.ctl.type === "color"
                    width: parent.width
                    bar: root.bar
                    integer: true
                    minimum: 0
                    maximum: 359
                    step: 1
                    value: Model.hueOf(ctlBlock.ctl.value)
                    onReleased: function (v) { hueCommit.pending = Math.round(v); hueCommit.restart() }

                    Timer {
                      id: hueCommit
                      property int pending: 0
                      interval: 140
                      repeat: false
                      onTriggered: root.apply(ctlBlock.deviceId, ctlBlock.ctl.key,
                                              Model.hsvToHex(hueCommit.pending, 1, 1))
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
}
