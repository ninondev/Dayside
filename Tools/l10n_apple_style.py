#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# -*- coding: utf-8 -*-
"""
l10n_apple_style.py — 按 Apple 官方本地化风格指南对十语字符串目录做机械修正与术语统一。

依据：
  * Xcode 27 随带的 Apple 十语风格指南
    /Applications/Xcode.app/Contents/PlugIns/IDEXCStringsSupport.framework/Versions/A/Resources/
    Skills/translation/references/styleguide_<lang>.md.packaged
  * macOS 自带 App 的 .loctable（时钟 / 日历 / 天气 / WeatherKit / 系统设置各扩展）
  * 本项目的约定：
    中文 / 日文数字与单位之间不留空格；术语全按 Apple 官方译法。

只改各语言的 stringUnit.value（含复数变体），**从不改键**；占位符（%lld / %@ / %1$@ / %#@x@）、
${applicationName}、URL、IANA 标识符原样保留。读写 JSON 用 ensure_ascii=False, indent=2，键顺序不变，
与 Xcode 写出的文件逐字节一致。每条规则可单独开关，可反复运行（幂等）。

用法：
  python3 Tools/l10n_apple_style.py                       # 应用全部默认规则，改写四份目录
  python3 Tools/l10n_apple_style.py --dry-run --report /tmp/r.md
  python3 Tools/l10n_apple_style.py --only cjk-quotes,ja-punct
  python3 Tools/l10n_apple_style.py --skip pt-title-case
  python3 Tools/l10n_apple_style.py --skip cjk-latin-space      # 关掉某条默认开的规则
  python3 Tools/l10n_apple_style.py --terms-report /tmp/terminology-report.md
  python3 Tools/l10n_apple_style.py --list-rules
"""

import argparse
import collections
import datetime
import json
import os
import random
import re
import subprocess
import sys
from types import SimpleNamespace

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULT_FILES = [
    'Dayside/Resources/Localizable.xcstrings',
    'Dayside/Resources/InfoPlist.xcstrings',
    'Dayside/Resources/AppShortcuts.xcstrings',
    'Dayside/Resources/ServicesMenu.xcstrings',
]

LANGS = ['zh-Hans', 'zh-Hant', 'en', 'ja', 'ko', 'de', 'es', 'fr', 'ru', 'pt-BR']

NBSP = '\u00a0'

# ---------------------------------------------------------------------------
# 字符类
# ---------------------------------------------------------------------------

# 汉字 / 假名 / 々（U+3005）。不含全角标点：数字与「，」之间的空格不归这条管。
CJK = '\u3005\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff'
CJKC = '[' + CJK + ']'
LATIN = 'A-Za-z\u00c0-\u024f'
# 数字占位符：%lld %ld %d %u %.1f %2$lld …
NUM_PH = r'%(?:\d+\$)?(?:lld|ld|lu|zd|d|u|i|\.\d*f|f)'
# 对象占位符：%@ %1$@
OBJ_PH = r'%(?:\d+\$)?@'
# 数字：钟点「9:00」「14:00」「9am」整体当一个记号（后面按钟点豁免）；不能从另一个数字中间开始。
NUM = r'(?<![\d:.,])(?:\d+(?::\d+)+(?:am|pm)?|\d+(?:am|pm)|\d+(?:[.,]\d+)*)'


def is_clock(tok):
    """「9:00」「14:00」「9am」「3:30pm」这类是输入示例或钟点，两侧空格不动。"""
    return re.fullmatch(r'\d+(?::\d+)+(?:am|pm)?|\d+(?:am|pm)', tok, re.I) is not None


# ---------------------------------------------------------------------------
# 规则 1：中文 / 日文里数字与汉字、假名之间不留空格
# ---------------------------------------------------------------------------

def rule_cjk_number_space(v, ctx):
    latin_mode = ctx.latin_mode

    def left(m):  # 汉字 + 空格 + 数字 → 去空格（「未来 7 天」的左边）
        tok = m.group(3)
        if is_clock(tok):
            return m.group(0)
        return m.group(1) + tok

    v = re.sub(r'(%s)( +)(%s|%s)' % (CJKC, NUM_PH, NUM), left, v)

    def right(m):  # 数字 + 空格 + 汉字 → 去空格（「7 天」「%lld 分钟」）
        tok = m.group(1)
        if is_clock(tok):
            return m.group(0)
        if not latin_mode and tok[0].isdigit():
            # 数字若是拉丁短语的一部分（「CC BY 4.0 许可」「ISO 8601 をコピー」「macOS 26 以上」），
            # 空格归「汉字与拉丁词之间」那条规则管，这里不动。
            prev = re.search(r'(\S+)$', m.string[:m.start()].rstrip(' '))
            if prev and re.search('[%s]' % LATIN, prev.group(1)):
                return m.group(0)
        return tok + m.group(3)

    v = re.sub(r'(%s|%s)( +)(%s)' % (NUM_PH, NUM, CJKC), right, v)
    return v


CJK_PUNCT = '。，、；：？！）】」』”’'


def rule_cjk_placeholder_space(v, ctx):
    """%@ 嵌在中文 / 日文句子里时两侧不留空格（「从 %@ 起」→「从%@起」、「%@ の時間帯」→「%@の時間帯」、
    「变为 %@。」→「变为%@。」）。只处理句中的 %@（后面紧跟汉字 / 假名或全角标点）；
    「添加 %@」「共同时段 %1$@ %2$@」这种 %@ 后面是句尾或空格的不动（Apple 自己的「在“新闻”中打开 %@」也留空格）。"""
    v = re.sub(r'(%s)( +)(%s)' % (OBJ_PH, CJKC), r'\1\3', v)
    v = re.sub(r'(%s)( +)(%s)(?=%s|[%s])' % (CJKC, OBJ_PH, CJKC, CJK_PUNCT), r'\1\3', v)
    return v


def rule_cjk_latin_space(v, ctx):
    """（默认开启）汉字与拉丁词之间也不留空格——Apple zh-Hant / ja 指南明文「No Space Between Chinese/Japanese and Latin」，
    本机 Apple 界面串实测 zh-Hans 397 : 1、zh-Hant 413 : 1、ja 457 : 0 都不留；此规则默认开启，会改变现有排版；可用 `--skip cjk-latin-space` 保留空格。"""
    v = re.sub(r'(%s) +(?=[%s])' % (CJKC, LATIN), r'\1', v)

    def right(m):
        tok = m.group(1)
        if is_clock(tok):
            return m.group(0)
        return tok + m.group(3)

    v = re.sub(r'([%s][^\s%s]*)( +)(%s)' % (LATIN, CJK, CJKC), right, v)
    return v


# ---------------------------------------------------------------------------
# 规则 2：zh-Hans / ja 引号「」→ “ ”（Apple 两份指南；zh-Hant 台湾版保留「」）
# ---------------------------------------------------------------------------

QUOTE_MAP = str.maketrans({'「': '\u201c', '」': '\u201d', '『': '\u2018', '』': '\u2019'})


def rule_cjk_quotes(v, ctx):
    v = v.translate(QUOTE_MAP)
    if ctx.lang == 'ja':
        # ja 指南：右引号后紧跟半角字符时补一个半角空格（“%1$@” POPサーバ）。
        v = re.sub(r'\u201d(?=[A-Za-z0-9])', '\u201d ', v)
    return v


def rule_ko_quotes(v, ctx):
    """ko 指南：界面元素引用用 ‘ ’，不用「」。顺手补上句号后漏掉的空格（「합니다.‘」→「합니다. ‘」）。"""
    v = v.translate(str.maketrans({'「': '\u2018', '」': '\u2019'}))
    v = re.sub(r'(다\.)(?=[^\s.)\u2019\u201d])', r'\1 ', v)
    return v


# ---------------------------------------------------------------------------
# 规则 3：ja 标点与固定译法
# ---------------------------------------------------------------------------

