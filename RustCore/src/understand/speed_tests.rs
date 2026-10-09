// SPDX-License-Identifier: GPL-3.0-only
//! 完整解析入口的耗时、名称解码与词表查找量守卫。

use super::{language, units};
use crate::city_index::test_work;
use serde_json::{json, Value};
use std::time::{Duration, Instant};

const INPUT_BYTES: usize = 4_000;
const RUNS: usize = 25;
const MAX_LOCALIZED_ENTRIES: usize = 4_096;
const MAX_EVIDENCE_UNITS: usize = 6_000;
const MAX_LEXICON_LOOKUPS: usize = 4_000;

struct BundledIndex(u64);

impl BundledIndex {
    fn open() -> Self {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../Dayside/Resources/cities.ttcity");
        assert!(std::path::Path::new(path).with_extension("ttpop").is_file(), "missing bundled population companion");
        let opened = crate::dispatch("city.open", json!({ "path": path })).unwrap();
        Self(opened["handle"].as_u64().unwrap())
    }

    fn payload(&self, text: &str) -> Value {
        json!({ "text": text, "region": "US", "language": "en", "cityHandle": self.0 })
    }
}

impl Drop for BundledIndex {
    fn drop(&mut self) {
        crate::dispatch("city.close", json!({ "handle": self.0 })).unwrap();
    }
}

// 交替使用不同段落，截断时保持字符完整，末尾空格补齐字节数。
fn sized_text(paragraphs: &[&str]) -> String {
    let mut text = String::new();
    for paragraph in paragraphs.iter().cycle() {
        if text.len() >= INPUT_BYTES {
            break;
        }
        text.push_str(paragraph);
        text.push('\n');
    }
    let mut end = INPUT_BYTES;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text.truncate(end);
    text.extend(std::iter::repeat_n(' ', INPUT_BYTES - text.len()));
    assert_eq!(text.len(), INPUT_BYTES);
    text
}

fn fixtures() -> Vec<(&'static str, String)> {
    vec![
        ("place-heavy-prose", sized_text(&[
            "Our route starts in London at 09:00, then Paris at 11:30. The Berlin team will send the notes before the call in Madrid at 15:45; Lisbon can review them tomorrow morning.",
            "The Portland office meets at 10am and Springfield follows at 2pm. We need separate reservations for Cambridge, Oxford, Richmond and Bristol, plus a later stop in Newcastle at 18:20.",
            "For Asia, Tokyo begins at 8:15am, Seoul at 09:40 and Singapore at noon. Mumbai and Delhi will reply after lunch; Bangkok, Jakarta and Manila receive the same itinerary.",
            "The last leg includes Toronto at 16:00, Vancouver at 13:00, Sydney at 07:30 and Melbourne at 08:00. Please confirm the rooms in Wellington, Auckland, San Jose and San Francisco.",
        ])),
        ("hostile-short-tokens", sized_text(&[
            "a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9; aa ab ac ad ae af ag ah ai aj ak al am an ao ap aq ar as at au av aw ax ay az 9:00.",
            "in la le li lo lu ma me mi mo mu na ne ni no nu pa pe pi po pu ra re ri ro ru sa se si so su ta te ti to tu 10 11 12 13 14 15 16 17 18 19 20 21 22 23.",
            "A LA 9am; B AN 2pm; C AM 00:01; D IN 23:59; E NO 1234567890; F DE 2026-10-02; G ON 02/10; H AT 12h; I AS +0100; J OR -0800; K TO 7:45; L IS 4pm.",
            "x1 y2 z3 q4 r5 s6 t7 u8 v9 w0; 00 01 02 03 04 05 06 07 08 09; // : ; @ ! ? ( ) [ ] 99:99 25:61 1.2.3 9-8-7; à é ö ü 中 日 12:00 in Li.",
        ])),
        ("mixed-language-email", sized_text(&[
            "From: Alex <alex@example.invalid>\nSubject: Next week's planning\nHello all, our London call is Tuesday at 9am. Please read the attached agenda and reply before Friday at 17:00. The Paris colleagues can join after lunch.",
            "Bonjour, la réunion à Berlin commence demain à 14h30. Gracias: nos vemos en Madrid el viernes a las 16:00. Bitte die Unterlagen bis morgen um 10 Uhr schicken; Amsterdam reviews the final draft.",
            "大家好，北京时间明天下午三点开会，上海同事请提前十分钟到。東京では明日の午前9時に確認します。서울 회의는 내일 오후 2시입니다。Singapore will send the minutes at 18:15.",
            "Ciao, a Roma ci vediamo domani alle 11:20. Warszawa: spotkanie jutro o 13:45. İstanbul için yarın saat 16:30 uygundur. Hẹn gặp tại Hà Nội lúc 9 giờ sáng. Москва: завтра в 15:00.",
            "Toronto can answer at 08:30 and Vancouver at 06:00; Cambridge needs another date. We are still waiting for the invoice, the guest list, travel approval and room details. Best regards, Alex\nSent from Sydney, 21:10.",
        ])),
    ]
}

