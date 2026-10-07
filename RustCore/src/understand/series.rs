// SPDX-License-Identifier: GPL-3.0-only
//! 几个写明的日子共享一个钟点或没有钟点，按文字顺序展开。
use super::dates::{days_from_civil, valid_date};
use super::lexicon::Sem;
use super::scan::{Atom, Located};
use super::types::{Alternative, DateSpec};
use super::units::{find, phrase_units, UKind, Unit};
use std::sync::OnceLock;

struct Cues {
    language: &'static str,
    join: &'static [&'static str],
    range: &'static [&'static str],
    every: &'static [&'static str],
    month: &'static [&'static str],
}

// 每种界面语言分别列出连接词；标点也走同一张封闭表。
const CUES: &[Cues] = &[
    Cues { language: "en", join: &[",", "and"], range: &["to", "through", "until", "-", "–"], every: &["every", "each"], month: &["in","of"] },
    Cues { language: "de", join: &[",", "und"], range: &["bis", "-", "–"], every: &["jeden", "jede", "jedes"], month: &["im","in","des"] },
    Cues { language: "es", join: &[",", "y", "e"], range: &["a", "al", "hasta", "-", "–"], every: &["cada", "todos los", "todas las", "todo"], month: &["de","en","del"] },
    Cues { language: "fr", join: &[",", "et"], range: &["à", "au", "jusqu'à", "-", "–"], every: &["chaque", "tous les", "toutes les"], month: &["en","de","du"] },
    Cues { language: "it", join: &[",", "e", "ed"], range: &["a", "al", "fino a", "-", "–"], every: &["ogni", "tutti i", "tutte le"], month: &["a","in","di","del","nel"] },
    Cues { language: "ja", join: &[",", "、", "と", "及び"], range: &["から", "まで", "～", "-", "–"], every: &["毎週", "毎"], month: &["年","月","の"] },
    Cues { language: "ko", join: &[",", "와", "과", "및"], range: &["부터", "까지", "-", "–"], every: &["매주", "매"], month: &["년","월","의"] },
    Cues { language: "nl", join: &[",", "en"], range: &["tot", "tot en met", "t/m", "-", "–"], every: &["elke", "iedere"], month: &["in","van"] },
    Cues { language: "pl", join: &[",", "i", "oraz"], range: &["do", "-", "–"], every: &["każdy", "każda", "każde", "w każdy", "w każdą"], month: &["w","we","roku"] },
    Cues { language: "ru", join: &[",", "и"], range: &["до", "по", "-", "–"], every: &["каждый", "каждую", "каждое", "по"], month: &["в","во","года","году"] },
    Cues { language: "tr", join: &[",", "ve", "ile"], range: &["ile", "kadar", "-", "–"], every: &["her"], month: &["ayında","ayı","yılında"] },
    Cues { language: "vi", join: &[",", "và"], range: &["đến", "tới", "-", "–"], every: &["mỗi", "hằng", "hàng"], month: &["trong","vào","tháng","năm"] },
    Cues { language: "id", join: &[",", "dan"], range: &["sampai", "hingga", "s.d.", "s.d", "-", "–"], every: &["setiap", "tiap"], month: &["pada","bulan","di","tahun"] },
    Cues { language: "pt-BR", join: &[",", "e"], range: &["até", "a", "ao", "-", "–"], every: &["cada", "todo", "toda", "todos os", "todas as"], month: &["em","de","do"] },
    Cues { language: "zh-Hans", join: &[",", "、", "和", "及", "与"], range: &["至", "到", "～", "-", "–"], every: &["每周", "每星期", "每个星期"], month: &["年","月","的"] },
    Cues { language: "zh-Hant", join: &[",", "、", "和", "及", "與"], range: &["至", "到", "～", "-", "–"], every: &["每週", "每星期", "每個星期"], month: &["年","月","的"] },
];

