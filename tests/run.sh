#!/bin/bash

# End-to-end tests for bin/omavaults against throwaway git repos.
# Never touches the real Obsidian config: XDG_CONFIG_HOME points at a temp dir,
# and xdg-open/pgrep are stubbed so no app is launched or detected.

set -uo pipefail

HELPER="$(cd "$(dirname "$0")/.." && pwd)/bin/omavaults"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export XDG_CONFIG_HOME="$T/config"
export XDG_CACHE_HOME="$T/cache"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
OBS="$XDG_CONFIG_HOME/obsidian/obsidian.json"

mkdir -p "$T/stub"
cat >"$T/stub/xdg-open" <<EOF
#!/bin/bash
echo "\$1" >>"$T/opened"
EOF
# "Obsidian running" is simulated by a real stand-in process named obsidian
# whose pid is stored in \$T/running; pgrep only ever reports that pid.
cat >"$T/stub/pgrep" <<EOF
#!/bin/bash
[[ -f "$T/running" ]] && cat "$T/running"
exit 0
EOF
# curl answers with $FAKE_HTTP_CODE and logs each request; never the network.
cat >"$T/stub/curl" <<STUB
#!/bin/bash
echo "\$*" >>"$T/curl.log"
printf '%s' "\${FAKE_HTTP_CODE:-000}"
STUB
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

# Conflict: both sides rewrite the same line. The remote version keeps the
# name, the local one is saved as a conflict copy, and the sync completes.
(cd "$T/other" && echo "remote line" >Work/todo.md && git commit -qam conflict && git push -q)
echo "local line" >"$T/local/Work/todo.md"
echo "keep me" >>"$T/local/Personal/journal.md"
out=$("$HELPER" sync "$T/local" Work)
check "conflicting sync succeeds" test "$(jq -r .ok <<<"$out")" = true
check "sync reports one conflict copy" test "$(jq -r .conflicts <<<"$out")" = 1
check "remote version keeps the name" test "$(cat "$T/local/Work/todo.md")" = "remote line"
copy=$(jq -r '.conflictCopies[0]' <<<"$out")
check "copy is named after the note" bash -c "[[ '$copy' == 'Work/todo (conflict '*').md' ]]"
check "copy holds the local version" test "$(cat "$T/local/$copy")" = "local line"
check "no rebase left behind" test ! -d "$T/local/.git/rebase-merge" -a ! -d "$T/local/.git/rebase-apply"
check "no conflict markers" bash -c "! grep -rq '<<<<<<<' '$T/local/Work'"
check "other vault's edits kept" grep -q "keep me" "$T/local/Personal/journal.md"
check "nothing left to push" test -z "$(git -C "$T/local" rev-list '@{u}..HEAD')"
(cd "$T/other" && git pull -q)
check "copy reached the remote" test -f "$T/other/$copy"
check "vault with copies needs attention" test "$(state_of Work)" = copies
check "status counts copies" test "$("$HELPER" status "$T/local" | jq -r '.vaults[] | select(.name == "Work") | .conflictCopies')" = 1
rm "$T/local/$copy"; "$HELPER" sync "$T/local" Work >/dev/null
check "deleting the copy clears it" test "$(state_of Work)" = synced
(cd "$T/other" && git pull -q)

# Edit vs delete: the edit survives, no copy.
(cd "$T/other" && echo base >Work/a.md && echo base >Work/b.md && git add -A && git commit -qm ab && git push -q)
"$HELPER" sync "$T/local" Work >/dev/null
(cd "$T/other" && git rm -q Work/a.md && echo "remote edit" >Work/b.md && git commit -qam "rm a, edit b" && git push -q)
echo "local edit" >"$T/local/Work/a.md"; rm "$T/local/Work/b.md"
out=$("$HELPER" sync "$T/local" Work)
check "edit/delete sync succeeds" test "$(jq -r .ok <<<"$out")" = true
check "local edit beats remote delete" test "$(cat "$T/local/Work/a.md" 2>/dev/null)" = "local edit"
check "remote edit beats local delete" test "$(cat "$T/local/Work/b.md" 2>/dev/null)" = "remote edit"
check "edit/delete makes no copies" test "$(jq -r '.conflicts // 0' <<<"$out")" = 0
(cd "$T/other" && git pull -q)

