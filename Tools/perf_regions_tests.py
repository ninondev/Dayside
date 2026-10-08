#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# 合成内存区域只核分组与边界，不调用系统 API。
import errno
import unittest
import perf_regions as regions


def record(address=0, size=16384, tag=1, private=2, shared=1, dirty=1, swapped=0):
    return dict(address=address, size=size, user_tag=tag, pages_resident=private + shared,
                private_pages_resident=private, shared_pages_resident=shared,
                pages_shared_now_private=0, pages_dirtied=dirty, pages_swapped_out=swapped)


class RegionTests(unittest.TestCase):
    def test_grouping_preserves_tags_and_page_counters_without_footprint_claim(self):
        grouped = regions.group_regions([record(), record(16384, tag=1, private=3, dirty=2),
                                          record(32768, tag=88, private=4, shared=2, swapped=1)],
                                         {1: 'VM_MEMORY_MALLOC', 88: 'VM_MEMORY_IOSURFACE'}, 16384)
        malloc, surface = grouped['groups']
        self.assertEqual(malloc['private_resident_pages'], 5)
        self.assertEqual(malloc['shared_resident_pages'], 2)
        self.assertEqual(malloc['dirty_pages'], 3)
        self.assertEqual(malloc['virtual_bytes'], 32768)
        self.assertEqual(surface['swapped_pages'], 1)
        self.assertEqual(grouped['page_size_bytes'], 16384)
        self.assertIn('not physical footprint', grouped['scope'])
        self.assertNotIn('footprint', malloc)
        with self.assertRaises(ValueError):
            regions.group_regions([record(private=-1)], {}, 16384)

    def test_sdk_names_use_numeric_definitions_not_alias_inventions(self):
        names = regions.sdk_tags('#define VM_MEMORY_MALLOC 1\n#define VM_MEMORY_COREGRAPHICS 42\n'
                                 '#define VM_MEMORY_COREGRAPHICS_MISC VM_MEMORY_COREGRAPHICS\n'
                                 '#define VM_MEMORY_COUNT 256\n')
        self.assertEqual(names, {1: 'VM_MEMORY_MALLOC', 42: 'VM_MEMORY_COREGRAPHICS'})
        self.assertEqual(regions.group_regions([record(tag=123)], names, 4096)['groups'][0]['name'], 'unknown-tag-123')

    def test_walk_stops_on_non_progress_and_overflow(self):
        calls = []
        def stuck(cursor):
            calls.append(cursor)
            return record()
        result = regions.walk_regions(stuck)
        self.assertEqual(result['status'], 'error')
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(result['records']), 1)
        with self.assertRaises(ValueError):
            regions.region_next(record(address=regions.MAX_ADDRESS, size=1), 0)
        with self.assertRaises(ValueError):
            regions.region_next(record(size=0), 0)

    def test_walk_limit_deadline_and_permission_denial_are_explicit(self):
        calls = []
        def advancing(cursor):
            calls.append(cursor)
            return record(address=cursor, size=1)
        result = regions.walk_regions(advancing, limit=2)
        self.assertEqual(result['status'], 'partial')
        self.assertEqual(len(calls), 2)
        with self.assertRaises(ValueError):
            regions.walk_regions(advancing, limit=4097)
        ticks = iter([0, 2])
        timed = regions.walk_regions(advancing, clock=lambda: next(ticks), seconds=1)
        self.assertEqual(timed['status'], 'partial')
        denied_calls = []
        def denied(cursor):
            denied_calls.append(cursor)
            raise OSError(errno.EPERM, 'synthetic permission denial')
        denied_result = regions.walk_regions(denied)
        self.assertEqual(denied_result['status'], 'error')
        self.assertEqual(len(denied_calls), 1)
        self.assertIn('permission denial', denied_result['error'])

    def test_sdk_struct_layout_is_96_bytes_with_address_at_80(self):
        self.assertEqual(regions.ctypes.sizeof(regions.RegionInfo), 96)
        self.assertEqual(regions.RegionInfo.address.offset, 80)
        self.assertEqual(regions.RegionInfo.size.offset, 88)


if __name__ == '__main__':
    unittest.main()
