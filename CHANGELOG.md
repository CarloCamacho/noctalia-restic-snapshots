# Changelog

## 0.6.0 — 2026-09-15

The Log tab release. 0.5.0 gave the Snapshots tab something to say; the Log tab still said one line —
the same line every hour — because that was genuinely all restic wrote to it. This release makes the
job log a record of what the run did.

### Added

- **The log now names the files a run changed.** Backup jobs run restic with `--verbose`, which emits
  one record per file *and* per directory with the action taken. The job script drops the `unchanged`
  ones as it writes the log, so a quiet run stays short and a run that changed something names what it
  changed. Measured on the real repository: the raw `--verbose` stream is **262 lines / 61 KB**, and
  the filtered log the panel reads is **2 lines / 682 bytes** —
  `scanned 173 files` and `0 new · 0 changed · 173 unchanged · 0 B added`.
- **`scan_finished` reads as what restic examined** rather than as a file with a blank path. It is a
  `verbose_status` with an empty `item` and a `total_files` count, so it gets its own line kind.

### Fixed

- **The Log tab showed one line, and always would have.** Not a parse failure and not a rendering one:
  `backup --json` writes a single `summary` object for a run that copies nothing — the job log on disk
  was **473 bytes, one line, byte-identical every hour** — and the job script routes every `status`
  line to the `.status` file instead of the log, so nothing else ever survived to be displayed. The
  tab was working correctly against a log that had nothing in it. `--verbose` is what puts something
  there.

### Changed

- `restic.backupArgs` gains `--verbose`. Only `backup` asks for it: it is the only command with
  per-file actions worth recording, and the blast radius of changing a backup invocation is kept to
  the one command that needs it.
- The generated job script gains a `case` arm that discards the `unchanged` verbose records. The
  filter lives in the job script rather than in the panel, so a quiet run's log is small on disk and
  the panel never reads or formats records it cannot use.
- An action restic adds later is shown as restic spelled it rather than dropped, and a per-file line
  is never folded into a count: a file a run touched must not vanish because the panel had not heard
  of the verb.

### Notes

- **Cost, measured.** The log grows only with what actually changed. A first backup of a new tree
  writes one line per file; an unchanged hourly run writes two. The panel already bounds its read to
  the last 16 KB / 200 rows, and the jobs directory is swept after a day, so neither the read nor the
  render is proportional to a large log — the failure mode 0.4.0 fixed.
- **`--verbose` does not disturb the live progress path.** The `.status` routing is unchanged and
  restic's message types are independent; the Run tab's progress still reads the last `status` line.

## 0.5.0 — 2026-09-15

The glanceability release. 0.4.0 made the plugin readable; the panel was still a table of
near-identical rows, with the most interesting fact about the repository -- that it has been backing
up for twenty-one hours and storing almost nothing -- nowhere on screen. This release gives the
repository a shape, makes the retention preview tell the truth, and removes two warnings that fired
on every load.

### Added

- **A history strip on the Snapshots tab.** One bar per snapshot, oldest to newest, as tall as the
  bytes that snapshot actually added, accented when it added anything at all. Twenty-two flat hours
  and one spike answers *is this working, and has anything changed?* at a glance. It is one
  `ui.box` per snapshot: no graph, no normalisation, and no new service state, because
  `summary.dataAdded` was already published in every snapshot row.
- **A headline that says what those numbers mean** — *933 KiB stored, from 18.9 MiB scanned across
  23 snapshots* — above the list. restic walks the whole backup set every run and stores only what
  changed, so *nothing to back up* is the good outcome; the panel now says so rather than leaving a
  flat strip to be read as a fault.
- **A sparkline in the bar widget.** The same series beside the glyph, so the shape of the
  repository is visible without opening anything. It reads the snapshots list rather than the status
  payload, and a bar never reaches zero height: with hourly backups most values are legitimately
  zero, and a line pinned along the floor is indistinguishable from a graph that failed to draw.
- **A countdown bar on the Run tab** that fills across the interval to the next backup. The panel
  already said *next scheduled run in 12m* in words; this is the one element on the panel that
  visibly advances on its own.
- **Date headings in the snapshot list**, one per calendar day.

### Fixed