# Several unpushed local commits on the same note (e.g. syncs while offline).
echo "draft 1" >"$T/local/Work/c.md"; git -C "$T/local" add -A; git -C "$T/local" commit -qm c1
echo "draft 2" >"$T/local/Work/c.md"; git -C "$T/local" commit -qam c2
(cd "$T/other" && echo "theirs" >Work/c.md && git add -A && git commit -qm c && git push -q)
out=$("$HELPER" sync "$T/local" Work)
check "multi-commit conflict sync succeeds" test "$(jq -r .ok <<<"$out")" = true
check "remote keeps the name (multi)" test "$(cat "$T/local/Work/c.md")" = "theirs"
check "one copy per note per sync" test "$(jq -r .conflicts <<<"$out")" = 1
check "the copy holds the latest local draft" test "$(cat "$T/local/$(jq -r '.conflictCopies[0]' <<<"$out")")" = "draft 2"
(cd "$T/other" && git pull -q)
find "$T/local/Work" -name '* (conflict *' -delete; "$HELPER" sync "$T/local" Work >/dev/null; (cd "$T/other" && git pull -q)

# Binary attachments: the copy must be byte-identical to the local file.
head -c 2048 /dev/urandom >"$T/local/Work/img.png"; "$HELPER" sync "$T/local" Work >/dev/null; (cd "$T/other" && git pull -q)
head -c 2048 /dev/urandom >"$T/other/Work/img.png"; (cd "$T/other" && git commit -qam img && git push -q)
head -c 2048 /dev/urandom >"$T/local/Work/img.png"; cp "$T/local/Work/img.png" "$T/mine.png"
out=$("$HELPER" sync "$T/local" Work)
bcopy=$(jq -r '.conflictCopies[0]' <<<"$out")
check "binary conflict copy is byte-identical" cmp -s "$T/mine.png" "$T/local/$bcopy"
check "binary keeps remote under its name" cmp -s "$T/other/Work/img.png" "$T/local/Work/img.png"

# A second conflict on the same note in the same minute gets a distinct name.
(cd "$T/other" && git pull -q && echo r2 >Work/img.png && git commit -qam img2 && git push -q)
echo l2 >"$T/local/Work/img.png"
out=$("$HELPER" sync "$T/local" Work)
check "repeat conflict copy gets a new name" bash -c "[[ '$(jq -r '.conflictCopies[0]' <<<"$out")' != '$bcopy' && -f '$T/local/$bcopy' ]]"
find "$T/local/Work" -name '* (conflict *' -delete; "$HELPER" sync "$T/local" Work >/dev/null; (cd "$T/other" && git pull -q)

touch "$T/local/.git/FETCH_HEAD"
check "fetch --max-age skips a recent fetch" test "$("$HELPER" fetch "$T/local" --max-age 300 | jq -r .message)" = "Fetched recently"
touch -d '10 minutes ago' "$T/local/.git/FETCH_HEAD"
check "fetch --max-age fetches when stale" test "$("$HELPER" fetch "$T/local" --max-age 300 | jq -r .message)" = "Fetched"
check "fetch --max-age rejects junk" bash -c "! '$HELPER' fetch '$T/local' --max-age soon >/dev/null"
check "rejects path traversal" bash -c "! '$HELPER' sync '$T/local' ../x >/dev/null"
check "rejects bad open name" bash -c "! '$HELPER' open '$T/local' ../etc >/dev/null"

# Obsidian registration: only on request (register, or opening a vault).
reg_count() { [[ -s $OBS ]] && jq '[.vaults // {} | .[]] | length' "$OBS" || echo 0; }
"$HELPER" status "$T/local" >/dev/null
check "status never registers vaults" test "$(reg_count)" = 0
check "status reports vaults missing from Obsidian" \
  test "$("$HELPER" status "$T/local" | jq -c '[.vaults[] | select(.inObsidian | not) | .name]')" = '["Personal","Work"]'
