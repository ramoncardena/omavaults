import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// omaVaults bar widget: owns the vault state and every helper process, draws
// the bar icon, and hosts Panel.qml. All git/Obsidian work happens in
// bin/omavaults, which prints one JSON object per command.
//
// The bar mounts one instance per monitor. Each instance polls local status
// (cheap), but network fetches are deduplicated by the helper's --max-age,
// and finished actions are broadcast so every screen shows the same state.
BarWidget {
  id: root
  moduleName: "io.github.ramoncardena.omavaults"

  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("bin/omavaults")).replace(/^file:\/\//, ""))

  // Settings come from this widget's shell.json entry, falling back to the
  // copy in ~/.config/omavaults/config.json. Disabling a widget deletes its
  // shell.json entry, so the copy is what a re-enabled widget recovers from.
  readonly property string savedConfigPath: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omavaults/config.json"
  property var savedConfig: ({})
  property bool savedConfigLoaded: false

  function configValue(name, fallback) {
    var inline = setting(name, "")
    if (inline !== "") return inline
    var saved = savedConfig ? savedConfig[name] : undefined
    return saved === undefined || saved === null || saved === "" ? fallback : saved
  }

  readonly property string repoUrl: String(configValue("repoUrl", "")).trim()
  readonly property string localPath: String(configValue("localPath", "~/Vaults")).trim() || "~/Vaults"
  readonly property int refreshIntervalSec: Math.max(30, Number(configValue("refreshIntervalSec", 300)) || 300)

  property var repo: ({ cloned: false, vaults: [] })
  readonly property var vaults: repo && repo.vaults ? repo.vaults : []
  property bool loaded: false
  property string busyAction: ""    // "", "clone", "fetch", "sync", "create", "import", "open"
  property string busyVault: ""     // vault being acted on; "" means all
  property string statusMessage: ""
  property string errorMessage: ""
  property string restartVault: ""  // vault waiting for an "Obsidian must restart" confirmation
  property double now: Date.now()
  property var candidates: []       // Obsidian vaults outside the repo, for import
  property bool picking: false      // folder chooser open; the panel is hidden meanwhile
  property string pickedFolder: ""  // chooser result, consumed by the panel on reopen

  readonly property bool configured: repoUrl !== ""
  readonly property bool busy: busyAction !== ""
  readonly property int attentionCount: vaults.filter(function(v) { return v.state !== "synced" }).length
  readonly property bool hasConflict: vaults.some(function(v) { return Model.isTrouble(v.state) })
  readonly property string summary: Model.summary(configured, repo, attentionCount, hasConflict)

  // ------------------------------------------------------------------ actions

  function parse(text) {
    try { return JSON.parse(String(text || "")) } catch (e) { return null }
  }

  function refresh() {
    now = Date.now()
    if (!configured || statusProc.running) return
    statusProc.command = [helperPath, "status", localPath]
    statusProc.running = true
  }

  function run(action, vault, args, message) {
    if (busy) return
    busyAction = action
    busyVault = vault || ""
    errorMessage = ""
    statusMessage = message || ""
    actionProc.command = [helperPath].concat(args)
    actionProc.running = true
  }

  // Periodic fetches pass maxAge so N monitors don't fetch N times; a manual
  // fetch always hits the network.
  function fetch(maxAge) {
    if (!configured || !repo.cloned) return
    var args = ["fetch", localPath]
    if (maxAge) args.push("--max-age", String(maxAge))
    run("fetch", "", args, "")
  }
  function clone() { run("clone", "", ["clone", repoUrl, localPath], "Cloning " + repoUrl + "…") }
  function syncVault(name) { run("sync", name, ["sync", localPath, name], "Syncing " + name + "…") }
  function syncAll() { if (configured && repo.cloned) run("sync", "", ["sync", localPath], "Syncing all vaults…") }
  function createVault(name) {
    var trimmed = String(name).trim()
    run("create", trimmed, ["create", localPath, trimmed], "Creating " + trimmed + "…")
  }
  function importVault(source, name) {
    var trimmed = String(name).trim()
    run("import", trimmed, ["import", localPath, String(source).trim(), trimmed], "Importing " + trimmed + "…")
  }
  // The panel is a full-screen overlay, so a normal dialog would open behind
  // it: hide the panel while the chooser is up, then bring it back.
  function pickFolder(start) {
    if (pickProc.running) return
    picking = true
    pickedFolder = ""
    pickProc.command = [helperPath, "pick-folder", String(start || "")]
    pickProc.running = true
    close()
  }
  function loadCandidates() {
    if (!configured || !repo.cloned || candidatesProc.running) return
    candidatesProc.command = [helperPath, "candidates", localPath]
    candidatesProc.running = true
  }
  function openVault(name) { restartVault = ""; run("open", name, ["open", localPath, name], "Opening " + name + "…") }
  function restartAndOpen(name) { restartVault = ""; run("open", name, ["open", "--restart", localPath, name], "Restarting Obsidian to add " + name + "…") }

  // Keep the file copy in step with the effective settings. Cheap no-op when
  // they already match, so every per-monitor instance can call it.
  function persistConfig(url, path) {
    if (!savedConfigLoaded || url === "") return
    if (savedConfig.repoUrl === url && savedConfig.localPath === path && Number(savedConfig.refreshIntervalSec) === refreshIntervalSec) return
    Quickshell.execDetached([helperPath, "config-save", url, path, String(refreshIntervalSec)])
  }

  function saveSettings(url, path) {
    persistConfig(String(url).trim(), String(path).trim() || "~/Vaults")
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") {
      statusMessage = "Saved"
      return true
    }
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.repoUrl = String(url).trim()
    entry.localPath = String(path).trim() || "~/Vaults"
    errorMessage = ""
    if (entry.repoUrl === repoUrl && entry.localPath === localPath) {
      statusMessage = "No changes to save"
      return true
    }
    if (!root.bar.shell.updateEntryInline(root.moduleName, entry)) {
      errorMessage = "Could not save settings to shell.json"
      return false
    }
    statusMessage = "Saved"
    return true
  }

  Component.onCompleted: refresh()
  onRepoUrlChanged: { refresh(); persistConfig(repoUrl, localPath) }
  onLocalPathChanged: { refresh(); persistConfig(repoUrl, localPath) }
  onSavedConfigLoadedChanged: persistConfig(repoUrl, localPath)

  FileView {
    id: savedConfigFile
    path: root.savedConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.savedConfig = root.parse(text()) || {}
      root.savedConfigLoaded = true
    }
    onLoadFailed: {
      root.savedConfig = {}
      root.savedConfigLoaded = true
    }
  }

  // Local status (dirty files) every minute; network fetch on the configured
  // interval.
  Timer { interval: 60000; running: root.configured; repeat: true; onTriggered: root.refresh() }
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: root.configured && root.repo.cloned
    repeat: true
    triggeredOnStart: true
    onTriggered: root.fetch(Math.floor(root.refreshIntervalSec / 2))
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = root.parse(text)
        if (result && result.ok) root.repo = result
        else if (result && result.error) root.errorMessage = result.error
        root.loaded = true
      }
    }
  }

  Process {
    id: pickProc
    stdout: StdioCollector { id: pickOut; waitForEnd: true }
    onExited: function(exitCode) {
      var result = root.parse(pickOut.text)
      if (result && result.ok) root.pickedFolder = result.path
      else if (result && !result.cancelled && result.error) root.errorMessage = result.error
      root.open()
      root.picking = false
    }
  }

  Process {
    id: candidatesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = root.parse(text)
        root.candidates = result && result.ok ? result.candidates : []
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    onExited: function(exitCode) {
      var result = root.parse(actionOut.text)
      var action = root.busyAction
      var vault = root.busyVault
      root.busyAction = ""
      root.busyVault = ""
      if (exitCode === 0 && result && result.ok) {
        root.statusMessage = action === "fetch" ? "" : (result.message || "")
        // Conflict copies need the user; say so even if the panel is closed.
        if (result.conflicts > 0)
          Quickshell.execDetached(["omarchy-notification-send", "-g", "󰈢", "omaVaults: notes edited on two devices",
            "Kept your version beside the synced one: " + result.conflictCopies.join(", ") + ". Merge them, then delete the copy."])
        if (action === "open") root.close()
        if (action === "create" || action === "import") Qt.callLater(function() { root.openVault(vault) })
      } else if (result && result.needsRestart) {
        root.statusMessage = ""
        root.restartVault = result.vault
      } else {
        root.statusMessage = ""
        root.errorMessage = result && result.error ? result.error : "Command failed (exit " + exitCode + ")"
        if (action !== "fetch") Quickshell.execDetached(["omarchy-notification-send", "-g", "󰀦", "omaVaults", root.errorMessage])
      }
      root.broadcast("refresh")
    }
  }

  // ------------------------------------------------------- panel contract
  // Shape required by shell.summon/hide/toggle routing and the bar's popout
  // coordinator (see the built-in clock): open/close/opened on this root.

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // omarchy-shell io.github.ramoncardena.omavaults <method>, e.g. bind a key
  // to `syncAll`.
  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.broadcast("refresh") }
    function fetch(): void { root.fetch(0) }
    function syncAll(): void { root.syncAll() }
  }

  // ---------------------------------------------------------------- bar icon

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.busyAction === "sync" ? "󰓦" : "󰠮"
    tooltipText: !root.configured ? "Vaults: not configured"
      : root.hasConflict ? "Vaults: needs attention"
      : root.attentionCount > 0 ? "Vaults: " + root.attentionCount + " out of sync"
      : "Vaults: up to date"
    active: root.attentionCount > 0
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.syncAll()
      else root.toggle()
    }
  }
}
