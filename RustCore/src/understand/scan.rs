// SPDX-License-Identifier: GPL-3.0-only
//! 原子识别（Scanner）：在单元序列的任意位置认出日期、钟点、时间段、相对时间、时长、截止习语、精确时刻、时区与地点线索。
//! 这里只认「一个词组是什么」，不拼装；两个数字的日期先写月还是先写日、点号连的两个数是钟点还是日期，
//! 这类要看整句语言与用户地区的判断留给装配层（`assemble.rs`），这里只把它们标成 `SlashPair` / `DotPair`。
use super::dates::{days_from_civil, valid_date, valid_month_day};
use super::lexicon::{Period, Sem, ABBREVIATIONS};
use super::types::{Clock, DateSpec, ZoneRef};
use super::units::{find, glued, is, is_punct, matcher, number, UKind, Unit};

/// 句段边界：句号一类切开两次提到；空行还切开日期沿用。单个换行不是边界（邮件会折行），装配层按单元里的「\n」算行号。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Break {
    Sentence,
    Paragraph,
}

#[derive(Debug, Clone)]
pub(super) enum Atom {
    Clock { clock: Clock, period: Option<Period>, explicit: bool },
    Period(Period),
    Date(DateSpec),
    /// 「今晚 / tonight / 明早」：日期 + 时段。
    DatePeriod(DateSpec, Period),
    /// 有前一处日期时按它的次日算，不能当成相对今天的明天。
    NextDay(Option<Period>),
    Relative(i64),
    /// 有线索的时长（for 2 hours、持续两小时、dauert 2 Stunden）。
    Duration(i64),
    /// 光秃秃的量（2 小时），只在紧跟钟点或时间段时算时长。
    Quantity(i64),
    /// 截止习语给的钟点（eod / noon / midnight），只在同一句没有显式钟点时成为一处提到。
    Idiom(&'static str, Clock),
    Instant(i64),
    Zone(ZoneRef),
    /// 「10/3」（两边都 ≤ 12）：先月还是先日由装配层按语言与地区定。`year` 是「10/3/2026」的年。
    SlashPair { a: u8, b: u8, year: Option<i32> },
    /// 「15.03」：钟点还是日期由装配层按语言定（有线索的早在这里就认成钟点或日期了）。
    DotPair { a: u8, b: u8 },
    RangeSep,
    From,
    Between,
    And,
    /// 地名线索：`strong` = 有「in / 在 / hora de / X time」这类词明说是地点。`bare` 有值时这个地名是冠词带出来的
    /// （the United States、aux États-Unis）：装配按原样当零散词查，再拿 `bare` 只认国家名，都没有就当没有线索。
    Place { text: String, strong: bool, bare: Option<String> },
    /// 目标线索（「在纽约是几点」「to London」）后面或前面的地名。
    Target { text: String, bare: Option<String> },
    TargetMarker,
    Boundary(Break),
    /// 形状是日期、钟点或偏移，数却不成立（2026-02-30、10:20:99、UTC+99）：装配时成为那一处的问题，不丢掉、不照常换算。
    /// 问题类型为 invalidDate | invalidTime | invalidOffset。
    Invalid(&'static str),
}

#[derive(Debug, Clone)]
pub(super) struct Located {
    pub(super) atom: Atom,
    /// 单元区间。
    pub(super) from: usize,
    pub(super) to: usize,
    pub(super) lang: Option<&'static str>,
}

/// 封闭日历语法的临时端点；省略字段在整段验证成功前不会成为原子。
struct CalendarEndpoint {
    from: usize,
    to: usize,
    day: u8,
    month: Option<u8>,
    year: Option<i32>,
    lang: Option<&'static str>,
}

pub(super) struct Scanner<'a> {
    pub(super) u: &'a [Unit],
    pub(super) out: Vec<Located>,
}

/// 2001-01-01 与 2100-01-01 的 Unix 秒：句子里的 10 / 13 位数字只在这个范围里才可能是时间戳。
const UNIX_MIN: i64 = 978_307_200;
const UNIX_MAX: i64 = 4_102_444_800;

fn identifier_payload(u: &[Unit], at: usize) -> bool {
    if u[at].kind != UKind::Word { return false; }
    let mut end = at;
    if end > 0 && u[end - 1].text == "\"" { end -= 1; }
    end >= 2 && matches!(u[end - 1].text.as_str(), "is" | ":" | "=")
        && matches!(u[end - 2].text.as_str(), "code" | "identifier" | "token")
}

/// 数字段先按紧邻词和形状分类；认走的整段保留位置，不再拆成钟点或日期。
pub(super) fn classify_numbers(u: &mut [Unit]) {
    let mut claims = Vec::new();
    let mut i = 0;
    while i < u.len() {
        let width = numeral_width(u, i);
        let Some(width) = width else { i += 1; continue };
        let mut end = number_span_end(u, i + width);
        let core_end = end;
        // 有四位年的有效日期保留整段，不能被价格或版本词抢走。
        if explicit_valid_date(u, i, core_end) {
            i = core_end;
            continue;
        }
        // 年在首尾的点号三连仍是日期；没有四位年的三连是版本。
        let dotted_version = u[i].kind == UKind::Number && core_end >= i + 5
            && u[i..core_end].iter().filter(|t| t.kind == UKind::Number).count() >= 3
            && u[i..core_end].iter().all(|t| t.kind == UKind::Number || is_punct(t, "."))
            && !u[i..core_end].iter().any(|t| t.kind == UKind::Number && t.text.len() == 4);
        // 末端单位管整个数量区间；and 只在紧邻 between 类词时连接两端。
        let between = (i.saturating_sub(6)..i).rev().find_map(|k| {
            is(u, k, |s| s == Sem::Between).filter(|n| k + n == i).map(|_| k)
        });
        let mut range_start = None;
        let connector = is(u, end, |s| s == Sem::RangeSep)
            .or_else(|| between.and_then(|_| is(u, end, |s| s == Sem::And)));
        if let Some(n) = connector {
            if let Some(width) = numeral_width(u, end + n) {
                let range_end = number_span_end(u, end + n + width);
                if local_blocker(u, range_end, Sem::NonTimeAfter).is_some() {
                    end = range_end;
                    range_start = between;
                }
            }
        }
        let before = (i.saturating_sub(6)..i).rev().find_map(|k| {
            local_blocker(u, k, Sem::NonTimeBefore).filter(|n| k + n == i).map(|_| k)
        });
        let slash_fraction = core_end == i + 3 && is_punct(&u[i + 1], "/")
            && u[i].kind == UKind::Number && u[i + 2].kind == UKind::Number;
        let after = local_blocker(u, end, Sem::NonTimeAfter)
            .or_else(|| slash_fraction.then(|| local_blocker(u, end, Sem::FractionMeasure)).flatten());
        if dotted_version || before.is_some() || after.is_some() {
            claims.push((before.or(range_start).unwrap_or(i), end + after.unwrap_or(0)));
            i = end + after.unwrap_or(0);
        } else {
            i += width;
        }
    }
    for (from, to) in claims {
        for t in &mut u[from..to] {
            t.kind = UKind::Punct;
            t.text.clear();
            super::units::reset_lexicon(t);
        }
    }
}

/// 黏着的数字、分隔符与小时写法组成一个跨度；句末句点留在跨度外。
fn number_span_end(u: &[Unit], mut end: usize) -> usize {
    while let Some(sep) = u.get(end) {
        let numeric_sep = sep.kind == UKind::Punct && matches!(sep.text.as_str(), "." | "," | ":" | "-" | "/");
        let hour_sep = sep.text == "h" && sep.kind == UKind::Word;
        let spaced_colon = cjk_colon_spaces(u, end);
        if (!sep.space_before || spaced_colon) && (numeric_sep || hour_sep)
            && u.get(end + 1).is_some_and(|t| t.kind == UKind::Number && (!t.space_before || spaced_colon))
        {
            end += 2;
        } else {
            break;
        }
    }
    end
}

/// 中日韩句中的全角冒号可在两侧留空白，其他分隔符保持紧贴。
fn cjk_colon_spaces(u: &[Unit], at: usize) -> bool {
    if !u.get(at).is_some_and(|t| is_punct(t, ":") && t.raw == "：") { return false; }
    let boundary = |k: usize| {
        let t = &u[k];
        t.kind == UKind::Punct && (matches!(t.text.as_str(), "!" | "?" | ";" | "。" | "；" | "|" | "\n\n")
            || t.text == "." && !in_dotted_abbreviation(u, k)
                && !(k > 0 && u[k - 1].kind == UKind::Number && !t.space_before
                    && u.get(k + 1).is_some_and(|next| next.kind == UKind::Number && !next.space_before)))
    };
    let start = (0..at).rev().find(|&k| boundary(k)).map_or(0, |k| k + 1);
    let end = (at + 1..u.len()).find(|&k| boundary(k)).unwrap_or(u.len());
    u[start..end].iter().any(|t| t.kind == UKind::Cjk)
}

/// 两位分钟的连字符写法只认紧邻的西里尔钟点线索或来源时区，不能拆开日期和号码。
fn hyphen_clock_shape(u: &[Unit], at: usize) -> Option<(u32, u32)> {
    let hour = u.get(at).filter(|t| t.kind == UKind::Number && t.text.len() <= 2)?;
    u.get(at + 1).filter(|t| is_punct(t, "-") && t.raw == "-" && !t.space_before)?;
    let minute = u.get(at + 2).filter(|t| t.kind == UKind::Number && t.text.len() == 2 && !t.space_before)?;
    let joined_number = |k: usize| u.get(k).is_some_and(|t| !t.space_before && matches!(t.text.as_str(), "-" | "/" | "." | ":"))
        && u.get(k + 1).is_some_and(|t| t.kind == UKind::Number && !t.space_before);
    if (at > 0 && !hour.space_before && matches!(u[at - 1].text.as_str(), "-" | "/" | "." | ":")) || joined_number(at + 3) { return None; }
    const CLOCK_CUES: &[&str] = &["в", "к", "около", "с", "до", "о", "об", "у", "з", "із", "зі"];
    let cued = at > 0 && CLOCK_CUES.contains(&u[at - 1].text.as_str());
    let end = at + 3;
    let source = zone_word_at(u, end) && u.get(end).is_some_and(|t| t.text == "мск" || t.text == "msk" || t.raw.chars().any(|c| ('\u{0400}'..='\u{04ff}').contains(&c)))
        || u.get(end).is_some_and(|t| t.text == "msk")
        || find(u, end, |s| s == Sem::ZoneBefore).is_some_and(|(n, _, lang)| lang == "ru" && zone_word_at(u, end + n));
    if !cued && !source { return None; }
    Some((hour.text.parse().ok()?, minute.text.parse().ok()?))
}

/// 韩语按字切分，分类词必须完整，不能把普通词的首尾当成单位。
fn local_blocker(u: &[Unit], i: usize, sem: Sem) -> Option<usize> {
    let (n, _, lang) = find(u, i, |s| s == sem)?;
    let hangul = |t: &Unit| t.text.chars().all(|c| ('\u{ac00}'..='\u{d7a3}').contains(&c));
    if lang == "ko" && ((i > 0 && glued(u, i) && hangul(&u[i - 1]))
        || u.get(i + n).is_some_and(|t| glued(u, i + n) && hangul(t))) {
        return None;
    }
    Some(n)
}

/// 只保护已有日期语法中的有效三项日期；日月斜线顺序保留给装配层。
fn explicit_valid_date(u: &[Unit], i: usize, end: usize) -> bool {
    let Some(span) = u.get(i..end) else { return false; };
    if span.len() != 5 || span[0].kind != UKind::Number || span[2].kind != UKind::Number || span[4].kind != UKind::Number
        || span[1].kind != UKind::Punct || span[3].text != span[1].text {
        return false;
    }
    let sep = span[1].text.as_str();
    let values = (span[0].text.parse::<i32>(), span[2].text.parse::<u8>(), span[4].text.parse::<i32>());
    let (Ok(a), Ok(b), Ok(c)) = values else { return false; };
    if span[0].text.len() == 4 && matches!(sep, "-" | "." | "/") {
        return u8::try_from(c).is_ok_and(|day| valid_date(a, b, day));
    }
    if span[4].text.len() == 4 {
        if let Ok(first) = u8::try_from(a) {
            return (sep == "." && valid_date(c, b, first))
                || (sep == "/" && (valid_date(c, b, first) || valid_date(c, first, b)));
        }
    }
    false
}

/// `numeric_date`、`named_date` 与日历端点只能从这里开始：数字、中日韩数字、月份词、ngày，或带撇号的土耳其语月份。
/// 不满足就一定读不出日期（debug 构建里两处调用都核对这一点）。
fn may_start_date(u: &[Unit], k: usize) -> bool {
    u.get(k).is_some_and(|t| matches!(t.kind, UKind::Number | UKind::Cjk) || t.text.contains('\''))
        || find(u, k, |s| matches!(s, Sem::DayBefore | Sem::Month(_))).is_some()
}

fn numeral_width(u: &[Unit], i: usize) -> Option<usize> {
    if u.get(i)?.kind == UKind::Number { Some(1) } else { is(u, i, |s| matches!(s, Sem::Number(_))) }
}

impl<'a> Scanner<'a> {
    fn push(&mut self, atom: Atom, from: usize, to: usize, lang: Option<&'static str>) {
        self.out.push(Located { atom, from, to, lang });
    }

    /// 钟点的分钟部分：`:MM`、`:MM:SS`、`h30`，或「.MM」（`dotted`，只在有钟点线索或分钟 ≥ 13 时认）。
    fn minutes_after(&self, i: usize, dotted: bool) -> Option<(u8, u8, usize)> {
        let u = self.u;
        let sep = u.get(i)?;
        let ok = is_punct(sep, ":") || (dotted && is_punct(sep, ".")) || (sep.kind == UKind::Word && sep.text == "h" && !sep.space_before);
        let spaced_colon = cjk_colon_spaces(u, i);
        if !ok || (sep.space_before && !spaced_colon) {
            return None;
        }
        let m = u.get(i + 1)?;
        if m.kind != UKind::Number || m.text.len() != 2 || (m.space_before && !spaced_colon) {
            return None;
        }
        let minute: u8 = m.text.parse().ok()?;
        if minute > 59 {
            return None;
        }
        if is_punct(sep, ":") && u.get(i + 2).is_some_and(|c| is_punct(c, ":")) {
            if let Some(s) = u.get(i + 3).filter(|s| s.kind == UKind::Number && s.text.len() == 2 && !s.space_before) {
                let second: u8 = s.text.parse().ok()?;
                if second <= 59 {
                    return Some((minute, second, 4));
                }
            }
        }
        Some((minute, 0, 2))
    }

    pub(super) fn scan(&mut self) {
        let u = self.u;
        let mut i = 0;
        while i < u.len() {
            let step = self.at(i);
            // 名字标记不增添原子，不查索引；保留完整词串，内部片段不另起候选。
            if step == 0 && u[i].nearby_candidate().1 == 0 {
                let end = nearby_name_end(u, i);
                if end > i {
                    for unit in &u[i..end] { unit.mark_nearby_candidate((i, end)); }
                }
            }
            i += step.max(1);
        }
        // 有地点线索的名字也沿用扫描器标记，线索词本身不计入地点跨度。
        for a in &self.out {
            if let Atom::Place { text, .. } = &a.atom {
                if text.is_empty() { continue; }
                let start = find(u, a.from, |s| matches!(s, Sem::PlaceIn | Sem::PlaceInArticle | Sem::ZoneBefore))
                    .map_or(a.from, |(n, _, _)| a.from + n);
                if start >= a.to { continue; }
                let end = nearby_name_end(u, start).min(a.to);
                for unit in &u[start..end] {
                    let prior = unit.nearby_candidate();
                    if prior.1 == 0 || prior.0 > start || prior.1 < end { unit.mark_nearby_candidate((start, end)); }
                }
            }
        }
        // 文字钟点的冒号标签或括号解释，与相同的数字钟点只保留一处；午夜的日期按数字写法定。
        let mut atoms = std::mem::take(&mut self.out).into_iter().peekable();
        self.out.reserve(atoms.len());
        while let Some(next) = atoms.next() {
            if let Some(end) = self.out.last().and_then(|previous| self.clock_restatement(previous, &next, atoms.peek())) {
                if end > next.to { atoms.next(); }
                let previous = self.out.last_mut().unwrap();
                previous.atom = next.atom;
                previous.to = end;
                previous.lang = previous.lang.or(next.lang);
            } else {
                self.out.push(next);
            }
        }
    }

    fn clock_restatement(&self, previous: &Located, next: &Located, following: Option<&Located>) -> Option<usize> {
        let Atom::Clock { clock: word, period: None, .. } = previous.atom else { return None; };
        let Atom::Clock { clock: written, period: None, explicit: true } = next.atom else { return None; };
        let u = self.u;
        if previous.to > next.from
            || (word.hour, word.minute, word.second) != (written.hour, written.minute, written.second)
            || u[previous.from..previous.to].iter().any(|t| t.kind == UKind::Number)
            || !u[next.from..next.to].iter().any(|t| t.kind == UKind::Number) { return None; }
        let midnight_word = (previous.from..previous.to).any(|at|
            find(u, at, |s| s == Sem::Midnight).is_some_and(|(n, _, _)| at + n <= previous.to));
        if word.day_offset != written.day_offset && !midnight_word { return None; }
        let mut end = next.to;
        // 两种写法各自明说了不同的时区，就仍是两处提到；相同的重复时区不是换算目标。
        if let (Some(before), Some(after)) = (self.out.get(self.out.len().saturating_sub(2)), following) {
            if let (Atom::Zone(a), Atom::Zone(b)) = (&before.atom, &after.atom) {
                if before.to == previous.from && next.to == after.from {
                    if a != b { return None; }
                    end = after.to;
                }
            }
        }
        let gap = &u[previous.to..next.from];
        if gap.is_empty() { return Some(end); }
        let separator = gap.iter().position(|t| is_punct(t, ":") || is_punct(t, "("))?;
        // 无空格汉字可连着短标签；逗号、连词、整句叙述不能把两处钟点拼成解释。
        let label = &gap[..separator];
        ((label.is_empty() || label.len() <= 8 && label.iter().all(|t| t.kind == UKind::Cjk)
            && is_punct(&gap[separator], ":"))
            && gap[separator..].iter().all(|t| t.kind == UKind::Punct && matches!(t.text.as_str(), ":" | "(" | "\n")))
            .then_some(end)
    }

