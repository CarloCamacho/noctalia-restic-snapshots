# Phase 0 — Feasibility Findings

**Date:** 2026-09-08
**Environment:** CachyOS · Noctalia v5 · restic 0.19.1 (static, `~/.local/bin`)

Every row was verified by running the real binary against a throwaway repository.

---

## 1. Installing restic without root

`sudo` requires a password on this machine and approval prompts are disabled, so `pacman -S restic`
was not an option. The official static release binary was used instead:

```bash
curl -L -o restic.bz2 https://github.com/restic/restic/releases/download/v0.19.1/restic_0.19.1_linux_amd64.bz2
python3 -c "import bz2,shutil; shutil.copyfileobj(bz2.open('restic.bz2'), open('$HOME/.local/bin/restic','wb'))"
chmod +x ~/.local/bin/restic
```

`restic version` → `restic 0.19.1 compiled with go1.26.4 on linux/amd64`, matching the Arch
package version (`0.19.1-1.1`), so behaviour is representative. Users who prefer the packaged
build can `pacman -S restic` and the plugin finds it either way.

## 2. Verified command behaviour

| # | Question | Method | Result |
| --- | --- | --- | --- |
| 1 | Does `restic init` work with a password file? | live | ✅ `RESTIC_PASSWORD_FILE` and `--password-file` both work |
| 2 | Can the password avoid the environment entirely? | live | ✅ `restic --password-file <path> -r <repo> …` — no env needed, so argv-only execution is possible |
| 3 | `backup --json` output shape | live | one `{"message_type":"summary", …}` line (plus `status` lines on larger runs) with `files_new`, `total_files_processed`, `total_bytes_processed`, `data_added` |
| 4 | `snapshots --json` output shape | live | a JSON **array**; per snapshot: `id`, `short_id`, `time`, `hostname`, `tags`, `paths`, `summary{…}` |
| 5 | `stats --json` | live | `{"total_size":…,"total_file_count":…,"snapshots_count":…}` |
| 6 | `check --json` | live | `{"message_type":"summary","num_errors":0,"broken_packs":null,…}` |
| 7 | `forget --dry-run --json` | live | array of groups with `tags`/`host`/`paths` plus `keep` and `remove` arrays |
| 8 | `restore --json` | live | `{"message_type":"summary","total_files":…,"files_restored":…,"bytes_restored":…}`; restores under `<target>/<absolute source path>` |

## 3. Two constraints that shaped the design

1. **`runAsync` clamps its timeout to 50–60000 ms.** A real backup blows through 60 s, so every
   long operation runs as a **generated script launched detached** (no callback → no timeout),
   writing `<token>.jsonl` and `<token>.exit` under `pluginDataDir()/jobs/`. The service polls the
   exit file. A `.pid` file is written too, so a running job can be cancelled.
2. **The daemon's PATH is bare** — the same finding as agent-harness: no `~/.local/bin`, which is
   exactly where restic now lives. Resolution therefore searches known per-user directories, then
   a probed login-shell PATH, then the daemon PATH (merged, never replaced), and the generated job
   script sets `PATH` explicitly.

## 4. Throwaway test fixture

`the worktrees/.tools-build/restic-test/` — a repository, a `0600` password file, 200 KB of
random data, and a staging restore directory. Used for the live end-to-end test below and
removed afterwards; no real data was touched.

## 5. Live end-to-end result

Driven through the plugin's own IPC:

| Step | Result |
| --- | --- |
| `backup-now` | detached job completed, snapshot created, `restic_status.lastRun.ok = true` |
| snapshot list | two snapshots listed with time, host, tag and file counts |
| `check` | `num_errors = 0` |
| `forget-dry-run` | preview reported keep/remove counts; nothing was removed |
| `restore` | restored into the configured staging target, files byte-identical |
| cancel | a running job terminated via its recorded PID |

Details of the run are recorded in the repository README's verification section.
