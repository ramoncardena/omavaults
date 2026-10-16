# Changelog

All notable changes to omaVaults. Versions follow the `version` field in
`manifest.json`; each release is tagged `v<version>`.

## 0.5.2 — 2026-10-16

### Changed
- omaVaults no longer adds vaults to Obsidian's vault list on its own. The
  panel asks instead (**Add to Obsidian** / **Restart Obsidian and add**), and
  **Not now** is remembered per vault, so vaults you removed from Obsidian stay
  removed. Opening a vault from the panel still adds that one vault.
- Status is read-only and reports which vaults are missing from Obsidian's list.

### Added
- `register [--restart] <dir> [vault...]` helper command.

## 0.5.1 — 2026-10-16

### Security
- Clone with `git clone -- <url>`, so a repository URL can never be parsed as a
  git option.
- Conflict copies refuse to write through symlinks in the repository.
- Obsidian detection matches only the real Obsidian process before a confirmed
  restart sends it SIGTERM, never a process that merely mentions "obsidian".
- Credentials embedded in URLs are masked in error messages and in the panel;
  plugin config and cache folders are private (0700).
- The marketplace's Automated Security Baseline passes with no findings or
  review capabilities.

### Changed
- Error messages describe manual steps in words instead of shell command lines.
- `scripts/dev-install.sh` is now `scripts/dev-sync.sh`.
- README explains that synced `.obsidian` plugins are code, so write access to
  the vaults repository decides what Obsidian runs on every device.

## 0.5.0 — 2026-10-16

### Added
- Warning banner when the vaults repository is public on GitHub, GitLab, or
  Codeberg (one anonymous, cached API request), with **Keep it public** for
  repositories that are meant to be public.

### Fixed
- The initial status refresh was skipped at startup and after settings
  changes; it now runs once settings have been applied.

## 0.4.0 — 2026-10-16

### Added
- Notes edited on two devices no longer stop a sync: the remote version keeps
  the name and yours is saved beside it as a conflict copy
  (`note (conflict <device> <date> <time>).md`). The panel, bar icon and a
  notification point to copies until they are merged and deleted.

## 0.3.1 — 2026-10-16

### Added
- **Browse** button (and `Ctrl+O`) in the import form, using the desktop's
  folder dialog.

### Changed
- All inline forms use matching, equal-width buttons.

### Fixed
- Letter shortcuts (`n`, `i`, `,`) could type their letter into the form they
  opened when an input method such as fcitx5 is active.

## 0.3.0 — 2026-10-16

### Added
- Import an existing vault folder into the repository, with the vaults
  Obsidian already knows about offered as one-click choices and other clones
  of the same repository flagged as duplicates.

## 0.2.1 — 2026-10-16

### Fixed
- Settings survive disabling and re-enabling the widget (they are mirrored to
  `~/.config/omavaults/config.json`).

## 0.2.0 — 2026-10-16

### Changed
- Restructured as `BarWidget.qml` + `Panel.qml` + `Model.js` following the
  Omarchy plugin guidelines.

### Added
- IPC methods `syncAll`, `fetch`, `refresh`; one network fetch per interval
  shared by all monitors.

## 0.1.0 — 2026-10-16

### Added
- Bar widget listing the Obsidian vaults in one git repository with per-vault
  sync state, sync on demand, open in Obsidian (with a one-time restart prompt
  for vaults Obsidian doesn't know yet), and creating new vaults.
