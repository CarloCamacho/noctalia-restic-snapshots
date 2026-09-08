<div align="center">

# 🗄 Restic Snapshots

**Your backups, visible — and honest about whether they ran.**

A [Noctalia v5](https://noctalia.dev) plugin: scheduled restic backups, a snapshot browser, staging
restore, and retention that always shows you what it would delete before it deletes it.

<br>

[![Noctalia](https://img.shields.io/badge/Noctalia-v5-8b5cf6?style=flat-square)](https://noctalia.dev)
[![plugin_api](https://img.shields.io/badge/plugin__api-24-22c55e?style=flat-square)](#)
[![restic](https://img.shields.io/badge/restic-0.19%2B-8b5cf6?style=flat-square)](https://restic.net)
[![tests](https://img.shields.io/badge/tests-17%20py%20%2B%2050%20lua-22c55e?style=flat-square)](#verification)
[![license](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

</div>

---

## What it does

| | |
| --- | --- |
| **Bar module** | restic health at a glance: last run, next run, snapshot count, live progress |
| **Snapshot browser** | every snapshot with time, host, tags and size — restore any one with a click |
| **Run tab** | back up now, check repository integrity, cancel a running job |
| **Retention tab** | edit the policy, **preview** exactly what would be removed, then confirm |
| **Control-center tile** | one-tap "back up now" |
| **Scheduler** | plugin-owned interval, or observe-only if you already run your own timers |

## Install

```bash
noctalia msg plugins source add carlocamacho git https://github.com/CarloCamacho/noctalia-restic-snapshots
noctalia msg plugins enable carlocamacho/restic-snapshots
```

Then open **Settings → Plugins → Restic Snapshots** and set:

| Setting | Example |
| --- | --- |
| Repository | `/mnt/backup/restic` or `sftp:host:/srv/restic` |
| Password file | `/run/secrets/restic-password` |
| Backup paths | `/home/you/work`, `/home/you/.config` |
| Mode | plugin (default) or observe-only |

## How it stays safe

- **The password is never a value.** It travels as `--password-file <path>`; the plugin stores only
  the path, and never reads the file's contents.
- **argv only.** Every restic call is an argv vector — no shell string is built from settings.
  Generated job scripts contain only validated argv and generated paths.
- **Long jobs cannot be killed by a timeout.** `runAsync` clamps timeouts to 60 s, so backups run
  as detached jobs with their own exit-code and PID files.
- **Retention is two-step.** Preview runs `forget --dry-run --json`, shows keep/remove counts, and
  the destructive button only appears afterwards — then asks for a second confirmation.
- **Restore never overwrites.** Snapshots restore into the configured staging target, under their
  original absolute path.

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

**Live end-to-end** (throwaway repository, driven through the plugin's own IPC):

| Step | Result |
| --- | --- |
| `backup-now` | ✅ new snapshot in 2 s, tags applied, job exit 0 |
| `check` | ✅ `num_errors = 0` |
| `forget-dry-run` | ✅ keep/remove preview, nothing removed |
| `restore` | ✅ files byte-identical under the staging target |

```bash
python3 -m unittest discover -s tests      # 17 tests: argv, quoting, schedule
lua5.4 tests/lua/widget_render_test.lua    # 15 assertions on the real widget tree
lua5.4 tests/lua/panel_render_test.lua     # 19 assertions on the real panel tree
lua5.4 tests/lua/jobs_test.lua             # 16 assertions on the detached job runner
luac5.4 -p plugin/restic-snapshots/*.luau  # syntax
```

## IPC

```bash
noctalia msg plugin carlocamacho/restic-snapshots:service all backup-now
noctalia msg plugin carlocamacho/restic-snapshots:service all check
noctalia msg plugin carlocamacho/restic-snapshots:service all forget-dry-run
noctalia msg plugin carlocamacho/restic-snapshots:service all restore '{"snapshot":"abc123"}'
noctalia msg panel-toggle carlocamacho/restic-snapshots:browser
```

## Layout

```
plugin/restic-snapshots/
  plugin.toml            manifest (plugin_api 24)
  service.luau           scheduler, job lifecycle, IPC
  widget.luau            bar module
  panel.luau             snapshot browser / run / retention
  shortcut.luau          control-center tile
  lib/restic.luau        argv builders + JSON parsers (pure)
  lib/jobs.luau          detached job runner + polling
  lib/schedule.luau      next-run arithmetic
  lib/env.luau           binary resolution (daemon PATH workaround)
  lib/state.luau         state keys and schema
```

## Roadmap

- [ ] Multi-repository profiles
- [ ] File-level diff between two snapshots
- [ ] `restic mount` browsing
- [ ] Remote backends: rclone/S3 object browser

## License

MIT — see [`LICENSE`](LICENSE).
