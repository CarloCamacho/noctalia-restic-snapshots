# Restic Snapshots 0.3.0 — frozen contracts & workstream map

Read this before writing code. It is the coordination artifact: frozen interfaces, file ownership,
ground rules, and the host behaviours that cost real debugging time in 0.2.0. If you need to change
something marked frozen, stop and report it instead of changing it — another workstream is coding
against it.

## 1. What 0.3.0 adds

0.2.0 shipped the trust fixes and is live and configured on the user's machine. 0.3.0 is the
feature release on top of it:

1. **Restore verification** — prove a backup can actually be restored: restore N files from the
   newest snapshot into a scratch directory and compare them against the live files, on a cadence
   or on demand. Publishes `status.verify`; the panel shows "Last verified".
2. **Pre/post-backup commands** — a staging command before the backup (a database dump, say) and a
   follow-up after it, both running *inside* the detached job so they inherit its timeout and
   cancellation. A failing pre-command aborts the backup.
3. **Launcher provider** — `/snap` in the Noctalia launcher: recent snapshots plus actions.
4. **Prometheus textfile export** — `restic_snapshots.prom` for node_exporter's textfile collector.
5. **Panel follow-ups** — render the check result and the verification result, show the
   diff's changed paths, and make the "this host only" filter exact.

## 2. Ground rules

**Environment.** The repository lives on the user's CachyOS box; you work there over SSH:

```bash
ssh <box> 'bash -lc "cd the worktrees/.wt-<yours> && COMMAND"'
```

- The remote login shell is **fish**, so always wrap remote commands in `bash -lc "..."`. For
  anything multi-line, compose the file locally and `scp` it to the box, then run it.
- Your worktree is already created on your branch. **Work only there.** Never edit
  `the plugin checkout` (the main checkout): the user's *running* shell loads that
  path and hot-reloads it. Never run `noctalia msg plugins enable/disable/source`.
- Commit in your worktree. Never merge, rebase or push.
- Gate — must be green when you finish, including your new tests:
  `bash /tmp/restic-gate.sh the worktrees/.wt-<yours>`

**Language.** Files are Luau but the suite runs them under **Lua 5.4**: `luac -p` must pass on
everything you touch. No `continue`, no type annotations, no string interpolation, no compound
assignment. `--!nonstrict`, locals declared before use, no new globals (except entry-point
callbacks, which the host calls).

**Security invariants — do not weaken.**
- Every restic invocation is an argv vector; no shell string is built from settings.
- The password is only ever passed as `--password-file <path>`; never read its contents.
- IPC payloads are untrusted: validate ids with `restic.validSnapshotId` and targets with
  `restic.validRestoreTarget` before use.
- No new network calls and no new downloads.
- Generated scripts stay `0600` and credential-free (paths only).

### Host behaviours that bit us in 0.2.0 (do not rediscover these)

1. **Callbacks run under a per-callback CPU budget.** A `while` loop calling `text:sub(i, i)` once
   per character blew it on a ~97 KB log and **killed the whole service `update()` tick** with
   `script callback 'update' exceeded its CPU budget`. Work inside `update()` / `poll` / a job
   finish must scale with lines or records, never with bytes walked one at a time. Plain-Lua tests
   cannot see this budget; `tests/test_source_invariants.py` guards the pattern.
2. **Glyph names must exist in the host's icon set** (Tabler, `assets/fonts/tabler.json` in a
   noctalia checkout). A bad name renders as nothing and logs `[WRN] [glyph] missing glyph: X`.
   Audit before you finish: `python3 /tmp/glyph_audit.py plugin/restic-snapshots`.
3. **The shell does not log to journalctl.** Its stdout is `/dev/null`; plugin `noctalia.log` lines
   and host warnings go to `~/.cache/noctalia/noctalia.log`. Grep that file, not the journal.

**Reports.** Final message: (1) files changed with why; (2) exact commands run + results;
(3) anything left out or blocked (a reported gap beats a hidden one); (4) your commit hash.

## 3. Live system you may test against

The plugin is **configured and working** on the box: repository `<repository>`, password file
`<password file>` (a path — never read it), backup path `<backup path>`,
restore target `<restore target>`, tags `noctalia`, mode `plugin`, interval 60 min.