struct Table { join: Vec<Vec<String>>, range: Vec<Vec<String>>, every: Vec<Vec<String>>, month: Vec<Vec<String>> }
fn table() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| {
        let words = |phrases: Vec<&str>| phrases.into_iter().map(|p| phrase_units(&super::text::fold_str(p))).collect();
        let mut languages = std::collections::HashSet::new();
        for cues in CUES { languages.insert(cues.language); }
        debug_assert_eq!(languages.len(), 16);
        Table {
            join: words(CUES.iter().flat_map(|c| c.join.iter().copied()).collect()),
            range: words(CUES.iter().flat_map(|c| c.range.iter().copied()).collect()),
            every: words(CUES.iter().flat_map(|c| c.every.iter().copied()).collect()),
            month: words(CUES.iter().flat_map(|c| c.month.iter().copied()).collect()),
        }
    })
}

fn matches(u: &[Unit], from: usize, to: usize, patterns: &[Vec<String>]) -> bool {
    from < to && patterns.iter().any(|p| p.len() == to - from && p.iter().zip(&u[from..to]).all(|(p, u)| *p == u.text))
}

fn join(u: &[Unit], from: usize, to: usize) -> Option<bool> {
    if from >= to { return None; }
    if matches(u, from, to, &table().range) { return Some(true); }
    let mut at = from;
    while at < to {
        let n = table().join.iter().filter(|p| at + p.len() <= to && p.iter().zip(&u[at..]).all(|(p, u)| *p == u.text)).map(Vec::len).max()?;
        at += n;
    }
    Some(false)
}

#[derive(Clone)]
pub(super) struct Day { pub date: DateSpec, pub from: usize, pub to: usize }

pub(super) struct Plan {
    pub clock: usize,
    pub dates: Vec<usize>,
    pub days: Vec<Day>,
    pub from: usize,
    pub to: usize,
    pub context_from: usize,
    pub context_to: usize,
    pub calendar_range: bool,
    pub has_range: bool,
}

fn kind(date: &DateSpec) -> u8 {
    match date { DateSpec::Weekday { .. } => 0, DateSpec::Offset { .. } => 1, _ => 2 }
}

fn day(a: &Located) -> Option<Day> {
    match &a.atom {
        Atom::Date(date) => Some(Day { date: date.clone(), from: a.from, to: a.to }),
        _ => None,
    }
}

fn clock_adjacent(u: &[Unit], from: usize, to: usize) -> bool {
    from <= to && to - from <= 3 && u[from..to].iter().enumerate().all(|(k, unit)| {
        (unit.kind == UKind::Punct && matches!(unit.text.as_str(), "," | "(" | ")" | "\"" | ":" | "\n"))
            || find(u, from + k, |s| matches!(s, Sem::Stop | Sem::ClockBefore | Sem::Filler)).is_some()
    })
}