def rule_ja_punct(v, ctx):
    """ja 指南：冒号 / 问号 / 叹号一律半角；后面还有文字时补一个半角空格。"""
    v = re.sub(r'\uff1a(?=\S)', ': ', v)
    v = v.replace('\uff1a', ':')
    v = re.sub(r'\uff1f(?=\S)', '? ', v)
    v = v.replace('\uff1f', '?')
    v = re.sub(r'\uff01(?=\S)', '! ', v)
    v = v.replace('\uff01', '!')
    return v


JA_TERMS = [
    ('やり直してください', 'やり直してみてください'),      # 指南定译「Try again」
    ('もう一度お試しください', 'やり直してみてください'),  # 指南明令不用
    ('日の入り', '日の入'),                               # Apple 时钟 / 天气都不送り「り」
    ('名称を変更', '名称変更'),                            # Shortcuts「Rename」
]


def rule_ja_terms(v, ctx):
    for old, new in JA_TERMS:
        v = v.replace(old, new)
    return v


# 时区：タイムゾーン → 時間帯（Apple 系统设置 / 日历 / 支持页一律 時間帯）。
# 现有的 時間帯 表示「时段」，先按语境改成 時間枠 等，再把 タイムゾーン 换过来。
# 幂等设计：键含「时区」的串只做显式表里的替换；键不含「时区」但含时段类词的串才做通用 時間帯→時間枠；
# タイムゾーンカード（时间名片）是功能名，保留待母语者定。
JA_ZONE_KEEP = ['タイムゾーンカード', 'のような時間帯の言い方']   # 原样保留的片段
JA_SLOT_SPECIFIC = [                                       # 先于通用替换、按语境定的写法
    ('この睡眠時間帯は', 'この睡眠時間は'),
    ('最初の候補時間帯へ', '最初の候補へ'),
    ('の時間帯は存在しません', 'の時間は存在しません'),
    ('光を浴びる時間帯は', '光を浴びる時間は'),
    ('選択可能な時間帯', '選択可能な範囲'),
]
JA_SLOT_IN_ZONE_KEYS = [                                   # 键里同时有「时区」与「时段」的串，只换这些片段
    ('の時間帯が1時間', 'の時間枠が1時間'),
    ('の時間帯が 1 時間', 'の時間枠が 1 時間'),
    ('時間帯は「13:00–15:00」', '時間枠は「13:00–15:00」'),
    ('時間帯は\u201c13:00–15:00\u201d', '時間枠は\u201c13:00–15:00\u201d'),
]
JA_SLOT_KEY_WORDS = ('时段', '范围', '作息', '跨午夜', '这段', '空档', '光照')


def rule_ja_timezone(v, ctx):
    original = v
    keep = {}
    for i, frag in enumerate(JA_ZONE_KEEP):
        token = '\ue000%d\ue001' % i
        if frag in v:
            v = v.replace(frag, token)
            keep[token] = frag
    key = ctx.key or ''
    if '时区' in key:
        for old, new in JA_SLOT_IN_ZONE_KEYS:
            v = v.replace(old, new)
    elif any(w in key for w in JA_SLOT_KEY_WORDS):
        for old, new in JA_SLOT_SPECIFIC:
            v = v.replace(old, new)
        v = v.replace('時間帯', '時間枠')
    v = v.replace('タイムゾーン', '時間帯')
    for token, frag in keep.items():
        v = v.replace(token, frag)
    if v != original:
        ctx.notes.append(('ja-timezone', ctx.file, ctx.key, ctx.lang, ctx.variation, original, v))
    return v


# ---------------------------------------------------------------------------
# 规则 4：fr 标点前不换行空格、« » 内侧不换行空格、弯撇号、Évènement
# ---------------------------------------------------------------------------

def rule_fr_nbsp(v, ctx):
    v = re.sub(r' +([?;:!])', NBSP + r'\1', v)          # 普通空格 → U+00A0
    v = re.sub(r'\u00ab +', '\u00ab' + NBSP, v)
    v = re.sub(r'\u00ab(?=[^\s])', '\u00ab' + NBSP, v)   # « 后没有空格也补
    v = re.sub(r' +\u00bb', NBSP + '\u00bb', v)
    v = re.sub(r'(?<=[^\s])\u00bb', NBSP + '\u00bb', v)
    return v


def rule_fr_apostrophe(v, ctx):
    return re.sub(r"(?<=[%s])'(?=[%s])" % (LATIN, LATIN), '\u2019', v)


FR_TERMS = [
    ('Événement', 'Évènement'),           # Apple 用 1990 拼写
    ('événement', 'évènement'),
    ('Ouvrir à la connexion', 'Ouvrir avec la session'),   # 系统设置「登录项」面板
]


def rule_fr_terms(v, ctx):
    for old, new in FR_TERMS:
        v = v.replace(old, new)
    return v


# ---------------------------------------------------------------------------
# 规则 5：de 省略号前不换行空格；Termin → Ereignis（Apple 日历）；Darstellung → Erscheinungsbild
# ---------------------------------------------------------------------------

def rule_de_ellipsis(v, ctx):
    """de 指南：省略号表示过程或后续对话框，前面一律不换行空格（「Laden …」）。只处理串尾的省略号，
    Apple 自己的「%@…%@」「…\u00a0%@」不在此列。"""
    return re.sub(r'([^\s%@\u2026]) *\u2026$', r'\1' + NBSP + '\u2026', v)


DE_TERMIN_EXCLUDE_KEYS = {
    # 这三条里的 Termin 指例会的「每一次」，不是日历里的 Ereignis 对象，留给母语者定。
    '按各人的工作时段安排：每次会议另选一个时刻，让工作时段外的时间轮流分担；有人休息的那次跳过。',
    '按各人的工作时段安排：每次会议另选一个时刻，让工作时段外的负担尽量均摊；有人休息的那次跳过。',
    '这几次都排不出时刻：有人休息，或没有时刻能让所有人在上限内。可以提高上限。',
    '每次都有所有人在工作时段内的时刻，不需要轮换。下面是每次最合适的时刻。',
}
DE_TERMIN = [  # 名词换了性（der Termin → das Ereignis），冠词与形容词词尾一起换
    (r'\bNächster Termin\b', 'Nächstes Ereignis'),
    (r'\bNächsten Termin\b', 'Nächstes Ereignis'),
    (r'\bUnbenannter Termin\b', 'Unbenanntes Ereignis'),
    (r'\bDieser Termin\b', 'Dieses Ereignis'),
    (r'\bDiesen Termin\b', 'Dieses Ereignis'),
    (r'\bdiesen Termin\b', 'dieses Ereignis'),
    (r'\bJeder Termin\b', 'Jedes Ereignis'),
    (r'\bjeder Termin\b', 'jedes Ereignis'),
    (r'\bjeden Termin\b', 'jedes Ereignis'),
    (r'\bKeinen Termin\b', 'Kein Ereignis'),
    (r'\bkeinen Termin\b', 'kein Ereignis'),
    (r'\bEinen Termin\b', 'Ein Ereignis'),
    (r'\beinen Termin\b', 'ein Ereignis'),
    (r'\bdes Termins\b', 'des Ereignisses'),
    (r'\bTermins\b', 'Ereignisses'),
    (r'\bTerminen\b', 'Ereignissen'),
    (r'\bTermine\b', 'Ereignisse'),
    (r'\bTermin\b', 'Ereignis'),
]


def rule_de_terms(v, ctx):
    if ctx.key not in DE_TERMIN_EXCLUDE_KEYS:
        for pat, rep in DE_TERMIN:
            v = re.sub(pat, rep, v)
    elif re.search(r'\bTermin', v):
        ctx.notes.append(('de-termin-skipped', ctx.file, ctx.key, ctx.lang, ctx.variation, v, v))
    if ctx.key == '外观' and v == 'Darstellung':
        v = 'Erscheinungsbild'                       # 系统设置「外观」面板名
    v = v.replace('Bei Anmeldung öffnen', 'Bei der Anmeldung öffnen')   # 「登录项」面板
    return v


