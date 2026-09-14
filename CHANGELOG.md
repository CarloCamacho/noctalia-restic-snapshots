# Changelog

## 0.2.0 — unreleased

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