fn range_days(a: &Day, b: &Day, daily_clock_range: bool) -> Option<Vec<Day>> {
    if let (DateSpec::Weekday { weekday: first, week }, DateSpec::Weekday { weekday: last, week: end_week }) = (&a.date, &b.date) {
        if end_week.is_some() && end_week != week || last < first { return None; }
        return Some((*first..=*last).map(|weekday| Day {
            date: DateSpec::Weekday { weekday, week: *week },
            from: if weekday == *last { b.from } else { a.from },
            to: if weekday == *first { a.to } else { b.to },
        }).collect());
    }
    if let (DateSpec::Offset { days: first }, DateSpec::Offset { days: last }) = (&a.date, &b.date) {
        if last < first { return None; }
        if i16::from(*last) - i16::from(*first) >= 7 { return Some(vec![a.clone(), b.clone()]); }
        return Some((*first..=*last).map(|days| Day { date: DateSpec::Offset { days }, from: if days == *last { b.from } else { a.from }, to: if days == *first { a.to } else { b.to } }).collect());
    }
    if !daily_clock_range { return Some(vec![a.clone(), b.clone()]); }
    let absolute = matches!(a.date, DateSpec::Absolute { .. });
    let values = |d: &DateSpec| match d {
        DateSpec::Absolute { year, month, day } => Some((*year, *month, *day)),
        DateSpec::MonthDay { month, day } => Some((2024, *month, *day)),
        _ => None,
    };
    let (year, month, first) = values(&a.date)?;
    let (mut end_year, end_month, last) = values(&b.date)?;
    if absolute && matches!(b.date, DateSpec::MonthDay { .. }) {
        end_year = year + i32::from((end_month, last) < (month, first));
    }
    let gap = days_from_civil(end_year, end_month, last) - days_from_civil(year, month, first);
    if gap < 0 { return None; }
    if gap >= 7 || !absolute && (month == 2 || end_month == 2) && month != end_month {
        return Some(vec![a.clone(), b.clone()]);
    }
    let mut out = Vec::new();
    let (mut y, mut m, mut d) = (year, month, first);
    for _ in 0..=gap {
        let date = if absolute { DateSpec::Absolute { year: y, month: m, day: d } } else { DateSpec::MonthDay { month: m, day: d } };
        out.push(Day { date, from: if (y, m, d) == (end_year, end_month, last) { b.from } else { a.from }, to: if (y, m, d) == (year, month, first) { a.to } else { b.to } });
        if valid_date(y, m, d + 1) { d += 1; }
        else { d = 1; if m < 12 { m += 1; } else { m = 1; y += 1; } }
    }
    Some(out)
}


fn calendar_consecutive(days: &[Day]) -> bool {
    days.len() > 1 && days.windows(2).all(|pair| match (&pair[0].date, &pair[1].date) {
        (DateSpec::Absolute { year: y1, month: m1, day: d1 }, DateSpec::Absolute { year: y2, month: m2, day: d2 }) => days_from_civil(*y2, *m2, *d2) - days_from_civil(*y1, *m1, *d1) == 1,
        (DateSpec::MonthDay { month: m1, day: d1 }, DateSpec::MonthDay { month: m2, day: d2 }) => days_from_civil(2024, *m2, *d2) - days_from_civil(2024, *m1, *d1) == 1,
        _ => false,
    })
}

pub(super) fn heading_calendar_days(u: &[Unit], first: &Day, last: &Day, nightly: bool) -> Option<Vec<Day>> {
    if !matches!(first.date, DateSpec::Absolute { .. } | DateSpec::MonthDay { .. })
        || !matches!(last.date, DateSpec::Absolute { .. } | DateSpec::MonthDay { .. })
        || join(u, first.to, last.from) != Some(true) { return None; }
    let mut days = range_days(first, last, true)?;
    // 跨午夜的短连续范围，最后一日只作结束的早晨；长范围仍保留两端。
    if nightly && calendar_consecutive(&days) { days.pop(); }
    Some(days)
}

pub(super) fn clock_gap(u: &[Unit], atoms: &[Located], from: usize, to: usize) -> bool {
    let mut at = from;
    while at < to {
        if u[at].kind == UKind::Punct && matches!(u[at].text.as_str(), "," | ":" | "(" | ")" | "\n") { at += 1; }
        else if let Some(a) = atoms.iter().find(|a| a.from == at && a.to <= to && matches!(a.atom, Atom::Zone(_) | Atom::Period(_) | Atom::From | Atom::RangeSep)) { at = a.to; }
        else if let Some((n, _, _)) = find(u, at, |s| matches!(s, Sem::ClockBefore | Sem::Stop | Sem::Filler | Sem::From | Sem::DayBefore)) { if at + n > to { return false; } at += n; }
        else { return false; }
    }
    true
}

