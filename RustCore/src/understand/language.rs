// SPDX-License-Identifier: GPL-3.0-only
//! 弱词的独立语言证据：被解释的词与它引出的候选地点都不参与投票。
use super::lexicon::{Sem, ABBREVIATIONS};
#[cfg(test)]
use super::lexicon::ENTRIES;
use super::table_storage::{cmp_text, FastSet, Slice, Text};
use super::text::is_hangul;
#[cfg(test)]
use super::text::fold;
use super::units::{find, glued, UKind, Unit};
#[cfg(test)]
use super::units::units;
use std::borrow::Cow;
#[cfg(test)]
use std::collections::HashMap;
#[cfg(test)]
use std::collections::HashSet;
use std::num::NonZeroUsize;
use std::rc::Rc;
use std::sync::OnceLock;

/// 封闭的同形弱词表；新增词必须附碰撞反例，不能按语言或词类整批扩张。
/// mon/thu 是法语所有格、越南语普通词；hier 是荷语「这里」；once 是英语「一次」。
/// mo 撞越南语 mở（营业）；en 是西语地点介词，也是荷语连词。
/// di/in/do 等是别的语言的介词；mai/ago/sie/mar 是月名与相对日、方向、代词或星期的碰撞。
/// cze/czw 只匹配完整的波兰语缩写，不匹配 cz… 词首（如 czynna）。
/// due/sei/elf/on 的数词义撞英语或德语普通词；其余短星期词撞介词、普通词或其它表项。
/// 六个意语名词只用独立证据区分普通名词与同名地点。
const WEAK_WORDS: &[&str] = &[
    "mon", "thu", "hier", "once", "di", "in", "mai", "ago", "sie", "gen", "mar", "may", "mo", "en",
    "cze", "czw", "due", "sei", "elf", "on",
    "do", "mi", "so", "sa", "mer", "ven", "vie", "sab", "dom", "ter", "qua", "qui", "sex",
    "ma", "wo", "za", "zo", "sr", "pt", "sal", "car", "per", "cum", "sat", "sun",
    "forno", "piazza", "yoga", "foto", "stelle", "luci", "feira",
];

pub(super) fn needs_evidence(u: &[Unit], at: usize, len: usize) -> bool {
    static WORDS: OnceLock<FastSet<&'static str>> = OnceLock::new();
    len == 1 && u.get(at).is_some_and(|t| WORDS.get_or_init(|| WEAK_WORDS.iter().copied().collect()).contains(t.text.as_str()))
}

/// 只参与投票，不改变扫描器的词义或地点边界；繁简字形都保留原文。
#[cfg(test)]
const EXTRA_VOTERS: &[(&str, &str)] = &[
    ("这", "zh"), ("這", "zh"), ("点", "zh"), ("點", "zh"), ("边", "zh"), ("邊", "zh"),
    ("后", "zh"), ("後", "zh"), ("们", "zh"), ("們", "zh"), ("个", "zh"), ("個", "zh"),
    ("里", "zh"), ("裡", "zh"), ("吗", "zh"), ("嗎", "zh"), ("与", "zh"), ("與", "zh"),
    ("还", "zh"), ("還", "zh"), ("从", "zh"), ("從", "zh"), ("说", "zh"), ("說", "zh"),
    ("a", "pt"), ("as", "pt"), ("à", "pt"), ("às", "pt"), ("ao", "pt"), ("aos", "pt"),
    ("o", "pt"), ("os", "pt"), ("de", "pt"), ("do", "pt"), ("da", "pt"), ("dos", "pt"), ("das", "pt"),
    ("em", "pt"), ("no", "pt"), ("na", "pt"), ("nos", "pt"), ("nas", "pt"), ("para", "pt"),
    ("por", "pt"), ("com", "pt"), ("que", "pt"), ("e", "pt"), ("eu", "pt"), ("você", "pt"),
    ("vocês", "pt"), ("não", "pt"), ("também", "pt"), ("até", "pt"), ("é", "pt"), ("são", "pt"),
];

#[cfg(test)]
struct Entry {
    sem: Sem,
    language: &'static str,
    raw: Vec<String>,
}

