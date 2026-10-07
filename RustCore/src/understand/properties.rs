// SPDX-License-Identifier: GPL-3.0-only
//! 随机文本的独立判据：位置、稳定性、折叠与日期沿用。
use super::{sentencegen, text::fold_str, understand, Clock, DateSpec, Options, Output, ZoneRef};
use std::time::Instant;

const HOSTILE: &[&str] = &[
    "😀", "👩🏽‍💻", "👨‍👩‍👧‍👦", "🇹🇷", "e\u{301}", "\u{308}\u{327}",
    "中文東京한글", "𠀀", "１２３４５６７８９０", "ıİß", "ẞǢǼǾ", "\0\u{1}\u{7}\u{1b}",
    "\t\r\n", "\u{b}\u{c}", "\u{200b}", "\u{200c}\u{200d}\u{feff}",
];

struct Sample {
    name: &'static str,
    seed: u64,
    iterations: usize,
    rng: u64,
    started: Instant,
}

impl Sample {
    fn new(name: &'static str, stream: u64) -> Self {
        let seed = std::env::var("MEANTIME_FUZZ_SEED").ok().and_then(|s| s.parse().ok()).unwrap_or(0);
        let iterations = std::env::var("MEANTIME_FUZZ_ITERATIONS").ok().and_then(|s| s.parse().ok()).unwrap_or(150);
        Self { name, seed, iterations, rng: stream.wrapping_add(seed), started: Instant::now() }
    }

    fn pick(&mut self, bound: usize) -> usize {
        // 加法发生器容许零种子。
        self.rng = self.rng.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        ((self.rng >> 32) as usize) % bound
    }

    fn done(&self, cases: usize) {
        eprintln!("PROPERTY {} seed={} iterations={} cases={} seconds={:.6}",
            self.name, self.seed, self.iterations, cases, self.started.elapsed().as_secs_f64());
    }
}

fn lookup(text: &str, _: bool) -> Option<ZoneRef> {
    let iana = match text.to_lowercase().as_str() {
        "tokyo" | "東京" | "东京" | "tokio" | "токио" => "Asia/Tokyo",
        "london" | "londres" | "londra" | "londyn" | "伦敦" | "ロンドン" | "런던" | "лондон" => "Europe/London",
        "berlin" | "берлин" => "Europe/Berlin",
        "paris" | "parís" | "paryż" | "париж" => "Europe/Paris",
        "new york" | "纽约" | "nueva york" | "nowy jork" | "нью-йорк" => "America/New_York",
        "sydney" | "сидней" | "시드니" => "Australia/Sydney",
        "singapore" | "singapur" => "Asia/Singapore",
        "los angeles" => "America/Los_Angeles",
        _ => return None,
    };
    Some(ZoneRef::City { city_index: 0, name: text.to_owned(), iana: iana.to_owned(), population: None })
}

fn read(text: &str, region: &str) -> Output {
    understand(text, &Options { region, ui_language: "en", lookup: &lookup })
}

fn joined_text(sample: &mut Sample, sentences: &[sentencegen::Case]) -> String {
    // 固定首项保证位置判据不会因零命中而空过。
    let mut text = String::from("09:45 Tokyo\n\n");
    for _ in 0..1 + sample.pick(3) {
        text.push_str(HOSTILE[sample.pick(HOSTILE.len())]);
        text.push(' ');
        text.push_str(&sentences[sample.pick(sentences.len())].text);
        text.push_str(HOSTILE[sample.pick(HOSTILE.len())]);
        text.push_str(".\n");
    }
    text
}

fn utf16(text: &str) -> Vec<u16> {
    let mut words = Vec::new();
    for scalar in text.chars().map(u32::from) {
        if scalar < 0x1_0000 {
            words.push(scalar as u16);
        } else {
            let n = scalar - 0x1_0000;
            words.push((0xd800 + (n >> 10)) as u16);
            words.push((0xdc00 + (n & 0x3ff)) as u16);
        }
    }
    words
}

fn boundary(words: &[u16], offset: usize) -> bool {
    offset <= words.len() && (offset == 0 || offset == words.len()
        || !((0xd800..=0xdbff).contains(&words[offset - 1]) && (0xdc00..=0xdfff).contains(&words[offset])))
}