// 日期范围只写了一次年份时，两端共用它；跨年按写出的先后衔接。
pub(super) fn share_range_years(u: &[Unit], atoms: &mut [Located], alternatives: &[Option<Alternative>]) {
    let dates: Vec<_> = atoms.iter().enumerate().filter(|(_, a)| matches!(a.atom, Atom::Date(DateSpec::Absolute { .. } | DateSpec::MonthDay { .. }))).map(|(k, _)| k).collect();
    for pair in dates.windows(2) {
        let (first, last) = (pair[0], pair[1]);
        if alternatives[first].is_some() || alternatives[last].is_some() { continue; }
        if join(u, atoms[first].to, atoms[last].from) != Some(true) { continue; }
        let (a, b) = (atoms[first].atom.clone(), atoms[last].atom.clone());
        let replacement = match (a, b) {
            (Atom::Date(DateSpec::MonthDay { month, day }), Atom::Date(DateSpec::Absolute { year, month: end_month, day: end_day })) => {
                let year = year - i32::from((month, day) > (end_month, end_day));
                valid_date(year, month, day).then_some((first, DateSpec::Absolute { year, month, day }))
            }
            (Atom::Date(DateSpec::Absolute { year, month: start_month, day: start_day }), Atom::Date(DateSpec::MonthDay { month, day })) => {
                let year = year + i32::from((month, day) < (start_month, start_day));
                valid_date(year, month, day).then_some((last, DateSpec::Absolute { year, month, day }))
            }
            _ => None,
        };
        if let Some((index, date)) = replacement { atoms[index].atom = Atom::Date(date); }
    }
}

pub(super) fn plans(u: &[Unit], atoms: &[Located]) -> Vec<Plan> {
    let mut out = Vec::new();
    for (clock, a) in atoms.iter().enumerate() {
        if !matches!(a.atom, Atom::Clock { .. } | Atom::Idiom(..)) { continue; }
        // 紧挨数字钟点的截止习语归那个钟点，不另作共享锚。
        if matches!(a.atom, Atom::Idiom(..)) && atoms.iter().any(|other| matches!(other.atom, Atom::Clock { .. })
            && (clock_adjacent(u, a.to, other.from) || clock_adjacent(u, other.to, a.from))) { continue; }
        // 时间段终点不能再共享一遍；各日自己写了钟点时也不跨过钟点。
        if clock >= 2 && matches!(atoms[clock - 1].atom, Atom::RangeSep) && matches!(atoms[clock - 2].atom, Atom::Clock { .. }) { continue; }
        let Some(last) = atoms[..clock].iter().rposition(|a| matches!(a.atom, Atom::Date(_))) else { continue; };
        let end = if matches!(a.atom, Atom::Clock { .. }) && clock + 2 < atoms.len() && matches!(atoms[clock + 1].atom, Atom::RangeSep) && matches!(atoms[clock + 2].atom, Atom::Clock { .. }) { atoms[clock + 2].to } else { a.to };
        if let Some((index, following)) = atoms.iter().enumerate().skip(clock + 1)
            .find(|(_, a)| a.from >= end && matches!(a.atom, Atom::Date(_) | Atom::Clock { .. } | Atom::Idiom(..) | Atom::Boundary(_))) {
            if matches!(following.atom, Atom::Date(DateSpec::Absolute { .. } | DateSpec::MonthDay { .. }))
                && clock_gap(u, atoms, end, following.from) {
                // 后面的日期若另有紧跟的钟点，归它自己的提到，不截断前面的共享系列。
                let own_clock = atoms[index + 1..].iter()
                    .find(|a| matches!(a.atom, Atom::Date(_) | Atom::Clock { .. } | Atom::Idiom(..) | Atom::Boundary(_)))
                    .is_some_and(|a| matches!(a.atom, Atom::Clock { .. } | Atom::Idiom(..))
                        && clock_gap(u, atoms, following.to, a.from));
                if !own_clock { continue; }
            }
        }
        if let Some(plan) = every_plan(u, atoms, Some(clock), last, u.len()) { out.push(plan); continue; }
        if atoms[last + 1..clock].iter().any(|a| matches!(a.atom, Atom::Clock { .. } | Atom::Idiom(..) | Atom::Boundary(_))) || !clock_gap(u, atoms, atoms[last].to, a.from) { continue; }
        let mut dates = vec![last];
        let mut connectors = Vec::new();
        let mut current = last;
        while let Some(previous) = atoms[..current].iter().rposition(|a| matches!(a.atom, Atom::Date(_))) {
            if kind(&day(&atoms[current]).unwrap().date) != kind(&day(&atoms[previous]).unwrap().date) { break; }
            let Some(range) = join(u, atoms[previous].to, atoms[current].from) else { break; };
            connectors.push(range);
            dates.push(previous);
            current = previous;
        }
        dates.reverse();
        connectors.reverse();
        if dates.len() < 2 { continue; }
        let first = day(&atoms[dates[0]]).unwrap();
        let mut days = vec![first.clone()];
        let mut valid = true;
        for (&index, &range) in dates[1..].iter().zip(&connectors) {
            let next = day(&atoms[index]).unwrap();
            if range {
                if let Some(expanded) = range_days(days.last().unwrap(), &next, end > a.to) { days.pop(); days.extend(expanded); }
                else { valid = false; break; }
            } else { days.push(next); }
        }
        if !valid || days.len() < 2 { continue; }
        let end = if matches!(a.atom, Atom::Clock { .. }) && clock + 2 < atoms.len() && matches!(atoms[clock + 1].atom, Atom::RangeSep) && matches!(atoms[clock + 2].atom, Atom::Clock { .. }) { atoms[clock + 2].to } else { a.to };
        let consecutive = calendar_consecutive(&days);
        let calendar_range = connectors.len() == 1 && connectors[0] && consecutive;
        let context_to = atoms[last].to;
        out.push(Plan { clock, dates, days, from: first.from, to: end, context_from: first.from, context_to, calendar_range, has_range: connectors.iter().any(|range| *range) });
    }
    out
}