    /// 在单元 `i` 处认一个原子，返回吃掉的单元数（0 = 什么都没认出，跳过这个单元）。
    fn at(&mut self, i: usize) -> usize {
        let u = self.u;
        let cur = &u[i];
        // 明写的代码／标识符标签只保护紧邻的一个词，后面的日期与钟点照常读取。
        // 这是局部字面量语法，不是对 domani / besok 等强词的语言否决。
        if identifier_payload(u, i) { return 1; }
        if cur.kind == UKind::Punct && cur.text == "\n\n" {
            self.push(Atom::Boundary(Break::Paragraph), i, i + 1, None);
            return 1;
        }
        if cur.kind == UKind::Punct && cur.text == "\n" {
            return 1;
        }
        // 句子边界：只看标点。「/」两边有空白才算隔开两次提到（9am NYC / 2pm London）；日期里的「10/3」不算；
        // 单个字母之间的点（U.S.、e.g.）是缩写，不算。
        if cur.kind == UKind::Punct && matches!(cur.text.as_str(), "." | "!" | "?" | ";" | "|" | "/" | "。" | "；")
            && !(cur.text == "." && u.get(i + 1).is_some_and(|n| n.kind == UKind::Number && !n.space_before))
            && !(cur.text == "." && in_dotted_abbreviation(u, i))
        {
            if cur.text != "/" || cur.space_before || u.get(i + 1).is_some_and(|n| n.space_before) {
                self.push(Atom::Boundary(Break::Sentence), i, i + 1, None);
            }
            return 1;
        }
        if let Some(n) = self.iana(i) {
            return n;
        }
        if let Some(n) = self.instant(i) {
            return n;
        }
        if let Some(n) = self.unix_in_sentence(i) {
            return n;
        }
        if let Some(n) = self.era_date(i) {
            return n;
        }
        if let Some(n) = self.relative_days(i) {
            return n;
        }
        if let Some(n) = self.relative(i) {
            return n;
        }
        if let Some(n) = self.dotted_date_before_clock(i) {
            return n;
        }
        if let Some(n) = self.duration(i) {
            return n;
        }
        if let Some(n) = self.shared_calendar(i) {
            return n;
        }
        // 「mai」在越南语是明天，在别的语言是五月；它本身不能证明语言。
        if cur.text == "mai" && vietnamese_evidence(u, i) {
            self.push(Atom::Date(DateSpec::Offset { days: 1 }), i, i + 1, Some("vi"));
            return 1;
        }
        if let Some(n) = self.numeric_date(i) {
            return n;
        }
        if may_start_date(u, i) {
            if let Some(n) = self.named_date(i) {
                return n;
            }
        } else {
            debug_assert!(self.named_date(i).is_none(), "date read at {i} without a date start");
        }
        if let Some(n) = self.compact_clock(i) {
            return n;
        }
        if let Some(n) = self.clock(i) {
            return n;
        }
        if let Some(n) = self.zone(i) {
            return n;
        }
        if let Some(n) = self.abbreviated_weekday_range(i) {
            return n;
        }
        if let Some(n) = self.weekday(i) {
            return n;
        }
        if let Some((n, sem, old_lang)) = find(u, i, |s| matches!(s, Sem::RelDay(_) | Sem::RelDayPeriod(..) | Sem::RelDayEnd(_) | Sem::NextDay | Sem::NextDayPeriod(_)))
            .filter(|(n, sem, _)| (!super::language::needs_evidence(u, i, *n)
                || !super::language::evidence(u, i, *n, None).has_grammar()
                || super::language::fits(u, i, *n, *sem, None)) && (*n != 1 || cur.text != "mai" || vietnamese_evidence(u, i)))
        {
            let lang = super::language::supported_language(u, i, n, sem, None).unwrap_or(old_lang);
            match sem {
                Sem::NextDay => self.push(Atom::NextDay(None), i, i + n, Some(lang)),
                Sem::NextDayPeriod(p) => self.push(Atom::NextDay(Some(p)), i, i + n, Some(lang)),
                Sem::RelDay(d) => self.push(Atom::Date(DateSpec::Offset { days: d }), i, i + n, Some(lang)),
                Sem::RelDayPeriod(d, p) => self.push(Atom::DatePeriod(DateSpec::Offset { days: d }, p), i, i + n, Some(lang)),
                // 「今天之内」：那天 + 到当天结束的截止（钟点是默认的 23:59，与截止习语同一套标注）。
                Sem::RelDayEnd(d) => {
                    self.push(Atom::Date(DateSpec::Offset { days: d }), i, i + n, Some(lang));
                    self.push(Atom::Idiom("dayend", Clock::at(23, 59)), i, i + n, Some(lang));
                }
                _ => {}
            }
            return n;
        }
        if let Some((n, Sem::Idiom(key), lang)) = find(u, i, |s| matches!(s, Sem::Idiom(_))) {
            let clock = match key {
                // 下班前 / EOD / COB 默认 17:00，宿主标明是默认、可改。
                "eod" => Clock::at(17, 0),
                "noon" | "before_noon" => Clock::at(12, 0),
                _ => Clock::at(23, 59),
            };
            self.push(Atom::Idiom(key, clock), i, i + n, Some(lang));
            return n;
        }
        // 西语「será」（将是）折叠后撞上意大利语「sera」（晚上）：原文带重音的不当时段（「será de 5:00 a. m.」报了矛盾）。
        if let Some((n, sem, lang)) = find(u, i, |s| matches!(s, Sem::Period(_) | Sem::Noon | Sem::Midnight))
            .filter(|(n, _, _)| !(*n == 1 && ((u[i].text == "sera" && !u[i].raw.is_ascii())
                || u[i].raw.to_lowercase() == "tới")))
        {
            match sem {
                Sem::Period(p) => self.push(Atom::Period(p), i, i + n, Some(lang)),
                Sem::Noon => self.push(Atom::Clock { clock: Clock::at(12, 0), period: None, explicit: true }, i, i + n, Some(lang)),
                Sem::Midnight => self.push(Atom::Clock { clock: Clock { hour: 0, minute: 0, second: 0, day_offset: 1 }, period: None, explicit: true }, i, i + n, Some(lang)),
                _ => {}
            }
            return n;
        }
        if let Some((n, _, lang)) = find(u, i, |s| s == Sem::LocalZone) {
            self.push(Atom::Zone(ZoneRef::Local), i, i + n, Some(lang));
            return n;
        }
        if let Some(n) = self.cues(i) {
            return n;
        }
        if let Some((n, sem, lang)) = find(u, i, |s| matches!(s, Sem::RangeSep | Sem::From | Sem::Between | Sem::And)) {
            let atom = match sem {
                Sem::RangeSep => Atom::RangeSep,
                Sem::From => Atom::From,
                Sem::Between => Atom::Between,
                _ => Atom::And,
            };
            self.push(atom, i, i + n, Some(lang));
            return n;
        }
        if cur.kind == UKind::Punct && cur.text == "-" {
            self.push(Atom::RangeSep, i, i + 1, None);
            return 1;
        }
        // 「>」「→」后面紧跟日期或钟点时是时间段的分隔（「24 fev - 2025 • 13:00 > 24 fev - 2025 • 19:00」）；
        // 后面是地名时照旧当目标（「9am ET → London」）。
        if cur.kind == UKind::Punct && matches!(cur.text.as_str(), ">" | "→") && starts_date_or_clock(u, i + 1) {
            self.push(Atom::RangeSep, i, i + 1, None);
            return 1;
        }
        0
    }

    /// 日本の元号で書いた日付：`令和7年5月1日(木)` = 2025-05-01、`令和元年5月1日` = 2019-05-01、
    /// `平成31年4月30日` = 2019-04-30（令和 n = 2018+n、平成 n = 1988+n、昭和 n = 1925+n、元年 = 1）。
    /// 括号里的星期照别的写好的星期一样并进日期。
    fn era_date(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        let base = match u[i].text.as_str() {
            "令" if u.get(i + 1).is_some_and(|t| t.text == "和") => 2018,
            "平" if u.get(i + 1).is_some_and(|t| t.text == "成") => 1988,
            "昭" if u.get(i + 1).is_some_and(|t| t.text == "和") => 1925,
            _ => return None,
        };
        let k = i + 2;
        let year = if u.get(k).is_some_and(|t| t.kind == UKind::Number && t.text.len() <= 2) && is(u, k + 1, |s| s == Sem::YearMark) == Some(1) {
            base + u[k].text.parse::<i32>().ok()?
        } else if u.get(k).is_some_and(|t| t.text == "元") && is(u, k + 1, |s| s == Sem::YearMark) == Some(1) {
            base + 1
        } else {
            return None;
        };
        let j = k + 2;
        let m = u.get(j).filter(|t| t.kind == UKind::Number && t.text.len() <= 2)?;
        is(u, j + 1, |s| s == Sem::MonthMark).filter(|n| *n == 1)?;
        let d = u.get(j + 2).filter(|t| t.kind == UKind::Number && t.text.len() <= 2)?;
        is(u, j + 3, |s| s == Sem::DayMark).filter(|n| *n == 1)?;
        let (month, day): (u8, u8) = (m.text.parse().ok()?, d.text.parse().ok()?);
        if !valid_date(year, month, day) {
            return None;
        }
        let end = self.weekday_in_parens(j + 4);
        self.push(Atom::Date(DateSpec::Absolute { year, month, day }), i, end, Some("ja"));
        Some(end - i)
    }

    /// 四位数字写的钟点（「1500 - 17:00 uur」的 1500 = 15:00）：只在它是时间段的一端、另一端是写明的钟点
    /// （带冒号或钟点词）时才算。数值像年的（1900–2100：「2000 - 23:00」的 2000）、紧跟在日期后面的（多半是它的年：
    /// 「9 december 1500」）、两头都是光秃秃的四位数的（「1500 - 1700 m」）都不算。
    fn compact_clock(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        let t = u.get(i).filter(|t| t.kind == UKind::Number && t.text.len() == 4)?;
        let value: u32 = t.text.parse().ok()?;
        if (1900..=2100).contains(&value) {
            return None;
        }
        let (hour, minute) = (value / 100, value % 100);
        if hour > 23 || minute > 59 {
            return None;
        }
        if self.out.last().is_some_and(|l| matches!(l.atom, Atom::Date(_)) && l.to == i) {
            return None;
        }
        // 自己后面紧跟的钟点词（「1500 uur」）一并吃掉。
        let mut end = i + 1;
        if let Some((n, _, _)) = find(u, end, |s| s == Sem::ClockAfter).filter(|_| !single_spaced_word(u, end)) {
            end += n;
        }
        // 前一头：区间符号后面是写明的钟点。
        let sep_at = find(u, end, |s| s == Sem::RangeSep)
            .map(|(n, _, _)| end + n)
            .or_else(|| {
                u.get(end)
                    .filter(|t| t.kind == UKind::Punct && matches!(t.text.as_str(), ">" | "→"))
                    .map(|_| end + 1)
            });
        let forward = sep_at.is_some_and(|k| Self::explicit_clock(u, k));
        // 后一头：刚认出的区间符号前面是一个写明的钟点。
        let backward = self.out.len() >= 2
            && matches!(self.out[self.out.len() - 1].atom, Atom::RangeSep)
            && self.out[self.out.len() - 1].to == i
            && matches!(self.out[self.out.len() - 2].atom, Atom::Clock { explicit: true, .. });
        if !forward && !backward {
            return None;
        }
        self.push(Atom::Clock { clock: Clock::at(hour as u8, minute as u8), period: None, explicit: true }, i, end, None);
        Some(end - i)
    }

    /// `k` 处是不是写明的钟点：「17:00」带冒号，或数字后面带钟点词（17 Uhr、17.00 uur、1700 hrs、17時）；
    /// 单个字母的钟点词要贴着数字（「3 h」是三小时）。四位紧凑写法也要带钟点词才算写明。
    fn explicit_clock(u: &[Unit], k: usize) -> bool {
        let Some(t) = u.get(k).filter(|t| t.kind == UKind::Number) else { return false };
        let with_word = |j: usize| find(u, j, |s| s == Sem::ClockAfter).is_some() && !single_spaced_word(u, j);
        match t.text.len() {
            1 | 2 => {
                (u.get(k + 1).is_some_and(|c| is_punct(c, ":")) && u.get(k + 2).is_some_and(|m| m.kind == UKind::Number && m.text.len() == 2))
                    || with_word(k + 1)
            }
            4 => with_word(k + 1),
            _ => false,
        }
    }

    /// ISO 8601 时刻（`2026-09-24T14:00:00Z`、`2026-09-24 14:00+02:00`）。
    fn instant(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        u.get(i).filter(|t| t.kind == UKind::Number && t.text.len() == 4)?;
        if !(is_punct(u.get(i + 1)?, "-") && u.get(i + 2)?.kind == UKind::Number && is_punct(u.get(i + 3)?, "-") && u.get(i + 4)?.kind == UKind::Number) {
            return None;
        }
        let t = u.get(i + 5)?;
        let hour_at = if t.text == "t" && !t.space_before { i + 6 } else if t.kind == UKind::Number && t.space_before { i + 5 } else { return None };
        // 日期与钟点之间是 T 的是正规 ISO，紧贴的 ±HH:MM 才算偏移（`offset_after_clock`）。
        let iso = hour_at == i + 6;
        let hour = u.get(hour_at).filter(|h| h.kind == UKind::Number && h.text.len() <= 2)?;
        let (minute, second, used) = self.minutes_after(hour_at + 1, false)?;
        let mut j = hour_at + 1 + used;
        // 小数秒。
        if u.get(j).is_some_and(|d| is_punct(d, ".") && !d.space_before) && u.get(j + 1).is_some_and(|d| d.kind == UKind::Number) {
            j += 2;
        }
        let (year, month, day) = (u[i].text.parse::<i32>().ok()?, u[i + 2].text.parse::<u8>().ok()?, u[i + 4].text.parse::<u8>().ok()?);
        let hour: u8 = hour.text.parse().ok()?;
        let date_ok = valid_date(year, month, day);
        if date_ok && hour == 24 {
            // 「2026-10-02 24:00」交给日期与钟点各自去认（24 点是次日 0 点）。
            return None;
        }
        if !date_ok || hour > 24 {
            // 形状是 ISO 时刻、数不成立：说出来，不丢掉（「2026-02-30 09:00 UTC」此前成了今天 9:00）。
            if !date_ok {
                self.push(Atom::Invalid("invalidDate"), i, i + 5, None);
            }
            if hour > 24 {
                self.push(Atom::Invalid("invalidTime"), hour_at, j, None);
            } else {
                self.push(Atom::Clock { clock: Clock { hour, minute, second, day_offset: 0 }, period: None, explicit: true }, hour_at, j, None);
            }
            return Some(j - i);
        }
        let offset = if u.get(j).is_some_and(|z| z.text == "z" && !z.space_before) {
            j += 1;
            Some(0)
        } else if let Some((minutes, used)) = numeric_offset(u, j).filter(|_| offset_after_clock(u, j, iso)) {
            j += used;
            Some(minutes)
        } else {
            None
        };
        let clock = Clock { hour, minute, second, day_offset: 0 };
        match offset {
            Some(minutes) => {
                let seconds = (days_from_civil(year, month, day) * 86_400) + hour as i64 * 3600 + minute as i64 * 60 + second as i64 - minutes as i64 * 60;
                self.push(Atom::Instant(seconds), i, j, None);
            }
            None => {
                self.push(Atom::Date(DateSpec::Absolute { year, month, day }), i, i + 5, None);
                self.push(Atom::Clock { clock, period: None, explicit: true }, hour_at, j, None);
            }
        }
        Some(j - i)
    }

    /// 句子里的 Unix 时间戳：10 / 13 位数字，前面有 unix / epoch / timestamp / 时间戳 / @ 一类线索；13 位（毫秒）落在
    /// 2001–2100 年、不紧贴 `+` 或字母时不要线索也认。10 位没线索的不认（电话号码），整段只有它时由入口另认。
    fn unix_in_sentence(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        let t = u.get(i).filter(|t| t.kind == UKind::Number && matches!(t.text.len(), 10 | 13))?;
        let raw: i64 = t.text.parse().ok()?;
        let seconds = if t.text.len() == 13 { raw / 1000 } else { raw };
        if !(UNIX_MIN..=UNIX_MAX).contains(&seconds) {
            return None;
        }
        let glued_to_symbol = i > 0 && !t.space_before && (u[i - 1].kind == UKind::Word || is_punct(&u[i - 1], "+") || is_punct(&u[i - 1], "-") || is_punct(&u[i - 1], "."));
        let glued_after = u.get(i + 1).is_some_and(|n| !n.space_before && (n.kind == UKind::Word || n.kind == UKind::Number || is_punct(n, "-") || (is_punct(n, ".") && u.get(i + 2).is_some_and(|next| !next.space_before && matches!(next.kind, UKind::Number | UKind::Word)))));
        if glued_after {
            return None;
        }
        let cued = (i > 0 && is_punct(&u[i - 1], "@"))
            || (1..=16).any(|back| i >= back && find(u, i - back, |s| s == Sem::UnixCue).is_some_and(|(n, _, _)| i - back + n == i || (i - back + n + 1 == i && matches!(u[i - 1].text.as_str(), ":" | "="))));
        if cued || (t.text.len() == 13 && !glued_to_symbol) {
            self.push(Atom::Instant(seconds), i, i + 1, None);
            return Some(1);
        }
        None
    }

    /// 数字日期：YYYY-MM-DD / YYYY/MM/DD / YYYY.MM.DD、DD.MM.YYYY、DD/MM/YYYY 与 MM/DD/YYYY（一边 > 12 时没有歧义，
    /// 否则交装配层按地区定）、DD.MM.（末尾有点）、CJK 的「2026年10月3日」「10月3日」「10월 3일」「十月三日」，
    /// 以及越南语「ngày 3 tháng 10」。点号连的两个数「15.03」没有线索时标成 `DotPair` 交装配层。
    fn numeric_date(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        let a = u.get(i).filter(|t| t.kind == UKind::Number)?;
        if let Some(n) = self.cjk_date(i) {
            return Some(n);
        }
        if let Some(n) = self.spaced_dot_date(i) {
            return Some(n);
        }
        let sep = u.get(i + 1)?;
        if sep.space_before || !(is_punct(sep, "-") || is_punct(sep, "/") || is_punct(sep, ".")) {
            return None;
        }
        let b = u.get(i + 2).filter(|t| t.kind == UKind::Number && !t.space_before)?;
        let third = u.get(i + 3).filter(|t| t.text == sep.text && !t.space_before);
        let c = third.and_then(|_| u.get(i + 4)).filter(|t| t.kind == UKind::Number && !t.space_before);
        if a.text.len() == 4 {
            let c = c?;
            let (year, month, day) = (a.text.parse().ok()?, b.text.parse().ok()?, c.text.parse().ok()?);
            if !valid_date(year, month, day) {
                // 年-月-日的形状、数不成立：说出来。
                if b.text.len() <= 2 && c.text.len() <= 2 {
                    self.push(Atom::Invalid("invalidDate"), i, i + 5, None);
                    return Some(5);
                }
                return None;
            }
            self.push(Atom::Date(DateSpec::Absolute { year, month, day }), i, i + 5, None);
            return Some(self.close_parens(i + 5) - i);
        }
        if a.text.len() > 2 || b.text.len() > 2 {
            return None;
        }
        let (x, y): (u8, u8) = (a.text.parse().ok()?, b.text.parse().ok()?);
        let year: Option<i32> = match c {
            Some(c) => Some(match c.text.len() {
                4 => c.text.parse().ok()?,
                2 => 2000 + c.text.parse::<i32>().ok()?,
                _ => return None,
            }),
            None => None,
        };
        let end_with_year = i + 5;
        // 带四位年的「31/02/2026」「31.02.2026」数不成立时说出来；两位年的可能是版本号，不管。
        let four_digit_year = c.is_some_and(|c| c.text.len() == 4);
        if sep.text == "/" {
            // 美国写法 M/D；一边大于 12 时没有歧义，否则交装配层。
            let decided = if x > 12 { Some((y, x)) } else if y > 12 { Some((x, y)) } else { None };
            return match (decided, year) {
                (Some((month, day)), Some(year)) => {
                    if !valid_date(year, month, day) {
                        if four_digit_year {
                            self.push(Atom::Invalid("invalidDate"), i, end_with_year, None);
                            return Some(end_with_year - i);
                        }
                        return None;
                    }
                    self.push(Atom::Date(DateSpec::Absolute { year, month, day }), i, end_with_year, None);
                    Some(self.close_parens(end_with_year) - i)
                }
                (Some((month, day)), None) => {
                    if !valid_month_day(month, day) {
                        return None;
                    }
                    self.push(Atom::Date(DateSpec::MonthDay { month, day }), i, i + 3, None);
                    Some(self.close_parens(i + 3) - i)
                }
                (None, year) => {
                    if x == 0 || y == 0 {
                        return None;
                    }
                    if let Some(year) = year {
                        if !valid_date(year, x, y) && !valid_date(year, y, x) {
                            if four_digit_year {
                                self.push(Atom::Invalid("invalidDate"), i, end_with_year, None);
                                return Some(end_with_year - i);
                            }
                            return None;
                        }
                    }
                    let end = if year.is_some() { end_with_year } else { i + 3 };
                    self.push(Atom::SlashPair { a: x, b: y, year }, i, end, None);
                    Some(end - i)
                }
            };
        }
        if sep.text == "-" {
            // `3-10` 不是日期（时间段用它），带年的 `3-10-2026` 也不认（写法太少见，读错代价大）。
            return None;
        }
        // 点号。
        if let Some(year) = year {
            // DD.MM.YYYY（德、波、俄、土）。
            if !valid_date(year, y, x) {
                if four_digit_year {
                    self.push(Atom::Invalid("invalidDate"), i, end_with_year, None);
                    return Some(end_with_year - i);
                }
                return None;
            }
            self.push(Atom::Date(DateSpec::Absolute { year, month: y, day: x }), i, end_with_year, None);
            return Some(self.close_parens(end_with_year) - i);
        }
        if third.is_some() {
            // 「3.10.」：德语写法，末尾有点。
            if !valid_month_day(y, x) {
                return None;
            }
            self.push(Atom::Date(DateSpec::MonthDay { month: y, day: x }), i, i + 4, None);
            return Some(self.close_parens(i + 4) - i);
        }
        let clock_cue = dotted_clock_context(u, i)
            || i > 0 && find(u, i - 1, |s| s == Sem::ClockBefore).is_some()
            || u.get(i + 3).is_some_and(|_| find(u, i + 3, |s| matches!(s, Sem::ClockAfter | Sem::Period(Period::Am | Period::Pm))).is_some());
        // 「15.03」：有钟点线索的让钟点去认；分钟 ≥ 13、或「09.00」这种月份不合法的只能是钟点，也让钟点认；
        // 日大于 23 的只能是日期；剩下两边都能读的交装配层按语言定。
        // 紧挨着中日韩字的「3.15」是月.日（「3.15 下午两点」），那里不用点号写钟点。
        let cjk_neighbour = (i > 0 && u[i - 1].kind == UKind::Cjk) || u.get(i + 3).is_some_and(|t| t.kind == UKind::Cjk);
        if cjk_neighbour {
            if valid_month_day(x, y) {
                self.push(Atom::Date(DateSpec::MonthDay { month: x, day: y }), i, i + 3, Some("zh"));
                return Some(3);
            }
            if valid_month_day(y, x) {
                self.push(Atom::DotPair { a: x, b: y }, i, i + 3, None);
                return Some(3);
            }
            return None;
        }
        if b.text.len() != 2 {
            return None;
        }
        // 「14.00」（整点、小时没有前导零）：钟点的读法只认带前导零的「09.00」，这里交装配按语言定。印尼、土耳其、荷、波、意语
        // 用点号写钟点，读成 14:00；别的语言不读（「14.00 USD」是价钱；印尼语「14.00」没读出）。
        let whole_hour_without_zero = x <= 23 && y == 0 && !a.text.starts_with('0');
        if clock_cue || (x <= 23 && (y >= 13 || y == 0) && !whole_hour_without_zero) {
            return None;
        }
        if x > 23 || x == 0 {
            if valid_month_day(y, x) {
                self.push(Atom::Date(DateSpec::MonthDay { month: y, day: x }), i, i + 3, None);
                return Some(self.close_parens(i + 3) - i);
            }
            return None;
        }
        if y > 59 {
            return None;
        }
        self.push(Atom::DotPair { a: x, b: y }, i, i + 3, None);
        Some(3)
    }

