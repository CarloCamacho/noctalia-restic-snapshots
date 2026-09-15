"""Fixture sanity for the job-log formatter (tests/lua/logfmt_test.lua).

`tests/lua/logfmt_test.lua` asserts what `plugin/restic-snapshots/lib/logfmt.luau` makes of the
captures in `tests/fixtures/`. Those assertions are only as strong as the fixtures themselves: if
`backup-progress.jsonl` were regenerated with a single status line, the lua check "the two folded
status lines are counted" would still pass -- against a log that no longer exercises folding at all
-- and nothing would say so. This module pins the properties the lua expectations rest on, so a
fixture can only change deliberately.

It also checks that the lua suite still reads every fixture: a renamed file would otherwise turn a
suite into a no-op that reports success.

Run from the repo root:  python3 -m unittest -v tests.test_logfmt
"""

import json
import pathlib
import unittest

REPO = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = REPO / "tests" / "fixtures"
LUA_SUITE = REPO / "tests" / "lua" / "logfmt_test.lua"

JSONL_FIXTURES = [
    "backup-summary.jsonl",
    "backup-progress.jsonl",
    "backup-unchanged.jsonl",
    "backup-verbose-new.jsonl",
    "backup-verbose-modified.jsonl",
    "check-summary.jsonl",
    "error.jsonl",
    "ls-list.jsonl",
    "ls-real.jsonl",
]


def raw(name):
    return (FIXTURES / name).read_bytes()


def message_types(name):
    """How many records of each message_type the fixture carries."""
    counts = {}
    for record in records(name):
        key = record.get("message_type", "?")
        counts[key] = counts.get(key, 0) + 1
    return counts


def actions(name):
    """The distinct verbose_status actions in the fixture."""
    return {record["action"] for record in records(name) if "action" in record}