check "status reports Obsidian not running" test "$("$HELPER" status "$T/local" | jq -r .obsidianRunning)" = false
"$HELPER" open "$T/local" Work >/dev/null
check "open launches URI" grep -q "obsidian://open?path=.*Work" "$T/opened"
check "opening registers just that vault" test "$(reg_count)" = 1
out=$("$HELPER" register "$T/local")
check "register adds the missing vaults" test "$(jq -r .registered <<<"$out")" = 1
check "all repo vaults now in Obsidian" test "$(reg_count)" = 2
check "register again is a no-op" test "$("$HELPER" register "$T/local" | jq -r '.registered // 0')" = 0
mkdir -p "$T/local/Alpha" "$T/local/Beta"
out=$("$HELPER" register "$T/local" Beta)
check "register with names adds only those" bash -c "[[ \$(jq -r .registered <<<'$out') == 1 ]] && jq -e '[.vaults[].path] | any(endswith(\"/Beta\"))' '$OBS' >/dev/null && ! jq -e '[.vaults[].path] | any(endswith(\"/Alpha\"))' '$OBS' >/dev/null"
check "register rejects unknown names" bash -c "! '$HELPER' register '$T/local' Nope >/dev/null"
check "register rejects path-like names" bash -c "! '$HELPER' register '$T/local' ../x >/dev/null"
rm -rf "$T/local/Alpha" "$T/local/Beta"

mkdir "$T/local/Research"
start_fake_obsidian() { (exec -a obsidian sleep 300) & echo $! >"$T/running"; }
stop_fake_obsidian() { [[ -f "$T/running" ]] && kill "$(cat "$T/running")" 2>/dev/null; rm -f "$T/running"; }
trap 'stop_fake_obsidian; rm -rf "$T"' EXIT
start_fake_obsidian
before=$(md5sum <"$OBS")
"$HELPER" status "$T/local" >/dev/null
check "status leaves obsidian.json alone while running" test "$before" = "$(md5sum <"$OBS")"
"$HELPER" open "$T/local" Research >/dev/null
check "unregistered vault while running -> exit 3" test $? -eq 3
check "no write while running" test "$before" = "$(md5sum <"$OBS")"
check "status reports Obsidian running" test "$("$HELPER" status "$T/local" | jq -r .obsidianRunning)" = true
out=$("$HELPER" register "$T/local"); rc=$?
check "register while running asks for a restart" bash -c "[[ $rc == 3 && \$(jq -r .needsRestart <<<'$out') == true ]]"
check "register while running writes nothing" test "$before" = "$(md5sum <"$OBS")"
: >"$T/opened"
out=$("$HELPER" register --restart "$T/local")
check "register --restart adds the vault" test "$(jq -r .registered <<<"$out")" = 1
check "register --restart quit Obsidian first" bash -c "! kill -0 \$(cat '$T/running') 2>/dev/null"
check "register --restart starts Obsidian again" grep -qx "obsidian://open" "$T/opened"

# Creating vaults.
stop_fake_obsidian
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

# Public-repository warning.
vis() { "$HELPER" visibility "$1" | jq -r .visibility; }
check "public GitHub repo" test "$(FAKE_HTTP_CODE=200 vis https://github.com/a/public.git)" = public
check "private GitHub repo" test "$(FAKE_HTTP_CODE=404 vis git@github.com:a/private.git)" = private
check "GitLab is checked" test "$(FAKE_HTTP_CODE=200 vis https://gitlab.com/a/b.git)" = public
check "Codeberg is checked" test "$(FAKE_HTTP_CODE=404 vis https://codeberg.org/a/b)" = private
check "network failure is unknown" test "$(FAKE_HTTP_CODE=000 vis https://github.com/a/flaky.git)" = unknown
check "other hosts are unknown" test "$(FAKE_HTTP_CODE=200 vis https://git.example.com/a/b.git)" = unknown
check "local paths are unknown" test "$(FAKE_HTTP_CODE=200 vis "$T/remote.git")" = unknown
n=$(wc -l <"$T/curl.log")
check "answers are cached across spellings" test "$(FAKE_HTTP_CODE=404 vis https://github.com/a/public)" = public
check "cached answer makes no request" test "$(wc -l <"$T/curl.log")" = "$n"
check "unknown answers are not cached" test "$(FAKE_HTTP_CODE=200 vis https://github.com/a/flaky.git)" = public
check "request carries no credentials" bash -c "! grep -qiE 'authorization|token|-u ' '$T/curl.log'"
check "request does not follow redirects" grep -q -- "--max-redirs 0" "$T/curl.log"

# Acknowledging a public repo is kept when settings are saved again.
"$HELPER" config-save --ack-public "https://github.com/a/public.git" >/dev/null
"$HELPER" config-save "https://github.com/a/public.git" "~/V" 300 >/dev/null
check "settings save keeps the public acknowledgement" test "$(jq -r .publicAcknowledged "$CFG")" = "https://github.com/a/public.git"
check "settings save updates the path" test "$(jq -r .localPath "$CFG")" = "~/V"
"$HELPER" config-save --dismiss-register "https://github.com/a/public.git" '["Work","Personal"]' >/dev/null
check "dismissed vault set is stored per repo" \
  test "$(jq -c '.registerDismissed["https://github.com/a/public.git"]' "$CFG")" = '["Work","Personal"]'
