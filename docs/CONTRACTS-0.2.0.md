# Restic Snapshots 0.2.0 — frozen contracts & workstream map

This file is the coordination artifact for the 0.2.0 work. **Read it before writing code.** It
exists so five workstreams can proceed in parallel without touching each other's files or
guessing at an interface someone else is implementing.

If you need to change something frozen here, **stop and report it** instead of changing it
unilaterally — another workstream is probably already coding against it.

---

## 1. Why 0.2.0 exists (context from the review)

The 0.1.0 plugin was reviewed against its own plan. It works, but five things made it unsafe to
trust with real backups:

1. `jobs.poll()` discards the final output when the log size did not change between ticks but the
   `.exit` file appeared — **reproduced**, and the retention preview then reported
   "Would keep 0, remove 0" while offering no Prune button.
2. The schedule (`lastRun`, `nextRunAt`) lived only in memory and re-armed from "now" on every
   load, so a shell restart or a settings edit could push a backup forward forever, silently.
3. A failed job never set `status.error`, so the bar module could not turn red; a cancel looked
   exactly like a failure.
4. A hung restic process blocked every future run forever (no watchdog).
5. Restore was one unconfirmed click with an unvalidated snapshot id and target; there was no
   dry-run and no destination allow-list.

0.2.0 fixes all five and adds the features that make the plugin *believable*: persistence, a
staleness guardian, scheduled integrity checks, repository stats, per-snapshot file listing, a
job log viewer, single-snapshot forget, snapshot filtering, and a real restore flow.

---

## 2. Ground rules (all workstreams)

**Environment.** The repository lives on the user's CachyOS box and you reach it over SSH:

```bash
ssh -F /opt/data/.ssh/config cachyos-ts 'bash -lc "cd /home/ian/work/.wt-<yours> && <cmd>"'
```

- The remote **login shell is fish**, so always wrap remote commands in `bash -lc "..."`.
- Your worktree is already created and checked out on your branch. **Work only there.**
- Do **not** edit `/home/ian/work/restic-snapshots` (the main checkout): the user's *running*
  shell loads that directory through a path source and hot-reloads on change.
- Do **not** run `noctalia msg plugins ...` (enable/disable/source). Live verification is the
  lead's job, after merge.
- Do **not** `git push`. Commit in your worktree; the lead merges and pushes.

**Language.** Files are Luau (`.luau`) but the test suite runs them under **Lua 5.4**:
- `luac -p` must pass on every file you touch.
- No Luau-only syntax: no `continue`, no type annotations, no string interpolation, no `+=`.
- `--!nonstrict` header, locals declared before use, no new globals.
- Modules are loaded with an explicit extension: `require("./lib/restic.luau")`.

**Style.** Match the existing code: section banners (`-- ── name ───`), comments that explain
*why* a decision was made (not what the line does), pure functions in `lib/`, I/O only in
services/entries. Do not reformat or re-wrap code you are not changing. Keep diffs reviewable.

**Security invariants — do not weaken any of these.**
- Every restic invocation is an **argv vector**. No shell string is ever built from settings.
- The password travels as `--password-file <path>`; the plugin never reads the file.
- Values from IPC are untrusted: validate before use.
- No new network calls, no new downloads, no obfuscated code.
- Generated scripts: `0600`, and never contain credentials (only paths).

**Testing — required, every workstream.**

```bash
cd /home/ian/work/.wt-<yours>
python3 -m unittest discover -s tests          # python: argv builders, parsers, schedule
for f in tests/lua/*.lua; do lua5.4 "$f"; done # lua: real entries/renders driven by the harness
luac -p plugin/restic-snapshots/*.luau plugin/restic-snapshots/lib/*.luau
noctalia plugins lint plugin/restic-snapshots
```

All existing tests must keep passing. Add tests for every behaviour you introduce — a review
finding once shipped because the suite never exercised "size unchanged + exit present", so
**the new tests are part of the deliverable, not a nice-to-have**.

The test host stub is `tests/lua/harness.lua` (owned by the lead; it now supports nested JSON
encode, real file sizes, `H.mtimes` for sweep tests, and the newer API members). If you need
another stub, ask for it in your report rather than editing the harness.