def records(name):
    """The fixture's JSON objects, one per line. Fails loudly rather than skipping a bad line."""
    out = []
    for number, line in enumerate((FIXTURES / name).read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError as error:  # pragma: no cover - the failure is the assertion
            raise AssertionError(f"{name}:{number} is not JSON: {error}") from error
    return out


class TestVerboseFixtures(unittest.TestCase):
    """`backup --json --verbose` (0.6.0): one verbose_status per file and per directory.

    Captured on restic 0.19.1 against a throwaway repository under /tmp -- `-new` is a first backup,
    `-modified` is a later run with one edited file. These fixtures exist because without --verbose a
    backup log is the single 473-byte summary above, which left the Log tab with nothing to show.

    The formatter reads exactly two fields from each of these records, `action` and `item`, so both
    are pinned here: a restic release that renamed either would otherwise turn the lua expectations
    into assertions about a `nil`.
    """

    NAMES = ("backup-verbose-new.jsonl", "backup-verbose-modified.jsonl")

    def test_every_verbose_record_carries_the_two_fields_the_formatter_reads(self):
        for name in self.NAMES:
            for index, record in enumerate(records(name), start=1):
                if record["message_type"] != "verbose_status":
                    continue
                self.assertIn("action", record, f"{name}:{index}")
                self.assertIn("item", record, f"{name}:{index}")
                self.assertIsInstance(record["action"], str, f"{name}:{index}")
                self.assertIsInstance(record["item"], str, f"{name}:{index}")

    def test_the_new_fixture_is_a_first_backup(self):
        self.assertEqual(message_types("backup-verbose-new.jsonl")["summary"], 1)
        seen = actions("backup-verbose-new.jsonl")
        self.assertIn("new", seen)
        self.assertNotIn("modified", seen)

    def test_the_modified_fixture_has_a_changed_file_a_quiet_one_and_a_scan(self):
        self.assertEqual(message_types("backup-verbose-modified.jsonl")["summary"], 1)
        seen = actions("backup-verbose-modified.jsonl")
        self.assertIn("modified", seen)
        self.assertIn("unchanged", seen)
        self.assertIn("scan_finished", seen)

    def test_scan_finished_carries_no_item_and_a_file_count(self):
        """Why the formatter may not assume every verbose record names a path."""
        scans = [
            record for record in records("backup-verbose-modified.jsonl")
            if record.get("action") == "scan_finished"
        ]
        self.assertEqual(len(scans), 1, "one scan per run")
        self.assertEqual(scans[0]["item"], "", "scan_finished names no file")
        self.assertGreater(scans[0]["total_files"], 0)

    def test_the_modified_fixture_carries_both_files_and_directories(self):
        """Directories are reported too, with a trailing slash; the formatter shows them as they are."""
        items = [
            record["item"] for record in records("backup-verbose-modified.jsonl")
            if record.get("action") == "modified"
        ]
        self.assertTrue(any(item.endswith("/") for item in items), items)
        self.assertTrue(any(not item.endswith("/") for item in items), items)


class TestBackupFixtures(unittest.TestCase):
    def test_summary_fixture_is_the_real_one_line_log(self):
        """The 473-byte single line the contract diagnoses: one summary, nothing else."""
        text = raw("backup-summary.jsonl")
        self.assertEqual(len(text), 473, "the contract's evidence is a 473-byte log file")
        self.assertEqual(len(text.splitlines()), 1, "the whole job log is ONE line")
        summary = records("backup-summary.jsonl")[0]
        self.assertEqual(summary["message_type"], "summary")
        self.assertEqual(summary["files_unmodified"], 173)
        self.assertEqual(summary["total_bytes_processed"], 860367)
        self.assertAlmostEqual(summary["total_duration"], 1.167760836)

    def test_summary_carries_every_field_the_backup_line_reads(self):
        """The lua `backup` line reads exactly these; a dropped key must break this test."""
        summary = records("backup-summary.jsonl")[0]
        for field in (
            "files_new", "files_changed", "files_unmodified", "dirs_new", "dirs_changed",
            "data_added", "total_bytes_processed", "total_duration",
        ):
            with self.subTest(field=field):
                self.assertIn(field, summary)

    def test_progress_fixture_has_three_status_lines_and_one_summary(self):
        """'collapsed == 2' is only meaningful while there are 3 status lines and 1 summary."""
        kinds = [record["message_type"] for record in records("backup-progress.jsonl")]
        self.assertEqual(kinds.count("status"), 3, kinds)
        self.assertEqual(kinds.count("summary"), 1, kinds)
        self.assertEqual(len(kinds), 4, kinds)
        self.assertEqual(kinds[-1], "summary", "the summary is the last line")

    def test_progress_numbers_are_what_the_lua_assertions_assume(self):
        statuses = [record for record in records("backup-progress.jsonl")
                    if record["message_type"] == "status"]
        last = statuses[-1]
        self.assertAlmostEqual(last["percent_done"], 0.8425)
        self.assertEqual(last["files_done"], 3362)
        self.assertEqual(last["total_files"], 4000)
        self.assertEqual(last["bytes_done"], 220856320)
        self.assertEqual(last["total_bytes"], 262144000)
        # ...and the earlier lines differ, so "the LAST status line is the one shown" is a real
        # assertion rather than an accident of two identical records.
        self.assertNotEqual(statuses[0]["files_done"], last["files_done"])
        self.assertNotEqual(statuses[0]["bytes_done"], last["bytes_done"])

    def test_progress_summary_numbers(self):
        summary = [record for record in records("backup-progress.jsonl")
                   if record["message_type"] == "summary"][0]
        self.assertEqual(summary["files_new"], 4000)
        self.assertEqual(summary["dirs_new"], 6)
        self.assertAlmostEqual(summary["total_duration"], 1.069303796)

    def test_unchanged_fixture(self):
        summary = records("backup-unchanged.jsonl")[0]
        self.assertEqual(summary["files_unmodified"], 4000)
        self.assertEqual(summary["data_added"], 358)
        self.assertAlmostEqual(summary["total_duration"], 0.750548185)


class TestCheckAndErrorFixtures(unittest.TestCase):
    def test_check_summary_shape(self):
        summary = records("check-summary.jsonl")[0]
        self.assertEqual(summary["message_type"], "summary")
        self.assertEqual(summary["num_errors"], 0)
        self.assertIsNone(summary["broken_packs"],
                          "null must stay null: the lua check asserts a missing value is absent, "
                          "not zero")
        self.assertIs(summary["suggest_repair_index"], False)
        self.assertIs(summary["suggest_prune"], False)
        self.assertNotIn("files_new", summary, "a check summary has no backup fields")

    def test_error_record_shape(self):
        record = records("error.jsonl")[0]
        self.assertEqual(record["message_type"], "error")
        self.assertEqual(record["code"], 10)
        self.assertIn("error", record)
        self.assertEqual(
            record["error"]["message"],
            "Fatal: unable to open config file: stat /tmp/nope/config: no such file or directory",
        )


class TestTextAndRecordFixtures(unittest.TestCase):
    def test_hooks_text_is_two_markers_and_two_outputs(self):
        lines = (FIXTURES / "hooks.txt").read_text(encoding="utf-8").splitlines()
        self.assertEqual(lines, [
            "== pre-backup command ==",
            "database dump written to /tmp/dump.sql",
            "== post-backup command ==",
            "pruned 3 old dumps",
        ])

    def test_ls_list_is_forty_record_objects(self):
        """'one records line counting 40, not 40 lines' -- so the fixture must have 40 records."""
        rows = records("ls-list.jsonl")
        self.assertEqual(len(rows), 40)
        struct_types = [row.get("struct_type") for row in rows]
        self.assertEqual(struct_types.count("snapshot"), 1, "one snapshot header")
        self.assertEqual(struct_types.count("node"), 39, "one node per entry")
        self.assertEqual(set(struct_types), {"snapshot", "node"},
                         "the record shapes the formatter folds are exactly these")
        self.assertEqual(rows[0]["message_type"], "snapshot",
                         "the ls stream starts with the snapshot header")

    def test_ls_real_is_thirty_lines(self):
        self.assertEqual(len(records("ls-real.jsonl")), 30)


class TestFixtureHygiene(unittest.TestCase):
    def test_every_jsonl_line_is_a_json_object(self):
        for name in JSONL_FIXTURES:
            for index, row in enumerate(records(name)):
                with self.subTest(fixture=name, line=index):
                    self.assertIsInstance(row, dict)

    def test_no_fixture_carries_a_blank_line(self):
        """The formatter counts a blank line as folded, so a blank would move `collapsed`."""
        for name in JSONL_FIXTURES:
            with self.subTest(fixture=name):
                self.assertNotIn(b"\n\n", raw(name))
                self.assertFalse(raw(name).startswith(b"\n"))

    def test_every_fixture_ends_with_exactly_one_newline(self):
        """restic terminates each JSON line; the formatter must not invent a line out of that.

        The lua suite counts `raw` lines and `collapsed`, so both a missing and a doubled final
        newline would be visible there -- this is the fixture side of that contract.
        """
        for name in JSONL_FIXTURES + ["hooks.txt"]:
            with self.subTest(fixture=name):
                text = raw(name).decode("utf-8")
                self.assertTrue(text.endswith("\n"), f"{name} does not end with a newline")
                self.assertFalse(text.endswith("\n\n"), f"{name} ends with a blank line")


class TestTheLuaSuiteUsesThem(unittest.TestCase):
    def test_the_lua_suite_exists(self):
        self.assertTrue(LUA_SUITE.is_file(), f"{LUA_SUITE} is missing")

    def test_the_lua_suite_reads_every_fixture(self):
        source = LUA_SUITE.read_text(encoding="utf-8")
        for name in JSONL_FIXTURES + ["hooks.txt"]:
            with self.subTest(fixture=name):
                self.assertIn(name, source,
                              f"tests/lua/logfmt_test.lua no longer reads {name}: its assertions "
                              f"about real captures would silently stop running")


if __name__ == "__main__":
    unittest.main()
