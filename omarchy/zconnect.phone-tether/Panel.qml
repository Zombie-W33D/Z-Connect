import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Z-Connect — phone internet over USB.
//
// The heavy lifting lives in the scripts installed alongside this widget:
//   connect.sh     starts gost on the phone and the adb port forward
//   disconnect.sh  stops both
//   status.sh      prints machine-readable state for this panel
//
// The panel only starts processes, so it keeps working when the desktop has no
// internet of its own — the status probe goes through the phone-side proxy.
Panel {
  id: root
  moduleName: "zconnect.phone-tether"
  ipcTarget: "zconnect.phone-tether"
  // Own the handler so the panel can be driven from a hotkey or a terminal,
  // not just from the bar icon.
  manageIpc: false

  // ---------------------------------------------------------------- scripts
  readonly property string scriptDir: setting("scriptDir", Quickshell.env("HOME") + "/.local/share/z-connect")
  readonly property string statusScript: scriptDir + "/status.sh"
  readonly property string connectScript: scriptDir + "/connect.sh"
  readonly property string disconnectScript: scriptDir + "/disconnect.sh"

  // ------------------------------------------------------------------ theme
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.62)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.34)
  readonly property color okColor: "#3fb950"
  readonly property color warnColor: "#d29922"

  // ------------------------------------------------------------------ state
  property var details: ({})
  property string action: ""            // "" | "connect" | "disconnect"
  property string errorText: ""
  property string statusError: ""
  property string actionStdout: ""
  property string actionStderr: ""

  readonly property bool busy: action !== ""

  readonly property string adbState: String(details.adb_state || "disconnected")
  readonly property bool phonePresent: adbState === "device"
  readonly property bool forwardPresent: details.forward === "yes"
  readonly property string gostPid: String(details.gost_pid || "")
  readonly property bool tunnelUp: phonePresent && forwardPresent && gostPid !== ""
  readonly property bool internetBad: details.proxy === "no"
  // Quick polls do not test the proxy, so "unknown" still counts as up.
  readonly property bool connected: tunnelUp && !internetBad

  readonly property string egressIp: String(details.egress_ip || "")
  readonly property string carrier: String(details.operator || "")
  readonly property string networkType: String(details.network || "")
  readonly property string batteryLevel: String(details.battery || "")
  readonly property string phoneModel: String(details.model || "")
  readonly property string proxyPort: String(details.port || "1080")

  readonly property string statusShort: {
    if (adbState === "unauthorized") return "Authorize USB"
    if (adbState === "offline") return "Phone offline"
    if (adbState === "missing") return "adb missing"
    if (!phonePresent) return "Disconnected"
    if (!tunnelUp) return "Ready"
    if (internetBad) return "No internet"
    if (details.proxy === "yes") return "Connected"
    return "Tunnel up"
  }

  readonly property string statusDetail: {
    if (adbState === "unauthorized")
      return "Unlock the phone, tap Allow on the USB debugging prompt, then press Connect."
    if (adbState === "offline")
      return "The USB connection dropped. Replug the cable and press Connect."
    if (adbState === "missing")
      return "The bundled adb binary is missing. Run fetch-deps.sh in " + scriptDir + "."
    if (!phonePresent)
      return "Plug in the phone with USB debugging enabled, then press Connect."
    if (!tunnelUp) {
      if (!forwardPresent && gostPid === "")
        return "USB link is ready. Press Connect to start the phone-side proxy."
      if (gostPid === "")
        return "The phone-side proxy is not running. Press Connect."
      return "The USB port forward is missing. Press Connect."
    }
    if (internetBad)
      return "The proxy is running but the phone could not reach the internet. Check that mobile data is on."
    if (details.proxy === "yes")
      return "Traffic is leaving through the phone's mobile data. No local internet is needed."
    return "The tunnel is up. Press refresh to test internet through the phone."
  }

  readonly property string tooltipText: {
    if (connected) {
      var ip = egressIp
      return "Phone tether connected" + (ip !== "" ? " — " + ip : "")
    }
    if (phonePresent) return "Phone tether: " + statusShort
    return "Phone tether: not connected"
  }

  // ----------------------------------------------------------------- status
  function refresh(full) {
    if (statusProc.running) return
    statusProc.command = [statusScript, full ? "--full" : "--quick"]
    statusProc.running = true
  }

  function applyStatus(text) {
    var raw = String(text || "").trim()
    if (raw === "") {
      if (!details || Object.keys(details).length === 0)
        statusError = "Could not read the phone status."
      return
    }

    var parsed = {}
    var lines = raw.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var at = line.indexOf("=")
      if (at > 0) parsed[line.slice(0, at)] = line.slice(at + 1)
    }
    details = parsed
    statusError = ""
  }

  // ---------------------------------------------------------------- actions
  function startAction(kind) {
    if (busy) return
    if (statusProc.running) statusProc.running = false
    action = kind
    errorText = ""
    actionStdout = ""
    actionStderr = ""
    actionProc.command = [kind === "connect" ? connectScript : disconnectScript]
    actionProc.running = true
  }

  function finishAction(code) {
    var kind = action
    action = ""
    if (code !== 0) {
      var message = pickError()
      if (message === "") message = kind === "connect" ? "Could not connect to the phone." : "Could not disconnect."
      errorText = message
    } else {
      errorText = ""
    }
    refresh(true)
  }

  function pickError() {
    var text = String(actionStderr || "") + "\n" + String(actionStdout || "")
    var lines = text.split("\n")

    // connect.sh prints the useful failure as an "error:" line; the phone-side
    // log may follow it, so prefer the first explicit error.
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line.indexOf("error:") === 0) return line.replace(/^error:\s*/, "")
    }
    // Otherwise use the last meaningful line, ignoring progress markers.
    for (var j = lines.length - 1; j >= 0; j--) {
      var candidate = lines[j].trim()
      if (candidate !== "" && candidate.indexOf("[") !== 0) return candidate
    }
    return ""
  }

  onOpenedChanged: {
    if (opened) refresh(true)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function connect(): void { root.startAction("connect") }
    function disconnect(): void { root.startAction("disconnect") }
    function refresh(): void { root.refresh(true) }
    function status(): string {
      return root.statusShort + (root.egressIp !== "" ? "|" + root.egressIp : "")
    }
  }

  Timer {
    interval: root.opened ? 15000 : 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(root.opened)
  }

  Process {
    id: statusProc
    command: [root.statusScript, "--quick"]
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") console.warn("zconnect/status", message)
      }
    }
  }

  Process {
    id: actionProc
    command: []
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionStderr = text
    }
    onExited: function(code) {
      // Let the collectors finish before reading their text.
      Qt.callLater(function() { root.finishAction(code) })
    }
  }

  // -------------------------------------------------------------- bar icon
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf10b" // nf-fa-mobile
    dimmed: !root.tunnelUp
    tooltipText: root.tooltipText
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh(true)
      else root.toggle()
    }
  }

  // Small state dot: green when the phone has internet, amber when the tunnel
  // exists but the phone cannot reach the network.
  Rectangle {
    visible: root.tunnelUp
    width: Style.space(5)
    height: width
    radius: width / 2
    color: root.internetBad ? root.warnColor : root.okColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: Style.space(2)
    anchors.bottomMargin: Style.space(2)
  }

  // ---------------------------------------------------------------- popup
  PopupCard {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      width: parent.width
      spacing: Style.space(12)

      PanelHero {
        width: parent.width
        title: "Z-Connect"
        meta: root.statusShort
        detail: root.tunnelUp ? "USB" : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconOpacity: root.tunnelUp ? 1.0 : 0.5
        iconComponent: Component {
          Text {
            text: "\uf10b"
            color: root.tunnelUp ? root.foreground : Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
        }
        trailingControl: Component {
          PanelActionButton {
            iconText: "\uf021"
            tooltipText: "Refresh status"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !root.busy
            onClicked: root.refresh(true)
          }
        }
      }

      Text {
        width: parent.width
        text: root.errorText !== "" ? root.errorText
          : (root.statusError !== "" ? root.statusError : root.statusDetail)
        color: root.errorText !== "" || root.statusError !== "" ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      PanelSeparator {
        foreground: root.foreground
      }

      PanelSectionHeader {
        text: "CONNECTION"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Column {
        width: parent.width
        spacing: Style.spacing.labelGap

        InfoRow { label: "Phone egress"; value: root.egressIp }
        InfoRow { label: "Carrier"; value: root.carrier }
        InfoRow { label: "Network"; value: root.networkType }
        InfoRow { label: "Battery"; value: root.batteryLevel !== "" ? root.batteryLevel + "%" : "" }
        InfoRow { label: "Device"; value: root.phoneModel }
        InfoRow { label: "SOCKS5"; value: "127.0.0.1:" + root.proxyPort }
      }

      PanelSeparator {
        foreground: root.foreground
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        Button {
          width: (parent.width - parent.spacing) / 2
          text: root.action === "connect" ? "Connecting…" : "Connect"
          iconText: "\uf10b"
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.body
          bordered: true
          active: !root.tunnelUp
          opacity: root.busy ? 0.5 : 1
          enabled: !root.busy
          onClicked: root.startAction("connect")
        }

        Button {
          width: (parent.width - parent.spacing) / 2
          text: root.action === "disconnect" ? "Disconnecting…" : "Disconnect"
          iconText: "\uf00d"
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.body
          bordered: true
          opacity: root.busy ? 0.5 : 1
          enabled: !root.busy
          onClicked: root.startAction("disconnect")
        }
      }
    }
  }

  component InfoRow: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      id: labelText
      width: Math.round(parent.width * 0.4)
      text: parent.label
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      width: parent.width - labelText.width - parent.spacing
      text: parent.value !== "" ? parent.value : "—"
      textFormat: Text.PlainText
      color: parent.value !== "" ? root.foreground : root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignRight
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