**Report format (final message).** Keep it short and factual:
1. files changed, one line each, with why;
2. exact commands run + observed results;
3. anything you could not do, or deliberately left out (be explicit — hidden gaps are worse than
   reported ones);
4. your commit hash(es).

## 3. Workstreams, branches, worktrees, file ownership

| WS | Branch | Worktree | Owns (only these files) |
|---|---|---|---|
| A | `fix/jobs-core` | `/home/ian/work/.wt-a` | `plugin/restic-snapshots/lib/jobs.luau`, `tests/lua/jobs_test.lua` |
| B | `feat/command-layer` | `/home/ian/work/.wt-b` | `plugin/restic-snapshots/lib/restic.luau`, `tests/test_restic.py` |
| C | `feat/service-trust` | `/home/ian/work/.wt-c` | `plugin/restic-snapshots/service.luau`, `lib/schedule.luau`, `plugin.toml`, `tests/test_schedule.py`, `tests/lua/service_test.lua` |
| D | `feat/panel-ux` | `/home/ian/work/.wt-d` | `plugin/restic-snapshots/panel.luau`, `widget.luau`, `shortcut.luau`, `tests/lua/panel_render_test.lua`, `tests/lua/widget_render_test.lua` |
| E | `docs/packaging` | `/home/ian/work/.wt-e` | `README.md`, `CHANGELOG.md`, `catalog.toml` |

All five branch from `release/0.2.0`, which already contains the frozen interfaces:
`lib/store.luau` (used by C), the new `lib/state.luau`, `plugin.toml`, `translations/en.json`
and the extended `tests/lua/harness.lua`.

**Already done in the contracts commit — do not redo:** `plugin.toml` (settings, `plugin_api`
30, tags, version), `translations/en.json` (every new label and panel string), `lib/state.luau`
(keys/events/status shape), `lib/store.luau`.

**Nobody edits `translations/en.json`.** Use the frozen keys (`panel.*`, `settings.*`,
`widget.*`). If a string you need is missing, use `noctalia.tr("panel.your_key")` anyway and note
it in your report — the lead will add the key during integration. `noctalia.tr` returns the key
unchanged when it is missing, so this is safe at runtime.

---

## 4. Frozen interfaces

### 4.1 `lib/store.luau` (already written, lead-owned)

```lua
M.SCHEMA = 1
M.filePath() -> string|nil
M.load() -> table          -- {} for missing/corrupt/older-schema; never nil
M.replace(record) -> ok, err
M.patch({ key = value }) -> ok, err     -- shallow merge; nil values ignored
```

Suggested persisted record (C decides the exact fields, but keep them flat and JSON-safe):

```lua
{ lastRun = {...}, lastSuccessAt = <epoch>, nextRunAt = <epoch>, lastLog = "<path>",
  lastCheckAt = <epoch>, checkRotationIndex = <n>, lastRestoreAt = <epoch> }
```

### 4.2 `lib/state.luau` (already written — read it)

Keys: `KEY_STATUS`, `KEY_SNAPSHOTS`, `KEY_JOB`, `KEY_JOBLOG`, `KEY_STATS`, `KEY_FILES`,
`KEY_DIFF`. Events: `EVENT_REFRESH`, `EVENT_BACKUP`, `EVENT_CHECK`, `EVENT_FORGET_DRY`,
`EVENT_FORGET`, `EVENT_FORGET_ONE`, `EVENT_RESTORE_DRY`, `EVENT_RESTORE`, `EVENT_CANCEL`,
`EVENT_STATS`, `EVENT_LS`, `EVENT_DIFF`, `EVENT_INIT`, `EVENT_UNLOCK`, `EVENT_LOGS`.

The **status shape** is `state.emptyStatus()` — the service writes it, the panel/widget read it.
`status.repository` is always the **redacted** display string.

### 4.3 Settings keys (already in `plugin.toml`, labels already in `en.json`)

| key | type | meaning |
|---|---|---|
| `repository`, `password_file`, `backup_paths`, `backup_tags`, `exclude_file`, `mode`, `interval_minutes`, `keep_last`, `keep_daily`, `keep_weekly`, `keep_monthly`, `restore_target`, `check_subset`, `restic_bin` | as 0.1.0 | unchanged |
| `env_file` | file | sourced by the job script before restic runs (cloud/remote credentials) |
| `job_timeout_minutes` | int, 180 | watchdog ceiling for a single job |
| `check_interval_hours` | int, 0 | scheduled `restic check`; 0 = off |
| `stale_after_hours` | int, 0 | staleness threshold; 0 = derive from the interval |
| `restore_allow_roots` | string_list, `[]` | extra directories a restore may target |
| `show_count`, `show_staleness` | widget bools | widget display |

