// SPDX-License-Identifier: GPL-3.0-only
//! 装配：以每个钟点为锚把周围的日期、时段、时区、地点、目标、时长拼成「一次提到」，零散词交城市索引；
//! 再做几件整段的事：两个数字的日期按语言与地区定顺序（另一种顺序作备选）、点号连的两个数按语言定钟点还是日期、
//! 没写日期的沿用同一段落前一处的、AoE 截止默认 23:59、同一行只隔着分隔符的几处归成一个等价组。
use super::dates::{apply_period, date_order, days_from_civil, dot_reading, half_day, valid_month_day, DateOrder, DotReading};
use super::lexicon::{Period, Sem};
use super::scan::{is_han_place_char, words_after, Atom, Break, Located};
use super::text;
use super::types::{Alternative, Clock, DateSpec, Issue, Mention, Output, Part, Unresolved, Writer, ZoneRef};
use super::units::{find, matcher, UKind, Unit};
use std::collections::HashMap;
use std::sync::OnceLock;

pub(super) struct Context<'a> {
    pub(super) units: &'a [Unit],
    pub(super) folded: &'a text::Folded,
    pub(super) atoms: Vec<Located>,
    pub(super) lookup: &'a dyn Fn(&str, bool) -> Option<ZoneRef>,
    /// 每个单元所在的那一句拉丁字母都是小写（随手打的 `3pm tokyo`）：那一句的零散词不看首字母大写。按句判：按整段判时，
    /// 后面加一句大写开头的「Thanks!」就改了前面的读法（模糊测试的变形检查 查出）。
    pub(super) lowercase: Vec<bool>,
    /// 每个单元是不是一句（或冒号、括号之后）的第一个词。
    pub(super) initial: Vec<bool>,
    /// 用户所在地区（ISO 3166）与界面语言：只用来定「10/3」的顺序。
    pub(super) region: &'a str,
    pub(super) ui_language: &'a str,
    pub(super) destinations: Vec<super::targets::Phrase>,
    /// 原子按起点排好，且每个都是 from ≤ to：可以按位置二分取一段。
    pub(super) atoms_ordered: bool,
}

/// 一处提到在装配期间的内部记录（单元区间与行号只在这里用）。
struct Built {
    mention: Mention,
    unit_from: usize,
    unit_to: usize,
    series_span: Option<[usize; 2]>,
    paragraph: usize,
    /// 第几个句段（只问目标的下一句接回前一句时要看）。
    segment: usize,
    /// 写明是在前一处日期的次日。
    day_after_previous: bool,
    /// 没有写上下午的词形小时或光秃秃的小时。
    bare_hour: bool,
}

/// 等价组之间允许的分隔符。
const GROUP_PUNCT: [&str; 14] = ["/", "|", "=", "→", "-", ">", "·", ",", ";", "(", ")", "\"", ":", "\n"];