fn checksum(output: &Value) -> u64 {
    serde_json::to_vec(output).unwrap().iter().fold(0xcbf29ce484222325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3)
    })
}

#[test]
fn understanding_city_name_work_is_bounded() {
    let index = BundledIndex::open();
    let mut excess = Vec::new();
    for (name, text) in fixtures() {
        test_work::reset();
        language::reset_work();
        units::reset_lookup_work();
        let output = crate::dispatch("understand.parse", index.payload(&text)).unwrap();
        let work = test_work::snapshot();
        let language_work = language::snapshot_work();
        let lexicon_lookups = units::snapshot_lookup_work();
        println!("WORK {name} bytes={} checksum={:016x} {work:?} LanguageWork {language_work:?} LexiconLookups {lexicon_lookups}", text.len(), checksum(&output));
        let expected = match name {
            "place-heavy-prose" => 0x79fc5e6f694ae820,
            "hostile-short-tokens" => 0xda4399ae60f807f7,
            "mixed-language-email" => 0x3f4f620f55573cfe,
            _ => unreachable!(),
        };
        assert_eq!(checksum(&output), expected, "{name}: full parsing output changed");
        if work.localized_entries > MAX_LOCALIZED_ENTRIES {
            excess.push(format!("{name}: localized entry ceiling {MAX_LOCALIZED_ENTRIES} exceeded: {work:?}"));
        }
        if language_work.evidence_units > MAX_EVIDENCE_UNITS {
            excess.push(format!("{name}: evidence unit ceiling {MAX_EVIDENCE_UNITS} exceeded: {language_work:?}"));
        }
        if lexicon_lookups > MAX_LEXICON_LOOKUPS {
            excess.push(format!("{name}: lexicon lookup ceiling {MAX_LEXICON_LOOKUPS} exceeded: {lexicon_lookups}"));
        }
    }
    assert!(excess.is_empty(), "parse work ceilings exceeded: {excess:?}");
}

#[test]
fn understanding_lookup_cache_preserves_keys_and_scope() {
    use std::cell::{Cell, RefCell};

    let calls = RefCell::new(Vec::new());
    let count = Cell::new(0);
    let lookup = super::memoized_lookup(|text: &str, strong: bool| {
        count.set(count.get() + 1);
        calls.borrow_mut().push((text.to_owned(), strong));
        (text != "missing").then(|| super::ZoneRef::Place { query: format!("handle-one:{text}:{strong}") })
    });
    let first = lookup("Cambridge", true);
    assert!(first.is_some());
    assert_eq!(lookup("Cambridge", true), first);
    assert_eq!(count.get(), 1);
    assert_eq!(lookup("missing", false), None);
    assert_eq!(lookup("missing", false), None);
    assert_eq!(count.get(), 2);
    assert_ne!(lookup("cambridge", true), first);
    assert_ne!(lookup("Cambridge", false), first);
    assert_eq!(lookup("missing", true), None);
    assert_eq!(count.get(), 5);
    assert_eq!(
        calls.borrow().as_slice(),
        &[("Cambridge".to_owned(), true), ("missing".to_owned(), false), ("cambridge".to_owned(), true), ("Cambridge".to_owned(), false), ("missing".to_owned(), true)],
    );
    let other_lookup = super::memoized_lookup(|text: &str, strong: bool| {
        count.set(count.get() + 1);
        Some(super::ZoneRef::Place { query: format!("handle-two:{text}:{strong}") })
    });
    let other = other_lookup("Cambridge", true);
    assert_ne!(other, first);
    assert_eq!(other_lookup("Cambridge", true), other);
    assert_eq!(count.get(), 6);
    assert_eq!(lookup("Cambridge", true), first);
    assert_eq!(count.get(), 6);
}

#[test]
fn understanding_name_predicate_matches_localized_map() {
    let index = crate::city_index::CityIndex::open(concat!(env!("CARGO_MANIFEST_DIR"), "/../Dayside/Resources/cities.ttcity")).unwrap();
    for city in [0, 1, 63, 64, 255, 256, 4_999, 50_000, index.city_count() - 1] {
        let names = index.names(city, false);
        for query in names.values() {
            assert_eq!(
                index.any_name_matches(city, |name| name == query),
                names.values().any(|name| name == query),
                "city {city}, localized name {query:?}",
            );
            let folded = crate::catalog::fold(query);
            assert_eq!(
                index.any_name_matches(city, |name| crate::catalog::fold(name) == folded),
                names.values().any(|name| crate::catalog::fold(name) == folded),
                "city {city}, folded name {folded:?}",
            );
        }
        let negative = "\0unmatched-city-name\0";
        assert_eq!(index.any_name_matches(city, |name| name == negative), names.values().any(|name| name == negative));
    }
    assert!(!index.any_name_matches(usize::MAX, |_| true));
}

