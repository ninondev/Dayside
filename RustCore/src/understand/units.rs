// SPDX-License-Identifier: GPL-3.0-only
//! 单元与词表匹配：折叠文本切成单元，词表短语按单元序列匹配。
use super::lexicon::Sem;
#[cfg(test)]
use super::lexicon::{ABBREVIATIONS, ENTRIES};
use super::text::{self, fold, tokens, Kind};
#[cfg(test)]
use super::text::fold_str;
#[cfg(test)]
use std::collections::HashMap;
use super::table_storage::{Slice, StrMap, WordsMap};

// ───────────────────────────── 单元 ─────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum UKind {
    Word,
    Number,
    Cjk,
    Punct,
}

#[derive(Debug, Clone)]
pub(super) struct Unit {
    pub(super) text: String,
    pub(super) kind: UKind,
    /// 折叠文本里的字符区间。
    pub(super) start: usize,
    pub(super) end: usize,
    /// 前面隔着空白。
    pub(super) space_before: bool,
    /// 原文里这个词的字母全是大写（缩写要看：`ET` 算、`et` 不算）。
    pub(super) upper: bool,
    /// 原文里首字母大写（零散的拉丁词当地名要看：「Tokyo」可以、「meet」不行；整段都小写时不看）。
    pub(super) capital: bool,
    /// 原文（IANA 标识符要原样交给宿主：America/New_York）。
    pub(super) raw: String,
    pub(super) evidence_memo: super::language::EvidenceMemo,
    lexicon_memo: LexiconMemo,
}

impl Unit {
    pub(super) fn nearby_candidate(&self) -> (usize, usize) { self.lexicon_memo.1.get() }
    pub(super) fn mark_nearby_candidate(&self, span: (usize, usize)) { self.lexicon_memo.1.set(span); }
}

/// 只缓存首词对应的词表；复制单元后重新按文字准备。
#[derive(Debug, Default)]
struct LexiconMemo(Option<Option<&'static [Phrase]>>, std::cell::Cell<(usize, usize)>);

impl Clone for LexiconMemo {
    fn clone(&self) -> Self { Self::default() }
}

pub(super) fn prepare_lexicon(units: &mut [Unit]) {
    for unit in units {
        if unit.lexicon_memo.0.is_none() {
            unit.lexicon_memo.0 = Some(prefix_phrases(&unit.text));
        }
    }
}

pub(super) fn reset_lexicon(unit: &mut Unit) {
    unit.lexicon_memo = LexiconMemo::default();
}

pub(super) fn units(f: &text::Folded) -> Vec<Unit> {
    let mut out: Vec<Unit> = Vec::new();
    let mut space = false;
    for t in tokens(f) {
        match t.kind {
            Kind::Space => space = true,
            Kind::Newline => {
                // 单个换行是软的（邮件会折行），只留一个「\n」单元记着这里换了行；连着的第二个换行（中间只有空白）
                // 把它升成「\n\n」：空行，段落边界。
                space = true;
                if let Some(last) = out.last_mut() {
                    if last.kind == UKind::Punct && last.text == "\n" {
                        last.text = "\n\n".to_owned();
                        last.end = t.end;
                        continue;
                    }
                    if last.kind == UKind::Punct && last.text == "\n\n" {
                        last.end = t.end;
                        continue;
                    }
                }
                out.push(Unit { text: "\n".to_owned(), kind: UKind::Punct, start: t.start, end: t.end, space_before: true, upper: false, capital: false, raw: "\n".to_owned(), evidence_memo: Default::default(), lexicon_memo: Default::default() });
            }
            Kind::Cjk => {
                for i in t.start..t.end {
                    out.push(Unit { text: f.chars[i].to_string(), kind: UKind::Cjk, start: i, end: i + 1, space_before: space && i == t.start, upper: false, capital: false, raw: f.original[i].to_string(), evidence_memo: Default::default(), lexicon_memo: Default::default() });
                }
                space = false;
            }
            kind => {
                let upper = kind == Kind::Word
                    && f.original[t.start..t.end].iter().filter(|c| c.is_alphabetic()).all(|c| c.is_uppercase());
                let capital = kind == Kind::Word && f.original[t.start].is_uppercase();
                let kind = match kind {
                    Kind::Word => UKind::Word,
                    Kind::Number => UKind::Number,
                    _ => UKind::Punct,
                };
                let raw = original_text(f, t.start, t.end);
                out.push(Unit { text: t.text, kind, start: t.start, end: t.end, space_before: space, upper, capital, raw, evidence_memo: Default::default(), lexicon_memo: Default::default() });
                space = false;
            }
        }
    }
    // 「a.m.」「p.m.」「a. m.」拼回一个单元（词表里写作 am / pm）：就地改首个单元，去掉被并进来的几个。
    let mut absorbed = Vec::new();
    let mut i = 0;
    while i < out.len() {
        if i + 2 < out.len()
            && (out[i].text == "a" || out[i].text == "p")
            && out[i + 1].text == "."
            && out[i + 2].text == "m"
        {
            let end = if i + 3 < out.len() && out[i + 3].text == "." { i + 3 } else { i + 2 };
            out[i].text = format!("{}m", out[i].text);
            out[i].end = out[end].end;
            absorbed.extend(i + 1..=end);
            i = end + 1;
            continue;
        }
        i += 1;
    }
    if !absorbed.is_empty() {
        let mut index = 0;
        let mut next = absorbed.iter().peekable();
        out.retain(|_| {
            let keep = next.peek() != Some(&&index);
            if !keep { next.next(); }
            index += 1;
            keep
        });
    }
    out
}

/// 折叠区间对应的原文（一个原文字符折成两个时 `original` 里重复，去掉相邻的重复位）。
pub(super) fn original_text(f: &text::Folded, start: usize, end: usize) -> String {
    let mut out = String::new();
    let mut last: Option<(usize, usize)> = None;
    for i in start..end {
        if last != Some(f.span[i]) {
            out.push(f.original[i]);
        }
        last = Some(f.span[i]);
    }
    out
}

// ───────────────────────────── 词表匹配 ─────────────────────────────

#[derive(Debug)]
pub(super) struct Phrase {
    pub(super) units: &'static [&'static str],
    pub(super) sems: &'static [(Sem, &'static str)],
}

