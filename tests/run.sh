#!/bin/bash

# End-to-end tests for bin/omavaults against throwaway git repos.
# Never touches the real Obsidian config: XDG_CONFIG_HOME points at a temp dir,
# and xdg-open/pgrep are stubbed so no app is launched or detected.

set -uo pipefail

HELPER="$(cd "$(dirname "$0")/.." && pwd)/bin/omavaults"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export XDG_CONFIG_HOME="$T/config"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
OBS="$XDG_CONFIG_HOME/obsidian/obsidian.json"

mkdir -p "$T/stub"
cat >"$T/stub/xdg-open" <<EOF
#!/bin/bash
echo "\$1" >>"$T/opened"
EOF
# "Obsidian running" is simulated by the existence of \$T/running.
cat >"$T/stub/pgrep" <<EOF
#!/bin/bash
[[ -f "$T/running" ]] && echo \$\$
exit 0
EOF
chmod +x "$T/stub/"*
export PATH="$T/stub:$PATH"

pass=0 failed=0
check() {
  local name="$1"
  shift
  if "$@"; then pass=$((pass + 1)); else failed=$((failed + 1)); echo "FAIL: $name"; fi
}
state_of() { "$HELPER" status "$T/local" | jq -r --arg v "$1" '.vaults[] | select(.name == $v) | .state'; }

# Fixture: bare remote with two vaults, plus a second clone ("other machine").
git init -q --bare -b main "$T/remote.git"
git clone -q "$T/remote.git" "$T/seed" 2>/dev/null
mkdir -p "$T/seed/Work" "$T/seed/Personal"
echo "# Todo" >"$T/seed/Work/todo.md"
echo "# Journal" >"$T/seed/Personal/journal.md"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm init && git -C "$T/seed" push -q origin main
git clone -q "$T/remote.git" "$T/other"

check "status before clone" test "$("$HELPER" status "$T/local" | jq -r .cloned)" = false
check "clone" "$HELPER" clone "$T/remote.git" "$T/local" >/dev/null
check "clone is idempotent" "$HELPER" clone "$T/remote.git" "$T/local" >/dev/null
check "lists vaults" test "$("$HELPER" status "$T/local" | jq -c '[.vaults[].name]')" = '["Personal","Work"]'
check "fresh clone is synced" test "$(state_of Work)" = synced

echo "edit" >>"$T/local/Personal/journal.md"
(cd "$T/other" && echo more >>Work/todo.md && git commit -qam remote && git push -q)
"$HELPER" fetch "$T/local" >/dev/null
check "local edit -> modified" test "$(state_of Personal)" = modified
check "remote edit -> behind" test "$(state_of Work)" = behind

check "sync one vault" "$HELPER" sync "$T/local" Personal >/dev/null
check "after sync: Personal synced" test "$(state_of Personal)" = synced
check "after sync: Work pulled" test "$(state_of Work)" = synced
(cd "$T/other" && git pull -q)
check "commit reached remote" grep -q edit "$T/other/Personal/journal.md"

# Conflict: both sides rewrite the same line. Sync must abort cleanly.
(cd "$T/other" && echo "remote line" >Work/todo.md && git commit -qam conflict && git push -q)
echo "local line" >"$T/local/Work/todo.md"
echo "keep me" >>"$T/local/Personal/journal.md"
"$HELPER" sync "$T/local" Work >/dev/null
check "conflicting sync fails" test $? -ne 0
check "no rebase left behind" test ! -d "$T/local/.git/rebase-merge" -a ! -d "$T/local/.git/rebase-apply"
check "no conflict markers" bash -c "! grep -q '<<<<<<<' '$T/local/Work/todo.md'"
check "other vault's edits kept" grep -q "keep me" "$T/local/Personal/journal.md"
check "conflict -> diverged" test "$(state_of Work)" = diverged

touch "$T/local/.git/FETCH_HEAD"
check "fetch --max-age skips a recent fetch" test "$("$HELPER" fetch "$T/local" --max-age 300 | jq -r .message)" = "Fetched recently"
touch -d '10 minutes ago' "$T/local/.git/FETCH_HEAD"
check "fetch --max-age fetches when stale" test "$("$HELPER" fetch "$T/local" --max-age 300 | jq -r .message)" = "Fetched"
check "fetch --max-age rejects junk" bash -c "! '$HELPER' fetch '$T/local' --max-age soon >/dev/null"
check "rejects path traversal" bash -c "! '$HELPER' sync '$T/local' ../x >/dev/null"
check "rejects bad open name" bash -c "! '$HELPER' open '$T/local' ../etc >/dev/null"

# Obsidian registration.
check "status pre-registers vaults when Obsidian is stopped" \
  test "$(jq '[.vaults[]] | length' "$OBS")" = 2
"$HELPER" open "$T/local" Work >/dev/null
check "open launches URI" grep -q "obsidian://open?path=.*Work" "$T/opened"

mkdir "$T/local/Research"
touch "$T/running"
before=$(md5sum <"$OBS")
"$HELPER" status "$T/local" >/dev/null
check "status leaves obsidian.json alone while running" test "$before" = "$(md5sum <"$OBS")"
"$HELPER" open "$T/local" Research >/dev/null
check "unregistered vault while running -> exit 3" test $? -eq 3
check "no write while running" test "$before" = "$(md5sum <"$OBS")"

