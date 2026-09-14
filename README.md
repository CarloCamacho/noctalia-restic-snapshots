<div align="center">

# 🗄 Restic Snapshots

**Your backups, visible — and honest about whether they ran.**

A [Noctalia v5](https://noctalia.dev) plugin: scheduled `restic` backups, a snapshot browser,
staging restore, and retention that always shows you what it would delete before it deletes it.

<br>

[![Noctalia](https://img.shields.io/badge/Noctalia-v5-8b5cf6?style=flat-square)](https://noctalia.dev)
[![plugin_api](https://img.shields.io/badge/plugin__api-30-22c55e?style=flat-square)](#)
[![restic](https://img.shields.io/badge/restic-0.19%2B-8b5cf6?style=flat-square)](https://restic.net)
[![license](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

</div>

---

## What it does

Restic Snapshots runs `restic` on a schedule you own and puts the result where you will actually
look at it: a bar glyph that turns red when a backup fails or the repository goes stale, a browser
for every snapshot, a two-step retention flow, and a restore that previews itself before it touches
the disk.

| | |
| --- | --- |
| **Bar module** | restic health at a glance: last run, next run, snapshot count, live progress |
| **Snapshot browser** | every snapshot with time, host, tags, file count and size — filter it, inspect it, restore one |
| **Run tab** | back up now, check integrity, initialise a new repository, clear a stale lock, cancel a job |
| **Retention tab** | edit the policy, **preview** exactly what would be removed (with ids), then confirm |
| **Log tab** | the last job's output with an ok / failed / cancelled verdict and its exit code |
| **Control-center tile** | one-tap "back up now" |
| **Scheduler** | plugin-owned interval persisted to disk — or observe-only if you already run your own timers |

## Plugin

| Field | Value |
| --- | --- |
| ID | `carlocamacho/restic-snapshots` |
| Service | `service` |
| Bar widget | `status` |
| Panel | `browser` |
| Control-center shortcut | `backup_now` |

## Requirements

- **Noctalia v5** at plugin API level **30** or newer (`plugin_api = 30` in `plugin.toml`).
- **`restic`** — the single manifest dependency, declared as `dependencies = ["restic"]` in
  `plugin.toml`.

Install it from your distribution (`pacman -S restic` on Arch/CachyOS, `apt install restic`,
`brew install restic`, …), or drop the official static release binary into `~/.local/bin`.

The plugin does **not** rely on the daemon's `PATH`, which is bare — it does not inherit your login
shell's profile, so `~/.local/bin` (where a hand-installed restic usually lives) is missing from it.
Instead the plugin resolves the binary through a **merged search path**: `~/.local/bin` and
`~/.local/sbin`, then a `PATH` probed from your login shell, then the daemon's own `PATH` — merged,
never replaced. The generated job script also sets `PATH` explicitly. If your binary lives somewhere
unusual, set the `restic_bin` setting to its absolute path.

`restic` 0.19 or newer is expected; the JSON output shapes this plugin parses were verified against
restic 0.19.1. There are no other dependencies.

## Install

### From a git source — not yet verified end-to-end

```bash
noctalia msg plugins source add carlocamacho git https://github.com/CarloCamacho/noctalia-restic-snapshots
noctalia msg plugins enable carlocamacho/restic-snapshots
```

> **This path is untested — do not assume it works.** Nothing here has been confirmed with a real
> install, and two earlier attempts to add this repository as a git source on the reference machine
> both failed to resolve it. One known blocker is the layout: Noctalia derives a plugin's directory
> from its id (the part after the `/`) and expects `restic-snapshots/plugin.toml` at the repository
> root, while this repository keeps the plugin under `plugin/restic-snapshots/`. The root
> `catalog.toml` added in 0.2.0 is what a git source reads to list plugins at all, and it removes
> one known blocker — but a git install is still unverified. If you want to *use* the plugin today,
> use one of the two routes below.

### From a local `path` source (recommended for development)

A `path` source scans its directory one level deep for `<name>/plugin.toml`, so point it at the
`plugin/` directory of a checkout:

```bash
noctalia msg plugins source add restic-dev path /path/to/noctalia-restic-snapshots/plugin
noctalia msg plugins enable carlocamacho/restic-snapshots
```

A `path` source is loaded in place — no clone, no export step. Edits to `.luau` files hot-reload;
manifest changes are picked up on the next config reload.

### Manual drop-in

Copy or symlink the plugin directory to `$XDG_DATA_HOME/noctalia/plugins/restic-snapshots/`
(`~/.local/share/noctalia/plugins/` by default) and enable it. The directory name must be exactly
`restic-snapshots`.

Then open **Settings → Plugins → Restic Snapshots** and set at least a **repository** and a
**password file**. Nothing runs before both are set.

## Usage

| Entry | How to reach it |
| --- | --- |
| **Bar widget** (`status`) | **Settings → Bar → add widget → Restic Snapshots**. Shows the current state, and optionally the snapshot count and the age of the newest snapshot. Left-click opens the panel; right-click opens settings. |
| **Panel** (`browser`) | left-click the bar widget, or run the command below. Four tabs: **Snapshots**, **Run**, **Retention**, **Log**. |
| **Control-center shortcut** (`backup_now`) | **Settings → Control center → Shortcuts**, add a shortcut, pick **Back up now**. One tap starts a backup; the tile disables itself while restic or the repository is not configured. |
| **Service** (`service`) | headless — it owns the schedule and the job lifecycle. Drive it over IPC (below); it has no UI of its own. |

```bash
noctalia msg panel-toggle carlocamacho/restic-snapshots:browser
```

Typical workflows:

- **Snapshots tab** — filter to *all snapshots* / *this host only* / *tagged &lt;tag&gt;*, type in the
  search box, flip newest/oldest. Each row's trailing `⋮` opens a context menu: *Preview restore*,
  *Restore*, *Files*, *Diff vs previous*, *Copy id*, *Forget this snapshot*. Restore and forget both
  preview first and ask for a second click; the id being acted on is always named.
- **Run tab** — *Back up now*, *Check repository*, and *Cancel* while a job is in flight. An
  *Initialise repository* button appears when the repository has never been created, and *Clear
  stale lock* when restic reports a lock. The repository stats card (total size, file count,
  snapshot count) and the last-run line (ok / failed / cancelled) live here too.
- **Retention tab** — *Preview removal* runs `forget --dry-run --json` and shows the keep/remove
  counts plus the ids and times of the snapshots that would go. *Prune now* only appears afterwards,
  and still asks for a second confirmation.
- **Log tab** — the last job's header (kind, when, verdict, exit code) and its output tail, with a
  truncation notice when older lines were dropped and a Refresh button.

## Settings

Plugin settings live in **Settings → Plugins → Restic Snapshots** (right-clicking the bar widget
gets you there too). Listed below in manifest order.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `repository` | `string` | *(empty)* | Restic repository: a local path (`/mnt/backup/restic`) or a backend URL (`sftp:host:/srv/restic`, `s3:…`, `b2:…`, `rclone:…`). Anything before an `@` and any token query parameter is redacted before the value is shown in the panel or the widget tooltip. Nothing runs until this and `password_file` are set. |
| `password_file` | `file` | *(empty)* | Path to a file holding the repository password. Passed to restic as `--password-file <path>`; the plugin stores the path only. |
| `env_file` | `file` | *(empty)* | Optional file sourced by the job script (`set -a; . <path>; set +a`) before restic runs, for backends that take credentials from the environment (`AWS_ACCESS_KEY_ID`, `B2_ACCOUNT_KEY`, `RCLONE_*`). Must be readable by your user at job time. |
| `backup_paths` | `string_list` | `[]` | Absolute paths to back up, each passed as a positional argument to `restic backup`. Nothing is backed up while this is empty. |
| `backup_tags` | `string_list` | `["noctalia"]` | Tags attached to every snapshot this plugin creates. Also what the panel's *tagged &lt;tag&gt;* filter matches. |
| `exclude_file` | `file` | *(empty)* | Optional restic exclude file passed as `--exclude-file`. |
| `mode` | `select` | `plugin` | `plugin` runs the plugin's own schedule; `observe` never starts a scheduled backup and only watches a repository something else writes to. Manual actions (back up now, check, restore, forget) work in both modes. |
| `interval_minutes` | `int` | `60` (5–1440) | How often a scheduled backup runs. Next-run time is computed from the last **successful** run and persisted, so a shell restart or a settings edit cannot push a backup forward forever. |
| `job_timeout_minutes` | `int` | `180` (5–2880) | Watchdog ceiling for a single job. A job still running after this long is treated as stuck: it is cancelled, recorded as failed with exit code 124 and the message "timed out", and the next scheduled run is allowed to fire. |
| `check_interval_hours` | `int` | `0` (0–720) | If non-zero, run `restic check` this often. Each scheduled check reads one rotating `--read-data-subset` slice, so a full pass is spread over many runs instead of one long one. `0` disables scheduled checks; the Run tab's Check button still works. |
| `stale_after_hours` | `int` | `0` (0–720) | Warn when the newest snapshot is older than this many hours. `0` derives the threshold from the backup interval (`max(2 × interval, 2 h)`). The warning fires once on the transition into stale and once on recovery. |
| `keep_last` | `int` | `7` (0–365) | `--keep-last` for the retention policy. At least one keep-* rule must be non-zero before a preview or prune is allowed. |
| `keep_daily` | `int` | `7` (0–365) | `--keep-daily` for the retention policy. |
| `keep_weekly` | `int` | `4` (0–104) | `--keep-weekly` for the retention policy. |
| `keep_monthly` | `int` | `6` (0–120) | `--keep-monthly` for the retention policy. |
| `restore_target` | `folder` | `~/restore` | Staging directory for restores. Snapshots are restored *beneath* it, under their original absolute path, so nothing is ever restored on top of a live file. Must be absolute (after `~` expansion), and may not be `/`, `$HOME`, or one of your backup sources. |
| `restore_allow_roots` | `string_list` | `[]` | Extra directories a restore may target. `restore_target` is always allowed; `/`, `$HOME` and any backed-up path are refused even when listed here. |
| `check_subset` | `string` | `1/100` | `--read-data-subset` value for manual checks, e.g. `1/100` or `5%`. Scheduled checks override it with their own rotating slice. |
| `restic_bin` | `string` | `restic` | Name or absolute path of the restic binary. A bare name is resolved through the merged search path described under **Requirements**. |

**Widget settings** are configured where the widget is added (**Settings → Bar**), not on the plugin
page:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_count` | `bool` | `false` | Show the snapshot count next to the glyph. |
| `show_staleness` | `bool` | `true` | Show how old the newest snapshot is (for example `4h`). |

## IPC

The service is a singleton with no output, so every event is addressed with the `all` target:

```bash
noctalia msg plugin carlocamacho/restic-snapshots:service all <event> [json]
```

| Event | Payload | Effect |
| --- | --- | --- |
| `refresh` | – | re-read `snapshots --json` and republish the snapshot list |
| `backup-now` | – | start a backup now (same as the shortcut and the Run tab button) |
| `check` | – | run `restic check --read-data-subset <check_subset>` |
| `forget-dry-run` | – | `forget --dry-run --json`; publishes the keep/remove counts **and** the ids that would be removed. Refused when no keep-* rule is set |
| `forget` | – | the real forget plus prune; refused when no keep-* rule is set, and only meaningful after a preview |
| `forget-one` | `{"snapshot":"<id>"}` | forget one snapshot by id; `--prune` is never passed |
| `restore-dry-run` | `{"snapshot":"<id>","target":"…?","include":"…?"}` | `restore --dry-run --json`; publishes how many files would land, and where. Validates the id and the target first |
| `restore` | `{"snapshot":"<id>","target":"…?","include":"…?"}` | the real restore, after the same validation |
| `cancel` | – | cancel the job in flight; the run is reported as *cancelled*, not *failed* |
| `stats` | – | `restic stats --json` → the repository summary card |
| `ls` | `{"snapshot":"<id>"}` | file listing for one snapshot |
| `diff` | `{"from":"<id>","to":"<id>"}` | `restic diff --json` between two snapshots |
| `init` | – | `restic init` the configured repository |
| `unlock` | – | `restic unlock --remove-all`, to clear a stale lock |
| `job-log` | `{"kind":"…"?}` | re-publish the last job's log tail into the panel |

Every payload is a single JSON object, passed as the last argument. `target` defaults to the
`restore_target` setting; `include` restricts the restore to one path inside the snapshot. Snapshot
ids are validated against the shape restic emits, and a restore target is validated before anything
runs — an invalid or disallowed payload is rejected with a notification and nothing is started.
Only one job runs at a time: while a job is in flight, new work is declined rather than queued.

Worked example — preview a restore into your staging target, look at the file count, then do it:

```bash
noctalia msg plugin carlocamacho/restic-snapshots:service all restore-dry-run '{"snapshot":"3f2a9c1e"}'
noctalia msg plugin carlocamacho/restic-snapshots:service all restore '{"snapshot":"3f2a9c1e","include":"/home/you/work"}'
```

## How it stays safe

- **The password is never a value.** It travels as `--password-file <path>`; the plugin stores only
  the path and never reads the file's contents.
- **argv only.** Every restic call is an argv vector — no shell string is ever built from settings.
  Generated job scripts contain only a validated argv and generated paths, and are mode `0600`.
- **Long jobs cannot be killed by a timeout.** `runAsync` clamps timeouts to 60 s, so backups run as
  **detached** jobs with their own exit-code and PID files. A job still running past
  `job_timeout_minutes` is caught by a watchdog, cancelled, recorded as a failure with exit code
  124, and the single-flight guard is released so the next scheduled run still fires.
- **The schedule survives a restart.** The next-run time is derived from the last **successful**
  run and persisted to the plugin data directory, so restarting the shell (or touching a setting)
  cannot silently skip or postpone a backup. A run that came due while the shell was down fires
  within about a minute of startup.
- **Retention is two-step.** *Preview removal* runs `forget --dry-run --json` and lists the
  keep/remove counts together with the ids and times of the snapshots that would go; the destructive
  button only appears afterwards and still asks for a second confirmation.
- **Restore cannot surprise you.** The target is validated first — absolute, not `/`, not `$HOME`,
  not a backup source, and either the configured restore target or under an allow-listed root. The
  panel's Restore button runs a `--dry-run` preview ("would restore N files into …") and only then
  offers the real restore. Snapshots are restored *beneath* the target under their original absolute
  path, so a restore never overwrites a live file.
- **A failed run is visible.** A non-zero exit raises `status.error`, so the bar module turns red and
  the Run tab says *failed*; a cancelled run is reported as *cancelled* and leaves the last-success
  time untouched.
- **Staleness is announced once.** When the newest snapshot passes the threshold the plugin notifies
  once — and once more on recovery, never on every tick.

## Verification

Phase 0 ran the real binary against a throwaway repository — see
[`docs/phase0-findings.md`](docs/phase0-findings.md).

| Assumption | Result |
| --- | --- |
| `--password-file` avoids the environment | ✅ argv-only execution possible |
| `backup --json` / `snapshots --json` shapes | ✅ captured and parsed from real output |
| `forget --dry-run --json` exposes keep/remove | ✅ drives the two-step confirmation |
| `restore --json` into a staging target | ✅ files byte-identical |
| `runAsync` timeout is 60 s | ⚠️ shaped the detached-job design |
| Daemon PATH contains restic | ❌ it does not — merged search path fixes it |

**Live end-to-end (0.1.0 pass)**, throwaway repository, driven through the plugin's own IPC:

| Step | Result |
| --- | --- |
| `backup-now` | ✅ new snapshot in 2 s, tags applied, job exit 0 |
| `check` | ✅ `num_errors = 0` |
| `forget-dry-run` | ✅ keep/remove preview, nothing removed |
| `restore` | ✅ files byte-identical under the staging target |

```bash
python3 -m unittest discover -s tests           # argv builders, quoting, schedule arithmetic
for f in tests/lua/*.lua; do lua5.4 "$f"; done  # real entries/renders + the detached job runner
luac -p plugin/restic-snapshots/*.luau plugin/restic-snapshots/lib/*.luau   # syntax
noctalia plugins lint plugin/restic-snapshots   # manifest + entries
```

All four are green on `release/0.2.0` (`0 errors, 0 warnings` from the lint).

## Notes

**Network calls: none.** The plugin makes no network calls at all — no HTTP client, no update check,
no telemetry. If `repository` points at a remote backend (`sftp:`, `s3:`, `b2:`, `rclone:`), it is
`restic` that opens those connections, using the credentials you configure in the repository URL or
in `env_file`.

**Processes spawned: two.** The resolved `restic` binary, and `/bin/sh` (which runs the generated
job script). Nothing else is executed, and no shell string is built from settings.

**Files written** — everything lives under the plugin data directory (`noctalia.pluginDataDir()`):

| Path | What it is |
| --- | --- |
| `jobs/<token>.sh` | the generated job script; mode `0600`, contains only the argv vector and generated paths |
| `jobs/<token>.jsonl` | the job's combined stdout + stderr — this is what the Log tab shows |
| `jobs/<token>.status` | the newest restic progress line, overwritten in place |
| `jobs/<token>.exit` | restic's exit code, written when it exits |
| `jobs/<token>.pid` | restic's own pid (so a cancel kills restic, not a pipeline member) |
| `jobs/<token>.fifo` | the named pipe the script reads restic's output from |
| `state.json` | the persisted schedule: last run, last success, next run, last check and its rotation index, last log path |

Stale job files are swept; nothing is written outside the data directory. No file of yours is ever
modified in place — a restore only ever *creates* files under the restore target.

**The password is only ever a path.** It is passed as `--password-file <path>`; the plugin never
reads the file, and never puts its contents into an environment variable, into argv, into a
generated script, or into shared state. `repository` is redacted (user info and token query
parameters stripped) before it is displayed in the panel or the widget tooltip.

**Debugging.** The last job's output is in the panel's **Log** tab, and on disk in
`jobs/<token>.jsonl`; its path is remembered in `state.json`, so the viewer still works after a
restart. Re-publish it over IPC with:

```bash
noctalia msg plugin carlocamacho/restic-snapshots:service all job-log
```

Read-only commands (`snapshots`, `stats`, `ls`, `diff`) carry `--no-lock`, and refreshes are skipped
while a job is in flight, so browsing never races a running backup.

## Layout

```
catalog.toml                     source index for this repository (what a git source reads)
plugin/restic-snapshots/
  plugin.toml                    manifest: ids, entries, settings, dependencies, plugin_api 30
  service.luau                   scheduler, job lifecycle, IPC, persistence
  widget.luau                    bar module
  panel.luau                     Snapshots / Run / Retention / Log
  shortcut.luau                  control-center tile
  lib/restic.luau                argv builders + JSON parsers (pure)
  lib/jobs.luau                  detached job runner + polling
  lib/schedule.luau              next-run, staleness and check arithmetic (pure)
  lib/store.luau                 persisted schedule / last-run state
  lib/state.luau                 state keys, event names, status shape
  lib/env.luau                   binary resolution (daemon PATH workaround)
  translations/en.json           user-visible strings
tests/                           Python and Lua suites
docs/phase0-findings.md          the live feasibility pass behind the design
```

## License

MIT — see [`LICENSE`](LICENSE).
