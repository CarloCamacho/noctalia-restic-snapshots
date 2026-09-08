"""Tests for schedule arithmetic (mirrors lib/schedule.luau).

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


class TestNextRun(unittest.TestCase):
    def test_interval_is_at_least_five_minutes(self):
        self.assertEqual(next_run(0, 1, 0), 5 * 60)

    def test_scheduled_from_last_run(self):
        self.assertEqual(next_run(1000, 60, 1000), 1000 + 3600)

    def test_overdue_does_not_stampede(self):
        # last run long ago: schedule a full interval from now, not immediately
        self.assertEqual(next_run(100000, 60, 0), 100000 + 3600)

    def test_due_boundary(self):
        self.assertFalse(due(99, 100))
        self.assertTrue(due(100, 100))
        self.assertTrue(due(101, 100))
        self.assertFalse(due(100, None))


class TestUntilLabel(unittest.TestCase):
    def test_labels(self):
        self.assertEqual(until_label(100, None), "not scheduled")
        self.assertEqual(until_label(100, 100), "due now")
        self.assertEqual(until_label(100, 130), "in 30s")
        self.assertEqual(until_label(100, 100 + 600), "in 10m")
        self.assertEqual(until_label(100, 100 + 7200), "in 2h")


if __name__ == "__main__":
    unittest.main()