pub(super) fn date_plans(u: &[Unit], atoms: &[Located], segment_to: usize) -> Vec<Plan> {
    // 普通的单个星期仍不单独成事；只有写明的多日语法才展开成无钟点的系列。
    // 月内重复星期仍只在无钟点的片段里找年月，避免借用另一处钟点后的限定。
    let no_clock = !atoms.iter().any(|a| matches!(a.atom, Atom::Clock { .. } | Atom::Relative(_) | Atom::Instant(_) | Atom::Idiom(..) | Atom::Invalid("invalidTime")));
    let mut out = Vec::new();
    for (weekday, a) in atoms.iter().enumerate() {
        if no_clock && matches!(a.atom, Atom::Date(DateSpec::Weekday { .. })) {
            if let Some(plan) = every_plan(u, atoms, None, weekday, segment_to) {
                out.push(plan);
            }
        }
    }
    let dates: Vec<_> = atoms.iter().enumerate()
        .filter(|(k, a)| matches!(a.atom, Atom::Date(_)) && !out.iter().any(|plan| plan.dates.contains(k)))
        .map(|(k, _)| k).collect();
    let mut at = 0;
    while at < dates.len() {
        let first = at;
        let mut connectors = Vec::new();
        while at + 1 < dates.len() {
            let (a, b) = (dates[at], dates[at + 1]);
            if kind(&day(&atoms[a]).unwrap().date) != kind(&day(&atoms[b]).unwrap().date) { break; }
            let Some(range) = join(u, atoms[a].to, atoms[b].from) else { break; };
            connectors.push(range);
            at += 1;
        }
        let indices = dates[first..=at].to_vec();
        at += 1;
        if indices.len() < 2 { continue; }
        let first_day = day(&atoms[indices[0]]).unwrap();
        let mut days = vec![first_day.clone()];
        let mut valid = true;
        for (&index, &range) in indices[1..].iter().zip(&connectors) {
            let next = day(&atoms[index]).unwrap();
            if range {
                if let Some(expanded) = range_days(days.last().unwrap(), &next, false) { days.pop(); days.extend(expanded); }
                else { valid = false; break; }
            } else { days.push(next); }
        }
        if !valid || days.len() < 2 { continue; }
        let last = *indices.last().unwrap();
        out.push(Plan {
            clock: last, dates: indices, days, from: first_day.from, to: atoms[last].to,
            context_from: first_day.from, context_to: atoms[last].to,
            calendar_range: false, has_range: connectors.iter().any(|range| *range),
        });
    }
    out
}