- **The retention preview misreported what it would keep.** The panel showed *Would keep 0, remove
  0* for a repository whose own `forget --dry-run` output says `keep: 2 snapshots, remove: null`, and
  it would have done so for any policy: the counts were being read from a payload the plugin could
  not parse. The service reads job logs with `parseJsonLines` (one decoded value per **line**) while
  the unit test used `parseObject` (one decode of the whole text), and restic writes the entire
  forget array on a single line — so production passed `{ array }`, the group test was satisfied by
  the *wrapper*, every "group" was really the array, `group.keep` was nil, and the function returned
  a confident zero. The array is now unwrapped at the boundary, and a payload that is neither a
  group nor a list of groups returns `nil` so the panel reports a failure instead of a plausible
  zero. A genuinely empty payload stays a zero: that is restic saying nothing matched. Measured on
  both real job files on this machine: 0.4.0 reports *keep 0, remove 0*; 0.5.0 reports *keep 2,
  remove 0*, matching restic exactly.
- **Two warnings on every manifest load.**
  `entry 'browser' setting 'browser_placement' shadows a plugin-level setting; entry value wins`,
  and the same for `browser_position`. `plugin_panel_shell.cpp` only suppresses its own injected
  copies when the **entry** already declares that key (`hasSettingKey` inspects `entry.settings`), so
  a plugin-level declaration is not recognised as one: the host injected `browser_placement` anyway,
  the entry's value then shadowed the plugin-level copy, and `plugin_manifest.cpp` warned on every
  load while the plugin-level copies sat dead. Both are now declared as `[[panel.setting]]` on the
  `browser` entry, so the labelled control from 0.4.0 is unchanged and the collision is gone.
- **The prune note pointed at a control that could not exist.** *Removal only runs after you confirm
  below* rendered even when nothing was to be removed and no confirmation could follow it.

### Changed

- **The snapshot headline is recency, not a 35-character nanosecond timestamp** — *21m ago ·
  22:15:06*, with the bytes added called out when there are any. The absolute date moved to the day
  heading, so it is still there when you are hunting for the snapshot from Tuesday.
- **Tabs mark the active tab with `selected`** rather than repainting it `primary`; the accent block
  competed with the panel's one real primary action.
- **Close is the `x` glyph** rather than the word *Close* set as flat text beside four tabs.
- **The per-snapshot Restore button is ghost, not secondary.** Twenty-two filled accent buttons down
  one edge was the loudest thing on the panel and the least informative part of it. The button stays
  visible and labelled, because the flow is two-step and discoverability matters more than quietness.
- **The snapshot action sheet is width-constrained and right-aligned.** A bare `ui.column` stretches
  its children and a button centres its content by default, so the sheet rendered as a full-width
  stack of centred buttons. Its entries now left-align.

### Notes

- 0.4.0 is dated as released above; it was tagged `v0.4.0`, but `catalog.toml` was still advertising
  **0.2.0**, and a git source reads that file — so the source index was two releases behind. It now
  reads 0.5.0. This is the second time this repository has been bitten by a stale index.

## 0.4.0 — 2026-09-15

The readability release. Three things a user hit in the panel, all of them about seeing what the
plugin actually did — and two of them limitations of the shell that the plugin had to work around.

### Added

- **A snapshot action sheet.** The trailing ⋯ button on a snapshot row opens *Details*, *Files*,
  *Diff with previous*, *Restore*, *Copy id* and *Forget this snapshot* in a sheet inside the panel.
  *Details* lists the snapshot's id, capture time (absolute and relative), host, tags, paths, files
  processed, bytes processed and data added, and offers its file listing and a copy of the id.
- **A Formatted / Raw log view.** See below.

### Fixed

- **The Log tab showed one clipped line of raw JSON.** It rendered restic's `--json` output
  verbatim, one clamped line per record, so a routine hourly backup read as a single unreadable
  blob (`{"message_type":"summary","files_new":0,…}`) and a listing job became 261 of them. The log
  is now formatted for a human; *Raw* still shows the untouched stream.
- **The ⋯ button did nothing on a left click.** The shell only permits its native context menu from
  a pointer callback reached through `onRightClick`, and the button asked for it from `onClick`,
  which returns false silently — so only a right click ever worked. A left click now opens the
  in-panel sheet; the native menu is unchanged.