    /// 未闭合的日.月后面有明确钟点时，只读日期，先于同形小时单位的时长。
    fn dotted_date_before_clock(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        let day = u.get(i).filter(|t| t.kind == UKind::Number && t.text.len() <= 2)?.text.parse::<u8>().ok()?;
        u.get(i + 1).filter(|t| is_punct(t, ".") && !t.space_before)?;
        let month = u.get(i + 2).filter(|t| t.kind == UKind::Number && t.text.len() <= 2 && !t.space_before)?.text.parse::<u8>().ok()?;
        if !valid_month_day(month, day)
            || (i.saturating_sub(6)..i).any(|k| find(u, k, |s| s == Sem::ClockBefore).is_some_and(|(n, _, _)| k + n == i))
            || find(u, i + 3, |s| s == Sem::ClockAfter).is_some() {
            return None;
        }
        // 中日韩紧邻字的月.日已有明确顺序，仍交给数字日期读取。
        let cjk_neighbour = i > 0 && u[i - 1].kind == UKind::Cjk || u.get(i + 3).is_some_and(|t| t.kind == UKind::Cjk);
        if cjk_neighbour && valid_month_day(day, month) { return None; }
        let mut next = i + 3;
        while u.get(next).is_some_and(|t| t.kind == UKind::Punct && matches!(t.text.as_str(), "," | ":" | "(" | ")" | "\n")) { next += 1; }
        let clock_start = next;
        let cue_end = next + find(u, next, |s| s == Sem::ClockBefore).map_or(0, |(n, _, _)| n);
        if let Some((n, _, _)) = find(u, cue_end, |s| matches!(s, Sem::Period(_))) { next = cue_end + n; }
        // 前看复用钟点的有效性规则，只保留日期原子。
        let mut following = Scanner { u, out: Vec::new() };
        following.clock(next)?;
        if !following.out.iter().any(|a| matches!(a.atom, Atom::Clock { explicit: true, .. })) { return None; }
        let lang = find(u, clock_start, |s| s == Sem::ClockBefore).map(|(_, _, lang)| lang);
        // 明确钟点前的日.月只有日期读法，不留下钟点候选。
        self.push(Atom::Date(DateSpec::MonthDay { month, day }), i, i + 3, lang);
        Some(3)
    }

    /// 中日韩数字：一 … 三十一（一、二 / 两、三 … 十、十一 … 十九、二十 … 三十一）。返回（值，吃掉的单元数）。
    fn cjk_number(&self, i: usize) -> Option<(u32, usize)> {
        let digit = |c: &str| -> Option<u32> {
            Some(match c {
                "一" => 1, "二" | "两" | "兩" => 2, "三" => 3, "四" => 4, "五" => 5, "六" => 6, "七" => 7, "八" => 8, "九" => 9,
                _ => return None,
            })
        };
        let u = self.u;
        let mut j = i;
        let mut tens = 0u32;
        let mut ones = 0u32;
        let mut seen = false;
        if let Some(d) = u.get(j).filter(|t| t.kind == UKind::Cjk).and_then(|t| digit(&t.text)) {
            if u.get(j + 1).is_some_and(|t| t.text == "十") {
                tens = d;
                j += 2;
                seen = true;
            } else {
                ones = d;
                j += 1;
                return Some((ones, j - i));
            }
        } else if u.get(j).is_some_and(|t| t.text == "十") {
            tens = 1;
            j += 1;
            seen = true;
        }
        if !seen {
            return None;
        }
        if let Some(d) = u.get(j).filter(|t| t.kind == UKind::Cjk).and_then(|t| digit(&t.text)) {
            ones = d;
            j += 1;
        }
        Some((tens * 10 + ones, j - i))
    }

    fn cjk_date(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        let mut j = i;
        let mut year = None;
        if u[j].text.len() == 4 && u[j].kind == UKind::Number && is(u, j + 1, |s| s == Sem::YearMark) == Some(1) {
            year = u[j].text.parse::<i32>().ok();
            j += 2;
        } else if u[j].text.len() == 3 && u[j].text.starts_with('1') && is(u, j + 1, |s| s == Sem::YearMark) == Some(1) {
            // 台湾公文的民国纪年（「114年9月26日」= 2025 年；此前年份丢了，按「最近的将来」读成 2026 年）。
            year = u[j].text.parse::<i32>().ok().map(|y| y + 1911);
            j += 2;
        }
        let m = u.get(j).filter(|t| t.kind == UKind::Number && t.text.len() <= 2)?;
        is(u, j + 1, |s| s == Sem::MonthMark).filter(|n| *n == 1)?;
        let d = u.get(j + 2).filter(|t| t.kind == UKind::Number && t.text.len() <= 2)?;
        is(u, j + 3, |s| s == Sem::DayMark).filter(|n| *n == 1)?;
        let (month, day): (u8, u8) = (m.text.parse().ok()?, d.text.parse().ok()?);
        let spec = match year {
            Some(year) if valid_date(year, month, day) => DateSpec::Absolute { year, month, day },
            None if valid_month_day(month, day) => DateSpec::MonthDay { month, day },
            _ => {
                self.push(Atom::Invalid("invalidDate"), i, j + 4, Some("zh"));
                return Some(j + 4 - i);
            }
        };
        let end = self.weekday_in_parens(j + 4);
        self.push(Atom::Date(spec), i, end, Some("zh"));
        Some(end - i)
    }

    /// 中文数词的月日：「十月三日」「三月十五号」。
    fn cjk_numeral_date(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        let (month, n1) = self.cjk_number(i)?;
        if !(1..=12).contains(&month) || !u.get(i + n1).is_some_and(|t| t.text == "月") {
            return None;
        }
        let day_at = i + n1 + 1;
        let (day, n2) = self.cjk_number(day_at)?;
        if !is(u, day_at + n2, |s| s == Sem::DayMark).is_some_and(|n| n == 1) || !valid_month_day(month as u8, day as u8) {
            return None;
        }
        let end = self.weekday_in_parens(day_at + n2 + 1);
        self.push(Atom::Date(DateSpec::MonthDay { month: month as u8, day: day as u8 }), i, end, Some("zh"));
        Some(end - i)
    }

    /// 韩文公文的「2025. 7. 10.」「2026. 4. 27.(월)」：点紧贴前一个数、后面留空格，末尾常常还有一个点；没写年的「5. 13.(수)」
    /// 要紧跟括号里的星期才算（此前这些点被当成句号，日期整个丢了）。
    fn spaced_dot_date(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        let dot = |k: usize| u.get(k).is_some_and(|t| is_punct(t, ".") && !t.space_before);
        let spaced = |k: usize| u.get(k).filter(|t| t.kind == UKind::Number && t.space_before && t.text.len() <= 2);
        let a = &u[i];
        if !dot(i + 1) || !dot(i + 3) {
            return None;
        }
        let b = spaced(i + 2)?;
        if a.text.len() == 4 {
            let c = spaced(i + 4)?;
            let (year, month, day) = (a.text.parse().ok()?, b.text.parse().ok()?, c.text.parse().ok()?);
            if !valid_date(year, month, day) {
                return None;
            }
            let end = if dot(i + 5) { i + 6 } else { i + 5 };
            self.push(Atom::Date(DateSpec::Absolute { year, month, day }), i, end, None);
            return Some(self.close_parens(end) - i);
        }
        if a.text.len() > 2 {
            return None;
        }
        let (month, day): (u8, u8) = (a.text.parse().ok()?, b.text.parse().ok()?);
        let end = self.weekday_in_parens(i + 4);
        if end == i + 4 || !valid_month_day(month, day) {
            return None;
        }
        self.push(Atom::Date(DateSpec::MonthDay { month, day }), i, end, None);
        Some(end - i)
    }

    /// 刚推进去的日期后面紧跟括号里的星期：并进这个日期原子的范围（算「离钟点多近」时括号算日期的一部分：
    /// 「2026. 4. 27.(월) 10:00 마감 5. 13.(수) 23:59」的 10:00 归 4 月 27 日），返回新的结束位置。
    fn close_parens(&mut self, end: usize) -> usize {
        let closed = self.weekday_in_parens(end);
        if let Some(last) = self.out.last_mut().filter(|a| a.to == end && matches!(a.atom, Atom::Date(_))) {
            last.to = closed;
        }
        closed
    }

    /// 日期后面括号里的星期（「10月3日（金）」「10월 3일 (금)」「Oct 3 (Fri)」）：并进日期的范围，返回新的结束位置。
    fn weekday_in_parens(&self, end: usize) -> usize {
        let u = self.u;
        let Some(open) = u.get(end).filter(|t| is_punct(t, "(")) else { return end };
        let _ = open;
        let inner = end + 1;
        let close_at = if let Some(n) = is(u, inner, |s| matches!(s, Sem::Weekday(_))) {
            inner + n
        } else if u.get(inner).is_some_and(|t| t.kind == UKind::Cjk && t.text.chars().count() == 1 && "月火水木金土日월화수목금토일".contains(t.text.as_str())) {
            inner + 1
        } else {
            return end;
        };
        if u.get(close_at).is_some_and(|t| is_punct(t, ")")) {
            close_at + 1
        } else {
            end
        }
    }

    /// 封闭月份词表，以及土耳其语月份后紧接的撇号与处所格。
    fn named_month_at(&self, i: usize) -> Option<(usize, u8, &'static str)> {
        self.named_month_with_structure(i, false)
    }

    fn named_month_with_structure(&self, i: usize, structural: bool) -> Option<(usize, u8, &'static str)> {
        let u = self.u;
        let t = u.get(i)?;
        // 波兰语「się」折成「sie」，与八月缩写相撞；越南语「mai」是明天。
        if (t.text == "sie" && t.raw.to_lowercase() == "się") || (!structural && t.text == "mai" && vietnamese_evidence(u, i)) {
            return None;
        }
        if let Some((n, Sem::Month(month), lang)) = find(u, i, |s| matches!(s, Sem::Month(_))) {
            if !structural && super::language::needs_evidence(u, i, n)
                && !super::language::evidence(u, i, n, None).is_unknown() && !super::language::fits(u, i, n, Sem::Month(month), None) {
                return None;
            }
            return Some((n, month, super::language::supported_language(u, i, n, Sem::Month(month), None).unwrap_or(lang)));
        }
        let (base, suffix) = t.text.split_once('\'')?;
        if t.kind != UKind::Word || !matches!(suffix, "da" | "de" | "ta" | "te") {
            return None;
        }
        matcher().by_first.get(base)?.iter().filter(|p| p.units.len() == 1).flat_map(|p| p.sems.iter()).find_map(|(sem, lang)| {
            match sem {
                Sem::Month(month) if *lang == "tr" => Some((1, *month, "tr")),
                _ => None,
            }
        })
    }

    /// 紧邻的钟点语法为「日数 + 月名」提供结构证据；内容词、句号与空行都结束这段语法。
    fn date_clock_after(&self, at: usize) -> bool {
        let u = self.u;
        let mut k = at;
        let mut period = None;
        while k < u.len() {
            // 复用完整钟点语法：数词、区间与时长的边界和实际扫描保持一致。
            let mut probe = Scanner { u, out: Vec::new() };
            if let Some((p, from, to)) = period { probe.push(Atom::Period(p), from, to, None); }
            if probe.clock(k).is_some() && probe.out.iter().any(|a| matches!(a.atom, Atom::Clock { .. })) { return true; }
            if u[k].kind == UKind::Number || is(u, k, |s| matches!(s, Sem::Number(_))).is_some() { break; }
            if u[k].kind == UKind::Punct && matches!(u[k].text.as_str(), "," | ":" | "•" | "(" | ")" | "\n") {
                k += 1;
            } else if let Some((n, sem, _)) = find(u, k, |s| matches!(s, Sem::ClockBefore | Sem::ClockContextBefore | Sem::Filler | Sem::Period(_))) {
                if let Sem::Period(p) = sem { period = Some((p, k, k + n)); }
                k += n;
            } else {
                break;
            }
        }
        false
    }

    /// 月份名的日期：「3 October 2026」「October 3rd」「3 de octubre」「le 3 octobre」「3. Oktober」「3 października」
    /// 「3 Ekim」「ngày 3 tháng 10」「十月三日」，前面可以有星期（「Thursday, October 2」），后面可以有年。
    fn named_date(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        if let Some(n) = self.cjk_numeral_date(i) {
            return Some(n);
        }
        let ordinal = |j: usize| -> usize {
            // 1st / 2nd / 3rd / 4th、1er、1º、3.（德语）、3e（荷兰语）。
            match u.get(j) {
                Some(t) if !t.space_before && matches!(t.text.as_str(), "st" | "nd" | "rd" | "th" | "er" | "e" | "º" | "ª" | "°" | ".") => 1,
                Some(t) if !t.space_before && is_punct(t, "-") && u.get(j + 1).is_some_and(|s| !s.space_before && s.text == "го") => 2,
                _ => 0,
            }
        };
        let skip_glue = |mut j: usize| -> usize {
            while let Some(t) = u.get(j) {
                if matches!(t.text.as_str(), "de" | "of" | "," | "del" | "le" | "am" | "the" | "den") {
                    j += 1;
                } else {
                    break;
                }
            }
            j
        };
        let year_at = |j: usize| -> Option<(i32, usize)> {
            // 「24 fev - 2025」（巴西活动页的写法）：两边留空格的短横后面紧跟四位年，也是年。
            let spaced_dash = u.get(j).is_some_and(|t| is_punct(t, "-") && t.space_before) && u.get(j + 1).is_some_and(|t| t.space_before);
            let k = if u.get(j).is_some_and(|t| is_punct(t, ",")) || u.get(j).is_some_and(|t| t.text == "de" || t.text == "del") || spaced_dash {
                j + 1
            } else {
                j
            };
            let t = u.get(k).filter(|t| t.kind == UKind::Number && t.text.len() == 4)?;
            let year: i32 = t.text.parse().ok()?;
            // 年后面的「r.」（波兰语 rok）、「г.」（俄语 год）是年的一部分：并进日期，那个点也就不算句号（「24 marca 2025 r.
            // (poniedziałek) do godziny 12:00」「12 мая 2025г.」；此前日期与后面的钟点被这个点隔成两句）。
            let mut end = k + 1;
            if u.get(end).is_some_and(|m| matches!(m.text.as_str(), "r" | "г")) {
                end += 1;
                if u.get(end).is_some_and(|d| is_punct(d, ".") && !d.space_before) {
                    end += 1;
                }
            }
            // 「3 October 2026, 18:00」里的 2026 是年；「October 3 1800」不会有人这么写钟点。
            (1900..=2200).contains(&year).then_some((year, end))
        };
        // 四位年份完整出现时，才消费前面的逗号和 năm。
        let vietnamese_year_at = |at: usize| -> Option<(i32, usize)> {
            let start = at + usize::from(u.get(at).is_some_and(|t| is_punct(t, ",")));
            let mark = is(u, start, |s| s == Sem::YearMark).unwrap_or(0);
            let index = start + mark;
            let token = u.get(index).filter(|t| t.kind == UKind::Number && t.text.len() == 4)?;
            Some((token.text.parse().ok()?, index + 1))
        };
        // 越南语：ngày D tháng M 后可带逗号、năm 和四位年份。
        if let Some(n) = is(u, i, |s| s == Sem::DayBefore) {
            let d = u.get(i + n).filter(|t| t.kind == UKind::Number && t.text.len() <= 2)?;
            let m_at = i + n + 1;
            let n2 = is(u, m_at, |s| s == Sem::MonthBefore)?;
            let m = u.get(m_at + n2).filter(|t| t.kind == UKind::Number && t.text.len() <= 2)?;
            let (month, day): (u8, u8) = (m.text.parse().ok()?, d.text.parse().ok()?);
            let mut end = m_at + n2 + 1;
            let year = vietnamese_year_at(end).map(|(year, next)| {
                end = next;
                year
            });
            // 日期后的逗号紧接钟点时，仍属于同一句。
            if u.get(end).is_some_and(|t| is_punct(t, ",")) && Self::explicit_clock(u, end + 1) {
                end += 1;
            }
            return self.push_date(year, month, day, i, end, Some("vi"));
        }
        // D [ordinal] [de] Month [year]
        if let Some(d) = u.get(i).filter(|t| t.kind == UKind::Number && t.text.len() <= 2) {
            let mut j = i + 1 + ordinal(i + 1);
            j = skip_glue(j);
            // 日数 + 月词 + 年／钟点本身就是日期证据，不依赖整句语言投票。
            let structural = find(u, j, |s| matches!(s, Sem::Month(_))).is_some_and(|(n, _, _)| {
                let end = j + n + usize::from(u.get(j + n).is_some_and(|t| is_punct(t, ".") && !t.space_before));
                year_at(end).is_some() || self.date_clock_after(end)
            });
            let month = self.named_month_with_structure(j, structural).or_else(|| {
                (u.get(j)?.text == "mai").then(|| find(u, j, |s| matches!(s, Sem::Month(_))))?
                    .and_then(|(n, sem, lang)| if let Sem::Month(month) = sem { Some((n, month, lang)) } else { None })
            });
            if let Some((n, month, lang)) = month {
                let day: u8 = d.text.parse().ok()?;
                let mut end = j + n;
                if u.get(end).is_some_and(|t| is_punct(t, ".") && !t.space_before) {
                    end += 1;
                }
                let year = year_at(end).map(|(y, e)| {
                    end = e;
                    y
                });
                return self.push_date(year, month, day, i, end, Some(lang));
            }
            // 越南语「3 tháng 10」：后面紧跟的四位数是年，不写 năm 也算（「8 tháng 2 2025」）。
            if let Some(n) = is(u, i + 1, |s| s == Sem::MonthBefore) {
                let m = u.get(i + 1 + n).filter(|t| t.kind == UKind::Number && t.text.len() <= 2)?;
                let (month, day): (u8, u8) = (m.text.parse().ok()?, d.text.parse().ok()?);
                let mut end = i + 2 + n;
                let year = vietnamese_year_at(end).map(|(year, next)| {
                    end = next;
                    year
                });
                // 日期后的逗号紧接钟点时，仍属于同一句。
                if u.get(end).is_some_and(|t| is_punct(t, ",")) && Self::explicit_clock(u, end + 1) {
                    end += 1;
                }
                return self.push_date(year, month, day, i, end, Some("vi"));
            }
            return None;
        }
        // Month D[ordinal][,] [year]
        let structural = find(u, i, |s| matches!(s, Sem::Month(_))).is_some_and(|(n, _, _)| {
            let j = i + n + usize::from(u.get(i + n).is_some_and(|t| is_punct(t, ".") && !t.space_before));
            u.get(j).is_some_and(|t| t.kind == UKind::Number && t.text.len() <= 2)
                && (year_at(j + 1 + ordinal(j + 1)).is_some() || self.date_clock_after(j + 1 + ordinal(j + 1)))
        });
        if let Some((n, month, lang)) = self.named_month_with_structure(i, structural) {
            let mut j = i + n;
            if u.get(j).is_some_and(|t| is_punct(t, ".") && !t.space_before) {
                j += 1;
            }
            let d = u.get(j).filter(|t| t.kind == UKind::Number && t.text.len() <= 2)?;
            // 不带变音符号的「sie 3 października」也先读后面的明确月份，保留单独「sie 3」的八月写法。
            if lang == "pl" && u[i].text == "sie" && self.named_month_at(j + 1).is_some_and(|(_, _, l)| l == "pl") {
                return None;
            }
            let day: u8 = d.text.parse().ok()?;
            let mut end = j + 1 + ordinal(j + 1);
            let year = year_at(end).map(|(y, e)| {
                end = e;
                y
            });
            return self.push_date(year, month, day, i, end, Some(lang));
        }
        None
    }