Allowed: read-only restic commands with `--no-lock`; the service's safe IPC events
(`refresh`, `backup-now`, `check`, `stats`, `ls`, `diff`, `forget-dry-run`, `restore-dry-run`,
`restore`, `job-log`, `verify-restore` once it exists); writes **inside** `<restore target>`.
Forbidden: `forget` without `--dry-run`, any `prune`, `unlock`, writing anywhere else on the box,
and `noctalia msg plugins ...` management commands. Run IPC with:

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u); export WAYLAND_DISPLAY=wayland-1
noctalia msg plugin carlocamacho/restic-snapshots:service all <event> '{"json":"payload"}'
```

Expect the service to be running the user's hourly schedule: if a job is in flight your event is
refused with "a job is already running" — that is correct behaviour, not a bug.

## 4. Workstreams and file ownership

| WS | Branch | Worktree | Owns (only these files) |
|---|---|---|---|
| V | `feat/verify` | `the worktrees/.wt-v` | `service.luau`, `lib/restic.luau`, `lib/schedule.luau`, `tests/lua/verify_test.lua` (new), `tests/test_restic.py` |
| H | `feat/hooks` | `the worktrees/.wt-h` | `lib/jobs.luau`, `tests/lua/jobs_hooks_test.lua` (new), `tests/test_jobs_script.py` |
| L | `feat/launcher` | `the worktrees/.wt-l` | `launcher.luau` (new), `tests/lua/launcher_test.lua` (new) |
| P | `feat/panel-extras` | `the worktrees/.wt-p` | `panel.luau`, `widget.luau`, `tests/lua/panel_render_test.lua`, `tests/lua/widget_render_test.lua` |
| M | `feat/metrics` | `the worktrees/.wt-m` | `lib/metrics.luau` (new), `tests/lua/metrics_test.lua` (new), `tests/test_metrics.py` (new) |
| D | `docs/030` | `the worktrees/.wt-docs` | `README.md`, `CHANGELOG.md` |

`plugin.toml`, `translations/en.json` and `lib/state.luau` are **already prepared** by the lead —
do not edit them except where a line below explicitly assigns you one.

**Wave 1**: V, H, L (independent). **Wave 2**: P, M, D — P needs V's `status.verify`, M reads the
persisted state and V's payload, D documents what shipped. Wave 2 worktrees are created after wave
1 merges.

## 5. Frozen interfaces

### 5.1 Settings already in `plugin.toml` (labels already in `en.json`)

| key | type | default | meaning |
|---|---|---|---|
| `pre_backup_command` | string | `""` | shell command run before restic, inside the job |
| `post_backup_command` | string | `""` | shell command run after a successful backup |
| `verify_interval_hours` | int | `0` | restore-verification cadence; 0 = off |
| `verify_file_count` | int | `3` | files restored and compared per verification |
| `metrics_dir` | folder | `""` | Prometheus textfile directory; empty = off |

### 5.2 State

New event (already in `lib/state.luau`): `EVENT_VERIFY = "verify-restore"` with payload
`{ target?: string }` (a scratch directory; validated with `restic.validRestoreTarget`).

`status.verify` (additive field already in `state.emptyStatus()`), published by WS-V:

```lua
{ lastAt = <epoch>, lastOk = <bool>, checked = <n>, matched = <n>, failed = <n>, detail = <string> }
```

`status.checks` (already published) stays `{ lastAt, lastOk, numErrors }`.

### 5.3 `lib/jobs.luau` — hooks (WS-H)

`M.start(argv, opts)` gains two optional strings:

```lua
opts.preCommand   -- run before restic, in the job script, via /bin/sh -c
opts.postCommand  -- run after restic, in the job script, via /bin/sh -c, with RESTIC_EXIT set
```

Frozen script behaviour:

- The commands are written into the script as single-quoted assignments (`PRECOMMAND='…'`) and
  invoked as `/bin/sh -c "$PRECOMMAND"`, never inlined into a command line.
- Their stdout/stderr are appended to the job log (`.jsonl`) with a `== pre-backup command ==` /
  `== post-backup command ==` marker line, so the Log tab shows them.
- **A non-zero pre-command aborts the job before restic runs**: the script removes the fifo, writes
  that exit code to `.exit`, and exits with it. Job logs must not contain the password file's
  *contents* (they never did; keep it that way).
- The post-command runs after restic finishes regardless of restic's exit code, receives
  `RESTIC_EXIT`, and its own failure must **not** change the recorded exit code (the backup result
  is restic's).
- With neither option set, the generated script must be byte-identical to today's.

### 5.4 Prometheus textfile export (WS-M)

Write `<metrics_dir>/restic_snapshots.prom` **atomically** (`noctalia.writeFile` to
`…prom.tmp`, then `noctalia.renameFile`). Content, one metric per line, `# HELP`/`# TYPE` included:

```
restic_snapshots_last_success_timestamp_seconds
restic_snapshots_count
restic_snapshots_newest_age_seconds
restic_snapshots_stale                     0|1
restic_snapshots_repo_bytes
restic_snapshots_repo_files
restic_snapshots_last_job_exit_code{kind="backup|check|restore|forget|ls|diff|verify"} <n>
restic_snapshots_last_check_errors
restic_snapshots_last_verify_ok             0|1
```

Source of truth is the **persisted store** plus the published state, so the file survives a
restart. Rewrite on transitions only (job finish, snapshot refresh, verification, check), never on
every tick. Unset/empty `metrics_dir` ⇒ no writes at all, and a write failure must be logged once
and never break the service.

### 5.5 Launcher provider (WS-L)

Manifest entry (the lead adds it to `plugin.toml`; these are the real keys the host parses for a
launcher provider entry — verified in `src/scripting/plugin_manifest.cpp`):

```toml
[[launcher_provider]]
id     = "snapshots"
entry  = "launcher.luau"
prefix = "/snap"
glyph  = "archive"

  [[launcher_provider.category]]
  label = "Snapshots"
  glyph = "archive"
```

Frozen behaviour: `onQuery(text)` publishes results from `KEY_SNAPSHOTS` (most recent first, host,
tag, file count, size) plus three fixed actions — "Back up now", "Check repository", "Open Restic
Snapshots" — which send the service events / `noctalia.togglePanel`. Results carry the declared
category label so the launcher's filter bar works. No network, no new processes beyond the
`noctalia msg` IPC the other entries already use. Use the frozen `launcher.*` keys for text.

### 5.6 Panel follow-ups (WS-P)

- Render `status.checks` on the Run tab (last check time + error count) and `status.verify`
  ("Last verified …", ok/failed with counts) with a "Verify restore" button sending
  `EVENT_VERIFY`.
- Render the diff's changed paths from `KEY_DIFF` (bounded; `parseDiff` already returns
  `addedPaths`/`removedPaths`/`changedPaths` with a `truncated` flag).
- "This host only" must use the real local hostname: read `/etc/hostname` (trimmed) via
  `noctalia.readFile`, falling back to today's inference if unreadable.

## 6. Out of scope for 0.3.0

Multi-repository profiles, `restic mount`, rclone/S3 object browsers, a file-level diff *viewer*
beyond listing the paths, retention-policy scheduling changes, and `thumbnail.webp` (the user
produces visual assets himself).