- **An in-flight job's log read as "failed".** While a job runs, nothing has succeeded yet and there
  is no exit code, so the header now says *running* and omits the exit code instead of inventing
  `exit 0`.
- **A prune suggestion was described as a repair suggestion**, and a folded `ls`/`diff` stream was
  reported as "progress lines folded" whatever it actually contained.
- **A large job log fell back to raw.** Formatting the log inside the service's periodic publish
  exceeded the shell's per-callback CPU budget on a 97 KB listing job — the shell meters CPU time
  and charges the GC work of a large allocation to the callback that caused it — so the Log tab
  showed raw JSON for exactly the logs this release makes readable. The service now publishes the
  log's **path**, and the panel reads, formats and caches it when you open the Log tab, so the
  periodic callback carries no payload proportional to a file. Verified by four reproductions of that
  job with no budget error, where it had previously failed on every run.

### Changed

- **Where the panel opens is now a labelled setting.** `browser_placement` (*floating* — the
  default, a centred window — or *attached* to the bar) and `browser_position`. The shell resolves
  these from the plugin's settings, but injects them without a label when the plugin does not
  declare them, which is why the option previously existed but could not be found.

## 0.3.0 — 2026-09-14

The proof release. 0.2.0 made the plugin honest about whether a backup *ran*; 0.3.0 makes it honest
about whether that backup *restores*, and adds the three things that let it live in a machine you
actually run: a command before and after the backup, an entry in the launcher, and a Prometheus
export.

### Added

- **Restore verification — proof that a backup restores, not just that it ran.**
  `verify_interval_hours` (default `0`, i.e. off) and `verify_file_count` (default `3`). On the
  cadence, or on demand from the Run tab's new *Verify restore* button and the `verify-restore` IPC
  event, a sample of regular files is restored from the newest snapshot into
  `<restore_target>/.verify/<epoch>/` and compared byte-for-byte with the live files. The panel shows
  **Last verified** — `3 of 3 files matched`, or the reason it failed — and the same result is
  published on the status as `verify` (`lastAt`, `lastOk`, `checked`, `matched`, `failed`, `detail`).
  A file that legitimately changed after the snapshot, or is gone, is reported as *skipped* rather
  than failed; a verification that could not run at all is reported as a failure with the reason and
  never as a pass. One notification per transition into failure, none on success.
- **Pre- and post-backup commands.** `pre_backup_command` and `post_backup_command` run *inside* the
  job, so they inherit its timeout, its cancellation and its log, and are invoked as
  `/bin/sh -c "$PRECOMMAND"` from a quoted assignment rather than inlined into a command line. A
  non-zero pre-backup command **aborts the backup before restic starts** and becomes the run's
  reported result; the post-backup command runs whatever restic's exit code was, receives it in
  `RESTIC_EXIT`, and its own failure never changes the recorded result. Both appear in the job log
  (and the Log tab) behind `== pre-backup command ==` / `== post-backup command ==`. With both
  settings empty, the generated script is byte-identical to 0.2.0's.
- **Launcher provider `/snap`.** The eight newest snapshots — short id, local time, host, file count,
  size — followed by **Back up now**, **Check repository** and **Open Restic Snapshots**. Activating a
  snapshot loads its file listing into the panel and opens the panel; typing a hostname, a tag or a
  short id narrows the list (case-insensitive substring first, the shell's fuzzy matcher as a
  fallback), and a query that matches nothing publishes an empty list rather than an error.
- **Prometheus textfile export.** `metrics_dir` makes the plugin write `restic_snapshots.prom`
  atomically (temp file + rename) whenever the state changes — a job finishing, a snapshot refresh, a
  check, a verification — for a `node_exporter` textfile collector or any scraper reading the
  directory. It carries `last_success_timestamp_seconds`, `count`, `newest_age_seconds`, `stale`,
  `repo_bytes`, `repo_files`, `last_job_exit_code{kind="…"}`, `last_check_errors`, `last_verify_ok`,
  `last_verify_matched`, `last_verify_failed` and `export_timestamp_seconds`. A value the plugin does
  not know is **omitted, never exported as zero**, so "no backup ever recorded" and "a backup at the
  Unix epoch" stay different statements. An empty `metrics_dir` means no writes at all, and a failed
  write is logged once without disturbing the service.