    /// 只在封闭的列表或范围里补日数省略的月份和年份；普通数字不会从邻近日期借字段。
    fn shared_calendar(&mut self, i: usize) -> Option<usize> {
        let first = self.calendar_endpoint(i)?;
        let mut endpoints = vec![first];
        let mut separators = Vec::new();
        let mut end = endpoints[0].to;
        while let Some((width, range, lang)) = self.calendar_connector(end) {
            let next = end + width;
            let Some(endpoint) = self.calendar_endpoint(next) else { break; };
            separators.push((end, next, range, lang));
            end = endpoint.to;
            endpoints.push(endpoint);
            // 范围只取两端；不把后面的独立日期或钟点再纳入同一语法。
            if range { break; }
        }
        if endpoints.len() < 2 { return None; }
        let range = separators.iter().any(|s| s.2);
        let calendar = endpoints.iter().find(|e| e.month.is_some())?;
        let month = calendar.month?;
        let lang = calendar.lang;
        let inherited_year = endpoints.iter().rev().find_map(|e| e.year);
        let last = endpoints.last()?;
        let last_values = (last.month.unwrap_or(month), last.day);
        let first_values = (endpoints[0].month.unwrap_or(month), endpoints[0].day);
        let specs: Option<Vec<_>> = endpoints.iter().enumerate().map(|(k, e)| {
            let m = e.month.unwrap_or(month);
            let year = e.year.or(inherited_year).map(|year| {
                // 范围只写一端年份时，跨年依文字顺序衔接；列表保持同年。
                if range && e.year.is_none() && e.month.is_some() && k == 0 && (m, e.day) > last_values { year - 1 }
                else if range && e.year.is_none() && e.month.is_some() && k > 0 && (m, e.day) < first_values { year + 1 }
                else { year }
            });
            match year {
                Some(year) if valid_date(year, m, e.day) => Some(DateSpec::Absolute { year, month: m, day: e.day }),
                None if valid_month_day(m, e.day) => Some(DateSpec::MonthDay { month: m, day: e.day }),
                _ => None,
            }
        }).collect();
        let specs = specs?;
        // 已读到的星期属于紧跟它的日数，不再另起一个星期提到。
        let previous_weekday = self.out.last().filter(|a| a.to == i && matches!(a.atom, Atom::Date(DateSpec::Weekday { .. }))).map(|a| a.from);
        if let Some(from) = previous_weekday { endpoints[0].from = from; self.out.pop(); }
        for (k, (endpoint, spec)) in endpoints.into_iter().zip(specs).enumerate() {
            self.push(Atom::Date(spec), endpoint.from, endpoint.to, endpoint.lang.or(lang));
            if let Some(&(from, to, range, lang)) = separators.get(k) {
                self.push(if range { Atom::RangeSep } else { Atom::And }, from, to, lang);
            }
        }
        Some(end - i)
    }

    /// 日期端点可带星期或越南语 ngày；没有月份的端点暂存为日数，只有整段闭合后才发布。
    fn calendar_endpoint(&self, i: usize) -> Option<CalendarEndpoint> {
        let u = self.u;
        let mut at = i;
        if let Some(n) = is(u, at, |s| matches!(s, Sem::Weekday(_))) { at += n; }
        let day_cue = find(u, at, |s| s == Sem::DayBefore).filter(|(_, _, lang)| *lang == "vi");
        if let Some((n, _, _)) = day_cue { at += n; }
        // 写了自己的钟点、时段或时长单位时，不能把小时数字借读成日数。
        // 各项都是只读判断：先读端点，读不出来（大多数位置）就不必再查这一串。
        let endpoint = if may_start_date(u, at) {
            self.calendar_endpoint_at(i, at, day_cue.is_some())?
        } else {
            debug_assert!(self.calendar_endpoint_at(i, at, day_cue.is_some()).is_none(), "date read at {at} without a date start");
            return None;
        };
        let borrows_clock = Self::explicit_clock(u, at)
            || (at.saturating_sub(6)..at).any(|k| find(u, k, |s| s == Sem::ClockBefore).is_some_and(|(n, _, _)| k + n == at))
            || find(u, at + 1, |s| matches!(s, Sem::Period(_) | Sem::HourUnit | Sem::MinuteUnit | Sem::DayUnit | Sem::DurationAfter)).is_some();
        (!borrows_clock).then_some(endpoint)
    }

    /// `calendar_endpoint` 跳过星期与 ngày 之后，从 `at` 读端点本身。
    fn calendar_endpoint_at(&self, i: usize, at: usize, day_cue: bool) -> Option<CalendarEndpoint> {
        let u = self.u;
        // ngày D/M[/YYYY] 明写日月顺序，只在闭合范围里使用这个端点。
        if day_cue && u.get(at + 1).is_some_and(|t| is_punct(t, "/") && !t.space_before) {
            let day = u.get(at).filter(|t| t.kind == UKind::Number && t.text.len() <= 2)?.text.parse().ok()?;
            let month = u.get(at + 2).filter(|t| t.kind == UKind::Number && t.text.len() <= 2 && !t.space_before)?.text.parse().ok()?;
            let mut to = at + 3;
            let year = if u.get(to).is_some_and(|t| is_punct(t, "/") && !t.space_before) {
                let y = u.get(to + 1).filter(|t| t.kind == UKind::Number && t.text.len() == 4 && !t.space_before)?.text.parse().ok()?;
                to += 2;
                Some(y)
            } else { None };
            return Some(CalendarEndpoint { from: i, to, day, month: Some(month), year, lang: Some("vi") });
        }
        let mut probe = Scanner { u, out: Vec::new() };
        let parsed = probe.numeric_date(at).or_else(|| probe.named_date(at));
        if let Some(n) = parsed {
            let date = probe.out.iter().find_map(|a| match a.atom {
                Atom::Date(DateSpec::Absolute { year, month, day }) => Some((day, month, Some(year))),
                Atom::Date(DateSpec::MonthDay { month, day }) => Some((day, month, None)),
                _ => None,
            });
            if let Some((day, month, year)) = date {
                return Some(CalendarEndpoint { from: i, to: at + n, day, month: Some(month), year, lang: probe.out.last().and_then(|a| a.lang) });
            }
            return None;
        }
        // 裸日数端点只能是 1–31 的一两位数字；先查这一条，不是数字的位置不必再试读钟点。
        let day = u.get(at).filter(|t| t.kind == UKind::Number && t.text.len() <= 2)?.text.parse::<u8>().ok()?;
        if !(1..=31).contains(&day) { return None; }
        // 省略月份的日数不能抢走完整钟点语法；分钟在前的钟点，以及由明确终点证明的裸起点都保留。
        let mut clock_probe = Scanner { u, out: Vec::new() };
        if clock_probe.clock(at).is_some() && clock_probe.out.iter().any(|a| matches!(a.atom, Atom::Clock { .. })) {
            return None;
        }
        // 黏着数字分隔符意味着还有自己的数段，不能截取其中的首个数字。
        if u.get(at + 1).is_some_and(|t| !t.space_before && matches!(t.text.as_str(), "/" | "." | ":")) { return None; }
        Some(CalendarEndpoint { from: i, to: at + 1, day, month: None, year: None, lang: None })
    }

    /// 日历列表沿用明确连词；au/al 是日期范围的封闭补充，不扩展地点或钟点词表。
    fn calendar_connector(&self, i: usize) -> Option<(usize, bool, Option<&'static str>)> {
        let u = self.u;
        if u.get(i).is_some_and(|t| matches!(t.text.as_str(), "au" | "al")) {
            return Some((1, true, Some(if u[i].text == "au" { "fr" } else { "es" })));
        }
        if u.get(i).is_some_and(|t| is_punct(t, ",")) {
            let n = is(u, i + 1, |s| s == Sem::And).unwrap_or(0);
            return Some((1 + n, false, None));
        }
        find(u, i, |s| matches!(s, Sem::And | Sem::RangeSep)).map(|(n, sem, lang)| (n, sem == Sem::RangeSep, Some(lang)))
    }

    fn push_date(&mut self, year: Option<i32>, month: u8, day: u8, from: usize, to: usize, lang: Option<&'static str>) -> Option<usize> {
        let spec = match year {
            Some(year) if valid_date(year, month, day) => DateSpec::Absolute { year, month, day },
            None if valid_month_day(month, day) => DateSpec::MonthDay { month, day },
            _ => return None,
        };
        // 前面紧挨着的星期（「Thursday, October 2」）一起算进日期的范围，不另起一个星期原子。
        // 吃掉的单元数从日期自己的起点 `start` 算：扫描从这里往后走，并进来的星期在前面，早已走过
        // （此前按并进后的起点算，多跳了星期那几格，「Thursday, October 2\n18:00」的 18 被跳过）。
        let start = from;
        let mut from = from;
        if let Some(last) = self.out.last() {
            if matches!(last.atom, Atom::Date(DateSpec::Weekday { .. })) && last.to + 2 >= from {
                from = last.from;
                self.out.pop();
            }
        }
        let to = self.weekday_in_parens(to);
        self.push(Atom::Date(spec), from, to, lang);
        Some(to - start)
    }

    /// 两个英语星期词由范围词直接连接时，结构本身允许缩写；独立的 sat/sun 仍需钟点证据。
    fn abbreviated_weekday_range(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        let weekday = |at| find(u, at, |s| matches!(s, Sem::Weekday(_) | Sem::WeekdayAbbr(_)))
            .filter(|(_, _, lang)| *lang == "en");
        let prefix = find(u, i, |s| matches!(s, Sem::NextWeek | Sem::ThisWeek | Sem::LastWeek))
            .filter(|(_, _, lang)| *lang == "en");
        // 前面写过周限定词时，从限定词处读整段；验证失败后不能跳过它重读成无限定范围。
        if prefix.is_none() && (i.saturating_sub(2)..i).any(|at| find(u, at, |s| matches!(s, Sem::NextWeek | Sem::ThisWeek | Sem::LastWeek))
            .is_some_and(|(n, _, lang)| lang == "en" && at + n == i)) { return None; }
        let first_at = i + prefix.map_or(0, |(n, _, _)| n);
        let week = prefix.map(|(_, sem, _)| match sem { Sem::NextWeek => "next", Sem::ThisWeek => "this", _ => "last" });
        let (n, first, _) = weekday(first_at)?;
        let sep = first_at + n;
        let (width, _, _) = find(u, sep, |s| s == Sem::RangeSep).filter(|(_, _, lang)| *lang == "en")?;
        let next = sep + width;
        let (last_width, last, _) = weekday(next)?;
        if !matches!(first, Sem::WeekdayAbbr(_)) && !matches!(last, Sem::WeekdayAbbr(_)) { return None; }
        for (at, len, sem) in [(first_at, n, first), (next, last_width, last)] {
            if !super::language::fits(u, at, len, sem, None) && !super::language::evidence(u, at, len, None).is_unknown() {
                return None;
            }
        }
        let value = |sem| match sem { Sem::Weekday(w) | Sem::WeekdayAbbr(w) => w, _ => unreachable!() };
        let end = next + last_width;
        // 终点另写了限定词时交还普通星期读取，不能吞掉它或发明跨周范围。
        if find(u, end, |s| matches!(s, Sem::NextAfter | Sem::NextWeek | Sem::ThisWeek | Sem::LastWeek))
            .is_some_and(|(_, _, lang)| lang == "en") { return None; }
        self.push(Atom::Date(DateSpec::Weekday { weekday: value(first), week }), i, sep, Some("en"));
        self.push(Atom::RangeSep, sep, next, Some("en"));
        self.push(Atom::Date(DateSpec::Weekday { weekday: value(last), week }), next, end, Some("en"));
        Some(end - i)
    }

    /// 星期：[下 / next / 来週の / 다음 주 / w przyszły] 星期 [prochain / próximo / depan / tuần sau / next week]。
    fn weekday(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        let mut j = i;
        let mut week = None;
        let mut lang = None;
        if let Some((n, sem, l)) = find(u, j, |s| matches!(s, Sem::NextWeek | Sem::ThisWeek | Sem::LastWeek)) {
            // 修饰词后面必须紧跟星期，否则它只是普通的词（「this」「上」「bu」）。
            let mut k = j + n;
            if is(u, k, |s| s == Sem::Filler).is_some() && find(u, k, |s| matches!(s, Sem::Weekday(_))).is_none() {
                k += is(u, k, |s| s == Sem::Filler).unwrap();
            }
            if find(u, k, |s| matches!(s, Sem::Weekday(_))).is_some() {
                week = Some(match sem {
                    Sem::NextWeek => "next",
                    Sem::ThisWeek => "this",
                    _ => "last",
                });
                lang = Some(l);
                j = k;
            }
        }
        let (n, sem, old_lang) = find(u, j, |s| matches!(s, Sem::Weekday(_) | Sem::WeekdayAbbr(_)))?;
        let l = super::language::supported_language(u, j, n, sem, None).unwrap_or(old_lang);
        let weekday = match sem {
            Sem::Weekday(w) => w,
            // 缩写只在后面紧跟钟点数字（可隔一个点）时算星期：「Di 15 Uhr」「mer 9h」「вт 15:00」「sáb 11 de la mañana」。
            Sem::WeekdayAbbr(w) => {
                let next = if u.get(j + n).is_some_and(|t| is_punct(t, ".") && !t.space_before) { j + n + 1 } else { j + n };
                if !u.get(next).is_some_and(|t| t.kind == UKind::Number) {
                    return None;
                }
                // 缩写长短都用独立证据检查。没有证据时保留既有读法，兼容边界尚未收紧。
                if !super::language::fits(u, j, n, sem, None) && !super::language::evidence(u, j, n, None).is_unknown() {
                    return None;
                }
                w
            }
            _ => return None,
        };
        let mut end = j + n;
        if let Some(n2) = is(u, end, |s| s == Sem::NextAfter) {
            week = Some("next");
            end += n2;
        } else if let Some((n2, sem, _)) = find(u, end, |s| matches!(s, Sem::NextWeek | Sem::ThisWeek | Sem::LastWeek))
            .filter(|(n2, _, lang)| *lang == "pl" && *n2 >= 3 && u[end].text == "w") {
            // 完整的波兰语周限定词跟在星期后面，不能当成地点。
            week = Some(match sem { Sem::NextWeek => "next", Sem::ThisWeek => "this", _ => "last" });
            end += n2;
        }
        // 「Mon.」的点。
        if u.get(end).is_some_and(|t| is_punct(t, ".") && !t.space_before) && u.get(end + 1).is_some_and(|t| t.kind != UKind::Number) {
            end += 1;
        }
        self.push(Atom::Date(DateSpec::Weekday { weekday, week }), i, end, lang.or(Some(l)));
        Some(end - i)
    }

    /// 数量 + 单位，可以两项（「1 hour and 30 minutes」「1小时30分钟」「2-hour」）：（分钟，吃掉的单元数）。
    fn quantity(&self, j: usize) -> Option<(i64, usize)> {
        let u = self.u;
        let mut total = 0i64;
        let mut k = j;
        let mut items = 0;
        loop {
            if let Some((n, sem, _)) = find(u, k, |s| matches!(s, Sem::HalfHour | Sem::OneHour | Sem::OneMinute | Sem::FixedMinutes(_))) {
                total += match sem {
                    Sem::HalfHour => 30,
                    Sem::OneMinute => 1,
                    Sem::FixedMinutes(minutes) => i64::from(minutes),
                    _ => 60,
                };
                k += n;
                items += 1;
            } else if let Some((v, width)) = self.quantity_number(k) {
                let mut k2 = k + width;
                // 小数：1.5 小时。
                let mut value = v as f64;
                if u.get(k2).is_some_and(|t| is_punct(t, ".") || is_punct(t, ",")) && u.get(k2 + 1).is_some_and(|t| t.kind == UKind::Number && !t.space_before) {
                    value += format!("0.{}", u[k2 + 1].text).parse::<f64>().ok()?;
                    k2 += 2;
                }
                // 「2-hour」「3-Stunden」：连字符黏着。
                if u.get(k2).is_some_and(|t| is_punct(t, "-") && !t.space_before) && u.get(k2 + 1).is_some_and(|t| !t.space_before && find(u, k2 + 1, |s| matches!(s, Sem::HourUnit | Sem::MinuteUnit)).is_some()) {
                    k2 += 1;
                }
                if let Some(n) = is(u, k2, |s| s == Sem::HourUnit) {
                    total += (value * 60.0).round() as i64;
                    k = k2 + n;
                    // 「1個半小時」「1時間半」：半跟在小时后面；「1h30」「2h15」：分钟黏在 h 后面。
                    if let Some(h) = is(u, k, |s| s == Sem::HalfAfter) {
                        total += 30;
                        k += h;
                    } else if u[k2].text == "h" && u.get(k).is_some_and(|m| m.kind == UKind::Number && !m.space_before && m.text.len() == 2) {
                        if let Some(m) = u[k].text.parse::<i64>().ok().filter(|m| *m <= 59) {
                            total += m;
                            k += 1;
                        }
                    }
                } else if let Some(n) = is(u, k2, |s| s == Sem::HourAndHalfUnit) {
                    // 「一个半小时」「1個半小時」。
                    total += (value * 60.0).round() as i64 + 30;
                    k = k2 + n;
                } else if let Some(n) = is(u, k2, |s| s == Sem::MinuteUnit || s == Sem::MinuteAfter) {
                    total += value.round() as i64;
                    k = k2 + n;
                } else {
                    break;
                }
                items += 1;
            } else {
                break;
            }
            if items >= 2 {
                break;
            }
            // 两项之间可以有「and / und / e / y / 又」。
            if let Some(n) = is(u, k, |s| s == Sem::And) {
                if u.get(k + n).is_some_and(|t| t.kind == UKind::Number) {
                    k += n;
                }
            }
        }
        (items > 0 && total > 0 && total <= 60 * 24 * 30).then_some((total, k - j))
    }

    /// 汉字数量先读完整的十位和个位，不能从「四十五」中单读「五」。
    fn quantity_number(&self, i: usize) -> Option<(u32, usize)> {
        if let Some(v) = self.u.get(i).and_then(number) {
            return Some((v, 1));
        }
        self.cjk_number(i).or_else(|| {
            let (n, Sem::Number(v), _) = find(self.u, i, |s| matches!(s, Sem::Number(_)))? else { return None; };
            Some((u32::from(v), n))
        })
    }

