import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// omaVaults bar widget: lists the Obsidian vaults in one git repo, shows each
// vault's sync state, opens a vault in Obsidian on click, and syncs on demand.
// All git/Obsidian work happens in bin/omavaults, which prints JSON.
Panel {
  id: plugin
  moduleName: "io.github.ramoncardena.omavaults"
  ipcTarget: moduleName

  readonly property string helperPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + moduleName + "/bin/omavaults"
  readonly property string repoUrl: String(setting("repoUrl", "")).trim()
  readonly property string localPath: String(setting("localPath", "~/Vaults")).trim()
  readonly property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 300)) || 300)

  readonly property color foreground: plugin.barForeground
  readonly property color dim: Qt.darker(plugin.foreground, 1.4)
  readonly property string fontFamily: plugin.bar ? plugin.bar.fontFamily : Style.font.family

  property var repo: ({ cloned: false, vaults: [] })
  readonly property var vaults: repo && repo.vaults ? repo.vaults : []
  property bool loaded: false
  property string busyAction: ""    // "", "clone", "fetch", "sync", "create", "open"
  property string busyVault: ""     // vault being synced/opened; "" means all
  property string statusMessage: ""
  property string errorMessage: ""
  property bool creating: false     // "new vault" form visible
  property string restartVault: ""  // vault waiting for an "Obsidian must restart" confirmation
  property int cursorIndex: 0
  property double now: Date.now()

  readonly property bool configured: repoUrl !== ""
  readonly property bool busy: busyAction !== ""
  readonly property int attentionCount: vaults.filter(function(v) { return v.state !== "synced" }).length
  readonly property bool hasConflict: vaults.some(function(v) { return v.state === "conflict" || v.state === "diverged" })

  // ------------------------------------------------------------- presentation

  function stateGlyph(state) {
    switch (state) {
      case "synced": return "󰄬"
      case "modified": return "󰏫"
      case "ahead": return "󰁝"
      case "behind": return "󰁅"
      case "diverged": return "󰃻"
      case "conflict": return "󰀦"
      case "unpublished": return "󰅤"
      default: return "󰘥"
    }
  }

  function stateText(v) {
    switch (v.state) {
      case "synced": return "Up to date"
      case "modified": return v.dirty + (v.dirty === 1 ? " local change" : " local changes")
      case "ahead": return v.ahead + (v.ahead === 1 ? " commit to push" : " commits to push")
      case "behind": return v.behind + (v.behind === 1 ? " update available" : " updates available")
      case "diverged": return "Local and remote changes — sync to merge"
      case "conflict": return "Conflict — resolve in the repo"
      case "unpublished": return "Not on the remote yet"
      default: return v.state
    }
  }

  function stateColor(state) {
    if (state === "conflict" || state === "diverged") return Color.urgent
    if (state === "synced") return plugin.dim
    return Color.accent
  }

  function relativeTime(epochSec) {
    if (!epochSec) return "never"
    var s = Math.max(0, Math.round(plugin.now / 1000 - epochSec))
    if (s < 60) return "just now"
    if (s < 3600) return Math.floor(s / 60) + "m ago"
    if (s < 86400) return Math.floor(s / 3600) + "h ago"
    return Math.floor(s / 86400) + "d ago"
  }

  readonly property string heroMeta: {
    if (!configured) return "NOT CONFIGURED"
    if (!repo.cloned) return "NOT CLONED"
    var n = vaults.length
    var summary = hasConflict ? "NEEDS ATTENTION" : attentionCount > 0 ? attentionCount + " TO SYNC" : "UP TO DATE"
    return n + (n === 1 ? " VAULT" : " VAULTS") + " · " + summary
  }

  // ------------------------------------------------------------------ actions

  function parse(text) {
    try { return JSON.parse(String(text || "")) } catch (e) { return null }
  }

  function refresh() {
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

  function fetch() {
    if (configured && repo.cloned) run("fetch", "", ["fetch", localPath], "")
  }
  function clone() { run("clone", "", ["clone", repoUrl, localPath], "Cloning " + repoUrl + "…") }
  function syncVault(name) { run("sync", name, ["sync", localPath, name], "Syncing " + name + "…") }
  function syncAll() { run("sync", "", ["sync", localPath], "Syncing all vaults…") }
  function createVault(name) { run("create", String(name).trim(), ["create", localPath, name], "Creating " + String(name).trim() + "…") }
  function openVault(name) { restartVault = ""; run("open", name, ["open", localPath, name], "Opening " + name + "…") }
  function restartAndOpen(name) { restartVault = ""; run("open", name, ["open", "--restart", localPath, name], "Restarting Obsidian to add " + name + "…") }

  function saveSettings(url, path) {
    if (!plugin.bar || !plugin.bar.shell || typeof plugin.bar.shell.updateEntryInline !== "function") {
      errorMessage = "This Omarchy version cannot save widget settings from the panel"
      return
    }
    var entry = { id: plugin.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.repoUrl = String(url).trim()
    entry.localPath = String(path).trim() || "~/Vaults"
    errorMessage = ""
    var changed = entry.repoUrl !== repoUrl || entry.localPath !== localPath
    if (!changed) { statusMessage = "No changes to save"; return true }
    if (plugin.bar.shell.updateEntryInline(plugin.moduleName, entry)) {
      statusMessage = "Saved"
      return true
    }
    errorMessage = "Could not save settings to shell.json"
    return false
  }

  function editSettings() {
    setup.editing = true
    Qt.callLater(function() { urlField.forceActiveFocus(); urlField.selectAll() })
  }

  function finishSettings(save) {
    if (save && !plugin.saveSettings(urlField.text, pathField.text)) return
    setup.editing = false
    keyCatcher.forceActiveFocus()
  }

  function newVault() {
    if (!configured || !repo.cloned) return
    creating = true
    Qt.callLater(function() { nameField.text = ""; nameField.forceActiveFocus() })
  }

  function finishCreate(save) {
    var name = nameField.text.trim()
    if (save && name === "") return
    creating = false
    keyCatcher.forceActiveFocus()
    if (save) createVault(name)
  }

  function moveCursor(dy) {
    if (vaults.length === 0) return
    cursorIndex = Math.max(0, Math.min(vaults.length - 1, cursorIndex + dy))
  }

  Component.onCompleted: refresh()
  onOpenedChanged: {
    if (opened) {
      now = Date.now()
      refresh()
      if (!configured) Qt.callLater(function() { urlField.forceActiveFocus() })
    } else {
      restartVault = ""
      creating = false
      setup.editing = false
    }
  }
  onRepoUrlChanged: refresh()
  onLocalPathChanged: refresh()

  // Cheap local status (dirty files) every minute; network fetch on the
  // configured interval.
  Timer { interval: 60000; running: plugin.configured; repeat: true; onTriggered: { plugin.now = Date.now(); plugin.refresh() } }
  Timer { interval: plugin.refreshIntervalSec * 1000; running: plugin.configured && plugin.repo.cloned; repeat: true; triggeredOnStart: true; onTriggered: plugin.fetch() }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = plugin.parse(text)
        if (result && result.ok) {
          plugin.repo = result
          plugin.cursorIndex = Math.min(plugin.cursorIndex, Math.max(0, plugin.vaults.length - 1))
        } else if (result && result.error) {
          plugin.errorMessage = result.error
        }
        plugin.loaded = true
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    onExited: function(exitCode) {
      var result = plugin.parse(actionOut.text)
      var action = plugin.busyAction
      var vault = plugin.busyVault
      plugin.busyAction = ""
      plugin.busyVault = ""
      if (exitCode === 0 && result && result.ok) {
        plugin.statusMessage = action === "fetch" ? "" : (result.message || "")
        if (action === "open") plugin.close()
        if (action === "create") Qt.callLater(function() { plugin.openVault(vault) })
      } else if (result && result.needsRestart) {
        plugin.statusMessage = ""
        plugin.restartVault = result.vault
      } else {
        plugin.statusMessage = ""
        plugin.errorMessage = result && result.error ? result.error : "Command failed (exit " + exitCode + ")"
        if (action !== "fetch") Quickshell.execDetached(["omarchy-notification-send", "-g", "󰀦", "omaVaults", plugin.errorMessage])
      }
      plugin.refresh()
    }
  }

  // ---------------------------------------------------------------- bar icon

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: plugin.bar
    text: plugin.busyAction === "sync" ? "󰓦" : "󰠮"
    tooltipText: !plugin.configured ? "Vaults: not configured"
      : plugin.hasConflict ? "Vaults: needs attention"
      : plugin.attentionCount > 0 ? "Vaults: " + plugin.attentionCount + " out of sync"
      : "Vaults: up to date"
    active: plugin.attentionCount > 0
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) plugin.syncAll()
      else plugin.toggle()
    }
  }

  // ------------------------------------------------------------------- popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: plugin
    bar: plugin.bar
    open: plugin.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: urlField.activeFocus || pathField.activeFocus || nameField.activeFocus
      onCloseRequested: plugin.close()
      onTabRequested: function(direction) { plugin.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { plugin.moveCursor(dy) }
      onActivateRequested: {
        if (plugin.restartVault !== "") plugin.restartAndOpen(plugin.restartVault)
        else if (plugin.vaults.length) plugin.openVault(plugin.vaults[plugin.cursorIndex].name)
      }
      onTextKey: function(text) {
        if (text === "s" && plugin.vaults.length) plugin.syncVault(plugin.vaults[plugin.cursorIndex].name)
        else if (text === "S") plugin.syncAll()
        else if (text === "r") plugin.fetch()
        else if (text === ",") plugin.editSettings()
        else if (text === "n") plugin.newVault()
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Column {
          id: contentColumn
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Vaults"
            meta: plugin.heroMeta
            foreground: plugin.foreground
            fontFamily: plugin.fontFamily
            iconComponent: Component {
              Text {
                text: "󰠮"
                color: plugin.hasConflict ? Color.urgent : plugin.foreground
                font.family: plugin.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(4)
                visible: plugin.configured && plugin.repo.cloned
                PanelActionButton {
                  iconText: "󰐕"
                  tooltipText: "New vault (n)"
                  foreground: plugin.foreground
                  fontFamily: plugin.fontFamily
                  enabled: !plugin.busy
                  onClicked: plugin.newVault()
                }
                PanelActionButton {
                  iconText: "󰭽"
                  tooltipText: "Fetch remote status (r)"
                  foreground: plugin.foreground
                  fontFamily: plugin.fontFamily
                  enabled: !plugin.busy
                  onClicked: plugin.fetch()
                }
                PanelActionButton {
                  iconText: "󰓦"
                  tooltipText: plugin.busyAction === "sync" && plugin.busyVault === "" ? "Syncing all vaults…" : "Sync all vaults (S)"
                  foreground: plugin.foreground
                  fontFamily: plugin.fontFamily
                  enabled: !plugin.busy
                  onClicked: plugin.syncAll()
                }
              }
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: plugin.errorMessage !== "" ? plugin.errorMessage : plugin.statusMessage
            color: plugin.errorMessage !== "" ? Color.urgent : plugin.dim
            font.family: plugin.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---- confirm: Obsidian only learns about new vaults at startup
          CursorSurface {
            visible: plugin.restartVault !== ""
            width: parent.width
            bordered: true
            foreground: plugin.foreground
            implicitHeight: restartColumn.implicitHeight + Style.spacing.rowPaddingX * 2

            Column {
              id: restartColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              spacing: Style.space(8)
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Obsidian is running and doesn't know \"" + plugin.restartVault + "\" yet. Restart it once to add the vault?"
                color: plugin.foreground
                font.family: plugin.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Row {
                spacing: Style.space(8)
                Button {
                  text: "Restart Obsidian"
                  iconText: "󰜉"
                  foreground: plugin.foreground
                  fontFamily: plugin.fontFamily
                  bordered: true
                  enabled: !plugin.busy
                  onClicked: plugin.restartAndOpen(plugin.restartVault)
                }
                Button {
                  text: "Cancel"
                  foreground: plugin.foreground
                  fontFamily: plugin.fontFamily
                  onClicked: plugin.restartVault = ""
                }
              }
            }
          }

          PanelSeparator { foreground: plugin.foreground }

          // ---- setup: no repo configured yet, or editing settings
          Column {
            id: setup
            property bool editing: false
            visible: !plugin.configured || editing
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "Repository"; foreground: plugin.foreground; fontFamily: plugin.fontFamily }
            TextField {
              id: urlField
              KeyNavigation.tab: pathField
              Keys.onEscapePressed: function(event) { plugin.finishSettings(false); event.accepted = true }
              width: parent.width
              placeholderText: "git@github.com:you/vaults.git"
              text: plugin.repoUrl
              foreground: plugin.foreground
              font.family: plugin.fontFamily
              onAccepted: plugin.finishSettings(true)
            }
            PanelSectionHeader { text: "Local folder"; foreground: plugin.foreground; fontFamily: plugin.fontFamily }
            TextField {
              id: pathField
              KeyNavigation.tab: urlField
              Keys.onEscapePressed: function(event) { plugin.finishSettings(false); event.accepted = true }
              width: parent.width
              placeholderText: "~/Vaults"
              text: plugin.localPath
              foreground: plugin.foreground
              font.family: plugin.fontFamily
              onAccepted: plugin.finishSettings(true)
            }
            Row {
              spacing: Style.space(8)
              Button {
                id: saveButton
                text: "Save"
                foreground: plugin.foreground
                fontFamily: plugin.fontFamily
                bordered: true
                enabled: urlField.text.trim() !== ""
                onClicked: plugin.finishSettings(true)
              }
              Button {
                visible: setup.editing
                text: "Cancel"
                foreground: plugin.foreground
                fontFamily: plugin.fontFamily
                onClicked: plugin.finishSettings(false)
              }
            }
          }

          // ---- configured but not cloned
          Column {
            visible: plugin.configured && !setup.editing && plugin.loaded && !plugin.repo.cloned
            width: parent.width
            spacing: Style.space(8)
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: plugin.repoUrl + "\n→ " + plugin.localPath
              color: plugin.dim
              font.family: plugin.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WrapAnywhere
            }
            Button {
              text: plugin.busyAction === "clone" ? "Cloning…" : "Clone repository"
              iconText: "󰇚"
              iconSpinning: plugin.busyAction === "clone"
              foreground: plugin.foreground
              fontFamily: plugin.fontFamily
              bordered: true
              enabled: !plugin.busy
              onClicked: plugin.clone()
            }
          }

          // ---- new vault form
          Column {
            visible: plugin.creating
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "New vault"; foreground: plugin.foreground; fontFamily: plugin.fontFamily }
            TextField {
              id: nameField
              width: parent.width
              placeholderText: "Vault name"
              foreground: plugin.foreground
              font.family: plugin.fontFamily
              onAccepted: plugin.finishCreate(true)
              Keys.onEscapePressed: function(event) { plugin.finishCreate(false); event.accepted = true }
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Creates \"" + (nameField.text.trim() || "…") + "\" in the repo, pushes it, and opens it in Obsidian."
              color: plugin.dim
              font.family: plugin.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Row {
              spacing: Style.space(8)
              Button {
                text: "Create"
                iconText: "󰐕"
                foreground: plugin.foreground
                fontFamily: plugin.fontFamily
                bordered: true
                enabled: !plugin.busy && nameField.text.trim() !== ""
                onClicked: plugin.finishCreate(true)
              }
              Button {
                text: "Cancel"
                foreground: plugin.foreground
                fontFamily: plugin.fontFamily
                onClicked: plugin.finishCreate(false)
              }
            }
          }

          // ---- vault list
          Text {
            visible: plugin.configured && !setup.editing && plugin.repo.cloned && plugin.vaults.length === 0
            width: parent.width
            text: "No vaults found. Each top-level folder of the repo is a vault."
            color: plugin.dim
            font.family: plugin.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Column {
            visible: plugin.configured && !setup.editing && plugin.repo.cloned
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: plugin.vaults
              VaultRow {
                required property var modelData
                required property int index
                width: parent.width
                vault: modelData
                rowIndex: index
              }
            }
          }

          // ---- footer
          Item {
            visible: plugin.configured && !setup.editing
            width: parent.width
            implicitHeight: footerRow.implicitHeight

            RowLayout {
              id: footerRow
              width: parent.width
              spacing: Style.space(8)
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: (plugin.repo.branch ? plugin.repo.branch + " · " : "") + "fetched " + plugin.relativeTime(plugin.repo.lastFetch) + " · " + (plugin.repo.dir || plugin.localPath)
                color: plugin.dim
                font.family: plugin.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }
              PanelActionButton {
                iconText: "󰒓"
                tooltipText: "Repository settings (,)"
                foreground: plugin.foreground
                fontFamily: plugin.fontFamily
                onClicked: plugin.editSettings()
              }
            }
          }
        }
      }
    }
  }

  component VaultRow: CursorSurface {
    id: row
    property var vault: ({})
    property int rowIndex: 0
    readonly property bool syncing: plugin.busyAction === "sync" && (plugin.busyVault === vault.name || plugin.busyVault === "")

    hasCursor: plugin.cursorIndex === rowIndex
    foreground: plugin.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) plugin.cursorIndex = row.rowIndex
      onClicked: plugin.openVault(row.vault.name)
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: plugin.stateGlyph(row.vault.state)
        color: plugin.stateColor(row.vault.state)
        font.family: plugin.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: row.vault.name
          color: plugin.foreground
          font.family: plugin.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: row.syncing ? "Syncing…" : plugin.stateText(row.vault) + (row.vault.lastCommit ? " · edited " + plugin.relativeTime(row.vault.lastCommit) : "")
          color: row.vault.state === "conflict" || row.vault.state === "diverged" ? Color.urgent : plugin.dim
          font.family: plugin.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "󰓦"
        tooltipText: "Sync " + row.vault.name + " (s)"
        foreground: plugin.foreground
        fontFamily: plugin.fontFamily
        enabled: !plugin.busy && row.vault.state !== "synced"
        opacity: enabled ? 1 : 0.35
        onClicked: plugin.syncVault(row.vault.name)
      }
    }
  }
}
