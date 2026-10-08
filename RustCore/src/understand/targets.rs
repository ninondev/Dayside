// SPDX-License-Identifier: GPL-3.0-only
//! Explicit destination grammar. The place slot is kept out of source-place
//! assembly; questions are assigned after all clocks in the paragraph are built.
use super::lexicon::Sem;
use super::scan::{words_after, Atom, Located};
use super::text::fold_str;
use super::types::ZoneRef;
use super::units::{find, phrase_units, UKind, Unit};
use super::table_storage::FastMap;
use std::sync::OnceLock;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Kind {
    Question,
    Arrow,
    Local,
}

pub(super) struct Phrase {
    pub from: usize,
    pub to: usize,
    pub name_from: usize,
    pub name_to: usize,
    pub text: String,
    pub bare: Option<String>,
    pub lang: Option<&'static str>,
    pub kind: Kind,
    pub local: bool,
    pub zone: Option<ZoneRef>,
}

// Closed tables, keyed by interface language. Accents, case and punctuation
// variants use the same deterministic folding as the rest of the engine.
const PREFIX: &[(&str, &[&str])] = &[
    (
        "en",
        &[
            "what time is that in",
            "what time is it in",
            "what time will that be in",
            "what time will it be in",
            "what time would that be in",
            "what time in",
            "what's that in",
            "what is that in",
        ],
    ),
    (
        "de",
        &[
            "wie spät ist das in",
            "wie spät wäre das in",
            "wie spät ist es in",
            "wie spät wird das in",
            "wie spät in",
            "wie viel uhr ist das in",
            "wieviel uhr in",
        ],
    ),
    (
        "es",
        &[
            "qué hora será en",
            "qué hora es en",
            "qué hora sería en",
            "qué hora en",
            "a qué hora se llega a",
            "a qué hora es en",
        ],
    ),
    (
        "fr",
        &[
            "quelle heure est-ce à",
            "quelle heure est-il à",
            "quelle heure sera-t-il à",
            "quelle heure serait-il à",
            "quelle heure à",
            "quelle heure est-ce en",
        ],
    ),
    (
        "it",
        &[
            "che ore saranno a",
            "che ore sono a",
            "che ora sarà a",
            "che ora è a",
            "che ore a",
            "che ora sarebbe a",
        ],
    ),
    ("ja", &[]),
    ("ko", &[]),
    (
        "nl",
        &[
            "hoe laat is dat in",
            "hoe laat is het dan in",
            "hoe laat is het in",
            "hoe laat zou dat in",
            "hoe laat in",
            "wat is dat in",
        ],
    ),
    (
        "pl",
        &[
            "która godzina jest w",
            "która godzina będzie w",
            "która godzina w",
            "która to godzina w",
            "o której godzinie w",
        ],
    ),
    (
        "ru",
        &[
            "во сколько это будет в",
            "во сколько будет в",
            "сколько времени будет в",
            "сколько это в",
            "сколько будет в",
            "сколько времени в",
            "который час в",
            "сколько в",
        ],
    ),
    ("tr", &[]),
    ("vi", &[]),
    (
        "id",
        &[
            "jam berapa itu di",
            "pukul berapa itu di",
            "jam berapa waktunya di",
            "pukul berapa waktunya di",
            "jam berapa di",
            "pukul berapa di",
        ],
    ),
    (
        "pt-BR",
        &[
            "que horas serão em",
            "que horas são em",
            "que horas seriam em",
            "que horas em",
            "que hora é em",
        ],
    ),
    ("zh-Hans", &[]),
    ("zh-Hant", &[]),
];
const SUFFIX: &[(&str, &[&str])] = &[
    ("en", &[]),
    ("de", &[]),
    ("es", &[]),
    ("fr", &[]),
    ("it", &[]),
    (
        "ja",
        &[
            "では今何時ですか",
            "は今何時ですか",
            "で今何時ですか",
            "は今何時",
            "では何時になりますか",
            "で何時になりますか",
            "では何時ですか",
            "で何時ですか",
            "は何時ですか",
            "では何時",
            "で何時",
            "は何時",
            "何時ですか",
            "何時",
        ],
    ),
    (
        "ko",
        &[
            "에서는 몇 시인가요",
            "에서는 몇 시예요",
            "에서는 몇 시야",
            "에서는 몇 시죠",
            "에서 몇 시인가요",
            "에서 몇 시예요",
            "는 몇 시인가요",
            "는 몇 시예요",
            "은 몇 시예요",
            "은 몇 시인가요",
            "은 몇 시야",
            "은 몇 시죠",
            "은 몇 시지",
            "몇 시인가요",
            "몇 시예요",
            "몇 시지",
            "몇 시야",
            "몇 시죠",
            "몇 시",
        ],
    ),
    ("nl", &[]),
    ("pl", &[]),
    ("ru", &[]),
    ("tr", &["saat kaç", "saat kaçtır", "saat kaç olur"]),
    ("vi", &["là mấy giờ", "mấy giờ"]),
    ("id", &["jam berapa", "pukul berapa"]),
    ("pt-BR", &[]),
    ("zh-Hans", &["那边是几点", "那边几点", "是几点", "的几点", "几点"]),
    ("zh-Hant", &["那邊是幾點", "那邊幾點", "是幾點", "的幾點", "幾點"]),
];
const LOCAL: &[(&str, &[&str])] = &[
    (
        "en",
        &["in my local time", "in my time", "my local time", "my time", "here"],
    ),
    ("de", &["in meiner zeit", "meine zeit", "meiner zeit", "hier"]),
    ("es", &["en mi horario", "en mi hora", "mi hora", "aquí"]),
    (
        "fr",
        &[
            "soit mon heure locale",
            "dans mon fuseau horaire",
            "à mon heure",
            "mon heure locale",
            "mon heure",
            "ici",
        ],
    ),
    (
        "it",
        &["nel mio fuso orario", "nella mia ora", "la mia ora"],
    ),
    (
        "ja",
        &[
            "こちらの時間では",
            "私の時間では",
            "こちらの時間",
            "私の時間",
        ],
    ),
    (
        "ko",
        &[
            "제 시간으로는 몇 시인가요",
            "제 시간으로는 몇 시예요",
            "제 시간으로는 몇 시지",
            "제 시간으로는 몇 시",
            "제 시간으로는",
            "제 시간",
        ],
    ),
    ("nl", &["in mijn tijd", "mijn tijd", "hier"]),
    ("pl", &["w moim czasie", "mój czas"]),
    (
        "ru",
        &["это по моему времени", "по моему времени", "моё время"],
    ),
    ("tr", &["benim saatimde", "benim saatim"]),
    (
        "vi",
        &["tính theo giờ của tôi", "theo giờ của tôi", "giờ của tôi", "ở đây"],
    ),
    ("id", &["dalam waktu saya", "waktu saya", "di sini"]),
    ("pt-BR", &["no meu horário", "na minha hora", "meu horário", "aqui"]),
    ("zh-Hans", &["按我的时间", "我的时间", "我这边"]),
    ("zh-Hant", &["按我的時間", "我的時間", "我這邊"]),
];
// 「这里」只跨封闭的系词连接钟点，普通叙述词不当连接词。
const HERE_COPULAS: &[(&str, &[&[&str]])] = &[
    ("here", &[&["it", "is"], &["is"]]),
    ("hier", &[&["ist", "es"], &["ist"], &["is", "het"], &["is"]]),
    ("ici", &[&["il", "est"], &["c", "'", "est"]]),
    ("aqui", &[&["son", "las"], &["es", "la"], &["sao"], &["e"], &["son"], &["es"]]),
    ("o day", &[&["la"]]),
    ("di sini", &[&["adalah"]]),
    ("我 这 边", &[&["是"]]),
    ("我 這 邊", &[&["是"]]),
];