    /// 相对时间：「in 3 hours」「3 hours later」「三小时后」「3時間後」「через 2 часа」「3 saat sonra」「dalam 3 jam」
    /// 「in an hour」「半小时后」。
    fn relative(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        // 量在后：in / dans / tra / через / dalam + 量；往回的 vor / hace / il y a / há + 量。
        if let Some((n, sem, lang)) = find(u, i, |s| s == Sem::RelIn || s == Sem::RelAgoBefore) {
            if let Some((minutes, used)) = self.quantity(i + n) {
                let mut end = i + n + used;
                // 越南语方向词可同时出现在量的两侧。
                if lang == "vi" && sem == Sem::RelIn {
                    if let Some((suffix, Sem::RelLater, "vi")) = find(u, end, |s| s == Sem::RelLater) {
                        end += suffix;
                    }
                }
                // 「in 3 hours」后面紧跟 later / ago 的仍是相对时间；跟着 long / lang 的是时长（「in 2 Stunden lang」没人这么写，防一手）。
                if is(u, end, |s| s == Sem::DurationAfter).is_some() {
                    return None;
                }
                let sign = if sem == Sem::RelAgoBefore { -1 } else { 1 };
                self.push(Atom::Relative(sign * minutes), i, end, Some(lang));
                return Some(end - i);
            }
        }
        // 量在前：量 + later / 后 / sonra / nữa / lagi / ago。
        if let Some((minutes, used)) = self.quantity(i) {
            if let Some((n, sem, lang)) = find(u, i + used, |s| matches!(s, Sem::RelLater | Sem::RelAgo)) {
                let sign = if sem == Sem::RelAgo { -1 } else { 1 };
                self.push(Atom::Relative(sign * minutes), i, i + used + n, Some(lang));
                return Some(used + n);
            }
        }
        None
    }

    /// 以天计的相对日期：「in 2 days」「dans 2 jours」「через 2 дня」「sau 2 ngày」「dalam 2 hari」（线索 + 数 + 天），
    /// 「2 days later」「三天后」「3日後」「3일 후」「2 gün sonra」「2 ngày nữa」「2 hari lagi」（数 + 天 + 后）。
    /// 成一个日期原子（今天起第 N 天），钟点另认（旧版认「三天后早上七点」，新引擎丢了日期）。
    fn relative_days(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        let count_at = |j: usize| -> Option<(i64, usize)> {
            if let Some(v) = u.get(j).and_then(number) {
                return Some((v as i64, 1));
            }
            match find(u, j, |s| matches!(s, Sem::Number(_))) {
                Some((n, Sem::Number(v), _)) => Some((v as i64, n)),
                _ => None,
            }
        };
        let (days, end, lang) = if let Some((n, sem, lang)) = find(u, i, |s| s == Sem::RelIn || s == Sem::RelAgoBefore) {
            let (value, used) = count_at(i + n)?;
            let unit = is(u, i + n + used, |s| s == Sem::DayUnit)?;
            (if sem == Sem::RelAgoBefore { -value } else { value }, i + n + used + unit, lang)
        } else {
            let (value, used) = count_at(i)?;
            // 中文「三天」前面可以有「个」以外的量词？没有；「3 days」「3天」「3日」「3일」数字后直接跟天。
            let unit = is(u, i + used, |s| s == Sem::DayUnit)?;
            let (n, sem, lang) = find(u, i + used + unit, |s| matches!(s, Sem::RelLater | Sem::RelAgo))?;
            (if sem == Sem::RelAgo { -value } else { value }, i + used + unit + n, lang)
        };
        if days == 0 || days.abs() > 120 {
            return None;
        }
        self.push(Atom::Date(DateSpec::Offset { days: days as i8 }), i, end, Some(lang));
        Some(end - i)
    }

    /// 介词必须紧邻数字，小时单位与介词来自同一张语言表。
    fn clock_hour_context(&self, j: usize) -> bool {
        let u = self.u;
        let Some(width) = numeral_width(u, j) else { return false; };
        if j == 0 {
            return false;
        }
        let Some((_, _, lang)) = find(u, j + width, |s| s == Sem::HourUnit) else { return false; };
        find(u, j - 1, |s| s == Sem::ClockHourBefore).is_some_and(|(n, _, prefix_lang)| n == 1 && prefix_lang == lang)
    }

    /// 日期词后必须确实写了日期，几个小时与几天的数量不能组成钟点。
    fn vietnamese_written_date_after(&self, at: usize) -> bool {
        let Some((n, _, "vi")) = find(self.u, at, |s| s == Sem::DayBefore) else { return false; };
        let mut probe = Scanner { u: self.u, out: Vec::new() };
        probe.named_date(at).is_some() || probe.numeric_date(at + n).is_some()
    }

    /// 时长：「for 2 hours」「持续两小时」「dauert 2 Stunden」「2 Stunden lang」「2 saat sürecek」「2시간 동안」，
    /// 或光秃秃的量（「15:00, 2 hours」）：后者标成 `Quantity`，只在紧跟钟点时由装配层算成时长。
    fn duration(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        // 明确的钟点介词优先于同形小时单位的时长读法。
        if self.clock_hour_context(i) {
            return None;
        }
        if let Some((n, _, lang)) = find(u, i, |s| s == Sem::DurationBefore) {
            // 「for」也是普通介词（「for you」）：后面必须紧跟量。
            if let Some((minutes, used)) = self.quantity(i + n) {
                let mut end = i + n + used;
                // 明确的方向后缀优先，活动词不能吞掉相对时间。
                if is(u, end, |s| matches!(s, Sem::RelLater | Sem::RelAgo)).is_some() {
                    return None;
                }
                if let Some(a) = is(u, end, |s| s == Sem::DurationAfter) {
                    end += a;
                }
                self.push(Atom::Duration(minutes), i, end, Some(lang));
                return Some(end - i);
            }
            return None;
        }
        let (minutes, used) = self.quantity(i)?;
        // 「3 hours later」由相对时间先认到，这里只剩没有方向词的量。
        if let Some((n, _, lang)) = find(u, i + used, |s| s == Sem::DurationAfter) {
            self.push(Atom::Duration(minutes), i, i + used + n, Some(lang));
            return Some(used + n);
        }
        // 前面有钟点线索（「alle 3 Stunden」= 每三小时）不算量；单位同时也是钟点词（「3 giờ」「3 часа」「3 h」）的让钟点去认。
        if i > 0 && find(u, i - 1, |s| s == Sem::ClockBefore).is_some() {
            return None;
        }
        let clock_context_before = (i.saturating_sub(6)..i).any(|k| is(u, k, |s| s == Sem::ClockContextBefore).is_some_and(|n| k + n == i));
        // 同形单位只有在明确钟点语法里保留；更长的小时单位仍是量。
        let clock_unit = (i..i + used).find(|&k| {
            is(u, k, |s| s == Sem::ClockAfter).is_some_and(|clock_len| {
                is(u, k, |s| s == Sem::HourUnit || s == Sem::MinuteUnit).is_some_and(|unit_len| unit_len == clock_len)
            })
        });
        let period_after = (i + used..(i + used + 4).min(u.len())).any(|k| {
            find(u, k, |s| matches!(s, Sem::Period(_))).is_some()
                && u[i + used..k].iter().enumerate().all(|(n, _)| find(u, i + used + n, |s| matches!(s, Sem::Stop | Sem::From | Sem::Filler)).is_some())
        });
        let period_before = self.out.last().is_some_and(|a| matches!(a.atom, Atom::Period(_) | Atom::DatePeriod(..)) && a.to == i);
        let range_end = self.out.last().is_some_and(|a| matches!(a.atom, Atom::RangeSep) && a.to == i);
        let range_start = is(u, i + used, |s| s == Sem::RangeSep).is_some_and(|n| {
            self.hour_at(i + used + n).is_some_and(|(_, width, _)| {
                let end = i + used + n + width;
                is(u, end, |s| s == Sem::ClockAfter).is_some_and(|clock_len| {
                    !is(u, end, |s| s == Sem::HourUnit || s == Sem::MinuteUnit).is_some_and(|unit_len| unit_len > clock_len)
                })
            })
        });
        let shifted_tail = find(u, i + used, |s| matches!(s, Sem::BeforeMinutes(_) | Sem::AfterMinutes(_))).is_some()
            || is(u, i + used, |s| s == Sem::Minus || s == Sem::ClockContextAfter).is_some_and(|n| self.minutes_value(i + used + n).is_some_and(|(v, _)| (1..=59).contains(&v)));
        if clock_unit.is_some_and(|k| glued(u, k) || period_after || period_before || range_end || range_start || shifted_tail || clock_context_before
            || (u[k].text == "h" && u.get(k + 1).is_some_and(|m| m.kind == UKind::Number && m.text.len() == 2 && m.text.parse::<u8>().is_ok_and(|v| v <= 59)))
            || (self.hour_at(i).is_some() && find(u, k, |s| s == Sem::ClockAfter).is_some_and(|(_, _, l)| l == "vi")
                && u.get(k + 1).is_some_and(|m| m.kind == UKind::Number && m.text.len() == 2)
                && self.vietnamese_written_date_after(k + 2))) {
            return None;
        }
        self.push(Atom::Quantity(minutes), i, i + used, None);
        Some(used)
    }

    /// 数词钟点（三 / three / drei / trzeciej / üç）：（钟点值，吃掉的单元数）。
    fn hour_word(&self, j: usize) -> Option<(u8, usize, &'static str)> {
        let (n, sem, lang) = find(self.u, j, |s| matches!(s, Sem::Number(0..=12)))?;
        let Sem::Number(h) = sem else { return None };
        if lang == "ko" && j > 0 && glued(self.u, j)
            && self.u[j - 1].raw.chars().any(super::text::is_hangul) {
            return None;
        }
        let lang = super::language::supported_language(self.u, j, n, sem, None)?;
        Some((h, n, lang))
    }

    /// 钟点的小时部分：数字（≤ 2 位、≤ 24）或数词。返回（小时，吃掉的单元数，语言）。
    fn hour_at(&self, j: usize) -> Option<(u32, usize, Option<&'static str>)> {
        let u = self.u;
        let t = u.get(j)?;
        if let Some(h) = number(t) {
            return (t.text.len() <= 2 && h <= 24).then_some((h, 1, None));
        }
        // 汉字小时按完整数词读取，不能把「十三点」拆成「三点」。
        if let Some((h, n)) = self.cjk_number(j).filter(|(h, _)| *h <= 24) {
            if let Some((_, _, lang)) = find(u, j + n, |s| s == Sem::ClockAfter) {
                return Some((h, n, Some(lang)));
            }
        }
        self.hour_word(j).map(|(h, n, lang)| (h as u32, n, Some(lang)))
    }

    /// 土耳其语带格的钟点数词（üçü / dörde）：（小时，吃掉的单元数，格）。
    fn turkish_cased_hour(&self, j: usize) -> Option<(u32, usize, Sem)> {
        let (n, sem, _) = find(self.u, j, |s| matches!(s, Sem::TrAcc(_) | Sem::TrDat(_)))?;
        match sem {
            Sem::TrAcc(h) | Sem::TrDat(h) => Some((h as u32, n, sem)),
            _ => None,
        }
    }

    /// 正午和午夜可带分钟词；正午词与明写的十二点合成一个钟点。
    fn named_clock(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        let cue = is(u, i, |s| s == Sem::ClockBefore).unwrap_or(0);
        let j = i + cue;
        // 截止短语先按整体认，不能把里面的中午或午夜抢成独立钟点。
        if find(u, i, |s| matches!(s, Sem::Idiom(_))).is_some() || find(u, j, |s| matches!(s, Sem::Idiom(_))).is_some() { return None; }
        let (n, sem, lang) = find(u, j, |s| matches!(s, Sem::Noon | Sem::Midnight))?;
        let mut end = j + n;
        let mut clock = if sem == Sem::Noon { Clock::at(12, 0) }
            else { Clock { hour: 0, minute: 0, second: 0, day_offset: 1 } };
        if sem == Sem::Noon && u.get(end).and_then(number) == Some(12) {
            end += 1;
            if let Some((m, s, used)) = self.minutes_after(end, false) {
                clock.minute = m;
                clock.second = s;
                end += used;
            }
            if u.get(end).is_some_and(|t| is_punct(t, "'") && !t.space_before)
                && u.get(end + 1).is_some_and(|t| !t.space_before && matches!(t.text.as_str(), "de" | "da" | "te" | "ta")) {
                end += 2;
            }
        }
        if let Some(n) = is(u, end, |s| s == Sem::HalfAfter) {
            clock.minute = 30;
            end += n;
        } else if let Some((n, Sem::AfterMinutes(m), _)) = find(u, end, |s| matches!(s, Sem::AfterMinutes(_))) {
            clock.minute = m;
            end += n;
        } else {
            let minus = find(u, end, |s| matches!(s, Sem::BeforeMinutes(_) | Sem::Minus));
            if let Some((n, modifier, _)) = minus {
                let minutes = match modifier {
                    Sem::BeforeMinutes(m) => Some((u32::from(m), 0)),
                    _ => self.minutes_value(end + n),
                };
                if let Some((m, used)) = minutes.filter(|(m, _)| (1..=59).contains(m)) {
                    clock.hour = (clock.hour + 23) % 24;
                    clock.minute = (60 - m) as u8;
                    clock.day_offset = 0;
                    end += n + used;
                }
            }
        }
        self.push(Atom::Clock { clock, period: None, explicit: true }, i, end, Some(lang));
        Some(end - i)
    }