/// 语言顺序与语法强度在词表装载时确定。
#[derive(Debug, PartialEq, Eq)]
pub(super) struct EntryGroup {
    pub(super) sem_languages: Slice<(Sem, Slice<&'static str>)>,
    pub(super) votes: Slice<(&'static str, bool)>,
}

impl EntryGroup {
    #[cfg(test)]
    fn new(entries: &[&Entry], english_abbreviation: bool) -> Self {
        let mut sem_languages: Vec<(Sem, Vec<&'static str>)> = Vec::new();
        let mut votes = Vec::new();
        let mut seen = HashSet::new();
        for entry in entries {
            if entry.language.is_empty() { continue; }
            let languages = match sem_languages.iter().position(|(sem, _)| *sem == entry.sem) {
                Some(index) => &mut sem_languages[index].1,
                None => {
                    sem_languages.push((entry.sem, Vec::new()));
                    &mut sem_languages.last_mut().unwrap().1
                }
            };
            if !languages.contains(&entry.language) { languages.push(entry.language); }
            if voter(entry.sem) && !(english_abbreviation && matches!(entry.sem, Sem::Weekday(_)))
                && seen.insert(entry.language) {
                let grammar = entries.iter().any(|e| e.language == entry.language && voter(e.sem)
                    && !matches!(e.sem, Sem::CommonNoun | Sem::Stop | Sem::Filler | Sem::Connector));
                votes.push((entry.language, grammar));
            }
        }
        for (_, languages) in &mut sem_languages { languages.shrink_to_fit(); }
        sem_languages.shrink_to_fit();
        votes.shrink_to_fit();
        Self {
            sem_languages: Slice::Owned(sem_languages.into_iter()
                .map(|(sem, languages)| (sem, Slice::Owned(languages.into_boxed_slice())))
                .collect()),
            votes: Slice::Owned(votes.into_boxed_slice()),
        }
    }

    fn languages(&self, sem: Sem) -> &[&'static str] {
        self.sem_languages.iter().find(|(candidate, _)| *candidate == sem)
            .map_or(&[], |(_, languages)| languages.as_slice())
    }
}

pub(super) struct Phrase {
    pub(super) len: usize,
    pub(super) entries: EntryGroup,
    pub(super) raw: RawGroups,
    pub(super) korean_clock: bool,
}

/// 单一原文拼法复用整组；多拼法仍逐项查表。
pub(super) enum RawGroups {
    Single(Slice<Text>),
    Multiple(Lookup<EntryGroup>),
}

#[cfg(test)]
struct LookupBuilderNode {
    children: HashMap<String, usize>,
    value: Option<NonZeroUsize>,
}

/// 逐单元查表，短语共享前缀只查一次。
#[cfg(test)]
struct LookupBuilder<T> {
    nodes: Vec<LookupBuilderNode>,
    values: Vec<T>,
}

#[cfg(test)]
impl<T: 'static> LookupBuilder<T> {
    fn new() -> Self {
        Self { nodes: vec![LookupBuilderNode { children: HashMap::new(), value: None }], values: Vec::new() }
    }

    fn insert(&mut self, text: &[String], value: T) {
        let mut at = 0;
        for word in text {
            at = match self.nodes[at].children.get(word) {
                Some(&child) => child,
                None => {
                    let child = self.nodes.len();
                    self.nodes.push(LookupBuilderNode { children: HashMap::new(), value: None });
                    self.nodes[at].children.insert(word.clone(), child);
                    child
                }
            };
        }
        match self.nodes[at].value {
            Some(index) => self.values[index.get() - 1] = value,
            None => {
                self.values.push(value);
                self.nodes[at].value = Some(NonZeroUsize::new(self.values.len()).expect("a stored value has a nonzero index"));
            }
        }
    }

    fn finish(self) -> Lookup<T> {
        let LookupBuilder { nodes: builder_nodes, values } = self;
        let mut nodes = Vec::with_capacity(builder_nodes.len());
        let mut edges = Vec::with_capacity(builder_nodes.len().saturating_sub(1));
        for node in builder_nodes {
            let start = edges.len();
            let mut children: Vec<_> = node.children.into_iter()
                .map(|(word, child)| (Text::Owned(word.into_boxed_str()), child)).collect();
            children.sort_unstable_by(|a, b| a.0.as_ref().cmp(b.0.as_ref()));
            edges.extend(children);
            let end = edges.len();
            nodes.push(LookupNode { start, end, value: node.value });
        }
        Lookup { nodes: Slice::Owned(nodes.into_boxed_slice()), edges: Slice::Owned(edges.into_boxed_slice()), values: Slice::Owned(values.into_boxed_slice()) }
    }
}

/// 初始化时用可变表；常驻结构只保留节点、边与终点值。
pub(super) struct LookupNode {
    pub(super) start: usize,
    pub(super) end: usize,
    pub(super) value: Option<NonZeroUsize>,
}

pub(super) struct Lookup<T: 'static> {
    pub(super) nodes: Slice<LookupNode>,
    pub(super) edges: Slice<(Text, usize)>,
    pub(super) values: Slice<T>,
}

impl<T: 'static> Lookup<T> {
    fn child(&self, node: usize, word: &str) -> Option<usize> {
        let node = &self.nodes[node];
        let edges = &self.edges[node.start..node.end];
        edges.binary_search_by(|(key, _)| cmp_text(key.as_ref(), word)).ok().map(|index| edges[index].1)
    }

    fn value(&self, node: usize) -> Option<&T> {
        self.nodes[node].value.map(|index| &self.values[index.get() - 1])
    }

    fn get<S: AsRef<str>>(&self, text: impl IntoIterator<Item = S>) -> Option<&T> {
        let mut at = 0;
        for word in text { at = self.child(at, word.as_ref())?; }
        self.value(at)
    }
}

fn raw_lowercase(raw: &str) -> Cow<'_, str> {
    if raw.is_ascii() {
        if raw.bytes().any(|c| c.is_ascii_uppercase()) { Cow::Owned(raw.to_ascii_lowercase()) }
        else { Cow::Borrowed(raw) }
    } else { Cow::Owned(raw.to_lowercase()) }
}

/// `word == raw_lowercase(raw)`；ASCII 原文逐字节比较，不必先分配小写副本。
fn equals_raw_lowercase(word: &str, raw: &str) -> bool {
    if raw.is_ascii() {
        word.len() == raw.len() && word.bytes().zip(raw.bytes()).all(|(w, r)| w == r.to_ascii_lowercase())
    } else {
        word == raw.to_lowercase()
    }
}

