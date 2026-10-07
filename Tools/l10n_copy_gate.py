#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""检查实际界面文案中的旧术语；分批施工可提供逐行范围清单。"""
import argparse
import json
import re
from pathlib import Path

import l10n_check

ZH_OLD = re.compile(r'上班时段|在休息时段|时钟调整|菜单栏面板|加入日历|共同空档|读懂了|地球窗(?!口)')
EN_OLD = re.compile(r'working hours|Shared Availability|Sun & Moon|Find a Time|\bDST\b|Copy Picture', re.IGNORECASE)
LOCATION_KEYS = {
    '写信人那边（先按你这里算）', '所在地', '请选择所在地。', '地点：%@',
    '无法保存文件。请选择可写入的位置后重试。',
    '拿到名片的人都能看到上面写的，包括城市名和大致位置。可约时段是你未来 14 天的作息，不查日历，也不经过任何服务器。',
    '记录同事与家人的所在地和作息，随时看当地时间和是否在上班。',
    '记录同事与家人的所在地和作息，随时看当地时间和是否在上班。点「添加人物」开始。',
}


def values(node):
    if isinstance(node, dict):
        if 'stringUnit' in node:
            yield node['stringUnit']['value']
        for key, item in node.items():
            if key != 'stringUnit':
                yield from values(item)


def findings(catalog, keys):
    result = []
    for key in sorted(keys & catalog['strings'].keys()):
        entry = catalog['strings'][key]
        for language, pattern in [('zh-Hans', ZH_OLD), ('en', EN_OLD)]:
            for value in values(entry.get('localizations', {}).get(language, {})):
                if pattern.search(value):
                    result.append((key, language, value))
                if language == 'zh-Hans' and '移除' in value and re.search(r'人物|行程|固定时刻|假期', key):
                    result.append((key, language, value))
                if language == 'en' and re.search(r'\blocation\b', value, re.IGNORECASE) and key not in LOCATION_KEYS:
                    result.append((key, language, value))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, default=l10n_check.CATALOG)
    parser.add_argument('--scope', type=Path)
    args = parser.parse_args()
    catalog = json.loads(args.catalog.read_text())
    files = {p: text for p, text in l10n_check.sources().items() if 'Tests' not in str(p.relative_to(l10n_check.ROOT))}
    keys = l10n_check.referenced_keys(list(catalog['strings']), files)
    deferred = set()
    if args.scope:
        scope = json.loads(args.scope.read_text())
        rows = scope['rows'] + scope.get('header_rows', [])
        deferred = {r['key'] for r in rows if r['status'].startswith('deferred')}
        # 被开放分支删除的帮助文案随该分支保留到下一批。
        for row in scope.get('retired_paragraphs', []):
            if row.get('defer_branches'):
                deferred.update(row.get('resolution', []))
        keys -= deferred
    errors = findings(catalog, keys)
    for key, language, value in errors:
        print(f'{language} {key}: {value}')
    print(f'文案残留检查：{len(keys)} 个界面键，{len(errors)} 条问题；延期 {len(deferred)} 个键')
    return bool(errors)


if __name__ == '__main__':
    raise SystemExit(main())
