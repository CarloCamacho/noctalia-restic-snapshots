"""Tests for schedule arithmetic (mirrors lib/schedule.luau).

The Lua module is the implementation; this mirrors it so the arithmetic that decides *when* a
backup runs, *whether* a repository counts as stale and *which* slice of the repository the next
integrity check reads is pinned down numerically in a suite that runs without the shell.

Run from the repo root:  python3 -m unittest -v tests.test_schedule
"""

import unittest


def next_run(now, interval_minutes, last_run=None):
    interval = max(5, int(interval_minutes or 60)) * 60
    base = last_run if last_run is not None else now
    candidate = base + interval
    if candidate <= now:
        candidate = now + interval
    return candidate


def due(now, next_run_at):
    return next_run_at is not None and now >= next_run_at


def until_label(now, next_run_at):
    if next_run_at is None:
        return "not scheduled"
    delta = next_run_at - now
    if delta <= 0:
        return "due now"
    if delta < 60:
        return f"in {delta}s"
    if delta < 3600:
        return f"in {delta // 60}m"
    return f"in {delta // 3600}h"


def stale_threshold_hours(cfg):
    explicit = float(cfg.get("staleAfterHours") or 0)
    if explicit > 0:
        return explicit
    interval = float(cfg.get("intervalMinutes") or 60)
    return max(2 * interval / 60, 2)


def is_stale(now, newest_snapshot_at, threshold_hours):
    if newest_snapshot_at is None or threshold_hours is None or threshold_hours <= 0:
        return False
    return (now - newest_snapshot_at) > threshold_hours * 3600


def check_due(now, last_check_at, interval_hours):
    if interval_hours is None or interval_hours <= 0:
        return False
    if last_check_at is None:
        return True
    return now >= last_check_at + interval_hours * 3600


def subset_for_index(index, total):
    size = max(1, int(total or 0))
    return f"{int(index or 0) % size + 1}/{size}"


class TestNextRun(unittest.TestCase):
    def test_interval_is_at_least_five_minutes(self):
        self.assertEqual(next_run(0, 1, 0), 5 * 60)

    def test_scheduled_from_last_run(self):
        self.assertEqual(next_run(1000, 60, 1000), 1000 + 3600)

    def test_overdue_does_not_stampede(self):
        # last run long ago: schedule a full interval from now, not immediately
        self.assertEqual(next_run(100000, 60, 0), 100000 + 3600)

    def test_computed_from_last_success_not_from_now(self):
        # The next run is measured from the last *success*: a reload must not push it forward.
        now = 1_800_000_000
        last_success = now - 1200  # 20 minutes ago, interval is an hour
        self.assertEqual(next_run(now, 60, last_success), last_success + 3600)
        self.assertLess(next_run(now, 60, last_success), now + 3600)

    def test_due_boundary(self):
        self.assertFalse(due(99, 100))
        self.assertTrue(due(100, 100))
        self.assertTrue(due(101, 100))
        self.assertFalse(due(100, None))

    def test_due_against_a_catch_up_target(self):
        now = 1_800_000_000
        catch_up = now + 30  # what the service arms when a stored run is already overdue
        self.assertFalse(due(now, catch_up))
        self.assertTrue(due(now + 30, catch_up))


class TestUntilLabel(unittest.TestCase):
    def test_labels(self):
        self.assertEqual(until_label(100, None), "not scheduled")
        self.assertEqual(until_label(100, 100), "due now")
        self.assertEqual(until_label(100, 130), "in 30s")
        self.assertEqual(until_label(100, 100 + 600), "in 10m")
        self.assertEqual(until_label(100, 100 + 7200), "in 2h")

    def test_past_is_due_now(self):
        self.assertEqual(until_label(1000, 900), "due now")


class TestStaleThreshold(unittest.TestCase):
    def test_explicit_setting_wins(self):
        self.assertEqual(stale_threshold_hours({"staleAfterHours": 6, "intervalMinutes": 60}), 6)

    def test_derived_from_the_interval(self):
        # two intervals: one missed run is late, two is a missed backup
        self.assertEqual(stale_threshold_hours({"staleAfterHours": 0, "intervalMinutes": 60}), 2)
        self.assertEqual(stale_threshold_hours({"staleAfterHours": 0, "intervalMinutes": 180}), 6)

    def test_floor_of_two_hours(self):
        # a 5-minute interval must not make every repository stale within ten minutes
        self.assertEqual(stale_threshold_hours({"staleAfterHours": 0, "intervalMinutes": 5}), 2)

    def test_missing_config_is_conservative(self):
        self.assertEqual(stale_threshold_hours({}), 2)


class TestIsStale(unittest.TestCase):
    def test_fresh_is_not_stale(self):
        now = 1_800_000_000
        self.assertFalse(is_stale(now, now - 60, 2))

    def test_older_than_threshold_is_stale(self):
        now = 1_800_000_000
        self.assertTrue(is_stale(now, now - 3 * 3600, 2))

    def test_exactly_at_the_threshold_is_not_yet_stale(self):
        now = 1_800_000_000
        self.assertFalse(is_stale(now, now - 2 * 3600, 2))

    def test_unknown_newest_snapshot_is_never_stale(self):
        self.assertFalse(is_stale(1_800_000_000, None, 2))

    def test_non_positive_threshold_is_never_stale(self):
        self.assertFalse(is_stale(1_800_000_000, 0, 0))


class TestCheckDue(unittest.TestCase):
    def test_disabled_interval_is_never_due(self):
        self.assertFalse(check_due(1_800_000_000, None, 0))
        self.assertFalse(check_due(1_800_000_000, 1, None))

    def test_never_checked_is_due(self):
        self.assertTrue(check_due(1_800_000_000, None, 24))

    def test_due_after_the_interval(self):
        now = 1_800_000_000
        self.assertFalse(check_due(now, now - 3600, 24))
        self.assertTrue(check_due(now, now - 24 * 3600, 24))
        self.assertTrue(check_due(now, now - 25 * 3600, 24))


class TestSubsetForIndex(unittest.TestCase):
    def test_first_slot(self):
        self.assertEqual(subset_for_index(0, 100), "1/100")

    def test_walks_the_series(self):
        self.assertEqual(subset_for_index(1, 7), "2/7")
        self.assertEqual(subset_for_index(6, 7), "7/7")

    def test_wraps(self):
        self.assertEqual(subset_for_index(7, 7), "1/7")
        self.assertEqual(subset_for_index(107, 100), "8/100")

    def test_degenerate_total_is_one_slot(self):
        self.assertEqual(subset_for_index(0, 0), "1/1")
        self.assertEqual(subset_for_index(5, 1), "1/1")


if __name__ == "__main__":
    unittest.main()