fn here_copula_end(u: &[Unit], from: usize, to: usize) -> usize {
    let here = u[from..to].iter().map(|t| t.text.as_str()).collect::<Vec<_>>().join(" ");
    HERE_COPULAS.iter().find(|(word, _)| *word == here)
        .and_then(|(_, forms)| forms.iter().find(|form| u.get(to..to + form.len())
            .is_some_and(|span| span.iter().zip(**form).all(|(unit, word)| {
                // é 的重音区分系词和连词 e，折叠后的同形不能抹掉这个区别。
                unit.text == *word && (*word != "e" || unit.raw.to_lowercase() == "é")
            }))))
        .map_or(to, |form| to + form.len())
}

pub(super) fn local_clock_start(u: &[Unit], phrase: &Phrase) -> usize {
    phrase.to.max(here_copula_end(u, phrase.name_from, phrase.name_to))
}

struct Form {
    units: Vec<String>,
    lang: &'static str,
}
type Table = FastMap<String, Vec<Form>>;
fn table(entries: &[(&'static str, &[&str])]) -> Table {
    let mut out: Table = FastMap::default();
    for &(lang, forms) in entries {
        for &form in forms {
            let units = phrase_units(&fold_str(form));
            out.entry(units[0].clone())
                .or_default()
                .push(Form { units, lang });
        }
    }
    for forms in out.values_mut() {
        forms.sort_by_key(|f| std::cmp::Reverse(f.units.len()));
    }
    out
}
fn matched<'a>(table: &'a Table, u: &[Unit], at: usize) -> Option<&'a Form> {
    table.get(&u.get(at)?.text)?.iter().find(|form| {
        u.get(at..at + form.units.len()).is_some_and(|span| {
            span.iter()
                .zip(&form.units)
                .all(|(unit, word)| &unit.text == word)
        })
    })
}
fn name_before(u: &[Unit], marker: usize, lang: &str) -> Option<(usize, usize)> {
    let end = marker;
    let mut start = marker.checked_sub(1)?;
    if !matches!(u[start].kind, UKind::Word | UKind::Cjk) {
        return None;
    }
    if u[start].kind == UKind::Cjk {
        // A spaced Hangul word or one uninterrupted Japanese/Chinese name.
        while start > 0 && !u[start].space_before && u[start - 1].kind == UKind::Cjk {
            start -= 1;
        }
    } else {
        let mut words = 1;
        while start > 0 && words < 6 {
            let prev = &u[start - 1];
            if prev.kind == UKind::Punct
                && prev.text == "-"
                && !u[start].space_before
                && start > 1
                && u[start - 2].kind == UKind::Word
            {
                start -= 2;
                words += 1;
                continue;
            }
            if prev.kind != UKind::Word {
                break;
            }
            if !prev.capital
                && !["de", "di", "do", "del", "phố", "pho"].contains(&prev.text.as_str())
            {
                break;
            }
            if find(u, start - 1, |s| {
                matches!(
                    s,
                    Sem::Stop | Sem::ClockBefore | Sem::Period(_) | Sem::ZoneBefore
                )
            })
            .is_some()
                && !["los", "las", "la", "le", "thanh", "pho"].contains(&prev.text.as_str())
            {
                break;
            }
            start -= 1;
            words += 1;
        }
    }
    // Fixed introductory/location words are grammar, never part of the place.
    for prefix in match lang {
        "ja" => &[
            "これは",
            "それは",
            "こちらは",
            "時には",
            "時は",
            "分は",
            "時",
            "分",
            "は",
        ][..],
        "ko" => &["시는", "는", "은"][..],
        "zh-Hans" => &["在", "到", "这是", "那是"][..],
        "zh-Hant" => &["在", "到", "這是", "那是"][..],
        "vi" => &["ở", "tại"][..],
        _ => &[][..],
    } {
        let p = phrase_units(&fold_str(prefix));
        if start + p.len() < end
            && u[start..start + p.len()]
                .iter()
                .zip(&p)
                .all(|(t, s)| &t.text == s)
        {
            start += p.len();
            break;
        }
    }
    Some((start, end))
}
fn query(u: &[Unit], from: usize, to: usize) -> String {
    let mut text = String::new();
    for t in &u[from..to] {
        if !text.is_empty() && t.space_before {
            text.push(' ');
        }
        text.push_str(&t.raw);
    }
    text
}
fn name_after(u: &[Unit], from: usize) -> (String, usize, Option<String>) {
    let (mut text, mut to, bare) = words_after(u, from, 6, true);
    // Explicit destination grammar licenses a written proper name even when
    // its first word collides with a time word (Hà / German "ha" idiom).
    if text.is_empty()
        && u.get(from)
            .is_some_and(|t| t.kind == UKind::Word && t.capital)
    {
        to = from + 1;
        while to < u.len()
            && to - from < 6
            && u[to].kind == UKind::Word
            && (u[to].capital || ["de", "di", "do", "del"].contains(&u[to].text.as_str()))
        {
            to += 1;
        }
        text = query(u, from, to);
    }
    if u.get(from).is_some_and(|t| t.kind == UKind::Cjk) {
        to = (from + 1..to).find(|&i| u[i].space_before).unwrap_or(to);
        return (query(u, from, to), to, bare);
    }
    (text, to, bare)
}
fn zone_after(u: &[Unit], from: usize) -> Option<(ZoneRef, usize)> {
    if from >= u.len() {
        return None;
    }
    let mut scanner = super::scan::Scanner { u, out: Vec::new() };
    let n = scanner.iana(from).or_else(|| scanner.zone(from))?;
    scanner.out.into_iter().find_map(|a| match a.atom {
        Atom::Zone(zone) => Some((zone, from + n)),
        _ => None,
    })
}
fn question_tail(u: &[Unit], mut end: usize, lang: &str) -> usize {
    // Finite endings that follow the short question forms.
    let endings = match lang {
        "ja" => &["ですか", "になりますか"][..],
        "ko" => &["인가요", "예요", "야", "죠", "지"][..],
        _ => &[][..],
    };
    for ending in endings {
        let p = phrase_units(&fold_str(ending));
        if u.get(end..end + p.len())
            .is_some_and(|s| s.iter().zip(&p).all(|(t, w)| &t.text == w))
        {
            end += p.len();
            break;
        }
    }
    end
}