    /// 钟点。
    fn clock(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        if let Some(n) = self.named_clock(i) { return Some(n); }
        // 整个词就是钟点（俄语 полтретьего）。
        if let Some((n, Sem::FixedClock(h, m), lang)) = find(u, i, |s| matches!(s, Sem::FixedClock(..))) {
            self.push(Atom::Clock { clock: Clock::at(h, m), period: None, explicit: true }, i, i + n, Some(lang));
            return Some(n);
        }
        // 前置线索（at / um / alle / om / pukul / lúc / saat / a las / в / o）。
        let cue_len = match find(u, i, |s| s == Sem::ClockBefore) {
            Some((n, _, _)) => n,
            None => 0,
        };
        let cue_lang = if cue_len > 0 { find(u, i, |s| s == Sem::ClockBefore).map(|(_, _, l)| l) } else { None };
        let j = i + cue_len;
        if j >= u.len() {
            return None;
        }
        // 日期前的介词不能抢走斜线日期的第一个数字。
        if cue_len > 0 && u.get(j + 1).is_some_and(|t| is_punct(t, "/") && !t.space_before) {
            if let Some(n) = self.numeric_date(j) {
                return Some(cue_len + n);
            }
        }
        // H:MM(:SS) 的形状、数不成立（25:61、10:20:99）：说出来，不丢掉秒或整段。24:xx 照旧是次日。
        if let Some(n) = self.invalid_clock_shape(i, j) {
            return Some(n);
        }
        if let Some((hour, minute)) = hyphen_clock_shape(u, j) {
            if hour > 24 || minute > 59 {
                self.push(Atom::Invalid("invalidTime"), j, j + 3, cue_lang);
                return Some(j + 3 - i);
            }
        }
        // 整点前后的偏移词在小时前：quarter past 3 / viertel vor 4 / halb 4 / wpół do 4 / без четверти 4 / четверть третьего。
        if let Some(n) = self.shifted_clock(i, j, cue_lang) {
            return Some(n);
        }
        // 分钟在前：ten to four / 10 vor 4 / 10 over 3 / za dziesięć czwarta / без десяти четыре。
        if let Some(n) = self.minutes_first_clock(i, j, cue_lang) {
            return Some(n);
        }
        let mut tr_case: Option<Sem> = None;
        let (hour, hour_len, word_lang) = match self.hour_at(j) {
            Some(h) => h,
            None => {
                // 「üçü on geçe」「dörde çeyrek kala」：带格的数词。
                let (h, n, case) = self.turkish_cased_hour(j)?;
                tr_case = Some(case);
                (h, n, Some("tr"))
            }
        };
        let hour_is_word = u[j].kind != UKind::Number;
        let mut end = j + hour_len;
        let mut minute = 0u8;
        let mut second = 0u8;
        let mut explicit = tr_case.is_some();
        let mut lang = cue_lang.or(word_lang);
        let mut korean_clock = word_lang == Some("ko");
        // 数词钟点要有前置线索、后置钟点词或分钟词（「three o'clock」「a las tres」「三点」「üç buçuk」），光秃秃的数词不算。
        if hour_is_word && cue_len == 0 && tr_case.is_none()
            && find(u, end, |s| matches!(s, Sem::ClockAfter | Sem::HalfAfter | Sem::AfterMinutes(_) | Sem::BeforeMinutes(_) | Sem::Minus)).is_none()
        {
            return None;
        }
        // 土耳其语数字后的格后缀：15'te / 3'ü / 4'e（撇号 + 后缀词）。
        if !hour_is_word && u.get(end).is_some_and(|t| is_punct(t, "'") && !t.space_before) {
            if let Some(suffix) = u.get(end + 1).filter(|t| t.kind == UKind::Word && !t.space_before) {
                let case = match suffix.text.as_str() {
                    "u" | "ü" | "i" | "ı" | "yi" | "yı" | "yu" | "yü" => Some(Sem::TrAcc(hour as u8)),
                    "e" | "a" | "ye" | "ya" => Some(Sem::TrDat(hour as u8)),
                    "te" | "de" | "ta" | "da" => Some(Sem::Stop),
                    _ => None,
                };
                if let Some(case) = case {
                    tr_case = Some(case);
                    end += 2;
                    explicit = true;
                    lang = lang.or(Some("tr"));
                }
            }
        }
        // H:MM、H:MM:SS、15h30、15.30（有线索、分钟 ≥ 13 或 09.00 这种月份不合法的）。
        let dotted_ok = !hour_is_word
            && (dotted_clock_context(u, j) || cue_len > 0
                || u.get(j + 3).is_some_and(|t| find(u, j + 3, |s| matches!(s, Sem::ClockAfter | Sem::Period(Period::Am | Period::Pm))).is_some() && t.kind != UKind::Number)
                || u.get(j + 2).is_some_and(|m| m.kind == UKind::Number && m.text.len() == 2 && !m.space_before && is_punct(&u[j + 1], ".") && !u[j + 1].space_before && m.text.parse::<u8>().ok().is_some_and(|v| v >= 13 || (v == 0 && u[j].text.starts_with('0')))));
        if tr_case.is_none() {
            if let Some((m, s, used)) = self.minutes_after(end, dotted_ok)
                .or_else(|| hyphen_clock_shape(u, j).map(|(_, m)| (m as u8, 0, 2))) {
                minute = m;
                second = s;
                end += used;
                explicit = true;
            }
        }
        // 数字后的钟点词：o'clock / Uhr / uur / 点 / 時 / 시 / giờ / h / hs / ч。
        // 钟点词正好是时区整词的开头（「9:00 heure de l'est」「9:00 heure du Pacifique」）时留给时区词。
        let starts_zone_word = matcher().zone_words.get(u.get(end).map_or("", |t| t.text.as_str())).is_some_and(|list| {
            list.iter().any(|(phrase, _)| end + phrase.len() <= u.len() && phrase.len() > 1 && (0..phrase.len()).all(|k| u[end + k].text == phrase[k]))
        });
        // 钟点词正好是更长的时长词的开头（韩「5시간」、日「2時間」：시 / 時 后面紧跟 간 / 間）：那是几个小时，不是几点
        // （「(최대 5시간)」读成了 5:00）。
        let longer_unit = |n: usize| is(u, end, |s| matches!(s, Sem::HourUnit | Sem::MinuteUnit)).is_some_and(|m| m > n);
        let clock_suffix = find(u, end, |s| s == Sem::ClockAfter).or_else(|| {
            if self.clock_hour_context(j) { find(u, end, |s| s == Sem::HourUnit) } else { None }
        });
        if let Some((n, _, l)) = clock_suffix.filter(|(n, _, _)| !starts_zone_word && !longer_unit(*n)
            && find(u, end, |s| matches!(s, Sem::LocalZone | Sem::ZoneBefore)).is_none_or(|(long, _, _)| long <= *n)) {
            // 「h」「g」「ч」只在紧跟数字时算（「3 h」是三小时）。已写了分钟的钟点（21:55）后面隔着空格的单字
            // 시 / 時 / 点同理不算：「21:55 시드니 시간」的시是地名的头一个字。
            let minutes_written = u[j + hour_len..end].iter().any(|t| t.kind == UKind::Number);
            let single = u[end].text.chars().count() == 1 && (u[end].kind == UKind::Word || (u[end].kind == UKind::Cjk && minutes_written));
            // 法语排版里 h 两边留空格（「9 h 30」）：后面跟两位分钟时也算。
            let spaced_h = u[end].text == "h"
                && u.get(end + 1).is_some_and(|m| m.kind == UKind::Number && m.text.len() == 2 && m.text.parse::<u8>().is_ok_and(|v| v <= 59));
            if !single || glued(u, end) || spaced_h {
                korean_clock |= l == "ko";
                end += n;
                explicit = true;
                lang = lang.or(Some(l));
                // 15h30、15 Uhr 30、3点15分、3시 30분、15 giờ 30 phút。
                // 俄语小时词后紧邻「日数 + 月名」时，日数留给日期，即使没有空格。
                let date_follows = l == "ru" && find(u, end + 1, |s| matches!(s, Sem::Month(_))).is_some_and(|(_, _, lang)| lang == l);
                if let Some(m) = u.get(end).filter(|t| t.kind == UKind::Number && t.text.len() <= 2 && !date_follows) {
                    let value: u8 = m.text.parse().ok()?;
                    // 越南语日期前的两位裸分钟属于钟点，已经写过分钟时不能再读一次。
                    let bare_vi_minute = l == "vi" && !minutes_written && m.text.len() == 2
                        && self.vietnamese_written_date_after(end + 1);
                    // 「3時70分」「3시 70분」：分钟不成立，说出来（此前 70 分被当成时长）。
                    if value > 59 && minute == 0 {
                        if let Some(after) = is(u, end + 1, |s| s == Sem::MinuteAfter || s == Sem::MinuteUnit) {
                            self.push(Atom::Invalid("invalidTime"), j, end + 1 + after, lang);
                            return Some(end + 1 + after - i);
                        }
                        if bare_vi_minute {
                            self.push(Atom::Invalid("invalidTime"), j, end + 1, lang);
                            return Some(end + 1 - i);
                        }
                    }
                    if value <= 59 && minute == 0 {
                        let after = is(u, end + 1, |s| s == Sem::MinuteAfter || s == Sem::MinuteUnit).unwrap_or(0);
                        // 「9 Uhr 30」「15h30」「9 h 30」「5 часов 30」接受；「3点 15」（后面没有分）只在紧贴时接受。
                        if after > 0 || glued(u, end) || u[end - 1].text == "uhr" || u[end - 1].text == "h" || matches!(l, "fr" | "ru") || bare_vi_minute {
                            minute = value;
                            end += 1 + after;
                        }
                    }
                } else if minute == 0 && !date_follows {
                    // 汉字写的分钟：「十一点四十五分」「三点二十」（两位以上或带「分」；此前丢了分钟）。
                    if let Some((value, used)) = self.cjk_number(end).or_else(|| self.minutes_value(end)) {
                        let after = is(u, end + used, |s| s == Sem::MinuteAfter || s == Sem::MinuteUnit).unwrap_or(0);
                        if (1..=59).contains(&value) && (after > 0 || value >= 10) {
                            minute = value as u8;
                            end += used + after;
                        }
                    }
                }
            }
        }
        // 钟点后面的分钟词：半 / 一刻 / y cuarto / et quart（加）、menos cuarto / meno un quarto / moins le quart（减）、
        // 4 menos 10 / 4 heures moins vingt（减 M 分）。有前置线索、钟点词或数词钟点时才算（「3 cats e mezza」不算）。
        if minute == 0 && (cue_len > 0 || explicit || hour_is_word) {
            // 中文「七点过十分」的分钟属于前面的钟点，单位或「一刻」必须明写。
            let past_minutes = find(u, end, |s| s == Sem::Past)
                .filter(|(_, _, l)| *l == "zh")
                .and_then(|(n, _, _)| self.cjk_clock_minutes(end + n).map(|(m, used)| (m, n + used)));
            if let Some((m, used)) = past_minutes {
                minute = m as u8;
                end += used;
                explicit = true;
            } else if let Some(h) = is(u, end, |s| s == Sem::HalfAfter) {
                minute = 30;
                end += h;
                explicit = true;
            } else if let Some((n2, Sem::AfterMinutes(v), _)) = find(u, end, |s| matches!(s, Sem::AfterMinutes(_))) {
                minute = v;
                end += n2;
                explicit = true;
            } else if let Some((n2, Sem::BeforeMinutes(v), _)) = find(u, end, |s| matches!(s, Sem::BeforeMinutes(_))) {
                if (1..=24).contains(&hour) {
                    let (h, off) = previous_hour(hour as u8);
                    self.push(Atom::Clock { clock: Clock { hour: h, minute: 60 - v, second: 0, day_offset: off }, period: None, explicit: true }, i, end + n2, lang);
                    return Some(end + n2 - i);
                }
            } else if let Some((n2, _, _)) = find(u, end, |s| s == Sem::Minus || s == Sem::ClockContextAfter) {
                if let Some((m, mn)) = self.minutes_value(end + n2) {
                    if (1..=24).contains(&hour) && (1..=59).contains(&m) {
                        let (h, off) = previous_hour(hour as u8);
                        self.push(Atom::Clock { clock: Clock { hour: h, minute: (60 - m) as u8, second: 0, day_offset: off }, period: None, explicit: true }, i, end + n2 + mn, lang);
                        return Some(end + n2 + mn - i);
                    }
                }
            }
        }
        // 两个数词按本语言的分钟语法合成钟点，不拆开重读。
        if minute == 0 && hour_is_word {
            let linker = if word_lang == Some("it") && u.get(end).is_some_and(|t| t.text == "e") { 1 } else { 0 };
            if linker > 0 || word_lang == Some("en") {
                if let Some((m, n)) = self.minutes_value(end + linker).filter(|(m, _)| (1..=59).contains(m)) {
                    minute = m as u8;
                    end += linker + n;
                    explicit = true;
                }
            }
        }
        // 日语「3時10分前」的前指整点前十分钟。
        if minute > 0 && lang == Some("ja") && u.get(end).is_some_and(|t| t.text == "前" && !t.space_before) {
            let (h, off) = previous_hour(hour as u8);
            self.push(Atom::Clock { clock: Clock { hour: h, minute: 60 - minute, second: 0, day_offset: off }, period: None, explicit: true }, i, end + 1, lang);
            return Some(end + 1 - i);
        }
        // 「12 del mediodía」中的正午是同一个钟点的说明。
        if hour == 12 {
            if let Some((n, _, l)) = find(u, end, |s| s == Sem::Noon) {
                end += n;
                explicit = true;
                lang = Some(l);
            }
        }
        // 土耳其语「üçü on geçe」「4'e çeyrek kala」：带格的钟点 + 分钟 + geçe / kala。
        if let Some(case) = tr_case.filter(|c| matches!(c, Sem::TrAcc(_) | Sem::TrDat(_))) {
            if let Some((clock, n2)) = self.turkish_tail(hour as u8, case, end) {
                self.push(Atom::Clock { clock, period: None, explicit: true }, i, end + n2, Some("tr"));
                return Some(end + n2 - i);
            }
        }
        // am / pm 紧跟（3pm、3 pm、3:30 p.m.）。
        let mut period = None;
        if let Some((n, Sem::Period(p @ (Period::Am | Period::Pm)), l)) = find(u, end, |s| matches!(s, Sem::Period(Period::Am | Period::Pm))) {
            // 「0am」「0pm」：十二小时制没有 0 点（旧版判不成立）。
            if hour == 0 && !hour_is_word {
                self.push(Atom::Invalid("invalidTime"), j, end + n, lang.or(Some(l)));
                return Some(end + n - i);
            }
            if hour <= 12 {
                period = Some(p);
                end += n;
                explicit = true;
                lang = lang.or(Some(l));
            }
        }
        // 光秃秃的数字：只有前置线索或跟着时段词才算钟点（「3 cats」不算、「at 3」算）。例外是时间段的一端
        // （「1pm–3」「1–3pm」）：另一端是带上下午的钟点、中间只隔一个区间符号时，这个数也是钟点，上下午由装配层
        // 跟另一端走（旧版读成 13:00–15:00，新引擎丢了一端）。
        // 光秃秃的数字后面紧跟时段词（「3 in the afternoon」「3 da madrugada」「3 de la tarde」）也是钟点，时段由装配层套上
        // （注释一直这么写，实现却只认 am / pm）。
        if !explicit && cue_len == 0 && !hour_is_word && (1..=12).contains(&hour) && find(u, end, |s| matches!(s, Sem::Period(_))).is_some() {
            explicit = true;
        }
        // 不带重音的「a」只是法语「à」折叠后的样子：西语、意语里「a 12」多半是数量（「de 9 a 12 años」），光秃秃的数字不算钟点
        // （西语的钟点线索是「a las」，法语不写重音时也带 h：「a 15h」）。
        if !explicit && cue_len == 1 && u[i].raw.to_lowercase() == "a" {
            return None;
        }
        let zone_hour = u.get(end).is_some_and(|t| t.upper && matches!(t.text.as_str(), "utc" | "gmt"));
        if !explicit && cue_len == 0 && !zone_hour {
            let after_range_start = self.out.len() >= 2
                && matches!(self.out[self.out.len() - 1].atom, Atom::RangeSep)
                && self.out[self.out.len() - 1].to == i
                && matches!(self.out[self.out.len() - 2].atom, Atom::Clock { period: Some(_), .. })
                && self.plausible_after_bare_end(end);
            // 「od 9 do 17」：起点是波兰语 od 带出的光秃秃数字，终点的光秃秃数字也当钟点（可以大于 12）。
            let from_cued_range_end = self.out.len() >= 3
                && matches!(self.out[self.out.len() - 1].atom, Atom::RangeSep)
                && self.out[self.out.len() - 1].to == i
                && matches!(self.out[self.out.len() - 2].atom, Atom::Clock { .. })
                && self.out[..self.out.len() - 2]
                    .iter()
                    .any(|l| matches!(l.atom, Atom::From) && matches!(l.lang, Some("pl" | "en")) && l.to == self.out[self.out.len() - 2].from)
                && self.plausible_after_bare_end(end);
            // 意「dalle」、葡「das」、波「od」本身就带着「几点」：后面跟着区间词与另一端时，这个数是钟点
            // （「dalle 9 alle 12」「od 9 do 17」）。
            let hours_from = i > 0
                && find(u, i - 1, |s| s == Sem::From).is_some_and(|(n, _, l)| n == 1 && matches!(l, "it" | "pt" | "pl" | "de" | "ru" | "en")
                    && self.range_end_number(end).is_some_and(|k| l != "en" || u[end..k].iter().any(|t| is_punct(t, ":"))
                        || self.plausible_after_bare_end(k) || find(u, k, |s| s == Sem::ClockAfter).is_some()));
            if hour_is_word || !(after_range_start || from_cued_range_end || hours_from || self.range_end_has_period(end)) {
                return None;
            }
        }
        // 前置线索 + 数字 + 时间单位（「alle 3 Stunden」）：那是时长，不是钟点。
        if !explicit && is(u, end, |s| matches!(s, Sem::HourUnit | Sem::MinuteUnit)).is_some() {
            return None;
        }
        if is(u, end, |s| matches!(s, Sem::RelLater | Sem::RelAgo)).is_some() && minute == 0 && !explicit {
            return None;
        }
        // 谚文词内不能截出钟点，完整钟点后可带助词；拒绝发生在修改先前的装配单元之前。
        if korean_clock {
            let mut tail = end;
            while u.get(tail).is_some_and(|t| !t.space_before && t.raw.chars().all(super::text::is_hangul)) {
                tail += 1;
            }
            let suffix: String = u[end..tail].iter().map(|t| t.raw.as_str()).collect();
            if !super::language::korean_clock_particle(&suffix)
                && !super::targets::korean_question_after_clock(u, end, tail) {
                return None;
            }
        }
        let (hour, mut day_offset) = if hour == 24 { (0, 1) } else { (hour as u8, 0) };
        if hour > 23 {
            return None;
        }
        // 时间段的后一端自己带着上下午（「午前2時～午前4時」「오전 9시~오후 6시」）：把紧挨着的时段词并进这个钟点，
        // 装配才认得出「钟点、区间符号、钟点」（此前后一端自成一处）。
        let mut start = i;
        let n = self.out.len();
        // 区间终点前的次日词并入终点；单独一句的次日词仍按前一处日期算。
        if n >= 3 && self.out[n - 1].to == i && self.out[n - 2].to == self.out[n - 1].from
            && matches!(self.out[n - 2].atom, Atom::RangeSep)
            && matches!(self.out[n - 3].atom, Atom::Clock { .. } | Atom::DotPair { .. })
        {
            if let Atom::NextDay(p) = self.out[n - 1].atom {
                day_offset = 1;
                period = period.or(p);
                start = self.out[n - 1].from;
                self.out.pop();
            }
        }
        let n = self.out.len();
        if period.is_none() && cue_len == 0 && n >= 2 && self.out[n - 1].to == i && self.out[n - 2].to == self.out[n - 1].from {
            if let (Atom::Period(p), Atom::RangeSep) = (&self.out[n - 1].atom, &self.out[n - 2].atom) {
                period = Some(*p);
                start = self.out[n - 1].from;
                self.out.pop();
            }
        }
        // 韩语时段前缀跟紧随的钟点绑定；不可见排版字符不把它们拆开。
        if period.is_none() && cue_len == 0 && hour <= 12 {
            if let Some(last) = self.out.last().filter(|a| a.lang == Some("ko") && a.to <= i
                && u[a.to..i].iter().all(|t| t.raw.chars().all(|c| matches!(c, '\u{200b}' | '\u{200c}' | '\u{200d}' | '\u{feff}')))) {
                if let Atom::Period(p) = last.atom {
                    period = Some(p);
                    start = last.from;
                    self.out.pop();
                }
            }
        }
        // 「4時～翌2時」：终点钟点前的「翌 / 翌日」并进这个钟点——终点在第二天，即使比起点晚。
        if let Some(sep) = self.out.last().filter(|l| cue_len == 0 && matches!(l.atom, Atom::RangeSep) && l.to <= j) {
            let before: String = u[sep.to..j].iter().map(|t| t.text.as_str()).collect();
            if before == "翌" || before == "翌日" {
                day_offset = 1;
                start = start.min(sep.to);
            }
        }
        let clock = Atom::Clock { clock: Clock { hour, minute, second, day_offset }, period, explicit };
        // 线索词同时是区间词（西「a」、葡「às」、法「à」、意「alle」），又紧跟在一个钟点后面：那是时间段的「到」
        // （「De 10:00 a 12:00 hrs」「das 9h às 18h」「de 22h à 6h」，此前后一端自成一处）。
        let range_cue = cue_len > 0
            && self.out.last().is_some_and(|p| p.to == i && matches!(p.atom, Atom::Clock { .. } | Atom::DotPair { .. }))
            && find(u, i, |s| s == Sem::RangeSep).is_some_and(|(n, _, _)| n == cue_len);
        if range_cue {
            self.push(Atom::RangeSep, i, j, cue_lang);
            self.push(clock, j, end, lang);
        } else {
            self.push(clock, start, end, lang);
        }
        Some(end - i)
    }

    /// `j` 处是「H:MM」或「H:MM:SS」的形状（数字、紧贴的冒号、两位数），数却不成立：记成 invalidTime，返回吃掉的单元数。
    fn invalid_clock_shape(&mut self, i: usize, j: usize) -> Option<usize> {
        let u = self.u;
        let h = u.get(j).filter(|t| t.kind == UKind::Number && t.text.len() <= 2)?;
        let spaced_colon = cjk_colon_spaces(u, j + 1);
        u.get(j + 1).filter(|c| is_punct(c, ":") && (!c.space_before || spaced_colon))?;
        let m = u.get(j + 2).filter(|t| t.kind == UKind::Number && t.text.len() == 2 && (!t.space_before || spaced_colon))?;
        let hour: u32 = h.text.parse().ok()?;
        let minute: u32 = m.text.parse().ok()?;
        let mut end = j + 3;
        let mut second = 0u32;
        if u.get(end).is_some_and(|c| is_punct(c, ":") && !c.space_before) {
            if let Some(s) = u.get(end + 1).filter(|t| t.kind == UKind::Number && t.text.len() == 2 && !t.space_before) {
                second = s.text.parse().ok()?;
                end += 2;
            }
        }
        // 秒只写一位（「9:00:0」）或多一段（「9:00:00:00」）：形状坏了。
        let mut malformed = false;
        if u.get(end).is_some_and(|c| is_punct(c, ":") && !c.space_before) && u.get(end + 1).is_some_and(|t| t.kind == UKind::Number && !t.space_before) {
            malformed = true;
            end += 2;
        }
        if hour <= 24 && minute <= 59 && second <= 59 && !malformed {
            return None;
        }
        self.push(Atom::Invalid("invalidTime"), j, end, None);
        Some(end - i)
    }

    /// 时间段的另一端带上下午或钟点词：`k` 处是区间符号（「-」「–」「to」「bis」「à」），后面是「数字[:MM] am/pm」或
    /// 「数字[:MM] Uhr / uur / h / часов」（「von 9 bis 12 Uhr」「9-12h」，此前前一端丢了）。单个字母的
    /// 钟点词（h、g、ч）要紧贴数字，「3 h」是三小时。
    fn range_end_has_period(&self, k: usize) -> bool {
        let u = self.u;
        let Some(j) = self.range_end_number(k) else {
            return false;
        };
        if find(u, j, |s| matches!(s, Sem::Period(Period::Am | Period::Pm))).is_some() {
            return true;
        }
        find(u, j, |s| s == Sem::ClockAfter).is_some() && (u[j].text.chars().count() > 1 || u[j].kind != UKind::Word || glued(u, j))
    }

    /// `k` 处是区间符号，后面跟着「数字[:MM]」：返回数字（与分钟）之后的位置。
    fn range_end_number(&self, k: usize) -> Option<usize> {
        let u = self.u;
        let sep_len = if u.get(k).is_some_and(|t| is_punct(t, "-")) {
            1
        } else {
            find(u, k, |s| s == Sem::RangeSep)?.0
        };
        let mut j = k + sep_len;
        if !u.get(j).is_some_and(|t| t.kind == UKind::Number && t.text.len() <= 2) {
            return None;
        }
        j += 1;
        if u.get(j).is_some_and(|c| is_punct(c, ":") && !c.space_before) && u.get(j + 1).is_some_and(|m| m.kind == UKind::Number && m.text.len() == 2) {
            j += 2;
        }
        Some(j)
    }

    /// 时间段光秃秃的终点后面接的是标点、句末、大写词（地名、时区）或中日韩字，才像终点（「1pm - 3 people」不是）。
    fn plausible_after_bare_end(&self, k: usize) -> bool {
        match self.u.get(k) {
            None => true,
            Some(t) => (t.text == "on" && self.u.get(k + 1).is_some_and(|u| u.text == "weekdays"))
                || t.kind == UKind::Punct || t.kind == UKind::Cjk || t.capital || t.upper
                || find(self.u, k, |s| matches!(s, Sem::RelDay(_) | Sem::RelDayPeriod(..) | Sem::Period(_))).is_some(),
        }
    }

    /// 分钟的值：数字（1–59）或数词（five / zehn / dwadzieścia / десяти）。
    fn minutes_value(&self, j: usize) -> Option<(u32, usize)> {
        let u = self.u;
        let t = u.get(j)?;
        if let Some(v) = number(t) {
            return (t.text.len() <= 2 && (1..=59).contains(&v)).then_some((v, 1));
        }
        let (n, sem, _) = find(u, j, |s| matches!(s, Sem::Number(_)))?;
        let Sem::Number(v) = sem else { return None };
        Some((v as u32, n))
    }