### 4.4 `lib/restic.luau` — B implements, C and D call

`M.config(settings)` returns exactly this shape (all keys always present):

```lua
{ bin, repository, redactedRepository, passwordFile, paths, tags, excludeFile, mode,
  intervalMinutes, keepLast, keepDaily, keepWeekly, keepMonthly, restoreTarget,
  restoreAllowRoots,          -- expanded absolute paths
  checkSubset, checkIntervalHours, staleAfterHours, jobTimeoutMinutes, envFile }
```

Pure commands (argv vectors, no I/O):

```lua
M.baseArgs(cfg, binPath)
M.backupArgs(cfg, binPath)
M.snapshotsArgs(cfg, binPath)                     -- read-only: adds --no-lock
M.statsArgs(cfg, binPath)                         -- --no-lock --json
M.checkArgs(cfg, binPath, subsetOverride)         -- subsetOverride wins over cfg.checkSubset
M.policyArgs(cfg), M.hasPolicy(cfg)
M.forgetArgs(cfg, binPath, dryRun)
M.forgetOneArgs(cfg, binPath, snapshotId)         -- `forget <id> --json`, never --prune
M.restoreArgs(cfg, binPath, snapshot, target, includes, opts)   -- opts = { dryRun = bool }
M.lsArgs(cfg, binPath, snapshot)                  -- --no-lock --json
M.diffArgs(cfg, binPath, fromId, toId)            -- --no-lock --json
M.initArgs(cfg, binPath)
M.unlockArgs(cfg, binPath)                        -- unlock --remove-all
```

Pure parsers / helpers:

```lua
M.parseJsonLines(text) -> { object, ... }         -- skips malformed lines
M.lastSummary(objects) -> object|nil
M.lastStatusLine(text) -> object|nil              -- decode one status line from the .status file
M.parseSnapshots(text) -> { snapshot, ... }
M.parseObject(text) -> table|nil
M.parseStats(text) -> { totalBytes, totalFileCount, snapshotsCount }|nil
M.parseLs(text, limit) -> { entries = {...}, truncated = bool }
M.parseDiff(text, limit) -> { added, removed, changed, truncated }|nil
M.snapshotRow(snapshot) -> row                    -- bounded fields only
M.snapshotSummary(rows) -> { count, newestAt }    -- newestAt: epoch seconds, from row.time
M.summariseForgetDry(objects, limit)
      -> { keepCount, removeCount, remove = { { id, shortId, time }, ... } }
M.filterSnapshots(rows, filter) -> rows           -- filter = { host = ?, tag = ?, text = ? }
M.validSnapshotId(id) -> bool                     -- ^[0-9a-fA-F]{4,64}$
M.validRestoreTarget(cfg, path) -> ok, err        -- absolute, resolved, not /, not $HOME, not a
                                                  -- backup source, under restoreTarget or an
                                                  -- allow-listed root, and not already occupied
M.redactRepository(value) -> string               -- strips userinfo@ and any token query params
M.humanBytes(value), M.ageLabel(seconds)
M.shellQuote(value), M.shellArgv(argv)
```

`snapshotRow` must now also carry `paths` (already does) and `shortId`; `snapshotSummary` is the
single source of truth for "newest snapshot age" so the service and the widget agree.

### 4.5 `lib/jobs.luau` — A implements, C calls

```lua
M.start(argv, opts) -> token, err, paths
  -- opts = { pathPrefix = string?, envFile = string?, detach = bool? }
  -- paths = { log, status, exit, pid, script, fifo }
M.poll(token, paths, lastSize)
  -> { done, exitCode, text, statusLine, changed, size }
M.cancel(paths) -> bool
M.readLog(path, maxBytes, maxLines) -> text        -- for the log viewer
M.sweep(maxAgeMs) -> removed
M.dataDir(sub) -> dir|nil, err
```

Generated script layout in `<pluginDataDir>/jobs/`:

```
<token>.sh       the generated script (mode 0600)
<token>.fifo     named pipe carrying restic's combined stdout+stderr
<token>.jsonl    every non-status line, appended (this is the job log)
<token>.status   the newest status JSON line, overwritten in place
<token>.pid      pid of the restic process (not of a pipeline member)
<token>.exit     restic's exit code, written when it exits
```

Two hard requirements, both from review findings:

1. **`poll` must return the log text whenever `done` is true**, even if the size did not change
   since the previous call — and the regression test for it must be in `tests/lua/jobs_test.lua`.
   Shape:

   ```lua
   if lastSize ~= nil and size == lastSize and not result.done then
     return result
   end
   ```

2. **The recorded pid must belong to restic.** A naive `restic | filter` pipeline puts the
   *filter's* pid in `$!`, so cancellation would kill the wrong process. Use a FIFO so restic
   itself can be backgrounded and its own status waited on:

   ```sh
   mkfifo "$fifo"
   restic … --json > "$fifo" 2>&1 &
   child=$!
   printf '%s' "$child" > "$pidfile"
   while IFS= read -r line; do
     case "$line" in
       *'"message_type":"status"'*) printf '%s\n' "$line" > "$statusfile" ;;
       *) printf '%s\n' "$line" >> "$logfile" ;;
     esac
   done < "$fifo"
   wait "$child"
   printf '%s' "$?" > "$exitfile"
   rm -f "$fifo"
   ```

   `envFile`, when set, is sourced first: `set -a; . '<path>'; set +a` (single-quoted). `PATH` is
   still set from `pathPrefix`. The script must start with a `chmod 600` on itself and on the log
   files it creates.

   A Python test that writes an equivalent script, runs it through `/bin/sh` with a fake restic
   that emits status lines, and asserts the split is welcome (optional but valuable — it is the
   only way to exercise the shell for real).

### 4.6 `lib/schedule.luau` — C owns

Keep `nextRun`, `due`, `untilLabel` (existing semantics) and add:

```lua
M.staleThresholdHours(cfg) -> number            -- stale_after_hours, else max(2 * interval/60, 2)
M.isStale(nowSec, newestSnapshotAt, thresholdHours) -> bool
M.checkDue(nowSec, lastCheckAt, intervalHours) -> bool
M.subsetForIndex(index, total) -> string        -- "3/7"; index wraps
```

### 4.7 Service behaviour C must implement

- **Persistence.** Load the store on start; persist after every job finish, snapshot refresh and
  config change (`store.patch`). `nextRunAt` is computed from **`lastSuccessAt`**, not from now.
  If the stored `nextRunAt` is already in the past at startup, run within ~60 s (catch-up) — do
  not add a whole interval.
- **Watchdog.** `status.jobStartedAt` is set when a job starts. In `update()`, a job running
  longer than `jobTimeoutMinutes * 60` is cancelled, finished as a failure with
  `exitCode = 124` and the message "timed out", and the single-flight guard is released so the
  next scheduled run still fires.
- **Cancel is not failure.** Set an explicit `cancelRequested` flag before signalling; the finish
  path records `lastRun.cancelled = true`, notifies once ("backup cancelled"), leaves
  `lastSuccessAt` alone and re-arms the schedule from now.
- **Failure visibility.** Any non-zero, uncancelled exit sets `status.error` (and
  `lastRun.ok = false`). Success clears `status.error`.
- **Staleness guardian.** After each snapshot refresh compute `newestSnapshotAt`/`staleness`/
  `stale` from `restic.snapshotSummary`. Notify **once** on the transition into stale and once on
  recovery — never on every tick.
- **Scheduled checks.** When `checkIntervalHours > 0` and due, run `check` with the rotating
  subset from `schedule.subsetForIndex`, persist `lastCheckAt`/`checkRotationIndex`, and store
  `checks = { lastAt, lastOk, numErrors }`.
- **Init detection.** When `snapshots` fails with a not-initialised repository, set
  `initNeeded = true` (match on restic stderr: "does not exist", "unable to open config",
  "Is there a repository"), and clear it after a successful `EVENT_INIT`.
- **Lock errors.** If restic reports a lock, set an error message containing "locked" so the
  panel can offer `EVENT_UNLOCK`.