#[test]
fn spans_stay_nested_sorted_and_on_utf16_boundaries() {
    let mut sample = Sample::new("spans", 0x713a_3258_905f_c6de);
    let sentences = sentencegen::cases(sample.seed, 24);
    for iteration in 0..sample.iterations {
        let text = joined_text(&mut sample, &sentences);
        let words = utf16(&text);
        let output = read(&text, "US");
        let context = format!("seed={} iteration={iteration} text={text:?}", sample.seed);
        assert!(!output.mentions.is_empty(), "{context}");
        for mention in output.mentions {
            let [start, end] = mention.span;
            assert!(start < end && end <= words.len(), "mention={mention:?} {context}");
            assert!(boundary(&words, start) && boundary(&words, end), "mention={mention:?} {context}");
            let mut previous_end = start;
            for part in &mention.parts {
                let [a, b] = part.span;
                assert!(start <= a && a < b && b <= end && previous_end <= a,
                    "mention={mention:?} part={part:?} previous_end={previous_end} {context}");
                assert!(boundary(&words, a) && boundary(&words, b), "part={part:?} {context}");
                previous_end = b;
            }
        }
    }
    sample.done(sample.iterations);
}

#[test]
fn repeated_reading_and_unrelated_suffixes_preserve_mentions() {
    let mut sample = Sample::new("stability", 0xd1ea_9b67_3c04_852f);
    let sentences = sentencegen::cases(sample.seed, 24);
    for iteration in 0..sample.iterations {
        let text = joined_text(&mut sample, &sentences);
        let first = serde_json::to_value(read(&text, "US")).unwrap();
        let again = serde_json::to_value(read(&text, "US")).unwrap();
        let context = format!("seed={} iteration={iteration} text={text:?}", sample.seed);
        assert_eq!(first, again, "{context}");
        for suffix in ["\n\nThanks!", " Merci."] {
            let appended = serde_json::to_value(read(&format!("{text}{suffix}"), "US")).unwrap();
            assert_eq!(first["mentions"], appended["mentions"], "suffix={suffix:?} {context}");
        }
    }
    sample.done(sample.iterations);
}

#[test]
fn folding_is_idempotent_for_hostile_unicode() {
    let mut sample = Sample::new("fold", 0xf642_8be1_c079_d3a5);
    for iteration in 0..sample.iterations {
        let mut text = HOSTILE[iteration % HOSTILE.len()].to_owned();
        for _ in 0..1 + sample.pick(40) {
            text.push_str(HOSTILE[sample.pick(HOSTILE.len())]);
            if let Some(c) = char::from_u32(sample.pick(0x11_0000) as u32) {
                text.push(c);
            }
        }
        let once = fold_str(&text);
        assert_eq!(once, fold_str(&once), "seed={} iteration={iteration} text={text:?}", sample.seed);
    }
    sample.done(sample.iterations);
}

#[test]
fn date_inheritance_obeys_written_dates_and_paragraph_boundaries() {
    let mut sample = Sample::new("date_inheritance", 0xa37b_158d_46f0_9ce2);
    let cities = ["Tokyo", "London", "Berlin", "Paris"];
    let mut entries = 0;
    for iteration in 0..sample.iterations {
        let mut text = String::new();
        let mut expected = Vec::new();
        for paragraph in 0..1 + sample.pick(2) {
            if paragraph != 0 { text.push('\n'); }
            let mut last_written: Option<(DateSpec, usize)> = None;
            for _ in 0..2 + sample.pick(4) {
                let explicit = sample.pick(3) == 0;
                if explicit {
                    let year = 2000 + sample.pick(100) as i32;
                    let month = 1 + sample.pick(12) as u8;
                    let day = 1 + sample.pick(28) as u8;
                    text.push_str(&format!("{year:04}-{month:02}-{day:02} "));
                    last_written = Some((DateSpec::Absolute { year, month, day }, expected.len()));
                }
                let hour = sample.pick(24) as u8;
                let minute = sample.pick(60) as u8;
                text.push_str(&format!("{hour:02}:{minute:02} {}\n", cities[sample.pick(cities.len())]));
                let date = last_written.as_ref().map(|(date, _)| date.clone());
                let from = if explicit { None } else { last_written.as_ref().map(|(_, index)| *index) };
                expected.push((date, from, Clock { hour, minute, second: 0, day_offset: 0 }));
            }
        }
        let output = read(&text, "US");
        let context = format!("seed={} iteration={iteration} text={text:?}", sample.seed);
        assert_eq!(output.mentions.len(), expected.len(), "{context} output={output:?}");
        for (index, (mention, (date, from, time))) in output.mentions.iter().zip(expected).enumerate() {
            assert_eq!(mention.date, date, "mention={index} {context}");
            assert_eq!(mention.date_inherited, from.is_some(), "mention={index} {context}");
            assert_eq!(mention.date_from, from, "mention={index} {context}");
            assert_eq!(mention.time, Some(time), "mention={index} {context}");
            assert!(mention.issues.is_empty(), "mention={index} {context}");
            entries += 1;
        }
    }
    sample.done(entries);
}

