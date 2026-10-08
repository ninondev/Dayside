#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import unittest

import ax_check


class InputRoleTests(unittest.TestCase):
    def findings(self, **node):
        return ax_check.check_nodes([node], ())[1]

    def test_static_search_field_is_rejected_without_a_placeholder(self):
        self.assertEqual(len(self.findings(role="AXStaticText", subrole="AXSearchField")), 1)

    def test_placeholder_requires_an_editable_text_role(self):
        for key in ("placeholderValue", "placeholder"):
            for role in ("AXStaticText", "AXGroup", "AXUnknown", ""):
                with self.subTest(key=key, role=role):
                    self.assertTrue(any(kind.startswith("R7 ") for kind, _ in self.findings(
                        role=role, **{key: "Search"})))

    def test_editable_text_roles_and_ordinary_labels_are_accepted(self):
        for role in ax_check.TEXT_ENTRY:
            with self.subTest(role=role):
                self.assertEqual(self.findings(role=role, placeholderValue="Search"), [])
        self.assertEqual(self.findings(role="AXStaticText", value="City"), [])

    def test_system_nodes_do_not_hide_broken_input_roles(self):
        self.assertEqual(len(self.findings(role="AXStaticText", subrole="AXSearchField",
                                          **{"class": "NSSearchButtonCellProxy"})), 1)


if __name__ == "__main__":
    unittest.main()
