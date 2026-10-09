import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// DroidCam bar widget: an icon showing the camera state and a popup with the
// phone, controls, a setup check, and settings. One instance per monitor; the
// connection itself lives in Service.qml and this is a view of it.
Panel {
  id: root
  moduleName: "io.github.saurasanchezpablo.droidcam"
  // The service owns the IPC target; `omarchy-shell shell toggle <id>` still
  // opens this popup through the bar.
  ipcTarget: ""
  manageIpc: false

  // ---------- Service ----------
  property var svc: null

  function resolveService() {
    var host = root.bar ? root.bar.shell : null
    var s = host && typeof host.serviceFor === "function" ? host.serviceFor(Model.PLUGIN_ID) : null
    if (s && s !== svc) {
      svc = s
      svc.attachView(root)
    }
  }

  Timer {
    // serviceFor() does not notify bindings, so look until it is there.
    interval: 200
    repeat: true
    triggeredOnStart: true
    running: root.svc === null
    onTriggered: root.resolveService()
  }

  onSettingsChanged: if (svc) svc.updateSettings(root.settings)
  Component.onDestruction: if (svc) svc.detachView(root)

  // ---------- State from the service ----------
  readonly property var cfg: svc ? svc.cfg : Model.settingsFrom(root.settings)
  readonly property string camState: svc ? svc.camState : "off"
  readonly property string reason: svc ? svc.reason : ""
  readonly property bool live: camState === "live"
  readonly property bool problem: camState === "setup"
  readonly property bool wanted: svc ? svc.wanted : false
  readonly property var phone: svc ? svc.phone : ({ reachable: false })
  readonly property bool pro: !!(phone && phone.pro && phone.caps)
  readonly property var caps: pro ? phone.caps : null
  readonly property var consumers: svc ? svc.consumers : []
  readonly property string statusText: svc ? svc.statusText : "Starting"
  readonly property string hint: Model.reasonHint(reason)
  readonly property bool hiddenByRule: cfg.hideWhenOff && !live && camState !== "connecting" && !problem && !opened

  property bool settingsOpen: false
  property bool doctorOpen: false

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function act(fn) { if (svc) fn(svc) }

  onOpenedChanged: {
    if (opened) {
      settingsOpen = settingsOpen || (problem && reason === "noHost")
      hostField.text = cfg.host
      portField.text = String(cfg.port)
      deviceField.text = cfg.device
    }
  }

  // ---------- Bar icon ----------
  visible: !hiddenByRule
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.stateIcon(root.camState)
    fontSize: Style.bar.iconFont
    fixedWidth: button.vertical ? -1 : Style.bar.iconSlot
    active: root.problem
    dimmed: !root.live
    tooltipText: "DroidCam: " + root.statusText
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.act(function(s) { s.toggleConnection() })
      else if (b === Qt.RightButton) root.act(function(s) { s.reconnect() })
      else root.toggle()
    }

    SequentialAnimation on opacity {
      running: root.camState === "connecting"
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { to: 0.45; duration: 700; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutQuad }
    }
  }

  // ---------- Popup ----------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: hostField.activeFocus || portField.activeFocus || deviceField.activeFocus || phoneNameField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "c") root.act(function(s) { s.toggleConnection() })
        else if (t === "r") root.act(function(s) { s.reconnect() })
        else if (t === "s") root.settingsOpen = !root.settingsOpen
        else if (t === "d") root.toggleDoctor()
        else if (t === "l") root.act(function(s) { s.control("torch") })
        else if (t === "a") root.act(function(s) { s.control("focus") })
        else if (t === "+" || t === "=") root.act(function(s) { s.control("zoomIn") })
        else if (t === "-") root.act(function(s) { s.control("zoomOut") })
        else if (t === "m") root.act(function(s) { s.control("mirror") })
      }

      // The card is capped at the screen height; scroll when the open
      // sections need more.
      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

      Column {
        id: column
        width: scroller.width
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: Model.stateIcon(root.camState)
            color: root.problem ? root.urgentColor : root.fg
            opacity: root.live || root.problem ? 1 : 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: batteryLabel.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.phone.reachable && root.phone.name ? root.phone.name : "DroidCam"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.statusText.toUpperCase()
              color: root.problem ? root.urgentColor : Qt.darker(root.fg, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: batteryLabel
            textFormat: Text.PlainText
            visible: !!(root.phone.reachable && root.phone.battery)
            text: visible ? (root.phone.battery.charging ? Model.ICONS.charging : Model.ICONS.battery) + " " + root.phone.battery.level + "%" : ""
            color: visible && root.phone.battery.level <= 15 && !root.phone.battery.charging ? root.urgentColor : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Hint / notice ----------
        Text {
          visible: text !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: !root.live && root.camState !== "off" && root.camState !== "connecting" && root.hint !== "" ? root.hint
            : root.svc ? root.svc.notice : ""
          color: root.problem ? root.urgentColor : root.fg
          opacity: root.problem ? 1 : 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        // ---------- Details ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          InfoPair {
            label: "Connection"
            value: Model.modeLabel(root.svc && root.svc.activeMode ? root.svc.activeMode : root.cfg.mode)
              + (root.cfg.host !== "" && (root.cfg.mode === "wifi" || (root.svc && root.svc.activeMode === "wifi")) ? " · " + root.cfg.host + ":" + root.cfg.port : "")
          }
          InfoPair {
            visible: !!(root.svc && root.svc.device)
            label: "Device"
            value: root.svc ? root.svc.device + (root.svc.lastCheck.format ? " · " + root.svc.lastCheck.format : "") : ""
          }
          InfoPair {
            visible: root.live || root.consumers.length > 0
            label: "In use by"
            value: root.consumers.length > 0 ? root.consumers.join(", ") : "No app"
          }
          InfoPair {
            visible: root.cfg.onDemand
            label: "Mode"
            value: root.camState === "standby" ? "Waiting for an app to open the camera" : "Streams only while in use"
          }
        }

        // ---------- Preview ----------
        Rectangle {
          visible: root.cfg.preview && root.live
          width: parent.width
          height: visible ? Math.round(width * 3 / 4) : 0
          radius: Style.cornerRadius
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
          clip: true

          Image {
            anchors.fill: parent
            visible: root.svc && root.svc.previewOk
            fillMode: Image.PreserveAspectFit
            cache: false
            asynchronous: true
            source: root.svc && root.svc.previewOk && root.opened ? "file://" + root.svc.previewPath + "?" + root.svc.previewTick : ""
          }

          Text {
            anchors.centerIn: parent
            visible: !(root.svc && root.svc.previewOk)
            textFormat: Text.PlainText
            text: root.svc && !root.svc.previewAvailable ? "Preview needs a private runtime folder (XDG_RUNTIME_DIR)"
              : root.svc && root.svc.doctor.ffmpeg === false ? "Preview needs ffmpeg" : "Loading preview…"
            color: root.fg
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- Camera controls ----------
        Column {
          visible: root.live
          width: parent.width
          spacing: Style.space(8)

          PanelSeparator { foreground: root.fg }

          PanelSectionHeader {
            text: "CAMERA"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Row {
            id: controlRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * 5) / 6

            ControlButton { iconText: Model.ICONS.zoomOut; tooltipText: "Zoom out (-)"; onClicked: root.act(function(s) { s.control("zoomOut") }) }
            ControlButton { iconText: Model.ICONS.zoomIn; tooltipText: "Zoom in (+)"; onClicked: root.act(function(s) { s.control("zoomIn") }) }
            ControlButton { iconText: Model.ICONS.focus; tooltipText: "Autofocus (a)"; onClicked: root.act(function(s) { s.control("focus") }) }
            ControlButton {
              iconText: Model.ICONS.flash
              tooltipText: "Torch (l)"
              active: !!(root.caps && root.caps.torch)
              onClicked: root.act(function(s) { s.control("torch") })
            }
            ControlButton { iconText: Model.ICONS.mirror; tooltipText: "Mirror (m)"; active: root.cfg.hflip; onClicked: root.act(function(s) { s.control("mirror") }) }
            ControlButton { iconText: Model.ICONS.flip; tooltipText: "Flip vertically"; active: root.cfg.vflip; onClicked: root.act(function(s) { s.control("flip") }) }
          }

          // Pro: absolute zoom and exposure, locks.
          Column {
            visible: !!(root.caps && root.caps.zoom)
            width: parent.width
            spacing: Style.space(4)
            InfoPair { label: "Zoom"; value: root.caps && root.caps.zoom ? root.caps.zoom.value.toFixed(1) + "×" : "" }
            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: root.caps && root.caps.zoom ? root.caps.zoom.min : 0
              maximum: root.caps && root.caps.zoom ? root.caps.zoom.max : 1
              value: root.caps && root.caps.zoom ? root.caps.zoom.value : 0
              step: 0.1
              onReleased: function(v) { root.act(function(s) { s.control("zoom", v) }) }
            }
          }

          Column {
            visible: !!(root.caps && root.caps.ev)
            width: parent.width
            spacing: Style.space(4)
            InfoPair { label: "Exposure"; value: root.caps && root.caps.ev ? root.caps.ev.value.toFixed(1) : "" }
            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: root.caps && root.caps.ev ? root.caps.ev.min : 0
              maximum: root.caps && root.caps.ev ? root.caps.ev.max : 1
              value: root.caps && root.caps.ev ? root.caps.ev.value : 0
              step: 0.5
              onReleased: function(v) { root.act(function(s) { s.control("ev", v) }) }
            }
          }

          Row {
            visible: !!(root.caps && (root.caps.exposureLock !== null || root.caps.wbLock !== null))
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing) / 2

            Button {
              visible: !!(root.caps && root.caps.exposureLock !== null)
              width: parent.cellWidth
              iconText: root.caps && root.caps.exposureLock ? Model.ICONS.lock : Model.ICONS.lockOpen
              text: "Exposure"
              active: !!(root.caps && root.caps.exposureLock)
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.act(function(s) { s.control("exposureLock") })
            }
            Button {
              visible: !!(root.caps && root.caps.wbLock !== null)
              width: parent.cellWidth
              iconText: root.caps && root.caps.wbLock ? Model.ICONS.lock : Model.ICONS.lockOpen
              text: "White balance"
              active: !!(root.caps && root.caps.wbLock)
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.act(function(s) { s.control("wbLock") })
            }
          }

          // Camera switch: the list is free, switching needs Pro.
          ButtonGroup {
            visible: root.phone.reachable && root.phone.cameras && root.phone.cameras.length > 1
            width: parent.width
            options: {
              var list = root.phone.cameras || []
              var out = []
              for (var i = 0; i < list.length; i++) out.push({ value: String(i), label: list[i] })
              return out
            }
            value: root.caps && root.caps.active >= 0 ? String(root.caps.active) : ""
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(v) { root.act(function(s) { s.control("camera", Number(v)) }) }
          }

          Text {
            visible: root.phone.reachable && root.phone.restricted
            width: parent.width
            textFormat: Text.PlainText
            text: "Zoom level, exposure and camera switching need DroidCam Pro on the phone."
            color: root.fg
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }

        // ---------- Actions ----------
        PanelSeparator { foreground: root.fg }

        Row {
          id: actionRow
          width: parent.width
          spacing: Style.space(6)
          readonly property real cellWidth: (width - spacing * 3) / 4

          ActionButton {
            iconText: root.wanted ? Model.ICONS.stop : Model.ICONS.play
            text: root.wanted ? "Stop" : "Connect"
            onClicked: root.act(function(s) { s.toggleConnection() })
          }
          ActionButton {
            iconText: Model.ICONS.restart
            text: "Reconnect"
            onClicked: root.act(function(s) { s.reconnect() })
          }
          ActionButton {
            iconText: Model.ICONS.stethoscope
            text: "Check"
            active: root.doctorOpen
            onClicked: root.toggleDoctor()
          }
          ActionButton {
            iconText: Model.ICONS.cog
            text: "Settings"
            active: root.settingsOpen
            onClicked: root.settingsOpen = !root.settingsOpen
          }
        }

        // ---------- Setup check ----------
        Column {
          visible: root.doctorOpen
          width: parent.width
          spacing: Style.space(8)

          PanelSeparator { foreground: root.fg }

          PanelSectionHeader {
            text: root.svc && root.svc.doctor.running ? "SETUP CHECK · RUNNING" : "SETUP CHECK"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.svc ? root.svc.doctor.rows : []
            Column {
              required property var modelData
              width: column.width
              spacing: Style.space(2)

              Row {
                spacing: Style.space(8)
                Text {
                  textFormat: Text.PlainText
                  text: modelData.ok ? Model.ICONS.check : Model.ICONS.close
                  color: modelData.ok ? root.fg : root.urgentColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
              Text {
                visible: modelData.hint !== ""
                x: Style.space(22)
                width: column.width - x
                textFormat: Text.PlainText
                text: modelData.hint
                color: root.fg
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }
          }
        }

        // ---------- Settings ----------
        Column {
          visible: root.settingsOpen
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator { foreground: root.fg }

          PanelSectionHeader { text: "CONNECTION"; foreground: root.fg; fontFamily: root.fontFamily }

          ButtonGroup {
            width: parent.width
            options: [
              { value: "auto", label: "Auto" },
              { value: "wifi", label: "Wi-Fi" },
              { value: "ios", label: "iPhone USB" },
              { value: "adb", label: "Android USB" }
            ]
            value: root.cfg.mode
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(v) { root.act(function(s) { s.saveSettings({ mode: v }) }) }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: hostField
              width: parent.width - portField.width - parent.spacing
              placeholderText: "Phone Wi-Fi address (192.168.1.50)"
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              foreground: root.fg
              onAccepted: portField.forceActiveFocus()
            }
            TextField {
              id: portField
              width: Style.space(76)
              placeholderText: "4747"
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              foreground: root.fg
              onAccepted: saveButton.clicked()
            }
          }

          Text {
            id: connectionError
            property string message: ""
            visible: message !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: message
            color: root.urgentColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing) / 2

            Button {
              id: saveButton
              width: parent.cellWidth
              iconText: Model.ICONS.check
              text: "Save & connect"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: {
                var res = Model.cleanPatch({ host: hostField.text.trim(), port: portField.text.trim() === "" ? 4747 : portField.text.trim() })
                if (!res.ok) { connectionError.message = res.error; return }
                connectionError.message = ""
                keyCatcher.forceActiveFocus()
                root.act(function(s) { s.saveSettings(res.patch); s.connectCamera() })
              }
            }
            Button {
              width: parent.cellWidth
              iconText: Model.ICONS.refresh
              text: "Import from app"
              tooltipText: "Read the address and options from the DroidCam app's settings"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.act(function(s) { s.importDroidcam() })
            }
          }

          // ---------- Saved phones ----------
          PanelSectionHeader { text: "PHONES"; foreground: root.fg; fontFamily: root.fontFamily }

          Repeater {
            model: root.cfg.phones
            Row {
              required property var modelData
              required property int index
              width: column.width
              spacing: Style.space(6)

              Button {
                width: parent.width - forget.width - parent.spacing
                leftAlign: true
                iconText: modelData.mode === "wifi" ? Model.ICONS.wifi : modelData.mode === "auto" ? Model.ICONS.phone : Model.ICONS.usb
                text: modelData.name + (modelData.host ? "  ·  " + modelData.host : "")
                selected: Model.isCurrentPhone(root.cfg, modelData)
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.act(function(s) { s.usePhone(index) })
              }
              Button {
                id: forget
                iconText: Model.ICONS.delete
                tooltipText: "Forget"
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.act(function(s) { s.forgetPhone(index) })
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)
            TextField {
              id: phoneNameField
              width: parent.width - savePhoneButton.width - parent.spacing
              placeholderText: "Name for this connection"
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              foreground: root.fg
              onAccepted: savePhoneButton.clicked()
            }
            Button {
              id: savePhoneButton
              iconText: Model.ICONS.plus
              text: "Save"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: {
                var name = phoneNameField.text.trim() || (root.phone.reachable && root.phone.name) || Model.modeLabel(root.cfg.mode)
                root.act(function(s) { s.savePhone(name) })
                phoneNameField.text = ""
                keyCatcher.forceActiveFocus()
              }
            }
          }

          // ---------- Video ----------
          PanelSectionHeader { text: "VIDEO"; foreground: root.fg; fontFamily: root.fontFamily }

          ButtonGroup {
            width: parent.width
            options: [
              { value: "640x480", label: "480p" },
              { value: "960x720", label: "720p 4:3" },
              { value: "1280x720", label: "720p" },
              { value: "1920x1080", label: "1080p" }
            ]
            value: root.cfg.size
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(v) { root.act(function(s) { s.saveSettings({ size: v }) }) }
          }

          Text {
            visible: !!(root.svc && root.svc.lastCheck.kind === "dc")
            width: parent.width
            textFormat: Text.PlainText
            text: "The DroidCam driver sets its own size (" + (root.svc ? root.svc.lastCheck.format || "" : "") + "); change it with the driver's width/height options."
            color: root.fg
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          TextField {
            id: deviceField
            width: parent.width
            placeholderText: "Camera device: automatic" + (root.svc && root.svc.lastCheck.device ? " (" + root.svc.lastCheck.device + ")" : "")
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            foreground: root.fg
            onAccepted: {
              var res = Model.cleanPatch({ device: text.trim() })
              if (!res.ok) { connectionError.message = res.error; return }
              connectionError.message = ""
              keyCatcher.forceActiveFocus()
              root.act(function(s) { s.saveSettings(res.patch) })
            }
          }

          // ---------- Behaviour ----------
          PanelSectionHeader { text: "BEHAVIOUR"; foreground: root.fg; fontFamily: root.fontFamily }

          SettingToggle { key: "autoConnect"; label: "Connect at login"; description: "Start the camera when the desktop starts" }
          SettingToggle { key: "onDemand"; label: "Only while in use"; description: "Stream only while an app has the camera open, to save the phone's battery" }
          SettingToggle { key: "takeOver"; label: "Take over"; description: "Close the DroidCam app window or another droidcam-cli instead of waiting" }
          SettingToggle { key: "notify"; label: "Notifications"; description: "Connected, disconnected, and setup problems" }
          SettingToggle { key: "preview"; label: "Preview"; description: "A small picture here while this popup is open (needs ffmpeg)" }
          SettingToggle { key: "audio"; label: "Audio"; description: "Use the phone as a microphone too (needs snd-aloop)" }
          SettingToggle { key: "hideWhenOff"; label: "Hide when off"; description: "Hide the bar icon while the camera is not streaming" }
        }
      }
      }
    }
  }

  // Bring a section that was just opened into view.
  function scrollToEnd() {
    Qt.callLater(function() {
      scroller.contentY = Math.max(0, scroller.contentHeight - scroller.height)
    })
  }
  onSettingsOpenChanged: if (settingsOpen) scrollToEnd()
  onDoctorOpenChanged: if (doctorOpen && !settingsOpen) scrollToEnd()

  function toggleDoctor() {
    doctorOpen = !doctorOpen
    if (doctorOpen) act(function(s) { s.runDoctor() })
  }

  component ActionButton: Button {
    width: actionRow.cellWidth
    iconSize: Style.font.title
    fontSize: Style.font.bodySmall
    foreground: root.fg
    fontFamily: root.fontFamily
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
    bordered: true
    opacity: enabled ? 1 : 0.5
  }

  component ControlButton: Button {
    width: controlRow.cellWidth
    iconSize: Style.font.title
    foreground: root.fg
    fontFamily: root.fontFamily
    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
    bordered: true
  }

  component SettingToggle: Toggle {
    property string key: ""
    width: column.width
    checked: root.cfg[key] === true
    foreground: root.fg
    fontFamily: root.fontFamily
    titleSize: Style.font.bodySmall
    onClicked: {
      var patch = {}
      patch[key] = !root.cfg[key]
      root.act(function(s) { s.saveSettings(patch) })
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    spacing: Style.space(8)

    Text {
      id: pairLabel
      textFormat: Text.PlainText
      text: parent.label
      color: root.fg
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      width: Math.max(0, parent.width - pairLabel.implicitWidth - parent.spacing)
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: parent.value
      color: root.fg
      elide: Text.ElideMiddle
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
