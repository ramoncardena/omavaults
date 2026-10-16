import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The omaVaults popup. BarWidget.qml owns all state and helper processes and
// injects itself as `hostWidget`; this file is only the view plus view-local
// state (keyboard cursor, inline forms).
Panel {
  id: root
  moduleName: "io.github.ramoncardena.omavaults"
  ipcTarget: moduleName
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot, not this nested panel, so
  // popout coordination and panel switching go through the root.host.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Until BarWidget.qml injects itself, bind against an inert stand-in.
  readonly property var host: hostWidget || ({
    repoUrl: "", localPath: "", repo: { cloned: false, vaults: [] }, vaults: [],
    loaded: false, busy: false, busyAction: "", busyVault: "", statusMessage: "",
    errorMessage: "", restartVault: "", configured: false, hasConflict: false,
    attentionCount: 0, summary: "", now: 0, candidates: []
  })

  readonly property color foreground: root.barForeground
  readonly property color dim: Qt.darker(root.foreground, 1.4)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  property int cursorIndex: 0
  property bool creating: false     // "new vault" form visible
  property bool importing: false    // "import vault" form visible
  property bool importNameEdited: false

  function toneColor(tone) {
    return tone === "urgent" ? Color.urgent : tone === "accent" ? Color.accent : root.dim
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function editSettings() {
    setup.editing = true
    Qt.callLater(function() { urlField.forceActiveFocus(); urlField.selectAll() })
  }

  function finishSettings(save) {
    if (save && !root.host.saveSettings(urlField.text, pathField.text)) return
    setup.editing = false
    keyCatcher.forceActiveFocus()
  }

  function newVault() {
    if (!root.host.configured || !root.host.repo.cloned) return
    importing = false
    creating = true
    Qt.callLater(function() { nameField.text = ""; nameField.forceActiveFocus() })
  }

  function finishCreate(save) {
    var name = nameField.text.trim()
    if (save && name === "") return
    creating = false
    keyCatcher.forceActiveFocus()
    if (save) root.host.createVault(name)
  }

  function folderName(path) {
    var parts = String(path).trim().replace(/\/+$/, "").split("/")
    return parts.length ? parts[parts.length - 1] : ""
  }

  function importVault() {
    if (!root.host.configured || !root.host.repo.cloned) return
    creating = false
    importing = true
    importNameEdited = false
    root.host.loadCandidates()
    Qt.callLater(function() { sourceField.text = ""; importNameField.text = ""; sourceField.forceActiveFocus() })
  }

  function pickCandidate(candidate) {
    sourceField.text = candidate.path
    importNameEdited = false
    importNameField.text = candidate.name
    importNameField.forceActiveFocus()
    importNameField.selectAll()
  }

  function finishImport(save) {
    var source = sourceField.text.trim()
    var name = importNameField.text.trim() || folderName(source)
    if (save && (source === "" || name === "")) return
    importing = false
    keyCatcher.forceActiveFocus()
    if (save) root.host.importVault(source, name)
  }

  function moveCursor(dy) {
    if (root.host.vaults.length === 0) return
    cursorIndex = Math.max(0, Math.min(root.host.vaults.length - 1, cursorIndex + dy))
  }

  onOpenedChanged: {
    if (opened) {
      if (hostWidget) hostWidget.refresh()
      if (!root.host.configured) Qt.callLater(function() { urlField.forceActiveFocus() })
    } else {
      if (hostWidget) hostWidget.restartVault = ""
      creating = false
      importing = false
      setup.editing = false
    }
  }

  Connections {
    target: root.hostWidget
    function onVaultsChanged() { root.cursorIndex = Math.min(root.cursorIndex, Math.max(0, root.host.vaults.length - 1)) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: urlField.activeFocus || pathField.activeFocus || nameField.activeFocus
        || sourceField.activeFocus || importNameField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { root.moveCursor(dy) }
      onActivateRequested: {
        if (root.host.restartVault !== "") root.host.restartAndOpen(root.host.restartVault)
        else if (root.host.vaults.length) root.host.openVault(root.host.vaults[root.cursorIndex].name)
      }
      onTextKey: function(text) {
        if (text === "s" && root.host.vaults.length) root.host.syncVault(root.host.vaults[root.cursorIndex].name)
        else if (text === "S") root.host.syncAll()
        else if (text === "r") root.host.fetch(0)
        else if (text === ",") root.editSettings()
        else if (text === "n") root.newVault()
        else if (text === "i") root.importVault()
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
            meta: root.host.summary
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰠮"
                color: root.host.hasConflict ? Color.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(4)
                visible: root.host.configured && root.host.repo.cloned
                PanelActionButton {
                  iconText: "󰐕"
                  tooltipText: "New vault (n)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !root.host.busy
                  onClicked: root.newVault()
                }
                PanelActionButton {
                  iconText: "󰋺"
                  tooltipText: "Import an existing vault (i)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !root.host.busy
                  onClicked: root.importVault()
                }
                PanelActionButton {
                  iconText: "󰭽"
                  tooltipText: "Fetch remote status (r)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !root.host.busy
                  onClicked: root.host.fetch(0)
                }
                PanelActionButton {
                  iconText: "󰓦"
                  tooltipText: root.host.busyAction === "sync" && root.host.busyVault === "" ? "Syncing all vaults…" : "Sync all vaults (S)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !root.host.busy
                  onClicked: root.host.syncAll()
                }
              }
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.host.errorMessage !== "" ? root.host.errorMessage : root.host.statusMessage
            color: root.host.errorMessage !== "" ? Color.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---- confirm: Obsidian only learns about new vaults at startup
          CursorSurface {
            visible: root.host.restartVault !== ""
            width: parent.width
            bordered: true
            foreground: root.foreground
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
                text: "Obsidian is running and doesn't know \"" + root.host.restartVault + "\" yet. Restart it once to add the vault?"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Row {
                spacing: Style.space(8)
                Button {
                  text: "Restart Obsidian"
                  iconText: "󰜉"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  enabled: !root.host.busy
                  onClicked: root.host.restartAndOpen(root.host.restartVault)
                }
                Button {
                  text: "Cancel"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.host.restartVault = ""
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---- setup: no repo configured yet, or editing settings
          Column {
            id: setup
            property bool editing: false
            visible: !root.host.configured || editing
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "Repository"; foreground: root.foreground; fontFamily: root.fontFamily }
            TextField {
              id: urlField
              KeyNavigation.tab: pathField
              Keys.onEscapePressed: function(event) { root.finishSettings(false); event.accepted = true }
              width: parent.width
              placeholderText: "git@github.com:you/vaults.git"
              text: root.host.repoUrl
              foreground: root.foreground
              font.family: root.fontFamily
              onAccepted: root.finishSettings(true)
            }
            PanelSectionHeader { text: "Local folder"; foreground: root.foreground; fontFamily: root.fontFamily }
            TextField {
              id: pathField
              KeyNavigation.tab: urlField
              Keys.onEscapePressed: function(event) { root.finishSettings(false); event.accepted = true }
              width: parent.width
              placeholderText: "~/Vaults"
              text: root.host.localPath
              foreground: root.foreground
              font.family: root.fontFamily
              onAccepted: root.finishSettings(true)
            }
            Row {
              spacing: Style.space(8)
              Button {
                id: saveButton
                text: "Save"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: urlField.text.trim() !== ""
                onClicked: root.finishSettings(true)
              }
              Button {
                visible: setup.editing
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.finishSettings(false)
              }
            }
          }

          // ---- configured but not cloned
          Column {
            visible: root.host.configured && !setup.editing && root.host.loaded && !root.host.repo.cloned
            width: parent.width
            spacing: Style.space(8)
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.host.repoUrl + "\n→ " + root.host.localPath
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WrapAnywhere
            }
            Button {
              text: root.host.busyAction === "clone" ? "Cloning…" : "Clone repository"
              iconText: "󰇚"
              iconSpinning: root.host.busyAction === "clone"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: !root.host.busy
              onClicked: root.host.clone()
            }
          }

          // ---- new vault form
          Column {
            visible: root.creating
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "New vault"; foreground: root.foreground; fontFamily: root.fontFamily }
            TextField {
              id: nameField
              width: parent.width
              placeholderText: "Vault name"
              foreground: root.foreground
              font.family: root.fontFamily
              onAccepted: root.finishCreate(true)
              Keys.onEscapePressed: function(event) { root.finishCreate(false); event.accepted = true }
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Creates \"" + (nameField.text.trim() || "…") + "\" in the repo, pushes it, and opens it in Obsidian."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Row {
              spacing: Style.space(8)
              Button {
                text: "Create"
                iconText: "󰐕"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: !root.host.busy && nameField.text.trim() !== ""
                onClicked: root.finishCreate(true)
              }
              Button {
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.finishCreate(false)
              }
            }
          }

          // ---- import vault form
          Column {
            visible: root.importing
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "Import vault"; foreground: root.foreground; fontFamily: root.fontFamily }

            Text {
              visible: root.host.candidates.length > 0
              width: parent.width
              text: "Vaults Obsidian knows about outside this repo:"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.host.candidates
              CursorSurface {
                id: candidateRow
                required property var modelData
                readonly property bool duplicate: !!modelData.duplicateOf
                width: parent.width
                foreground: root.foreground
                hasCursor: !duplicate && candidateMouse.containsMouse
                current: sourceField.text.trim() === modelData.path
                opacity: duplicate ? 0.55 : 1
                implicitHeight: candidateText.implicitHeight + Style.spacing.rowPaddingX

                MouseArea {
                  id: candidateMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: !candidateRow.duplicate
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.pickCandidate(candidateRow.modelData)
                }

                ColumnLayout {
                  id: candidateText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(1)
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: candidateRow.modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: candidateRow.duplicate
                      ? "Already in this repo (another clone at " + candidateRow.modelData.duplicateOf + ")"
                      : Model.plural(candidateRow.modelData.files, "file", "files") + " · " + Model.size(candidateRow.modelData.sizeKB) + " · " + candidateRow.modelData.path
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                }
              }
            }

            TextField {
              id: sourceField
              width: parent.width
              placeholderText: "Folder to import, e.g. ~/Notes/Work"
              foreground: root.foreground
              font.family: root.fontFamily
              KeyNavigation.tab: importNameField
              onTextChanged: if (!root.importNameEdited) importNameField.text = root.folderName(text)
              onAccepted: root.finishImport(true)
              Keys.onEscapePressed: function(event) { root.finishImport(false); event.accepted = true }
            }
            TextField {
              id: importNameField
              width: parent.width
              placeholderText: "Vault name"
              foreground: root.foreground
              font.family: root.fontFamily
              KeyNavigation.tab: sourceField
              onTextEdited: root.importNameEdited = true
              onAccepted: root.finishImport(true)
              Keys.onEscapePressed: function(event) { root.finishImport(false); event.accepted = true }
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Copies the folder into the repo as \"" + (importNameField.text.trim() || "…") + "\" (the original stays where it is), pushes it, and opens the copy in Obsidian."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Row {
              spacing: Style.space(8)
              Button {
                text: "Import"
                iconText: "󰋺"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: !root.host.busy && sourceField.text.trim() !== "" && importNameField.text.trim() !== ""
                onClicked: root.finishImport(true)
              }
              Button {
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.finishImport(false)
              }
            }
          }

          // ---- vault list
          Text {
            visible: root.host.configured && !setup.editing && root.host.repo.cloned && root.host.vaults.length === 0
            width: parent.width
            text: "No vaults found. Each top-level folder of the repo is a vault."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Column {
            visible: root.host.configured && !setup.editing && root.host.repo.cloned
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.host.vaults
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
            visible: root.host.configured && !setup.editing
            width: parent.width
            implicitHeight: footerRow.implicitHeight

            RowLayout {
              id: footerRow
              width: parent.width
              spacing: Style.space(8)
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: (root.host.repo.branch ? root.host.repo.branch + " · " : "") + "fetched " + Model.relativeTime(root.host.repo.lastFetch, root.host.now) + " · " + (root.host.repo.dir || root.host.localPath)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }
              PanelActionButton {
                iconText: "󰒓"
                tooltipText: "Repository settings (,)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.editSettings()
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
    readonly property bool syncing: root.host.busyAction === "sync" && (root.host.busyVault === vault.name || root.host.busyVault === "")

    hasCursor: root.cursorIndex === rowIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursorIndex = row.rowIndex
      onClicked: root.host.openVault(row.vault.name)
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
        text: Model.stateGlyph(row.vault.state)
        color: root.toneColor(Model.stateTone(row.vault.state))
        font.family: root.fontFamily
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
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: row.syncing ? "Syncing…" : Model.stateText(row.vault) + (row.vault.lastCommit ? " · edited " + Model.relativeTime(row.vault.lastCommit, root.host.now) : "")
          color: Model.isTrouble(row.vault.state) ? Color.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "󰓦"
        tooltipText: "Sync " + row.vault.name + " (s)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !root.host.busy && row.vault.state !== "synced"
        opacity: enabled ? 1 : 0.35
        onClicked: root.host.syncVault(row.vault.name)
      }
    }
  }
}