# ---------------------------------------------------------------------------
# 规则 6：ru 大写 Вы / Ваш；设置「外观」→ Оформление
# ---------------------------------------------------------------------------

RU_VY = re.compile(r'\b(вы|вас|вам|вами|ваш|ваша|ваше|ваши|вашего|вашей|вашему|ваших|вашим|вашими|вашу)\b')


def rule_ru_vy(v, ctx):
    """ru 指南：对用户称呼用大写 Вы 及其变格（俄罗斯科学院批准的写法）。"""
    return RU_VY.sub(lambda m: m.group(1)[0].upper() + m.group(1)[1:], v)


def rule_ru_terms(v, ctx):
    if ctx.key == '外观' and v == 'Внешний вид':
        return 'Оформление'
    return v


# ---------------------------------------------------------------------------
# 规则 7：pt-BR 短串 Title Case（跟随英文源串的大小写：英文是 Title Case 的标签 / 按钮 / 菜单项才改）；
#         Temporizador → Timer；登录项句
# ---------------------------------------------------------------------------

EN_SMALL = {'a', 'an', 'the', 'and', 'or', 'but', 'nor', 'to', 'of', 'in', 'on', 'at', 'by', 'for',
            'from', 'with', 'as', 'per', 'vs', 'via', 'into', 'onto', 'over', 'up'}
PT_SMALL = {'a', 'o', 'as', 'os', 'e', 'ou', 'de', 'da', 'do', 'das', 'dos', 'em', 'no', 'na', 'nos', 'nas',
            'com', 'para', 'por', 'ao', 'à', 'às', 'aos', 'um', 'uma', 'sem', 'sob', 'pelo', 'pela', 'que',
            'se', 'até', 'ante', 'num', 'numa'}

# 这些操作与状态采用句首大写，不继承英文标签的大小写。
PT_SENTENCE_CASE_KEYS = {
    '刷新时钟调整', '把时钟调整加进日历（%lld 次）', '未来 12 个月的时钟调整',
    '现在能打给谁', '加入日历（%lld 场）', '工作日', '拆成几场',
    '移除人物', '移除人物…', '移除假期', '与本机的时差变化', '各地下一次时钟调整',
}


def en_is_title(s):
    """英文源串是不是 Title Case 的标签 / 按钮 / 菜单项。句子、状态句（「Timer finished」）、带句号的都不算。"""
    s = (s or '').strip()
    if not s or '\n' in s or re.search(r'[.!?:]$', s):
        return None
    toks = [t.strip('\u2026()\u201c\u201d"\',;') for t in s.split()]
    words = [t for t in toks if t and re.match(r"^[A-Za-z][A-Za-z'\u2019-]*$", t)]
    if not words:
        return None
    def capitalized(w):          # iPhone / macOS / ISO 这类带大写字母的词也算
        return w[0].isupper() or any(c.isupper() for c in w)
    if len(words) == 1:
        w = words[0]
        if capitalized(w) and not w.lower().endswith('ing'):
            return 'single'
        return None
    if not capitalized(words[0]):
        return None
    major = [w for w in words[1:] if w.lower() not in EN_SMALL]
    if not major:
        return 'title'
    return 'title' if all(capitalized(w) for w in major) else None


def pt_title_case(s):
    out = []
    seen_word = False
    for i, t in enumerate(s.split(' ')):
        if not t or re.search(r'[%$@{}0-9]', t) or t.startswith('('):
            out.append(t)
            continue
        m = re.search(r'[%s]' % LATIN, t)
        if not m:
            out.append(t)
            continue
        j = m.start()
        core = t[j:]
        letters = re.sub(r'[^%s]' % LATIN, '', core)
        if any(c.isupper() for c in letters[1:]):      # iPhone / QR / macOS 这类原样
            out.append(t)
            seen_word = True
            continue
        if seen_word and core.lower().rstrip('\u2026') in PT_SMALL:
            out.append(t[:j] + core.lower())
            continue
        # 「Data/hora」→「Data/Hora」：斜杠后的部分也首字母大写；连字符后不动（Apple「Meio-dia」「Meia-noite」）
        parts = re.split(r'(/)', core)
        for k in range(0, len(parts), 2):
            part = parts[k]
            if part and part[0].isalpha() and not (k > 0 and part.lower() in PT_SMALL):
                parts[k] = part[0].upper() + part[1:]
        out.append(t[:j] + ''.join(parts))
        seen_word = True
    return ' '.join(out)


def rule_pt_title_case(v, ctx):
    if ctx.key in PT_SENTENCE_CASE_KEYS:
        return v
    if os.path.basename(ctx.file) == 'AppShortcuts.xcstrings':   # 快捷指令短语是口语句，不改
        return v
    if '\n' in v or re.search(r'[.!?:]$', v):
        return v
    kind = en_is_title(ctx.en_value)
    if not kind:
        return v
    new = pt_title_case(v)
    if new != v and kind == 'single':
        ctx.notes.append(('pt-title-from-single-en', ctx.file, ctx.key, ctx.lang, ctx.variation, v, new))
    return new


def rule_pt_terms(v, ctx):
    v = re.sub(r'\b([Tt])emporizador(es)?\b',
               lambda m: ('T' if m.group(1) == 'T' else 't') + 'imer' + ('s' if m.group(2) else ''), v)
    v = v.replace('Abrir ao iniciar sessão', 'Abrir no Início da Sessão')   # 「登录项」面板
    return v


# ---------------------------------------------------------------------------
# 规则 8：es 重命名；ko 外观
# ---------------------------------------------------------------------------

def rule_es_terms(v, ctx):
    return re.sub(r'^Cambiar nombre(\u2026?)$', r'Renombrar\1', v)


def rule_ko_terms(v, ctx):
    if ctx.key == '外观' and v == '외관':
        return '화면 모드'
    return v


# ---------------------------------------------------------------------------
# 规则 8·5：zh-Hans 拷贝 / 重新命名 / 登录时打开
#
# 逐条对过本机 .loctable：AppKit 编辑菜单 `Copy` = 拷贝（`副本` 是名词那个复制品）、
# Finder `Rename` = 重新命名、登录项扩展 `Open at Login` = 登录时打开。
# **`Share` 不改**：Apple 自己两种都用（系统设置与 Finder 是 共享，另一处菜单是 分享…），
# 没有唯一官方写法，就不动我们的「分享」。键（源语）不动，只改 zh-Hans 的值。
# ---------------------------------------------------------------------------

def rule_zh_hans_terms(v, ctx):
    v = v.replace('复制', '拷贝')
    v = v.replace('重命名', '重新命名')
    v = v.replace('无法更新开机自启', '无法更新「登录时打开」')
    v = v.replace('开机自启', '登录时打开')
    return v


# ---------------------------------------------------------------------------
# 规则 8·6：ko 日程（单个日历事件）= 이벤트（Apple 日历）
#
# 只改「一个事件」那几处；行程（여행 일정）、议程（캘린더 일정）这些「安排」义的
# 일정 是对的，不动——所以这里是封闭键表，不做整词替换。
# ---------------------------------------------------------------------------

KO_EVENT_KEYS = {'未命名日程', '下一日程', '即将到来的日程', '菜单栏显示下一日程'}


def rule_ko_event(v, ctx):
    if ctx.key in KO_EVENT_KEYS:
        return v.replace('일정', '이벤트')
    return v


# ---------------------------------------------------------------------------
# 规则 9：zh-Hant 輔助說明 / 整日 / 在登入時打開
# ---------------------------------------------------------------------------

def rule_zh_hant_terms(v, ctx):
    if ctx.key == '帮助' and v == '說明':
        v = '輔助說明'
    v = v.replace('全天', '整日')
    v = v.replace('無法更新登入時開啟', '無法更新「在登入時打開」')
    v = v.replace('登入時開啟', '在登入時打開')
    return v