- **Panel follow-ups.** The Run tab renders the result of the last integrity check and the last
  verification; a diff lists the paths that changed (bounded, with a count of the rest); the *this
  host only* filter uses the real local hostname (`/etc/hostname`, falling back to the previous
  inference when it cannot be read).
- **Guards for the defects a plain-Lua test cannot see.** `tests/test_source_invariants.py` rejects
  any per-character string walk in the plugin and checks every glyph name against the host's Tabler
  icon set; `tests/lua/jobs_readlog_test.lua` covers a 5,000-line tail and a 200 KB single line.

### Fixed

- **The job-log tail blew the host's per-callback CPU budget and killed the service's update tick.**
  `tailLines` walked the log backwards one character at a time (`text:sub(i, i)`); on a ~97 KB
  `ls --json` job log the host aborted the whole tick with
  `script callback 'update' exceeded its CPU budget`, so the panel stopped updating and the job's
  summary — file counts, the retention preview — was thrown away. The walk is now one forward pass
  over the newlines with a ring buffer, so its cost is linear in **lines** and never in bytes, and
  the invariants suite fails on the old pattern.
- **Two glyph names that rendered as blank boxes.** The Restore button and the restore drawer used
  `undo` (now `arrow-back-up`) and the sort toggle used `arrow-up-down` (now `arrows-up-down`); the
  host logged `[WRN] [glyph] missing glyph: …` and drew nothing at all. Every glyph name in the
  plugin is now checked against the host's icon set.
- **A job log that is one enormous line was shown as empty.** When the byte bound landed inside a
  line with no newline after it, the reader dropped the partial first line and with it the entire
  log; it now keeps the bounded tail in that case, which is more useful than showing nothing.
  (Found by the test written for the two defects above — the same live-testing pass.)
- **A cancel is a cancel, not a result — and it now reaches the verification job too.** A run stopped
  with *Cancel* is recorded as *cancelled* in the Run tab and the log header, notified once as
  information, and leaves `status.error` and the last-success time untouched, so the bar module does
  not go red for something you did on purpose; the schedule re-arms from that moment rather than from
  the last success. This matters more in 0.3.0 because restore verification is an ordinary job:
  *Cancel* stops it, the watchdog covers it, and a cancelled verification is never recorded as a
  successful one. The cancel is carried as an explicit flag rather than inferred from the exit code,
  so a restic that dies from a signal nobody sent is still a failure.

### Changed

- **The generated job script changes only when you use a hook.** With both commands empty not one
  hook line is emitted (the tests assert byte identity against the 0.2.0 generator). With a
  post-backup command, the job's `.exit` file is written only *after* it finishes, so a job is not
  reported as finished — and its log is not complete — until its follow-up is done.
- **`verify` is a job kind like any other.** It appears in the job log header, in the Run tab's
  last-run line and as the `kind` label of the metrics export, and it is covered by the single-flight
  guard, the watchdog and *Cancel*.
