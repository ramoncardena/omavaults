# omaVaults

An Omarchy bar widget for Obsidian vaults kept in a git repository. One repo
holds many vaults (each top-level folder is a vault); the panel shows every
vault's sync state, syncs on demand, and opens a vault in Obsidian on click.

## Install (development)

```bash
scripts/dev-install.sh
```

Then click the notebook icon in the bar, enter the repository URL and a local
folder (default `~/Vaults`), **Save**, and **Clone repository**.

Settings live in the widget's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.ramoncardena.omavaults",
  "repoUrl": "git@github.com:you/vaults.git",
  "localPath": "~/Vaults",
  "refreshIntervalSec": 300 }
```

Authentication is whatever git already uses (SSH agent or a credential
helper). The widget never prompts: SSH runs in `BatchMode`, so set up keys
first.

## Use

| Action | Mouse | Keyboard |
|---|---|---|
| Open vault in Obsidian | click a row | `↑`/`↓`, `Enter` |
| Sync one vault | row's sync button | `s` |
| Sync all vaults | **Sync all** / right-click bar icon | `S` |
| Fetch remote status | refresh button | `r` |
| Create a vault | `+` button | `n`, type a name, `Enter` |
| Repository settings | ⚙ button | `,` |

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
`refreshIntervalSec`.

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

## Layout

```
manifest.json      Omarchy plugin manifest (bar-widget)
OmaVaults.qml      bar icon + popup panel (Quickshell, Omarchy UI kit)
bin/omavaults      git/Obsidian helper; every command prints JSON
tests/run.sh       end-to-end helper tests on throwaway repos
```

## Test

```bash
tests/run.sh
```

## License

[MIT](LICENSE)