impl Context<'_> {
    /// 写得不成立的一段：原文与位置。
    fn issue(&self, kind: &'static str, mut from: usize, mut to: usize) -> Issue {
        // 词表短语折叠、切词的结果与本次输入无关，整个进程只算一次。
        static PREFIXES: OnceLock<Vec<Vec<String>>> = OnceLock::new();
        static SUFFIXES: OnceLock<Vec<Vec<String>>> = OnceLock::new();
        let words = |phrases: &[&str]| -> Vec<Vec<String>> {
            phrases.iter().map(|phrase| super::units::phrase_units(&text::fold_str(phrase))).collect()
        };
        let prefixes = PREFIXES.get_or_init(|| words(super::lexicon::ISSUE_PREFIXES));
        let suffixes = SUFFIXES.get_or_init(|| words(super::lexicon::ISSUE_SUFFIXES));
        let prefix = prefixes.iter().filter_map(|p| {
            (p.len() < to - from && p.iter().zip(&self.units[from..]).all(|(p, u)| *p == u.text)).then_some(p.len())
        }).max().unwrap_or(0);
        from += prefix;
        let suffix = suffixes.iter().filter(|_| kind == "conflictingDeadline").filter_map(|p| {
            (p.len() < to - from && p.iter().zip(&self.units[to.saturating_sub(p.len())..to]).all(|(p, u)| *p == u.text)).then_some(p.len())
        }).max().unwrap_or(0);
        to -= suffix;
        let text = super::units::original_text(self.folded, self.units[from].start, self.units[to - 1].end);
        Issue { kind, text, span: self.span_of(from, to) }
    }

    fn span_of(&self, from: usize, to: usize) -> [usize; 2] {
        let start = self.units[from].start;
        let end = self.units[to - 1].end;
        [self.folded.span[start].0, self.folded.span[end - 1].1]
    }

    /// 两个原子之间（`a.to .. b.from`）只有空白、逗号、连接词与「at / on / 的 / の」这类，就算挨着。
    fn adjacent(&self, a: usize, b: usize) -> bool {
        if a > b {
            return false;
        }
        let gap = &self.units[a..b];
        gap.len() <= 3
            && gap.iter().enumerate().all(|(k, t)| {
                (t.kind == UKind::Punct && matches!(t.text.as_str(), "," | "(" | ")" | "\"" | ":" | "\n"))
                    || find(self.units, a + k, |s| matches!(s, Sem::Stop | Sem::ClockBefore | Sem::Filler)).is_some()
            })
    }

    /// 后置日期只跨过标点、空白、该钟点的时区或地点及封闭日期连接词。
    /// 缝里同时有逗号、分号、顿号或短横与其它词时，后面的日期另成一处；
    /// 钟点保留原读法，是否沿用前文日期仍由段落继承决定。
    fn following_date_gap(&self, seg: &[Located], owned: &[usize], clock_from: usize, from: usize, to: usize) -> bool {
        let mut at = from;
        while at < to {
            if self.units[at].kind == UKind::Punct { at += 1; continue; }
            if let Some(atom) = owned.iter().map(|&k| &seg[k]).find(|a| a.from == at && a.to <= to
                && matches!(a.atom, Atom::Zone(_))) {
                at = atom.to;
                continue;
            }
            if let Some(words) = super::lexicon::DATE_LINK_WORDS.iter().find(|words|
                at + words.len() <= to && words.iter().zip(&self.units[at..]).all(|(word, unit)| *word == unit.text)) {
                at += words.len();
                continue;
            }
            if let Some(atom) = owned.iter().map(|&k| &seg[k]).find(|a| a.from == at && a.to <= to
                && self.location_attached(a.from, a.to, clock_from, from)
                && matches!(&a.atom, Atom::Place { text, strong, bare }
                    if self.resolved_place(text, *strong, a.from, a.to, bare.as_deref(), a.lang).is_some_and(|(_, end)| end == a.to))) {
                at = atom.to;
                continue;
            }
            // 零散地名也须精确命中并按原有规则紧邻钟点，不把别句的地点借过来。
            let word_end = (at..to).find(|&k| self.units[k].kind == UKind::Punct).unwrap_or(to);
            let place_end = (at + 1..=word_end).rev().find(|&end| {
                let text = super::units::original_text(self.folded, self.units[at].start, self.units[end - 1].end);
                self.location_attached(at, end, clock_from, from)
                    && self.resolved_place(&text, false, at, end, None, None).is_some()
            });
            if let Some(end) = place_end { at = end; } else { return false; }
        }
        true
    }

    /// 时长前的连接词按整个短语跨过，不能逐字拆开多字词。
    fn duration_adjacent(&self, a: usize, b: usize) -> bool {
        if a > b { return false; }
        let mut k = a;
        while k < b {
            if self.units[k].kind == UKind::Punct && matches!(self.units[k].text.as_str(), "," | "(" | ")" | "\"" | ":" | "\n") {
                k += 1;
            } else if let Some((n, _, _)) = find(self.units, k, |s| matches!(s, Sem::RangeSep | Sem::Stop | Sem::ClockBefore | Sem::Filler)) {
                if k + n > b { return false; }
                k += n;
            } else {
                return false;
            }
        }
        true
    }

    /// 一个原子（或零散词）挂在前一个锚上还是后一个锚上：与前一个锚之间没有逗号、分号、冒号、短横且不超过 3 个单元就挂前面，
    /// 否则挂后面；没有后面的就挂前面（「9am Tokyo, 2pm London」「Tokyo 9am, London 2pm」「Berlin 9:00 - Tokyo 16:00」都对）。
    /// 连成时间段的短横在锚里面，不在这个缝里。「>」「→」与区间词（to / bis / tot）跟短横一样隔开两次提到
    /// （两头都写日期的时间段隔得远时各归各）。
    fn attaches_to_previous(&self, prev_end: usize, start: usize) -> bool {
        if start < prev_end {
            return true;
        }
        let gap = &self.units[prev_end..start];
        gap.len() <= 3
            && !gap.iter().enumerate().any(|(k, t)| {
                (t.kind == UKind::Punct
                    && matches!(t.text.as_str(), "," | ";" | ":" | "。" | "、" | "\n\n" | "-" | "–" | "—" | "~" | "〜" | "～" | ">" | "→"))
                    || find(self.units, prev_end + k, |s| s == Sem::RangeSep).is_some()
            })
    }

    /// 钟点前后没被认出的词：可能是地名（「3pm Tokyo」「东京明早九点」「Встреча завтра в 10:00 Москва」）。
    /// 零散词的一段按词切开（起、止、字）：连字符与撇号夹在两个词中间的算一个词（Нью-Йорк、Winston-Salem）。
    fn loose_tokens(&self, s: usize, e: usize) -> Vec<(usize, usize, String)> {
        let u = self.units;
        let mut out = Vec::new();
        let mut j = s;
        while j < e {
            if u[j].kind != UKind::Word {
                j += 1;
                continue;
            }
            let start = j;
            let mut text = u[j].text.clone();
            j += 1;
            while j + 1 < e && glued_joint(u, j) {
                text.push_str(&u[j].text);
                text.push_str(&u[j + 1].text);
                j += 2;
            }
            out.push((start, j, text));
        }
        out
    }

    fn loose_words(&self, from: usize, to: usize, taken: &[bool]) -> Vec<(String, usize, usize)> {
        let u = self.units;
        let mut out = Vec::new();
        let mut j = from;
        while j < to {
            if taken[j] || u[j].kind == UKind::Number || u[j].kind == UKind::Punct {
                j += 1;
                continue;
            }
            if u[j].kind == UKind::Cjk {
                let start = j;
                let mut s = String::new();
                // 空格处断开：韩语词与词之间有空格（「뉴욕처럼 입력할 수 있습니다」此前连成一串去查，纽约丢了）。
                // 一段最多 12 个字（布宜诺斯艾利斯 7 个、サンクトペテルブルク 9 个都装得下）。
                while j < to && !taken[j] && u[j].kind == UKind::Cjk && (j == start || !u[j].space_before) && s.chars().count() < 12 {
                    // 单字虚词截断。
                    let hangul_word = u[start].raw.chars().all(super::text::is_hangul);
                    if !hangul_word && find(u, j, |x| matches!(x, Sem::Stop | Sem::Filler)).is_some_and(|(n, _, _)| n >= 1) && !is_han_place_char(u, j) {
                        break;
                    }
                    if let Some((n, _, _)) = find(u, j, |x| matches!(x, Sem::Stop)) {
                        if n >= 2 && !hangul_word {
                            break;
                        }
                    }
                    s.push_str(&u[j].text);
                    j += 1;
                }
                if !s.is_empty() {
                    out.push((s, start, j));
                } else {
                    j += 1;
                }
                continue;
            }
            // 拉丁词：连续的非时间词，最多 5 个；连字符与撇号夹在两个词中间的算一个词（Нью-Йорк、Winston-Salem；词表里的「-」
            // 是时间段分隔符，可能已被认成原子，所以这里不看它 taken 没有）。零散词分几个窗口取，连字符词可以越过窗口的尾巴
            // 拼完；下一个窗口从它的后半截开始时跳过（「3pm Winston-Salem」此前在连字符处被切开，Salem 对上了印度的塞勒姆）。
            if glued_joint(u, j.saturating_sub(1)) && j > 0 {
                j += 1;
                continue;
            }
            let start = j;
            let mut words = Vec::new();
            while j < to && (!taken[j] || CITY_HEAD_GLUE.contains(&u[j].text.as_str()) && words.first().is_some_and(|head: &String| CITY_HEADS.contains(&head.as_str()))) && u[j].kind == UKind::Word && words.len() < 6 {
                // 有词义的时间词（hora / heure / de / to）不当地名（「9am hora de」此前查到乌克兰的 Kholodna Hora）。
                // 虚词只在一段的开头截断：Ho Chi Minh 的 minh、Città del Messico 的 del 都在词表里，带着它们整段先去查
                // （整段被切碎，最后 chi 一个词对上了芝加哥）。
                let time_word = find(u, j, |x| {
                    matches!(x, Sem::Connector | Sem::HourUnit | Sem::MinuteUnit | Sem::DayUnit | Sem::ClockAfter | Sem::ClockBefore | Sem::ClockHourBefore | Sem::From | Sem::RangeSep)
                })
                .is_some();
                if time_word && !(CITY_HEAD_GLUE.contains(&u[j].text.as_str()) && words.first().is_some_and(|head: &String| CITY_HEADS.contains(&head.as_str()))) || (words.is_empty() && (find(u, j, |x| matches!(x, Sem::Stop)).is_some() && !(u[j].capital && ["los", "las", "la", "le", "el", "il", "l"][..].contains(&u[j].text.as_str()) && u.get(j + 1).is_some_and(|t| t.capital)) || super::language::ordinary_noun(u, j))) {
                    break;
                }
                let mut word = u[j].text.clone();
                j += 1;
                while j + 1 < u.len() && glued_joint(u, j) && !taken[j + 1] {
                    word.push_str(&u[j].text);
                    word.push_str(&u[j + 1].text);
                    j += 2;
                }
                words.push(word);
            }
            if words.is_empty() {
                j += 1;
            } else {
                out.push((words.join(" "), start, j));
            }
        }
        out
    }

    /// 这几个原子里词表命中最多的语言（同数取先出现的）。
    fn vote(atoms: &[Located]) -> Option<&'static str> {
        let mut counts: Vec<(&'static str, usize)> = Vec::new();
        for a in atoms {
            let Some(lang) = a.lang.filter(|l| !l.is_empty()) else { continue };
            if let Some(entry) = counts.iter_mut().find(|(l, _)| *l == lang) {
                entry.1 += 1;
            } else {
                counts.push((lang, 1));
            }
        }
        counts.iter().max_by_key(|(_, n)| *n).map(|(l, _)| *l)
    }

    /// 两个日期隔几天：都写全（绝对日期）按公历算；都是月日时，同一个月份的下一天算 1、相同算 0；其余比不出。
    fn day_gap(a: &DateSpec, b: &DateSpec) -> Option<i64> {
        if let (DateSpec::Absolute { year: y1, month: m1, day: d1 }, DateSpec::Absolute { year: y2, month: m2, day: d2 }) = (a, b) {
            return Some(days_from_civil(*y2, *m2, *d2) - days_from_civil(*y1, *m1, *d1));
        }
        match (a, b) {
            (DateSpec::MonthDay { month: m1, day: d1 }, DateSpec::MonthDay { month: m2, day: d2 }) if m1 == m2 && *d2 == *d1 + 1 => Some(1),
            (x, y) if x == y => Some(0),
            _ => None,
        }
    }

    // 只推进能由日期本身确定的次日。
    fn next_day(date: &DateSpec) -> Option<DateSpec> {
        match *date {
            DateSpec::Absolute { year, month, day } => {
                let (year, month, day) = if super::dates::valid_date(year, month, day + 1) {
                    (year, month, day + 1)
                } else if month < 12 {
                    (year, month + 1, 1)
                } else {
                    (year.checked_add(1)?, 1, 1)
                };
                super::dates::valid_date(year, month, day).then_some(DateSpec::Absolute { year, month, day })
            }
            DateSpec::MonthDay { month: 2, day: 28 } => None,
            DateSpec::MonthDay { month, day } => {
                let (month, day) = if valid_month_day(month, day + 1) {
                    (month, day + 1)
                } else {
                    (if month == 12 { 1 } else { month + 1 }, 1)
                };
                valid_month_day(month, day).then_some(DateSpec::MonthDay { month, day })
            }
            DateSpec::Offset { days } => days.checked_add(1).map(|days| DateSpec::Offset { days }),
            DateSpec::Weekday { weekday, week: Some(week) } if weekday < 7 => Some(DateSpec::Weekday { weekday: weekday + 1, week: Some(week) }),
            DateSpec::Weekday { weekday: 7, week: Some("last") } => Some(DateSpec::Weekday { weekday: 1, week: Some("this") }),
            DateSpec::Weekday { weekday: 7, week: Some("this") } => Some(DateSpec::Weekday { weekday: 1, week: Some("next") }),
            DateSpec::Weekday { .. } => None,
        }
    }

    /// 地名查表。冠词带出来的（`bare` 有值：the United States、los Estados Unidos、aux États-Unis、no Brasil）先拿去掉冠词的
    /// 认国家名，再把首字母大写的按原样当零散词查（La Paz、The Hague 本来就带冠词；零散词只认够有名的）；都没有就当没有线索，
    /// 调用处不记「没认出」（in the office、en la plaza、au bureau 不是地名）。小写的不查城市：「la plaza」的别名能对上
    /// 阿根廷的 Presidencia de la Plaza，「Brasil」能对上巴伊亚的 Pau Brasil。
    /// 有明确线索（w X、в X、czas w X、время в X）而原样查不到时，按线索语言试变格还原后的原形（w Nowym Jorku → Nowy Jork）。
    fn find_place(&self, text: &str, strong: bool, bare: Option<&str>, lang: Option<&str>) -> Option<ZoneRef> {
        let direct = match bare {
            None => (self.lookup)(text, strong).or_else(|| strong.then(|| super::places::country_lookup(text)).flatten()),
            // 「X 时间 / X time」：照有线索查（成都时间、osaka time），查不到当没有线索。
            Some("") => (self.lookup)(text, strong),
            Some(bare) => super::places::country_lookup(bare)
                .or_else(|| (lang != Some("de") && bare.chars().next().is_some_and(char::is_uppercase)).then(|| (self.lookup)(text, false)).flatten()),
        };
        if direct.is_some() || !strong || bare.is_some() {
            return direct;
        }
        match restore_inflected_place(text, lang) {
            Some(base) => (self.lookup)(&base, true),
            None => direct,
        }
    }

    /// Lowercase place heads in mixed-case text need an exact big-city name.
    /// Lowercase-only sentences, uncased scripts and German keep their rules.
    fn lowercase_place_needs_big_city(&self, text: &str, s: usize, bare: Option<&str>, lang: Option<&str>) -> bool {
        if lang == Some("de") || self.lowercase[s] || bare == Some("") { return false; }
        let case_marker = self.tr_suffixed(s).is_some()
            || text.split_once(['\'', '’']).is_some_and(|(_, suffix)| ["da", "de", "ta", "te", "nda", "nde", "daki", "deki", "taki", "teki", "ndaki", "ndeki"].contains(&suffix));
        let place_cue = find(self.units, s, |sem| matches!(sem, Sem::PlaceIn | Sem::PlaceInArticle | Sem::ZoneBefore | Sem::SelfLocation)).is_some()
            || find(self.units, s, |sem| sem == Sem::TargetTo).is_some_and(|(_, _, language)| !language.is_empty() && language != "zh")
            || find(self.units, s, |sem| sem == Sem::TargetAsk).is_some_and(|(n, _, _)| (s..s + n).any(|k| {
                find(self.units, k, |sem| matches!(sem, Sem::PlaceIn | Sem::PlaceInArticle)).is_some_and(|(width, _, _)| k + width == s + n)
            }));
        if !place_cue && !case_marker {
            return false;
        }
        if case_marker && !place_cue && self.units[s].capital || bare.unwrap_or(text).chars().next().is_none_or(|c| !c.is_lowercase()) { return false; }
        // Shared cues such as "in" may carry English even in a German clause.
        // Use the same segment vote as the existing German loose-place rule.
        let start = self.atoms.iter().rposition(|a| a.to <= s && matches!(a.atom, Atom::Boundary(_))).map_or(0, |k| k + 1);
        let end = self.atoms.iter().position(|a| a.from > s && matches!(a.atom, Atom::Boundary(_))).unwrap_or(self.atoms.len());
        Self::vote(&self.atoms[start..end]) != Some("de")
    }

    fn exact_big_city(&self, text: &str) -> Option<ZoneRef> {
        // Weak lookup skips country and adjective/inflection restoration. The
        // apostrophe in a Turkish case marker still leaves an exact city stem.
        let zone = super::places::with_exact_city_spelling(|| (self.lookup)(text, false))?;
        let primary = match &zone {
            ZoneRef::Options { reason: "city", options } => options.first()?,
            city => city,
        };
        matches!(primary, ZoneRef::City { city_index, .. } if *city_index < super::places::BIG_CITY_LIMIT).then_some(zone)
    }

    fn place_candidate_fits(&self, text: &str, s: usize, bare: Option<&str>, lang: Option<&str>) -> bool {
        // 在后面紧贴的未知汉字串没有名字边界，不从整句话猜地点。
        if self.units[s].text == "在" && bare.is_none() {
            if ["家", "门口", "門口", "楼下", "樓下", "办公室", "辦公室"].iter().any(|word| text.starts_with(word)) { return false; }
            if self.units.get(s + 1).is_some_and(|unit| unit.kind == UKind::Cjk && !unit.space_before)
                && text.chars().all(super::text::is_cjk)
                && !text.char_indices().skip(1).map(|(end, _)| &text[..end]).chain(std::iter::once(text))
                    .any(|head| self.find_place(head, true, None, lang).is_some()) { return false; }
        }
        if !self.lowercase_place_needs_big_city(text, s, bare, lang) { return true; }
        let mut head = text;
        let article_words = bare.map_or(0, |noun| text.split_whitespace().count().saturating_sub(noun.split_whitespace().count()));
        loop {
            if head.split_whitespace().count() <= article_words { return false; }
            if self.exact_big_city(head).is_some() { return true; }
            let Some((shorter, _)) = head.rsplit_once(' ') else { return false; };
            head = shorter;
        }
    }

    fn find_candidate_place(&self, text: &str, strong: bool, s: usize, bare: Option<&str>, lang: Option<&str>) -> Option<ZoneRef> {
        if self.lowercase_place_needs_big_city(text, s, bare, lang) {
            self.exact_big_city(text)
        } else {
            self.find_place(text, strong, bare, lang)
        }
    }

    /// Resolve the name before deciding whether the phrase modifies the clock.
    /// Ordinary words following a location name stay outside its understood span.
    fn resolved_place(&self, text: &str, strong: bool, s: usize, e: usize, bare: Option<&str>, lang: Option<&str>) -> Option<(ZoneRef, usize)> {
        if !self.place_candidate_fits(text, s, bare, lang) { return None; }
        if let Some(zone) = self.find_candidate_place(text, strong, s, bare, lang) { return Some((zone, e)); }
        if !strong || bare == Some("") { return None; }
        let u = self.units;
        let name_start = s + find(u, s, |sem| matches!(sem, Sem::PlaceIn | Sem::PlaceInArticle | Sem::ZoneBefore | Sem::SelfLocation | Sem::TargetTo | Sem::TargetAsk)).map_or(0, |(n, _, _)| n);
        let article_words = self.lowercase_place_needs_big_city(text, s, bare, lang).then(|| bare.map_or(0, |noun| text.split_whitespace().count().saturating_sub(noun.split_whitespace().count())));
        for end in (s + 1..e).rev() {
            if end <= name_start { continue; }
            let cjk = u.get(name_start).is_some_and(|unit| unit.kind == UKind::Cjk)
                && u[name_start..end].iter().all(|unit| unit.kind == UKind::Cjk);
            if !cjk && (u[end].kind != UKind::Word || !u[end].space_before) { continue; }
            let trimmed = super::units::original_text(self.folded, u[name_start].start, u[end - 1].end);
            if article_words.is_some_and(|count| trimmed.split_whitespace().count() <= count) { continue; }
            let bare = bare.map(|b| b.rsplitn(u[end..e].iter().filter(|t| t.kind == UKind::Word).count() + 1, ' ').last().unwrap_or(b));
            if let Some(zone) = self.find_candidate_place(&trimmed, true, s, bare, lang) { return Some((zone, end)); }
        }
        None
    }

    fn resolved_target(&self, text: &str, s: usize, e: usize, bare: Option<&str>, lang: Option<&str>) -> Option<(ZoneRef, usize)> {
        if self.lowercase_place_needs_big_city(text, s, bare, lang) {
            self.resolved_place(text, true, s, e, bare, lang)
        } else {
            self.find_place(text, true, bare, lang).map(|zone| (zone, e))
        }
    }

    fn loose_attached(&self, s: usize, e: usize, clock_from: usize, clock_to: usize) -> bool {
        let (a, b) = if e <= clock_from { (e, clock_from) } else if s >= clock_to { (clock_to, s) } else { return true; };
        if b - a > 5 { return false; }
        let mut k = a;
        while k < b {
            let t = &self.units[k];
            if t.kind == UKind::Punct && (matches!(t.text.as_str(), "(" | ")" | "\"")
                || t.text == "," && s >= clock_to && b - a == 1 && (self.units[s].capital || self.units[s].kind == UKind::Cjk)) { k += 1; }
            else if let Some((n, _, _)) = find(self.units, k, |sem| matches!(sem, Sem::ClockBefore | Sem::Period(_) | Sem::RelDay(_) | Sem::RelDayPeriod(..))) { k += n; }
            else if matches!(t.text.as_str(), "的" | "の" | "に" | "は" | "에" | "는" | "은") { k += 1; }
            else { return false; }
        }
        k == b
    }

    /// 完整日期只连接紧挨日期与钟点的地名，普通叙述仍交原来的连接规则。
    fn calendar_date_attached(&self, s: usize, e: usize, clock_from: usize) -> bool {
        if e > clock_from { return false; }
        // 要找的日期落在 e..clock_from 之间：原子有序时只看起点在这一段里的。
        let window = if self.atoms_ordered {
            let first = self.atoms.partition_point(|atom| atom.from < e);
            &self.atoms[first..first + self.atoms[first..].partition_point(|atom| atom.from <= clock_from)]
        } else {
            &self.atoms[..]
        };
        window.iter().filter(|atom| {
            matches!(atom.atom, Atom::Date(_) | Atom::DatePeriod(..))
                && e <= atom.from && atom.to <= clock_from
        }).any(|date| {
            self.loose_attached(s, e, date.from, date.from)
                && self.loose_attached(date.to, date.to, clock_from, clock_from)
        })
    }

    fn location_attached(&self, s: usize, e: usize, clock_from: usize, clock_to: usize) -> bool {
        if self.loose_attached(s, e, clock_from, clock_to) { return true; }
        if s >= clock_to && s - clock_to <= 6 {
            let mut k = clock_to;
            while k < s {
                let t = &self.units[k];
                if t.text == "'" && self.units.get(k + 1).is_some_and(|t| ["da", "de", "ta", "te"].contains(&t.text.as_str())) { k += 2; }
                else if t.text == "," { k += 1; }
                else if let Some((n, _, _)) = find(self.units, k, |sem| matches!(sem, Sem::Period(_) | Sem::ClockBefore)) { k += n; }
                else if ["ci", "vediamo", "is", "het", "minh", "ra", "don", "ban", "ご", "ろ", "頃", "て", "で", "sind", "wir", "spielen", "treffen", "uns", "on", "se", "retrouve", "quedamos", "llegamos", "llego", "到", "到了", "的", "の", "に", "は", "에", "는", "은"].contains(&t.text.as_str()) { k += 1; }
                else { break; }
            }
            if k == s { return true; }
        }
        if self.calendar_date_attached(s, e, clock_from) { return true; }
        if e > clock_from || clock_from - e > 6 { return false; }
        let mut k = e;
        while k < clock_from {
            if matches!(self.units[k].text.as_str(), "的" | "の" | "に" | "は" | "て" | "で" | "에" | "는" | "은")
                || self.units[k].text == "," && find(self.units, k + 1, |sem| matches!(sem, Sem::ClockBefore)).is_some() { k += 1; }
            else if let Some((n, _, _)) = find(self.units, k, |sem| matches!(sem, Sem::Period(_) | Sem::ClockBefore)) { k += n; }
            else { return false; }
        }
        k == clock_from
    }

    /// Counterpart and travel grammar does not identify the clock's location.
    fn excluded_place_role(&self, s: usize, e: usize, clock_from: usize, clock_to: usize, lang: Option<&str>) -> bool {
        let u = self.units;
        let boundary = |t: &Unit| t.kind == UKind::Punct && matches!(t.text.as_str(), "." | "!" | "?" | ";" | "。" | "；" | "\n\n");
        let start = u[..s].iter().rposition(|t| boundary(t) || t.text == ",").map_or(0, |k| k + 1).max(if clock_to <= s { clock_to } else { 0 });
        let counterpart = ["with", "mit", "avec", "con", "com", "met", "z", "ze", "с", "со", "ile", "voi", "dengan"];
        let direction = ["to", "naar", "nach", "vers", "hacia", "para", "do"];
        if u[start..s].iter().rev().take(5).any(|t| counterpart.contains(&t.text.as_str()))
            && !(self.location_attached(s, e, clock_from, clock_to) && find(u, s, |sem| sem == Sem::PlaceIn).is_some()) { return true; }
        if s > start && direction.contains(&u[s - 1].text.as_str()) { return true; }
        let named: String = u[s..e].iter().map(|t| t.text.as_str()).collect();
        // Russian в marks either a destination or a location; the prepositional case retains a departure location.
        if lang == Some("ru") && s > start && u[s].text == "в" && u[s - 1].text == "вылет"
            && !["е", "ии", "ах", "ях"].iter().any(|ending| named.ends_with(ending)) { return true; }
        if named.ends_with('へ') { return true; }
        if ["으로", "로", "와", "과"].iter().any(|suffix| named.strip_suffix(suffix).is_some_and(|stem| self.find_place(stem, true, None, Some("ko")).is_some())) { return true; }
        if named.split_once('\'').is_some_and(|(_, suffix)| ["ya", "ye", "na", "ne"].contains(&suffix))
            && !(s >= clock_to && u.get(e).is_some_and(|t| t.text == "variyor")) { return true; }
        if u[s].text == "a" && u[start..s].iter().any(|t| ["vuelo", "viaje", "tren", "flight", "train", "treno", "voo"].contains(&t.text.as_str())) { return true; }
        let limit = if e <= clock_from { clock_from } else { (e + 12).min(u.len()) };
        let after: String = u[e..limit].iter().take_while(|t| !boundary(t)).map(|t| t.text.as_str()).collect();
        if after.starts_with("가는") || after.starts_with("행") { return true; }
        if after.starts_with(['へ', '로', '와', '과']) || after.starts_with("으로") { return true; }
        if after.contains("チームと") || after.contains("工場と") || after.starts_with('と') { return true; }
        if after.contains("지사와") || after.contains("팀과") || after.contains("동생과") || after.contains("물류팀과") { return true; }
        lang == Some("tr") && u[s..limit].iter().take_while(|t| !boundary(t)).any(|t| t.text.ends_with("yle") || t.text.ends_with("yla"))
    }

    /// 「我在哪儿」的说法（I'm in Berlin、我在上海、東京にいます、서울에 있어요、İstanbul'dayım）：封闭表 cue
    /// （`Sem::SelfLocation`）+ 查得到的地名（日、韩、土的地名在 cue 前，土语是撇号后面的后缀）。第一个成立的说法赢：
    /// 报出 `Writer`，并吃掉说法里的地名——重叠的地点 / 目标原子删掉、单元标成已占，装配时不再作零散来源或目标；最后按 9b 为同句的钟点给地点建议。
    /// 查不到地名的 cue（I'm in a meeting、ich bin in Eile）不算说法，整段照旧读。
    fn detect_writer(&self, atoms: &mut Vec<Located>, taken: &mut [bool]) -> Option<Writer> {
        let u = self.units;
        for i in 0..u.len() {
            if taken[i] { continue; }
            // （地名，单元起，单元止，去冠词的地名）。
            // 最后一项是说法的语言：变格语言（jestem w Warszawie、я в Москве）按它还原地名原形。
            let mut hit: Option<WriterHit> = None;
            if let Some((n, _, lang)) = find(u, i, |s| s == Sem::SelfLocation) {
                if matches!(lang, "ja" | "ko" | "tr") {
                    hit = self.place_before(i).map(|(text, from)| (text, from, i + n, None, Some(lang)));
                } else {
                    let (text, end, bare) = words_after(u, i + n, 3, true);
                    if !text.is_empty() {
                        hit = Some((text, i, end, bare, Some(lang)));
                    }
                }
            }
            // 土耳其语的后缀粘在带撇号的地名后面（İstanbul'dayım、Ankara'da yaşıyorum）。
            if hit.is_none() {
                hit = self.tr_suffixed(i).map(|(text, end)| {
                    let raw = self.lowercase_place_needs_big_city(&text, i, None, Some("tr"))
                        .then(|| u[i].raw.rsplit_once(['\'', '’', '‘', '`', '´', 'ʼ', '＇']).map(|(stem, _)| stem)).flatten();
                    (raw.map(str::to_owned).unwrap_or(text), i, end, None, Some("tr"))
                });
            }
            let Some((text, from, to, bare, lang)) = hit else { continue };
            if taken[from..to].iter().any(|t| *t) { continue; }
            let Some((place, to)) = self.resolved_place(&text, true, from, to, bare.as_deref(), lang) else { continue };
            atoms.retain(|a| !(a.from < to && from < a.to && matches!(a.atom, Atom::Place { .. } | Atom::Target { .. })));
            for t in taken.iter_mut().take(to).skip(from) {
                *t = true;
            }
            return Some(Writer { place, span: self.span_of(from, to) });
        }
        None
    }

    /// cue 前面连着的中日韩地名（東京にいます、서울에 있어요）：逐字往前走到空格或虚词为止。
    fn place_before(&self, cue: usize) -> Option<(String, usize)> {
        let u = self.units;
        let mut j = cue;
        while j > 0 && !u[j].space_before && u[j - 1].kind == UKind::Cjk {
            if find(u, j - 1, |s| matches!(s, Sem::Stop | Sem::Filler)).is_some_and(|(n, _, _)| n >= 1) && !is_han_place_char(u, j - 1) {
                break;
            }
            if find(u, j - 1, |s| s == Sem::Stop).is_some_and(|(n, _, _)| n >= 2) {
                break;
            }
            j -= 1;
        }
        (j < cue).then(|| (u[j..cue].iter().map(|t| t.text.as_str()).collect::<String>(), j))
    }

    /// 带撇号的土耳其语词（İstanbul'dayım、Ankara'da yaşıyorum）：最后一个撇号后面是对上封闭表的后缀，前面是地名。
    /// （地名，吃掉的单元数）。
    fn tr_suffixed(&self, i: usize) -> Option<(String, usize)> {
        let u = self.units;
        let t = &u[i];
        if t.kind != UKind::Word {
            return None;
        }
        let (place, tail) = t.text.rsplit_once('\'')?;
        if place.is_empty() || tail.is_empty() {
            return None;
        }
        let base: Vec<String> = text::tokens(&text::fold(tail)).into_iter().map(|x| x.text).collect();
        for phrase in matcher().by_first.get("'")? {
            let units = &phrase.units;
            if units.len() < 2 || units[0] != "'" || !phrase.sems.iter().any(|(s, _)| *s == Sem::SelfLocation) {
                continue;
            }
            let mut seq = base.clone();
            let mut k = i + 1;
            while seq.len() < units.len() - 1 && k < u.len() {
                seq.push(u[k].text.clone());
                k += 1;
            }
            if seq.len() == units.len() - 1 && (0..seq.len()).all(|x| seq[x] == units[x + 1]) {
                return Some((place.to_owned(), k - i));
            }
        }
        None
    }

    /// 点号两数原子是时间段的一端，另一端是写明的钟点（「17.00 - 19.00 Uhr」）或时间段后面紧跟时区（「10.00 – 12.00 WIB」）：
    /// 这是钟点，不看这句是什么语言（印尼语那句没有别的语言票，德语那句按日期读、0 月不成立，都丢了一端）。
    fn dot_pair_in_clock_range(atoms: &[Located], k: usize) -> bool {
        if !matches!(atoms[k].atom, Atom::DotPair { .. }) {
            return false;
        }
        let end = |x: &Located| matches!(x.atom, Atom::Clock { .. } | Atom::DotPair { .. });
        let joined = |x: usize, y: usize| atoms[x].to == atoms[y].from;
        let range = |sep: usize| matches!(atoms[sep].atom, Atom::RangeSep);
        let (lo, hi) = if k + 2 < atoms.len() && range(k + 1) && joined(k, k + 1) && joined(k + 1, k + 2) && end(&atoms[k + 2]) {
            (k, k + 2)
        } else if k >= 2 && range(k - 1) && joined(k - 1, k) && joined(k - 2, k - 1) && end(&atoms[k - 2]) {
            (k - 2, k)
        } else {
            return false;
        };
        let other = if lo == k { &atoms[hi] } else { &atoms[lo] };
        matches!(other.atom, Atom::Clock { explicit: true, .. })
            || atoms.get(hi + 1).is_some_and(|z| matches!(z.atom, Atom::Zone(_)) && z.from == atoms[hi].to)
    }

    /// 「10/3」「15.03」这类留给装配的两数原子，按这句的语言与用户地区定成钟点或日期，另一种读法作备选。
    fn resolve_pair(&self, located: &Located, lang: Option<&str>, clock_range: bool, clock_follows: bool) -> Option<(Atom, Option<Alternative>)> {
        match &located.atom {
            Atom::SlashPair { a, b, year } => {
                let order = date_order(lang, self.region, self.ui_language);
                let ((month, day), (alt_month, alt_day)) = match order {
                    DateOrder::MonthDay => ((*a, *b), (*b, *a)),
                    DateOrder::DayMonth => ((*b, *a), (*a, *b)),
                };
                let make = |month: u8, day: u8| -> Option<DateSpec> {
                    match year {
                        Some(y) => super::dates::valid_date(*y, month, day).then_some(DateSpec::Absolute { year: *y, month, day }),
                        None => valid_month_day(month, day).then_some(DateSpec::MonthDay { month, day }),
                    }
                };
                let primary = make(month, day).or_else(|| make(alt_month, alt_day))?;
                let alt = make(alt_month, alt_day).filter(|d| *d != primary).map(|date| Alternative::DateOrder { date });
                Some((Atom::Date(primary), alt))
            }
            Atom::DotPair { a, b } => {
                let clock = (*a <= 23 && *b <= 59).then(|| Clock::at(*a, *b));
                let date_dm = valid_month_day(*b, *a).then_some(DateSpec::MonthDay { month: *b, day: *a });
                let date_md = valid_month_day(*a, *b).then_some(DateSpec::MonthDay { month: *a, day: *b });
                let as_clock = |clock: Clock| (Atom::Clock { clock, period: None, explicit: true }, date_dm.clone().map(|date| Alternative::DotDate { date }));
                if clock_range {
                    if let Some(clock) = clock {
                        return Some(as_clock(clock));
                    }
                }
                if clock_follows {
                    let date = if dot_reading(lang) == DotReading::MonthDayOnly { date_md.clone().or(date_dm.clone()) } else { date_dm.clone() };
                    if let Some(date) = date {
                        // 后面写明钟点时，前面的点号两数只作日期。
                        return Some((Atom::Date(date), None));
                    }
                }
                match dot_reading(lang) {
                    DotReading::ClockFirst => clock.map(as_clock),
                    // 德、俄语也用点号写钟点（「Beginn: 17.00」「в 17.00」）：日期不成立（没有 0 月）时读成钟点。
                    DotReading::DateFirst => match date_dm {
                        Some(date) => Some((Atom::Date(date), clock.map(|time| Alternative::DotClock { time }))),
                        None => clock.map(as_clock),
                    },
                    DotReading::MonthDayOnly => date_md.map(|date| (Atom::Date(date), None)),
                    DotReading::None => None,
                }
            }
            _ => None,
        }
    }

    pub(super) fn assemble(&self) -> Output {
        let u = self.units;
        let destinations = &self.destinations;
        // 「我在哪儿」的说法先认：成立时吃掉自己的地名（那段单元不再当任何一处的零散词），并给出写这句话的人在哪儿；同句的钟点在 finish 中可采用地点建议。
        let mut atoms = self.atoms.clone();
        let mut taken = vec![false; u.len()];
        // A target's place and grammar cannot become a source or a sentence
        // suggestion. Reserve the entire explicit phrase before loose lookup.
        for p in destinations { taken[p.from..p.to].fill(true); }
        let writer = self.detect_writer(&mut atoms, &mut taken);
        let all_atoms = &atoms;
        // Only clocks recognized from the written grammar decide preceding pairs.
        // One reverse pass covers prose gaps and soft wraps within a paragraph.
        let mut explicit_clock_follows = vec![false; all_atoms.len()];
        let mut clock_follows = false;
        for (k, a) in all_atoms.iter().enumerate().rev() {
            if matches!(a.atom, Atom::Boundary(Break::Paragraph)) { clock_follows = false; }
            explicit_clock_follows[k] = clock_follows;
            if matches!(a.atom, Atom::Clock { explicit: true, .. }) { clock_follows = true; }
        }
        for a in all_atoms.iter() {
            if !matches!(a.atom, Atom::Boundary(_)) {
                for t in taken.iter_mut().take(a.to).skip(a.from) {
                    *t = true;
                }
            }
        }
        // 全文的语言票（给宿主，也作句段判不出语言时的回退）。
        let mut counts: HashMap<&'static str, usize> = HashMap::new();
        for a in all_atoms {
            if let Some(l) = a.lang.filter(|l| !l.is_empty()) {
                *counts.entry(l).or_default() += 1;
            }
        }
        let mut languages: Vec<(&'static str, usize)> = counts.into_iter().collect();
        languages.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
        let text_lang = languages.first().map(|(l, _)| *l);

        // 句段：按边界切；每段记它在单元里的范围与段落号（空行加一）。
        let mut segments: Vec<(usize, usize, usize, usize, usize)> = Vec::new(); // (atom lo, atom hi, unit lo, unit hi, paragraph)
        let (mut start, mut unit_start, mut paragraph) = (0, 0, 0usize);
        for (k, a) in all_atoms.iter().enumerate() {
            if let Atom::Boundary(kind) = a.atom {
                segments.push((start, k, unit_start, a.from, paragraph));
                start = k + 1;
                unit_start = a.to;
                if kind == Break::Paragraph {
                    paragraph += 1;
                }
            }
        }
        segments.push((start, all_atoms.len(), unit_start, u.len(), paragraph));

        let mut built: Vec<Built> = Vec::new();
        // 没有独立提到的日期也能截断旧标题，须在筛掉日期锚之前保留位置。
        let mut written_dates = Vec::new();
        // 次日原子很少，先记下位置，下面两处只看它们。
        let next_days: Vec<usize> = all_atoms.iter().enumerate()
            .filter(|(_, a)| matches!(a.atom, Atom::NextDay(_))).map(|(k, _)| k).collect();
        let day_after_previous = |m: &Mention| {
            next_days.iter().map(|&k| &all_atoms[k]).any(|a| {
                m.parts.iter().any(|p| p.kind == "date" && p.span == self.span_of(a.from, a.to))
            })
        };
        // 独立的次日标题只在同段后面还有钟点时保留。
        let next_day_heading = |a: &Located| {
            next_days.iter().copied().find(|&k| {
                let original = &all_atoms[k];
                original.from == a.from && original.to == a.to
            }).is_some_and(|index| {
                all_atoms[index + 1..].iter()
                    .take_while(|next| !matches!(next.atom, Atom::Boundary(Break::Paragraph)))
                    .any(|next| matches!(next.atom, Atom::Clock { .. }))
            })
        };
        // 只问目标的句子（「What time in Tokyo?」）：（句段号，段落号，地名，单元起止），最后接回前一句恰好那一处。
        let mut pending_targets: Vec<(usize, usize, String, Option<String>, usize, usize)> = Vec::new();
        for (seg_index, (s0, s1, seg_unit_start, seg_unit_end, paragraph)) in segments.into_iter().enumerate() {
            if s0 >= s1 {
                continue;
            }
            let seg_lang = Self::vote(&all_atoms[s0..s1]).or(text_lang);
            // 两数原子按语言定下来；定不下来的（英文里的「2.10」）整个拿掉。
            let mut seg: Vec<Located> = Vec::new();
            let mut alts: Vec<Option<Alternative>> = Vec::new();
            let mut from_pair: Vec<bool> = Vec::new();
            let here = &all_atoms[s0..s1];
            for (k, a) in here.iter().enumerate() {
                if matches!(a.atom, Atom::SlashPair { .. } | Atom::DotPair { .. }) {
                    if let Some((atom, alt)) = self.resolve_pair(a, seg_lang, Self::dot_pair_in_clock_range(here, k), explicit_clock_follows[s0 + k]) {
                        seg.push(Located { atom, from: a.from, to: a.to, lang: a.lang });
                        alts.push(alt);
                        from_pair.push(true);
                    }
                } else {
                    let mut located = a.clone();
                    if let Atom::NextDay(period) = located.atom {
                        located.atom = match period {
                            Some(period) => Atom::DatePeriod(DateSpec::Offset { days: 1 }, period),
                            None => Atom::Date(DateSpec::Offset { days: 1 }),
                        };
                    }
                    seg.push(located);
                    alts.push(None);
                    from_pair.push(false);
                }
            }
            if seg.is_empty() {
                continue;
            }
            // 起用日没有自有钟点时，只是日期区间的起头，不给结束日期添冲突。
            let mut start_dates = Vec::new();
            for (k, start) in seg.iter().enumerate() {
                if !matches!(start.atom, Atom::Date(DateSpec::Offset { .. }))
                    || seg[..k].iter().any(|previous| matches!(previous.atom, Atom::Clock { .. } | Atom::Idiom(..))
                        && self.adjacent(previous.to, start.from)) { continue; }
                let Some(end) = seg.get(k + 2) else { continue; };
                if matches!(seg.get(k + 1).map(|a| &a.atom), Some(Atom::RangeSep))
                    && matches!(end.atom, Atom::Date(DateSpec::Absolute { .. } | DateSpec::MonthDay { .. }))
                    && self.adjacent(start.to, seg[k + 1].from) && self.adjacent(seg[k + 1].to, end.from)
                {
                    start_dates.push(k);
                }
            }
            for k in start_dates.into_iter().rev() {
                seg.remove(k); alts.remove(k); from_pair.remove(k);
            }
            super::series::share_range_years(self.units, &mut seg, &alts);
            written_dates.extend(seg.iter()
                .filter(|a| matches!(a.atom, Atom::Date(_) | Atom::DatePeriod(..) | Atom::Invalid("invalidDate")))
                .map(|a| (a.from, a.to)));
            // 两头都写了日期的时间段（「24 fev - 2025 • 13:00 > 24 fev - 2025 • 19:00」）：同一天或差一天并成一处
            // （只在日期差一天时把终点放在第二天）；差得更远的是两次提到，各归各。
            let calendar_date = |atom: &Atom| matches!(atom, Atom::Date(DateSpec::Absolute { .. } | DateSpec::MonthDay { .. }));
            let punct_gap = |a: usize, b: usize| {
                a <= b
                    && self.units[a..b].len() <= 2
                    && self.units[a..b]
                        .iter()
                        .all(|t| t.kind == UKind::Punct && !matches!(t.text.as_str(), "." | "!" | "?" | ";" | "|" | "/" | "。" | "；" | "\n" | "\n\n"))
            };
            let mut k = 0;
            while k + 4 < seg.len() {
                if calendar_date(&seg[k].atom)
                    && matches!(seg[k + 1].atom, Atom::Clock { .. })
                    && matches!(seg[k + 2].atom, Atom::RangeSep)
                    && calendar_date(&seg[k + 3].atom)
                    && matches!(seg[k + 4].atom, Atom::Clock { .. })
                    && punct_gap(seg[k].to, seg[k + 1].from)
                    && self.adjacent(seg[k + 1].to, seg[k + 2].from)
                    && punct_gap(seg[k + 2].to, seg[k + 3].from)
                    && punct_gap(seg[k + 3].to, seg[k + 4].from)
                {
                    let next_day = match (&seg[k].atom, &seg[k + 3].atom) {
                        (Atom::Date(a), Atom::Date(b)) => match Self::day_gap(a, b) {
                            Some(1) => Some(true),
                            Some(0) => Some(false),
                            _ => None,
                        },
                        _ => None,
                    };
                    if let Some(next_day) = next_day {
                        // 第二头的日期折进区间符号的范围，终点换成带上日偏移的钟点；下面的锚按「钟点、区间符号、钟点」照旧认。
                        let mut sep = seg[k + 2].clone();
                        sep.to = seg[k + 4].from;
                        let mut end_loc = seg[k + 4].clone();
                        if let Atom::Clock { clock, .. } = &mut end_loc.atom {
                            clock.day_offset += i8::from(next_day);
                        }
                        let (end_alt, end_pair) = (alts[k + 4].clone(), from_pair[k + 4]);
                        seg.splice(k + 2..k + 5, [sep, end_loc]);
                        alts.splice(k + 2..k + 5, [None, end_alt]);
                        from_pair.splice(k + 2..k + 5, [false, end_pair]);
                        continue;
                    }
                }
                k += 1;
            }
            let mut series = super::series::plans(self.units, &seg);
            // 已由共享钟点认出的日期串不再另起无钟点的系列。
            let date_series: Vec<_> = super::series::date_plans(self.units, &seg, seg_unit_end)
                .into_iter().filter(|candidate| !series.iter().any(|plan| plan.dates.iter().any(|date| candidate.dates.contains(date)))).collect();
            series.extend(date_series);
            let headings: Vec<_> = super::series::heading_date_plans(self.units, &seg, seg_unit_start, seg_unit_end)
                .into_iter().filter(|heading| !series.iter().any(|plan| plan.dates.iter().any(|date| heading.dates.contains(date)))).collect();
            series.extend(headings);
            for plan in &mut series {
                if plan.has_range && plan.dates.iter().any(|&k| matches!(alts[k], Some(Alternative::DateOrder { .. } | Alternative::DotDate { .. } | Alternative::DotClock { .. }))) {
                    plan.days = plan.dates.iter().filter_map(|&k| match &seg[k].atom {
                        Atom::Date(date) => Some(super::series::Day { date: date.clone(), from: seg[k].from, to: seg[k].to }),
                        _ => None,
                    }).collect();
                    plan.calendar_range = false;
                }
            }
            for plan in &series { taken[plan.context_from..plan.context_to].fill(true); }
            // 时间段：钟点、区间符号、钟点，两两紧挨；「and / und / et」只在「between 9 and 5」里连成一段（「9am and 5pm」、
            // 「9am and then we leave at 5pm」是两处；此前只看区间符号前面一边会误并）。
            let is_range = |k: usize| -> bool {
                matches!(seg[k].atom, Atom::Clock { .. })
                    && k + 2 < seg.len()
                    && matches!(seg[k + 2].atom, Atom::Clock { .. } | Atom::Invalid("invalidTime"))
                    && self.adjacent(seg[k].to, seg[k + 1].from)
                    && self.adjacent(seg[k + 1].to, seg[k + 2].from)
                    && match seg[k + 1].atom {
                        Atom::RangeSep => true,
                        Atom::And => k > 0 && matches!(seg[k - 1].atom, Atom::Between) && self.adjacent(seg[k - 1].to, seg[k].from),
                        _ => false,
                    }
            };
            // 锚：钟点（不是时间段终点）、相对时间、精确时刻、写得不成立的钟点；截止习语不紧挨钟点时另成一处；
            // 都没有时用日期（只有日期的一处）。
            let mut anchors: Vec<usize> = Vec::new();
            let mut k = 0;
            while k < seg.len() {
                if matches!(seg[k].atom, Atom::Clock { .. } | Atom::Relative(_) | Atom::Instant(_) | Atom::Invalid("invalidTime")) {
                    anchors.push(k);
                    if is_range(k) {
                        k += 3;
                        continue;
                    }
                }
                k += 1;
            }
            // 截止习语另成一处（「Call at 9 and submit by EOD」两处），紧挨着某个钟点时不另起（「by EOD, 5pm」）。
            let clock_anchors = anchors.clone();
            for (k, a) in seg.iter().enumerate() {
                if matches!(a.atom, Atom::Idiom(..))
                    && !clock_anchors.iter().any(|&c| self.adjacent(seg[c].to, a.from) || self.adjacent(a.to, seg[c].from))
                {
                    anchors.push(k);
                }
            }
            if !anchors.is_empty() {
                // 同段的完整日期串标题先独立成系列，后面的自有日期不会被吞进标题。
                anchors.extend(series.iter().filter(|plan| matches!(seg[plan.clock].atom, Atom::Date(_))).map(|plan| plan.clock));
            }
            anchors.sort_unstable();
            anchors.dedup();
            // 公历日期可单独成事；次日标题须有后续钟点。
            // 两数日期与普通相对日子不单独成事。
            let mut date_only = false;
            if anchors.is_empty() {
                anchors = seg
                    .iter()
                    .enumerate()
                    .filter(|(k, a)| {
                        series.iter().any(|plan| plan.clock == *k)
                            || !series.iter().any(|plan| plan.dates.contains(k))
                                && (!from_pair[*k] || all_atoms.iter().any(|original| original.from == a.from && original.to == a.to && matches!(original.atom, Atom::SlashPair { .. })))
                                && (matches!(a.atom, Atom::Date(DateSpec::Absolute { .. } | DateSpec::MonthDay { .. }) | Atom::Invalid("invalidDate"))
                                    || next_day_heading(a))
                    })
                    .map(|(k, _)| k)
                    .collect();
                date_only = !anchors.is_empty();
            }
            if anchors.is_empty() {
                for a in &seg {
                    if let Atom::Target { text, bare } = &a.atom {
                        if self.place_candidate_fits(text, a.from, bare.as_deref(), a.lang) {
                            pending_targets.push((seg_index, paragraph, text.clone(), bare.clone(), a.from, a.to));
                        }
                    }
                }
                continue;
            }
            // 每个锚的范围末尾（时间段带终点）。
            let anchor_end = |k: usize| -> usize { if !date_only && is_range(k) { seg[k + 2].to } else { seg[k].to } };
            // 每个非锚原子挂到哪个锚。
            let owner_of = |start: usize| -> usize {
                let mut prev: Option<usize> = None;
                let mut next: Option<usize> = None;
                for (slot, &a) in anchors.iter().enumerate() {
                    if anchor_end(a) <= start {
                        prev = Some(slot);
                    } else if seg[a].from >= start && next.is_none() {
                        next = Some(slot);
                    }
                }
                match (prev, next) {
                    (Some(p), Some(n)) => if self.attaches_to_previous(anchor_end(anchors[p]), start) { p } else { n },
                    (Some(p), None) => p,
                    (None, Some(n)) => n,
                    (None, None) => 0,
                }
            };
            let mut owned: Vec<Vec<usize>> = vec![Vec::new(); anchors.len()];
            for (k, a) in seg.iter().enumerate() {
                if anchors.contains(&k) {
                    continue;
                }
                // 时间段的终点归它的起点。
                if matches!(a.atom, Atom::RangeSep | Atom::And) || anchors.iter().any(|&x| x + 2 == k && anchor_end(x) == a.to) {
                    continue;
                }
                let mut assigned_slot = owner_of(a.from);
                // 日期挨着下一处钟点时归下一处，避免两个星期都挂到前一处。
                if matches!(a.atom, Atom::Date(_) | Atom::DatePeriod(..)) {
                    let next = anchors.iter().enumerate().find(|(_, anchor)| seg[**anchor].from >= a.to);
                    if let Some((slot, &anchor)) = next {
                        let next_gap = seg[anchor].from - a.to;
                        let previous_gap = anchors.iter().copied().filter(|&anchor| anchor_end(anchor) <= a.from)
                            .map(|anchor| a.from - anchor_end(anchor)).min();
                        // 前一处是共享日子时，后面自己带钟点的公历日期归它自己的钟点。
                        let own_next = matches!(a.atom, Atom::Date(DateSpec::Absolute { .. } | DateSpec::MonthDay { .. }))
                            && matches!(seg[anchor].atom, Atom::Clock { .. } | Atom::Idiom(..))
                            && super::series::clock_gap(self.units, &seg, a.to, seg[anchor].from)
                            && anchors[..slot].iter().rev().find(|&&previous| anchor_end(previous) <= a.from)
                                .is_some_and(|&previous| series.iter().any(|plan| plan.clock == previous));
                        if own_next || previous_gap.is_none_or(|gap| next_gap < gap) {
                            assigned_slot = slot;
                        }
                    }
                }
                owned[assigned_slot].push(k);
            }
            // 共享钟点的日期由整串展开，不让普通的就近归属丢掉其中一天。
            for plan in &series {
                for owned in &mut owned {
                    owned.retain(|&k| !plan.dates.contains(&k) && !(plan.context_from <= seg[k].from && seg[k].to <= plan.context_to && !matches!(seg[k].atom, Atom::Zone(_) | Atom::Period(_))));
                }
            }
            // 一个锚只取离它最近的日期；别的写明的公历日期各成「只有日期」的一处（「Oct 3 is the deadline, and the call is
            // Oct 4 at 9am」：截止与通话各归各；此前取第一个日期会把通话归到截止日）。
            let mut extra_dates: Vec<usize> = Vec::new();
            // 一个钟点挨着两个不同的相对日子（`9am today tomorrow`、`2024-01-01 9am tomorrow`）：矛盾，说出来。
            let mut conflicting_dates: Vec<(usize, usize)> = Vec::new();
            if !date_only {
                for (slot, &anchor) in anchors.iter().enumerate() {
                    // 同一表达式按封闭日期连接语法判断；其它无分句标点的旧距离规则保持不变。
                    // 整个缝是同一日期表达式时不受三个单元限制，紧邻的星期说明照旧保留。
                    let end = anchor_end(anchor);
                    let far: Vec<usize> = owned[slot]
                        .iter()
                        .copied()
                        .filter(|&k| {
                            (!from_pair[k] || matches!(seg[k].atom, Atom::Date(DateSpec::Absolute { .. })))
                                && matches!(seg[k].atom, Atom::Date(DateSpec::Absolute { .. } | DateSpec::MonthDay { .. }))
                                && seg[k].from >= end
                                && {
                                    let to = seg[k].from;
                                    let boundary = self.units[end..to].iter().any(|u| u.kind == UKind::Punct
                                        && matches!(u.text.as_str(), "," | ";" | "；" | "-"));
                                    let weekday_note = owned[slot].iter().any(|&w| {
                                        matches!(seg[w].atom, Atom::Date(DateSpec::Weekday { .. })) && seg[w].to <= to && to - seg[w].to <= 2
                                            && (!boundary || seg[w].from >= end
                                                && self.following_date_gap(&seg, &owned[slot], seg[anchor].from, end, seg[w].from))
                                    });
                                    !weekday_note && (boundary || to - end > 3)
                                        && !self.following_date_gap(&seg, &owned[slot], seg[anchor].from, end, to)
                                }
                        })
                        .collect();
                    for k in far {
                        owned[slot].retain(|&x| x != k);
                        extra_dates.push(k);
                    }
                    // 同一处挨着的几个日子先互相对一对（通知写法）：
                    //  · 星期与写明的公历日期：对得上（或没写年、这里核不了）就只留公历日期（`Dienstag, 15.07.2025`、`02/07/2025 (quarta-feira)`
                    //    `Thứ 5 ngày 04/09/2025`）；写了年而星期对不上才算矛盾。
                    //  · 相对的日子与写明的公历日期：留写明的（「tomorrow (3/24)」是作者把明天写明了）。
                    //  · 只有几个星期、没有别的日子：「周一至周五」这种作息，不是某一天，星期都不要（「SENIN S.D. JUMAT PUKUL 08.10 - 14.00」）。
                    {
                        let is = |k: usize, f: &dyn Fn(&DateSpec) -> bool| matches!(&seg[k].atom, Atom::Date(d) if f(d));
                        let dates: Vec<usize> = owned[slot].iter().copied().filter(|&k| matches!(seg[k].atom, Atom::Date(_))).collect();
                        let calendar: Vec<usize> = dates.iter().copied().filter(|&k| is(k, &|d| matches!(d, DateSpec::Absolute { .. } | DateSpec::MonthDay { .. }))).collect();
                        let weekdays: Vec<usize> = dates.iter().copied().filter(|&k| is(k, &|d| matches!(d, DateSpec::Weekday { .. }))).collect();
                        let relative: Vec<usize> = dates.iter().copied().filter(|&k| is(k, &|d| matches!(d, DateSpec::Offset { .. }))).collect();
                        if !calendar.is_empty() {
                            for &w in &weekdays {
                                let consistent = calendar.iter().all(|&c| match (&seg[c].atom, &seg[w].atom) {
                                    (Atom::Date(DateSpec::Absolute { year, month, day }), Atom::Date(DateSpec::Weekday { weekday, .. })) => {
                                        (days_from_civil(*year, *month, *day) + 3).rem_euclid(7) + 1 == i64::from(*weekday)
                                    }
                                    _ => true,
                                });
                                if consistent {
                                    owned[slot].retain(|&x| x != w);
                                }
                            }
                            // 只在紧挨着时（中间最多一个括号或逗号）才是说明：「tomorrow (3/24)」「tomorrow, Oct 5」；
                            // 「2024-01-01 9am tomorrow」隔着钟点各说一个日子，仍算矛盾（严格写法的迁移门钉着）。
                            for &r in &relative {
                                let beside = calendar.iter().any(|&c| {
                                    let (a, b) = if seg[c].from >= seg[r].to { (seg[r].to, seg[c].from) } else { (seg[c].to, seg[r].from) };
                                    b >= a && b - a <= 2 && self.units[a..b].iter().all(|t| t.kind == UKind::Punct)
                                });
                                if beside {
                                    owned[slot].retain(|&x| x != r);
                                }
                            }
                        } else if weekdays.len() >= 2 && relative.is_empty() {
                            for &w in &weekdays {
                                owned[slot].retain(|&x| x != w);
                            }
                        }
                    }
                    let dates: Vec<usize> = owned[slot].iter().copied().filter(|&k| matches!(seg[k].atom, Atom::Date(_) | Atom::DatePeriod(..))).collect();
                    if dates.len() < 2 {
                        continue;
                    }
                    let distance = |k: usize| if seg[k].to <= seg[anchor].from { seg[anchor].from - seg[k].to } else { seg[k].from.saturating_sub(end) };
                    let own_following = |k: usize| matches!(seg[k].atom, Atom::Date(DateSpec::Absolute { .. } | DateSpec::MonthDay { .. }))
                        && end <= seg[k].from && super::series::clock_gap(self.units, &seg, end, seg[k].from);
                    let keep = dates.iter().copied().min_by_key(|&k| (!own_following(k), distance(k))).unwrap_or(dates[0]);
                    for &k in &dates {
                        if k == keep {
                            continue;
                        }
                        owned[slot].retain(|&x| x != k);
                        if (!from_pair[k] || matches!(seg[k].atom, Atom::Date(DateSpec::Absolute { .. })))
                            && matches!(seg[k].atom, Atom::Date(DateSpec::Absolute { .. } | DateSpec::MonthDay { .. }))
                        {
                            extra_dates.push(k);
                        } else if !matches!((&seg[k].atom, &seg[keep].atom), (Atom::Date(x), Atom::Date(y)) if x == y) {
                            conflicting_dates.push((slot, k));
                        }
                    }
                }
            }
            // Keep complete names intact across atom-owned grammatical glue.
            let loose_all = self.loose_words(seg_unit_start, seg_unit_end, &taken);
            let mut loose_owned: Vec<Vec<(String, usize, usize)>> = vec![Vec::new(); anchors.len()];
            for w in loose_all {
                loose_owned[owner_of(w.1)].push(w);
            }
            for (slot, &anchor) in anchors.iter().enumerate() {
                let mut mention = self.mention(&seg, &alts, anchor, anchor_end(anchor), &owned[slot], &loose_owned[slot], seg_lang, date_only);
                for &(_, k) in conflicting_dates.iter().filter(|(s, _)| *s == slot) {
                    mention.0.issues.push(self.issue("conflictingDate", seg[k].from, seg[k].to));
                }
                if let Some(plan) = series.iter().find(|plan| plan.clock == anchor) {
                    let nightly = matches!((mention.0.time, mention.0.end), (Some(start), Some(end)) if (end.hour, end.minute, end.second) < (start.hour, start.minute, start.second));
                    for (index, day) in plan.days.iter().enumerate() {
                        if nightly && plan.calendar_range && index + 1 == plan.days.len() { continue; }
                        let mut item = mention.0.clone();
                        // 日期锚的备选只属于它自己，各日下面分别取回。
                        if matches!(seg[anchor].atom, Atom::Date(_)) { item.alternatives.clear(); }
                        item.date = Some(day.date.clone());
                        item.date_inherited = false;
                        item.date_from = None;
                        item.series = Some(plan.from);
                        item.span = self.span_of(plan.from, plan.to);
                        item.parts.retain(|part| part.kind != "date");
                        item.parts.push(Part { kind: "date", span: self.span_of(day.from, day.to) });
                        item.parts.sort_by_key(|part| part.span[0]);
                        if let Some(alt) = plan.dates.iter().find(|&&k| seg[k].from == day.from && seg[k].to == day.to).and_then(|&k| alts[k].clone()) {
                            item.alternatives.push(alt);
                        }
                        if nightly { if let Some(end) = &mut item.end { end.day_offset = 1; } }
                        built.push(Built { mention: item, unit_from: plan.from, unit_to: mention.1.1.max(plan.to), series_span: Some(self.span_of(plan.from, plan.to)), paragraph, segment: seg_index, day_after_previous: false, bare_hour: false });
                    }
                } else {
                    let (unit_from, unit_to) = mention.1;
                    let day_after_previous = day_after_previous(&mention.0);
                    built.push(Built { mention: mention.0, unit_from, unit_to, series_span: None, paragraph, segment: seg_index, day_after_previous, bare_hour: mention.2 });
                }
            }
            for &k in &extra_dates {
                let mention = self.mention(&seg, &alts, k, seg[k].to, &[], &[], seg_lang, true);
                let (unit_from, unit_to) = mention.1;
                let day_after_previous = day_after_previous(&mention.0);
                built.push(Built { mention: mention.0, unit_from, unit_to, series_span: None, paragraph, segment: seg_index, day_after_previous, bare_hour: mention.2 });
            }
        }
        // 只问目标的一句接回前一句：前一句（同一段落）恰好一处、还没有目标时才接；几处时不猜。
        for (seg_index, paragraph, text, bare, from, to) in pending_targets {
            let previous: Vec<usize> =
                built.iter().enumerate().filter(|(_, b)| b.paragraph == paragraph && b.segment + 1 == seg_index).map(|(i, _)| i).collect();
            let [only] = previous[..] else { continue };
            let resolved = self.resolved_target(&text, from, to, bare.as_deref(), None);
            let to = resolved.as_ref().map_or(to, |(_, end)| *end);
            let span = self.span_of(from, to);
            let b = &mut built[only];
            if b.mention.target.is_some() {
                continue;
            }
            match resolved {
                Some((zone, _)) => {
                    b.mention.target = Some(zone);
                    b.mention.parts.push(Part { kind: "target", span });
                    b.mention.parts.sort_by_key(|p| p.span[0]);
                }
                None if bare.is_none() => b.mention.unresolved.push(Unresolved { text, span, role: "target" }),
                None => continue,
            }
            b.mention.span = [b.mention.span[0].min(span[0]), b.mention.span[1].max(span[1])];
            b.unit_to = b.unit_to.max(to);
        }
        built.sort_by_key(|b| b.unit_from);
        self.finish(built, languages.into_iter().map(|(l, _)| l).collect(), writer, &written_dates)
    }

    fn assign_destinations(&self, built: &mut Vec<Built>, destinations: &[super::targets::Phrase]) {
        use super::targets::Kind;
        let u = self.units;
        let mut previous_question = 0;
        let mut now_questions: Vec<Built> = Vec::new();
        for p in destinations {
            let paragraph_start = u[..p.from].iter().rposition(|t| t.text == "\n\n").map_or(0, |i| i + 1);
            let sentence_start = self.atoms.iter().filter(|a| a.to <= p.from && matches!(a.atom, Atom::Boundary(_)) && !matches!(u[a.from].text.as_str(), ";" | "|" | "/"))
                .map(|a| a.to).max().unwrap_or(0).max(paragraph_start);
            // Use clock-part positions, not expanded mention spans: adding a
            // previous question to a mention must not move its clock forward.
            let clock_start = |b: &Built| b.mention.parts.iter().filter(|part| part.kind == "time")
                .map(|part| part.span[0]).min();
            let question_start = self.span_of(p.from, p.to)[0];
            let unit_start = |at: usize| u.get(at).map_or(self.folded.span.last().map_or(0, |s| s.1), |t| self.folded.span[t.start].0);
            let window_start = if p.kind == Kind::Question { paragraph_start.max(previous_question) } else { paragraph_start };
            let lower = self.units.get(window_start).map_or(0, |t| self.folded.span[t.start].0);
            let eligible: Vec<usize> = built.iter().enumerate().filter(|(_, b)| b.mention.time.is_some()
                && clock_start(b).is_some_and(|start| lower <= start && start < question_start)).map(|(i, _)| i).collect();
            let own_clock = eligible.iter().copied().rev().find(|&i| clock_start(&built[i]).is_some_and(|start| start >= unit_start(sentence_start)));
            // A question can put the requested city before its own explicit
            // clock ("What time in Tokyo at 15:00 in Paris?"). That clock is
            // inside the question, rather than a later unrelated mention.
            let question_end = self.atoms.iter().filter(|a| a.from >= p.to && matches!(a.atom, Atom::Boundary(_)) && !matches!(u[a.from].text.as_str(), ";" | "|" | "/"))
                .map(|a| a.from).min().unwrap_or(u.len());
            let own_clock = own_clock.or_else(|| (p.kind == Kind::Question).then(|| {
                built.iter().enumerate().find(|(_, b)| b.mention.time.is_some() && clock_start(b).is_some_and(|start| unit_start(p.to) <= start && start < unit_start(question_end))).map(|(i, _)| i)
            }).flatten());
            let mut owners: Vec<usize> = match p.kind {
                Kind::Question if own_clock.is_none() => eligible,
                Kind::Arrow => own_clock.filter(|&i| {
                    let end = built[i].unit_to;
                    self.destination_gap(end, p.from, false)
                }).into_iter().collect(),
                _ => own_clock.or_else(|| eligible.last().copied()).into_iter().collect(),
            };
            if p.kind == Kind::Local {
                // A phrase directly introducing the next clock is its source,
                // including after a comma/semicolon, rather than a conversion
                // of the preceding clock in that sentence.
                let sentence_end = self.atoms.iter().filter(|a| a.from >= p.to && matches!(a.atom, Atom::Boundary(_)))
                    .map(|a| a.from).min().unwrap_or(u.len());
                let clock_gap_start = super::targets::local_clock_start(u, p);
                let following = built.iter().enumerate().find(|(_, b)| b.mention.time.is_some()
                    && clock_start(b).is_some_and(|start| unit_start(p.to) <= start && start < unit_start(sentence_end)
                        && u[clock_gap_start..].iter().take_while(|t| self.folded.span[t.start].0 < start).all(|t|
                            t.kind == UKind::Punct && matches!(t.text.as_str(), "," | ":" | "(" | ")" | "\n")
                            || b.mention.parts.iter().any(|part| matches!(part.kind, "date" | "period")
                                && part.span[0] <= self.folded.span[t.start].0 && self.folded.span[t.end - 1].1 <= part.span[1]))));
                if let Some((i, _)) = following { owners = vec![i]; }
                else {
                    owners = own_clock.filter(|&i| {
                        let end = built[i].unit_to;
                        self.destination_gap(end, p.from, true)
                    }).into_iter().collect();
                }
            }
            // 一个共享钟点问转换地时，整串日子都指向那个地方。
            let series: Vec<_> = owners.iter().filter_map(|&i| built[i].mention.series).collect();
            owners.extend(built.iter().enumerate().filter(|(_, b)| b.mention.series.is_some_and(|id| series.contains(&id))).map(|(i, _)| i));
            owners.sort_unstable();
            owners.dedup();
            // Explicit target grammar is strong evidence even for a place
            // the city index cannot resolve; keep its written name as !X.
            let case_suffix = (p.lang == Some("tr")).then(|| p.text.rsplit_once(['\'', '’'])).flatten()
                .filter(|(_, suffix)| ["da", "de", "ta", "te", "nda", "nde"].contains(&suffix.to_lowercase().as_str()));
            let name = case_suffix.map_or(p.text.as_str(), |(stem, _)| stem);
            let resolved = if p.local { Some((ZoneRef::Local, p.name_to)) }
                else if let Some(zone) = &p.zone { Some((zone.clone(), p.name_to)) }
                else { self.resolved_place(name, true, p.name_from, p.name_to, p.bare.as_deref(), p.lang) };
            let name_to = resolved.as_ref().map_or(p.name_to, |(_, end)| *end);
            let mut span = self.span_of(p.name_from, name_to);
            if let Some((_, suffix)) = case_suffix { span[1] -= 1 + suffix.encode_utf16().count(); }
            // 只问地点、范围里没有可换算的钟点（「What time is it in Tokyo?」「东京现在几点？」）：答的是此刻那里几点。
            if p.asks_now && owners.is_empty() && (resolved.is_some() || p.bare.is_none()) {
                let (unit_from, unit_to) = (p.from.min(p.name_from), p.to.max(name_to));
                let mut mention = Mention::empty(self.span_of(unit_from, unit_to));
                mention.relative_minutes = Some(0);
                let asked = if p.from < p.name_from { Some((p.from, p.name_from)) } else { (name_to < p.to).then_some((name_to, p.to)) };
                if let Some((from, to)) = asked {
                    mention.parts.push(Part { kind: "time", span: self.span_of(from, to) });
                }
                match &resolved {
                    Some((zone, _)) => {
                        mention.target = Some(zone.clone());
                        mention.parts.push(Part { kind: "target", span });
                    }
                    None => mention.unresolved.push(Unresolved { text: name.to_owned(), span, role: "target" }),
                }
                mention.parts.sort_by_key(|part| part.span[0]);
                let paragraph = self.atoms.iter().filter(|a| a.to <= p.from && matches!(a.atom, Atom::Boundary(Break::Paragraph))).count();
                now_questions.push(Built { mention, unit_from, unit_to, series_span: None, paragraph, segment: usize::MAX, day_after_previous: false, bare_hour: false });
                previous_question = p.to;
                continue;
            }
            for i in owners {
                let b = &mut built[i];
                if p.local && (b.mention.source.is_none() || matches!(b.mention.source, Some(ZoneRef::Options { reason: "sentence", .. }))) {
                    b.mention.source = Some(ZoneRef::Local);
                    b.mention.sentence_place_country = None;
                    b.mention.parts.push(Part { kind: "zone", span });
                } else if b.mention.target.is_none() {
                    if let Some((zone, _)) = &resolved {
                        b.mention.target = Some(zone.clone());
                        b.mention.parts.push(Part { kind: "target", span });
                    } else {
                        b.mention.unresolved.push(Unresolved { text: name.to_owned(), span, role: "target" });
                    }
                }
                b.mention.parts.sort_by_key(|part| part.span[0]);
                b.mention.span[0] = b.mention.span[0].min(span[0]);
                b.mention.span[1] = b.mention.span[1].max(span[1]);
                // 紧贴钟点的说法（「我这边」、箭头去处）算这一处的一部分：等价组按单元范围判，
                // 不把它算进来，「3pm my time / 9am New York」会被拆成两组，写信人偏移就推不出来。
                if p.kind != Kind::Question {
                    b.unit_from = b.unit_from.min(p.from);
                    b.unit_to = b.unit_to.max(p.to);
                }
            }
            if p.kind == Kind::Question { previous_question = p.to; }
        }
        for question in now_questions {
            let at = built.partition_point(|b| b.unit_from <= question.unit_from);
            built.insert(at, question);
        }
    }

    fn destination_gap(&self, mut from: usize, to: usize, local: bool) -> bool {
        if from > to { return false; }
        let u = self.units;
        // A written Turkish clock can carry a glued locative suffix:
        // 10:00'da, benim saatimde / 10:00'da → Tokyo.
        if from + 2 <= to && u[from].text == "'" && !u[from].space_before
            && !u[from + 1].space_before && ["da", "de", "ta", "te"].contains(&u[from + 1].text.as_str()) {
            from += 2;
        }
        u[from..to].iter().all(|t| t.kind == UKind::Punct &&
            (matches!(t.text.as_str(), "," | ":" | "(" | ")" | "\n") || local && matches!(t.text.as_str(), ";" | "-")))
    }

    /// 整段的事：AoE 默认 23:59、日期沿用（同一段落里往后）、等价组。
    /// 数字带分钟分隔符的是明确钟点；中午和午夜是有固定含义的词。
    fn bare_hour_atom(&self, a: &Located) -> bool {
        let Atom::Clock { clock, .. } = a.atom else { return false };
        if clock.hour > 12 || clock.day_offset != 0 { return false; }
        let u = &self.units[a.from..a.to];
        if u.iter().any(|x| matches!(x.text.as_str(), ":" | ".")) { return false; }
        if (a.from..a.to).any(|i| find(self.units, i, |s| matches!(s, Sem::Noon | Sem::Midnight)).is_some()) { return false; }
        let digits = u.iter().filter(|x| x.kind == UKind::Number).count();
        let numeric_clock_unit = digits == 1 && (a.from..a.to).any(|i| find(self.units, i, |s| s == Sem::ClockAfter).is_some());
        !numeric_clock_unit && digits <= 1 && (digits == 1 || (a.from..a.to).any(|i| find(self.units, i, |s| matches!(s,
            Sem::Number(_) | Sem::HourOrdinal(_) | Sem::FixedClock(..) | Sem::TrAcc(_) | Sem::TrDat(_))).is_some()))
    }

    fn finish(&self, mut built: Vec<Built>, languages: Vec<&'static str>, writer: Option<Writer>, written_dates: &[(usize, usize)]) -> Output {
        // AoE 截止：日期 + AoE、没有钟点 → 23:59。「End of Day, AoE」也是 AoE 那天的 23:59，不是下班前的 17:00。
        for b in &mut built {
            let m = &mut b.mention;
            if (m.time.is_none() || m.time_implied == Some("eod")) && m.date.is_some() && m.instant.is_none() && m.relative_minutes.is_none() {
                let aoe = matches!(&m.source, Some(ZoneRef::Fixed { region: Some(r), .. }) if r == "Etc/GMT+12")
                    || matches!(&m.source, Some(ZoneRef::Region { iana }) if iana == "Etc/GMT+12");
                if aoe {
                    m.time = Some(Clock::at(23, 59));
                    m.time_implied = Some("aoe");
                }
            }
        }
        self.merge_date_series_headings(&mut built, written_dates);
        self.assign_destinations(&mut built, &self.destinations);
        // 同段日期并入首个钟点；独立日期标题还能跨空行，后来的日期会截断它。
        let mut k = 0;
        while k + 1 < built.len() {
            let Some(next) = (k + 1..built.len()).find(|&j| {
                let m = &built[j].mention;
                m.date.is_some() || m.time.is_some() || m.instant.is_some() || m.issues.iter().any(|i| i.kind == "invalidTime")
            }) else { break };
            let (a, b) = (&built[k].mention, &built[next].mention);
            let date_only = a.date.is_some() && a.time.is_none() && a.instant.is_none() && a.relative_minutes.is_none() && a.issues.is_empty();
            let timed = b.date.is_none() && b.time.is_some() && b.instant.is_none() && b.relative_minutes.is_none();
            let (pa, pb) = (built[k].paragraph, built[next].paragraph);
            let heading_end = date_only.then(|| self.date_heading_end_on_own_line(&built[k])).flatten();
            let another_date = written_dates.iter().any(|&(from, to)| from >= heading_end.unwrap_or(built[k].unit_to) && to <= built[next].unit_from);
            let adjacent_in_paragraph = next == k + 1 && pb == pa;
            if date_only && timed && (adjacent_in_paragraph || (heading_end.is_some() && (pb == pa || !another_date))) {
                let a = built.remove(k);
                let b = &mut built[next - 1];
                let m = &mut b.mention;
                m.date = a.mention.date;
                m.span[0] = a.mention.span[0];
                m.parts.splice(0..0, a.mention.parts);
                m.alternatives.splice(0..0, a.mention.alternatives);
                m.unresolved.splice(0..0, a.mention.unresolved);
                if m.source.is_none() {
                    m.source = a.mention.source;
                }
                b.unit_from = a.unit_from;
                b.day_after_previous |= a.day_after_previous;
                continue;
            }
            k += 1;
        }
        // 星期和相对日子只给钟点定日期；标题先合并，剩下的无钟点提到不输出。
        built.retain(|b| {
            let m = &b.mention;
            !(matches!(m.date, Some(DateSpec::Weekday { .. } | DateSpec::Offset { .. }))
                && m.time.is_none() && m.instant.is_none() && m.relative_minutes.is_none() && m.issues.is_empty())
        });
        built.sort_by_key(|b| b.unit_from);
        // 日期沿用：同一段落里，有钟点却没日期的沿用前面最近一处的日期，并记下来自哪一处。没写年的月日沿用前面写明的年份
        // （「2025년 2월 15일(토) 23:00 ~ 2월 16일(일) 07:00」「2026. 4. 27.(월) 10:00 … 5. 13.(수) 23:59」；此前
        // 按「最近的将来」读成了 2027 年）；年底写到年初的（12 月 30 日 … 1 月 2 日）进一年。
        let mut last_date: Option<(usize, DateSpec, usize, bool)> = None;
        for (index, b) in built.iter_mut().enumerate() {
            let m = &mut b.mention;
            if m.instant.is_some() || m.relative_minutes.is_some() {
                continue;
            }
            // 次日词以同段前一处为基准；缺少基准时才是明天。
            let mut unsupported_next_day = false;
            if b.day_after_previous {
                if let Some((p, previous, _, ambiguous)) = &last_date {
                    if *p == b.paragraph {
                        // 前一处还有别的日期读法时，不选主读法来推次日。
                        if let Some(date) = (!*ambiguous).then(|| Self::next_day(previous)).flatten() {
                            m.date = Some(date);
                        } else {
                            unsupported_next_day = true;
                            if let Some(part) = m.parts.iter().find(|p| p.kind == "date") {
                                let marker = self.atoms.iter().find(|a| matches!(a.atom, Atom::NextDay(_)) && self.span_of(a.from, a.to) == part.span);
                                if let Some(marker) = marker {
                                    m.issues.push(self.issue("unsupportedRelativeDate", marker.from, marker.to));
                                }
                            }
                        }
                    }
                }
            }
            if unsupported_next_day {
                m.date = None;
                last_date = None;
                continue;
            }
            if let (Some(DateSpec::MonthDay { .. }), Some((p, DateSpec::Absolute { year, month, day }, _, _))) = (&m.date, &last_date) {
                if *p == b.paragraph {
                    let (year, after) = (*year, (*month, *day));
                    let dated = |spec: &DateSpec| -> Option<DateSpec> {
                        let DateSpec::MonthDay { month, day } = *spec else { return None };
                        let y = if (month, day) < after && after.0 >= 11 && month <= 2 { year + 1 } else { year };
                        super::dates::valid_date(y, month, day).then_some(DateSpec::Absolute { year: y, month, day })
                    };
                    if let Some(date) = m.date.as_ref().and_then(dated) {
                        m.date = Some(date);
                        for alt in &mut m.alternatives {
                            if let Alternative::DateOrder { date } | Alternative::DotDate { date } = alt {
                                if let Some(with_year) = dated(date) {
                                    *date = with_year;
                                }
                            }
                        }
                    }
                }
            }
            match (&m.date, &last_date) {
                (Some(d), _) => {
                    let ambiguous = m.alternatives.iter().any(|a| matches!(a, Alternative::DateOrder { .. } | Alternative::DotDate { .. }));
                    last_date = Some((b.paragraph, d.clone(), index, ambiguous));
                }
                (None, Some((p, d, from, _))) if *p == b.paragraph && m.time.is_some() => {
                    m.date = Some(d.clone());
                    m.date_inherited = true;
                    m.date_from = Some(*from);
                    if m.alternatives.iter().any(|a| matches!(a, Alternative::DateOrder { .. } | Alternative::DotDate { .. })) {
                        if let Some((_, _, _, ambiguous)) = last_date.as_mut() {
                            *ambiguous = true;
                        }
                    }
                }
                _ => {}
            }
        }
        // 无时段的小时按同段前一处排序，另一半天保留为候选。经过推断的一处不能再给下一处作依据。
        let mut previous_clock: Option<(usize, Clock, Option<DateSpec>)> = None;
        for b in &mut built {
            let m = &mut b.mention;
            let mut inferred = false;
            if b.bare_hour {
                if let (Some(time), Some((paragraph, previous, previous_date))) = (m.time, &previous_clock) {
                    let gap = match (previous_date, &m.date) {
                        (None, None) => Some(0),
                        (Some(DateSpec::Offset { days: a }), Some(DateSpec::Offset { days: b })) => Some(i64::from(*b) - i64::from(*a)),
                        (Some(a), Some(b)) => Self::day_gap(a, b),
                        _ => None,
                    };
                    if *paragraph == b.paragraph && gap.is_some() {
                        let mut other = time;
                        other.hour = (time.hour + 12) % 24;
                        let minute = |c: Clock| i64::from(c.day_offset) * 1440 + i64::from(c.hour) * 60 + i64::from(c.minute);
                        let distance = |c| (minute(c) + gap.unwrap_or(0) * 1440 - minute(*previous)).abs();
                        if distance(other) < distance(time) {
                            m.time = Some(other);
                            other = time;
                        }
                        m.alternatives.push(Alternative::DotClock { time: other });
                        inferred = true;
                    }
                }
            }
            previous_clock = if inferred || !m.issues.is_empty() || m.time_implied.is_some() { None } else { m.time.map(|time| (b.paragraph, time, m.date.clone())) };
        }
        // 等价组：同一行、中间只有分隔符或连接词的几处同一个号。
        let mut group = 0usize;
        for i in 0..built.len() {
            if i > 0 && (built[i].mention.series.is_some() || built[i - 1].mention.series.is_some()
                || !self.only_separators_between(built[i - 1].unit_to, built[i].unit_from)) {
                group += 1;
            }
            built[i].mention.group = group;
        }
        self.suggest_nearby_places(&mut built, writer.as_ref());
        // A writer's stated location is also a sentence location clue. Keep
        // writer metadata, and suggest it only for clocks in that same sentence.
        if let Some(writer) = &writer {
            let same_sentence = |span: [usize; 2]| {
                let (lo, hi) = if writer.span[1] <= span[0] { (writer.span[1], span[0]) } else if span[1] <= writer.span[0] { (span[1], writer.span[0]) } else { return true; };
                !self.units.iter().enumerate().any(|(k, t)| {
                    let pos = self.span_of(k, k + 1)[0];
                    lo <= pos && pos < hi && t.kind == UKind::Punct && matches!(t.text.as_str(), "." | "!" | "?" | "。" | "！" | "？" | "\n" | "\n\n")
                })
            };
            let another_place = self.atoms.iter().any(|atom| {
                let span = self.span_of(atom.from, atom.to);
                if !same_sentence(span) || span[0] < writer.span[1] && writer.span[0] < span[1] { return false; }
                match &atom.atom {
                    Atom::Place { text, strong: true, bare } if !text.is_empty()
                        && self.place_candidate_fits(text, atom.from, bare.as_deref(), atom.lang) => self.resolved_place(text, true, atom.from, atom.to, bare.as_deref(), atom.lang)
                        .is_none_or(|(zone, _)| zone != writer.place),
                    _ => false,
                }
            });
            let another_name = self.loose_words(0, self.units.len(), &vec![false; self.units.len()]).iter().any(|(word, start, end)| {
                let span = self.span_of(*start, *end);
                if !same_sentence(span) || span[0] < writer.span[1] && writer.span[0] < span[1] { return false; }
                if self.units[*start].kind == UKind::Cjk {
                    return self.find_place(word, false, None, None).is_some_and(|zone| matches!(&zone, ZoneRef::City { city_index, .. } if *city_index < 2_000) && zone != writer.place);
                }
                let tokens = self.loose_tokens(*start, *end);
                let mut k = 0;
                while k < tokens.len() {
                    let at = tokens[k].0;
                    if !self.units[at].capital || self.initial[at] { k += 1; continue; }
                    let found = (k + 1..=tokens.len().min(k + 4)).rev().find_map(|to| {
                        let name = tokens[k..to].iter().map(|t| t.2.as_str()).collect::<Vec<_>>().join(" ");
                        self.find_place(&name, false, None, None).map(|zone| (to, zone))
                    });
                    if let Some((to, zone)) = found {
                        if matches!(&zone, ZoneRef::City { city_index, .. } if *city_index < 2_000) && zone != writer.place { return true; }
                        k = to;
                    } else { k += 1; }
                }
                false
            });
            if !another_place && !another_name {
                for b in &mut built {
                    let m = &mut b.mention;
                    if m.time.is_some() && m.source.is_none() && m.unresolved.is_empty() && same_sentence(m.span) {
                        if matches!(&writer.place, ZoneRef::Region { .. } | ZoneRef::Options { reason: "country", .. }) {
                            let units: Vec<_> = self.units.iter().enumerate().filter(|(k, _)| { let span = self.span_of(*k, *k + 1); writer.span[0] <= span[0] && span[1] <= writer.span[1] }).collect();
                            'country: for len in (1..=units.len()).rev() {
                                for start in 0..=units.len() - len {
                                    let query = super::units::original_text(self.folded, units[start].1.start, units[start + len - 1].1.end);
                                    if let Some(code) = super::places::country_code(&query) { m.sentence_place_country = Some(code.to_owned()); break 'country; }
                                }
                            }
                        }
                        m.source = Some(ZoneRef::Options { reason: "sentence", options: vec![writer.place.clone()] });
                        m.parts.push(Part { kind: "place", span: writer.span });
                        m.span = [m.span[0].min(writer.span[0]), m.span[1].max(writer.span[1])];
                    }
                }
            }
        }
        // 标题合并完成后才定输出下标；整串的范围只涵盖日子和共享钟点。
        let mut series_first = std::collections::HashMap::new();
        for (index, b) in built.iter_mut().enumerate() {
            if let Some(id) = b.mention.series {
                b.mention.series = Some(*series_first.entry(id).or_insert(index));
                if let Some(span) = b.series_span { b.mention.span = span; }
            }
        }
        Output { mentions: built.into_iter().map(|b| b.mention).collect(), truncated_at: None, languages, writer }
    }

    /// 像个名字（看地名的最后一个词，前面可能是句首大写的介词「En」「W」）：首字母大写，或整句都是小写（随手打的
    /// `meet in tokyo`），或是中日韩文字。
    fn looks_like_name(&self, s: usize) -> bool {
        let t = &self.units[s];
        t.capital || t.upper || self.lowercase[s] || t.kind != UKind::Word
    }

    /// 零散词查到的城：首字母大写不说明它是专名的地方（句首、全小写的一句、名词都大写的德语），只认人口前 2,000 座大城
    /// （「Ende」是印尼的恩德、「Date」是日本的伊达）。中日韩文字没有大小写，不在此列。
    fn loose_place_fits(&self, zone: &ZoneRef, s: usize, seg_lang: Option<&str>) -> bool {
        let ZoneRef::City { city_index, name, iana, .. } = zone else { return true };
        if *city_index < 2_000 || self.units[s].kind == UKind::Cjk || super::places::names_its_zone(name, iana) {
            return true;
        }
        let german = seg_lang.map_or(self.ui_language.starts_with("de"), |l| l == "de");
        !(self.initial[s] || self.lowercase[s] || german)
    }

    /// 仅补原有来源为空的钟点：同分句前置完整地点，间隔至多三个普通词，
    /// 中间没有其它钟点、日期或时区；分句边界沿用后置日期规则。
    /// 地点只认人口前 2,000 座城市或现有国家表；名称只按大小写比主名、英文名或本句语言名。
    /// 不去重音、不认跨语言别名或片段；有大小写的三字母及以下词必须含大写，功能词仍先否决。
    /// 只看扫描器标记的短窗口，复用本次解析的查表缓存；已用地点、相邻和后置读法不变。
    /// 候选顺序为地点在前、本机在后；已有单一来源和已有候选均不重写。
    fn suggest_nearby_places(&self, built: &mut [Built], writer: Option<&Writer>) {
        if !built.iter().any(|b| b.mention.source.is_none() && b.mention.time.is_some()) { return; }
        let u = self.units;
        let mut blocked = vec![false; u.len()];
        for a in &self.atoms {
            if matches!(a.atom, Atom::Clock { .. } | Atom::Idiom(..) | Atom::Date(_)
                | Atom::DatePeriod(..) | Atom::NextDay(_) | Atom::SlashPair { .. }
                | Atom::DotPair { .. } | Atom::Zone(_) | Atom::Instant(_) | Atom::Relative(_)
                | Atom::Invalid(_) | Atom::Boundary(_)) { blocked[a.from..a.to].fill(true); }
        }
        let mut reserved: Vec<_> = built.iter().flat_map(|b| b.mention.parts.iter())
            .filter(|p| matches!(p.kind, "zone" | "target" | "place")).map(|p| p.span)
            .chain(writer.map(|w| w.span)).collect();
        reserved.extend(self.destinations.iter().map(|p| self.span_of(p.from, p.to)));
        for b in built {
            let m = &mut b.mention;
            if m.source.is_some() || m.time.is_none() || !m.unresolved.is_empty() || !m.issues.is_empty() { continue; }
            let Some(part) = m.parts.iter().find(|p| p.kind == "time") else { continue; };
            let Ok(clock) = u.binary_search_by_key(&part.span[0], |t| self.folded.span[t.start].0) else { continue; };
            let mut end = clock;
            let mut nearby = Vec::new();
            let mut words = 0;
            while words <= 3 {
                while end > 0 && u[end - 1].kind == UKind::Punct
                    && matches!(u[end - 1].text.as_str(), "(" | ")" | "\"" | "\n") { end -= 1; }
                if end == 0 || blocked[end - 1] || !matches!(u[end - 1].kind, UKind::Word | UKind::Cjk) { break; }
                let (marked_start, marked_end) = u[end - 1].nearby_candidate();
                let mut start = end - 1;
                if marked_end == end { start = marked_start; }
                else if u[start].kind == UKind::Cjk {
                    while start > 0 && !u[start].space_before && u[start - 1].kind == UKind::Cjk { start -= 1; }
                }
                if blocked[start..end].iter().any(|v| *v) { break; }
                let tokens = if u[start].kind == UKind::Cjk { vec![(start, end, u[start..end].iter().map(|t| t.text.as_str()).collect())] }
                    else { self.loose_tokens(start, end) };
                let count = tokens.len();
                let (head, rest) = city_head_rest(&tokens);
                if marked_end == end {
                    // 完整名字先查，成功后不拆别名；没命中才让开未知的叙述词。
                    'name: for n in (1..=count).rev() {
                        for at in 0..=count - n {
                            if words + count - at - n > 3
                                || head > 0 && (at > 0 && at < head || at == 0 && at + n <= rest)
                                || n == 1 && at > 0 && inner_skip(u, &tokens, at) { continue; }
                            let place_start = tokens[at].0;
                            let place_end = tokens[at + n - 1].1;
                            let span = self.span_of(place_start, place_end);
                            // 连字符可以在完整名字里，缩短名字后却不能跨它借用地点。
                            if (place_end..clock).any(|k| blocked[k] || u[k].kind == UKind::Punct
                                && matches!(u[k].text.as_str(), "," | ";" | "；" | "、" | "-" | ":" | "|" | "/" | "." | "!" | "?" | "。" | "！" | "？" | "\n\n")) { continue; }
                            if self.location_attached(place_start, place_end, clock, clock)
                                || reserved.iter().any(|p| p[0] < span[1] && span[0] < p[1]) { continue; }
                            let language = m.language.unwrap_or(self.ui_language);
                            if super::units::nearby_ordinary(u, place_start, place_end, language) { continue; }
                            // 完整多词名字可带冠词；单独的功能词及小写功能词开头先否决。
                            if (n == 1 || !u[place_start].capital)
                                && super::lexicon::nearby_common_word(&tokens[at].2, language) { continue; }
                            // 与原有零散名字查找使用同一折叠拼写、同一弱强度，复用命中和未命中。
                            let name = tokens[at..at + n].iter().map(|t| t.2.as_str()).collect::<Vec<_>>().join(" ");
                            if CITY_HEADS.contains(&name.as_str()) { continue; }
                            let original = self.folded.nearby_original(u[place_start].start, u[place_end - 1].end);
                            let letters: Vec<_> = original.chars().filter(|c| c.is_alphabetic()).collect();
                            if letters.len() <= 3 && letters.iter().any(|c| c.is_lowercase() || c.is_uppercase())
                                && !letters.iter().any(|c| c.is_uppercase()) { continue; }
                            let written = super::places::nearby_case(original);
                            let exact_language = m.language.unwrap_or("");
                            let country = super::places::nearby_country_lookup(&written, exact_language);
                            let found = if country.is_none() { (self.lookup)(&name, false) } else { None };
                            let known_city = matches!(&found, Some(ZoneRef::City { .. } | ZoneRef::Options { reason: "city", .. }));
                            let zone = country.or_else(|| found.and_then(|zone| nearby_famous_city(zone, &written, exact_language)));
                            if let Some(zone) = zone {
                                nearby.push((zone, span));
                                m.parts.push(Part { kind: "place", span });
                                m.span[0] = m.span[0].min(span[0]);
                                reserved.push(span);
                                if at == 0 && n == count { break 'name; }
                            }
                            // 整体确实是小城时不拆出内部的大城别名。
                            if at == 0 && n == count && known_city { break 'name; }
                        }
                    }
                }
                words += count;
                end = start;
            }
            if !nearby.is_empty() {
                nearby.sort_by_key(|(_, span)| std::cmp::Reverse(span[1]));
                let mut options = Vec::new();
                for (zone, _) in nearby { if !options.contains(&zone) { options.push(zone); } }
                options.push(ZoneRef::Local);
                m.source = Some(ZoneRef::Options { reason: "nearby", options });
                m.parts.sort_by_key(|p| p.span[0]);
            }
        }
    }

    /// 日期串作标题时，后面的一个钟点属于整串，不能只带走最后一天。
    fn merge_date_series_headings(&self, built: &mut Vec<Built>, written_dates: &[(usize, usize)]) {
        let date_only = |b: &Built| b.mention.date.is_some() && b.mention.time.is_none()
            && b.mention.instant.is_none() && b.mention.relative_minutes.is_none() && b.mention.issues.is_empty();
        let mut k = 0;
        while k < built.len() {
            let Some(series) = built[k].mention.series.filter(|_| date_only(&built[k])) else { k += 1; continue; };
            let end = (k + 1..built.len()).find(|&j| built[j].mention.series != Some(series)).unwrap_or(built.len());
            if end - k < 2 || !built[k..end].iter().all(date_only) { k = end; continue; }
            let Some(next) = (end..built.len()).find(|&j| {
                let m = &built[j].mention;
                m.date.is_some() || m.time.is_some() || m.instant.is_some() || m.issues.iter().any(|i| i.kind == "invalidTime")
            }) else { break; };
            let clock = &built[next];
            // 后一处自己写了日期时，由它自己的日期作主。
            let timed = clock.mention.date.is_none() && clock.mention.time.is_some()
                && clock.mention.instant.is_none() && clock.mention.relative_minutes.is_none();
            let heading_end = self.date_heading_end_on_own_line(&built[k]);
            let another_date = written_dates.iter().any(|&(from, to)|
                from >= heading_end.unwrap_or(built[end - 1].unit_to) && to <= clock.unit_from);
            let same_paragraph = built[k].paragraph == clock.paragraph;
            let eligible = next == end && same_paragraph
                || heading_end.is_some() && (same_paragraph || !another_date);
            if !timed || !eligible { k = end; continue; }

            // 日历范围跨句接上每日时段时，仍复用同一套范围展开与跨夜规则。
            let mut days: Vec<_> = built[k..end].iter().enumerate().map(|(offset, b)| {
                let part = b.mention.parts.iter().find(|p| p.kind == "date").unwrap().clone();
                (b.mention.date.clone().unwrap(), Some(k + offset), part)
            }).collect();
            if end == k + 2 && clock.mention.end.is_some()
                && built[k..end].iter().all(|b| b.mention.alternatives.is_empty()) {
                let endpoint = |b: &Built| {
                    let part = b.mention.parts.iter().find(|p| p.kind == "date")?;
                    let atom = self.atoms.iter().find(|a| self.span_of(a.from, a.to) == part.span
                        && matches!(a.atom, Atom::Date(_) | Atom::SlashPair { .. } | Atom::DotPair { .. }))?;
                    Some(super::series::Day { date: b.mention.date.clone()?, from: atom.from, to: atom.to })
                };
                if let (Some(first), Some(last)) = (endpoint(&built[k]), endpoint(&built[k + 1])) {
                    let nightly = matches!((clock.mention.time, clock.mention.end), (Some(start), Some(end))
                        if (end.hour, end.minute, end.second) < (start.hour, start.minute, start.second));
                    if let Some(expanded) = super::series::heading_calendar_days(self.units, &first, &last, nightly) {
                        days = expanded.into_iter().map(|day| {
                            let span = self.span_of(day.from, day.to);
                            let date_index = (k..end).find(|&i| built[i].mention.parts.iter().any(|p| p.kind == "date" && p.span == span));
                            (day.date, date_index, Part { kind: "date", span })
                        }).collect();
                    }
                }
            }
            // 整串选中日期与共享时段；地点和目标仍由各自的部分标记。
            let clock_parts: Vec<_> = clock.mention.parts.iter().filter(|p| matches!(p.kind, "time" | "end")).collect();
            let clock_from = clock_parts.iter().map(|p| p.span[0]).min().unwrap_or(clock.mention.span[0]);
            let clock_to = clock_parts.iter().map(|p| p.span[1]).max().unwrap_or(clock.mention.span[1]);
            let span = [built[k].mention.span[0].min(clock_from),
                built[end - 1].mention.span[1].max(clock_to)];
            let replacements: Vec<_> = days.into_iter().map(|(date, date_index, date_part)| {
                let heading = &built[date_index.unwrap_or(k)];
                let mut mention = clock.mention.clone();
                // 日期标题接上的跨午夜时段，结束钟点属于次日。
                if let (Some(start), Some(end)) = (mention.time, mention.end.as_mut()) {
                    if (end.hour, end.minute, end.second) < (start.hour, start.minute, start.second) && end.day_offset == 0 {
                        end.day_offset = 1;
                    }
                }
                mention.date = Some(date);
                mention.date_inherited = false;
                mention.date_from = None;
                mention.series = Some(series);
                mention.span = span;
                // 钟点的备选读法由整串共享；每一天只带自己的日期备选。
                if date_index.is_some() { mention.alternatives.extend(heading.mention.alternatives.clone()); }
                mention.parts.extend(heading.mention.parts.iter().filter(|p| p.kind != "date").cloned());
                mention.parts.push(date_part);
                mention.parts.sort_by_key(|p| p.span[0]);
                mention.unresolved.extend(heading.mention.unresolved.clone());
                if mention.source.is_none() {
                    mention.source = heading.mention.source.clone();
                    mention.sentence_place_country = heading.mention.sentence_place_country.clone();
                }
                if mention.target.is_none() { mention.target = heading.mention.target.clone(); }
                Built {
                    mention, unit_from: built[k].unit_from.min(clock.unit_from),
                    unit_to: built[end - 1].unit_to.max(clock.unit_to), series_span: Some(span),
                    paragraph: clock.paragraph, segment: clock.segment,
                    day_after_previous: heading.day_after_previous || clock.day_after_previous, bare_hour: false,
                }
            }).collect();
            let count = replacements.len();
            built.remove(next);
            built.splice(k..end, replacements);
            k += count;
        }
    }

    /// 日期所在行只含日期、标点和短标题，不能把一句正文当成跨段标题。
    fn date_heading_end_on_own_line(&self, b: &Built) -> Option<usize> {
        // 已验证为日期串的整段都属于标题；单日继续要求对应原始日期原子。
        let (date_from, mut date_to) = if b.mention.series.is_some() && b.mention.time.is_none() {
            (b.unit_from, b.unit_to)
        } else {
            let part = b.mention.parts.iter().find(|p| p.kind == "date")?;
            let date = self.atoms.iter().find(|a| {
                matches!(a.atom, Atom::Date(_) | Atom::DatePeriod(..) | Atom::NextDay(_) | Atom::SlashPair { .. }) && self.span_of(a.from, a.to) == part.span
            })?;
            (date.from, date.to)
        };
        let newline = |u: &Unit| u.kind == UKind::Punct && matches!(u.text.as_str(), "\n" | "\n\n");
        let from = self.units[..date_from].iter().rposition(newline).map_or(0, |k| k + 1);
        let to = self.units[date_to..].iter().position(newline).map_or(self.units.len(), |k| date_to + k);
        // 紧接在日期后、仍在同一行的星期只是标题注记，不截断标题。
        for a in &self.atoms {
            if a.from >= date_to && a.to <= to && matches!(a.atom, Atom::Date(DateSpec::Weekday { .. }))
                && self.units[date_to..a.from].iter().all(|u| u.kind == UKind::Punct)
            {
                date_to = a.to;
            }
        }
        let label = |units: &[Unit]| {
            let text: String = units.iter().filter(|u| u.kind != UKind::Punct).map(|u| u.text.as_str()).collect();
            // 无冒号的标题词只认封闭表，汉字与谚文按完整词比较。
            if matches!(text.as_str(), "" | "date" | "schedule" | "termin" | "datum" | "日期" | "日程" | "날짜" | "일정") {
                return true;
            }
            if !units.last().is_some_and(|u| u.text == ":") || units.iter().any(|u| u.kind == UKind::Number) {
                return false;
            }
            let (mut words, mut cjk) = (0, false);
            for u in units {
                match u.kind {
                    UKind::Cjk => {
                        if !cjk || u.space_before { words += 1; }
                        cjk = true;
                    }
                    UKind::Word => { words += 1; cjk = false; }
                    _ => { cjk = false; }
                }
            }
            words <= 2
        };
        (label(&self.units[from..date_from]) && label(&self.units[date_to..to])).then_some(to)
    }

    /// 两处之间只有空白、分隔符与连接词，且没有换行。
    fn only_separators_between(&self, from: usize, to: usize) -> bool {
        if from > to {
            return false;
        }
        let u = self.units;
        let mut k = from;
        while k < to {
            let t = &u[k];
            if t.kind == UKind::Punct {
                if t.text == "\n" || t.text == "\n\n" || !GROUP_PUNCT.contains(&t.text.as_str()) || t.text == "\n" {
                    return false;
                }
                k += 1;
                continue;
            }
            if let Some((n, _, _)) = find(u, k, |s| s == Sem::Connector) {
                k += n;
                continue;
            }
            return false;
        }
        true
    }

    #[allow(clippy::too_many_arguments)]
    fn mention(
        &self,
        seg: &[Located],
        alts: &[Option<Alternative>],
        anchor: usize,
        anchor_end: usize,
        owned: &[usize],
        loose: &[(String, usize, usize)],
        seg_lang: Option<&'static str>,
        date_only: bool,
    ) -> (Mention, (usize, usize), bool) {
        let u = self.units;
        let a = &seg[anchor];
        let mut parts = vec![];
        let mut m = Mention::empty(self.span_of(a.from, a.to));
        m.language = a.lang.or(seg_lang);
        if let Some(alt) = &alts[anchor] {
            m.alternatives.push(alt.clone());
        }
        let mut from = a.from;
        let mut to = a.to;
        let mut period_applied = false;
        let mut clock_period = None;
        let mut explicit24 = false;
        match &a.atom {
            Atom::Clock { clock, period, explicit } => {
                m.time = Some(*clock);
                clock_period = *period;
                explicit24 = *explicit && clock.hour > 12;
                parts.push(Part { kind: "time", span: self.span_of(a.from, a.to) });
            }
            Atom::Relative(minutes) => {
                m.relative_minutes = Some(*minutes);
                parts.push(Part { kind: "time", span: self.span_of(a.from, a.to) });
            }
            Atom::Instant(seconds) => {
                m.instant = Some(*seconds);
                parts.push(Part { kind: "instant", span: self.span_of(a.from, a.to) });
            }
            Atom::Idiom(key, clock) => {
                m.time = Some(*clock);
                // 单独的中午是确切钟点；中文中午前、下班前和日末给出的截止时刻标为补足。
                m.time_implied = (*key != "noon").then_some(*key);
                // 习语给的钟点（17:00、23:59）当写明的看：再配上「上午」就是矛盾（「上午下班前」）。
                explicit24 = clock.hour > 12;
                parts.push(Part { kind: "time", span: self.span_of(a.from, a.to) });
            }
            Atom::Date(spec) => {
                m.date = Some(spec.clone());
                parts.push(Part { kind: "date", span: self.span_of(a.from, a.to) });
            }
            Atom::DatePeriod(spec, _) => {
                m.date = Some(spec.clone());
                parts.push(Part { kind: "date", span: self.span_of(a.from, a.to) });
            }
            Atom::Invalid(kind) => {
                m.issues.push(self.issue(kind, a.from, a.to));
            }
            _ => {}
        }
        // 时间段终点。
        let mut end_index = anchor;
        // 时间段的终点写得不成立（「13:00 to 25:00」）：整段这一处不算读成。
        if !date_only && anchor_end > a.to {
            if let Atom::Invalid(kind) = &seg[anchor + 2].atom {
                m.issues.push(self.issue(kind, seg[anchor + 2].from, seg[anchor + 2].to));
                to = seg[anchor + 2].to;
                end_index = anchor + 2;
            }
        }
        if !date_only && anchor_end > a.to {
            if let Atom::Clock { clock, period, .. } = &seg[anchor + 2].atom {
                let mut end_clock = *clock;
                // 「3–4pm」：起点没写时段、终点写了 pm，起点跟着终点（3 ≤ 4 时）。
                if clock_period.is_none() {
                    if let (Some(Period::Pm), Some(start)) = (period, m.time.as_mut()) {
                        if start.hour < 12 && start.hour <= clock.hour.max(1) {
                            start.hour += 12;
                        }
                    }
                }
                if let Some(p) = period {
                    let (h, d) = apply_period(end_clock.hour, *p);
                    end_clock.hour = h;
                    end_clock.day_offset += d;
                } else if end_clock.day_offset == 0 {
                    if let Some(sp) = clock_period.filter(|_| (1..=12).contains(&end_clock.hour)) {
                        // 「1pm–3」「11am–1」「10pm–2」：终点没写上下午、起点写了，终点跟着起点；跟过去不晚于起点时再加 12 小时。
                        // 这里的 `clock` 是终点；起点是锚上还没套上下午的钟点。终点自己带日偏移的（「4時～翌2時」、
                        // 两头都写日期的时间段）不这么推——写明了在哪一天。
                        let start_raw = m.time.map(|t| t.hour).unwrap_or(0);
                        let (start24, start_day) = apply_period(start_raw, sp);
                        let (mut end24, end_day) = apply_period(end_clock.hour, sp);
                        if (end_day, end24) <= (start_day, start24) {
                            end24 += 12;
                            if end24 >= 24 {
                                end24 -= 24;
                            }
                        }
                        end_clock.hour = end24;
                        end_clock.day_offset += end_day;
                    }
                }
                m.end = Some(end_clock);
                parts.push(Part { kind: "end", span: self.span_of(seg[anchor + 2].from, seg[anchor + 2].to) });
                to = seg[anchor + 2].to;
                end_index = anchor + 2;
            }
        }
        // 已经套上的时段属于上半天还是下半天、最后一个时段原子在哪（接连两个时段也要比，「3 de la mañana de la tarde」）。
        let mut applied_half: Option<bool> = None;
        let mut last_period_to: Option<usize> = None;
        if let (Some(p), Some(t)) = (clock_period, m.time.as_mut()) {
            let (h, d) = apply_period(t.hour, p);
            t.hour = h;
            t.day_offset += d;
            period_applied = true;
            applied_half = half_day(p);
        }
        // 紧挨着的截止习语（「by noon at 3pm」「明天中午前 下午3点」）：等时段都套完再比。
        let mut deadlines: Vec<(&'static str, Clock, usize, usize)> = Vec::new();
        // 挂在这个锚上的原子：时段、日期、时区、地点、目标、时长。
        let mut places: Vec<PlaceClue> = Vec::new();
        let mut targets: Vec<(String, usize, usize, Option<String>)> = Vec::new();
        let mut target_marker: Option<usize> = None;
        let mut local_zone: Option<(usize, usize)> = None;
        let mut pending_quantities = Vec::new();
        for &k in owned {
            let n = &seg[k];
            match &n.atom {
                Atom::Period(p) if m.time.is_some() && (period_applied || explicit24) => {
                    // 已经有时段或写明了 24 小时制：再来一个对不上的时段是矛盾，说出来，不悄悄取一个
                    // （「午前15時」「15 Uhr morgens」「今晩午前3時」「3 de la mañana de la tarde」）。
                    let near = self.adjacent(n.to, a.from)
                        || self.adjacent(seg[end_index].to, n.from)
                        || last_period_to.is_some_and(|lp| self.adjacent(lp, n.from));
                    // 只挨着时间段终点的时段词说的是终点（「von 22 Uhr bis 6 Uhr morgens」：早上的是 6 点；此前
                    // 拿起点 22 点去比，报了矛盾）。
                    let at_end = end_index != anchor && self.adjacent(seg[end_index].to, n.from) && !self.adjacent(n.to, a.from);
                    let hour = if at_end { m.end.map(|e| e.hour) } else { m.time.map(|t| t.hour) }.unwrap_or(0);
                    let clash = if at_end || (explicit24 && !period_applied) {
                        half_day(*p) == Some(false) && hour > 12
                    } else {
                        matches!((applied_half, half_day(*p)), (Some(x), Some(y)) if x != y)
                    };
                    if at_end {
                        let end_period = match seg[end_index].atom { Atom::Clock { period, .. } => period, _ => None };
                        let clash = end_period.is_some_and(|old| matches!((half_day(old), half_day(*p)), (Some(x), Some(y)) if x != y))
                            || (end_period.is_none() && hour > 12 && half_day(*p) == Some(false));
                        if clash {
                            m.issues.push(self.issue("conflictingPeriod", n.from, n.to));
                        } else if end_period.is_none() {
                            if let Some(end) = m.end.as_mut() {
                                let (h, d) = apply_period(end.hour, *p);
                                end.hour = h;
                                end.day_offset += d;
                            }
                        }
                        parts.push(Part { kind: "time", span: self.span_of(n.from, n.to) });
                        to = to.max(n.to);
                    } else if near && clash {
                        m.issues.push(self.issue("conflictingPeriod", n.from, n.to));
                        from = from.min(n.from);
                        to = to.max(n.to);
                    }
                }
                Atom::Period(p) if !period_applied && m.time.is_some() => {
                    // 时段挨着钟点（前后都行：「下午3点」「3 de la tarde」「3 in the afternoon」）。
                    let near = self.adjacent(n.to, a.from) || self.adjacent(seg[end_index].to, n.from);
                    if near && !explicit24 {
                        let at_end = end_index != anchor && self.adjacent(seg[end_index].to, n.from) && !self.adjacent(n.to, a.from);
                        if at_end {
                            let end_period = match seg[end_index].atom { Atom::Clock { period, .. } => period, _ => None };
                            let clash = end_period.is_some_and(|old| matches!((half_day(old), half_day(*p)), (Some(x), Some(y)) if x != y))
                                || (end_period.is_none() && m.end.is_some_and(|end| end.hour > 12) && half_day(*p) == Some(false));
                            if clash {
                                m.issues.push(self.issue("conflictingPeriod", n.from, n.to));
                            } else if end_period.is_none() {
                                if let Some(end) = m.end.as_mut() {
                                    let (h, d) = apply_period(end.hour, *p);
                                    end.hour = h;
                                    end.day_offset += d;
                                }
                            }
                            parts.push(Part { kind: "time", span: self.span_of(n.from, n.to) });
                            to = to.max(n.to);
                            continue;
                        }
                        applied_half = half_day(*p);
                        last_period_to = Some(n.to);
                        if let Some(t) = m.time.as_mut() {
                            let (h, d) = apply_period(t.hour, *p);
                            t.hour = h;
                            t.day_offset += d;
                        }
                        if let Some(e) = m.end.as_mut().filter(|_| !matches!(seg[end_index].atom, Atom::Clock { period: Some(_), .. })) {
                            let (h, d) = apply_period(e.hour, *p);
                            e.hour = h;
                            e.day_offset += d;
                            // 终点跟着套上下午后不晚于起点（「上午9:00~12:00」的 12 套上「上午」成了 0 点）：再加 12 小时，
                            // 与「1pm–3」同一条。
                            if let Some(t) = m.time {
                                if (e.day_offset, e.hour, e.minute) <= (t.day_offset, t.hour, t.minute) {
                                    e.hour += 12;
                                    if e.hour >= 24 {
                                        e.hour -= 24;
                                    }
                                }
                            }
                        }
                        period_applied = true;
                        parts.push(Part { kind: "time", span: self.span_of(n.from, n.to) });
                        from = from.min(n.from);
                        to = to.max(n.to);
                    }
                }
                Atom::Date(spec) if m.date.is_none() && m.instant.is_none() => {
                    m.date = Some(spec.clone());
                    if let Some(alt) = &alts[k] {
                        m.alternatives.push(alt.clone());
                    }
                    parts.push(Part { kind: "date", span: self.span_of(n.from, n.to) });
                    from = from.min(n.from);
                    to = to.max(n.to);
                }
                Atom::DatePeriod(spec, p) if m.date.is_none() && m.instant.is_none() => {
                    m.date = Some(spec.clone());
                    let hour = m.time.map(|t| t.hour).unwrap_or(0);
                    if m.time.is_some() && explicit24 && half_day(*p) == Some(false) && hour > 12 {
                        m.issues.push(self.issue("conflictingPeriod", n.from, n.to));
                    } else if !period_applied && !explicit24 {
                        if let Some(t) = m.time.as_mut() {
                            let (h, d) = apply_period(t.hour, *p);
                            t.hour = h;
                            t.day_offset += d;
                            period_applied = true;
                            applied_half = half_day(*p);
                            last_period_to = Some(n.to);
                        }
                    }
                    parts.push(Part { kind: "date", span: self.span_of(n.from, n.to) });
                    from = from.min(n.from);
                    to = to.max(n.to);
                }
                Atom::Zone(ZoneRef::Local) => {
                    // 相对量只说距参考时刻多久，不带本地钟面的时区。
                    if m.relative_minutes.is_none() { local_zone = Some((n.from, n.to)); }
                }
                Atom::Invalid(kind) => {
                    m.issues.push(self.issue(kind, n.from, n.to));
                    from = from.min(n.from);
                    to = to.max(n.to);
                }
                Atom::Idiom(key, deadline) if m.time.is_some() && m.time_implied.is_none() => deadlines.push((key, *deadline, n.from, n.to)),
                Atom::Zone(zone) => {
                    if m.source.is_none() && m.instant.is_none() {
                        m.source = Some(zone.clone());
                        parts.push(Part { kind: "zone", span: self.span_of(n.from, n.to) });
                        from = from.min(n.from);
                        to = to.max(n.to);
                    } else if m.target.is_none() && k > anchor {
                        m.target = Some(zone.clone());
                        parts.push(Part { kind: "target", span: self.span_of(n.from, n.to) });
                        to = to.max(n.to);
                    }
                }
                Atom::Duration(minutes) if m.duration_minutes.is_none() && m.time.is_some() => {
                    m.duration_minutes = Some(*minutes);
                    parts.push(Part { kind: "duration", span: self.span_of(n.from, n.to) });
                    from = from.min(n.from);
                    to = to.max(n.to);
                }
                Atom::Quantity(minutes) if m.duration_minutes.is_none() && m.time.is_some() => {
                    // 光秃秃的量只在紧跟钟点或时间段时算时长（「15:00, 2 hours」「15時から2時間」）。
                    if n.from >= to && self.duration_adjacent(to, n.from) {
                        m.duration_minutes = Some(*minutes);
                        parts.push(Part { kind: "duration", span: self.span_of(n.from, n.to) });
                        to = to.max(n.to);
                    } else if n.from >= to {
                        pending_quantities.push((*minutes, n.from, n.to, to));
                    }
                }
                Atom::Place { text, strong, bare } => {
                    if text.is_empty() {
                        // 「X time」：取紧挨在前面的零散词。
                        // 查不到时当没有线索（`Some("")`）：X 常是普通名词（讲座时间、活动时间、Meeting time）。
                        if let Some((w, s, _)) = loose.iter().rev().find(|(_, _, e)| *e <= n.from && n.from - *e <= 1) {
                            places.push((w.clone(), true, *s, n.to, Some(String::new()), n.lang));
                            let tokens = self.loose_tokens(*s, n.from);
                            for start in 1..tokens.len() {
                                if !u[tokens[start].0].capital && !self.lowercase[tokens[start].0] { continue; }
                                let text = tokens[start..].iter().map(|t| t.2.as_str()).collect::<Vec<_>>().join(" ");
                                places.push((text, true, tokens[start].0, n.to, Some(String::new()), n.lang));
                            }
                        }
                    } else {
                        places.push((text.clone(), *strong, n.from, n.to, bare.clone(), n.lang));
                    }
                }
                Atom::Target { text, bare } if self.place_candidate_fits(text, n.from, bare.as_deref(), n.lang) => {
                    targets.push((text.clone(), n.from, n.to, bare.clone()));
                }
                Atom::TargetMarker => target_marker = Some(n.from),
                _ => {}
            }
        }
        for (key, deadline, s, e) in deadlines {
            let Some(t) = m.time.as_mut() else { break };
            // 「下班前三点」：下班前说的三点是下午（没写上下午的 1–6 点按下午算）。
            if key == "eod" && !period_applied && !explicit24 && (1..=6).contains(&t.hour) {
                t.hour += 12;
            }
            // 钟点比固定的截止还晚（「by noon at 3pm」「明天中午前 下午3点」）：矛盾，说出来；更早的钟点就是具体的截止时刻。
            // 下班前的 17:00 只是默认，写明的钟点直接取代它（「EOD is 6pm here」），不算矛盾。
            if key != "eod" && (t.day_offset, t.hour, t.minute) > (deadline.day_offset, deadline.hour, deadline.minute) {
                m.issues.push(self.issue("conflictingDeadline", s, e));
            }
            parts.push(Part { kind: "time", span: self.span_of(s, e) });
            from = from.min(s);
            to = to.max(e);
        }
        // 零散词：只看紧挨着这次提到的（前后 4 个单元内）。
        for (w, s, e) in loose {
            if m.instant.is_some() || m.time.is_none() && m.date.is_none() && m.relative_minutes.is_none() { continue; }
            // 夹在这一处中间的词也算（「下周二东京下午三点」的东京在日期与钟点之间；此前只看前后）。
            let near = (*s >= from && *e <= to) || (*e <= from && from - *e <= 4) || (*s >= to && *s - to <= 4)
                || self.calendar_date_attached(*s, *e, a.from);
            let already = places.iter().any(|(_, _, ps, pe, _, _)| ps <= s && e <= pe) || targets.iter().any(|(_, ts, te, _)| ts <= s && e <= te);
            if already {
                continue;
            }
            if u[*s].kind == UKind::Cjk {
                if super::language::ordinary_noun(u, *s) { continue; }
                // 那边与全国修饰已知地名，后面的普通叙述不属于名字。
                let modified = ["那边", "那邊", "全国", "全國"].iter().filter_map(|marker| w.find(marker))
                    .filter(|&end| end > 0).find_map(|end| {
                        let name = &w[..end];
                        self.find_place(name, true, None, None).map(|_| (name, *s + name.chars().count()))
                    });
                if let Some((name, name_to)) = modified.filter(|_| near && self.loose_attached(*s, *e, a.from, anchor_end)) {
                    places.push((name.to_owned(), true, *s, name_to, Some(String::new()), Some("zh")));
                    continue;
                }
                let location = ["에서는", "에서", "에는", "에", "의"].iter()
                    .any(|ending| w.ends_with(ending) && w.chars().count() >= ending.chars().count() + 2);
                let japanese_location = u.get(*e).is_some_and(|t| matches!(t.text.as_str(), "で" | "に")) && find(u, *e, |sem| matches!(sem, Sem::Stop)).is_none_or(|(n, _, _)| n == 1)
                    && self.find_place(w, true, None, Some("ja")).is_some();
                let genitive = (super::places::country_lookup(w).is_some() || self.find_place(w, false, None, Some("ja")).is_some_and(|zone| matches!(zone, ZoneRef::City { city_index, .. } if city_index < 2_000))) && u.get(*e).is_some_and(|t| t.text == "の");
                let country_modifier = super::places::country_lookup(w).is_some() && u.get(*e).is_some_and(|t| {
                    let tail: String = u[*e..].iter().take(5).map(|t| t.text.as_str()).collect();
                    t.space_before && ["지사", "공장", "고객센터", "물류팀", "개발팀", "협력사", "지원"].iter().any(|word| tail.starts_with(word))
                });
                let strong = location || japanese_location || genitive || country_modifier;
                if strong || target_marker.is_some_and(|marker| *e <= marker && marker - *e <= 2)
                    || near && (self.loose_attached(*s, *e, a.from, anchor_end) || self.calendar_date_attached(*s, *e, a.from) || *s > anchor_end && *s - anchor_end == 1 && ["standup", "sync", "meeting", "call", "webinar"].contains(&u[anchor_end].text.as_str())) {
                    places.push((w.clone(), strong, *s, *e, None, Some(if w.chars().any(super::text::is_hangul) { "ko" } else { "ja" })));
                }
                continue;
            }
            if !near { continue; }
            // 拉丁 / 西里尔的零散词：整段、再每个更短的连续子段（最长的先、离钟点近的先），一段第一个词的首字母要大写
            // （整段文字都是小写时不要求：`3pm tokyo`；段中间的小写词不断开：Città del Messico、Thành phố México）。
            // 单个词只认一段的第一个词、或「城市」通名后面的专名；段里靠后的单词不去查——「15:00 Ho Chi Xyz Abc」的
            // Chi 不该读成芝加哥。
            let tokens = self.loose_tokens(*s, *e);
            let (head, rest) = city_head_rest(&tokens);
            let mut spans: Vec<(usize, usize)> = Vec::new();
            for len in (1..=tokens.len()).rev() {
                let mut starts: Vec<usize> = (0..=(tokens.len() - len)).collect();
                if *s >= to {
                    starts.sort();
                } else {
                    starts.sort_by(|a, b| b.cmp(a));
                }
                for st in starts {
                    let end = st + len;
                    // 只在一串大写专名中间才不查。
                    if len == 1 && st != 0 && st != rest && inner_skip(u, &tokens, st) {
                        continue;
                    }
                    if head > 0 && (st > 0 && st < head || st == 0 && end <= rest) {
                        continue;
                    }
                    spans.push((st, end));
                }
            }
            for (a, b) in spans {
                let (st, en) = (tokens[a].0, tokens[b - 1].1);
                let place_start = if head > 0 && a == rest { tokens[0].0 } else { st };
                if !(u[st].capital && st >= anchor_end && st - anchor_end <= 4 && !seg_lang.map_or(self.ui_language.starts_with("de"), |lang| lang == "de")) && !self.loose_attached(place_start, en, seg[anchor].from, anchor_end)
                    && !self.calendar_date_attached(place_start, en, seg[anchor].from) { continue; }
                if find(u, st, |s| s == Sem::Stop).is_some() && !(u[st].capital && b > a + 1 && ["los", "las", "la", "le", "el", "il"].contains(&u[st].text.as_str())) || super::language::ordinary_noun(u, st) {
                    continue;
                }
                // 句首的大写不能取消钟点后紧接的小写城市。只放行整句其余字母全小写、句末单词的明确位置。
                let sentence_end = |t: &Unit| t.kind == UKind::Punct && matches!(t.text.as_str(), "." | "!" | "?" | ";" | "。" | "；" | "！" | "？" | "\n" | "\n\n");
                let clause_start = (0..st).rev().find(|&k| sentence_end(&u[k])).map_or(0, |k| k + 1);
                let clause_end = (en..u.len()).find(|&k| sentence_end(&u[k])).unwrap_or(u.len());
                let clock_tail = matches!(seg[anchor].atom, Atom::Clock { .. } | Atom::DotPair { .. }) && st == to && b == a + 1
                    && u.get(en).is_none_or(|t| t.kind == UKind::Punct)
                    && (clause_start..clause_end).all(|k| self.initial[k] || !u[k].raw.chars().any(char::is_uppercase));
                let german = seg_lang.map_or(self.ui_language.starts_with("de"), |l| l == "de");
                // 钟点后紧接的一对括号只包地名时，与直接写地名相同。
                let parenthesized = st == anchor_end + 1 && u[anchor_end].text == "("
                    && u.get(en).is_some_and(|t| t.text == ")");
                if (!german && u[st].capital) || self.lowercase[st] || clock_tail
                    || german && u[st].capital && (st == anchor_end || en == seg[anchor].from || self.calendar_date_attached(place_start, en, seg[anchor].from) || parenthesized || st == anchor_end + 1 && u[anchor_end].text == ",") {
                    let text: Vec<&str> = tokens[a..b].iter().map(|t| t.2.as_str()).collect();
                    if text.len() == 1 && text[0].chars().count() < 2 { continue; }
                    places.push((text.join(" "), false, place_start, en, None, None));
                }
            }
        }
        // 问句在后（X 几点 / X では何時 / 是 X 几点）：它前面最近的地名是目标。
        if let Some(marker) = target_marker {
            if let Some(pos) = places.iter().rposition(|(text, _, s, e, bare, lang)| *e <= marker && marker - *e <= 2
                && self.place_candidate_fits(text, *s, bare.as_deref(), *lang)) {
                let (w, _, s, e, bare, _) = places.remove(pos);
                targets.push((w, s, e, bare));
            }
        }
        // 线索地名前面紧挨着一段零散词时，整段（连线索词一起）也当一个候选、而且先查：意语「Monaco di Baviera」的 di
        // 同时是印尼语的「在」，只查 Baviera 会把慕尼黑读成摩纳哥。
        let mut wholes: Vec<PlaceClue> = Vec::new();
        for (text, strong, s, e, bare, lang) in &places {
            if text.is_empty() || !*strong || bare.is_some() || u[*s].kind == UKind::Cjk {
                continue;
            }
            if let Some((_, ls, _)) = loose.iter().find(|(_, run_start, run_end)| *run_end == *s && u[*run_start].kind == UKind::Word) {
                let tokens = self.loose_tokens(*ls, *e);
                if (2..=5).contains(&tokens.len()) && (self.lowercase[*ls] || u[*ls].capital) {
                    let joined: Vec<&str> = tokens.iter().map(|t| t.2.as_str()).collect();
                    // 整段只是先试一下：查不到当没试过（bare 给空串 = 「查不到当没有线索」，不报「没认出」），
                    // 后面原来那个线索地名照常查（「9:00 sydney in new york」的整段查不到，new york 仍是目标）。
                    wholes.push((joined.join(" "), *strong, *ls, *e, Some(String::new()), *lang));
                }
            }
        }
        places.extend(wholes);
        // 同一个起点时长的在前（整段先于它的前半截）。
        places.sort_by_key(|p| (p.2, std::cmp::Reverse(p.3)));
        let mut resolved: Vec<_> = places.iter().filter_map(|(text, strong, s, e, bare, lang)| {
            self.resolved_place(text, *strong, *s, *e, bare.as_deref(), *lang).map(|(zone, end)| ((*s, end), zone))
        }).collect();
        // Every place in this sentence participates, including a phrase owned by
        // another clock. A shared sentence never chooses between two places.
        resolved.extend(seg.iter().filter_map(|n| match &n.atom {
            Atom::Place { text, strong, bare } if !text.is_empty()
                && !targets.iter().any(|(_, start, end, _)| *start <= n.from && n.to <= *end) => self.resolved_place(text, *strong, n.from, n.to, bare.as_deref(), n.lang)
                .map(|(zone, end)| ((n.from, end), zone)),
            _ => None,
        }));
        let distinct = resolved.iter().filter(|((s, e), _)| !resolved.iter().any(|((ls, le), _)| ls <= s && e <= le && (ls < s || e < le)))
            .map(|(_, zone)| zone).fold(Vec::new(), |mut zones, zone| { if !zones.contains(&zone) { zones.push(zone); } zones });
        let mut unknown_names: std::collections::HashSet<_> = places.iter().filter(|(text, strong, s, e, bare, lang)| *strong && bare.is_none() && self.place_candidate_fits(text, *s, bare.as_deref(), *lang) && self.resolved_place(text, *strong, *s, *e, bare.as_deref(), *lang).is_none() && (text.chars().next().is_some_and(char::is_uppercase) || self.looks_like_name(e.saturating_sub(1))))
            .map(|(text, _, _, _, _, _)| super::text::fold_str(text)).collect();
        unknown_names.extend(seg.iter().filter_map(|n| match &n.atom {
            Atom::Place { text, strong: true, bare: None } if !text.is_empty()
                && !targets.iter().any(|(_, start, end, _)| *start <= n.from && n.to <= *end)
                && self.place_candidate_fits(text, n.from, None, n.lang)
                && self.resolved_place(text, true, n.from, n.to, None, n.lang).is_none()
                && (text.chars().next().is_some_and(char::is_uppercase) || self.looks_like_name(n.to.saturating_sub(1))) => Some(super::text::fold_str(text)),
            _ => None,
        }));
        // 地名：有明确线索的先；零散的要城市索引精确命中且够有名（由 lookup 判）。
        let mut resolved_spans: Vec<(usize, usize)> = Vec::new();
        let mut excluded_spans: Vec<(usize, usize)> = Vec::new();
        for (text, strong, s, e, bare, lang) in &places {
            // 已认出的目的地不能再截短成另一个来源地名。
            if excluded_spans.iter().any(|(start, end)| start <= s && e <= end) { continue; }
            if !self.place_candidate_fits(text, *s, bare.as_deref(), *lang) { continue; }
            let resolved = self.resolved_place(text, *strong, *s, *e, bare.as_deref(), *lang);
            let e = &resolved.as_ref().map_or(*e, |(_, end)| *end);
            if m.instant.is_some() || m.time.is_none() && m.relative_minutes.is_none() && m.date.is_none() { continue; }
            let attached = self.location_attached(*s, *e, a.from, anchor_end) || bare == &Some(String::new())
                || find(u, *s, |sem| sem == Sem::ZoneBefore)
                    .is_some_and(|(n, sem, _)| super::language::fits(u, *s, n, sem, Some((*s + n, *e))));
            if bare != &Some(String::new()) && self.excluded_place_role(*s, *e, a.from, anchor_end, *lang) {
                if resolved.is_some() { excluded_spans.push((*s, *e)); }
                continue;
            }
            let sentence = *strong && !attached && m.time.is_some() && m.source.is_none();
            if sentence && resolved.is_some() && (m.time.is_none() || distinct.len() + unknown_names.len() != 1 || local_zone.is_some()) { continue; }
            if resolved_spans.iter().any(|(rs, re)| s < re && rs < e) {
                continue;
            }
            if m.source.is_some() {
                // 已经有时区：再出现的「in X」是目标（9am PST in London）。
                if *strong && (attached || resolved_spans.iter().any(|(_, end)| end == s) || seg.iter().any(|n| matches!(n.atom, Atom::Zone(_)) && n.to == *s)) && m.target.is_none() && *s > a.to {
                    let target = if self.lowercase_place_needs_big_city(text, *s, bare.as_deref(), *lang) {
                        resolved
                    } else {
                        self.find_place(text, true, bare.as_deref(), *lang).map(|zone| (zone, *e))
                    };
                    match target {
                        Some((zone, _)) => {
                            m.target = Some(zone);
                            parts.push(Part { kind: "target", span: self.span_of(*s, *e) });
                            resolved_spans.push((*s, *e));
                        }
                        None if bare.is_none() => m.unresolved.push(Unresolved { text: text.clone(), span: self.span_of(*s, *e), role: "target" }),
                        None => {}
                    }
                }
                continue;
            }
            match resolved.map(|(zone, _)| zone).filter(|zone| *strong || self.loose_place_fits(zone, *s, seg_lang)) {
                Some(zone) => {
                    if sentence && matches!(&zone, ZoneRef::Region { .. } | ZoneRef::Options { reason: "country", .. }) {
                        let name_start = *s + find(u, *s, |sem| matches!(sem, Sem::PlaceIn | Sem::PlaceInArticle | Sem::ZoneBefore)).map_or(0, |(n, _, _)| n);
                        let trimmed = super::units::original_text(self.folded, u[name_start.min(e.saturating_sub(1))].start, u[e.saturating_sub(1)].end);
                        m.sentence_place_country = super::places::country_code(text).or_else(|| bare.as_deref().and_then(super::places::country_code))
                            .or_else(|| super::places::country_code(&trimmed)).map(str::to_owned);
                    }
                    m.source = Some(if sentence { ZoneRef::Options { reason: "sentence", options: vec![zone] } } else { zone });
                    parts.push(Part { kind: if sentence { "place" } else { "zone" }, span: self.span_of(*s, *e) });
                    resolved_spans.push((*s, *e));
                    from = from.min(*s);
                    to = to.max(*e);
                }
                // 小写的普通词跟在「in / w / en」后面（「W celu udziału」「w webinarium」）不是没认出的地名，不报；全小写的一句照报。
                None if *strong && bare.is_none() && (self.looks_like_name(e.saturating_sub(1)) || text.chars().next().is_some_and(char::is_uppercase)) => {
                    let name_start = *s + find(u, *s, |sem| matches!(sem, Sem::PlaceIn | Sem::PlaceInArticle | Sem::ZoneBefore)).map_or(0, |(n, _, _)| n);
                    let end = if u.get(name_start).is_some_and(|t| t.capital) {
                        (name_start + 1..*e).find(|&k| u[k].kind == UKind::Word && u[k].space_before && !u[k].capital).unwrap_or(*e)
                    } else { *e };
                    let query = if name_start < end { super::units::original_text(self.folded, u[name_start].start, u[end - 1].end) } else { text.clone() };
                    m.unresolved.push(Unresolved { text: query, span: self.span_of(*s, end), role: "place" })
                }
                None => {}
            }
        }
        for (text, s, e, bare) in &targets {
            if m.target.is_some() {
                break;
            }
            match self.resolved_target(text, *s, *e, bare.as_deref(), None) {
                Some((zone, end)) => {
                    m.target = Some(zone);
                    parts.push(Part { kind: "target", span: self.span_of(*s, end) });
                    resolved_spans.push((*s, end));
                    to = to.max(end);
                }
                None if bare.is_none() => m.unresolved.push(Unresolved { text: text.clone(), span: self.span_of(*s, *e), role: "target" }),
                None => {}
            }
        }
        // 「本地时间 / my time」：有别的时区时是目标，没有时是来源。
        if let Some((s, e)) = local_zone {
            if m.source.is_some() && m.instant.is_none() {
                if m.target.is_none() {
                    m.target = Some(ZoneRef::Local);
                    parts.push(Part { kind: "target", span: self.span_of(s, e) });
                    resolved_spans.push((s, e));
                    to = to.max(e);
                }
            } else if m.instant.is_none() {
                m.source = Some(ZoneRef::Local);
                parts.push(Part { kind: "zone", span: self.span_of(s, e) });
                resolved_spans.push((s, e));
                from = from.min(s);
                to = to.max(e);
            }
        }
        // 地点后确认时长，只跨已确认的时区跨度，普通内容词仍会挡住连接。
        resolved_spans.sort_unstable();
        for (minutes, start, end, gap_start) in pending_quantities {
            if m.time.is_none() || m.duration_minutes.is_some() { break; }
            let mut cursor = gap_start;
            for &(s, e) in &resolved_spans {
                if s >= cursor && e <= start {
                    if !self.duration_adjacent(cursor, s) { break; }
                    cursor = e;
                }
            }
            if self.duration_adjacent(cursor, start) {
                m.duration_minutes = Some(minutes);
                parts.push(Part { kind: "duration", span: self.span_of(start, end) });
                to = to.max(end);
            }
        }
        m.span = self.span_of(from, to);
        parts.sort_by_key(|p| p.span[0]);
        m.parts = parts;
        let written_period = owned.iter().any(|&k| matches!(seg[k].atom, Atom::Period(_) | Atom::DatePeriod(..)));
        let bare_hour = !period_applied && !written_period && clock_period.is_none() && m.end.is_none() && m.issues.is_empty()
            && self.bare_hour_atom(a);
        (m, (from, to), bare_hour)
    }
}

/// `j` 处是夹在两个词中间、前后都不带空白的连字符或撇号（Нью-Йорк、Côte d'Ivoire）。
fn glued_joint(u: &[Unit], j: usize) -> bool {
    u[j].kind == UKind::Punct
        && matches!(u[j].text.as_str(), "-" | "'")
        && !u[j].space_before
        && j > 0
        && u[j - 1].kind == UKind::Word
        && u.get(j + 1).is_some_and(|n| n.kind == UKind::Word && !n.space_before)
}

/// 零散词段里靠后的单个词要不要跳过（不去查）：夹在一串大写专名中间（前后两个词都大写）才跳过。
/// 串的最后一个词照查（「Weekly Sync Tokyo 9am」）；前一个词小写时它另起一串（「arasında Berlin saatinde」，
/// 靠后的单词不能一律跳过，否则这种写法会丢掉地名）。
fn inner_skip(u: &[Unit], tokens: &[(usize, usize, String)], st: usize) -> bool {
    u[tokens[st - 1].0].capital && tokens.get(st + 1).is_some_and(|n| u[n.0].capital)
}

/// 「城市」通名（折叠后，多词的按空格切开）：Kota Bandung 的 Kota、Thành phố X 的 Thành phố。它自己不是地名，
/// 一段由它开头时，后面的专名也当一个候选去查。
const CITY_HEADS: &[&str] = &[
    "city", "ciudad", "cidade", "citta", "ville", "kent", "kenti", "sehir", "miasto", "kota", "thanh pho", "stad", "stadt", "город",
];

/// 通名后面的小品词（Ciudad de X、Città del X、City of X 的 de / del / of）：跟着通名一起让开。
const CITY_HEAD_GLUE: &[&str] = &["de", "di", "da", "do", "del", "dos", "das", "du", "of"];

/// 一段零散词开头的「城市」通名：（通名占几个词，专名从第几个词起）。没有通名时 (0, 0)。
fn city_head_rest(tokens: &[(usize, usize, String)]) -> (usize, usize) {
    for head in CITY_HEADS {
        let words = head.split(' ').count();
        if tokens.len() >= words && head.split(' ').zip(tokens).all(|(w, t)| t.2 == w) {
            let mut rest = words;
            while tokens.get(rest).is_some_and(|t| CITY_HEAD_GLUE.contains(&t.2.as_str())) {
                rest += 1;
            }
            return (words, rest);
        }
    }
    (0, 0)
}

/// 有线索的地名变格还原：（语言，词尾，去掉词尾后补上的原形词尾）。只收波兰语方位格与俄语前置格，
/// 还原后的原形仍要由查表精确命中；没有词变了的就不查。（w Nowym Jorku → Nowy Jork、в Сиднее → Сидней）。
/// 挂在钟点上的一处地名线索：（地名，是否强线索，单元起，单元止，去冠词的地名，线索的语言）。
type PlaceClue = (String, bool, usize, usize, Option<String>, Option<&'static str>);
/// 「我在哪儿」说法里的地名：（地名，单元起，单元止，去冠词的地名，说法的语言）。
type WriterHit = (String, usize, usize, Option<String>, Option<&'static str>);

const PLACE_INFLECTIONS: &[(&str, &[(&str, &str)])] = &[
    // 波兰语：Londynie → Londyn、Paryżu → Paryż、Singapurze → Singapur、Nowym → Nowy（形容词）。
    ("pl", &[("niu", "eń"), ("ce", "ka"), ("ym", "y"), ("ie", ""), ("ze", ""), ("u", "")]),
    // 俄语：Сиднее → Сидней、Лондоне → Лондон、Нью-Йорке → Нью-Йорк。
    ("ru", &[("ее", "ей"), ("е", "")]),
];

/// 按语言逐词还原变格的地名：空格与连字符照原样保留（w Nowym Jorku → w Nowy Jork 的「Nowy Jork」）。
fn restore_inflected_place(text: &str, lang: Option<&str>) -> Option<String> {
    fn push_word(out: &mut String, word: &str, endings: &[(&str, &str)], changed: &mut bool) {
        let restored = endings.iter().find_map(|&(ending, restore)| {
            let stem = word.strip_suffix(ending).filter(|s| s.chars().count() >= 3)?;
            Some(format!("{stem}{restore}"))
        });
        match restored {
            Some(base) => {
                out.push_str(&base);
                *changed = true;
            }
            None => out.push_str(word),
        }
    }
    let endings = PLACE_INFLECTIONS.iter().find(|(l, _)| Some(*l) == lang)?.1;
    let mut out = String::new();
    let mut word = String::new();
    let mut changed = false;
    for c in text.chars() {
        if c == ' ' || c == '-' {
            push_word(&mut out, &word, endings, &mut changed);
            out.push(c);
            word.clear();
        } else {
            word.push(c);
        }
    }
    push_word(&mut out, &word, endings, &mut changed);
    changed.then_some(out)
}

/// 只保留有索引排名证明的大城，城市重名的每个选项分别过门槛。
fn nearby_famous_city(zone: ZoneRef, written: &str, language: &str) -> Option<ZoneRef> {
    match zone {
        city @ ZoneRef::City { city_index, .. } if city_index < super::places::BIG_CITY_LIMIT
            && super::places::nearby_city_matches(&city, written, language) => Some(city),
        ZoneRef::Options { reason: "city", options } => {
            let mut options: Vec<_> = options.into_iter().filter_map(|zone| nearby_famous_city(zone, written, language)).collect();
            match options.len() {
                0 => None,
                1 => options.pop(),
                _ => Some(ZoneRef::Options { reason: "city", options }),
            }
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_punctuation_table_has_no_duplicates() {
        for (i, a) in GROUP_PUNCT.iter().enumerate() {
            assert!(!GROUP_PUNCT[i + 1..].contains(a), "{a}");
        }
    }
}
