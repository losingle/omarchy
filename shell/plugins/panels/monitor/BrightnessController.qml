import QtQuick
import Quickshell.Io
import "Model.js" as Model

// A late read may never overwrite a newer selection or a local slider edit.
Item {
  id: root
  property string helperDirectory: ""
  property string targetName: ""
  property string identity: ""
  property bool active: false
  property bool suspended: false
  property int value: 0
  property bool available: false
  property bool checked: false
  property string error: ""
  property int revision: 0
  property int pendingValue: -1
  readonly property bool busy: writer.running || debounce.running || pendingValue >= 0
  readonly property bool reading: reader.running

  function command() {
    return ["python3", "-B", helperDirectory + "monitor_state.py",
      "--brightness", targetName, "--identity", identity]
  }
  function invalidate() {
    revision++
    available = false
    checked = false
    value = 0
    error = ""
    pendingValue = -1
    debounce.stop()
    if (active) Qt.callLater(read)
  }
  function read() {
    if (!active || suspended || busy || reader.running || !targetName || !identity) return
    reader.requestRevision = revision
    reader.received = false
    reader.command = command()
    reader.running = true
  }
  function preview(next) {
    if (suspended || !available || !isFinite(next)) return
    revision++
    value = Model.clampBrightness(next)
    pendingValue = value
    debounce.restart()
  }
  function cancelPreview() { debounce.stop() }
  function setValue(next) {
    if (suspended || !available || !targetName || !isFinite(next)) return
    revision++
    value = Model.clampBrightness(next)
    pendingValue = value
    debounce.stop()
    flush()
  }
  function flush() {
    if (suspended || writer.running || reader.running || pendingValue < 0) return
    writer.requestRevision = revision
    error = ""
    writer.command = command().concat(["--value", String(pendingValue)])
    pendingValue = -1
    writer.running = true
  }
  onTargetNameChanged: invalidate()
  onIdentityChanged: invalidate()
  onActiveChanged: if (active) read()
  onSuspendedChanged: if (!suspended && active) read()

  function accept(text) {
    try {
      var result = JSON.parse(text)
      if (result.name !== targetName || result.description !== identity) return false
      checked = true
      available = typeof result.brightness === "number" && isFinite(result.brightness)
        && result.brightness >= 0 && result.brightness <= 100
      value = available ? result.brightness : 0
      if (available) error = ""
      return true
    } catch (e) { return false }
  }

  Timer { id: debounce; interval: 180; onTriggered: root.flush() }
  Timer { interval: 15000; repeat: true; running: root.active && !root.suspended; onTriggered: root.read() }
  Process {
    id: reader
    property int requestRevision: -1
    property bool received: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (reader.requestRevision !== root.revision || root.suspended || root.busy) return
        reader.received = root.accept(text)
      }
    }
    onExited: {
      if (requestRevision === root.revision && !root.busy && !root.suspended && !received) {
        root.checked = true
        root.available = false
        root.value = 0
        root.error = "Could not read this display's brightness."
      }
      if (root.pendingValue >= 0) Qt.callLater(root.flush)
      else if (requestRevision !== root.revision) Qt.callLater(root.read)
    }
  }
  Process {
    id: writer
    property int requestRevision: -1
    stderr: StdioCollector { id: writeError; waitForEnd: true }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (writer.requestRevision === root.revision) root.accept(text)
    }
    onExited: function(code) {
      if (code !== 0 && requestRevision === root.revision) {
        root.error = String(writeError.text || "Could not set display brightness").trim()
        root.available = false
        root.value = 0
        Qt.callLater(root.read)
      }
      if (root.pendingValue >= 0) Qt.callLater(root.flush)
    }
  }
}