#[test]
#[ignore]
fn understand_speed_gate() {
    // dev 同样量耗时，2 ms 门限只用于 Release 构建。
    let enforce_ceiling = !cfg!(debug_assertions);
    let index = BundledIndex::open();
    let mut excess = Vec::new();
    for (name, text) in fixtures() {
        let payload = index.payload(&text);
        let warmup = crate::dispatch("understand.parse", payload.clone()).unwrap();
        let expected = checksum(&warmup);
        test_work::reset();
        language::reset_work();
        units::reset_lookup_work();
        let output = crate::dispatch("understand.parse", payload.clone()).unwrap();
        let work = test_work::snapshot();
        let language_work = language::snapshot_work();
        let lexicon_lookups = units::snapshot_lookup_work();
        assert_eq!(checksum(&output), expected);
        let mut elapsed = Vec::with_capacity(RUNS);
        for _ in 0..RUNS {
            let start = Instant::now();
            let output = std::hint::black_box(crate::dispatch("understand.parse", payload.clone()).unwrap());
            elapsed.push(start.elapsed());
            assert_eq!(checksum(&output), expected);
        }
        elapsed.sort_unstable();
        let median = elapsed[RUNS / 2];
        println!(
            "SPEED {name} bytes={} runs={RUNS} median_ms={:.6} checksum={expected:016x} {work:?} LanguageWork {language_work:?} LexiconLookups {lexicon_lookups}",
            text.len(), median.as_secs_f64() * 1_000.0,
        );
        if enforce_ceiling && median > Duration::from_millis(2) {
            excess.push(format!("{name}: {median:?}"));
        }
    }
    assert!(excess.is_empty(), "2 ms median ceiling exceeded: {excess:?}");
}

#[test]
#[ignore]
fn understand_profile_hostile() {
    assert!(!std::hint::black_box(cfg!(debug_assertions)), "run understand_profile_hostile with --release");
    let index = BundledIndex::open();
    let text = fixtures().into_iter().find(|(name, _)| *name == "hostile-short-tokens").unwrap().1;
    let payload = index.payload(&text);
    crate::dispatch("understand.parse", payload.clone()).unwrap();
    let start = Instant::now();
    let mut runs = 0;
    while start.elapsed() < Duration::from_secs(8) {
        std::hint::black_box(crate::dispatch("understand.parse", payload.clone()).unwrap());
        runs += 1;
    }
    println!("PROFILE hostile-short-tokens runs={runs} elapsed={:?}", start.elapsed());
}

#[test]
#[ignore]
fn understand_city_cost_report() {
    assert!(!std::hint::black_box(cfg!(debug_assertions)), "run understand_city_cost_report with --release");
    let index = BundledIndex::open();
    for text in ["a", "ab", "us", "la", "de", "le", "of", "san", "London", "Cambridge", "Paris", "Springfield"] {
        for strong in [false, true] {
            let lookup = || serde_json::to_value(super::city_lookup(Some(index.0), text, strong)).unwrap();
            let expected = checksum(&lookup());
            test_work::reset();
            language::reset_work();
            units::reset_lookup_work();
            let output = lookup();
            let work = test_work::snapshot();
            let language_work = language::snapshot_work();
            let lexicon_lookups = units::snapshot_lookup_work();
            assert_eq!(checksum(&output), expected);
            let mut elapsed = Vec::with_capacity(RUNS);
            for _ in 0..RUNS {
                let start = Instant::now();
                let output = std::hint::black_box(lookup());
                elapsed.push(start.elapsed());
                assert_eq!(checksum(&output), expected);
            }
            elapsed.sort_unstable();
            println!(
                "CITY_COST query={text:?} strong={strong} runs={RUNS} median_us={:.6} checksum={expected:016x} {work:?} LanguageWork {language_work:?} LexiconLookups {lexicon_lookups}",
                elapsed[RUNS / 2].as_secs_f64() * 1_000_000.0,
            );
        }
    }
    for (name, text) in fixtures() {
        let mut payload = index.payload(&text);
        payload.as_object_mut().unwrap().remove("cityHandle");
        let expected = checksum(&crate::dispatch("understand.parse", payload.clone()).unwrap());
        test_work::reset();
        language::reset_work();
        units::reset_lookup_work();
        let output = crate::dispatch("understand.parse", payload.clone()).unwrap();
        let work = test_work::snapshot();
        let language_work = language::snapshot_work();
        let lexicon_lookups = units::snapshot_lookup_work();
        assert_eq!(checksum(&output), expected);
        let mut elapsed = Vec::with_capacity(RUNS);
        for _ in 0..RUNS {
            let start = Instant::now();
            let output = std::hint::black_box(crate::dispatch("understand.parse", payload.clone()).unwrap());
            elapsed.push(start.elapsed());
            assert_eq!(checksum(&output), expected);
        }
        elapsed.sort_unstable();
        println!(
            "NO_CITY {name} bytes={} runs={RUNS} median_ms={:.6} checksum={expected:016x} {work:?} LanguageWork {language_work:?} LexiconLookups {lexicon_lookups}",
            text.len(), elapsed[RUNS / 2].as_secs_f64() * 1_000.0,
        );
    }
}
