# Noctalia Restic Snapshot Service — Implementation Plan

> **Goal:** a Noctalia v5 plugin that schedules `restic` backups, shows their health in the
> bar, and browses/restores snapshots from a panel — without ever putting a repository
> password into plaintext plugin settings.

**Status:** plan only. No repository is initialised, no backup is run, and no package is
installed during planning.

---

## Why this one

- Omarchy's **Time Machine** (restic backups, 96★) has no Noctalia equivalent. The Noctalia
  community store ships **164 plugins and zero backup/snapshot managers** (catalog snapshot
  2026-09-08).
- `restic 0.19.1-1.1` is available in `cachyos-extra-v3` and is not currently installed on
  this machine — the plugin must degrade cleanly when the binary is missing.
- It fits the proven `noctalia-taildrop` shape exactly: a headless service owning the work,
  a thin widget, and one focused panel. No new architectural ground.

## Architecture

```
[[service]]  service.luau     single writer: schedule tick, job queue, restic argv, state
[[widget]]   widget.luau      status glyph + last-run age; sparkline of snapshot sizes
[[panel]]    panel.luau       snapshot browser + run controls + restore wizard
[[shortcut]] shortcut.luau    "back up now" control-center tile
lib/         schedule.luau    cron-lite parsing, next-run math, retention policy validation
             restic.luau      argv builders + --json parsers, pure and unit-testable
             state.luau       state keys, schema versions, migration
```

Separation rule: **the service is the only entry that executes restic.** Widget, panel, and
shortcut talk to it through `noctalia.state` (watch) and IPC (`noctalia msg plugin …`). This
keeps one lock owner and one source of truth, mirroring the taildrop service.

### Execution safety

| Rule | Reason |
| --- | --- |
| Use `noctalia.runAsync(argvTable, cb, timeout)` (**API 24**) for every restic call | argv form executes the program directly, no shell parsing, no injection |
| `runStream(cmd, onLine)` takes a **string only** — interpolate nothing untrusted into it | only validated enums/paths/whitelisted numbers may be interpolated |
| Passwords arrive as `RESTIC_PASSWORD_FILE` / `RESTIC_PASSWORD_COMMAND` / systemd credential **paths**, never values | plugin settings are plaintext TOML |
| Every destructive call (`forget --prune`, `restore` in place) runs `--dry-run` first and needs explicit confirmation | retention and restore are irreversible |
| Timeout every invocation; classify `timedOut` separately from a non-zero exit | a hung restic must not wedge the service tick |

## Stack

- Noctalia v5 Luau entries, `plugin_api = 24` (argv `runAsync`); feature-detect API 26/28.
- `restic` 0.19+, optional `systemd` user timer, optional `rclone`/`sftp` backends.
- `noctalia.state` for cross-entry state, `pluginDataDir()` for durable schedule/history,
  `noctalia.json` for parsing restic `--json` output.

## Scope and corrections

- The plugin is a **front-end**, not a scheduler replacement. If a systemd user timer already
  runs restic, the plugin must be able to run in "observe only" mode (read snapshots, never
  trigger).
- Scheduling lives in the plugin service by default (interval + optional daily window), with a
  documented `systemd` mode as an alternative for machines that must back up while the shell is
  not running.
- Retention (`forget`) is **opt-in and never automatic on first install**.
- Restore defaults to a **staging directory**, never in place.
- Local snapshot history is for display only; restic's repository is authoritative.

## Proposed files

```
restic-snapshots/
  plugin/restic/plugin.toml
  plugin/restic/service.luau
  plugin/restic/widget.luau
  plugin/restic/panel.luau
  plugin/restic/shortcut.luau
  plugin/restic/lib/schedule.luau
  plugin/restic/lib/restic.luau
  plugin/restic/lib/state.luau
  plugin/restic/translations/en.json
  plugin/restic/README.md
  plugin/restic/CHANGELOG.md
  plugin/restic/thumbnail.webp
  tests/test_restic_argv.py        # mirrors argv builders; asserts no shell metacharacters
  tests/test_schedule.py           # next-run math, DST, retention validation
  docs/ipc-contract.md
```

### Manifest sketch