    /// 中文偏移分钟必须带分钟单位或完整的刻钟词，不能只取数词的一部分。
    fn cjk_clock_minutes(&self, j: usize) -> Option<(u32, usize)> {
        let u = self.u;
        if let Some((n, Sem::AfterMinutes(m), "zh")) = find(u, j, |s| matches!(s, Sem::AfterMinutes(_))) {
            return Some((u32::from(m), n));
        }
        let (m, used) = self.cjk_number(j).or_else(|| self.minutes_value(j))?;
        if !(1..=59).contains(&m) { return None; }
        let unit = is(u, j + used, |s| s == Sem::MinuteAfter || s == Sem::MinuteUnit)?;
        Some((m, used + unit))
    }

    /// 「quarter past 3」「viertel vor 4」「halb 4」「wpół do 4」「setengah 4」「без четверти 4」「четверть третьего」「половина третьего」。
    /// 每一种都要求后面真有钟点，没有就当没匹配（「half」也是荷兰语的整点前半小时词、「пол」也是别的词的开头）。
    fn shifted_clock(&mut self, i: usize, j: usize, cue_lang: Option<&'static str>) -> Option<usize> {
        let u = self.u;
        let with_after = |end: usize| -> usize { end + is(u, end, |s| s == Sem::ClockAfter).unwrap_or(0) };
        // 中文「差十分四点」以明写的整点为终点，分钟与整点单位缺一不可。
        if let Some((n, _, "zh")) = find(u, j, |s| s == Sem::Minus) {
            let (m, mn) = self.cjk_clock_minutes(j + n)?;
            let (h, hn, _) = self.hour_at(j + n + mn)?;
            let (suffix, _, "zh") = find(u, j + n + mn + hn, |s| s == Sem::ClockAfter)? else { return None };
            if h > 24 { return None; }
            let (hour, off) = previous_hour(h as u8);
            let end = j + n + mn + hn + suffix;
            self.push(Atom::Clock { clock: Clock { hour, minute: (60 - m) as u8, second: 0, day_offset: off }, period: None, explicit: true }, i, end, Some("zh"));
            return Some(end - i);
        }
        // quarter past 3 / viertel vor 4 / kwart over 3 / half past 3 / dreiviertel 4 / четверть третьего / половина третьего。
        if let Some((n, Sem::ClockShift(shift), lang)) = find(u, j, |s| matches!(s, Sem::ClockShift(_))) {
            if let Some((on, Sem::HourOrdinal(o), _)) = find(u, j + n, |s| matches!(s, Sem::HourOrdinal(_))) {
                // 俄语序数属格：钟点 = 序数 − 1。
                let (hour, off) = previous_hour(o);
                let clock = Clock { hour, minute: shift.unsigned_abs(), second: 0, day_offset: off };
                self.push(Atom::Clock { clock, period: None, explicit: true }, i, j + n + on, cue_lang.or(Some(lang)));
                return Some(j + n + on - i);
            }
            if lang != "ru" {
                if let Some((h, hn, _)) = self.hour_at(j + n).filter(|(h, _, _)| (1..=24).contains(h)) {
                    let end = with_after(j + n + hn);
                    let clock = if shift >= 0 {
                        Clock::at(if h == 24 { 0 } else { h as u8 }, shift as u8)
                    } else {
                        let (hour, off) = previous_hour(h as u8);
                        Clock { hour, minute: (60 - shift.unsigned_abs() as i16) as u8, second: 0, day_offset: off }
                    };
                    self.push(Atom::Clock { clock, period: None, explicit: true }, i, end, cue_lang.or(Some(lang)));
                    return Some(end - i);
                }
            }
        }
        // halb 4 / half 4 / wpół do 4 / setengah 4 = 3:30。
        if let Some((n, _, lang)) = find(u, j, |s| s == Sem::HalfBefore) {
            if let Some((h, hn, _)) = self.hour_at(j + n).filter(|(h, _, _)| (1..=12).contains(h)) {
                let end = with_after(j + n + hn);
                let (hour, off) = previous_hour(h as u8);
                self.push(Atom::Clock { clock: Clock { hour, minute: 30, second: 0, day_offset: off }, period: None, explicit: true }, i, end, cue_lang.or(Some(lang)));
                return Some(end - i);
            }
        }
        // 「без четверти четыре」= 3:45；「без десяти четыре」= 3:50。
        if let Some((n, Sem::BeforeMinutes(v), lang)) = find(u, j, |s| matches!(s, Sem::BeforeMinutes(_))) {
            if lang == "ru" {
                if let Some((h, hn, _)) = self.hour_at(j + n).filter(|(h, _, _)| (1..=24).contains(h)) {
                    let (hour, off) = previous_hour(h as u8);
                    self.push(Atom::Clock { clock: Clock { hour, minute: 60 - v, second: 0, day_offset: off }, period: None, explicit: true }, i, j + n + hn, Some("ru"));
                    return Some(j + n + hn - i);
                }
            }
        }
        if let Some((n, _, lang)) = find(u, j, |s| s == Sem::Minus) {
            if lang == "ru" {
                if let Some((m, mn)) = self.minutes_value(j + n).filter(|(m, _)| (1..=59).contains(m)) {
                    if let Some((h, hn, _)) = self.hour_at(j + n + mn).filter(|(h, _, _)| (1..=24).contains(h)) {
                        let (hour, off) = previous_hour(h as u8);
                        self.push(Atom::Clock { clock: Clock { hour, minute: (60 - m) as u8, second: 0, day_offset: off }, period: None, explicit: true }, i, j + n + mn + hn, Some("ru"));
                        return Some(j + n + mn + hn - i);
                    }
                }
            }
        }
        None
    }

    /// 「ten to four」「twenty past three」「10 vor 4」「10 nach 3」「10 over 3」「10 voor 4」「za dziesięć czwarta」「dziesięć po trzeciej」。
    /// 英语与波兰语只认数词（「3 to 4pm」是时间段），德语、荷兰语数字也认（那里 vor / voor / nach / over 不当时间段词）。
    fn minutes_first_clock(&mut self, i: usize, j: usize, cue_lang: Option<&'static str>) -> Option<usize> {
        let u = self.u;
        // 波兰语「za dziesięć czwarta」：ToHour 在最前。
        if let Some((n, _, lang)) = find(u, j, |s| s == Sem::ToHour) {
            if lang == "pl" {
                let (m, mn) = self.minutes_value(j + n)?;
                if u[j + n].kind == UKind::Number {
                    return None;
                }
                let (h, hn, _) = self.hour_at(j + n + mn)?;
                if !(1..=59).contains(&m) || !(1..=12).contains(&h) {
                    return None;
                }
                let (hour, off) = previous_hour(h as u8);
                self.push(Atom::Clock { clock: Clock { hour, minute: (60 - m) as u8, second: 0, day_offset: off }, period: None, explicit: true }, i, j + n + mn + hn, Some("pl"));
                return Some(j + n + mn + hn - i);
            }
            return None;
        }
        let (m, mn) = self.minutes_value(j)?;
        let minutes_are_digits = u[j].kind == UKind::Number;
        let (n, sem, lang) = find(u, j + mn, |s| matches!(s, Sem::Past | Sem::ToHour))?;
        if minutes_are_digits && !matches!(lang, "de" | "nl" | "tr") {
            return None;
        }
        if !(1..=59).contains(&m) {
            return None;
        }
        let (h, hn, _) = self.hour_at(j + mn + n)?;
        if !(1..=12).contains(&h) {
            return None;
        }
        let mut end = j + mn + n + hn;
        if let Some(c) = is(u, end, |s| s == Sem::ClockAfter) {
            end += c;
        }
        let clock = if sem == Sem::Past {
            Clock::at(h as u8, m as u8)
        } else {
            let (hour, off) = previous_hour(h as u8);
            Clock { hour, minute: (60 - m) as u8, second: 0, day_offset: off }
        };
        self.push(Atom::Clock { clock, period: None, explicit: true }, i, end, cue_lang.or(Some(lang)));
        Some(end - i)
    }

    /// 土耳其语带格钟点后面的「M geçe」「çeyrek kala」：（钟点，吃掉的单元数）。宾格 + geçe = 过了 M 分；与格 + kala = 差 M 分。
    fn turkish_tail(&self, hour: u8, case: Sem, at: usize) -> Option<(Clock, usize)> {
        let u = self.u;
        if let Some((n, Sem::ClockShift(shift), _)) = find(u, at, |s| matches!(s, Sem::ClockShift(_))) {
            return match (case, shift >= 0) {
                (Sem::TrAcc(_), true) => Some((Clock::at(hour % 24, shift as u8), n)),
                (Sem::TrDat(_), false) => {
                    let (h, off) = previous_hour(hour);
                    Some((Clock { hour: h, minute: (60 - shift.unsigned_abs() as i16) as u8, second: 0, day_offset: off }, n))
                }
                _ => None,
            };
        }
        let (m, mn) = self.minutes_value(at)?;
        let (n, sem, _) = find(u, at + mn, |s| matches!(s, Sem::Past | Sem::ToHour))?;
        if !(1..=59).contains(&m) {
            return None;
        }
        match (case, sem) {
            (Sem::TrAcc(_), Sem::Past) => Some((Clock::at(hour % 24, m as u8), mn + n)),
            (Sem::TrDat(_), Sem::ToHour) => {
                let (h, off) = previous_hour(hour);
                Some((Clock { hour: h, minute: (60 - m) as u8, second: 0, day_offset: off }, mn + n))
            }
            _ => None,
        }
    }

    /// 时区：UTC / GMT ± 偏移、单独的 ±HH:MM、全大写缩写（小写的 3–4 字母缩写紧跟在钟点后也认：`3pm pst`）、
    /// 「北京时间 / Pacific time / hora del este / по москве」这类整词。
    pub(super) fn zone(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        let m = matcher();
        // Standard/daylight words explicitly name a fixed offset.
        for (name, minutes, region) in [
            ("Midden-Europese Tijd", 60, "Europe/Berlin"),
            ("Midden-Europese Zomertijd", 120, "Europe/Berlin"),
        ] {
            if u[i].text != "midden" { continue; }
            let phrase = super::units::phrase_units(&super::text::fold_str(name));
            if u.get(i..i + phrase.len()).is_some_and(|span| span.iter().zip(&phrase).all(|(t, p)| t.text == *p)) {
                self.push(Atom::Zone(ZoneRef::Fixed { minutes, region: Some(region.to_owned()) }), i, i + phrase.len(), Some("nl"));
                return Some(phrase.len());
            }
        }
        // 整词（最长的先）。
        if let Some(list) = m.zone_words.get(&u[i].text) {
            for (phrase, iana) in list {
                let n = phrase.len();
                if n == 1 && u[i].text == "central" && !u[i].capital && !u[i].upper && !self.out.last().is_some_and(|l| matches!(l.atom, Atom::Clock { .. }) && l.to == i) { continue; }
                if i + n <= u.len() && (0..n).all(|k| u[i + k].text == phrase[k]) {
                    let zone = if *iana == "UTC" { ZoneRef::Fixed { minutes: 0, region: None } } else { ZoneRef::Region { iana: (*iana).to_owned() } };
                    self.push(Atom::Zone(zone), i, i + n, None);
                    return Some(n);
                }
            }
        }
        let cur = &u[i];
        if cur.kind == UKind::Word && (cur.text == "utc" || cur.text == "gmt") {
            // 「UTC+99」这种不成立的偏移：说出来，不悄悄读成 UTC。
            if let (Some(sign), Some(num)) = (u.get(i + 1), u.get(i + 2)) {
                if (is_punct(sign, "+") || is_punct(sign, "-")) && !sign.space_before && num.kind == UKind::Number && !num.space_before
                    && numeric_offset(u, i + 1).is_none()
                {
                    let mut end = i + 3;
                    if u.get(end).is_some_and(|c| is_punct(c, ":") && !c.space_before) && u.get(end + 1).is_some_and(|m| m.kind == UKind::Number) {
                        end += 2;
                    }
                    self.push(Atom::Invalid("invalidOffset"), i, end, None);
                    return Some(end - i);
                }
            }
            let (minutes, used) = numeric_offset(u, i + 1).unwrap_or((0, 0));
            self.push(Atom::Zone(ZoneRef::Fixed { minutes, region: None }), i, i + 1 + used, None);
            return Some(1 + used);
        }
        // 钟点后紧跟的偏移：`+05:30`、`+8`、`-0300`。`-HH:MM` 一律当时间段（`14:00-16:00` 远比 `14:00-03:00` 常见）。
        // 钟点后单独的大写 Z（军用记法 Zulu）：UTC。
        if cur.raw == "Z" && self.out.last().is_some_and(|l| matches!(l.atom, Atom::Clock { .. }) && l.to == i) {
            self.push(Atom::Zone(ZoneRef::Fixed { minutes: 0, region: None }), i, i + 1, None);
            return Some(1);
        }
        let sign_ok = !is_range_dash(cur) && (is_punct(cur, "+") || (is_punct(cur, "-") && u.get(i + 1).is_some_and(|t| t.text.len() == 4)));
        if sign_ok && self.out.last().is_some_and(|l| matches!(l.atom, Atom::Clock { .. }) && l.to == i) {
            if let Some((minutes, used)) = numeric_offset(u, i) {
                self.push(Atom::Zone(ZoneRef::Fixed { minutes, region: None }), i, i + used, None);
                return Some(used);
            }
        }
        if cur.kind == UKind::Word {
            // 西里尔缩写与拉丁 MSK 指向同一个固定偏移。
            if let Some(&index) = m.abbreviations.get(&cur.text).or_else(|| (cur.text == "мск").then(|| m.abbreviations.get("msk")).flatten()) {
                let after_clock = self.out.last().is_some_and(|l| matches!(l.atom, Atom::Clock { .. } | Atom::Instant(_)) && l.to + 1 >= i);
                let accept = cur.upper && (cur.text.len() >= 2)
                    || matches!(cur.text.as_str(), "aoe" | "мск")
                    || (after_clock && cur.text.len() >= 3 && !matches!(cur.text.as_str(), "art" | "cat" | "pet" | "wat" | "ist" | "est" | "ast" | "eat" | "wit" | "gst"));
                if accept {
                    let abbrev = &ABBREVIATIONS[index];
                    let options: Vec<ZoneRef> = abbrev
                        .options
                        .iter()
                        .map(|(fixed, iana)| match fixed {
                            Some(minutes) => ZoneRef::Fixed { minutes: *minutes, region: Some((*iana).to_owned()) },
                            None => ZoneRef::Region { iana: (*iana).to_owned() },
                        })
                        .collect();
                    let zone = if options.len() == 1 { options.into_iter().next().unwrap() } else { ZoneRef::Options { reason: "abbreviation", options } };
                    self.push(Atom::Zone(zone), i, i + 1, None);
                    return Some(1);
                }
            }
        }
        None
    }

    /// IANA 时区标识符（America/New_York、Asia/Ho_Chi_Minh、America/Argentina/Buenos_Aires、Etc/GMT+12）：
    /// 首段是 tz 数据库的大区，中间不隔空白。原样（保留大小写）交给宿主校验，不在这里判真假。
    pub(super) fn iana(&mut self, i: usize) -> Option<usize> {
        const AREAS: [&str; 11] = ["africa", "america", "antarctica", "arctic", "asia", "atlantic", "australia", "europe", "indian", "pacific", "etc"];
        let u = self.u;
        if u[i].kind != UKind::Word || !AREAS.contains(&u[i].text.as_str()) {
            return None;
        }
        let mut j = i + 1;
        while j < u.len() && !u[j].space_before {
            let ok = match u[j].kind {
                UKind::Word | UKind::Number => true,
                UKind::Punct => matches!(u[j].text.as_str(), "/" | "_" | "-" | "+"),
                UKind::Cjk => false,
            };
            if !ok {
                break;
            }
            j += 1;
        }
        // 不停在分隔符上（「Asia/」「Europe/London-」）。
        while j > i + 1 && u[j - 1].kind == UKind::Punct {
            j -= 1;
        }
        if !u[i + 1..j].iter().any(|t| t.text == "/") {
            return None;
        }
        let raw: String = u[i..j].iter().map(|t| t.raw.as_str()).collect();
        self.push(Atom::Zone(ZoneRef::Region { iana: raw }), i, j, None);
        Some(j - i)
    }

    /// 地点与目标线索：「in X」「hora de X」「X time」「在 X」「是 X 几点」「X では何時」「to X」「→ X」。
    fn cues(&mut self, i: usize) -> Option<usize> {
        let u = self.u;
        // 查城市之前判断语法。候选地点不能替引出它的线索词证明语言；未知仍保留既有读法。
        if super::language::ordinary_noun(u, i) { return None; }
        let cue_lang = |n, sem, lang: &'static str, excluded| {
            if lang.is_empty() || super::language::evidence(u, i, n, excluded).is_unknown() { Some(lang) }
            else { super::language::supported_language(u, i, n, sem, excluded) }
        };
        if let Some((n, sem, lang)) = find(u, i, |s| s == Sem::TargetAsk) {
            // Bare Indonesian questions look back to a place, rather than treating
            // a following ordinary word ("jam berapa sekarang") as its name.
            if lang == "id" && n == 2 && ["jam", "pukul"].contains(&u[i].text.as_str()) && u[i + 1].text == "berapa" {
                let lang = cue_lang(n, sem, lang, None)?;
                self.push(Atom::TargetMarker, i, i + n, Some(lang));
                return Some(n);
            }
            // 问句在前（what time in X、quelle heure à X、jam berapa di X）：地名在后。
            let place = words_after(u, i + n, 4, false);
            let lang = cue_lang(n, sem, lang, Some((i + n, place.1)))?;
            if !place.0.is_empty() {
                self.push(Atom::Target { text: place.0, bare: place.2 }, i, place.1, Some(lang));
                return Some(place.1 - i);
            }
            // 问句在后（X 几点、X では何時、X는 몇 시、X'te saat kaç）：由装配阶段把前面的地名改成目标。
            self.push(Atom::TargetMarker, i, i + n, Some(lang));
            return Some(n);
        }
        // 线索后面紧跟的是时区词（「по МСК」「in ET」）：让给时区词去认，不当地名吞掉（「в 19:00 по МСК」）。
        if i > 0 && u[i - 1].text == "'" && ["a", "e", "da", "de", "ta", "te"].contains(&u[i].text.as_str()) { return None; }
        if find(u, i, |s| matches!(s, Sem::ZoneBefore | Sem::PlaceIn | Sem::PlaceInArticle)).is_some_and(|(n, _, _)| zone_word_at(u, i + n)) {
            return None;
        }
        if let Some((n, sem, lang)) = find(u, i, |s| s == Sem::ZoneBefore).filter(|_| !["de", "di"].contains(&u[i].text.as_str()) || self.out.iter().rev().take_while(|l| !matches!(l.atom, Atom::Boundary(_))).any(|l| matches!(l.atom, Atom::Clock { .. }) && l.to <= i && i - l.to <= 5)) {
            let place = words_after(u, i + n, 3, false);
            let rejected_zone_before = n == 1 && ["de", "di"].contains(&u[i].text.as_str())
                && matches!(super::language::evidence(u, i, n, Some((i + n, place.1))), super::language::Evidence::Language(language, _) if !["fr", "es", "it"].contains(&language));
            // The same word may still be another cue, such as Indonesian PlaceIn "di".
            if let Some(lang) = cue_lang(n, sem, lang, Some((i + n, place.1))).filter(|_| !place.0.is_empty() && !rejected_zone_before) {
                self.push(Atom::Place { text: place.0, strong: true, bare: place.2 }, i, place.1, Some(lang));
                return Some(place.1 - i);
            }
        }
        if let Some((n, sem, lang)) = find(u, i, |s| s == Sem::PlaceIn) {
            // 在作为独立介词才引出地点，词内的现在、正在、在线等不算。
            let independent_after_adverb = i >= 2 && !u[i].space_before && !u[i - 1].space_before
                && matches!((u[i - 2].text.as_str(), u[i - 1].text.as_str()),
                    ("其" | "确" | "確", "实" | "實") | ("出", "现" | "現"));
            if u[i].text == "在" && !independent_after_adverb && (i > 0 && !u[i].space_before
                && ["现", "現", "正", "实", "實", "存", "所", "内", "內"].contains(&u[i - 1].text.as_str())
                || u.get(i + 1).is_some_and(|next| !next.space_before && ["线", "線", "住"].contains(&next.text.as_str()))) { return None; }
            let place = words_after(u, i + n, 3, false);
            if let Some(lang) = cue_lang(n, sem, lang, Some((i + n, place.1))).filter(|_| !place.0.is_empty()) {
                self.push(Atom::Place { text: place.0, strong: true, bare: place.2 }, i, place.1, Some(lang));
                return Some(place.1 - i);
            }
        }
        // 介词与冠词连写（au Japon、nos Estados Unidos、im Iran）：只认国家名，不投语言票。
        if let Some((n, sem, lang)) = find(u, i, |s| s == Sem::PlaceInArticle) {
            let place = words_after(u, i + n, 3, false);
            if !place.0.is_empty() && cue_lang(n, sem, lang, Some((i + n, place.1))).is_some() {
                let bare = place.2.unwrap_or_else(|| place.0.clone());
                self.push(Atom::Place { text: place.0, strong: true, bare: Some(bare) }, i, place.1, Some(lang));
                return Some(place.1 - i);
            }
        }
        if let Some((n, sem, lang)) = find(u, i, |s| s == Sem::TargetTo) {
            let place = words_after(u, i + n, 3, false);
            if let Some(lang) = cue_lang(n, sem, lang, Some((i + n, place.1))).filter(|_| !place.0.is_empty()
                && self.out.iter().any(|l| matches!(l.atom, Atom::Clock { .. } | Atom::Relative(_) | Atom::Instant(_) | Atom::Idiom(..)))) {
                self.push(Atom::Target { text: place.0, bare: place.2 }, i, place.1, if lang.is_empty() { None } else { Some(lang) });
                return Some(place.1 - i);
            }
        }
        // 「X time / X Zeit / X tijd / X saati / X时间」：地名在前，由装配阶段取前面的词。
        if u[i].text == "기" && u.get(i + 1).is_some_and(|t| t.text == "준" && !t.space_before) && (i == 0 || u[i].space_before) {
            self.push(Atom::Place { text: String::new(), strong: true, bare: None }, i, i + 2, Some("ko"));
            return Some(2);
        }
        if let Some((n, sem, lang)) = find(u, i, |s| s == Sem::ZoneAfter) {
            let start = (0..i).rev().find(|&k| u[k].kind != UKind::Word && u[k].kind != UKind::Cjk).map_or(0, |k| k + 1);
            let lang = cue_lang(n, sem, lang, Some((start, i)))?;
            self.push(Atom::Place { text: String::new(), strong: true, bare: None }, i, i + n, Some(lang));
            return Some(n);
        }
        // Turkish proper names carry locative case after an apostrophe. The
        // suffix is a location clue even when its noun phrase precedes the clock.
        if u[i].kind == UKind::Word {
            for end in i..(i + 4).min(u.len()) {
                if u[end].kind != UKind::Word { break; }
                if end > i && !u[i].capital && u[end].capital { break; }
                if u[end].text.split_once('\'').is_some_and(|(_, suffix)| ["da", "de", "ta", "te", "nda", "nde", "daki", "deki", "taki", "teki", "ndaki", "ndeki"].contains(&suffix)) {
                    // A lowercase-only sentence keeps the loose-name adjacency
                    // rule; only mixed-case text gains this new place cue.
                    if !u[i].capital && super::sentence_lowercase(u)[i] { break; }
                    let name = u[i..=end].iter().map(|t| t.raw.as_str()).collect::<Vec<_>>().join(" ");
                    self.push(Atom::Place { text: name, strong: true, bare: None }, i, end + 1, Some("tr"));
                    return Some(end + 1 - i);
                }
                if find(u, end, |s| matches!(s, Sem::Stop | Sem::Period(_) | Sem::ClockBefore)).is_some() { break; }
            }
        }
        None
    }
}