# ---------------------------------------------------------------------------
# 规则 10：月相八相按 WeatherKit
#
# 值逐字来自本机 `WeatherKit.framework/.../Localizable.loctable` 的 Title Case 键
# （`New Moon` / `Waxing Crescent` / `First Quarter` / `Waxing Gibbous` / `Full Moon` /
# `Waning Gibbous` / `Last Quarter` / `Waning Crescent`），也就是 Apple 自己在天气 App
# 界面上写的那一套；ja 的 三日月 / 十日夜 / 寝待月 / 有明月 与 ko 的 상현망간의 달 一类
# 是和历 / 韩历的传统名字，Apple 就这么写。
# ---------------------------------------------------------------------------

MOON = {
    ('zh-Hant', '蛾眉月'): ('蛾眉月', '眉月'),
    ('de', '盈凸月'): ('Zunehmender Dreiviertelmond', 'Zunehmender Mond'),
    ('de', '亏凸月'): ('Abnehmender Dreiviertelmond', 'Abnehmender Mond'),
    ('ru', '上弦月'): ('Первая четверть', '1\u2011я четверть'),
    ('ru', '盈凸月'): ('Растущая Луна', 'Прибывающая луна'),
    ('ru', '亏凸月'): ('Убывающая Луна', 'Убывающая луна'),
    ('ru', '下弦月'): ('Последняя четверть', '3\u2011я четверть'),
    # ja：上弦 / 下弦 / 三日月 / 満月 / 新月 已与 Apple 相同，只差这三相。
    ('ja', '盈凸月'): ('満ちていく凸月', '十日夜'),
    ('ja', '亏凸月'): ('欠けていく凸月', '寝待月'),
    ('ja', '残月'): ('細い月（欠けていく月）', '有明月'),
    # ko：Apple 用 신월 / 만월 与 상현 / 하현（不带 달），凸月两相是 상현망간의 달 / 하현망간의 달。
    ('ko', '新月'): ('삭', '신월'),
    ('ko', '上弦月'): ('상현달', '상현'),
    ('ko', '盈凸月'): ('차오르는 볼록달', '상현망간의 달'),
    ('ko', '满月'): ('보름달', '만월'),
    ('ko', '亏凸月'): ('기우는 볼록달', '하현망간의 달'),
    ('ko', '下弦月'): ('하현달', '하현'),
    # pt-BR：Apple 的 Title Case 写法；「蛾眉月 / 残月」只写 Crescente / Minguante，凸月是「<相> Gibosa」。
    ('pt-BR', '新月'): ('Lua nova', 'Lua Nova'),
    ('pt-BR', '蛾眉月'): ('Lua crescente', 'Crescente'),
    ('pt-BR', '上弦月'): ('Quarto crescente', 'Quarto Crescente'),
    ('pt-BR', '盈凸月'): ('Gibosa crescente', 'Crescente Gibosa'),
    ('pt-BR', '满月'): ('Lua cheia', 'Lua Cheia'),
    ('pt-BR', '亏凸月'): ('Gibosa minguante', 'Minguante Gibosa'),
    ('pt-BR', '下弦月'): ('Quarto minguante', 'Quarto Minguante'),
    ('pt-BR', '残月'): ('Lua minguante', 'Minguante'),
}


def rule_moon_phases(v, ctx):
    hit = MOON.get((ctx.lang, ctx.key))
    if not hit:
        return v
    old, new = hit
    if v == old:
        return new
    if v != new:
        ctx.notes.append(('moon-unexpected', ctx.file, ctx.key, ctx.lang, ctx.variation, v, new))
    return v


# ---------------------------------------------------------------------------
# 规则表（顺序即执行顺序：术语与引号先，标点与空格后，pt Title Case 最后）
# ---------------------------------------------------------------------------

RULES = [
    dict(id='ja-timezone', langs=['ja'], default=True, fn=rule_ja_timezone,
         desc='ja タイムゾーン → 時間帯；表示时段的 時間帯 按语境改 時間枠 / 時間 / 範囲 / 候補'),
    dict(id='ja-terms', langs=['ja'], default=True, fn=rule_ja_terms,
         desc='ja やり直してみてください / 日の入 / 名称変更'),
    dict(id='fr-terms', langs=['fr'], default=True, fn=rule_fr_terms,
         desc='fr Évènement（1990 拼写）、Ouvrir avec la session'),
    dict(id='de-terms', langs=['de'], default=True, fn=rule_de_terms,
         desc='de Termin → Ereignis（日历日程，含冠词变格）、Erscheinungsbild、Bei der Anmeldung öffnen'),
    dict(id='ru-terms', langs=['ru'], default=True, fn=rule_ru_terms,
         desc='ru 设置「外观」→ Оформление'),
    dict(id='pt-terms', langs=['pt-BR'], default=True, fn=rule_pt_terms,
         desc='pt-BR Temporizador → Timer、Abrir no Início da Sessão'),
    dict(id='es-terms', langs=['es'], default=True, fn=rule_es_terms,
         desc='es Cambiar nombre → Renombrar'),
    dict(id='ko-terms', langs=['ko'], default=True, fn=rule_ko_terms,
         desc='ko 外观 → 화면 모드'),
    dict(id='zh-hans-terms', langs=['zh-Hans'], default=True, fn=rule_zh_hans_terms,
         desc='zh-Hans 复制 → 拷贝、重命名 → 重新命名、开机自启 → 登录时打开（分享不改：Apple 自己两种都用）'),
    dict(id='ko-event', langs=['ko'], default=True, fn=rule_ko_event,
         desc='ko 单个日历事件的 일정 → 이벤트（封闭键表；行程 / 议程义的 일정 不动）'),
    dict(id='zh-hant-terms', langs=['zh-Hant'], default=True, fn=rule_zh_hant_terms,
         desc='zh-Hant 輔助說明 / 整日 / 在登入時打開'),
    dict(id='moon-phases', langs=['zh-Hant', 'ja', 'ko', 'de', 'ru', 'pt-BR'], default=True, fn=rule_moon_phases,
         desc='月相八相按 WeatherKit（zh-Hant 眉月；ja 十日夜 / 寝待月 / 有明月；ko 신월 / 상현 / 상현망간의 달；de Zunehmender/Abnehmender Mond；ru 1‑я/3‑я четверть；pt-BR Title Case 与 Crescente Gibosa 词序）'),
    dict(id='cjk-quotes', langs=['zh-Hans', 'ja'], default=True, fn=rule_cjk_quotes,
         desc='zh-Hans / ja 「」→ “ ”（ja 右引号后接半角字符补空格）'),
    dict(id='ko-quotes', langs=['ko'], default=True, fn=rule_ko_quotes,
         desc='ko 「」→ ‘ ’'),
    dict(id='ja-punct', langs=['ja'], default=True, fn=rule_ja_punct,
         desc='ja 全角：？！→ 半角 + 空格'),
    dict(id='fr-nbsp', langs=['fr'], default=True, fn=rule_fr_nbsp,
         desc='fr ? ; : ! 前与 « » 内侧用不换行空格 U+00A0'),
    dict(id='fr-apostrophe', langs=['fr'], default=True, fn=rule_fr_apostrophe,
         desc='fr 直撇号 \' → ’'),
    dict(id='de-ellipsis', langs=['de'], default=True, fn=rule_de_ellipsis,
         desc='de 串尾省略号前不换行空格'),
    dict(id='ru-vy', langs=['ru'], default=True, fn=rule_ru_vy,
         desc='ru 大写 Вы / Вас / Вам / Ваш…'),
    dict(id='cjk-number-space', langs=['zh-Hans', 'zh-Hant', 'ja'], default=True, fn=rule_cjk_number_space,
         desc='zh-Hans / zh-Hant / ja 数字（含 %lld）与汉字、假名之间去空格；钟点与拉丁短语里的数字不动'),
    dict(id='cjk-placeholder-space', langs=['zh-Hans', 'zh-Hant', 'ja'], default=True, fn=rule_cjk_placeholder_space,
         desc='zh-Hans / zh-Hant / ja 句中 %@ 与汉字、假名之间去空格'),
    dict(id='cjk-latin-space', langs=['zh-Hans', 'zh-Hant', 'ja'], default=True, fn=rule_cjk_latin_space,
         desc='汉字与拉丁词之间去空格（Apple zh-Hant / ja 指南与本机 Apple 界面实测都不留：zh-Hans 1 / 214、ja 0 / 236；规则默认开启）'),
    dict(id='pt-title-case', langs=['pt-BR'], default=True, fn=rule_pt_title_case,
         desc='pt-BR 英文源串为 Title Case 的标签 / 按钮 / 菜单项改 Title Case（介词冠词小写）'),
]
RULE_BY_ID = {r['id']: r for r in RULES}


