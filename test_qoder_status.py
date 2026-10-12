import unittest

from qoder_tool import QoderTool


class QoderStatusTests(unittest.TestCase):
    def test_no_campaign_is_not_checked(self):
        status = QoderTool._activity_status([])
        self.assertEqual(status, {
            "campaignCount": 0,
            "claimableCount": 0,
            "claimedCount": 0,
            "checked": False,
        })

    def test_claimable_is_not_checked(self):
        status = QoderTool._activity_status([{"claimStatus": "CLAIMABLE"}])
        self.assertEqual(status, {
            "campaignCount": 1,
            "claimableCount": 1,
            "claimedCount": 0,
            "checked": False,
        })

    def test_only_claimed_is_checked(self):
        status = QoderTool._activity_status([
            {"claimStatus": "CLAIMED"},
            {"claimStatus": "FINISHED"},
        ])
        self.assertEqual(status, {
            "campaignCount": 2,
            "claimableCount": 0,
            "claimedCount": 1,
            "checked": True,
        })


if __name__ == "__main__":
    unittest.main()
