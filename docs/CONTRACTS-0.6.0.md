# Restic Snapshots 0.6.0 — frozen contracts & workstream map

Read this before touching the job log. It records why the Log tab looked empty, what makes it
non-empty, and the two places the record shape is now depended on.

## 1. The report, and what it actually was

> "Can you take a look at the Log tab? It never has any info"

The tab was **working**. It rendered a header (`backup · 1m ago · ok · exit 0`), one formatted line
(`0 new · 0 changed · 173 unchanged · 840.2 KiB processed · 0 B added · 1.2s`) and the Formatted/Raw
toggle — a toggle that only renders when there *is* a body. It had one line because the log had one
line.

## 2. The evidence

`message_type` histogram of every job log on the machine:

```
1a0a4ff5d50d8fd9b1.jsonl    1 line    1 summary           <- hourly backup
1a0a4dc30bec4dd357.jsonl    1 line    1 summary           <- hourly backup
1a0a4d1294af54bac6.jsonl    1 line    1 summary
1a0a4a5326040b32b5.jsonl    1 line    1 summary
1a0a4a2613b20a0e44.jsonl  261 lines  260 node, 1 snapshot   <- an `ls` job
```

Three causes, all structural:

1. **`backup --json` says almost nothing about a run that copies nothing.** One `summary` object at
   the end. There is no per-file output unless `--verbose` is passed, and it was not.
2. **The job script diverts the interesting lines.** Its `case` sends anything matching
   `"message_type":"status"` to `.status` (the Run tab's live progress), not to the log — and those
   are the lines carrying `percent_done` / `files_done` / `bytes_done`.
3. The surviving line is identical every hour, so the tab reads as empty.

The `ls` jobs prove the tab renders fine when there is content: 260 file records become a listing.

## 3. The fix, and why it is split in two places

| Where | What | Why there |
|---|---|---|
| `lib/restic.luau` `backupArgs` | `--verbose` | restic only emits `verbose_status` per file when asked. **Only `backup` gets it** — it is the only command with per-file actions worth recording, and changing a backup invocation deserves the smallest possible blast radius. |
| `lib/jobs.luau` (generated script) | a `case` arm that discards `"action":"unchanged"` | The filter belongs in the job script, not the panel: a quiet run's log stays tiny on disk, and the panel never reads or formats ~260 records it cannot use. Doing it here also means the cost is paid once, by a detached script, instead of on every panel render. |
| `lib/logfmt.luau` | `verbose_status` → `{kind="file"}` / `{kind="scan"}` | The formatter is the only place that knows what a record means. |
| `panel.luau` | renders `file` and `scan` kinds | The panel is the only place that knows how to word it. |

### Measured, on the real repository

```
raw `--verbose` stream          262 lines / 61144 bytes
after the job script's filter     2 lines /   682 bytes
renders as:  scanned 173 files
             0 new · 0 changed · 173 unchanged · 0 B added
```

And on a run that changes a file, the file is named — the first time anything in this plugin has
named a file:

```
scan      scanned 2 files
file      modified  /tmp/lf-fixture/data/two.txt
backup    0 new, 1 changed, 1 unchanged, 1853 B added
```

## 4. `scan_finished` is the trap in this record shape

It is a `verbose_status` with an **empty `item`** and a `total_files` count:

```json
{"message_type":"verbose_status","action":"scan_finished","item":"","total_files":173}
```

A formatter that assumes every `verbose_status` names a path renders it as a file line with a blank
path. It therefore gets its own kind, and `tests/test_logfmt.py` pins the empty `item` so a restic
release that changes it breaks a test rather than the panel.

**Directory records are the other shape to know about.** restic reports directories too, with a
trailing slash in `item`, and it reports one whenever a directory's metadata changed — including the
*parents* of the backup path. This repository produced none on a quiet run; a throwaway fixture under
`/tmp` produced three every time (`/tmp/`'s mtime changes constantly). They are deliberately **not**
filtered: a new directory is real news, and the trailing slash shows it for what it is.

## 5. Interfaces that did not change

- `KEY_JOBLOG` still carries `{kind, at, ok, cancelled, exitCode, logPath}`. The `.status` routing,
  the `.jsonl` log path and the jobs sweep are untouched: `--verbose` adds message types, it does not
  remove or reorder the ones that were already there.
- `lib/restic.luau`'s `backupArgs` remains the single source of the backup argv, and
  `tests/test_restic.py`'s independent Python model of it is updated in the same commit — that
  duplication is the point of the test.
- Every log line kind that existed before still renders identically. `file` and `scan` are additions.

## 6. Verification

```bash
python3 -m unittest discover -s tests
for f in tests/lua/*.lua; do lua5.4 "$f"; done
luac -p plugin/restic-snapshots/*.luau plugin/restic-snapshots/lib/*.luau
noctalia plugins lint plugin/restic-snapshots
```

Green on `release/0.6.0`: 105 Python tests (1 skipped), all **11** Lua suites, `luac -p` parsing all
13 `.luau` files, lint `0 errors, 0 warnings`.

Two new fixtures, both **real** captures from restic 0.19.1 against a throwaway repository under
`/tmp` — a formatter tested against invented JSON is tested against nothing:

| Fixture | What it is | Why it exists |
|---|---|---|
| `backup-verbose-new.jsonl` | a first backup, every file `new` | the action a first run produces |
| `backup-verbose-modified.jsonl` | a later run with one edited file | `modified`, a quiet `unchanged`, a `scan_finished`, and directory records |

`tests/test_logfmt.py` pins both (every record carries `action` and `item`; `scan_finished` has an
empty `item` and a positive `total_files`; the fixture carries both files and directories), so a
regenerated fixture cannot quietly weaken the lua expectations.

### One production check left to the scheduler

The `.status` file was empty on every short backup reproduced during this work — including before the
change, on runs under a second — so `--verbose`'s effect on it cannot be shown from a probe. The
routing is unchanged and restic's message types are independent, but **the next scheduled backup is
the real check**: `.status` should still hold a `status` line and the Run tab should still show
progress.