# ---------------------------------------------------------------------------
# 目录读写
# ---------------------------------------------------------------------------

def iter_units(entry, lang):
    """产出 (variation 名, stringUnit 字典)。'' 是普通串；'plural.one' 这类是变体；substitutions 也覆盖。"""
    loc = entry.get('localizations', {}).get(lang)
    if not isinstance(loc, dict):
        return
    su = loc.get('stringUnit')
    if isinstance(su, dict) and isinstance(su.get('value'), str):
        yield '', su
    var = loc.get('variations')
    if isinstance(var, dict):
        for kind, cats in var.items():
            if isinstance(cats, dict):
                for cat, unit in cats.items():
                    su2 = unit.get('stringUnit') if isinstance(unit, dict) else None
                    if isinstance(su2, dict) and isinstance(su2.get('value'), str):
                        yield '%s.%s' % (kind, cat), su2
    subs = loc.get('substitutions')
    if isinstance(subs, dict):
        for name, sub in subs.items():
            var2 = sub.get('variations', {}) if isinstance(sub, dict) else {}
            for kind, cats in var2.items():
                if isinstance(cats, dict):
                    for cat, unit in cats.items():
                        su3 = unit.get('stringUnit') if isinstance(unit, dict) else None
                        if isinstance(su3, dict) and isinstance(su3.get('value'), str):
                            yield 'subst.%s.%s.%s' % (name, kind, cat), su3


def en_value_for(entry, variation):
    units = dict(iter_units(entry, 'en'))
    if variation in units:
        return units[variation]['value']
    if '' in units:
        return units['']['value']
    for k in ('plural.other', 'plural.one'):
        if k in units:
            return units[k]['value']
    return None


def load_catalog(path):
    with open(path, encoding='utf-8') as f:
        raw = f.read()
    return json.loads(raw), raw


def dump_catalog(data, trailing_newline):
    return json.dumps(data, ensure_ascii=False, indent=2) + ('\n' if trailing_newline else '')


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def apply_rules(path, data, active_rules, latin_mode, changes, counts, notes):
    strings = data.get('strings', {})
    for key, entry in strings.items():
        for lang in LANGS:
            for variation, unit in iter_units(entry, lang):
                original = unit['value']
                v = original
                touched = []
                ctx = SimpleNamespace(lang=lang, key=key, file=path, variation=variation,
                                      en_value=en_value_for(entry, variation) if lang == 'pt-BR' else None,
                                      latin_mode=latin_mode, notes=notes)
                for rule in active_rules:
                    if lang not in rule['langs']:
                        continue
                    before = v
                    v = rule['fn'](v, ctx)
                    if v != before:
                        touched.append(rule['id'])
                        counts[(lang, rule['id'])] += 1
                if v != original:
                    if v.count('%') != original.count('%'):
                        raise SystemExit('占位符数量变了，拒绝写出：%s / %s / %r → %r' % (path, lang, original, v))
                    unit['value'] = v
                    changes.append(dict(file=path, key=key, lang=lang, variation=variation,
                                        before=original, after=v, rules=touched))


def write_report(path, args, files, changes, counts, notes, latin_stats, active_rules):
    langs = [l for l in LANGS if l != 'en']
    rule_ids = [r['id'] for r in active_rules]
    lines = []
    lines.append('# 本地化机械修正报告（`Tools/l10n_apple_style.py`）')
    lines.append('')
    lines.append('生成时间：%s；模式：%s；文件：%s' % (
        datetime.datetime.now().strftime('%Y-%m-%d %H:%M'),
        '试运行（未写入）' if args.dry_run else '已写入',
        '、'.join('`%s`' % os.path.relpath(f, ROOT) for f in files)))
    lines.append('启用规则：%s' % '、'.join('`%s`' % r for r in rule_ids))
    off = [r['id'] for r in RULES if r not in active_rules]
    if off:
        lines.append('未启用：%s' % '、'.join('`%s`' % r for r in off))
    lines.append('')
    lines.append('## 改动统计（每语每规则改了几串；同一串可能被多条规则各改一次）')
    lines.append('')
    lines.append('| 规则 | ' + ' | '.join(langs) + ' | 合计 |')
    lines.append('|---|' + '---|' * (len(langs) + 1))
    for rid in rule_ids:
        row = [counts.get((l, rid), 0) for l in langs]
        if sum(row) == 0:
            continue
        lines.append('| `%s` | %s | %d |' % (rid, ' | '.join(str(x) or '' for x in row), sum(row)))
    per_lang = collections.Counter(c['lang'] for c in changes)
    lines.append('| **改动串数（去重）** | %s | **%d** |' % (' | '.join(str(per_lang.get(l, 0)) for l in langs), len(changes)))
    lines.append('')
    lines.append('## 随机抽样 %d 条前后对照（seed %d）' % (args.samples, args.seed))
    lines.append('')
    rng = random.Random(args.seed)
    sample = rng.sample(changes, min(args.samples, len(changes))) if changes else []
    sample.sort(key=lambda c: (LANGS.index(c['lang']), c['key']))
    lines.append('| # | 语言 | 键 | 规则 | 改前 | 改后 |')
    lines.append('|---|---|---|---|---|---|')
    for i, c in enumerate(sample, 1):
        lines.append('| %d | %s | %s | %s | %s | %s |' % (
            i, c['lang'], md(c['key'], 60), ' '.join(c['rules']), md(c['before']), md(c['after'])))
    lines.append('')

    def note_section(title, kind, intro):
        rows = [n for n in notes if n[0] == kind]
        if not rows:
            return
        lines.append('## %s（%d 条）' % (title, len(rows)))
        lines.append('')
        if intro:
            lines.append(intro)
            lines.append('')
        same = all(before == after for _, _, _, _, _, before, after in rows)
        lines.append('| 键 | 现值 |' if same else '| 键 | 改前 | 改后 |')
        lines.append('|---|---|' if same else '|---|---|---|')
        for _, f, key, lang, variation, before, after in rows:
            if same:
                lines.append('| %s | %s |' % (md(key, 70), md(before)))
            else:
                lines.append('| %s | %s | %s |' % (md(key, 70), md(before), md(after)))
        lines.append('')

    note_section('ja 時間帯 / タイムゾーン 逐键处理', 'ja-timezone',
                 '键里含「时区」的只换显式表里的片段；其余按语境：時間枠（时段）、時間（睡眠 / 光照 / 不存在的时刻）、範囲（可选范围）、候補（候选）。'
                 '「タイムゾーンカード」（时间名片）与「〜のような時間帯の言い方」原样保留。')
    ph = [c for c in changes if 'cjk-placeholder-space' in c['rules']]
    if ph:
        lines.append('## 句中 %%@ 两侧去空格的串（%d 条，%%@ 可能是地名 / 日期 / 时刻，请人核）' % len(ph))
        lines.append('')
        lines.append('| 语言 | 键 | 改后 |')
        lines.append('|---|---|---|')
        for c in ph:
            lines.append('| %s | %s | %s |' % (c['lang'], md(c['key'], 70), md(c['after'])))
        lines.append('')
    note_section('pt-BR 由单词英文源串推定为标签而改 Title Case 的串', 'pt-title-from-single-en',
                 '英文只有一个词（「Countdown」「Weight」）时无法从大小写看出是标签还是状态句，按标签处理；请母语者过一眼。')
    note_section('de 保留 Termin 的串（例会「每一次」，不是日历对象）', 'de-termin-skipped', '')
    note_section('月相值与预期不符、未改', 'moon-unexpected', '')
    lines.append('## 汉字与拉丁词之间的空格（规则 `cjk-latin-space`，默认开启）')
    lines.append('')
    lines.append('Apple zh-Hant 指南「No Space Between Chinese and Latin」、ja 指南「No Space Between English and Japanese」；'
                 'zh-Hans 指南示例除「你可以使用 Apple ID 登录」外一律不留（「开发优秀的iOS App」「通过Apple登录」）。'
                 '本机 macOS 自带 App 的 %s 张 .loctable（时钟 / 日历 / 天气 / 通讯录 / 快捷指令 / 系统设置 / AppKit 菜单）实测：'
                 % latin_stats.get('tables', '?'))
    lines.append('')
    lines.append('| 语言 | Apple 界面串：留空格 / 不留 | 我们目录里仍留空格的串 |')
    lines.append('|---|---|---|')
    for l in ('zh-Hans', 'zh-Hant', 'ja'):
        a = latin_stats.get(l, {})
        lines.append('| %s | %s / %s | %d |' % (l, a.get('apple_space', '?'), a.get('apple_nospace', '?'), a.get('ours', 0)))
    lines.append('')
    lines.append('这条规则按 Apple 的中日文排版惯例默认开启；'
                 '要保留这类空格就 `--skip cjk-latin-space`。')
    lines.append('')
    lines.append('## 脚本改不到、要跟着做的事')
    lines.append('')
    lines.append('1. `ClockText.duration`（`Dayside/Models/ClockText.swift`）把「%lld 小时」「%lld 分钟」两段用普通空格相接，目录改成「%lld小时」后中文会成「11小时 30分钟」；'
                 'zh-Hans / zh-Hant / ja 要改成不加分隔（Apple「%@小时%@分钟」），对应测试 `ClockTextTests.swift`（「11 小时 30 分钟」四条）与 '
                 '`CatalogAndFormattingTests.swift`（`durationText(90)`）的期望值跟着改。')
    lines.append('2. 日期与钟点相接的「\\(day) \\(time)」（`ClockText.dateTime` / `interval`）保留空格：Apple 中文在日期与星期 / 时刻之间也留一个空格（zh-Hans 指南「Date And Time」条）。')
    lines.append('3. ja「タイムゾーンカード」（时间名片）没跟着改成 時間帯カード，功能名留母语者定；ja 的 時間枠 / 時間 / 範囲 / 候補 也是按语境的机械选择，见上表。')
    lines.append('4. zh-Hans 源语与 Apple 不同的四处（复制 / 拷贝、分享 / 共享、重命名 / 重新命名、开机自启 / 登录时打开）保留源语键；匹配 Apple 术语时给 zh-Hans 添加独立译文值。')
    lines.append('5. 改完跑一遍 `Tools/verify_all.sh` 与八语截图（`Tools/shoot_app_pages.sh`）看版式：pt-BR Title Case 与 fr 不换行空格不改宽度，zh / ja 去空格只会变窄。')
    lines.append('')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))