pub(super) fn heading_date_plans(u: &[Unit], atoms: &[Located], segment_from: usize, segment_to: usize) -> Vec<Plan> {
    let label = |units: &[Unit]| {
        let text: String = units.iter().filter(|unit| unit.kind != UKind::Punct).map(|unit| unit.text.as_str()).collect();
        if matches!(text.as_str(), "" | "date" | "schedule" | "termin" | "datum" | "日期" | "日程" | "날짜" | "일정") { return true; }
        if !units.last().is_some_and(|unit| unit.text == ":") || units.iter().any(|unit| unit.kind == UKind::Number) { return false; }
        let (mut words, mut cjk) = (0, false);
        for unit in units {
            match unit.kind {
                UKind::Cjk => { if !cjk || unit.space_before { words += 1; } cjk = true; }
                UKind::Word => { words += 1; cjk = false; }
                _ => { cjk = false; }
            }
        }
        words <= 2
    };
    let mut out = Vec::new();
    let mut from = segment_from;
    for at in segment_from..segment_to {
        if u[at].kind != UKind::Punct || !matches!(u[at].text.as_str(), "." | "。" | "\n" | "\n\n") { continue; }
        // 日.月.年里的点还在日期原子内，不能把它当标题末尾。
        if atoms.iter().any(|a| a.from <= at && at + 1 < a.to) { continue; }
        let to = if matches!(u[at].text.as_str(), "\n" | "\n\n") { at } else { at + 1 };
        let lo = atoms.iter().position(|a| a.from >= from).unwrap_or(atoms.len());
        let hi = atoms[lo..].iter().position(|a| a.to > to).map_or(atoms.len(), |k| lo + k);
        if lo < hi {
            for mut plan in date_plans(u, &atoms[lo..hi], to) {
                // 只有完整的日期串才作标题；同一行夹着的正文仍走原来的归属。
                if plan.context_from < from || plan.context_to > to || !label(&u[from..plan.context_from])
                    || !u[plan.context_to..to].iter().all(|unit| unit.kind == UKind::Punct)
                    || atoms[lo..hi].iter().enumerate().any(|(k, a)| matches!(a.atom, Atom::Date(_)) && !plan.dates.contains(&k)) { continue; }
                plan.clock += lo;
                for date in &mut plan.dates { *date += lo; }
                out.push(plan);
            }
        }
        from = at + 1;
    }
    out
}

