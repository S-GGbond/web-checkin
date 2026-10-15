import unittest
from types import SimpleNamespace
from unittest.mock import patch

from web_checkin.trae_usage import date_range_timestamps, query_account


class FakeTrae:
    def __init__(self, pages):
        self.pages = pages
        self.calls = []
        self.saved = []

    def _load_auth(self, _row):
        return {"token": "test"}

    def _post(self, _row, _auth, path, body, *, header_overrides=None):
        self.calls.append((path, body, header_overrides))
        return self.pages.pop(0)

    def _save_auth(self, row, auth):
        self.saved.append((row["id"], auth.copy()))


def record(timestamp, credits, model="model-a"):
    return {
        "usage_time": timestamp,
        "credits_float": credits,
        "model_name": model,
        "usage_source": 0,
        "extra_info": {"input_token": 12, "output_token": 3},
    }


class TraeUsageTests(unittest.TestCase):
    def setUp(self):
        self.row = {
            "id": 7,
            "external_id": "user-7",
            "display_name": "测试账号",
            "label": "",
        }

    def test_date_range_uses_inclusive_shanghai_days(self):
        start, end, days = date_range_timestamps("2026-10-03", "2026-10-04")
        self.assertEqual(days, ["2026-10-03", "2026-10-04"])
        self.assertEqual(end - start + 1, 2 * 86400)

    def test_rejects_reversed_and_oversized_ranges(self):
        with self.assertRaises(ValueError):
            date_range_timestamps("2026-10-05", "2026-10-04")
        with self.assertRaises(ValueError):
            date_range_timestamps("2026-01-01", "2026-04-03")

    def test_paginates_and_aggregates_daily_and_model_usage(self):
        stamp = 1790960400
        fake = FakeTrae([
            (200, {"total": 2, "user_usage_group_by_sessions": [record(stamp, 1.25)]}),
            (200, {"total": 2, "user_usage_group_by_sessions": [record(stamp + 3600, 2.5, "model-b")]}),
        ])
        with patch("web_checkin.trae_usage.time.sleep"):
            result = query_account(fake, self.row, "2026-10-03", "2026-10-03", page_size=1)
        self.assertEqual([call[1]["page_num"] for call in fake.calls], [1, 2])
        self.assertEqual(fake.calls[0][1]["usage_type"], [7])
        self.assertEqual(fake.calls[0][1]["page_size"], 1)
        self.assertEqual(fake.calls[0][2], {"x-ide-version-code": "20260401"})
        self.assertEqual(result["totalCredits"], 3.75)
        self.assertEqual(result["requestCount"], 2)
        self.assertEqual(result["daily"][0]["requests"], 2)
        self.assertEqual(result["models"][0]["model"], "model-b")
        self.assertEqual(result["items"][0]["tokens"]["input"], 12)
        self.assertEqual(fake.saved[0][0], 7)

    def test_saves_refreshed_auth_even_when_request_fails(self):
        fake = FakeTrae([(401, {"message": "unauthorized"})])
        with self.assertRaisesRegex(RuntimeError, "查询用量失败"):
            query_account(fake, self.row, "2026-10-03", "2026-10-03")
        self.assertEqual(len(fake.saved), 1)


if __name__ == "__main__":
    unittest.main()