- **Redaction.** `status.repository = restic.redactRepository(cfg.repository)`.
- **`envFile`** is passed through to `jobs.start` as `opts.envFile`.
- **Log publishing.** After a job finishes, publish `KEY_JOBLOG` with
  `{ kind, at, ok, cancelled, exitCode, lines = { tail lines }, truncated = bool }` (tail via
  `jobs.readLog`, bounded: ≤ 200 lines, ≤ 32 KiB) and persist `lastLog` so the viewer works after
  a restart. `EVENT_LOGS` re-publishes from the persisted path.
- **IPC.** Dispatch every frozen event; validate payloads (`restic.validSnapshotId`,
  `restic.validRestoreTarget`); on rejection notify the reason and publish nothing. Wrap the
  handler in `pcall` as today.
- **Restore flow.** `EVENT_RESTORE_DRY` runs `restore … --dry-run --json` as a job and publishes
  the summary into `KEY_JOB` (`kind = "restore-dry"`, `ok`, `files`, `target`). `EVENT_RESTORE`
  validates the snapshot id and target first, then runs the real restore. Both stay inside the
  single-flight guard.
- **Concurrency.** While a job is in flight, skip read-only refreshes (`snapshots`/`stats`/`ls`)
  rather than racing the repository lock. Read-only commands carry `--no-lock`.

### 4.8 Panel/widget behaviour D must implement

Tabs: **Snapshots / Run / Retention / Log**.

- **Snapshots.** Filter row: a select (`all snapshots` / `this host only` / `tagged <tag>`) plus a
  text input filtered with `restic.filterSnapshots`; a newest/oldest toggle; rows showing time,
  host, tags, file count and size. Each row has a trailing `dots-vertical` button whose
  `onClick`/`onRightClick` opens `panel.openContextMenu({ items = …, onActivate = "onContextAction",
  context = <snapshot id>, maxVisible = 12 })` with items
  `restore_preview`, `restore`, `files`, `diff_prev`, `copy_id`, `forget_one`
  (define a global `function onContextAction(actionId, context)` in `panel.luau`).
  Restore is **two-step inside the panel**: clicking Restore previews first (`EVENT_RESTORE_DRY`),
  shows "would restore N files into <target>", and only then offers a confirm button that sends
  `EVENT_RESTORE`. Forget-one is likewise two-step, and always names the snapshot id.
- **Run.** Back up now / Check / Cancel; an **Initialise repository** button when
  `status.initNeeded`; a **Clear stale lock** button when the error mentions a lock; progress
  (percent, files, bytes) while running; last-run line that distinguishes ok / failed / cancelled;
  next run; a repository stats card (total size, file count, snapshot count) refreshed with
  `EVENT_STATS`; a staleness line when `status.stale`.
- **Retention.** Policy summary, preview via `EVENT_FORGET_DRY` showing keep/remove counts **and
  the bounded list of snapshot ids/times that would be removed**, then the existing two-step
  confirm.
- **Log.** Last job header (kind, when, ok/failed/cancelled, exit code) plus the tail lines from
  `KEY_JOBLOG` inside a `ui.scroll`; a truncated notice when `truncated`; a Refresh button sending
  `EVENT_LOGS`.
- **Widget.** Glyph/colour by state: not installed / not configured → `on_surface/0.5`;
  running → `primary` with the `loader-2` glyph; error → `error`; stale → `error` (or `tertiary`,
  your call — justify it in a comment); otherwise `on_surface`. Optional count
  (`show_count`) and staleness label (`show_staleness`). Tooltip rows: restic version, repository
  (**already redacted — do not redact again**), mode, snapshot count, newest snapshot age, last
  run (with cancelled/failed), next run, progress, error.
- **Shortcut.** Keep one-tap backup; `setEnabled(false)` when not available/configured, as today.

Every user-visible string goes through `noctalia.tr("<frozen key>")`. Keys are listed in
`translations/en.json`.

---

## 5. Out of scope for this round

Deliberately not in 0.2.0 — do not build these, and do not leave half-built scaffolding for them:

- Pre/post backup hooks, a `[[launcher_provider]]`, Prometheus textfile export, a restore
  verification job, multi-repository profiles, `restic mount`, rclone/S3 object browsing, a
  file-level diff viewer beyond `restic diff --json`, `thumbnail.webp` (the user produces visual
  assets himself).