- **The published status gained a `verify` field** alongside `checks`, and both survive a shell
  restart (the last verification's result and counts are persisted with the schedule).
- **`verify-restore` joined the frozen event set** in `lib/state.luau`. Its optional
  `{"target": "…"}` payload is validated like every other restore target, and an unusable target is
  rejected with a notification rather than starting anything.
- **Launcher rows carry the manifest's `Snapshots` category** so the launcher's filter bar works —
  the launcher compares that label literally, which is why it is not translated. The unused
  `launcher.category.snapshots` translation key was dropped.

## 0.2.0 — 2026-09-14

The trust release: the five things that made 0.1.0 unsafe to leave running, plus the features that
make the plugin worth watching.

### Fixed

- **Lost job output on the final poll.** `jobs.poll()` discarded the last read whenever the log size
  had not changed since the previous tick, even though the `.exit` file had appeared — so the final
  status line and summary were thrown away, and the retention preview then reported "would keep 0,
  remove 0" with no Prune button to offer. `poll` now returns the log text whenever the job is done.
  Covered by a regression test that drives "size unchanged + exit present".
- **A restart could silently skip a backup.** The schedule (`lastRun`, `nextRunAt`) lived only in
  memory and re-armed from "now" on every load, so a shell restart or a settings edit could push a
  backup forward indefinitely. The schedule and last-run state are now persisted to the plugin data
  directory, and the next run is derived from the last **successful** run; a run that came due while
  the shell was down fires within about a minute of startup instead of waiting out a full interval.
- **Failures were invisible, and a cancel looked like a failure.** A non-zero exit never set
  `status.error`, so the bar module could not turn red. Failed runs now surface an error state, and
  a cancel sets an explicit flag and is reported as *cancelled* — it no longer touches the
  last-success time.
- **A stuck job blocked every future run.** A hung restic process held the single-flight guard
  forever. A watchdog now cancels any job running longer than `job_timeout_minutes`, records it as a
  failure with exit code 124 and the message "timed out", and releases the guard so the next
  scheduled run still fires.
- **Restore was one unconfirmed click.** It took an unvalidated snapshot id and target, with no
  dry-run and no destination allow-list. Restores are now two-step and validated first: the target
  must be absolute, not `/`, not `$HOME`, not one of the backup sources, and either the configured
  restore target or under an allow-listed root. A `--dry-run` preview reports how many files would
  land and where, and only then does the real restore become available.

### Added

- **Staleness guardian** — notifies once when the newest snapshot passes `stale_after_hours` (or a
  threshold derived from the backup interval), and once again on recovery.
- **Scheduled integrity checks** — `restic check` on `check_interval_hours`, reading a rotating
  `--read-data-subset` slice so a full pass is spread across many runs instead of one long one. The
  last check time, result and rotation index are persisted.
- **Repository stats** — total size, file count and snapshot count (`restic stats --json`) on the
  Run tab.
- **Per-snapshot file listing** — `restic ls --json` for any snapshot from its row's context menu.
- **Job log viewer** — the last job's header (kind, when, verdict, exit code) and output tail in a
  new **Log** tab, re-publishable over IPC; the log path is persisted so the viewer still works
  after a restart.
- **Single-snapshot forget** — forget one snapshot by id from its context menu, always naming the
  id, and never passing `--prune`.
- **Snapshot filtering** — list all snapshots, only this host's, or everything carrying a tag, plus
  a text search and a newest/oldest toggle.
- **`env_file` setting** — an optional file sourced by the job script before restic runs, for
  backends that take credentials from the environment (`AWS_ACCESS_KEY_ID`, `B2_ACCOUNT_KEY`,
  `RCLONE_*`).
- **`plugin_api` 30** — the panel uses versioned panel options; requires Noctalia v5 at plugin API
  level 30 or newer.
- **Tag vocabulary fix** — the manifest's tags now use Noctalia's vocabulary (`backup` → `utility`),
  so the plugin is filed under the categories the store actually uses.
- **New retention and job settings** — `job_timeout_minutes`, `stale_after_hours`,
  `restore_allow_roots` and `check_interval_hours`, plus a `show_staleness` widget setting.

## 0.1.0 — unreleased

Initial build on a completed Phase 0 pass (see `docs/phase0-findings.md`).

- Plugin-owned backup schedule (interval), with an observe-only mode for users who already run
  their own restic timers.
- Snapshot browser with per-snapshot restore into a staging target.
- Repository integrity check (`restic check --read-data-subset`).
- Retention policy with a mandatory dry-run preview and two-step confirmation before pruning.
- Detached job runner: long operations are not subject to the 60 s `runAsync` timeout, and a
  running job can be cancelled through its recorded PID.
- Bar module with last-run/next-run/progress, plus a control-center tile.
- Password passed only as `--password-file <path>`; no shell string is ever built from settings.
- 17 Python tests (argv, quoting, schedule) and 50 Lua assertions across the widget, panel and
  job runner.

### Fixed during live testing

- `tonumber(str:gsub(...))` passed gsub's substitution count as the numeric base, so the job
  poller errored on every tick and the service stopped responding to IPC. Parenthesised the
  gsub, and added a regression test that feeds a newline-terminated exit file.
- Backup refusals were silent; the service now logs why a run was declined.
