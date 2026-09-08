# Changelog

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
