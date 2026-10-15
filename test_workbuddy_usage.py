import unittest
import io
import json

from web_checkin.workbuddy_usage import fetch_usage, write_csv


class FakeResponse:
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def read(self):
        return json.dumps({
            "code": 0,
            "data": {
                "total": 1,
                "records": [{
                    "requestTime": "2026-10-10 10:00:00",
                    "requestName": "需求拆解",
                    "model": "model-a",
                    "client": "web",
                    "credit": 1.25,
                }],
            },
        }).encode("utf-8")


class WorkBuddyUsageTests(unittest.TestCase):
    def test_normalizes_request_name_and_exports_csv(self):
        records = fetch_usage(
            "2026-10-10",
            "2026-10-10",
            "cookie=test",
            opener=lambda request, timeout: FakeResponse(),
        )
        self.assertEqual(records[0]["requestName"], "需求拆解")
        output = io.StringIO()
        write_csv(records, output)
        self.assertIn("requestName", output.getvalue())
        self.assertIn("需求拆解", output.getvalue())


if __name__ == "__main__":
    unittest.main()