/// 线索词后面的地名：最多 `max` 个词（中日韩按连续的字算一个），遇到词表里的东西、数字、标点就停。
/// 紧跟线索的冠词（the United States、los Estados Unidos、in den USA、in de Verenigde Staten）后面是普通的词时一起带上，
/// 第三项给去掉冠词的地名（装配只拿它认国家名）；冠词后面是词表里的词（in the morning、en la tarde）照旧不算地名。
/// 写成大写的「US」是美国，小写的 us 是代词，仍在词表里停。`cjk_loose` = 开头的中日韩字也算地名
/// （「上海」的「上」也是词表里星期的「上」）：只给「我在哪儿」的说法用，别的线索照旧严。
pub(super) fn words_after(u: &[Unit], j: usize, max: usize, cjk_loose: bool) -> (String, usize, Option<String>) {
    let plain = |k: usize| {
        u.get(k).is_some_and(|t| t.kind == UKind::Word && (t.raw == "US" || starts_abbreviation(u, k) || t.capital && u.get(j).is_some_and(|first| first.capital) || find(u, k, |s| !matches!(s, Sem::Number(_) | Sem::CommonNoun)).is_none() && !super::language::ordinary_noun(u, k)))
    };
    if u.get(j).is_some_and(|t| t.kind == UKind::Word && ARTICLES.contains(&t.text.as_str())) && plain(j + 1) && !u[j].capital {
        let (text, end, _) = words_after(u, j + 1, max, cjk_loose);
        if text.is_empty() {
            return (String::new(), j, None);
        }
        return (format!("{} {}", u[j].raw, text), end, Some(text));
    }
    let mut j = j;
    let mut words = 0;
    let mut latin = String::new();
    let mut glue: Option<&str> = None;
    let mut cjk = String::new();
    while j < u.len() {
        let t = &u[j];
        if t.kind == UKind::Number {
            break;
        }
        if t.kind == UKind::Punct {
            // 连字符与撇号夹在两个词中间（États-Unis、Aix-en-Provence、Côte d'Ivoire、İstanbul'da）：地名的一部分，照原样拼。
            // 词表里的「-」是时间段的分隔符，所以要在查词表之前认（此前这里在查词表之后，连字符地名一直拼不起来）。
            let inside = matches!(t.text.as_str(), "-" | "'") && !latin.is_empty() && !t.space_before
                && u.get(j + 1).is_some_and(|n| n.kind == UKind::Word && !n.space_before);
            if inside {
                glue = Some(t.raw.as_str());
                j += 1;
                continue;
            }
            // 带点的缩写（U.S.、U.K.）：点照原样拼进去。
            if t.text == "." && !latin.is_empty() && in_dotted_abbreviation(u, j) {
                latin.push('.');
                if u.get(j + 1).is_some_and(|n| n.kind == UKind::Word && !n.space_before) {
                    glue = Some("");
                }
                j += 1;
                continue;
            }
            break;
        }
        if let Some(g) = glue.take() {
            // 贴着连字符的词（na、en、sur）即使在词表里也是地名的一部分。
            latin.push_str(g);
            latin.push_str(&t.raw);
            j += 1;
            continue;
        }
        if words == max {
            break;
        }
        // 紧接地名的汉字钟点仍属于时间（「在大阪八点」），不能随地名吞掉。
        // 数字本身可以在地名里（「三河」），只有完整的钟点后缀才截断。
        let numeral_start = j == 0 || t.space_before
            || !["零", "〇", "一", "二", "两", "兩", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万", "萬", "亿", "億"].contains(&u[j - 1].text.as_str());
        if !cjk.is_empty() && t.kind == UKind::Cjk && numeral_start
            && (Scanner { u, out: Vec::new() }).hour_at(j).is_some_and(|(_, n, _)| {
                find(u, j + n, |s| s == Sem::ClockAfter).is_some_and(|(clock_len, _, _)| {
                    !is(u, j + n, |s| matches!(s, Sem::HourUnit | Sem::MinuteUnit)).is_some_and(|unit_len| unit_len > clock_len)
                })
            }) {
            break;
        }
        if t.raw == "US" && cjk.is_empty() {
            if !latin.is_empty() {
                latin.push(' ');
            }
            latin.push_str("U.S.");
            words += 1;
            j += 1;
            continue;
        }
        let cjk_ok = t.kind == UKind::Cjk && is_han_place_char(u, j) && (cjk_loose || !cjk.is_empty());
        if (find(u, j, |s| !matches!(s, Sem::Number(_) | Sem::CommonNoun)).is_some() || super::language::ordinary_noun(u, j))
            && !cjk_ok && !starts_abbreviation(u, j) && !(t.capital && (!latin.is_empty() || ARTICLES.contains(&t.text.as_str())) && (find(u, j, |sem| matches!(sem, Sem::Weekday(_) | Sem::Month(_))).is_none() || latin.split_whitespace().count() == 1 && ARTICLES.contains(&latin.to_lowercase().as_str())))
            && !(!latin.is_empty() && ["de", "di", "da", "do", "del", "du"].contains(&t.text.as_str()) && u.get(j + 1).is_some_and(|next| next.capital)) {
            break;
        }
        if t.kind == UKind::Cjk {
            cjk.push_str(&t.raw);
            j += 1;
            continue;
        }
        if !cjk.is_empty() {
            break;
        }
        if !latin.is_empty() {
            latin.push(' ');
        }
        latin.push_str(&t.raw);
        words += 1;
        j += 1;
    }
    let text = if !cjk.is_empty() { cjk } else { latin };
    (text, j, None)
}

/// 「差 M 分到 H 点」里的 H 是下一个整点：返回（前一个小时，日偏移）。1 点差一刻 = 0:45（同一天）；13 点 = 12 点。
fn previous_hour(hour: u8) -> (u8, i8) {
    match hour {
        0 | 24 => (23, 0),
        h => (h - 1, 0),
    }
}

/// 「>」「→」后面跟的是不是日期或钟点的开头：数字，或月份、星期、相对日子、时段词、正午午夜、钟点线索词。
/// 后面是地名（London、東京）时不是——那还是目标。
fn starts_date_or_clock(u: &[Unit], j: usize) -> bool {
    u.get(j).is_some_and(|t| t.kind == UKind::Number)
        || find(u, j, |s| {
            matches!(
                s,
                Sem::Month(_) | Sem::Weekday(_) | Sem::RelDay(_) | Sem::RelDayPeriod(..) | Sem::RelDayEnd(_) | Sem::ClockBefore | Sem::Period(_) | Sem::Noon | Sem::Midnight
            )
        })
        .is_some()
}

/// 单个字母的钟点词（h、g、ч）前面隔着空白：不算（「3 h」是三小时；「9 h 30」那种由钟点自己认）。
fn single_spaced_word(u: &[Unit], j: usize) -> bool {
    u.get(j).is_some_and(|t| t.kind == UKind::Word && t.text.chars().count() == 1 && t.space_before)
}

/// 地名里的汉字碰巧也是词表里的字（「日本」的「日」、「上海」的「上」）：前面已经有地名字时继续算地名。
pub(super) fn is_han_place_char(units: &[Unit], j: usize) -> bool {
    // 词表里单字的虚词（的、是、在）仍然截断；其余单字（日、上、下、本、月）可以是地名的一部分。
    !matches!(units[j].text.as_str(), "的" | "是" | "在" | "和" | "跟" | "到" | "至" | "从" | "從" | "の" | "で" | "に" | "は" | "에" | "는" | "은")
}

/// `+05:30` / `+0530` / `+8` / `-03`：（分钟，吃掉的单元数）。
/// 区间用的长横与波浪（看折叠前的原文）：永远不是偏移的负号（「09:00–10:00」）。减号「−」与连字符「-」可以是。
pub(super) fn is_range_dash(t: &Unit) -> bool {
    matches!(t.raw.as_str(), "–" | "—" | "‒" | "―" | "〜" | "～" | "~" | "∼")
}

/// 钟点后面紧跟的 ±偏移算不算偏移：正规 ISO（日期与钟点之间是 T）里紧贴的都算；日期与钟点之间是空格时，「-」后面跟
/// HH:MM 是时间段的终点（「2026-10-02 09:00-10:00 UTC」），只有「+」与 git 那种不带冒号的「-0700」算偏移；长横永远不算
/// （「2026-10-02 09:00–10:00 UTC」曾读成 UTC 19:00，差 10 小时）。
fn offset_after_clock(u: &[Unit], j: usize, iso: bool) -> bool {
    let Some(sign) = u.get(j) else { return false };
    if is_range_dash(sign) {
        return false;
    }
    if is_punct(sign, "+") {
        return true;
    }
    if !is_punct(sign, "-") {
        return false;
    }
    (iso && !sign.space_before) || u.get(j + 1).is_some_and(|t| t.kind == UKind::Number && t.text.len() == 4)
}

pub(super) fn numeric_offset(u: &[Unit], i: usize) -> Option<(i32, usize)> {
    let sign = u.get(i)?;
    let sign = if is_punct(sign, "+") { 1 } else if is_punct(sign, "-") { -1 } else { return None };
    let h = u.get(i + 1).filter(|t| t.kind == UKind::Number && !t.space_before)?;
    let (hours, minutes, used) = match h.text.len() {
        1 | 2 => {
            let hours: i32 = h.text.parse().ok()?;
            if u.get(i + 2).is_some_and(|c| is_punct(c, ":") && !c.space_before) {
                let m = u.get(i + 3).filter(|t| t.kind == UKind::Number && t.text.len() == 2)?;
                (hours, m.text.parse().ok()?, 4)
            } else {
                (hours, 0, 2)
            }
        }
        4 => (h.text[..2].parse().ok()?, h.text[2..].parse().ok()?, 2),
        _ => return None,
    };
    // 上限 ±18:00，与旧严格语法和 ISO 8601 的通行做法一样（地球上实际用到的是 −12 到 +14）；「UTC+18:01」「UTC+99」不成立。
    if hours > 18 || minutes > 59 || (hours == 18 && minutes > 0) {
        return None;
    }
    Some((sign * (hours * 60 + minutes), used))
}

/// 线索后面可以带的冠词（折叠后）：英 the、西 el / los / las / la、法 le / la / les、德 den / der / dem / die、荷 de / het。
const ARTICLES: &[&str] = &["the", "el", "los", "las", "la", "le", "les", "den", "der", "dem", "die", "de", "het"];

/// `i` 处的点在单个字母组成的缩写里（U.S.、e.g.、U.S.A.）：前面是单个字母，而且后面紧跟单个字母、或前面已经是「字母.字母」。
fn in_dotted_abbreviation(u: &[Unit], i: usize) -> bool {
    let single = |k: usize| u.get(k).is_some_and(|t| t.kind == UKind::Word && t.text.chars().count() == 1);
    if u[i].space_before || i == 0 || !single(i - 1) {
        return false;
    }
    let next_letter = single(i + 1) && !u[i + 1].space_before;
    let after_dot = i >= 2 && u[i - 2].kind == UKind::Punct && u[i - 2].text == "." && !u[i - 1].space_before;
    next_letter || after_dot
}

/// `k` 处的单个字母是带点缩写的开头（U.S. 的 U：西语里 u 是「或」，在词表里）。
fn starts_abbreviation(u: &[Unit], k: usize) -> bool {
    u.get(k + 1).is_some_and(|n| n.kind == UKind::Punct && n.text == ".") && in_dotted_abbreviation(u, k + 1)
}

/// 点号钟点须有紧邻时区、时间标签或印尼语语法作证；不把普通点号数扩成钟点。
fn dotted_clock_context(u: &[Unit], i: usize) -> bool {
    let end = i + 3;
    let zone = u.get(end).is_some_and(|t| {
        zone_word_at(u, end) || t.upper && matcher().abbreviations.contains_key(&t.text)
            || t.kind == UKind::Word && is(u, end + 1, |s| s == Sem::ZoneAfter).is_some()
    });
    if zone { return true; }
    if i >= 1 && find(u, i - 1, |s| matches!(s, Sem::RangeSep | Sem::And | Sem::WeekdayAbbr(_) | Sem::ClockBefore))
        .is_some_and(|(n, _, lang)| n == 1 && lang == "id") { return true; }
    find(u, end, |s| s == Sem::RangeSep).is_some_and(|(_, _, lang)| lang == "id")
}

/// `j` 处开头是一个时区整词（МСК、ET、北京时间、Berlin time）。
fn zone_word_at(u: &[Unit], j: usize) -> bool {
    let Some(first) = u.get(j) else { return false };
    // Cyrillic Moscow time is unambiguous in every casing. Keep the cue from
    // swallowing it as a place before zone() can return the fixed offset.
    first.text == "мск" || matcher().zone_words.get(&first.text).is_some_and(|list| {
        list.iter().any(|(phrase, _)| j + phrase.len() <= u.len() && (0..phrase.len()).all(|k| u[j + k].text == phrase[k]))
    })
}

/// 同一句里另有只属于越南语的完整词表短语，才把「mai」当明天。
fn vietnamese_evidence(u: &[Unit], at: usize) -> bool {
    let boundary = |k: usize| {
        let t = &u[k];
        t.kind == UKind::Punct
            && (t.text == "\n\n" || matches!(t.text.as_str(), "!" | "?" | ";" | "。" | "；" | "|")
                || (t.text == "." && !in_dotted_abbreviation(u, k)
                    && !u.get(k + 1).is_some_and(|n| n.kind == UKind::Number && !n.space_before)))
    };
    let start = (0..at).rev().find(|&k| boundary(k)).map_or(0, |k| k + 1);
    let end = (at + 1..u.len()).find(|&k| boundary(k)).unwrap_or(u.len());
    for k in start..end {
        if k == at || matches!(u[k].text.as_str(), "mai" | "h" | "g") { continue; }
        let Some(phrases) = matcher().by_first.get(&u[k].text) else { continue; };
        for phrase in phrases {
            let n = phrase.units.len();
            if k + n > end || !(0..n).all(|j| u[k + j].text == phrase.units[j]) { continue; }
            // 单个去声调的词会撞上别的语言；带声调原词或多词语法才能独立作证。
            if n == 1 && u[k].raw.is_ascii() { continue; }
            if let Some(sems) = matcher().sem_langs.get(phrase.units) {
                if sems.iter().flat_map(|(_, langs)| langs).all(|&l| l == "vi") {
                    return true;
                }
            }
        }
    }
    false
}

/// 沿用名字形状与封闭词表，汉字词义只否决完整词，不能否决地名里的单字前缀。
fn nearby_name_end(u: &[Unit], start: usize) -> usize {
    if u[start].kind == UKind::Cjk {
        if find(u, start, |s| matches!(s, Sem::Stop | Sem::Filler)).is_some() && !is_han_place_char(u, start) { return start; }
        if start > 0 && !u[start].space_before && u[start - 1].kind == UKind::Cjk { return start; }
        let mut end = start + 1;
        while end < u.len() && u[end].kind == UKind::Cjk && !u[end].space_before && end - start < 12 { end += 1; }
        if end < u.len() && u[end].kind == UKind::Cjk && !u[end].space_before { return start; }
        return if find(u, start, |_| true).is_some_and(|(n, _, _)| start + n == end) { start } else { end };
    }
    if u[start].kind != UKind::Word || u[start].text.chars().count() < 2 { return start; }
    let article = |i: usize| u[i].capital && ["los", "las", "la", "le", "el", "il", "l"].contains(&u[i].text.as_str())
        && u.get(i + 1).is_some_and(|t| t.kind == UKind::Word && t.capital);
    if find(u, start, |s| s != Sem::CommonNoun).is_some() && !article(start) { return start; }
    let mut end = start + 1;
    let mut words = 1;
    while end < u.len() && words < 6 {
        if u[end].kind == UKind::Punct && matches!(u[end].text.as_str(), "-" | "'")
            && !u[end].space_before && u.get(end + 1).is_some_and(|t| t.kind == UKind::Word && !t.space_before) {
            end += 2; continue;
        }
        let connector = u[start].capital && ["de", "da", "del", "am", "of", "the", "van", "den"].contains(&u[end].text.as_str())
            && u.get(end + 1).is_some_and(|t| t.kind == UKind::Word && t.capital);
        let after_connector = u[start].capital && u[end].capital && end > start
            && ["de", "da", "del", "am", "of", "the", "van", "den"].contains(&u[end - 1].text.as_str());
        if u[end].kind != UKind::Word || u[end].text.chars().count() < 2
            || !connector && !after_connector && (find(u, end, |_| true).is_some()
                || u[start].capital != u[end].capital) { break; }
        end += 1; words += 1;
    }
    end
}