fn every_plan(u: &[Unit], atoms: &[Located], clock: Option<usize>, weekday: usize, segment_to: usize) -> Option<Plan> {
    let a = &atoms[weekday];
    let Atom::Date(DateSpec::Weekday { weekday: wanted, .. }) = a.atom else { return None; };
    let prefix = (a.from.saturating_sub(6)..a.from).find(|&start| (a.from..=a.to).any(|end| matches(u, start, end, &table().every)))?;
    let lo = atoms[..weekday].iter().rev().find(|a| matches!(a.atom, Atom::Clock { .. } | Atom::Idiom(..) | Atom::Boundary(_))).map_or(0, |a| a.to);
    let hi = clock.map_or(segment_to, |clock| atoms[clock].from);
    let mut months = Vec::new();
    let mut years = Vec::new();
    for k in lo..hi {
        if let Some((n, Sem::Month(month), _)) = find(u, k, |s| matches!(s, Sem::Month(_))) {
            if k + n <= hi { months.push((month, k, k + n)); }
        }
        if let Some(n) = find(u, k, |s| s == Sem::MonthBefore).map(|x| x.0) {
            if let Some(month) = u.get(k + n).filter(|_| k + n < hi).and_then(|t| t.text.parse::<u8>().ok()).filter(|m| (1..=12).contains(m)) { months.push((month, k, k + n + 1)); }
        }
        if u[k].kind == UKind::Number {
            if let Ok(value) = u[k].text.parse::<i32>() {
                if u[k].text.len() == 4 && (1800..=2200).contains(&value) { years.push((value, k)); }
                if (1..=12).contains(&value) && find(u, k + 1, |s| s == Sem::MonthMark).is_some_and(|(n, _, _)| k + n < hi) {
                    months.push((value as u8, k, k + 1 + find(u, k + 1, |s| s == Sem::MonthMark).unwrap().0));
                }
            }
        }
    }
    months.sort_unstable(); months.dedup();
    let [(month, month_from, month_to)] = months[..] else { return None; };
    let [(year, year_at)] = years[..] else { return None; };
    // 没写年时无法从星期确定月内哪几天，不借机器日期补年。
    let mut days = Vec::new();
    for d in 1..=31 {
        if valid_date(year, month, d) && (days_from_civil(year, month, d) + 3).rem_euclid(7) + 1 == i64::from(wanted) {
            days.push(Day { date: DateSpec::Absolute { year, month, day: d }, from: a.from, to: a.to });
        }
    }
    if days.is_empty() { return None; }
    let scope_from = prefix.min(month_from).min(year_at);
    let scope_to = a.to.max(month_to).max(year_at + 1);
    if !clock_gap(u, atoms, scope_to, hi) { return None; }
    // 月份限定只接封闭的介词、年月标记；别的正文不能被整串吞掉。
    if atoms.iter().any(|a| scope_from <= a.from && a.to <= scope_to && matches!(a.atom, Atom::Invalid(_))) { return None; }
    let mut claimed = vec![false; u.len()];
    claimed[a.from..a.to].fill(true);
    claimed[month_from..month_to].fill(true);
    claimed[year_at] = true;
    let prefix_end = (a.from..=a.to).filter(|&end| matches(u, prefix, end, &table().every)).max()?;
    claimed[prefix..prefix_end].fill(true);
    for atom in atoms.iter().filter(|a| scope_from <= a.from && a.to <= scope_to && matches!(a.atom, Atom::Zone(_) | Atom::Period(_))) { claimed[atom.from..atom.to].fill(true); }
    let mut at = scope_from;
    let mut qualification = false;
    while at < scope_to {
        if claimed[at] { at += 1; continue; }
        let n = table().month.iter().filter(|p| at + p.len() <= scope_to && p.iter().zip(&u[at..]).all(|(p, u)| *p == u.text)).map(Vec::len).max()?;
        qualification = true;
        at += n;
    }
    if !qualification { return None; }
    let dates = atoms.iter().enumerate().filter(|(_, a)| scope_from <= a.from && a.to <= scope_to && matches!(a.atom, Atom::Date(_))).map(|(k, _)| k).collect();
    let end = clock.map_or(scope_to, |clock| {
        if matches!(atoms[clock].atom, Atom::Clock { .. }) && clock + 2 < atoms.len() && matches!(atoms[clock + 1].atom, Atom::RangeSep) && matches!(atoms[clock + 2].atom, Atom::Clock { .. }) { atoms[clock + 2].to } else { atoms[clock].to }
    });
    Some(Plan { clock: clock.unwrap_or(weekday), dates, days, from: if clock.is_some() { a.from } else { scope_from }, to: end, context_from: scope_from, context_to: scope_to, calendar_range: false, has_range: false })
}