# Creating vaults.
rm -f "$T/running"
git -C "$T/local" reset -q --hard '@{u}'   # clear the earlier conflict scenario
check "create vault" "$HELPER" create "$T/local" "  Garden Notes " >/dev/null
check "create trims name" test -d "$T/local/Garden Notes/.obsidian"
check "new vault is synced" test "$(state_of "Garden Notes")" = synced
(cd "$T/other" && git pull -q)
check "new vault reached remote" test -f "$T/other/Garden Notes/Welcome.md"
echo '{"x":1}' >"$T/local/Garden Notes/.obsidian/workspace.json"
check "workspace.json is ignored" test "$(state_of "Garden Notes")" = synced
check "duplicate name fails" bash -c "! '$HELPER' create '$T/local' 'Garden Notes' >/dev/null"
check "dot name fails" bash -c "! '$HELPER' create '$T/local' .hidden >/dev/null"
check "slash name fails" bash -c "! '$HELPER' create '$T/local' a/b >/dev/null"
check "empty name fails" bash -c "! '$HELPER' create '$T/local' '   ' >/dev/null"

git -C "$T/local" remote set-url origin "$T/missing.git"
out=$("$HELPER" create "$T/local" Offline)
check "create offline still succeeds" test "$(jq -r .ok <<<"$out")" = true
check "create offline says not pushed" grep -q "not pushed" <<<"$out"
check "offline vault committed locally" test -n "$(git -C "$T/local" log --oneline -1 -- Offline)"
git -C "$T/local" remote set-url origin "$T/remote.git"

# Importing existing vaults.
SRC="$T/outside/Old Notes"
mkdir -p "$SRC/.obsidian/plugins/x" "$SRC/.git" "$SRC/.trash" "$SRC/sub"
echo note >"$SRC/a.md"; echo deep >"$SRC/sub/b.md"; echo '{}' >"$SRC/.obsidian/plugins/x/data.json"
echo '{"w":1}' >"$SRC/.obsidian/workspace.json"; echo junk >"$SRC/.git/HEAD"; echo gone >"$SRC/.trash/c.md"
before=$(find "$SRC" -type f -print0 | sort -z | xargs -0 md5sum)
check "import vault" "$HELPER" import "$T/local" "$SRC" >/dev/null
check "import keeps the folder name" test -f "$T/local/Old Notes/sub/b.md"
check "import copies plugin config" test -f "$T/local/Old Notes/.obsidian/plugins/x/data.json"
check "import skips .git" test ! -e "$T/local/Old Notes/.git"
check "import skips workspace and trash" test ! -e "$T/local/Old Notes/.obsidian/workspace.json" -a ! -e "$T/local/Old Notes/.trash"
check "import adds .gitignore" test -f "$T/local/Old Notes/.gitignore"
check "import leaves source untouched" test "$before" = "$(find "$SRC" -type f -print0 | sort -z | xargs -0 md5sum)"
check "imported vault is synced" test "$(state_of "Old Notes")" = synced
(cd "$T/other" && git pull -q)
check "imported vault reached remote" test -f "$T/other/Old Notes/a.md"
check "import with custom name" "$HELPER" import "$T/local" "$SRC" "Archive" >/dev/null
check "custom name used" test -f "$T/local/Archive/a.md"
check "import refuses existing name" bash -c "! '$HELPER' import '$T/local' '$SRC' >/dev/null"
check "import refuses missing folder" bash -c "! '$HELPER' import '$T/local' '$T/nope' >/dev/null"
check "import refuses folder inside repo" bash -c "! '$HELPER' import '$T/local' '$T/local/Work' New >/dev/null"
check "import refuses folder containing repo" bash -c "! '$HELPER' import '$T/local' '$T' New >/dev/null"
mkdir -p "$T/outside/Huge"; truncate -s 96M "$T/outside/Huge/video.mp4"
check "import refuses files over the host limit" bash -c "! '$HELPER' import '$T/local' '$T/outside/Huge' >/dev/null"
check "refused import leaves nothing behind" test ! -e "$T/local/Huge"

# Import candidates: Obsidian vaults outside the repo, duplicates flagged.
git clone -q "$T/remote.git" "$T/oldclone"
jq --arg a "$SRC" --arg b "$T/oldclone/Work" --arg c "$T/local/Work" \
  '.vaults += {c1: {path: $a}, c2: {path: $b}, c3: {path: $c}}' "$OBS" >"$T/obs.tmp" && mv "$T/obs.tmp" "$OBS"
cands=$("$HELPER" candidates "$T/local")
check "candidates list outside vaults" test "$(jq -r --arg a "$SRC" '.candidates[] | select(.path == $a) | .duplicateOf' <<<"$cands")" = null
check "candidates flag other clones" test "$(jq -r --arg b "$T/oldclone/Work" '.candidates[] | select(.path == $b) | .duplicateOf' <<<"$cands")" = "$T/oldclone"
check "candidates skip repo vaults" test -z "$(jq -r --arg c "$T/local/Work" '.candidates[] | select(.path == $c) | .path' <<<"$cands")"

# Folder chooser: with no session bus and no zenity/kdialog, it must fail
# with a clear message instead of hanging.
out=$(env DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent PATH="$T/stub:/usr/bin" bash -c "command -v zenity kdialog >/dev/null || '$HELPER' pick-folder")
check "pick-folder without a chooser explains why" bash -c "[[ -z '$out' ]] || jq -e '.ok == false and (.error | test(\"type the path\"))' <<<'$out' >/dev/null"

# Settings copy outside shell.json.
CFG="$XDG_CONFIG_HOME/omavaults/config.json"
check "config-save writes file" "$HELPER" config-save "https://example.com/v.git" "~/Vaults" 120 >/dev/null
check "config-save content" test "$(jq -c . "$CFG")" = '{"repoUrl":"https://example.com/v.git","localPath":"~/Vaults","refreshIntervalSec":120}'
check "config-save requires url" bash -c "! '$HELPER' config-save '' '~/Vaults' >/dev/null"
check "config-save rejects bad interval" bash -c "! '$HELPER' config-save u p soon >/dev/null"

echo
echo "$pass passed, $failed failed"
(( failed == 0 ))