/// A glued Korean clock particle may be followed by a destination question.
/// Keep ordinary Hangul word tails blocked; both the particle and question
/// ending must come from the closed grammar.
pub(super) fn korean_question_after_clock(u: &[Unit], from: usize, to: usize) -> bool {
    static TABLE: OnceLock<Table> = OnceLock::new();
    let suffix = TABLE.get_or_init(|| table(SUFFIX));
    (from..to).any(|marker| {
        matched(suffix, u, marker).is_some_and(|form| {
            form.lang == "ko"
                && question_tail(u, marker + form.units.len(), "ko") == to
                && name_before(u, marker, "ko").is_some_and(|(name, _)| {
                    name > from && super::language::korean_clock_particle(&query(u, from, name))
                })
        })
    })
}

pub(super) fn scan(u: &[Unit], atoms: &[Located]) -> Vec<Phrase> {
    static PREFIX_TABLE: OnceLock<Table> = OnceLock::new();
    static SUFFIX_TABLE: OnceLock<Table> = OnceLock::new();
    static LOCAL_TABLE: OnceLock<Table> = OnceLock::new();
    let prefix = PREFIX_TABLE.get_or_init(|| table(PREFIX));
    let suffix = SUFFIX_TABLE.get_or_init(|| table(SUFFIX));
    let local = LOCAL_TABLE.get_or_init(|| table(LOCAL));
    let mut out: Vec<Phrase> = Vec::new();
    let mut i = 0;
    while i < u.len() {
        let arrow =
            u[i].text == "→" || u[i].text == "-" && u.get(i + 1).is_some_and(|t| t.text == ">");
        if let Some(form) = matched(prefix, u, i) {
            let name_from = i + form.units.len();
            // 问句末尾的介词可与本地说法共用：「jam berapa di sini」。
            let local_match = matched(local, u, name_from).map(|form| (name_from, form))
                .or_else(|| (form.lang == "id" && name_from > i && u[name_from - 1].text == "di")
                    .then(|| matched(local, u, name_from - 1).map(|form| (name_from - 1, form))).flatten());
            let local_form = local_match.map(|(_, form)| form);
            let zone = zone_after(u, name_from);
            let (text, name_to, bare) = if let Some((_, end)) = &zone {
                (query(u, name_from, *end), *end, None)
            } else if let Some((start, l)) = local_match {
                (
                    query(u, start, start + l.units.len()),
                    start + l.units.len(),
                    None,
                )
            } else {
                name_after(u, name_from)
            };
            if !text.is_empty() {
                out.push(Phrase {
                    from: i,
                    to: name_to,
                    name_from,
                    name_to,
                    text,
                    bare,
                    lang: Some(form.lang),
                    kind: Kind::Question,
                    local: local_form.is_some(),
                    zone: zone.map(|(zone, _)| zone),
                });
                i = name_to;
                continue;
            }
        }
        if arrow {
            let name_from = i + if u[i].text == "→" { 1 } else { 2 };
            let local_form = matched(local, u, name_from);
            let zone = zone_after(u, name_from);
            let (text, name_to, bare) = if let Some((_, end)) = &zone {
                (query(u, name_from, *end), *end, None)
            } else if let Some(l) = local_form {
                (
                    query(u, name_from, name_from + l.units.len()),
                    name_from + l.units.len(),
                    None,
                )
            } else {
                name_after(u, name_from)
            };
            if !text.is_empty() {
                out.push(Phrase {
                    from: i,
                    to: name_to,
                    name_from,
                    name_to,
                    text,
                    bare,
                    lang: local_form.map(|l| l.lang),
                    kind: Kind::Arrow,
                    local: local_form.is_some(),
                    zone: zone.map(|(zone, _)| zone),
                });
                i = name_to;
                continue;
            }
        }
        if let Some(form) = matched(local, u, i).filter(|form| {
            // 法语 hier 是昨天；德荷语的系词或独立荷语证据才能把它读作这里。
            u[i].text != "hier" || here_copula_end(u, i, i + form.units.len()) > i + form.units.len()
                || super::language::supported_language(u, i, form.units.len(), Sem::LocalZone, None) == Some("nl")
        }) {
            let name_to = i + form.units.len();
            let tail = matched(suffix, u, name_to);
            let has_question =
                tail.is_some() || (i..name_to).any(|k| matched(suffix, u, k).is_some());
            let to = tail.map_or(name_to, |s| {
                question_tail(u, name_to + s.units.len(), s.lang)
            });
            out.push(Phrase {
                from: i,
                to,
                name_from: i,
                name_to,
                text: query(u, i, name_to),
                bare: None,
                lang: Some(form.lang),
                kind: if has_question {
                    Kind::Question
                } else {
                    Kind::Local
                },
                local: true,
                zone: None,
            });
            i = to;
            continue;
        }
        if let Some(form) = matched(suffix, u, i) {
            if let Some((mut from, name_to)) = name_before(u, i, form.lang) {
                // Word-form clocks share a CJK run with the topic and place:
                // 九点是纽约几点 / 9時は東京では何時. A name cannot eat the
                // already scanned clock or its source words.
                if let Some(end) = atoms
                    .iter()
                    .filter(|a| a.to <= i && matches!(a.atom, Atom::Clock { .. } | Atom::Idiom(..)))
                    .map(|a| a.to)
                    .max()
                {
                    from = from.max(end);
                }
                while from < name_to && ["是", "は", "는", "은"].contains(&u[from].text.as_str())
                {
                    from += 1;
                }
                // 对应与相当于是目标问句的引词，不属于城市名字。
                if matches!(form.lang, "zh-Hans" | "zh-Hant") {
                    for prefix in ["对应", "對應", "相当于", "相當於"] {
                        let words = phrase_units(prefix);
                        if from + words.len() < name_to && u[from..from + words.len()].iter().zip(&words).all(|(unit, word)| &unit.text == word) {
                            from += words.len();
                            break;
                        }
                    }
                }
                if from == name_to {
                    i += form.units.len();
                    continue;
                }
                if out.last().is_none_or(|p| p.to <= from) {
                    let to = question_tail(u, i + form.units.len(), form.lang);
                    out.push(Phrase {
                        from,
                        to,
                        name_from: from,
                        name_to,
                        text: query(u, from, name_to),
                        bare: None,
                        lang: Some(form.lang),
                        kind: Kind::Question,
                        local: false,
                        zone: None,
                    });
                    i = to;
                    continue;
                }
            }
        }
        i += 1;
    }
    out
}
