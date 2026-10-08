#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import unittest
import perf_ruler as ruler


class SurfaceProtocolTests(unittest.TestCase):
    def records(self):
        phases = ['idle', 'panel', 'panel-closed'] + ['page-' + p for p in ruler.PAGES] + [
            'settings', 'welcome', 'earth-open', 'earth-scrub', 'earth-closed', 'closed', 'closed-idle']
        events = [dict(event='ready', scenario='surfaces', protocol=1, surfaceProtocol=2,
                       mapRenderer='iosurface', places=5, people=3,
                       reduceMotion=False, fixtureHash='fixture', pages=list(ruler.PAGES))]
        samples = []
        clock = 1.0
        for phase in phases:
            duration = 60.0 if phase in ('idle', 'closed-idle') else 5.0
            metrics = dict(fp=100 * ruler.MIB, rss=150 * ruler.MIB, cpu_ns=int(clock * 1e9))
            events.append(dict(event='begin', scenario='surfaces', phase=phase, uptime=clock, metrics=metrics))
            samples.append(dict(uptime=clock, **metrics))
            if phase.startswith('page-'):
                events.append(dict(event='checkpoint', scenario='surfaces', page=phase[5:]))
            if phase == 'panel-closed':
                events.append(dict(event='checkpoint', scenario='surfaces', closedPanelBaseline=True,
                                   panelVisible=False, toolsVisible=False))
            if phase in ('panel', 'earth-open', 'earth-scrub'):
                events.append(dict(event='checkpoint', scenario='surfaces', phase=phase, visible=True,
                                   occlusionVisible=True, mapRenderer='iosurface', mapViews=1, mapSurfaces=1))
            clock += duration
            metrics = dict(fp=110 * ruler.MIB, rss=160 * ruler.MIB, cpu_ns=int(clock * 1e9))
            samples.append(dict(uptime=clock, **metrics))
            events.append(dict(event='end', scenario='surfaces', phase=phase, uptime=clock, metrics=metrics))
            clock += 1
        return events, samples

    def test_missing_surface_and_missing_page_acknowledgment_are_rejected(self):
        events, samples = self.records()
        with self.assertRaises(ValueError):
            ruler.parse_events([e for e in events if e.get('phase') != 'welcome'], samples, 'surfaces')
        with self.assertRaises(ValueError):
            ruler.parse_events([e for e in events if e.get('page') != 'sharing'], samples, 'surfaces')

    def test_surface_boundaries_keep_increment_peak_and_idle_cpu(self):
        events, samples = self.records()
        phases = ruler.parse_events(events, samples, 'surfaces')
        self.assertEqual(len(phases), 20)
        self.assertEqual(phases['panel-closed']['end_footprint_mib'], 110)
        self.assertEqual(phases['page-people']['begin_footprint_mib'], 100)
        self.assertEqual(phases['page-people']['footprint_delta_mib'], 10)
        self.assertEqual(phases['page-people']['peak_footprint_mib'], 110)
        self.assertEqual(phases['idle']['cpu_seconds_per_60s'], 60)
        self.assertIsNone(phases['page-people']['cpu_seconds_per_60s'])

    def test_old_protocol_and_missing_closed_panel_baseline_are_rejected(self):
        events, samples = self.records()
        for altered in ([dict(events[0], surfaceProtocol=1), *events[1:]],
                        [e for e in events if e.get('phase') != 'panel-closed'],
                        [e for e in events if not e.get('closedPanelBaseline')]):
            with self.assertRaises(ValueError):
                ruler.parse_events(altered, samples, 'surfaces')

    def test_open_windows_or_misplaced_closed_panel_witness_are_rejected(self):
        events, samples = self.records()
        for field in ('panelVisible', 'toolsVisible'):
            altered = [dict(e, **{field: True}) if e.get('closedPanelBaseline') else e for e in events]
            with self.assertRaises(ValueError):
                ruler.parse_events(altered, samples, 'surfaces')
        witness = next(e for e in events if e.get('closedPanelBaseline'))
        altered = [e for e in events if not e.get('closedPanelBaseline')] + [witness]
        with self.assertRaises(ValueError):
            ruler.parse_events(altered, samples, 'surfaces')

    def test_surface_summary_contains_only_measured_phases(self):
        events, samples = self.records()
        phases = ruler.parse_events(events, samples, 'surfaces')
        runs = [dict(build='new', scenario='surfaces', status='valid', phases=phases)]
        summary = ruler.aggregate(runs, 3)
        self.assertEqual(len(summary), 20)
        self.assertNotIn('surfaces/active', summary)
        self.assertIn('surfaces/panel-closed', summary)

    def test_occluded_or_missing_map_backing_is_rejected(self):
        events, samples = self.records()
        for field, value in [('occlusionVisible', False), ('mapViews', 0), ('mapSurfaces', 0),
                             ('mapSurfaces', True), ('mapRenderer', 'unknown')]:
            altered = [dict(e, **{field: value}) if e.get('event') == 'checkpoint'
                       and e.get('phase') == 'earth-open' else e for e in events]
            with self.assertRaises(ValueError):
                ruler.parse_events(altered, samples, 'surfaces')

    def test_overlapping_surface_boundaries_are_rejected(self):
        events, samples = self.records()
        start = next(i for i, e in enumerate(events) if e.get('event') == 'begin' and e.get('phase') == 'panel')
        stop = next(i for i, e in enumerate(events) if e.get('event') == 'end' and e.get('phase') == 'idle')
        shifted = list(events)
        panel_start = shifted.pop(start)
        shifted.insert(stop, panel_start)
        with self.assertRaises(ValueError):
            ruler.parse_events(shifted, samples, 'surfaces')


if __name__ == '__main__':
    unittest.main()