/// 每个地区用它自己的主要语言取系统短日期格式当判据，只看数据可靠的那部分：语言在界面十六语里、
/// 格式不以年开头（年在前的写法说明不了两个光秃秃的数里哪个是月）、不是 EU / UN 这类保留代码。
/// 其余地区由下一条测试按写明的理由逐个钉住。
const FIXTURE_LANGUAGES: [&str; 15] = ["en", "de", "es", "fr", "it", "ja", "ko", "nl", "pl", "ru", "tr", "vi", "id", "pt", "zh"];
const RESERVED_REGIONS: [&str; 13] = ["AC", "AQ", "CP", "CQ", "DG", "EA", "EU", "EZ", "HM", "IC", "QO", "TA", "UN"];

fn numeric_order(region: &str) -> Option<bool> {
    let output = read("03/07 14:25 UTC", region);
    if output.mentions.len() != 1 || !output.mentions[0].issues.is_empty() { return None; }
    match output.mentions[0].date {
        Some(DateSpec::MonthDay { month: 3, day: 7 }) => Some(true),
        Some(DateSpec::MonthDay { month: 7, day: 3 }) => Some(false),
        _ => None,
    }
}

#[test]
fn numeric_date_order_matches_each_regions_own_short_date_pattern() {
    let started = Instant::now();
    let mut count = 0;
    let mut failures = Vec::new();
    for row in include_str!("../../tests/fixtures/date_order_regions.tsv").lines().filter(|r| !r.starts_with('#') && !r.is_empty()) {
        let fields: Vec<_> = row.split('\t').collect();
        assert_eq!(fields.len(), 4, "fixture row={row:?}");
        let (region, locale, order) = (fields[0], fields[1], fields[2]);
        let language = locale.split('_').next().unwrap_or("");
        if order == "year" || !FIXTURE_LANGUAGES.contains(&language) || RESERVED_REGIONS.contains(&region) { continue; }
        let expected = match order { "month" => true, "day" => false, other => panic!("fixture order {other:?}") };
        if numeric_order(region) != Some(expected) {
            failures.push(format!("region={region} locale={locale} order={order} pattern={:?} engine={:?}", fields[3], numeric_order(region)));
        }
        count += 1;
    }
    assert!(count > 100, "too few reliable rows: {count}");
    eprintln!("PROPERTY numeric_date_order exhaustive=true iterations={count} cases={count} seconds={:.6}", started.elapsed().as_secs_f64());
    assert!(failures.is_empty(), "{} mismatched regions:\n{}", failures.len(), failures.join("\n"));
}

/// 判据管不到的地区：年在前的写法、自己语言不在十六语里、跟着美国写法的几处。每条写着为什么。
#[test]
fn numeric_date_order_for_regions_the_patterns_cannot_decide() {
    let cases: &[(&str, bool, &str)] = &[
        ("CN", true, "两个数先月后日（3/7 是三月七日）"),
        ("TW", true, "同上"),
        ("JP", true, "同上"),
        ("KR", true, "同上"),
        ("KP", true, "同上"),
        ("HU", true, "匈牙利写月在日前（10.02. 是十月二日）"),
        ("SE", false, "系统格式是年-月-日，口头两个数先日后月（3/7 是七月三日）"),
        ("ZA", false, "年/月/日之外，口头多随英式先日"),
        ("LK", false, "同上"),
        ("LT", false, "拿不准，按多数先日，另一种顺序照样给"),
        ("MN", false, "同上"),
        ("IR", false, "同上"),
        ("CA", true, "两种都有人写，按月/日读并附另一种"),
        ("PH", true, "跟美国写法"),
        ("AS", true, "美国属地"),
        ("FM", false, "系统的英语格式先日"),
        ("PW", false, "同上"),
    ];
    let wrong: Vec<_> = cases.iter().filter(|(region, month_first, _)| numeric_order(region) != Some(*month_first))
        .map(|(region, month_first, why)| format!("{region}: expected month_first={month_first} ({why}), engine {:?}", numeric_order(region)))
        .collect();
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
}