def md(s, limit=0):
    s = (s or '').replace('|', '\\|').replace('\n', '⏎')
    s = s.replace(NBSP, '⍽').replace('\u2011', '‑')
    if limit and len(s) > limit:
        s = s[:limit] + '…'
    return '`%s`' % s if s else ''


def latin_space_stats(files_data):
    """给报告用：Apple 界面串与我们目录里「汉字与拉丁字母之间留空格」的计数。"""
    stats = {}
    apple = {}
    try:
        apple = read_loctables(APPLE_TABLES_FOR_STATS)
    except Exception:
        apple = {}
    for l in ('zh-Hans', 'zh-Hant', 'ja'):
        sp = nosp = 0
        for table in apple.values():
            for v in table.get(l, {}).values():
                if re.search(CJKC + r' [%s]|[%s] ' % (LATIN, LATIN) + CJKC, v):
                    sp += 1
                if re.search(CJKC + r'[%s]|[%s]' % (LATIN, LATIN) + CJKC, v):
                    nosp += 1
        ours = 0
        for data in files_data:
            for key, entry in data.get('strings', {}).items():
                for variation, unit in iter_units(entry, l):
                    if re.search(CJKC + r' [%s]|[%s] ' % (LATIN, LATIN) + CJKC, unit['value']):
                        ours += 1
        stats[l] = dict(apple_space=sp if apple else '?', apple_nospace=nosp if apple else '?', ours=ours)
    stats['tables'] = len(apple)
    return stats


# ---------------------------------------------------------------------------
# 术语核对报告：对照本机 Apple .loctable
# ---------------------------------------------------------------------------

LOC_LANGS = {'en': 'en', 'zh_CN': 'zh-Hans', 'zh_TW': 'zh-Hant', 'ja': 'ja', 'ko': 'ko', 'de': 'de',
             'es': 'es', 'fr': 'fr', 'pt_BR': 'pt-BR', 'ru': 'ru'}

CLOCK = '/System/Applications/Clock.app/Contents/Resources/Localizable.loctable'
CAL = '/System/Applications/Calendar.app/Contents/Resources/Localizable.loctable'
WEATHER = '/System/Applications/Weather.app/Contents/Resources/Localizable.loctable'
WEATHERKIT = '/System/Library/Frameworks/WeatherKit.framework/Versions/A/Resources/Localizable.loctable'
CONTACTS_INFO = '/System/Applications/Contacts.app/Contents/Resources/InfoPlist.loctable'
CONTACTS_AB = '/System/Applications/Contacts.app/Contents/Resources/ABLabelStrings.loctable'
SHORTCUTS = '/System/Applications/Shortcuts.app/Contents/Resources/Localizable.loctable'
LOGIN = '/System/Library/ExtensionKit/Extensions/LoginItems.appex/Contents/Resources/Localizable.loctable'
LOGIN_INFO = '/System/Library/ExtensionKit/Extensions/LoginItems.appex/Contents/Resources/InfoPlist.loctable'
CCS_INFO = '/System/Library/ExtensionKit/Extensions/ControlCenterSettings.appex/Contents/Resources/InfoPlist.loctable'
APPEAR_INFO = '/System/Library/ExtensionKit/Extensions/Appearance.appex/Contents/Resources/InfoPlist.loctable'
SECPRIV = '/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/Resources/Localizable.loctable'
NOTIF = '/System/Library/CoreServices/NotificationCenter.app/Contents/Resources/Localizable.loctable'
DATETIME = '/System/Library/ExtensionKit/Extensions/DateAndTime Extension.appex/Contents/Resources/Localizable.loctable'

APPLE_TABLES_FOR_STATS = [CLOCK, CAL, WEATHER, CONTACTS_AB, SHORTCUTS, LOGIN, SECPRIV, NOTIF, DATETIME,
                          '/System/Applications/System Settings.app/Contents/Resources/Localizable.loctable',
                          '/System/Library/Frameworks/AppKit.framework/Versions/C/Resources/MenuCommands.loctable',
                          '/System/Library/Frameworks/AppKit.framework/Versions/C/Resources/Localizable.loctable']