```toml
id = "carlocamacho/restic"
name = "Restic Snapshots"
icon = "archive"
version = "0.1.0"
plugin_api = 24
author = "carlocamacho"
license = "MIT"
dependencies = ["restic"]
tags = ["system", "backup", "panel", "service", "utility"]

[[setting]]
key = "repository"
type = "string"
label_key = "settings.repository.label"
description_key = "settings.repository.description"
default = ""

[[setting]]
key = "password_file"
type = "file"
label_key = "settings.password_file.label"
description_key = "settings.password_file.description"
default = ""

[[setting]]
key = "mode"
type = "select"
label_key = "settings.mode.label"
default = "plugin"
# `options` is an array of { value, label_key } tables.
options = [
  { value = "plugin",  label_key = "settings.mode.plugin" },
  { value = "observe", label_key = "settings.mode.observe" },
]

[[service]]
id = "service"
entry = "service.luau"

[[widget]]
id = "status"
entry = "widget.luau"

[[panel]]
id = "browser"
entry = "panel.luau"
width = 720
height = 520
placement = "floating"
position = "center"
keyboard_focus = "exclusive"

[[shortcut]]
id = "backup_now"
entry = "shortcut.luau"
```

## Phase 0 — feasibility gate (read-only)

1. Confirm `restic` presence with `noctalia.commandExists("restic")` and capture
   `restic version`. Record that it is **absent today**; the plugin must render an
   "install restic" state rather than an error.
2. Confirm password delivery works non-interactively *before* any UI work: with the user's
   explicit permission and an existing repository, run a read-only
   `restic snapshots --json` with `RESTIC_PASSWORD_FILE` set. Do not print credentials,
   repository URLs, or snapshot paths in logs.
3. Capture the **real** JSON shapes for `snapshots`, `backup`, `check`, `stats`, and
   `forget --dry-run --json`. Treat these as fixtures; do not assume field names.
4. Verify the argv form of `runAsync` with a trivial `{"restic","version"}` and confirm
   `exitCode`, `stdout`, `stderr`, and `timedOut` behave as documented.
5. Decide the scheduler owner (plugin service vs. systemd user timer) and record the decision
   in `docs/ipc-contract.md`.

**Exit criteria:** read-only snapshot listing works, JSON fixtures captured, argv execution
proven. No writes, no repo init, no backup.

## Phase 1 — data contract

1. Define the state keys and their schemas in `lib/state.luau`:
   - `restic_status` — `{ available, version, repoConfigured, mode, phase, lastRun, nextRun, busy, error }`
   - `restic_snapshots` — bounded list `{ id, shortId, time, hostname, tags, paths, sizeBytes }`
   - `restic_job` — `{ id, kind, phase, percent, filesDone, bytesDone, startedAt, finishedAt, exitCode, error }`
2. Bound everything: cap snapshot list length, truncate stdout/stderr, keep history to N runs.
3. Write `lib/restic.luau` as pure functions: `buildBackupArgs`, `buildSnapshotsArgs`,
   `buildForgetArgs`, `parseSnapshots(json)`, `parseProgress(line)`. No I/O — unit-testable.
4. Write `lib/schedule.luau`: interval parsing, next-run computation, quiet-window overlap
   handling, and retention-policy validation (`keep-daily/weekly/monthly/yearly`, `keep-last`).
5. Emit a schema version with every state write and ignore unknown future fields on read.

## Phase 2 — service (`service.luau`)

1. `onEnable()` starts the scheduler; `onExit(_signal, reason)` stops it and releases the lock.
2. Tick every second (via `noctalia.setUpdateInterval(1000)`); the scheduler only fires when
   `now >= nextRun` and no job is in flight (single-flight guard).
3. Publish status transitions to `restic_status`; only `state.set` when a value actually
   changes, so panels are not re-rendered on every tick.
4. Run `backup` with `runAsync` argv and parse `--json` progress into `restic_job`.
5. On completion: refresh the snapshot list, compute the next run, notify on success/failure
   (`noctalia.notify` / `noctalia.notifyError`), and persist history to `pluginDataDir()`.
6. IPC surface (also documented in `docs/ipc-contract.md`):

   | Event | Payload | Effect |
   | --- | --- | --- |
   | `refresh` | — | re-read snapshots |
   | `backup-now` | `{ tags?, paths? }` | queue a backup |
   | `check` | `{ readDataSubset? }` | run `restic check` |
   | `forget-dry-run` | `{ policy }` | validate retention without pruning |
   | `cancel` | `{ jobId }` | cancel the running job |

7. Handle `onConfigChanged()` by re-validating the repository/password path and re-arming the
   schedule without restarting the plugin.

## Phase 3 — widget (`widget.luau`)

1. `update()` renders: glyph + last-run age; tooltip with repository, snapshot count, size,
   and next run. Use `barWidget.render` with `ui.*` for a sparkline (`ui.graph` of the last N
   snapshot sizes) — `ui.input`/`ui.select`/`ui.scroll` are not available in the bar.
2. State mapping: `ok` / `running` / `stale` (older than 2× interval) / `error` / `no-repo` /
   `restic-missing`. Never show a green state when the binary is missing.
