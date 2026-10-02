import QtQuick
import Quickshell.Io

// One agent's usage record, read straight off the data file that
// omarchy-agent-usage-update maintains. The panel never learns how the
// numbers were made — a record that appears in the usage directory is an
// agent, whoever wrote it.
Item {
  id: root
  visible: false

  property string agentId: ""
  property string path: ""
  property var record: null
  property string loadedText: ""

  FileView {
    id: agentFile
    path: root.path
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: {
      root.loadedText = ""
      root.record = null
    }
  }

  // Fallback reload when inotify watch-rearms fail (quota exhaustion, ENOSPC).
  // The atomic mv rewrite replaces the inode; if inotify can't re-arm, the
  // FileView stays frozen. Periodic reload bounds staleness (#9974).
  Timer {
    interval: 120000
    repeat: true
    running: true
    onTriggered: agentFile.reload()
  }

  function parse(content) {
    var text = String(content || "")
    // Every new record object counts as a change and rewrites the sync
    // snapshot, so the fallback reload must not make one for unchanged bytes.
    if (text === root.loadedText) return
    root.loadedText = text
    try {
      var parsed = JSON.parse(text)
      root.record = parsed && typeof parsed === "object" ? parsed : null
    } catch (e) {
      console.warn("agents", "Ignoring bad usage record", root.path, e)
      root.record = null
    }
  }
}