# (概念, loctable, Apple 键, 我们的键列表, 备注, 词干表)
# 词干表：我们的键是短语时，只看 Apple 那个词（或词干）在不在我们的译文里；没有词干表就整串比。
TERM_CHECKS = [
    ('时区', CAL, 'Time Zone', ['来源时区', '时区不可用'], '', None),
    ('时区（系统设置）', DATETIME, 'TIME_ZONE', ['来源时区'], '', None),
    ('日历', CAL, 'Calendar-XX03', ['日历'], '', None),
    ('日程', CAL, 'Event', ['未命名日程'], 'ko 이벤트 vs 일정：Apple 日历用 이벤트，我们全目录用 일정，改要连动约 20 键，留母语者', None),
    ('全天', CAL, 'All-Day', ['全天'], 'fr Apple 也有 toute la journée（`all-day`），两种都算 Apple 写法', None),
    ('通讯录', CONTACTS_INFO, 'CFBundleName', ['从通讯录选择'], 'pt-BR 我们句中小写 contatos，可接受',
     dict(ru='контакт', **{'pt-BR': 'contatos'})),
    ('小组件', NOTIF, 'Edit Widgets', ['编辑小组件以选择地点'], '只看「小组件」一词',
     {'zh-Hant': '小工具', 'ja': 'ウィジェット', 'ko': '위젯', 'de': 'Widget', 'es': 'widget', 'fr': 'widget', 'pt-BR': 'widget', 'ru': 'виджет'}),
    ('菜单栏', CCS_INFO, 'CFBundleDisplayName', ['菜单栏'], '', None),
    ('登录时打开', LOGIN, 'Open at Login', ['开机自启'], 'zh-Hans 源语「开机自启」vs Apple「登录时打开」：保留源语键；匹配 Apple 术语时给 zh-Hans 添加独立译文值', None),
    ('登录项', LOGIN_INFO, 'CFBundleDisplayName', ['macOS 需要在系统设置的登录项中允许 Dayside。'], '只看「登录项」一词',
     {'zh-Hant': '登入項目', 'ja': 'ログイン項目', 'ko': '로그인 항목', 'de': 'Anmeldeobjekte', 'es': 'ítems de inicio', 'fr': 'ouverture de session', 'pt-BR': 'Itens de Início', 'ru': 'объект'}),
    ('通知', WEATHER, 'Notifications', ['允许系统通知'], 'de 系统一律 Mitteilungen', None),
    ('隐私', SECPRIV, 'Privacy', ['日历读取权限未开启。请在系统设置的「隐私与安全性 › 日历」里允许 Dayside 访问。'], '只看「隐私」一词', None),
    ('撤销', SHORTCUTS, 'Undo', ['撤销'], 'ru：指南说 Undo 与 Cancel 同屏时 Undo 译「Не применять」；我们面板撤销条与取消不同屏，保留 Отменить', None),
    ('取消', CLOCK, 'CANCEL_TIMER', ['取消'], 'ru：Apple 时钟同一张表里 CANCEL_TIMER 是 Отмена、CANCEL 是 Отменить，指南按钮规则写 Отменить；目录采用 Apple 时钟的 Отмена，保留现值', None),
    ('拷贝', CONTACTS_AB, 'COPY', ['复制文字', '复制链接'], 'zh-Hans 源语「复制」vs Apple「拷贝」：13 键；匹配 Apple 术语时给 zh-Hans 添加独立译文值；ko Apple 通讯录 복사하기、Shortcuts 복사，我们 복사 可接受',
     {'ko': '복사'}),
    ('粘贴', SHORTCUTS, 'Paste', ['粘贴并换算'], '', {'ko': '붙여넣'}),
    ('分享', SHORTCUTS, 'Share (Button)', ['分享预览', '分享二维码'], 'zh-Hans 源语「分享」vs Apple「共享」：9 键；匹配 Apple 术语时给 zh-Hans 添加独立译文值；de Freigabe / ru отправка、обмен 是名词化说法，母语者定',
     {'zh-Hans': '共享', 'de': 'teil', 'fr': 'partag', 'ru': 'подел', 'pt-BR': 'compartilh'}),
    ('导入', CAL, 'Import', ['导入'], '', None),
    ('导出', CAL, 'Export…', ['导出诊断包…'], 'ru 我们「Экспорт диагностики…」名词式，可接受',
     {'zh-Hans': '导出', 'zh-Hant': '輸出', 'ja': '書き出', 'ko': '내보내', 'de': 'Exportier', 'es': 'Exportar', 'fr': 'Exporter', 'pt-BR': 'Exportar', 'ru': 'Экспорт'}),
    ('计时器', CLOCK, 'TIMER', ['计时器'], '', None),
    ('秒表', CLOCK, 'STOP_WATCH', ['秒表'], '', None),
    ('闹钟', CLOCK, 'ALARM_DEFAULT_TITLE', ['闹钟'], '', None),
    ('日出（时钟 App）', CLOCK, 'SUNRISE', ['日出'], 'Apple 时钟 / 天气两处译法不同（fr Jour / Lever；es Salida del sol / Amanecer；ru Восход солнца 两处一致，我们 Восход 可接受）', None),
    ('日出（天气 App）', WEATHER, 'Sunrise', ['日出'], 'ru 时钟 / 天气两处都是 Восход солнца，我们的短写 Восход 可接受（面板一行放不下时）', None),
    ('日落（时钟 App）', CLOCK, 'SUNSET', ['日落'], 'fr Apple 时钟写 Nuit、天气写 Coucher；我们 Coucher du soleil 可接受', None),
    ('日落（天气 App）', WEATHER, 'Sunset', ['日落'], '', None),
    ('世界时钟', CLOCK, 'WORLD_CLOCK', ['世界时钟'], 'fr Apple 时钟 App 的标签是 Horloges（复数），我们 Horloge mondiale 可接受', None),
    ('重命名', SHORTCUTS, 'Rename', ['重命名'], 'zh-Hans 源语「重命名」vs Apple「重新命名」：保留源语键；匹配 Apple 术语时给 zh-Hans 添加独立译文值', None),
    ('帮助', SHORTCUTS, 'Help', ['帮助'], '', None),
    ('外观', APPEAR_INFO, 'CFBundleDisplayName', ['外观'], '', None),
    ('通用', CAL, 'General', ['通用'], '', None),
    ('设置', WEATHER, 'Settings', ['设置'], '', None),
    ('新月', WEATHERKIT, 'New Moon', ['新月'], 'ko 신월 vs 삭：留母语者', None),
    ('蛾眉月', WEATHERKIT, 'Waxing Crescent', ['蛾眉月'], 'es / pt-BR Apple 只写 Creciente，我们 Luna creciente；未列入本脚本', None),
    ('上弦月', WEATHERKIT, 'First Quarter', ['上弦月'], '', None),
    ('盈凸月', WEATHERKIT, 'Waxing Gibbous', ['盈凸月'], 'ja 十日夜、ko 상현망간의 달：留母语者；fr Apple 不带 Lune；pt-BR 词序 Crescente Gibosa', None),
    ('满月', WEATHERKIT, 'Full Moon', ['满月'], 'ko 만월 vs 보름달：留母语者', None),
    ('亏凸月', WEATHERKIT, 'Waning Gibbous', ['亏凸月'], 'ja 寝待月：留母语者', None),
    ('下弦月', WEATHERKIT, 'Last Quarter', ['下弦月'], '', None),
    ('残月', WEATHERKIT, 'Waning Crescent', ['残月'], 'ja 有明月：留母语者；es / pt-BR Apple 只写 Menguante / Minguante', None),
]


def norm(s):
    """比较前归一：不换行空格当普通空格、去软连字符、不分大小写。"""
    return (s or '').replace(NBSP, ' ').replace('\u00ad', '').casefold()


