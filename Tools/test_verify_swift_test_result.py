#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import copy
import unittest
from verify_swift_test_result import execution_errors


class ExecutionReceiptTests(unittest.TestCase):
    def setUp(self):
        self.test_id = "DaysideTests/MapScrubTests/earthCopyCommandWorksInNativeFullscreen()"
        self.summary = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        self.node = {"nodeType": "Test Case", "nodeIdentifierURL": "test://com.apple.xcode/Dayside/" + self.test_id,
                     "result": "Passed", "durationInSeconds": 2.5}
        self.tree = {"testNodes": [{"children": [self.node]}]}

    def test_one_executed_exact_test_passes(self):
        self.assertEqual(execution_errors(self.summary, self.tree, self.test_id), [])

    def test_skipped_or_failed_test_cannot_count_as_success(self):
        for status in ("Skipped", "Failed", "Not Run"):
            self.node["result"] = status
            self.assertTrue(execution_errors(self.summary, self.tree, self.test_id))

    def test_empty_selection_is_rejected(self):
        self.assertTrue(execution_errors(self.summary, {"testNodes": []}, self.test_id))

    def test_same_method_in_another_target_is_rejected(self):
        self.node["nodeIdentifierURL"] = self.node["nodeIdentifierURL"].replace("DaysideTests/", "OtherTests/")
        self.assertTrue(execution_errors(self.summary, self.tree, self.test_id))

    def test_zero_duration_or_missing_counts_is_rejected(self):
        self.node["durationInSeconds"] = 0
        self.assertTrue(execution_errors(self.summary, self.tree, self.test_id))
        self.node["durationInSeconds"] = 2.5
        self.assertTrue(execution_errors({}, self.tree, self.test_id))

    def test_extra_executed_test_is_rejected(self):
        self.tree["testNodes"][0]["children"].append(copy.deepcopy(self.node))
        self.assertTrue(execution_errors(self.summary, self.tree, self.test_id))


if __name__ == "__main__":
    unittest.main()
