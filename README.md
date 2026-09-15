<div align="center">

# 🗄 Restic Snapshots

**Your backups, visible — and honest about whether they ran, and whether they restore.**

A [Noctalia v5](https://noctalia.dev) plugin: scheduled `restic` backups, a snapshot browser,
staging restore, restore verification, and retention that always shows you what it would delete
before it deletes it.

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
for every snapshot, a two-step retention flow, a restore that previews itself before it touches the
disk, and — new in 0.3.0 — a periodic check that files from the newest snapshot really do restore
and really do match the files on disk.

| | |
| --- | --- |
| **Bar module** | restic health at a glance: last run, next run, snapshot count, live progress |
| **Snapshot browser** | every snapshot with time, host, tags, file count and size — filter it, inspect it, restore one |
| **Restore verification** | restores a sample of files from the newest snapshot and compares them byte-for-byte with the live files, on a cadence or on demand |
| **Run tab** | back up now, check integrity, verify a restore, initialise a new repository, clear a stale lock, cancel a job |
| **Retention tab** | edit the policy, **preview** exactly what would be removed (with ids), then confirm |
| **Log tab** | the last job's output with an ok / failed / cancelled verdict and its exit code |
| **Launcher provider** | `/snap` in the Noctalia launcher: the newest snapshots, plus back up now / check / open |
| **Hooks** | an optional command before the backup (a database dump, say) and one after it |
| **Prometheus export** | `restic_snapshots.prom` for a node_exporter textfile collector |
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
| Launcher provider | `snapshots` — prefix **`/snap`** |

## Requirements

- **Noctalia v5** at plugin API level **30** or newer (`plugin_api = 30` in `plugin.toml`).
- **`restic`** — the single manifest dependency, declared as `dependencies = ["restic"]` in
  `plugin.toml`.
- For the metrics export, something that reads a Prometheus textfile directory — normally
  `node_exporter` with its `textfile` collector enabled. Nothing else is required, and the plugin
  works fine without it (see [Prometheus textfile export](#prometheus-textfile-export)).

Install restic from your distribution (`pacman -S restic` on Arch/CachyOS, `apt install restic`,
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

## Configure

Open **Settings → Plugins → Restic Snapshots** and set at least a **repository**, a **password
file** and one backup path. Nothing runs before those are set. A working starting point:

| Setting | Example value |
| --- | --- |
| `repository` | `/srv/restic-repo` (a local path) or `sftp:host:/srv/restic` |
| `password_file` | `/etc/restic/passwd` |
| `backup_paths` | `/home/you/dotfiles` |
| `backup_tags` | `["noctalia"]` (the default) |
| `interval_minutes` | `60` (the default) |
| `restore_target` | `/mnt/restore` |

**The password file holds the repository password in plain text, and the plugin never reads it,
checks it or changes its mode.** That is on purpose — it is also the one thing about this plugin you
have to get right yourself: `chmod 600` the file. A password file at mode `644` (which is what the
reference machine's `/etc/restic/passwd` was when this was written) is a plain-text secret
readable by every account on the box, and the repository is only as private as that file. The
plugin's only use of it is `--password-file <path>`, so nothing else about the setup changes when
you tighten the mode. If the repository is remote, prefer an `env_file` with a scoped credential
over credentials embedded in the repository URL.

Point the **restore target** at a directory you own that is *not* inside a backup source; restores
and restore verification write there, never over a live file.

## Usage

| Entry | How to reach it |
| --- | --- |
| **Bar widget** (`status`) | **Settings → Bar → add widget → Restic Snapshots**. Shows the current state, and optionally the snapshot count and the age of the newest snapshot. Left-click opens the panel; right-click opens settings. |
| **Panel** (`browser`) | left-click the bar widget, or run the command below. Four tabs: **Snapshots**, **Run**, **Retention**, **Log**. |
| **Control-center shortcut** (`backup_now`) | **Settings → Control center → Shortcuts**, add a shortcut, pick **Back up now**. One tap starts a backup; the tile disables itself while restic or the repository is not configured. |
| **Launcher** (`/snap`) | open the launcher and type **`/snap`** — the newest snapshots plus three actions. See [Launcher provider](#launcher-provider--snap). |
| **Service** (`service`) | headless — it owns the schedule and the job lifecycle. Drive it over IPC (below); it has no UI of its own. |

```bash
noctalia msg panel-toggle carlocamacho/restic-snapshots:browser
```

Typical workflows:

- **Snapshots tab** — filter to *all snapshots* / *this host only* / *tagged &lt;tag&gt;*, type in the
  search box, flip newest/oldest. Each row's trailing `⋮` opens a context menu: *Preview restore*,
  *Restore*, *Files*, *Diff vs previous*, *Copy id*, *Forget this snapshot*.
  The trailing **⋯ button** on each row opens the same actions as an in-panel sheet on a left click
  — *Details*, *Files*, *Diff with previous*, *Restore*, *Copy id*, *Forget this snapshot* —
  while a **right click** opens the shell's native menu. *Details* shows the snapshot's id (short
  and full), when it was captured (absolute and relative), host, tags, paths, files processed, bytes
  processed and data added, with buttons to open its file listing or copy the id.
  Restore and forget both preview first and ask for a second click; the id being acted on is always
  named, and **forget never happens from a single click**.
- **Run tab** — *Back up now*, *Check repository*, *Verify restore*, and *Cancel* while a job is in
  flight. An *Initialise repository* button appears when the repository has never been created, and
  *Clear stale lock* when restic reports a lock. The repository stats card (total size, file count,
  snapshot count), the last-run line (ok / failed / cancelled) and the last check and last
  verification lines live here too.
- **Retention tab** — *Preview removal* runs `forget --dry-run --json` and shows the keep/remove
  counts plus the ids and times of the snapshots that would go. *Prune now* only appears afterwards,
  and still asks for a second confirmation.
- **Log tab** — the last job's header (kind, when, verdict, exit code; a job still running reads
  *running* rather than failed) and its output, rendered **Formatted** for a human: progress is
  folded into one line (`84.25% · 1006/4000 files · 63.6 MiB`), a backup's summary becomes a
  sentence (`0 new · 0 changed · 173 unchanged · 840.2 KiB processed · 0 B added · 1.2s`), a listing
  or diff stream is counted instead of printed (`40 records (ls)`), and the folded count is shown.
  **Raw** switches to the untouched restic output, and a Refresh button re-reads it. Pre- and
  post-backup command output appears here verbatim, behind `== pre-backup command ==` /
  `== post-backup command ==`, as does any error — errors are never folded away, however long the
  log is.

### Reading the Snapshots tab

The tab opens with the repository's shape rather than a wall of rows:

- **A history strip** — one bar per snapshot, oldest to newest, as tall as the bytes that snapshot
  actually added, and accented when it added anything at all. Because restic walks the whole backup
  set every run and stores only what changed, a long flat strip with the occasional spike *is* the
  healthy picture: the backups are running and your files are not changing.
- **A headline** — *933 KiB stored, from 18.9 MiB scanned across 23 snapshots*. The gap between
  those two numbers is what deduplication is doing for you.
- **Date headings**, one per calendar day. Each row leads with recency (*21m ago · 22:15:06*) and
  calls out the bytes it added, if any; the absolute date lives in the heading.

The Run tab fills a bar across the interval to the next backup, and the bar widget carries the same
history as a sparkline beside its glyph.

### Reading the Log tab

The Log tab shows the **last job's own log**, read from disk when you open the tab. Backups run restic
with `--verbose`, so the log records what the run did to each file — and the job script discards the
`unchanged` records as it writes, which is what keeps a quiet hour short:

```
scanned 173 files
0 new · 0 changed · 173 unchanged · 840.2 KiB processed · 0 B added · 1.2s
```

A run that changed something names the files it changed, which is the only place in the plugin that
does:

```
scanned 2 files
modified · /home/ian/cachyos-dotfiles/.config/niri/config.kdl
0 new · 1 changed · 1 unchanged · 1.8 KiB added · 0.8s
```

*Formatted* is the default view; *Raw* shows restic's own JSON lines untouched. The tab reads at most
the last 16 KB and renders at most 200 rows, and says so when it has done either.

### Where the panel opens

The panel is a normal plugin panel, so the shell places it: **Settings → Plugins → Restic Snapshots
→ Panel placement** chooses *floating* (the default — a centred window) or *attached* (docked to the
bar the panel was opened from), and **Panel position** picks the corner or edge for a floating
panel. Both are read when the panel opens, so a change takes effect the next time you open it.

## Restore verification

**What it is for.** `restic check` tells you the repository's data is internally consistent. It does
not tell you that the archive can be restored onto this machine and still matches what you think you
backed up. Restore verification answers that second question, on a cadence you choose.

**How it works.** When a verification runs, the service:

1. lists the snapshots fresh and takes the **newest** one (not whichever snapshot the panel happens
   to be filtered to, so the UI can never say "verified the newest" while something else was
   checked);
2. lists that snapshot (`restic ls --json`, bounded to 2,000 entries) and picks up to
   `verify_file_count` **regular files** of at most 4 MiB each — preferring files that have content
   so that two empty files are not what gets compared, though a snapshot of nothing but empty files
   still verifies rather than reporting "nothing to check". The picks are spread evenly through the
   listing, so repeat verifications of a growing snapshot do not all land on the same few paths;
3. restores exactly those files with `restic restore` (no `--dry-run`) into
   `<restore_target>/.verify/<epoch>/`, one epoch-stamped scratch directory per run, so two
   verifications can never collide;
4. reads each restored file back and compares it **byte-for-byte** with the live file at its
   original path;
5. publishes the result and deletes the restored files again.

**What it proves, and what it does not.** It proves that *this* sample of *this* snapshot restored
successfully and still matches the live files — that the repository, the credentials, the restore
path and the snapshot's own data all still work end to end. It is emphatically **not** a full archive
check: it reads a handful of files, from the newest snapshot only, and only files that are still
present on disk. A repository-wide verification of every byte is `restic check --read-data` (which
is what the Run tab's *Check repository* button and `check_interval_hours` do, one rotating slice at
a time). Use both: `check --read-data` for the repository, this for the promise that a file you
saved is a file you can get back.

**The three outcomes per file**, and why each is the honest label:

| Outcome | When | Counts as |
| --- | --- | --- |
| **matched** | the restore produced the file and the live file holds exactly those bytes | proven |
| **failed** | the restore produced no readable copy at all, **or** the live file exists and differs and could not legitimately have changed since the snapshot | a backup problem |
| **skipped** | the live file is gone, was modified after the snapshot was taken, is larger than 4 MiB, or could not be read | nothing proven about that file |

The important one is **skipped**: a file you edited after the last backup, or deleted since, is
*expected* to differ, and calling that a failure would train you to ignore this feature. It is not a
pass either — it proves nothing. The published result has no separate `skipped` counter;
`skipped = checked − matched − failed`. A run in which *every* sampled file was skipped is recorded
as **not failed** (nothing disagreed with the backup) with a detail that says none of them could be
compared — so if you alert on this feature, look at `matched` as well as `lastOk`.

A verification that could not run at all — no snapshot in the repository, no usable file in the
snapshot, an `ls` that failed — is published as a **failure with the reason**, never as a pass.
`lastOk` is never true for a run that compared nothing. You get one notification per transition into
failure and none for success.

**Settings:** `verify_interval_hours` (`int`, default `0` — off) and `verify_file_count` (`int`,
default `3`, range 1–25). Every attempt stamps the verification time, so a failure is retried on the
interval rather than on every tick; a verification refused because another job holds the
single-flight guard is not published at all, only re-armed.

**Worked example.** Verify daily, three files per run:

```toml
verify_interval_hours = 24
verify_file_count = 3
```

That is the whole configuration. The Run tab then shows a *Last verified* line reading, for example,
`3 of 3 files matched`, and on a failing run the reason — `1 of 3 checked files do not match the
backup: /home/you/dotfiles/…: the backup does not match the live file`.

Run one now, without waiting for the cadence:

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u); export WAYLAND_DISPLAY=wayland-1
noctalia msg plugin carlocamacho/restic-snapshots:service all verify-restore
# a scratch directory somewhere else inside an allowed restore root:
noctalia msg plugin carlocamacho/restic-snapshots:service all verify-restore '{"target":"/mnt/restore"}'
```

The result lands in the published status as `verify` (`lastAt`, `lastOk`, `checked`, `matched`,
`failed`, `detail`), which is what the panel, the widget and the metrics export read. With the
settings above and a restore target of `/mnt/restore`, a run at epoch `1789397000` restores
into `/mnt/restore/.verify/1789397000/home/you/dotfiles/…`, compares the files, and
then removes those restored files, leaving the empty `.verify/1789397000/…` directory tree behind
(deliberately — see [Limitations](#limitations--things-that-are-deliberately-not-done)).

## Pre- and post-backup commands

**What they are for.** A backup of files is often not enough: a database has to be dumped to a file
first, a staged export has to be tidied afterwards, and something should tell you when the run
finished and how it went. `pre_backup_command` and `post_backup_command` are that staging and
follow-up step — run *inside* the job, rather than as a side process the plugin cannot see, so they
inherit the job's timeout, its cancellation and its log.

> **These settings are arbitrary code.** Both values are executed by `/bin/sh -c` **with your user's
> privileges**: they can read, write, delete and run anything you can. The plugin does not parse,
> sandbox, validate or restrict them, and it does not know what they do. Only your own plugin
> settings file can set them — but a settings file you did not write, or a copied configuration, is
> therefore a way to run code as your user. Treat these two fields exactly like a shell script you
> keep in your home directory. Everything else in this plugin is an argv vector built from
> validated values; these two are the deliberate exception, which is why they are *advanced*
> settings and empty by default.

| Setting | Type | Default | What it is |
| --- | --- | --- | --- |
| `pre_backup_command` | `string` | *(empty)* | Runs before restic starts. Non-zero exit aborts the job before restic runs. |
| `post_backup_command` | `string` | *(empty)* | Runs after restic finishes, regardless of how restic finished. |

Both are empty by default, and with both empty the generated job script is byte-identical to
0.2.0's — no hook code is emitted at all.

**Pre-backup command.** Runs inside the job after the job's log and fifo exist and before restic is
started. A **non-zero exit aborts the backup**: restic never runs, that exit code is written to the
job's `.exit` file and becomes the job's recorded result (reported as failed, with the code), the
fifo is removed, and the log gets the line `the pre-backup command failed; restic was not started`. A
staging step that fails therefore cannot leave you with a snapshot that silently omits the data it
was supposed to dump.

**Post-backup command.** Runs after restic finishes, **whatever restic's exit code was** — it is not
a success-only hook. It receives that code in the `RESTIC_EXIT` environment variable and runs
*before* the job's `.exit` file is written, so a job only counts as finished once its follow-up is
done, and the exit code finally recorded is **restic's**, not the follow-up's. A failing post-command
is logged (and shows in the Log tab) but never turns a good backup into a failed one, or the other
way round.

**Both appear in the job log.** Their stdout and stderr are appended to the job log behind a marker
line, `== pre-backup command ==` or `== post-backup command ==`, which is what the Log tab renders.
The commands themselves travel into the generated script as a single-quoted assignment and are
invoked as `/bin/sh -c "$PRECOMMAND"` — the value never becomes part of a command line, so quotes,
`$(…)`, backticks or newlines in it cannot escape into the surrounding script.

**Worked example** — dump a SQLite database into a staging directory the backup includes, and log
the outcome of the run:

```toml
pre_backup_command  = 'mkdir -p /home/you/staging && sqlite3 /home/you/.local/share/app/app.db ".backup /home/you/staging/app.db"'
post_backup_command = 'logger -t restic-snapshots "backup finished with RESTIC_EXIT=$RESTIC_EXIT"'
```

`backup_paths` then needs to include `/home/you/staging` alongside your normal paths, so the fresh
dump is in the snapshot. After a run, the Log tab (and `jobs/<token>.jsonl`) shows:

```
== pre-backup command ==
== post-backup command ==
```

with whatever the two commands printed underneath each marker. A post-command that only wants to run
on failure is a normal shell test, since it has the exit code:

```toml
post_backup_command = '[ "$RESTIC_EXIT" -eq 0 ] || notify-send "Backup failed" "see the Restic Snapshots log"'
```

## Launcher provider — `/snap`

Type `/snap` in the Noctalia launcher. Results are published from the plugin's current snapshot list,
newest first, plus three fixed actions.

| Example query | What you get |
| --- | --- |
| `/snap` | the eight newest snapshots, then **Back up now**, **Check repository**, **Open Restic Snapshots** |
| `/snap cachyos` | snapshots whose host (or tag, short id or time) matches — substring first, the host's fuzzy matcher as a fallback, so a shortened or slightly mistyped host still finds its rows |
| `/snap 3f2a9c1e` | the snapshot with that short id (a pasted id matches exactly, and floats to the top of the list) |
| `/snap check` | the action rows only, for when you want the action and not a snapshot |

**Each snapshot row** is titled with the short id and the snapshot's local time (`3f2a9c1e · 04:12`)
and subtitled with the host, file count and size (`cachyos · 412 files · 1.2 GiB`). **Activating a
row** asks the service for that snapshot's file listing (`ls`) and opens the Restic Snapshots panel,
so you land on the snapshot's files rather than on an empty browser; the listing appears in the
panel's files section as soon as the service's listing job finishes, a moment later. The id is
validated by the service before restic ever sees it, exactly like the panel's own *Files* action —
the launcher sends the same event with the same payload.

**The three action rows** (filtered by the same matching rule, against their labels):

| Row | What it does |
| --- | --- |
| **Back up now** | sends the service's `backup-now` event — the same thing the Run tab button and the control-center tile do |
| **Check repository** | sends the `check` event, which runs `restic check --read-data-subset <check_subset>` |
| **Open Restic Snapshots** | opens the panel |

Snapshots are only listed once the service has published a snapshot list (open the panel once, or
wait for the first refresh, after a restart). A query that matches nothing publishes an empty list —
the launcher draws its own "no results" placeholder, and backspacing brings the actions back. The
provider makes no network call and runs no process other than the same `noctalia msg plugin` IPC the
panel already uses.

## Prometheus textfile export

**What it is for.** The plugin knows things a monitoring stack cannot find out any other way: when
the last backup *really* succeeded, how old the newest snapshot is, whether the last integrity check
found errors, whether the last restore verification matched. With `metrics_dir` set, it writes them
as one exposition-format file that a Prometheus textfile collector picks up.

**Setting:** `metrics_dir` (`folder`, default empty = off). The file is
`<metrics_dir>/restic_snapshots.prom`, and the directory is created if it does not exist.

```toml
metrics_dir = "/var/lib/node_exporter/textfile"
```

**The file is rewritten when the state changes** — a job finishing, a snapshot refresh, a check, a
verification — not on every tick, so it is not a source of disk churn. The write is atomic: the
content is written to `restic_snapshots.prom.tmp` and then renamed over the real file, so a collector
reading the directory can never see a half-written file. If the write fails (a directory it cannot
create, no permission, a filesystem that went away), the failure is logged once and the service
carries on — a broken metrics export never breaks a backup. With `metrics_dir` empty there are no
writes at all.

**The metrics**, one per line with `# HELP` / `# TYPE` (all gauges):

| Metric | Meaning |
| --- | --- |
| `restic_snapshots_last_success_timestamp_seconds` | Unix time of the last successful backup |
| `restic_snapshots_count` | snapshots in the repository |
| `restic_snapshots_newest_age_seconds` | age of the newest snapshot, in seconds (never negative, even if a clock is skewed) |
| `restic_snapshots_stale` | `1` when the newest snapshot is older than `stale_after_hours` |
| `restic_snapshots_repo_bytes` | bytes stored in the repository, as reported by `restic stats` |
| `restic_snapshots_repo_files` | files in the repository, as reported by `restic stats` |
| `restic_snapshots_last_job_exit_code{kind="backup"}` | exit code of the last finished job, labelled with its kind (`backup`, `check`, `restore`, `forget`, `ls`, `diff`, `verify`, …) |
| `restic_snapshots_last_check_errors` | errors reported by the last repository integrity check |
| `restic_snapshots_last_verify_ok` | `1` when the last restore verification matched every comparable file |
| `restic_snapshots_last_verify_matched` | files that matched the live copy in the last verification |
| `restic_snapshots_last_verify_failed` | files that disagreed with the live copy in the last verification |
| `restic_snapshots_export_timestamp_seconds` | Unix time this export was written |

**A value the plugin does not know is omitted, never emitted as `0`.** "No backup has ever been
recorded" and "a backup succeeded at the Unix epoch" are different statements, and a graph that
cannot tell them apart is worse than no graph. The one line always present when the file is written
at all is `restic_snapshots_export_timestamp_seconds` — that is how a scraper tells a fresh export
from a stale one, whatever the other values say.

**Something has to collect the file.** The plugin writes it; it does not push it anywhere, and it
makes no network call. The usual collector is `node_exporter`'s textfile collector:

```sh
# in the node_exporter service arguments
--collector.textfile.directory=/var/lib/node_exporter/textfile
```

That directory must be the same one as `metrics_dir`, and node_exporter must be able to read it
(`chmod 755` the directory; the plugin writes the file as your user). Two useful expressions once it
is scraped:

```promql
# the newest snapshot is older than the staleness threshold
restic_snapshots_stale == 1
# the export itself has gone stale (the plugin stopped running)
time() - restic_snapshots_export_timestamp_seconds > 3600
```

**Nothing on the machine this was written on collects it yet:** the settings are not set there
because no `node_exporter` is installed, so the export is configured, implemented and tested but
unused in that setup. Setting `metrics_dir` on a box without a collector is harmless — it just leaves
one small file behind.

## Settings

Plugin settings live in **Settings → Plugins → Restic Snapshots** (right-clicking the bar widget
gets you there too). Listed below in manifest order; the entries marked *advanced* are behind the
settings page's advanced toggle.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `repository` | `string` | *(empty)* | Restic repository: a local path (`/mnt/backup/restic`) or a backend URL (`sftp:host:/srv/restic`, `s3:…`, `b2:…`, `rclone:…`). Anything before an `@` and any token query parameter is redacted before the value is shown in the panel or the widget tooltip. Nothing runs until this and `password_file` are set. |
| `password_file` | `file` | *(empty)* | Path to a file holding the repository password. Passed to restic as `--password-file <path>`; the plugin stores the path only and never reads the file. `chmod 600` it yourself. |
| `env_file` | `file` | *(empty)* | Optional file sourced by the job script (`set -a; . <path>; set +a`) before restic runs, for backends that take credentials from the environment (`AWS_ACCESS_KEY_ID`, `B2_ACCOUNT_KEY`, `RCLONE_*`). Must be readable by your user at job time. |
| `backup_paths` | `string_list` | `[]` | Absolute paths to back up, each passed as a positional argument to `restic backup`. Nothing is backed up while this is empty. |
| `backup_tags` | `string_list` | `["noctalia"]` | Tags attached to every snapshot this plugin creates. Also what the panel's *tagged &lt;tag&gt;* filter matches. |
| `exclude_file` | `file` | *(empty)* | Optional restic exclude file passed as `--exclude-file`. |
| `mode` | `select` | `plugin` | `plugin` runs the plugin's own schedule; `observe` never starts a scheduled backup and only watches a repository something else writes to. Manual actions (back up now, check, restore, verify, forget) work in both modes. |
| `interval_minutes` | `int` | `60` (5–1440) | How often a scheduled backup runs. Next-run time is computed from the last **successful** run and persisted, so a shell restart or a settings edit cannot push a backup forward forever. |
| `job_timeout_minutes` | `int` | `180` (5–2880) | Watchdog ceiling for a single job. A job still running after this long is treated as stuck: it is cancelled, recorded as failed with exit code 124 and the message "timed out", and the next scheduled run is allowed to fire. Also covers the pre/post commands, which run inside the job. |
| `check_interval_hours` | `int` | `0` (0–720) | If non-zero, run `restic check` this often. Each scheduled check reads one rotating `--read-data-subset` slice, so a full pass is spread over many runs instead of one long one. `0` disables scheduled checks; the Run tab's Check button still works. |
| `stale_after_hours` | `int` | `0` (0–720) | Warn when the newest snapshot is older than this many hours. `0` derives the threshold from the backup interval (`max(2 × interval, 2 h)`). The warning fires once on the transition into stale and once on recovery. |
| `keep_last` | `int` | `7` (0–365) | `--keep-last` for the retention policy. At least one keep-* rule must be non-zero before a preview or prune is allowed. |
| `keep_daily` | `int` | `7` (0–365) | `--keep-daily` for the retention policy. |
| `keep_weekly` | `int` | `4` (0–104) | `--keep-weekly` for the retention policy. |
| `keep_monthly` | `int` | `6` (0–120) | `--keep-monthly` for the retention policy. |
| `restore_target` | `folder` | `~/restore` | Staging directory for restores. Snapshots are restored *beneath* it, under their original absolute path, so nothing is ever restored on top of a live file. Must be absolute (after `~` expansion), and may not be `/`, `$HOME`, or one of your backup sources. Restore verification writes under `<restore_target>/.verify/`. |
| `restore_allow_roots` | `string_list` | `[]` | Extra directories a restore may target. `restore_target` is always allowed; `/`, `$HOME` and any backed-up path are refused even when listed here. |
| `check_subset` | `string` | `1/100` | `--read-data-subset` value for manual checks, e.g. `1/100` or `5%`. Scheduled checks override it with their own rotating slice. |
| `restic_bin` | `string` | `restic` | Name or absolute path of the restic binary. A bare name is resolved through the merged search path described under **Requirements**. |
| `pre_backup_command` | `string` | *(empty)* | Shell command run inside the job **before** restic starts, via `/bin/sh -c`. A non-zero exit aborts the backup before restic runs, and that exit code becomes the job's recorded result (the job is reported as failed with it). Arbitrary code with your user's privileges — read [Pre- and post-backup commands](#pre--and-post-backup-commands) first. *Advanced.* |
| `post_backup_command` | `string` | *(empty)* | Shell command run inside the job **after** restic finishes — whatever restic's exit code was. It receives that code in the `RESTIC_EXIT` environment variable, and its own failure never changes the backup's recorded result. *Advanced.* |
| `verify_interval_hours` | `int` | `0` (0–720) | How often to prove a backup can actually be restored. `0` disables scheduled verification; the Run tab's *Verify restore* button and the `verify-restore` IPC event still work. |
| `verify_file_count` | `int` | `3` (1–25) | How many files a verification restores and compares. A value below 1 falls back to the default (3); above 25 it is clamped to 25. |
| `metrics_dir` | `folder` | *(empty)* | Directory for the Prometheus textfile export (`restic_snapshots.prom`). Empty means the plugin writes nothing at all. See [Prometheus textfile export](#prometheus-textfile-export). *Advanced.* |
| `browser_placement` | `select` | `floating` | Where this plugin's panel opens: `floating` (a centred window) or `attached` (docked to the bar). Read by the shell when the panel opens. Declared on the `browser` **panel entry**, not at plugin level: the shell injects its own copy of this key per panel entry unless the entry declares it, and two declarations of the same key produce a shadow warning on every load. |
| `browser_position` | `select` | `center` | Where a floating panel is placed: `auto`, `center`, or a corner/edge (`top_left` … `bottom_right`). Ignored while the panel is attached. Panel entry setting, for the same reason as `browser_placement`. |

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
| `verify-restore` | `{"target":"…"?}` | restore a sample of the newest snapshot into a scratch directory under the target and compare it with the live files; publishes `status.verify` |
| `forget-dry-run` | – | `forget --dry-run --json`; publishes the keep/remove counts **and** the ids that would be removed. Refused when no keep-* rule is set |
| `forget` | – | the real forget plus prune; refused when no keep-* rule is set, and only meaningful after a preview |
| `forget-one` | `{"snapshot":"<id>"}` | forget one snapshot by id; `--prune` is never passed |
| `restore-dry-run` | `{"snapshot":"<id>","target":"…?","include":"…?"}` | `restore --dry-run --json`; publishes how many files would land, and where. Validates the id and the target first |
| `restore` | `{"snapshot":"<id>","target":"…?","include":"…?"}` | the real restore, after the same validation |
| `cancel` | – | cancel the job in flight; the run is reported as *cancelled*, not *failed* |
| `stats` | – | `restic stats --json` → the repository summary card |
| `ls` | `{"snapshot":"<id>"}` | file listing for one snapshot (this is what a `/snap` row sends) |
| `diff` | `{"from":"<id>","to":"<id>"}` | `restic diff --json` between two snapshots |
| `init` | – | `restic init` the configured repository |
| `unlock` | – | `restic unlock --remove-all`, to clear a stale lock |
| `job-log` | `{"kind":"…"?}` | re-publish the last job's log tail into the panel |

Every payload is a single JSON object, passed as the last argument. `target` defaults to the
`restore_target` setting; `include` restricts the restore to one path inside the snapshot (and for a
verification, a target replaces the scratch directory's base while staying inside an allowed restore
root). Snapshot ids are validated against the shape restic emits, and a restore target is validated
before anything runs — an invalid or disallowed payload is rejected with a notification and nothing
is started. Only one job runs at a time: while a job is in flight, new work is declined rather than
queued (a verification refused that way is logged and re-armed, and publishes nothing).

Worked example — preview a restore into your staging target, look at the file count, then do it:

```bash
noctalia msg plugin carlocamacho/restic-snapshots:service all restore-dry-run '{"snapshot":"3f2a9c1e"}'
noctalia msg plugin carlocamacho/restic-snapshots:service all restore '{"snapshot":"3f2a9c1e","include":"/home/you/work"}'
```

## How it stays safe

- **The password is never a value.** It travels as `--password-file <path>`; the plugin stores only
  the path and never reads the file's contents. Its mode is yours to set — `chmod 600`.
- **argv only, with two named exceptions.** Every restic call is an argv vector — no shell string is
  ever built from settings. Generated job scripts contain only a validated argv and generated paths,
  and are mode `0600`. The exceptions are `pre_backup_command` and `post_backup_command`, which are
  user-supplied shell strings *by design*; they are the only settings that become code, they are
  invoked as `/bin/sh -c "$PRECOMMAND"` from a quoted assignment, and they are empty by default.
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
- **Verification writes only where a restore may write, and only reads your files.** Its scratch
  directory is derived from the restore target (or from a target supplied over IPC) and is checked by
  the same `validRestoreTarget` that guards a restore, so every path it writes is inside an allowed
  restore root. The snapshot it verifies comes from restic's own output, not from a caller. It never
  modifies a live file, and it removes the restored files when it is done.
- **A failed run is visible.** A non-zero exit raises `status.error`, so the bar module turns red and
  the Run tab says *failed*; a cancelled run is reported as *cancelled* and leaves the last-success
  time untouched.
- **Staleness is announced once.** When the newest snapshot passes the threshold the plugin notifies
  once — and once more on recovery, never on every tick.

## Limitations / things that are deliberately not done

Read this before you decide how much to trust the plugin with. Every item here is a real property of
the current implementation, not a roadmap promise.

- **Verification is a sample, not a proof.** `verify_file_count` files (3 by default), from the
  newest snapshot only, at most 4 MiB each. It catches "the repository no longer restores", "the
  password changed", "the target is gone", "this file's data is corrupt" — it does not catch a
  corrupt chunk that no sampled file references. For the whole archive use `restic check --read-data`
  (the Run tab's *Check repository* and `check_interval_hours`).
- **A file that changed after the snapshot is reported as *skipped*, not failed.** That is
  deliberate — otherwise every verification of a working machine would report failures — but it
  means a run can legitimately prove nothing about the files you have edited most recently. If every
  sampled file is skipped the run still counts as not-failed (`failed` is 0) and its detail reads
  `N file(s) restored and read back, but none could be compared with a live file`; read `matched`,
  not just `lastOk`, before you trust a green result.
- **Empty `.verify/<epoch>` directory trees are left behind** under your restore target. The host's
  filesystem API cannot remove a directory (only files), so a verification removes the files it
  restored and leaves the directory skeleton. Each run uses its own epoch-stamped directory, so
  leftovers can never make the next run fail — they are empty directories, inside the restore target,
  and you can delete them whenever you like. The cleanup walk is also bounded (2,000 entries per
  run); if it hits that bound it logs that restored files may remain.
- **`--include` is a restic pattern, not a literal path.** A verification restores with one
  `--include` per sampled file. Restic matches those as patterns, so a path containing glob
  metacharacters (`*`, `?`, `[`) can over- or under-match. It **fails closed**: the restore produces
  no copy for that file, and the verification reports it as a failure rather than as a match.
- **Scheduled work uses a rotating subset, never the whole thing at once.** `check_interval_hours`
  reads one `--read-data-subset` slice per run, rotating through the repository; a full pass is
  therefore spread over many runs, and a repository is only fully read if the schedule survives that
  long. Verification picks an evenly-spaced sample that is deterministic per snapshot, so the same
  snapshot always verifies the same files, and a growing snapshot shifts the picks rather than
  always testing the newest paths.
- **The plugin never reads the password file** — not to validate it, not to check its mode, not to
  copy it. If it is wrong, the failure shows up as a restic error in the job log, and if it is
  world-readable, nothing will warn you. `chmod 600` it.
- **A cancel is aimed at restic's own process.** The panel/launcher cancel reads the job's recorded
  PID and signals restic (SIGTERM, then SIGKILL after a grace window). If the cancel arrives while a
  `pre_backup_command` is still running, restic has not started and there is no PID to signal: the
  job is still recorded as *cancelled* and its guard released after the watchdog's grace windows
  (about 20 s), but the command itself may keep running. A cancelled job keeps the exit code it
  actually died with (143 for a SIGTERM), which is why *cancelled* is carried as a separate flag
  rather than inferred from the code.
- **`mode = observe` never starts a backup.** It watches a repository something else writes to.
  Manual actions still work, including verification.
- **Verification needs the machine the files live on, and they must still be there.** It compares
  against the live tree, so it is a check of *this* machine against *this* repository — running it on
  a machine whose files have moved, been renamed or been emptied proves little and reports mostly
  skips.
- **Not done in 0.3.0, on purpose:** multiple repositories/profiles, `restic mount`, rclone/S3 object
  browsing, a file-level diff *viewer* (the panel lists the changed paths, bounded), scheduling of
  the retention policy, and a `thumbnail.webp` (required before a community-catalog pull request is
  accepted; the visual asset is produced separately).
- **The metrics file is not pushed anywhere, and nothing on this machine collects it.** See
  [Prometheus textfile export](#prometheus-textfile-export) — the plugin writes the file only.

## How it was tested

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

**Defects found by running the plugin for real (0.3.0)** — none of them reachable from a plain-Lua
test, so each has a committed guard:

| Defect | Evidence it was real | Guard |
| --- | --- | --- |
| The job-log tail walked the string one character at a time and blew the host's per-callback CPU budget | `[ERR] script callback 'update' exceeded its CPU budget` on a ~97 KB `ls --json` job log | the loop is now one forward pass over lines; `tests/test_source_invariants.py` rejects per-character walks |
| Two glyph names that are not in the host's icon set rendered as blank boxes | `[WRN] [glyph] missing glyph: undo` / `arrow-up-down` in `~/.cache/noctalia/noctalia.log` | the names are `arrow-back-up` / `arrows-up-down`; the same invariant test checks every glyph name against the host's Tabler set |
| A job log that is one enormous line was shown as empty when the byte bound landed inside it | reproduced in `tests/lua/jobs_readlog_test.lua` (a 200 KB single line) | the bounded tail is kept when there is no newline to cut at |

**Defects found by running the plugin for real (0.5.0)** — both invisible to the tests that existed
at the time, for a reason worth recording:

| Defect | Evidence it was real | Guard |
| --- | --- | --- |
| The retention preview reported *keep 0, remove 0* for a repository whose own `forget --dry-run` output says `keep: 2, remove: null` | the plugin returned a **confident zero** from a payload it could not parse: the service reads logs with `parseJsonLines` (one decoded value per *line*), the test used `parseObject` (one decode of the whole text), and restic writes the entire forget array on **one line** — so production passed `{ array }` and the group test was satisfied by the wrapper | the array is unwrapped at the boundary; an unreadable non-empty payload returns `nil` so the panel reports a failure rather than a zero. `restic_pure_test` now asserts the **wrapped** shape, which is the shape the service actually passes |
| `entry 'browser' setting 'browser_placement' shadows a plugin-level setting; entry value wins` on **every** manifest load | the host only suppresses its injected copies when the *entry* declares the key (`hasSettingKey` inspects `entry.settings`), so a plugin-level declaration was ignored and the entry's value shadowed it | both keys are declared as `[[panel.setting]]` on the `browser` entry. Proved side by side: `noctalia plugins lint` on 0.4.0 prints the two warnings, on 0.5.0 prints none |
| The Log tab showed one line and always would: every job log on the machine held exactly one record | a `message_type` histogram of every log file: four hourly backups at 1 × `summary` (473 bytes, identical each hour), one `ls` job at 260 × `node`. `backup --json` writes a single summary when nothing is copied, and the job script diverts every `status` line to `.status`, so nothing else reached the log | backup jobs now run with `--verbose`; the job script discards the `unchanged` records. The real repository goes from 262 raw lines / 61 KB to **2 lines / 682 bytes**, and a run that changes a file names it |

The whole suite, run from the repository root:

```bash
python3 -m unittest discover -s tests           # argv builders, quoting, job script, schedule, invariants
for f in tests/lua/*.lua; do lua5.4 "$f"; done  # real entries/renders + the detached job runner
luac -p plugin/restic-snapshots/*.luau plugin/restic-snapshots/lib/*.luau   # syntax
noctalia plugins lint plugin/restic-snapshots   # manifest + entries
```

All four are green on `release/0.6.0`: `luac -p` parses all thirteen `.luau` files, the Python suite
runs 105 tests (one skipped), the eleven Lua suites pass — including the additions for 0.5.0 (the
`parseJsonLines` wrapper shape the retention defect hid behind) and 0.6.0 (the `--verbose` record
shape, the job script's `unchanged` filter, and the per-file log lines) — and
`noctalia plugins lint` reports `0 errors, 0 warnings`.

## Notes

**Network calls: none.** The plugin makes no network calls at all — no HTTP client, no update check,
no telemetry, no metrics push. If `repository` points at a remote backend (`sftp:`, `s3:`, `b2:`,
`rclone:`), it is `restic` that opens those connections, using the credentials you configure in the
repository URL or in `env_file`.

**Processes spawned.** Inside a job: the resolved `restic` binary, `/bin/sh` (which runs the
generated job script), and — only when you have set them — one `/bin/sh -c` per pre/post-backup
command. Outside a job: `kill` for a cancel or a watchdog escalation, `/bin/sh -lc` once at startup
to read your login shell's `PATH`, and `noctalia msg plugin …` for the actions the panel, the
control-center tile and the launcher send. Nothing else is executed. No shell string is ever built
from settings: the only settings that become shell commands are the two hook commands.

**Files written** — the plugin data directory (`noctalia.pluginDataDir()`), the restore target, and
the metrics directory if you configure one:

| Path | What it is |
| --- | --- |
| `jobs/<token>.sh` | the generated job script; mode `0600`, contains only the argv vector, generated paths and your two hook commands |
| `jobs/<token>.jsonl` | the job's combined stdout + stderr, including the hook output behind its markers — this is what the Log tab shows |
| `jobs/<token>.status` | the newest restic progress line, overwritten in place |
| `jobs/<token>.exit` | restic's exit code (or the pre-command's abort code), written when the job stops |
| `jobs/<token>.pid` | restic's own pid (so a cancel kills restic, not a pipeline member) |
| `jobs/<token>.fifo` | the named pipe the script reads restic's output from |
| `state.json` | the persisted schedule and results: last run, last success, next run, last check and its rotation index, last verification, last log path |
| `<restore_target>/…` | files a restore or a verification writes, under their original absolute path |
| `<restore_target>/.verify/<epoch>/…` | one scratch directory per verification; the restored files are removed afterwards, the empty directories stay (see [Limitations](#limitations--things-that-are-deliberately-not-done)) |
| `<metrics_dir>/restic_snapshots.prom` | the Prometheus textfile export, replaced atomically via `restic_snapshots.prom.tmp` |

Stale job files are swept; nothing is written outside those directories. No file of yours is ever
modified in place — a restore only ever *creates* files under the restore target.

**The password is only ever a path.** It is passed as `--password-file <path>`; the plugin never
reads the file, and never puts its contents into an environment variable, into argv, into a
generated script, or into shared state — and it is not in the metrics export. `repository` is
redacted (user info and token query parameters stripped) before it is displayed in the panel or the
widget tooltip.

**Debugging.** The last job's output is in the panel's **Log** tab, and on disk in
`jobs/<token>.jsonl`; its path is remembered in `state.json`, so the viewer still works after a
restart. Re-publish it over IPC with:

```bash
noctalia msg plugin carlocamacho/restic-snapshots:service all job-log
```

The shell does not log to `journalctl` — its stdout goes to `/dev/null`, so plugin log lines and
host warnings land in `~/.cache/noctalia/noctalia.log`. That file is where a `missing glyph` warning
or a `script callback … exceeded its CPU budget` error would show up.

Read-only commands (`snapshots`, `stats`, `ls`, `diff`) carry `--no-lock`, and refreshes are skipped
while a job is in flight, so browsing never races a running backup.

## Layout

```
catalog.toml                     source index for this repository (what a git source reads)
plugin/restic-snapshots/
  plugin.toml                    manifest: ids, entries, settings, dependencies, plugin_api 30
  service.luau                   scheduler, job lifecycle, verification, IPC, persistence
  widget.luau                    bar module
  panel.luau                     Snapshots / Run / Retention / Log
  shortcut.luau                  control-center tile
  launcher.luau                  the /snap launcher provider
  lib/restic.luau                argv builders + JSON parsers (pure)
  lib/jobs.luau                  detached job runner, hooks, polling
  lib/schedule.luau              next-run, staleness, check and verification arithmetic (pure)
  lib/metrics.luau               the Prometheus textfile export (pure render + atomic write)
  lib/store.luau                 persisted schedule / last-run state
  lib/state.luau                 state keys, event names, status shape
  lib/env.luau                   binary resolution (daemon PATH workaround)
  translations/en.json           user-visible strings
tests/                           Python and Lua suites
docs/phase0-findings.md          the live feasibility pass behind the design
docs/CONTRACTS-0.3.0.md          the frozen interfaces and workstream record for 0.3.0
```

## License

MIT — see [`LICENSE`](LICENSE).