pub(super) type ZoneWord = (&'static [&'static str], &'static str);
pub(super) type SemLanguages = (Sem, Slice<&'static str>);

pub(super) struct Matcher {
    pub(super) by_first: StrMap<[Phrase]>,
    pub(super) abbreviations: StrMap<usize>,
    pub(super) zone_words: StrMap<[ZoneWord]>,
    pub(super) sem_langs: WordsMap<[SemLanguages]>,
}

#[cfg(test)]
#[derive(Debug, PartialEq, Eq)]
struct ReferencePhrase {
    units: Vec<String>,
    sems: Vec<(Sem, &'static str)>,
}

#[cfg(test)]
#[derive(Debug, PartialEq, Eq)]
struct ReferenceMatcher {
    by_first: HashMap<String, Vec<ReferencePhrase>>,
    abbreviations: HashMap<String, usize>,
    zone_words: HashMap<String, Vec<(Vec<String>, &'static str)>>,
    sem_langs: HashMap<Vec<String>, Vec<(Sem, Vec<&'static str>)>>,
}

#[cfg(test)]
thread_local! {
    static LOOKUP_WORK: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
pub(super) fn reset_lookup_work() { LOOKUP_WORK.set(0); }

#[cfg(test)]
pub(super) fn snapshot_lookup_work() -> usize { LOOKUP_WORK.get() }

/// 短语切成单元：中日韩逐字，其余按空格（数字与字母分开：`thứ 2` → [thu, 2]）。
pub(super) fn phrase_units(folded: &str) -> Vec<String> {
    let mut out = Vec::new();
    for word in folded.split_whitespace() {
        let f = fold(word);
        for t in tokens(&f) {
            match t.kind {
                Kind::Space => {}
                Kind::Cjk => out.extend(t.text.chars().map(|c| c.to_string())),
                _ => out.push(t.text),
            }
        }
    }
    // 词表里的「a.m.」「p.m.」与单元里的合并形一致。
    let joined = out.join(" ");
    match joined.as_str() {
        "a . m" | "a . m ." => vec!["am".into()],
        "p . m" | "p . m ." => vec!["pm".into()],
        _ => out,
    }
}

pub(super) fn matcher() -> &'static Matcher {
    &super::generated_tables::MATCHER
}

#[cfg(test)]
fn reference_matcher() -> ReferenceMatcher {
        let mut by_text: HashMap<Vec<String>, Vec<(Sem, &'static str)>> = HashMap::new();
        let mut sem_langs: HashMap<Vec<String>, Vec<(Sem, Vec<&'static str>)>> = HashMap::new();
        for (phrase, sem, lang) in ENTRIES {
            let u = phrase_units(&fold_str(phrase));
            if u.is_empty() {
                continue;
            }
            let entry = by_text.entry(u.clone()).or_default();
            if !entry.iter().any(|(s, _)| s == sem) {
                entry.push((*sem, lang));
            }
            let langs = sem_langs.entry(u).or_default();
            match langs.iter().position(|(s, _)| s == sem) {
                Some(p) => {
                    if !langs[p].1.contains(lang) {
                        langs[p].1.push(*lang);
                    }
                }
                None => langs.push((*sem, vec![*lang])),
            }
        }
        let mut by_first: HashMap<String, Vec<ReferencePhrase>> = HashMap::new();
        for (u, sems) in by_text {
            by_first.entry(u[0].clone()).or_default().push(ReferencePhrase { units: u, sems });
        }
        for list in by_first.values_mut() {
            list.sort_by_key(|x| std::cmp::Reverse(x.units.len()));
        }
        let abbreviations = ABBREVIATIONS.iter().enumerate().map(|(i, a)| (a.text.to_lowercase(), i)).collect();
        let mut zone_words: HashMap<String, Vec<(Vec<String>, &'static str)>> = HashMap::new();
        for (word, iana) in super::lexicon::ZONE_WORDS.iter().chain(EXTRA_ZONE_WORDS) {
            let u = phrase_units(&fold_str(word));
            if let Some(first) = u.first().cloned() {
                zone_words.entry(first).or_default().push((u, iana));
            }
        }
        for list in zone_words.values_mut() {
            list.sort_by_key(|x| std::cmp::Reverse(x.0.len()));
        }
        // 初始化后只读，保留实际元素与列表顺序，收紧构造时的余量。
        for list in by_first.values_mut() {
            for phrase in list.iter_mut() {
                phrase.units.shrink_to_fit();
                phrase.sems.shrink_to_fit();
            }
            list.shrink_to_fit();
        }
        for list in sem_langs.values_mut() {
            for (_, languages) in list.iter_mut() { languages.shrink_to_fit(); }
            list.shrink_to_fit();
        }
        for list in zone_words.values_mut() {
            for (units, _) in list.iter_mut() { units.shrink_to_fit(); }
            list.shrink_to_fit();
        }
        by_first.shrink_to_fit();
        sem_langs.shrink_to_fit();
        zone_words.shrink_to_fit();
        ReferenceMatcher { by_first, abbreviations, zone_words, sem_langs }
}

/// 新加六种语言与几处常见说法的「X 时间」整词（`lexicon::ZONE_WORDS` 是十语时代的表）。
#[cfg(test)]
pub(super) const EXTRA_ZONE_WORDS: &[(&str, &str)] = &[
    ("ora italiana", "Europe/Rome"), ("ora di roma", "Europe/Rome"), ("ora di milano", "Europe/Rome"),
    ("nederlandse tijd", "Europe/Amsterdam"), ("amsterdamse tijd", "Europe/Amsterdam"), ("belgische tijd", "Europe/Brussels"),
    ("czasu polskiego", "Europe/Warsaw"), ("czasu warszawskiego", "Europe/Warsaw"), ("polskiego czasu", "Europe/Warsaw"),
    ("türkiye saati", "Europe/Istanbul"), ("türkiye saatiyle", "Europe/Istanbul"), ("tsi", "Europe/Istanbul"),
    ("giờ việt nam", "Asia/Ho_Chi_Minh"), ("giờ hà nội", "Asia/Bangkok"), ("giờ sài gòn", "Asia/Ho_Chi_Minh"),
    ("waktu indonesia barat", "Asia/Jakarta"), ("waktu indonesia tengah", "Asia/Makassar"), ("waktu indonesia timur", "Asia/Jayapura"),
    ("pacific", "America/Los_Angeles"), ("eastern", "America/New_York"), ("central", "America/Chicago"), ("mountain", "America/Denver"),
    ("us/pacific", "America/Los_Angeles"), ("us/eastern", "America/New_York"), ("us/central", "America/Chicago"),
    ("hora peninsular", "Europe/Madrid"), ("hora de canarias", "Atlantic/Canary"), ("hora canarias", "Atlantic/Canary"), ("heure française", "Europe/Paris"),
    ("heure de france", "Europe/Paris"), ("heure du québec", "America/Toronto"), ("mitteleuropäische zeit", "Europe/Berlin"),
    ("österreichische zeit", "Europe/Vienna"), ("schweizer zeit", "Europe/Zurich"), ("hora de brasil", "America/Sao_Paulo"),
    ("horário de verão", "America/Sao_Paulo"), ("moscow", "Europe/Moscow"),
];

/// 单元 `i` 起最长的、含义满足 `pred` 的词表短语：（长度，含义，语言）。
pub(super) fn find(units: &[Unit], i: usize, pred: impl Fn(Sem) -> bool) -> Option<(usize, Sem, &'static str)> {
    let first = units.get(i)?;
    let list = match first.lexicon_memo.0 {
        Some(list) => list,
        None => prefix_phrases(&first.text),
    }?;
    for phrase in list {
        let n = phrase.units.len();
        if i + n > units.len() {
            continue;
        }
        // 两个条件都要成立：先查词义（比较枚举），大多数短语在这里就排除，不必逐词比字符串。
        let Some(&(sem, lang)) = phrase.sems.iter().find(|(s, _)| pred(*s)) else { continue; };
        // 拉丁词要整词对上（「sat」不在「saturday」里），多词短语中间不能隔着标点以外的东西。
        if (0..n).all(|k| units[i + k].text == phrase.units[k]) {
            return Some((n, sem, lang));
        }
    }
    None
}

/// 附近地点的整词否决；普通名词按分句语言，虚词仍沿用原有名字规则。
pub(super) fn nearby_ordinary(units: &[Unit], start: usize, end: usize, language: &str) -> bool {
    let language = language.split(['-', '_']).next().unwrap_or(language);
    let Some(first) = units.get(start) else { return true; };
    let list = first.lexicon_memo.0.unwrap_or_else(|| prefix_phrases(&first.text));
    list.is_some_and(|list| list.iter().any(|phrase| phrase.units.len() == end - start
        && phrase.units.iter().zip(&units[start..end]).all(|(word, unit)| *word == unit.text)
        && phrase.sems.iter().any(|(sem, lang)| *sem != Sem::CommonNoun || *lang == language)))
}

fn prefix_phrases(text: &str) -> Option<&'static [Phrase]> {
    #[cfg(test)]
    LOOKUP_WORK.set(LOOKUP_WORK.get() + 1);
    matcher().by_first.get(text)
}

pub(super) fn is(units: &[Unit], i: usize, pred: impl Fn(Sem) -> bool) -> Option<usize> {
    find(units, i, pred).map(|(n, _, _)| n)
}

pub(super) fn number(u: &Unit) -> Option<u32> {
    if u.kind == UKind::Number && u.text.len() <= 9 {
        u.text.parse().ok()
    } else {
        None
    }
}

pub(super) fn is_punct(u: &Unit, c: &str) -> bool {
    u.kind == UKind::Punct && u.text == c
}

/// 数字后紧跟（不隔空白）。
pub(super) fn glued(units: &[Unit], i: usize) -> bool {
    units.get(i).is_some_and(|u| !u.space_before)
}

#[cfg(test)]
pub(super) fn generated_matcher_source() -> String {
    table_snapshot::declaration(&reference_matcher())
}

#[cfg(test)]
pub(super) fn audit_generated_matcher() {
    let mut expected = reference_matcher();
    for list in expected.by_first.values_mut() {
        list.sort_by(|a, b| b.units.len().cmp(&a.units.len()).then_with(|| a.units.cmp(&b.units)));
    }
    let actual = table_snapshot::reconstruct_compiled(matcher());
    assert_eq!(actual, expected,
        "compiled matcher differs from the original complete builder");
}

#[cfg(test)]
mod table_snapshot {
    use super::*;
    use super::super::table_generation::{sem_source, string_source};
    use std::collections::HashSet;
    use std::fmt::Write as _;

    fn words_source<S: AsRef<str>>(words: &[S]) -> String {
        let mut source = String::from("&[");
        for word in words { write!(source, "{},", string_source(word.as_ref())).unwrap(); }
        source.push(']');
        source
    }

    fn sems_source(sems: &[(Sem, &'static str)]) -> String {
        let mut source = String::from("&[");
        for (sem, language) in sems {
            write!(source, "({}, {}),", sem_source(*sem), string_source(language)).unwrap();
        }
        source.push(']');
        source
    }

    pub(super) fn declaration(table: &ReferenceMatcher) -> String {
        let mut source = String::from("pub(super) static MATCHER: Matcher = Matcher { by_first: StrMap { entries: &[\n");
        let mut first: Vec<_> = table.by_first.iter().collect();
        first.sort_by(|a, b| a.0.cmp(b.0));
        for (key, list) in first {
            writeln!(source, "({}, &[", string_source(key)).unwrap();
            let mut phrases: Vec<_> = list.iter().collect();
            // 同长度的不同完整键不能同时命中；只固定这部分目录顺序。
            phrases.sort_by(|a, b| b.units.len().cmp(&a.units.len()).then_with(|| a.units.cmp(&b.units)));
            assert!(phrases.windows(2).all(|pair| pair[0].units != pair[1].units), "duplicate normalized phrase");
            for phrase in phrases {
                writeln!(source, "UnitPhrase {{ units: {}, sems: {} }},",
                    words_source(&phrase.units), sems_source(&phrase.sems)).unwrap();
            }
            source.push_str("]),\n");
        }
        source.push_str("] }, abbreviations: StrMap { entries: &[\n");
        let mut abbreviations: Vec<_> = table.abbreviations.iter().collect();
        abbreviations.sort_by(|a, b| a.0.cmp(b.0));
        for (key, index) in abbreviations {
            writeln!(source, "({}, &{index}),", string_source(key)).unwrap();
        }
        source.push_str("] }, zone_words: StrMap { entries: &[\n");
        let mut zones: Vec<_> = table.zone_words.iter().collect();
        zones.sort_by(|a, b| a.0.cmp(b.0));
        for (key, list) in zones {
            write!(source, "({}, &[", string_source(key)).unwrap();
            // 列表由原厂稳定排序，重名与同长度项不再重排。
            for (words, iana) in list {
                write!(source, "({}, {}),", words_source(words), string_source(iana)).unwrap();
            }
            source.push_str("]),\n");
        }
        source.push_str("] }, sem_langs: WordsMap { entries: &[\n");
        let mut languages: Vec<_> = table.sem_langs.iter().collect();
        languages.sort_by(|a, b| a.0.cmp(b.0));
        for (words, sems) in languages {
            write!(source, "({}, &[", words_source(words)).unwrap();
            for (sem, languages) in sems {
                write!(source, "({}, Slice::Borrowed({})),", sem_source(*sem), words_source(languages)).unwrap();
            }
            source.push_str("]),\n");
        }
        source.push_str("] } };\n");
        source
    }

    fn assert_str_directory<V: ?Sized + 'static>(directory: &StrMap<V>) {
        assert!(directory.entries.windows(2).all(|pair| pair[0].0 < pair[1].0),
            "directory keys must be unique and strictly sorted");
        for (key, value) in directory.entries {
            assert!(std::ptr::eq(directory.get(key).expect("directory key must resolve"), *value));
            assert!(directory.contains_key(key));
        }
        let mut absent = String::from("\0missing");
        while directory.entries.iter().any(|(key, _)| *key == absent) { absent.push('\0'); }
        assert!(directory.get(&absent).is_none());
    }

    pub(super) fn reconstruct_compiled(table: &Matcher) -> ReferenceMatcher {
        assert_str_directory(&table.by_first);
        assert_str_directory(&table.abbreviations);
        assert_str_directory(&table.zone_words);
        assert!(table.sem_langs.entries.windows(2).all(|pair| pair[0].0 < pair[1].0),
            "full phrase directory keys must be unique and strictly sorted");
        let mut by_first = HashMap::new();
        let mut all_phrases = HashSet::new();
        for &(key, list) in table.by_first.entries {
            assert!(!list.is_empty(), "first-key list must not be empty");
            assert!(list.windows(2).all(|pair| {
                pair[0].units.len() > pair[1].units.len()
                    || pair[0].units.len() == pair[1].units.len() && pair[0].units < pair[1].units
            }), "phrase lists must have canonical longest-first order");
            let mut phrases = Vec::new();
            for phrase in list {
                assert_eq!(phrase.units.first().copied(), Some(key));
                assert!(all_phrases.insert(phrase.units), "duplicate complete phrase key");
                phrases.push(ReferencePhrase {
                    units: phrase.units.iter().map(|word| (*word).to_owned()).collect(),
                    sems: phrase.sems.to_vec(),
                });
            }
            by_first.insert(key.to_owned(), phrases);
        }
        let abbreviations = table.abbreviations.entries.iter().map(|&(key, index)| {
            assert!(*index < ABBREVIATIONS.len());
            (key.to_owned(), *index)
        }).collect();
        let mut zone_words = HashMap::new();
        for &(key, list) in table.zone_words.entries {
            assert!(list.windows(2).all(|pair| pair[0].0.len() >= pair[1].0.len()));
            let list = list.iter().map(|&(words, iana)| {
                assert_eq!(words.first().copied(), Some(key));
                (words.iter().map(|word| (*word).to_owned()).collect(), iana)
            }).collect();
            zone_words.insert(key.to_owned(), list);
        }
        let mut sem_langs = HashMap::new();
        for &(words, sems) in table.sem_langs.entries {
            assert!(all_phrases.remove(words), "semantic-language key absent from phrases");
            let lookup = table.sem_langs.get(words).expect("complete phrase key must resolve");
            assert!(std::ptr::eq(lookup, sems));
            sem_langs.insert(words.iter().map(|word| (*word).to_owned()).collect(),
                sems.iter().map(|(sem, languages)| (*sem, languages.to_vec())).collect());
        }
        assert!(all_phrases.is_empty(), "phrase lacks full semantic-language payload");
        assert!(table.sem_langs.get(&["\0missing"]).is_none());
        ReferenceMatcher { by_first, abbreviations, zone_words, sem_langs }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prepared_prefixes_preserve_predicates_and_phrase_boundaries() {
        let mut cached = units(&fold("years old qzxxyzz tomorrow and one"));
        let uncached = cached.clone();
        reset_lookup_work();
        prepare_lexicon(&mut cached);
        assert_eq!(snapshot_lookup_work(), cached.len());
        prepare_lexicon(&mut cached);
        assert_eq!(snapshot_lookup_work(), cached.len());
        assert!(matches!(cached[0].lexicon_memo.0, Some(Some(_))));
        assert!(matches!(cached[2].lexicon_memo.0, Some(None)));
        assert_eq!(find(&cached, 0, |s| s == Sem::NonTimeAfter).unwrap().0, 2);
        assert_eq!(find(&cached[..1], 0, |s| s == Sem::NonTimeAfter).unwrap().0, 1);
        assert_eq!(find(&cached, 2, |_| true), None);
        assert_eq!(snapshot_lookup_work(), cached.len());
        for end in 1..=cached.len() {
            for at in 0..end {
                assert_eq!(find(&cached[..end], at, |_| true), find(&uncached[..end], at, |_| true));
                for sem in [Sem::NonTimeAfter, Sem::And, Sem::RelDay(1), Sem::Number(1)] {
                    assert_eq!(find(&cached[..end], at, |s| s == sem), find(&uncached[..end], at, |s| s == sem));
                }
            }
        }
        let mut changed = cached.clone();
        assert!(changed.iter().all(|unit| unit.lexicon_memo.0.is_none()));
        changed[0].text = "qzxxyzz".to_owned();
        assert_eq!(find(&changed, 0, |_| true), None);
        prepare_lexicon(&mut changed);
        assert_eq!(find(&changed, 0, |_| true), None);
        assert_eq!(find(&cached, 0, |s| s == Sem::NonTimeAfter).unwrap().0, 2);
    }

    #[test]
    fn number_classification_invalidates_changed_prefixes() {
        let mut prepared = units(&fold("costs 3 dollars tomorrow"));
        let mut unprepared = prepared.clone();
        prepare_lexicon(&mut prepared);
        assert!(find(&prepared, 0, |s| s == Sem::NonTimeBefore).is_some());
        super::super::scan::classify_numbers(&mut prepared);
        super::super::scan::classify_numbers(&mut unprepared);
        assert!(prepared[..3].iter().all(|unit| unit.text.is_empty() && unit.lexicon_memo.0.is_none()));
        assert!(prepared[3].lexicon_memo.0.is_some());
        reset_lookup_work();
        prepare_lexicon(&mut prepared);
        assert_eq!(snapshot_lookup_work(), 3);
        for at in 0..prepared.len() {
            assert_eq!(find(&prepared, at, |_| true), find(&unprepared, at, |_| true));
        }
        assert_eq!(find(&prepared, 0, |_| true), None);
        assert!(find(&prepared, 3, |s| s == Sem::RelDay(1)).is_some());
    }
}