3. Clicks: left toggles the panel; declare `[widget.actions] right = "…"` defaults in the
   manifest and remember every widget already gets `middle = "settings-open-widget"`.
4. `onScroll` steps through the last N snapshots in the tooltip.

## Phase 4 — panel (`panel.luau`)

1. Tabs as `ui.row` chips (not `ui.select` — dropdowns are unavailable in a persistent panel):
   **Snapshots · Run · Restore · Retention**.
2. Snapshots tab: scrollable list (`ui.scroll`), per-row time/host/tags/size, a search
   `ui.input` (filter by tag/path/host), and per-row actions (browse contents via
   `restic ls --json`, diff two selected snapshots, restore).
3. Run tab: path/tag inputs, `--dry-run` preview, live progress from `restic_job`, cancel.
4. Restore tab: pick snapshot → pick paths (`--include`) → **staging target directory**
   (default `~/restore/<snapshot>`); in-place restore requires typing the target path to
   confirm.
5. Retention tab: edit a policy, always preview with `forget --dry-run --json`, show exactly
   what would be removed, then require an explicit confirm before the real prune.
6. Use `panel.openContextMenu` (API 28, feature-detected) for right-click row actions; fall
   back to visible buttons when unavailable.

## Phase 5 — safety, tests, delivery

1. Unit tests for `lib/restic.luau` and `lib/schedule.luau`: assert argv builders never emit
   shell metacharacters for hostile inputs (spaces, quotes, `$(…)`, backticks, newlines), and
   that schedule math survives DST boundaries and month ends.
2. Manual matrix: restic missing · repo unset · wrong password · repo unreachable · disk full ·
   interrupted backup · concurrent external backup (lock conflict) · restore to an existing
   non-empty directory.
3. Verify a **dry-run never mutates**: compare `restic snapshots --json` before/after.
4. Package per the workflow doc: `plugin.toml`, entries, `README.md`, `thumbnail.webp`,
   `translations/en.json`; local test via `~/.local/share/noctalia/plugins/restic/` and
   `noctalia msg plugin carlocamacho/restic:service all refresh`.
5. Submit to `noctalia-dev/community-plugins` under a first-come directory name (`restic` is
   currently unused).

## Acceptance criteria

- With no repository configured, the widget shows a calm "not configured" state and the panel
  explains what to set; nothing errors.
- With restic missing, the plugin says so and offers the exact install command; no retry loop.
- A scheduled backup runs unattended, survives a shell restart, and reports success/failure.
- Snapshot list, sizes, and per-snapshot contents match `restic snapshots --json` and
  `restic ls --json` exactly.
- `forget` and in-place restore are impossible without an explicit confirmation step, and both
  always show a dry-run first.
- No password value is ever written to plugin settings, logs, state, or notifications.
- A hung restic process is reported as a timeout and the next scheduled run still fires.

## Deferred scope

- Multi-repository profiles (one plugin instance per repo is the MVP).
- Remote/cloud browser integration (rclone remotes, S3 object browser).
- Snapshot mount/unmount (`restic mount` + a FUSE check).
- File-level diff viewer beyond restic's own `--json` output.
- A `[[launcher_provider]]` `/snap` search provider.

## Risks / rollback

| Risk | Mitigation |
| --- | --- |
| Wrong retention policy deletes snapshots | dry-run always shown first; no automatic prune; confirm-by-typing |
| Password leaks through logs or state | never read the password; pass only the file/command path; redact stderr before display |
| Concurrent restic runs | service single-flight guard plus restic's own repository lock; surface lock errors clearly |
| Long backup blocks the shell | work runs in `runAsync`, not on the UI thread; the panel streams progress, never blocks |
| Plugin uninstalled mid-job | `onExit(_, "uninstall")` cancels the job; restic's lock is released on process exit |

**Rollback:** disable the plugin (`noctalia msg plugins disable carlocamacho/restic`). The
service stops, the widget disappears, and no repository data is touched — the plugin never
writes to the repository except through the explicit commands above.

## Sources

- [Noctalia plugin development](https://docs.noctalia.dev/noctalia/plugins/development/) ·
  [Runtime API](https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/) ·
  [Plugin API versions](https://docs.noctalia.dev/noctalia/plugins/development/plugin-api/) ·
  [Workflow & publishing](https://docs.noctalia.dev/noctalia/plugins/development/workflow/)
- [restic documentation](https://restic.readthedocs.io/en/stable/) (commands, `--json`,
  `RESTIC_PASSWORD_FILE`, repository locking)
- Local evidence: `pacman -Si restic` → `0.19.1-1.1` in `cachyos-extra-v3`; `restic` absent;
  Noctalia community catalog has no backup plugin.