impl Phrase {
    fn raw_entries(&self, u: &[Unit], at: usize) -> Option<&EntryGroup> {
        let span = &u[at..at + self.len];
        match &self.raw {
            RawGroups::Single(key) => {
                (key.len() == span.len() && key.iter().zip(span)
                    .all(|(word, unit)| equals_raw_lowercase(word.as_ref(), &unit.raw)))
                    .then_some(&self.entries)
            }
            RawGroups::Multiple(raw) => raw.get(span.iter().map(|t| raw_lowercase(&t.raw))),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Evidence {
    Unknown,
    Conflicting,
    Language(&'static str, bool),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct EvidenceKey {
    slice: usize,
    units: usize,
    len: usize,
    excluded: Option<(usize, usize)>,
}

/// 只在单元不再修改后启用；复制单元时不继承原句的缓存。
/// 第二格挂在句段首个单元上：这一句段里每个位置可投票的短语（与被解释的词无关的筛选已做完）。
#[derive(Debug, Default)]
pub(super) struct EvidenceMemo(std::cell::RefCell<Option<Vec<(EvidenceKey, Evidence)>>>, std::cell::RefCell<Vec<SegmentVoters>>);

impl Clone for EvidenceMemo {
    fn clone(&self) -> Self { Self::default() }
}

/// 一个句段（`start..end`）内各位置按长度从长到短排好的候选投票短语：（单元数，拼法选定的词条组）。
#[derive(Debug)]
pub(super) struct SegmentVoters {
    slice: usize,
    units: usize,
    end: usize,
    at: Rc<[Vec<(usize, &'static EntryGroup)>]>,
}

/// 数字段分类完成后启用，生命周期与这次解析的单元相同。
pub(super) fn enable_memos(u: &[Unit]) {
    for unit in u {
        *unit.evidence_memo.0.borrow_mut() = Some(Vec::new());
    }
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct EvidenceWork {
    pub evidence_calls: usize,
    pub evidence_units: usize,
}

#[cfg(test)]
thread_local! {
    static EVIDENCE_WORK: std::cell::Cell<EvidenceWork> = const { std::cell::Cell::new(EvidenceWork { evidence_calls: 0, evidence_units: 0 }) };
}

#[cfg(test)]
pub(super) fn reset_work() { EVIDENCE_WORK.set(EvidenceWork::default()); }

#[cfg(test)]
pub(super) fn snapshot_work() -> EvidenceWork { EVIDENCE_WORK.get() }

#[cfg(test)]
fn add_work(update: impl FnOnce(&mut EvidenceWork)) {
    let mut work = EVIDENCE_WORK.get();
    update(&mut work);
    EVIDENCE_WORK.set(work);
}

impl Evidence {
    pub(super) fn is_unknown(self) -> bool { matches!(self, Self::Unknown) }
    pub(super) fn has_grammar(self) -> bool { matches!(self, Self::Language(_, true) | Self::Conflicting) }
}

fn phrases() -> &'static Lookup<Phrase> {
    &super::generated_tables::LANGUAGE
}

#[cfg(test)]
fn reference_phrase_table() -> Lookup<Phrase> {
        let mut grouped: HashMap<Vec<String>, Vec<Entry>> = HashMap::new();
        for (phrase, sem, language) in ENTRIES.iter().copied()
            .chain(EXTRA_VOTERS.iter().map(|&(phrase, language)| (phrase, Sem::Filler, language))) {
            let u = units(&fold(phrase));
            let text: Vec<String> = u.iter().map(|t| t.text.clone()).collect();
            if text.is_empty() { continue; }
            grouped.entry(text).or_default().push(Entry {
                sem,
                language,
                raw: u.iter().map(|t| t.raw.to_lowercase()).collect(),
            });
        }
        let mut table = LookupBuilder::new();
        for (text, entries) in grouped {
            let english_abbreviation = text.len() == 1 && matches!(text[0].as_str(),
                "mon" | "tue" | "tues" | "wed" | "thu" | "thur" | "thurs" | "fri" | "sat" | "sun");
            let mut by_raw: HashMap<&[String], Vec<&Entry>> = HashMap::new();
            for entry in &entries { by_raw.entry(&entry.raw).or_default().push(entry); }
            let phrase_entries = EntryGroup::new(&entries.iter().collect::<Vec<_>>(), english_abbreviation);
            let raw = if by_raw.len() == 1 {
                let (key, _) = by_raw.into_iter().next().expect("one raw group has one key");
                RawGroups::Single(Slice::Owned(key.iter().map(|word| Text::Owned(word.clone().into_boxed_str())).collect()))
            } else {
                let mut raw = LookupBuilder::new();
                for (key, same_raw) in by_raw { raw.insert(key, EntryGroup::new(&same_raw, english_abbreviation)); }
                RawGroups::Multiple(raw.finish())
            };
            let phrase = Phrase {
                len: text.len(),
                entries: phrase_entries,
                raw,
                korean_clock: entries.iter().any(|e| e.language == "ko" && e.sem == Sem::ClockAfter),
            };
            table.insert(&text, phrase);
        }
        table.finish()
}

fn matching_phrases(u: &[Unit], at: usize, end: usize) -> Vec<&'static Phrase> {
    let table = phrases();
    let mut node = 0;
    let mut result = Vec::new();
    for unit in &u[at..end] {
        let Some(next) = table.child(node, unit.text.as_str()) else { break; };
        node = next;
        if let Some(phrase) = table.value(node) { result.push(phrase); }
    }
    result
}

/// 原文拼法先选整组，再按含义取语言，保留词表里的先后次序。
fn languages<'a>(u: &[Unit], at: usize, p: &'a Phrase, sem: Sem) -> &'a [&'static str] {
    p.raw_entries(u, at).unwrap_or(&p.entries).languages(sem)
}

fn dotted_abbreviation(u: &[Unit], at: usize) -> bool {
    let letter = |i: usize| u.get(i).is_some_and(|t| t.kind == UKind::Word && t.text.chars().count() == 1);
    at > 0 && letter(at - 1)
        && ((!u[at].space_before && letter(at + 1) && !u[at + 1].space_before)
            || (at > 2 && u[at - 2].text == "." && letter(at - 3) && !u[at - 1].space_before))
}

fn boundary(u: &[Unit], at: usize) -> bool {
    let t = &u[at];
    if t.kind != UKind::Punct { return false; }
    match t.text.as_str() {
        "\n\n" | "!" | "?" | ";" | "。" | "；" | "！" | "？" | "|" => true,
        "/" => t.space_before || u.get(at + 1).is_some_and(|n| n.space_before),
        "." => !dotted_abbreviation(u, at)
            && !u.get(at + 1).is_some_and(|n| n.kind == UKind::Number && !n.space_before),
        _ => false,
    }
}

fn overlaps(a: usize, b: usize, excluded: (usize, usize)) -> bool {
    a < excluded.1 && excluded.0 < b
}

#[cfg(test)]
fn voter(sem: Sem) -> bool {
    // 这些弱读法不能互相证明；数字、时区名与城市查询结果也不投票。
    !matches!(sem, Sem::Number(_) | Sem::TrAcc(_) | Sem::TrDat(_) | Sem::Month(_)
        | Sem::WeekdayAbbr(_) | Sem::UnixCue | Sem::FractionMeasure)
}

fn neutral_word(u: &[Unit], at: usize, len: usize) -> bool {
    static WORDS: OnceLock<FastSet<&'static str>> = OnceLock::new();
    len == 1 && (WORDS.get_or_init(|| ABBREVIATIONS.iter().map(|a| a.text).collect()).contains(u[at].raw.as_str())
        || matches!(u[at].text.as_str(), "usd" | "gbp" | "eur" | "pln" | "tl" | "kg" | "cm" | "yoga" | "deadline" | "am" | "pm" | "h" | "g" | "年" | "月" | "日"))
}

/// 专名内部的连接词属于地点名字，不能证明整句的语言。
fn inside_place_name(u: &[Unit], at: usize, len: usize) -> bool {
    len == 1 && at > 0 && at + 1 < u.len()
        && matches!(u[at].text.as_str(), "di" | "del" | "de" | "da" | "do" | "della" | "du" | "des" | "van" | "von" | "of" | "en" | "sur")
        && !u[at].capital && u[at - 1].kind == UKind::Word && u[at - 1].capital
        && u[at + 1].kind == UKind::Word && u[at + 1].capital
}

/// 完整钟点后的助词与系词；不接受任意词内余下的音节。
pub(super) fn korean_clock_particle(suffix: &str) -> bool {
    matches!(suffix, "" | "에" | "에는" | "는" | "쯤" | "경" | "부터" | "까지" | "입니다" | "부터입니다"
        | "까지예요" | "부터는" | "까지는" | "예요" | "이에요" | "이고" | "이야" | "쯤에" | "경에")
}

/// 谚文逐字切分，但投票词仍须完整；钟点的 시 可紧接小时数词并带助词。
fn whole_hangul_voter(u: &[Unit], at: usize, p: &Phrase) -> bool {
    let hangul = |t: &Unit| !t.raw.is_empty() && t.raw.chars().all(is_hangul);
    let end = at + p.len;
    if !hangul(&u[at]) && !hangul(&u[end - 1]) { return true; }
    let mut start = at;
    while start > 0 && glued(u, start) && hangul(&u[start - 1]) { start -= 1; }
    if start != at {
        let clock_suffix = p.korean_clock;
        let hour_prefix = find(u, start, |s| matches!(s, Sem::Number(1..=12)))
            .is_some_and(|(n, _, language)| language == "ko" && start + n == at);
        if !clock_suffix || !hour_prefix { return false; }
    }
    let mut tail = end;
    while tail < u.len() && glued(u, tail) && hangul(&u[tail]) { tail += 1; }
    let suffix: String = u[end..tail].iter().map(|t| t.raw.as_str()).collect();
    let suffix = if p.korean_clock {
        suffix.strip_prefix('반').unwrap_or(&suffix)
    } else { &suffix };
    korean_clock_particle(suffix)
}

/// 用同一句段里的独立词语与语法判断语言。共用词给各语言分别计分，并列时弃权。
pub(super) fn evidence(u: &[Unit], at: usize, len: usize, excluded: Option<(usize, usize)>) -> Evidence {
    if at >= u.len() || len == 0 || at + len > u.len() { return Evidence::Unknown; }
    let key = EvidenceKey { slice: u.as_ptr() as usize, units: u.len(), len, excluded };
    let memo = &u[at].evidence_memo.0;
    if let Some(result) = memo.borrow().as_ref().and_then(|entries| entries.iter().find(|(k, _)| *k == key).map(|(_, result)| *result)) {
        return result;
    }
    let result = evidence_uncached(u, at, len, excluded);
    if let Some(entries) = memo.borrow_mut().as_mut() {
        entries.push((key, result));
    }
    result
}

/// 句段内一个位置的候选投票短语，从长到短；只做与被解释的词无关的筛选。
fn position_voters(u: &[Unit], k: usize, end: usize) -> Vec<(usize, &'static EntryGroup)> {
    matching_phrases(u, k, end).into_iter().rev().filter_map(|p| {
        let n = p.len;
        if needs_evidence(u, k, n) || neutral_word(u, k, n) || inside_place_name(u, k, n) || !whole_hangul_voter(u, k, p) { return None; }
        // 货币与时区缩写、数字串和标点不证明语言。
        if u[k..k + n].iter().any(|t| t.kind == UKind::Number)
            || !u[k..k + n].iter().any(|t| t.raw.chars().any(char::is_alphabetic)) {
            return None;
        }
        let group = p.raw_entries(u, k)?;
        (!group.votes.is_empty()).then_some((n, group))
    }).collect()
}

/// 同一句段反复判断不同的词时，各位置的候选只算一次（缓存启用后挂在句段首个单元上）。
/// 计算与读取时都不持有借用：词表查询可能再回到这里。
fn segment_voters(u: &[Unit], start: usize, end: usize) -> Rc<[Vec<(usize, &'static EntryGroup)>]> {
    let compute = || (start..end).map(|k| position_voters(u, k, end)).collect::<Rc<[_]>>();
    let anchor = &u[start].evidence_memo;
    if anchor.0.borrow().is_none() { return compute(); }
    let (slice, units) = (u.as_ptr() as usize, u.len());
    let hit = anchor.1.borrow().iter().find(|s| s.slice == slice && s.units == units && s.end == end).map(|s| Rc::clone(&s.at));
    if let Some(at) = hit { return at; }
    let at = compute();
    anchor.1.borrow_mut().push(SegmentVoters { slice, units, end, at: Rc::clone(&at) });
    at
}

fn evidence_uncached(u: &[Unit], at: usize, len: usize, excluded: Option<(usize, usize)>) -> Evidence {
    #[cfg(test)]
    add_work(|work| work.evidence_calls += 1);
    let start = (0..at).rev().find(|&k| boundary(u, k)).map_or(0, |k| k + 1);
    let end = (at + len..u.len()).find(|&k| boundary(u, k)).unwrap_or(u.len());
    let dispute = (at, at + len);
    let blocked = |a, b| overlaps(a, b, dispute) || excluded.is_some_and(|e| overlaps(a, b, e));
    // 语言很少，按出现先后存；并列最高分时弃权，所以与先后次序无关。
    let mut scores: Vec<(&'static str, (usize, bool))> = Vec::new();
    let mut exclusive = None;
    let mut conflict = false;
    let voters = segment_voters(u, start, end);
    {
        let mut k = start;
        while k < end {
            #[cfg(test)]
            add_work(|work| work.evidence_units += 1);
            if blocked(k, k + 1) { k += 1; continue; }
            // 不同文字系统可构成局部句段；英文会议用语不能证明夹在其中的中日韩日词。
            if u[at].kind == UKind::Cjk && u[k].kind != UKind::Cjk { k += 1; continue; }
            let mut consumed = 1;
            for &(n, group) in &voters[k - start] {
                if blocked(k, k + n) { continue; }
                let unshared = group.votes.len() == 1;
                let mut strong = None;
                let mut strong_count = 0;
                for &(language, grammar) in &group.votes {
                    let score = match scores.iter().position(|(l, _)| *l == language) {
                        Some(index) => &mut scores[index].1,
                        None => { scores.push((language, (0, false))); &mut scores.last_mut().unwrap().1 }
                    };
                    score.0 += if n > 1 { 3 } else if grammar { 2 } else { 1 };
                    score.1 |= grammar;
                    if grammar { strong = Some(language); strong_count += 1; }
                }
                if unshared && strong_count == 1 {
                    let language = strong.unwrap();
                    conflict |= exclusive.is_some_and(|previous| previous != language);
                    exclusive = Some(language);
                }
                consumed = n;
                break;
            }
            k += consumed;
        }
    }
    if conflict { return Evidence::Conflicting; }
    let Some(&(language, (best, grammar))) = scores.iter().max_by_key(|(_, score)| score.0) else { return Evidence::Unknown };
    if scores.iter().any(|&(other, (score, _))| other != language && score == best) { Evidence::Unknown }
    else { Evidence::Language(language, grammar) }
}

/// 这个含义有独立证据支持时，返回相应语言。
pub(super) fn supported_language(u: &[Unit], at: usize, len: usize, sem: Sem, excluded: Option<(usize, usize)>) -> Option<&'static str> {
    let span = u.get(at..at.checked_add(len)?)?;
    let p = phrases().get(span.iter().map(|t| t.text.as_str()))?;
    let langs = languages(u, at, p, sem);
    if let Evidence::Language(language, _) = evidence(u, at, len, excluded) {
        if langs.contains(&language) { return Some(language); }
    }
    // 唯一含义（包括多语共享同一个数值）不需要投票；投票只可选语言标签，不能取消读法。
    if needs_evidence(u, at, len) { None } else { langs.first().copied() }
}

pub(super) fn fits(u: &[Unit], at: usize, len: usize, sem: Sem, excluded: Option<(usize, usize)>) -> bool {
    supported_language(u, at, len, sem, excluded).is_some()
}

/// 普通名词只在它自己的语言得到独立证据时挡住地点读取。
pub(super) fn ordinary_noun(u: &[Unit], at: usize) -> bool {
    find(u, at, |s| s == Sem::CommonNoun)
        .is_some_and(|(len, sem, lang)| {
            // Lowercase «районе» describes a district. Capitalized «Районе»
            // can explicitly name Rayón, whose stored alias must stay usable.
            !(lang == "ru" && u[at].text == "раионе" && u[at].capital)
                // Feira 单独是集市；完整的大写地名仍交给精确索引查询。
                && !(lang == "pt" && u[at].text == "feira" && u[at].capital
                    && u.get(at + 1).is_some_and(|unit| unit.text == "de")
                    && u.get(at + 2).is_some_and(|unit| unit.capital))
                && fits(u, at, len, sem, None)
        })
}

#[cfg(test)]
pub(super) fn generated_language_source() -> String {
    table_snapshot::declaration(&reference_phrase_table())
}

#[cfg(test)]
pub(super) fn audit_generated_language() {
    let expected = reference_phrase_table();
    table_snapshot::assert_borrowed(phrases());
    table_snapshot::assert_equivalent(phrases(), &expected);
}

#[cfg(test)]
mod table_snapshot {
    use super::*;
    use super::super::table_generation::{sem_source, string_source};
    use std::fmt::Write as _;

    struct Canonical<'a, T: 'static> {
        nodes: Vec<(usize, usize, Option<usize>)>,
        edges: Vec<(String, usize)>,
        values: Vec<&'a T>,
    }

    // 仅重排节点身份；边与终点的完整内容都参与核对。
    fn canonical<T: 'static>(table: &Lookup<T>) -> Canonical<'_, T> {
        assert!(!table.nodes.is_empty(), "lookup must contain its root");
        let mut edge_end = 0;
        for node in &table.nodes {
            assert_eq!(node.start, edge_end, "edge ranges must cover the arena exactly once");
            assert!(node.start <= node.end && node.end <= table.edges.len(), "invalid edge range");
            let children = &table.edges[node.start..node.end];
            assert!(children.windows(2).all(|w| w[0].0.as_ref() < w[1].0.as_ref()),
                "edges must be unique and strictly sorted");
            edge_end = node.end;
        }
        assert_eq!(edge_end, table.edges.len(), "unowned edges");
        let mut old_ids = vec![0];
        let mut seen = vec![false; table.nodes.len()];
        seen[0] = true;
        let mut used_values = vec![false; table.values.len()];
        let mut nodes = Vec::new();
        let mut edges = Vec::new();
        let mut values = Vec::new();
        let mut at = 0;
        while at < old_ids.len() {
            let old = &table.nodes[old_ids[at]];
            let value = old.value.map(|index| {
                let index = index.get() - 1;
                assert!(index < table.values.len(), "terminal outside value arena");
                assert!(!used_values[index], "terminal value cannot have multiple owners");
                used_values[index] = true;
                values.push(&table.values[index]);
                values.len()
            });
            let start = edges.len();
            for (word, child) in &table.edges[old.start..old.end] {
                assert!(*child < table.nodes.len(), "child outside node arena");
                assert!(!seen[*child], "cycle or multiply owned child");
                seen[*child] = true;
                let new_id = old_ids.len();
                old_ids.push(*child);
                edges.push((word.as_ref().to_owned(), new_id));
            }
            nodes.push((start, edges.len(), value));
            at += 1;
        }
        assert!(seen.into_iter().all(|used| used), "unreachable lookup node");
        assert!(used_values.into_iter().all(|used| used), "unreachable terminal value");
        Canonical { nodes, edges, values }
    }

    fn lookup_source<T: 'static>(table: &Lookup<T>, value_source: impl Fn(&T) -> String) -> String {
        let canonical = canonical(table);
        let mut result = String::from("Lookup { nodes: Slice::Borrowed(&[\n");
        for (start, end, value) in canonical.nodes {
            let value = value.map_or_else(|| "None".to_owned(), |index| format!("NonZeroUsize::new({index})"));
            writeln!(result, "LookupNode {{ start: {start}, end: {end}, value: {value} }},").unwrap();
        }
        result.push_str("]), edges: Slice::Borrowed(&[\n");
        for (word, child) in canonical.edges {
            writeln!(result, "(Text::Borrowed({}), {child}),", string_source(&word)).unwrap();
        }
        result.push_str("]), values: Slice::Borrowed(&[\n");
        for value in canonical.values { writeln!(result, "{},", value_source(value)).unwrap(); }
        result.push_str("]) }");
        result
    }

    fn group_source(group: &EntryGroup) -> String {
        let mut result = String::from("EntryGroup { sem_languages: Slice::Borrowed(&[");
        for (sem, languages) in &group.sem_languages {
            write!(result, "({}, Slice::Borrowed(&[", sem_source(*sem)).unwrap();
            for language in languages { write!(result, "{},", string_source(language)).unwrap(); }
            result.push_str("])),");
        }
        result.push_str("]), votes: Slice::Borrowed(&[");
        for (language, grammar) in &group.votes {
            write!(result, "({}, {grammar}),", string_source(language)).unwrap();
        }
        result.push_str("]) }");
        result
    }

    fn phrase_source(phrase: &Phrase) -> String {
        let raw = match &phrase.raw {
            RawGroups::Single(key) => {
                let mut result = String::from("RawGroups::Single(Slice::Borrowed(&[");
                for word in key { write!(result, "Text::Borrowed({}),", string_source(word.as_ref())).unwrap(); }
                result.push_str("]))");
                result
            }
            RawGroups::Multiple(table) => format!("RawGroups::Multiple({})", lookup_source(table, group_source)),
        };
        format!("LanguagePhrase {{ len: {}, entries: {}, raw: {raw}, korean_clock: {} }}",
            phrase.len, group_source(&phrase.entries), phrase.korean_clock)
    }

    pub(super) fn declaration(table: &Lookup<Phrase>) -> String {
        format!("pub(super) static LANGUAGE: Lookup<LanguagePhrase> = {};\n", lookup_source(table, phrase_source))
    }

    fn compare_lookup<T: 'static>(actual: &Lookup<T>, expected: &Lookup<T>, compare_value: impl Fn(&T, &T)) {
        let actual = canonical(actual);
        let expected = canonical(expected);
        assert_eq!(actual.nodes, expected.nodes, "complete trie nodes/terminal ranges differ");
        assert_eq!(actual.edges, expected.edges, "complete trie edge keys/child paths differ");
        assert_eq!(actual.values.len(), expected.values.len());
        for (actual, expected) in actual.values.into_iter().zip(expected.values) {
            compare_value(actual, expected);
        }
    }

    pub(super) fn assert_equivalent(actual: &Lookup<Phrase>, expected: &Lookup<Phrase>) {
        compare_lookup(actual, expected, |actual, expected| {
            assert_eq!(actual.len, expected.len, "phrase length differs");
            assert_eq!(actual.korean_clock, expected.korean_clock);
            assert_eq!(actual.entries, expected.entries, "ordered language/vote payload differs");
            match (&actual.raw, &expected.raw) {
                (RawGroups::Single(actual), RawGroups::Single(expected)) => {
                    let actual: Vec<_> = actual.iter().map(AsRef::as_ref).collect();
                    let expected: Vec<_> = expected.iter().map(AsRef::as_ref).collect();
                    assert_eq!(actual, expected, "exact raw spelling differs");
                }
                (RawGroups::Multiple(actual), RawGroups::Multiple(expected)) => {
                    compare_lookup(actual, expected, |actual, expected| assert_eq!(actual, expected));
                }
                _ => panic!("raw group sharing distinction differs"),
            }
        });
    }

    fn borrowed_lookup<T: 'static>(table: &Lookup<T>) {
        assert!(matches!(&table.nodes, Slice::Borrowed(_)));
        assert!(matches!(&table.edges, Slice::Borrowed(_)));
        assert!(matches!(&table.values, Slice::Borrowed(_)));
        assert!(table.edges.iter().all(|(key, _)| matches!(key, Text::Borrowed(_))));
        let canonical = canonical(table);
        for (node, &(start, end, value)) in table.nodes.iter().zip(&canonical.nodes) {
            assert_eq!((node.start, node.end, node.value.map(NonZeroUsize::get)), (start, end, value),
                "compiled node identities and edge ranges must be canonical");
        }
        for ((word, child), (expected_word, expected_child)) in table.edges.iter().zip(&canonical.edges) {
            assert_eq!((word.as_ref(), child), (expected_word.as_str(), expected_child));
        }
    }

    fn borrowed_group(group: &EntryGroup) {
        assert!(matches!(&group.sem_languages, Slice::Borrowed(_)));
        assert!(matches!(&group.votes, Slice::Borrowed(_)));
        assert!(group.sem_languages.iter().all(|(_, languages)| matches!(languages, Slice::Borrowed(_))));
    }

    pub(super) fn assert_borrowed(table: &Lookup<Phrase>) {
        borrowed_lookup(table);
        for phrase in &table.values {
            borrowed_group(&phrase.entries);
            match &phrase.raw {
                RawGroups::Single(key) => {
                    assert!(matches!(key, Slice::Borrowed(_)));
                    assert!(key.iter().all(|word| matches!(word, Text::Borrowed(_))));
                    assert_eq!(key.len(), phrase.len);
                }
                RawGroups::Multiple(raw) => {
                    borrowed_lookup(raw);
                    for group in &raw.values { borrowed_group(group); }
                }
            }
        }
    }

    #[test]
    #[should_panic(expected = "phrase length differs")]
    fn semantic_audit_rejects_a_changed_reference_phrase_length() {
        let mut reference = reference_phrase_table();
        match &mut reference.values {
            Slice::Owned(values) => values[0].len += 1,
            Slice::Borrowed(_) => panic!("reference builder must own its values"),
        }
        assert_equivalent(phrases(), &reference);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frozen_lookup_keeps_empty_and_nonterminal_paths() {
        let empty = LookupBuilder::<usize>::new().finish();
        assert_eq!(empty.get(std::iter::empty::<&str>()), None);
        assert_eq!(empty.get(["missing"]), None);
        let mut builder = LookupBuilder::new();
        builder.insert(&["parent".to_owned(), "child".to_owned()], 9);
        let table = builder.finish();
        assert_eq!(table.get(["parent"]), None);
        assert_eq!(table.get(["parent", "child"]), Some(&9));
    }

    #[test]
    fn frozen_lookup_keeps_unordered_siblings_at_each_depth() {
        let mut builder = LookupBuilder::new();
        let keys = ["zebra", "東京", "alpha", "βeta", "middle", "école"];
        for (index, key) in keys.iter().enumerate() {
            builder.insert(&[(*key).to_owned()], index);
            for (child_index, child) in keys.iter().enumerate().rev() {
                builder.insert(&[(*key).to_owned(), (*child).to_owned()], 100 + index * 10 + child_index);
            }
        }
        let table = builder.finish();
        for (index, key) in keys.iter().enumerate() {
            assert_eq!(table.get([*key]), Some(&index));
            for (child_index, child) in keys.iter().enumerate() {
                assert_eq!(table.get([*key, *child]), Some(&(100 + index * 10 + child_index)));
            }
        }
        assert_eq!(table.get(["other"]), None);
    }

    #[test]
    fn frozen_lookup_keeps_empty_prefix_replacement_unicode_and_missing_paths() {
        let key = |words: &[&str]| words.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
        let mut builder = LookupBuilder::new();
        builder.insert(&key(&[]), 7);
        builder.insert(&key(&["am"]), 1);
        builder.insert(&key(&["am", "pm"]), 2);
        builder.insert(&key(&["東京"]), 3);
        builder.insert(&key(&["am"]), 4);
        let table = builder.finish();
        assert_eq!(table.get(std::iter::empty::<&str>()), Some(&7));
        assert_eq!(table.get(["am"]), Some(&4));
        assert_eq!(table.get(["am", "pm"]), Some(&2));
        assert_eq!(table.get(["東京"]), Some(&3));
        assert_eq!(table.get(["missing"]), None);
        assert_eq!(table.get(["am", "東京"]), None);
        assert_eq!(table.get(["am", "pm", "tail"]), None);
    }

    fn reference_phrases() -> HashMap<Vec<String>, Vec<Entry>> {
        let mut result: HashMap<Vec<String>, Vec<Entry>> = HashMap::new();
        for (phrase, sem, language) in ENTRIES.iter().copied()
            .chain(EXTRA_VOTERS.iter().map(|&(text, language)| (text, Sem::Filler, language))) {
            let phrase_units = units(&fold(phrase));
            let text: Vec<_> = phrase_units.iter().map(|u| u.text.clone()).collect();
            if !text.is_empty() {
                result.entry(text).or_default().push(Entry {
                    sem, language, raw: phrase_units.iter().map(|u| u.raw.to_lowercase()).collect(),
                });
            }
        }
        result
    }

    fn reference_raw_matches(u: &[Unit], entry: &Entry) -> bool {
        entry.raw.iter().zip(u).all(|(text, unit)| {
            if unit.raw.is_ascii() { unit.raw.eq_ignore_ascii_case(text) }
            else { unit.raw.to_lowercase() == *text }
        })
    }

    #[test]
    fn prepared_phrases_match_linear_prefixes_and_input_slices() {
        let reference = reference_phrases();
        let mut by_first: HashMap<&str, Vec<&Vec<String>>> = HashMap::new();
        for phrase in reference.keys() { by_first.entry(&phrase[0]).or_default().push(phrase); }
        for (text, entries) in &reference {
            let original = entries[0].raw.join(" ");
            for variant in [original.clone(), original.to_uppercase(), text.join(" ")] {
                let u = units(&fold(&format!("qzxxyzz {variant} qzxxyzz")));
                for end in 1..=u.len() {
                    for at in 0..end {
                        let mut expected: Vec<_> = by_first.get(u[at].text.as_str()).into_iter().flatten().filter(|phrase| {
                            at + phrase.len() <= end && phrase.iter().enumerate().all(|(i, word)| u[at + i].text == *word)
                        }).map(|phrase| phrase.len()).collect();
                        expected.sort_unstable_by(|a, b| b.cmp(a));
                        let actual: Vec<_> = matching_phrases(&u[..end], at, end).into_iter().rev().map(|phrase| phrase.len).collect();
                        assert_eq!(actual, expected, "{variant}: {at}..{end}");
                    }
                }
            }
        }
    }

    #[test]
    fn prepared_raw_groups_preserve_accent_semantics_and_language_order() {
        let reference = reference_phrases();
        for (text, entries) in &reference {
            let p = phrases().get(text.iter()).unwrap();
            assert_eq!(p.korean_clock, entries.iter().any(|e| e.language == "ko" && e.sem == Sem::ClockAfter));
            for entry in entries {
                let original = entry.raw.join(" ");
                for variant in [original.clone(), original.to_uppercase(), text.join(" ")] {
                    let u = units(&fold(&variant));
                    if u.len() != text.len() || !u.iter().zip(text).all(|(unit, word)| unit.text == *word) { continue; }
                    let raw_matches: Vec<_> = entries.iter().filter(|e| reference_raw_matches(&u, e)).collect();
                    assert_eq!(p.raw_entries(&u, 0).is_some(), !raw_matches.is_empty(), "{variant}");
                    for sem in entries.iter().map(|e| e.sem).chain([Sem::UnixCue, Sem::Number(59)]) {
                        let mut expected = Vec::new();
                        for e in entries {
                            if e.sem == sem && (raw_matches.is_empty() || reference_raw_matches(&u, e))
                                && !e.language.is_empty() && !expected.contains(&e.language) {
                                expected.push(e.language);
                            }
                        }
                        assert_eq!(languages(&u, 0, p, sem), expected, "{variant}: {sem:?}");
                    }
                    let english_abbreviation = u.len() == 1 && matches!(u[0].text.as_str(),
                        "mon" | "tue" | "tues" | "wed" | "thu" | "thur" | "thurs" | "fri" | "sat" | "sun");
                    let mut expected_votes = Vec::new();
                    for e in &raw_matches {
                        if voter(e.sem) && !e.language.is_empty()
                            && !(english_abbreviation && matches!(e.sem, Sem::Weekday(_)))
                            && !expected_votes.iter().any(|(language, _)| *language == e.language) {
                            let grammar = raw_matches.iter().any(|other| other.language == e.language && voter(other.sem)
                                && !matches!(other.sem, Sem::CommonNoun | Sem::Stop | Sem::Filler | Sem::Connector));
                            expected_votes.push((e.language, grammar));
                        }
                    }
                    let actual_votes = p.raw_entries(&u, 0).map_or(&[][..], |group| group.votes.as_slice());
                    assert_eq!(actual_votes, expected_votes, "{variant}");
                }
            }
        }
    }

    #[test]
    fn prepared_neutral_abbreviations_preserve_exact_raw_case() {
        for abbreviation in ABBREVIATIONS {
            for text in [abbreviation.text.to_owned(), abbreviation.text.to_lowercase(), abbreviation.text.to_uppercase()] {
                let u = units(&fold(&text));
                let expected = ABBREVIATIONS.iter().any(|a| a.text == u[0].raw)
                    || matches!(u[0].text.as_str(), "usd" | "gbp" | "eur" | "pln" | "tl" | "kg" | "cm" | "yoga" | "deadline" | "am" | "pm" | "h" | "g" | "年" | "月" | "日");
                assert_eq!(neutral_word(&u, 0, 1), expected, "{text}");
                assert!(!neutral_word(&u, 0, 2));
            }
        }
        for text in WEAK_WORDS {
            let u = units(&fold(text));
            assert!(needs_evidence(&u, 0, 1), "{text}");
            assert!(!needs_evidence(&u, 0, 2));
        }
        for text in ["ET", "et", "È", "e", "À", "a", "a.m.", "p.m."] {
            let u = units(&fold(text));
            assert_eq!(needs_evidence(&u, 0, 1), WEAK_WORDS.contains(&u[0].text.as_str()));
        }
    }

    #[test]
    fn evidence_memo_preserves_disputes_exclusions_and_slices() {
        let u = units(&fold("once et"));
        enable_memos(&u);
        let queries = [(&u[..], 0, 1, None), (&u[..], 0, 1, Some((1, 2))), (&u[..], 0, 2, None), (&u[..1], 0, 1, None)];
        for (index, (slice, at, len, excluded)) in queries.into_iter().enumerate() {
            let expected = evidence_uncached(slice, at, len, excluded);
            assert_eq!(expected, if index == 0 { Evidence::Language("fr", true) } else { Evidence::Unknown });
            reset_work();
            assert_eq!(evidence(slice, at, len, excluded), expected);
            let first = snapshot_work();
            assert_eq!(first.evidence_calls, 1);
            assert!(first.evidence_units > 0);
            assert_eq!(evidence(slice, at, len, excluded), expected);
            assert_eq!(snapshot_work(), first);
        }
        let shifted = units(&fold("et once"));
        enable_memos(&shifted);
        assert_eq!(evidence(&shifted, 1, 1, None), Evidence::Language("fr", true));
        assert_eq!(evidence(&shifted[1..], 0, 1, None), Evidence::Unknown);
        assert_eq!(evidence(&shifted[1..], 0, 1, None), evidence_uncached(&shifted[1..], 0, 1, None));
    }

    #[test]
    fn evidence_memo_is_disabled_by_default_and_reset_on_clone() {
        let mut u = units(&fold("once et"));
        reset_work();
        let expected = evidence(&u, 0, 1, None);
        assert_eq!(evidence(&u, 0, 1, None), expected);
        assert_eq!(snapshot_work().evidence_calls, 2);
        enable_memos(&u);
        assert_eq!(evidence(&u, 0, 1, None), expected);
        let mut cloned = u.clone();
        assert!(cloned.iter().all(|unit| unit.evidence_memo.0.borrow().is_none()));
        cloned[1].raw = "ET".to_owned();
        let changed = evidence_uncached(&cloned, 0, 1, None);
        assert_ne!(changed, expected);
        assert_eq!(changed, Evidence::Unknown);
        enable_memos(&cloned);
        reset_work();
        assert_eq!(evidence(&cloned, 0, 1, None), changed);
        assert_eq!(evidence(&cloned, 0, 1, None), changed);
        assert_eq!(snapshot_work().evidence_calls, 1);
        assert_eq!(evidence(&u, 0, 1, None), expected);
        let original_address = u.as_ptr();
        u[0] = u[0].clone();
        assert!(u[0].evidence_memo.0.borrow().is_none());
        u[1].raw = "ET".to_owned();
        assert_eq!(u.as_ptr(), original_address);
        enable_memos(&u);
        assert_eq!(evidence(&u, 0, 1, None), Evidence::Unknown);
    }

    #[test]
    fn traditional_characters_and_portuguese_function_words_vote() {
        for (text, want) in [
            ("once 這邊", "zh"), ("once 这边", "zh"),
            ("once 點後", "zh"), ("once o ônibus com você não", "pt"),
        ] {
            let u = units(&fold(text));
            assert!(matches!(evidence(&u, 0, 1, None), Evidence::Language(l, _) if l == want), "{text}");
        }
        let upper = units(&fold("once ET"));
        assert!(evidence(&upper, 0, 1, None).is_unknown());
        let lower = units(&fold("once et"));
        assert!(matches!(evidence(&lower, 0, 1, None), Evidence::Language("fr", _)));
    }
}
