# omaVaults

An Omarchy bar widget for Obsidian vaults kept in a git repository. One repo
holds many vaults (each top-level folder is a vault); the panel shows every
vault's sync state, syncs on demand, and opens a vault in Obsidian on click.

<p align="center">
  <img src="preview.png" alt="omaVaults panel listing five vaults with their sync states: up to date, local changes, updates available, and commits to push" width="560">
</p>

## Requirements

- Omarchy 4 (Quattro) with its bundled Quickshell plugin host
- `git`, `jq`, `flock` and `setsid` (util-linux), `pgrep` (procps),
  `xdg-open`, and `omarchy-notification-send`; all ship with Omarchy
- [Obsidian](https://obsidian.md) installed with the `obsidian://` URI handler
- Non-interactive git access to your vaults repo (see *Authentication*)

No root privileges, packages, services, or installers are needed.

## Install

```bash
omarchy plugin add https://github.com/ramoncardena/omavaults.git --enable
```

For local development, copy the working tree into the plugins folder (the
shell rejects symlinks) and enable it:

```bash
scripts/dev-install.sh
```

Then click the notebook icon in the bar, enter the repository URL and a local
folder (default `~/Vaults`), **Save**, and **Clone repository**.

Settings live in the widget's entry in `~/.config/omarchy/shell.json`, with a
copy in `~/.config/omavaults/config.json`. The `shell.json` entry wins when
present; the copy is used when it's missing, e.g. after disabling and
re-enabling the widget (which resets its `shell.json` entry):

```json
{ "id": "io.github.ramoncardena.omavaults",
  "repoUrl": "git@github.com:you/vaults.git",
  "localPath": "~/Vaults",
  "refreshIntervalSec": 300 }
```

### Authentication

The widget can't show a prompt, so git must authenticate on its own. SSH runs
in `BatchMode`, and HTTPS has terminal prompts disabled:

- **HTTPS**: works with any git credential helper, e.g. after
  `gh auth setup-git`.
- **SSH**: the key must be usable without typing a passphrase, either loaded
  into an agent or unencrypted. If the shell has no `SSH_AUTH_SOCK`, the
  helper falls back to systemd's `$XDG_RUNTIME_DIR/ssh-agent.socket`.

## Use

| Action | Mouse | Keyboard |
|---|---|---|
| Open vault in Obsidian | click a row | `↑`/`↓`, `Enter` |
| Sync one vault | row's sync button | `s` |
| Sync all vaults | ⟳ in the header / right-click bar icon | `S` |
| Fetch remote status | cloud button in the header | `r` |
| Create a vault | `+` button | `n`, type a name, `Enter` |
| Repository settings | ⚙ button | `,` |
| Close panel | click outside | `Esc` |

The bar icon highlights when any vault is out of sync.

### New vaults

**New vault** creates a top-level folder with a minimal `.obsidian/` config,
a `Welcome.md`, and a `.gitignore` for Obsidian's per-device files
(`workspace*.json`, cache, `.trash/`), then commits, pushes, and opens it in
Obsidian. If the push fails (offline, auth), the vault is still created and
committed locally and shows as *commits to push*. Names can't start with `.`
or contain `/`.

### Sync states

| State | Meaning |
|---|---|
| Up to date | nothing to do |
| local changes | uncommitted edits |
| commits to push | committed locally, not pushed |
| updates available | remote has new commits for this vault |
| diverged | both sides changed; sync will rebase |
| conflict | a rebase/merge is in progress in the repo |

**Sync** = `git add` + commit (scoped to the vault, or everything for Sync
all) → `fetch` → `rebase --autostash` onto upstream → `push`. If the rebase
conflicts it is aborted: your commit stays local, the vault shows *diverged*,
and the working tree is left clean (no conflict markers). Resolve with
`git pull --rebase` in the repo. Nothing is ever force-pushed.

Status refreshes locally every minute and fetches from the remote every
`refreshIntervalSec`. The bar runs one widget per monitor; they share a single
fetch per interval, and finished actions refresh every screen.

### IPC

```bash
omarchy-shell io.github.ramoncardena.omavaults toggle   # also open/close/show/hide
omarchy-shell io.github.ramoncardena.omavaults syncAll  # e.g. from a Hyprland bind
omarchy-shell io.github.ramoncardena.omavaults fetch
omarchy-shell io.github.ramoncardena.omavaults refresh
```

### Obsidian integration

Obsidian only opens vaults listed in `~/.config/obsidian/obsidian.json`, and
only reads that file at startup (a running instance rewrites it from memory).
So omaVaults:

- writes `obsidian.json` **only while Obsidian is not running**, and
  pre-registers all repo vaults whenever that's the case;
- if you open a vault Obsidian doesn't know yet while it's running, asks to
  restart Obsidian once (`Enter` confirms), then opens the vault.

Tip: add `.obsidian/workspace*.json` to the repo's `.gitignore`, or every
vault will look modified whenever you open it.

## Safety and privacy

Like every Omarchy plugin, omaVaults runs unsandboxed as your user. Inspect
the source before installing. What it does:

- **Network**: only `git clone`/`fetch`/`push` to the repository you
  configure. No telemetry and no other requests.
- **Writes**: the configured local folder (your vaults repo) and new vault
  folders inside it; `~/.config/obsidian/obsidian.json`, where vault entries
  are added in Obsidian's own format and only while Obsidian is not running;
  its own widget entry in `~/.config/omarchy/shell.json` and
  `~/.config/omavaults/config.json` when you save settings.
- **Git**: commits with your configured git identity. It never force-pushes
  or rewrites published history; a conflicting rebase is aborted.
- **Processes**: launches Obsidian through `xdg-open`. It quits Obsidian
  (`SIGTERM`, a normal shutdown) only after you confirm the restart prompt.
- No root, no services, no background daemons beyond the shell itself.

## Remove

```bash
omarchy plugin remove io.github.ramoncardena.omavaults --yes
```

Removing the plugin leaves your vaults folder, the `obsidian.json` entries,
and `~/.config/omavaults/` in place, so a reinstall picks up where you left
off. Remove those yourself if you no longer want them.

## Development

```
manifest.json      Omarchy plugin manifest (bar-widget)
BarWidget.qml      entry point: state, helper processes, IPC, bar icon
Panel.qml          the popup (loaded by BarWidget.qml)
Model.js           pure presentation helpers
bin/omavaults      git/Obsidian helper; every command prints JSON
tests/run.sh       end-to-end helper tests on throwaway repos
```

```bash
tests/run.sh
omarchy plugin validate .
# qs.* imports resolve from a root containing `qs` -> $OMARCHY_PATH/shell
mkdir -p /tmp/qslint && ln -sfn "${OMARCHY_PATH:-/usr/share/omarchy}/shell" /tmp/qslint/qs
qmllint -I /tmp/qslint BarWidget.qml Panel.qml
```

## License

[MIT](LICENSE)