check "dismissing keeps other settings" test "$(jq -r .publicAcknowledged "$CFG")" = "https://github.com/a/public.git"
check "dismiss rejects non-list input" bash -c "! '$HELPER' config-save --dismiss-register u 'Work' >/dev/null"

# Security hardening.
# A clone URL that looks like an option must not be parsed as one.
check "option-like clone URL is not an option" bash -c "! '$HELPER' clone '--upload-pack=touch $T/pwned' '$T/optclone' >/dev/null; [[ ! -e '$T/pwned' ]]"

# Credentials in URLs are never echoed back.
out=$("$HELPER" clone "https://user:s3cr3t@127.0.0.1:9/x/y.git" "$T/credclone")
check "clone errors hide URL credentials" bash -c "! grep -q s3cr3t <<<'$out'"

# Obsidian detection: a live process that merely mentions obsidian in its
# arguments (matched by the old pattern) is ignored; one named obsidian counts.
detect() { PATH="/usr/bin:$PATH" bash -c 'source <(sed -n "/^obsidian_pid()/,/^}/p" "$1"); obsidian_pid' _ "$HELPER"; }
bash -c 'sleep 300; :' decoy "/home/x/obsidian notes" & decoy=$!
sleep 0.3
check "decoy is alive for the test" kill -0 "$decoy"
check "decoy mentioning obsidian is not Obsidian" bash -c "[[ \"\$(PATH=/usr/bin:\$PATH bash -c 'source <(sed -n \"/^obsidian_pid()/,/^}/p\" \"$HELPER\"); obsidian_pid')\" != $decoy ]]"
kill "$decoy" 2>/dev/null
(exec -a obsidian sleep 300) & standin=$!
sleep 0.3
check "a process named obsidian is detected" test "$(detect)" = "$standin"
kill "$standin" 2>/dev/null

# Conflict copies never write through a symlink in the repo.
(cd "$T/other" && git pull -q && mkdir -p Work/sub && echo base >Work/sub/n.md && git add -A && git commit -qm sub && git push -q)
"$HELPER" sync "$T/local" Work >/dev/null
mkdir -p "$T/outside-target"
(cd "$T/other" && echo "remote" >Work/sub/n.md && git commit -qam r && git push -q)
echo "local" >"$T/local/Work/sub/n.md"
# Plant a symlink where the copy would go (as if pulled from the repo).
stamp_glob="$T/local/Work/sub/n (conflict "
ln -s "$T/outside-target/evil.md" "$T/local/Work/sub/n (conflict $(hostname) $(date '+%Y-%m-%d %H%M')).md"
out=$("$HELPER" sync "$T/local" Work)
check "copy avoids a symlinked name" bash -c "[[ ! -s '$T/outside-target/evil.md' ]]"
check "sync still succeeds beside the symlink" test "$(jq -r .ok <<<"$out")" = true
rm -f "$T/local/Work/sub/"*conflict*; "$HELPER" sync "$T/local" Work >/dev/null; (cd "$T/other" && git pull -q)

# A symlinked directory on the copy's path aborts cleanly instead.
(cd "$T/other" && echo base >Work/sub/m.md && git add -A && git commit -qm m && git push -q)
"$HELPER" sync "$T/local" Work >/dev/null
(cd "$T/other" && echo "remote" >Work/sub/m.md && git commit -qam rm && git push -q)
echo "local" >"$T/local/Work/sub/m.md"
check "symlink guard rejects symlinked folders" bash -c "source <(sed -n '/^inside_repo_no_symlinks()/,/^}/p' '$HELPER'); mkdir -p '$T/g/real'; ln -sfn '$T/outside-target' '$T/g/link'; ! inside_repo_no_symlinks '$T/g' 'link/x.md' && inside_repo_no_symlinks '$T/g' 'real/x.md' && ! inside_repo_no_symlinks '$T/g' '../x.md'"
"$HELPER" sync "$T/local" Work >/dev/null; (cd "$T/other" && git pull -q)

echo
echo "$pass passed, $failed failed"
(( failed == 0 ))
