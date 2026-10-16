.pragma library

// Pure presentation helpers for omaVaults: no QML types, so BarWidget.qml and
// Panel.qml share one source of truth for how a vault state reads.

function stateGlyph(state) {
  switch (state) {
    case "synced": return "󰄬"
    case "modified": return "󰏫"
    case "ahead": return "󰁝"
    case "behind": return "󰁅"
    case "diverged": return "󰃻"
    case "conflict": return "󰀦"
    case "copies": return "󰈢"
    case "unpublished": return "󰅤"
    default: return "󰘥"
  }
}

function hostName(host) {
  switch (host) {
    case "github.com": return "GitHub"
    case "gitlab.com": return "GitLab"
    case "codeberg.org": return "Codeberg"
    default: return host
  }
}

function plural(n, one, many) {
  return n + " " + (n === 1 ? one : many)
}

function size(kb) {
  if (kb < 1024) return Math.max(1, Math.round(kb)) + " KB"
  if (kb < 1024 * 1024) return (kb / 1024).toFixed(kb < 10240 ? 1 : 0) + " MB"
  return (kb / 1024 / 1024).toFixed(1) + " GB"
}

function stateText(v) {
  var copies = Number(v.conflictCopies) || 0
  var base = baseStateText(v)
  if (copies > 0 && v.state !== "copies") base += " · " + plural(copies, "conflict copy", "conflict copies")
  return base
}

function baseStateText(v) {
  switch (v.state) {
    case "synced": return "Up to date"
    case "modified": return plural(v.dirty, "local change", "local changes")
    case "ahead": return plural(v.ahead, "commit to push", "commits to push")
    case "behind": return plural(v.behind, "update available", "updates available")
    case "diverged": return "Local and remote changes — sync to merge"
    case "conflict": return "Conflict — resolve in the repo"
    case "copies": return plural(Number(v.conflictCopies) || 0, "conflict copy", "conflict copies") + " to merge"
    case "unpublished": return "Not on the remote yet"
    default: return String(v.state || "")
  }
}

// "urgent" | "dim" | "accent": the caller maps the tone to theme colors.
function stateTone(state) {
  if (isTrouble(state)) return "urgent"
  if (state === "synced") return "dim"
  return "accent"
}

function isTrouble(state) {
  return state === "conflict" || state === "diverged" || state === "copies"
}

function relativeTime(epochSec, nowMs) {
  if (!epochSec) return "never"
  var s = Math.max(0, Math.round(nowMs / 1000 - epochSec))
  if (s < 60) return "just now"
  if (s < 3600) return Math.floor(s / 60) + "m ago"
  if (s < 86400) return Math.floor(s / 3600) + "h ago"
  return Math.floor(s / 86400) + "d ago"
}

function summary(configured, repo, attentionCount, hasConflict) {
  if (!configured) return "NOT CONFIGURED"
  if (!repo || !repo.cloned) return "NOT CLONED"
  var n = repo.vaults ? repo.vaults.length : 0
  var state = hasConflict ? "NEEDS ATTENTION" : attentionCount > 0 ? attentionCount + " TO SYNC" : "UP TO DATE"
  return plural(n, "VAULT", "VAULTS") + " · " + state
}