def read_loctables(paths):
    out = {}
    for p in paths:
        if not os.path.exists(p):
            continue
        try:
            raw = subprocess.run(['plutil', '-convert', 'json', '-o', '-', p],
                                 capture_output=True, text=True, timeout=120).stdout
            d = json.loads(raw)
        except Exception:
            continue
        table = {}
        for lk, lv in d.items():
            if lk in LOC_LANGS and isinstance(lv, dict):
                table[LOC_LANGS[lk]] = {k: v for k, v in lv.items() if isinstance(v, str)}
        if 'pt-BR' not in table and isinstance(d.get('pt'), dict):      # Apple 表里 pt = 巴西葡语
            table['pt-BR'] = {k: v for k, v in d['pt'].items() if isinstance(v, str)}
        if 'en' not in table and isinstance(d.get('en_GB'), dict):      # WeatherKit 没有 en，只有 en_GB
            table['en'] = {k: v for k, v in d['en_GB'].items() if isinstance(v, str)}
        out[p] = table
    return out


def write_terms_report(path, files_data):
    ours = {}
    for data in files_data:
        for key, entry in data.get('strings', {}).items():
            ours.setdefault(key, entry)
    tables = read_loctables(sorted({t[1] for t in TERM_CHECKS}))
    langs = [l for l in LANGS if l != 'en']
    lines = ['# 术语核对：Dayside 目录 vs Apple 本机 .loctable', '',
             '由 `Tools/l10n_apple_style.py --terms-report` 生成（%s）。Apple 列逐字来自 macOS 自带 App 的 .loctable'
             '（`plutil -convert json`），我们列来自四份 String Catalog，都是脚本跑完之后的现状；「✓」= 逐字相同（不换行空格与软连字符不计），'
             '「✓含」= Apple 那个词（或词干）出现在我们的译文里（我们的键是短语），「✗」= 不同。备注是人写的判断。'
             % datetime.datetime.now().strftime('%Y-%m-%d %H:%M'), '']
    diffs = []
    for concept, table_path, apple_key, our_keys, remark, stems in TERM_CHECKS:
        table = tables.get(table_path, {})
        apple = {l: table.get(l, {}).get(apple_key) for l in LANGS}
        if apple.get('en') is None:
            lines.append('## %s' % concept)
            lines.append('')
            lines.append('Apple 表 `%s` 里没有键 `%s`，跳过。' % (os.path.basename(table_path), apple_key))
            lines.append('')
            continue
        lines.append('## %s（Apple `%s` · `%s`：%s）' % (concept, short_table(table_path), apple_key, apple['en']))
        lines.append('')
        if remark:
            lines.append('备注：%s' % remark)
            lines.append('')
        lines.append('| 语言 | Apple | 我们（键 → 值） | 判定 |')
        lines.append('|---|---|---|---|')
        for l in langs:
            a = apple.get(l)
            cells = []
            verdict = []
            for k in our_keys:
                entry = ours.get(k)
                if not entry:
                    cells.append('%s → （无此键）' % md(k, 40))
                    continue
                units = dict(iter_units(entry, l))
                v = units.get('', {}).get('value') if '' in units else next((u['value'] for u in units.values()), '')
                cells.append('%s → %s' % (md(k, 40), md(v)))
                probe = (stems or {}).get(l, a)
                if a is None or v is None:
                    verdict.append('?')
                elif norm(v) == norm(a):
                    verdict.append('✓')
                elif norm(probe) in norm(v):
                    verdict.append('✓含')
                else:
                    verdict.append('✗')
                    diffs.append((concept, l, k, v, a, remark))
            lines.append('| %s | %s | %s | %s |' % (l, md(a) if a is not None else '（无）', '<br>'.join(cells), ' '.join(verdict)))
        lines.append('')
    lines.insert(3, '共核 %d 个概念，与 Apple 不同的 %d 处，列在文末并附处理建议。' % (len(TERM_CHECKS), len(diffs)))
    lines.insert(4, '')
    lines.append('## 与 Apple 不同的汇总')
    lines.append('')
    lines.append('| 概念 | 语言 | 我们 | Apple | 建议 |')
    lines.append('|---|---|---|---|---|')
    for concept, l, k, v, a, remark in diffs:
        lines.append('| %s | %s | %s | %s | %s |' % (concept, l, md(v), md(a), remark or '按 Apple 改'))
    lines.append('')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    return diffs


def short_table(p):
    return p.replace('/System/Applications/', '').replace('/Contents/Resources/', '/') \
            .replace('/System/Library/ExtensionKit/Extensions/', '').replace('/System/Library/Frameworks/', '') \
            .replace('/System/Library/CoreServices/', '').replace('/Versions/A/Resources/', '/')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('files', nargs='*', help='要处理的 .xcstrings（默认四份目录）')
    ap.add_argument('--dry-run', action='store_true', help='只报告不写入')
    ap.add_argument('--check', action='store_true', help='只检查；规则需改动或目录缺失时失败')
    ap.add_argument('--report', metavar='路径', help='写改动报告（Markdown）')
    ap.add_argument('--terms-report', metavar='路径', help='写术语核对报告（对照本机 Apple .loctable，需 plutil）')
    ap.add_argument('--only', metavar='规则,…', help='只跑这些规则')
    ap.add_argument('--skip', metavar='规则,…', help='跳过这些规则')
    ap.add_argument('--enable', metavar='规则,…', help='打开默认关闭的规则（如 cjk-latin-space）')
    ap.add_argument('--list-rules', action='store_true')
    ap.add_argument('--samples', type=int, default=30, help='报告里的随机抽样条数')
    ap.add_argument('--seed', type=int, default=20260917)
    args = ap.parse_args(argv)
    if args.check:
        args.dry_run = True

    if args.list_rules:
        for r in RULES:
            print('%-24s %-7s %-22s %s' % (r['id'], '默认开' if r['default'] else '默认关', ','.join(r['langs']), r['desc']))
        return 0

    def parse(opt):
        ids = [x.strip() for x in (opt or '').split(',') if x.strip()]
        for x in ids:
            if x not in RULE_BY_ID:
                raise SystemExit('没有这条规则：%s（--list-rules 看清单）' % x)
        return ids

    only, skip, enable = parse(args.only), parse(args.skip), parse(args.enable)
    active = []
    for r in RULES:
        on = r['default'] or r['id'] in enable
        if only:
            on = r['id'] in only
        if r['id'] in skip:
            on = False
        if on:
            active.append(r)
    latin_mode = any(r['id'] == 'cjk-latin-space' for r in active)

    files = [os.path.join(ROOT, f) if not os.path.isabs(f) else f for f in (args.files or DEFAULT_FILES)]
    missing = [f for f in files if not os.path.exists(f)]
    if args.check and missing:
        for path in missing:
            print('缺少文案目录：%s' % path)
        return 1
    files = [f for f in files if os.path.exists(f)]
    changes, notes = [], []
    counts = collections.Counter()
    datas = []
    for path in files:
        data, raw = load_catalog(path)
        apply_rules(path, data, active, latin_mode, changes, counts, notes)
        out = dump_catalog(data, raw.endswith('\n'))
        datas.append(data)
        n = sum(1 for c in changes if c['file'] == path)
        if not args.dry_run and out != raw:
            with open(path, 'w', encoding='utf-8') as f:
                f.write(out)
        print('%-52s %4d 串改动%s' % (os.path.relpath(path, ROOT), n, '（未写入）' if args.dry_run else ''))

    per_lang = collections.Counter(c['lang'] for c in changes)
    print('合计 %d 串：%s' % (len(changes), '，'.join('%s %d' % (l, per_lang[l]) for l in LANGS if per_lang[l])))
    for kind, f, key, lang, variation, before, after in notes:
        if kind in ('moon-unexpected',):
            print('警告 %s %s [%s] %r 现值 %r，预期改成 %r' % (kind, os.path.basename(f), lang, key, before, after))
    if args.report:
        stats = latin_space_stats(datas)
        write_report(args.report, args, files, changes, counts, notes, stats, active)
        print('报告：%s' % args.report)
    if args.terms_report:
        diffs = write_terms_report(args.terms_report, datas)
        print('术语核对：%s（%d 处不同）' % (args.terms_report, len(diffs)))
    return 1 if args.check and changes else 0


if __name__ == '__main__':
    sys.exit(main())
