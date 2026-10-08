// SPDX-License-Identifier: GPL-3.0-only
//! Independent rule 11 regressions: destinations follow explicit grammar and bounded scope.
use super::*;

fn lookup(text: &str, _strong: bool) -> Option<ZoneRef> {
    let folded = fold_str(text);
    let iana = match folded.as_str() {
        "sydney" | "sidney" | "sydney'de" | "시드니" => "Australia/Sydney",
        "berlin" | "berlin'de" => "Europe/Berlin",
        "madrid" => "Europe/Madrid",
        "paris" | "paris'te" => "Europe/Paris",
        "roma" => "Europe/Rome",
        "tokyo" | "tokyo'da" | "токио" | "東京" | "东京" => "Asia/Tokyo",
        "서울" => "Asia/Seoul",
        "amsterdam" => "Europe/Amsterdam",
        "warszawa" | "warszawie" => "Europe/Warsaw",
        "москва" | "москве" | "moskva" => "Europe/Moscow",
        "istanbul" | "istanbul'da" => "Europe/Istanbul",
        "ha noi" => "Asia/Ho_Chi_Minh",
        "jakarta" => "Asia/Jakarta",
        "brasilia" => "America/Sao_Paulo",
        "london" | "런던" | "ロンドン" => "Europe/London",
        "new york" | "纽约" | "紐約" => "America/New_York",
        _ => return None,
    };
    Some(ZoneRef::City {
        city_index: 0,
        name: text.into(),
        iana: iana.into(),
        population: None,
    })
}

fn read(text: &str, lang: &str) -> Vec<Mention> {
    understand(
        text,
        &Options {
            region: "US",
            ui_language: lang,
            lookup: &lookup,
        },
    )
    .mentions
}

fn zone(zone: &Option<ZoneRef>) -> String {
    match zone {
        None => "-".into(),
        Some(ZoneRef::City { iana, .. } | ZoneRef::Region { iana }) => iana.clone(),
        Some(ZoneRef::Fixed { minutes, .. }) => format!("{minutes:+}"),
        Some(ZoneRef::Local) => "local".into(),
        // Retain the distinction between an explicit source and a sentence suggestion.
        Some(ZoneRef::Options { reason, .. }) => format!("?{reason}"),
        Some(ZoneRef::Place { query }) => format!("@{query}"),
    }
}

fn snapshot(mentions: &[Mention]) -> Vec<String> {
    mentions
        .iter()
        .map(|m| {
            let clock = m
                .time
                .map(|c| format!("{:02}:{:02}", c.hour, c.minute))
                .or_else(|| (m.relative_minutes == Some(0)).then(|| "now".into()))
                .unwrap_or_else(|| "-".into());
            let unknown = m
                .unresolved
                .iter()
                .map(|u| format!(" !{}:{}", u.role, u.text))
                .collect::<String>();
            format!("{clock} {} > {}{unknown}", zone(&m.source), zone(&m.target))
        })
        .collect()
}

fn check(cases: Vec<(String, &str, Vec<String>)>) {
    let mut failures = Vec::new();
    for (text, lang, want) in cases {
        let mentions = read(&text, lang);
        let got = snapshot(&mentions);
        if got != want || mentions.iter().any(|m| !m.issues.is_empty()) {
            failures.push(format!(
                "{lang}: {text}\nwant {want:?}\ngot {got:?}\n{mentions:?}"
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

// Written case forms deliberately remain in the test lookup. These tests isolate
// question recognition and attachment from the separate city-index inflection tests.
const QUESTIONS: &[(&str, &str, &str, &str)] = &[
    (
        "en",
        "What time is that in Sydney?",
        "Sydney",
        "Australia/Sydney",
    ),
    (
        "de",
        "Wie spät ist das in Berlin?",
        "Berlin",
        "Europe/Berlin",
    ),
    ("es", "¿Qué hora será en Madrid?", "Madrid", "Europe/Madrid"),
    (
        "fr",
        "Quelle heure est-ce à Paris ?",
        "Paris",
        "Europe/Paris",
    ),
    ("it", "Che ore sono a Roma?", "Roma", "Europe/Rome"),
    ("ja", "東京 では何時ですか？", "東京", "Asia/Tokyo"),
    ("ko", "서울에서는 몇 시예요?", "서울", "Asia/Seoul"),
    (
        "nl",
        "Hoe laat is dat in Amsterdam?",
        "Amsterdam",
        "Europe/Amsterdam",
    ),
    (
        "pl",
        "Która godzina jest w Warszawie?",
        "Warszawie",
        "Europe/Warsaw",
    ),
    (
        "ru",
        "Сколько времени будет в Москве?",
        "Москве",
        "Europe/Moscow",
    ),
    ("tr", "İstanbul'da saat kaç?", "İstanbul", "Europe/Istanbul"),
    ("vi", "Ở Hà Nội là mấy giờ?", "Hà Nội", "Asia/Ho_Chi_Minh"),
    ("id", "Jam berapa di Jakarta?", "Jakarta", "Asia/Jakarta"),
    (
        "pt-BR",
        "Que horas são em Brasília?",
        "Brasília",
        "America/Sao_Paulo",
    ),
    ("zh-Hans", "在东京是几点？", "东京", "Asia/Tokyo"),
    ("zh-Hant", "在東京是幾點？", "東京", "Asia/Tokyo"),
];

#[test]
fn sixteen_languages_question_targets_previous_clock_and_not_later_clock() {
    check(
        QUESTIONS
            .iter()
            .map(|&(lang, question, _, iana)| {
                (
                    format!("09:00 UTC. {question} 12:00 UTC."),
                    lang,
                    vec![format!("09:00 +0 > {iana}"), "12:00 +0 > -".into()],
                )
            })
            .collect(),
    );
}

// QUESTIONS 里写成「此刻几点」的那些语言（其余语言的例句回指前文或用将来时：what time is that in、wie spät ist das、
// qué hora será、quelle heure est-ce、hoe laat is dat、во сколько это будет）。
const PRESENT_QUESTION_LANGUAGES: &[&str] = &["it", "ja", "ko", "pl", "tr", "vi", "id", "pt-BR", "zh-Hans", "zh-Hant"];

#[test]
fn sixteen_languages_blank_line_stops_previous_question_scope() {
    // 空行后的问句不再回指前一段的钟点；问的是此刻时答「现在」，回指前文的问法照旧不答。
    check(
        QUESTIONS
            .iter()
            .map(|&(lang, question, _, iana)| {
                let mut want = vec!["09:00 +0 > -".to_owned()];
                if PRESENT_QUESTION_LANGUAGES.contains(&lang) {
                    want.push(format!("now - > {iana}"));
                }
                want.push("12:00 +0 > -".into());
                (format!("09:00 UTC.\n\n{question}\n12:00 UTC."), lang, want)
            })
            .collect(),
    );
}

#[test]
fn present_tense_questions_without_a_clock_ask_for_the_time_now() {
    check(vec![
        ("What time is it in Tokyo?".into(), "en", vec!["now - > Asia/Tokyo".into()]),
        ("what time in tokyo".into(), "en", vec!["now - > Asia/Tokyo".into()]),
        ("Wie spät ist es in Berlin?".into(), "de", vec!["now - > Europe/Berlin".into()]),
        ("Quelle heure est-il à Paris ?".into(), "fr", vec!["now - > Europe/Paris".into()]),
        ("在东京是几点？".into(), "zh-Hans", vec!["now - > Asia/Tokyo".into()]),
        ("東京 では何時ですか？".into(), "ja", vec!["now - > Asia/Tokyo".into()]),
        ("İstanbul'da saat kaç?".into(), "tr", vec!["now - > Europe/Istanbul".into()]),
        // 表示此刻的词写在地名前，不算进地名。
        ("现在东京几点？".into(), "zh-Hans", vec!["now - > Asia/Tokyo".into()]),
        ("目前東京幾點？".into(), "zh-Hant", vec!["now - > Asia/Tokyo".into()]),
        ("いま東京は何時ですか".into(), "ja", vec!["now - > Asia/Tokyo".into()]),
        // 「今」开头的地名整个保留（测试查表里没有今治，原样留作未解析的目标）。
        ("今治は何時ですか".into(), "ja", vec!["now - > - !target:今治".into()]),
        // 后面另一句的钟点不是这一问的对象：问句照样答此刻，钟点照样是独立的一处。
        ("What time is it in Tokyo? 15:00 UTC.".into(), "en", vec!["now - > Asia/Tokyo".into(), "15:00 +0 > -".into()]),
        // 范围里有钟点时仍是换算那个钟点，不另答此刻。
        ("09:00 UTC. What time is it in Tokyo?".into(), "en", vec!["09:00 +0 > Asia/Tokyo".into()]),
    ]);
}

#[test]
fn questions_about_an_earlier_or_future_time_need_that_time() {
    check(vec![
        ("What time is that in Tokyo?".into(), "en", vec![]),
        ("What time will it be in Tokyo?".into(), "en", vec![]),
        ("Wie spät ist das in Berlin?".into(), "de", vec![]),
        ("¿Qué hora será en Madrid?".into(), "es", vec![]),
        ("Paris'te saat kaç olur?".into(), "tr", vec![]),
        ("What time is it?".into(), "en", vec![]),
    ]);
}

#[test]
fn sixteen_languages_own_sentence_clock_is_the_only_question_subject() {
    check(
        QUESTIONS
            .iter()
            .map(|&(lang, question, _, iana)| {
                (
                    format!("09:00 UTC. 10:00 UTC, {question} 12:00 UTC."),
                    lang,
                    vec![
                        "09:00 +0 > -".into(),
                        format!("10:00 +0 > {iana}"),
                        "12:00 +0 > -".into(),
                    ],
                )
            })
            .collect(),
    );
}

#[test]
fn sixteen_languages_known_question_target_is_not_a_sentence_source_suggestion() {
    check(
        QUESTIONS
            .iter()
            .map(|&(lang, question, _, iana)| {
                (
                    format!("09:00, {question}"),
                    lang,
                    vec![format!("09:00 - > {iana}")],
                )
            })
            .collect(),
    );
}

#[test]
fn closed_question_inflections_keep_city_out_of_source_slot() {
    check(vec![
        (
            "09:00 UTC. Paris'te saat kaç?".into(),
            "tr",
            vec!["09:00 +0 > Europe/Paris".into()],
        ),
        (
            "09:00 UTC. Berlin'de saat kaç?".into(),
            "tr",
            vec!["09:00 +0 > Europe/Berlin".into()],
        ),
        (
            "09:00 UTC. 東京で何時になりますか。".into(),
            "ja",
            vec!["09:00 +0 > Asia/Tokyo".into()],
        ),
        (
            "09:00 UTC. 서울 몇 시야?".into(),
            "ko",
            vec!["09:00 +0 > Asia/Seoul".into()],
        ),
        (
            "09:00 UTC. 서울 몇 시죠?".into(),
            "ko",
            vec!["09:00 +0 > Asia/Seoul".into()],
        ),
        (
            "09:00 UTC. 서울에서는 몇 시인가요?".into(),
            "ko",
            vec!["09:00 +0 > Asia/Seoul".into()],
        ),
        (
            "09:00 UTC. Во сколько это будет в Москве?".into(),
            "ru",
            vec!["09:00 +0 > Europe/Moscow".into()],
        ),
        (
            "09:00 UTC. Сколько это в Москве?".into(),
            "ru",
            vec!["09:00 +0 > Europe/Moscow".into()],
        ),
        (
            "09:00 UTC. Hà Nội mấy giờ?".into(),
            "vi",
            vec!["09:00 +0 > Asia/Ho_Chi_Minh".into()],
        ),
    ]);
}

#[test]
fn question_can_reach_multiple_previous_sentences_but_next_question_resets_scope() {
    check(vec![
        ("09:00 UTC. 10:00 UTC. What time is that in Sydney? 11:00 UTC. 12:00 UTC. What time is that in Berlin? 13:00 UTC.".into(), "en",
         vec!["09:00 +0 > Australia/Sydney".into(), "10:00 +0 > Australia/Sydney".into(), "11:00 +0 > Europe/Berlin".into(), "12:00 +0 > Europe/Berlin".into(), "13:00 +0 > -".into()]),
        ("09:00 UTC. What time is that in Sydney? What time is that in Berlin? 12:00 UTC.".into(), "en",
         vec!["09:00 +0 > Australia/Sydney".into(), "12:00 +0 > -".into()]),
        ("09:00 UTC.\n10:00 UTC. What time is that in Sydney?".into(), "en",
         vec!["09:00 +0 > Australia/Sydney".into(), "10:00 +0 > Australia/Sydney".into()]),
    ]);
}

#[test]
fn semicolon_question_keeps_attached_source_and_targets_its_own_sentence_only() {
    check(vec![
        (
            "09:00 UTC. De beurs opent om 9:30 in Paris; hoe laat is dat in Sydney? 12:00 UTC."
                .into(),
            "nl",
            vec![
                "09:00 +0 > -".into(),
                "09:30 Europe/Paris > Australia/Sydney".into(),
                "12:00 +0 > -".into(),
            ],
        ),
        (
            "Paris'te 09:30 açılış; Sydney'de saat kaç?".into(),
            "tr",
            vec!["09:30 Europe/Paris > Australia/Sydney".into()],
        ),
        (
            "런던 오전 9시는 서울 몇 시예요?".into(),
            "ko",
            vec!["09:00 Europe/London > Asia/Seoul".into()],
        ),
    ]);
}

#[test]
fn unicode_and_ascii_arrows_target_only_the_written_time_before_them() {
    let mut cases = Vec::new();
    for arrow in ["→", "->"] {
        cases.push((
            format!("09:00 UTC. 15:00 KST {arrow} Sydney. 12:00 UTC."),
            "en",
            vec![
                "09:00 +0 > -".into(),
                "15:00 +540 > Australia/Sydney".into(),
                "12:00 +0 > -".into(),
            ],
        ));
        cases.push((
            format!("09:00 UTC, 10:00 UTC {arrow} Sydney."),
            "en",
            vec!["09:00 +0 > -".into(), "10:00 +0 > Australia/Sydney".into()],
        ));
        cases.push((
            format!("09:00 {arrow} Sydney."),
            "en",
            vec!["09:00 - > Australia/Sydney".into()],
        ));
    }
    check(cases);
}

#[test]
fn local_destination_with_written_source_contrasts_with_local_source_alone() {
    check(vec![
        (
            "09:00 UTC. 10:00 UTC. What time is that in my time?".into(),
            "en",
            vec!["09:00 +0 > local".into(), "10:00 +0 > local".into()],
        ),
        (
            "09:00 UTC. 10:00 UTC. 제 시간으로는 몇 시지?".into(),
            "ko",
            vec!["09:00 +0 > local".into(), "10:00 +0 > local".into()],
        ),
        (
            "09:00 UTC. 10:00 UTC. 私の時間では何時ですか？".into(),
            "ja",
            vec!["09:00 +0 > local".into(), "10:00 +0 > local".into()],
        ),
        (
            "my time 09:00.".into(),
            "en",
            vec!["09:00 local > -".into()],
        ),
        (
            "我这边 09:00。".into(),
            "zh-Hans",
            vec!["09:00 local > -".into()],
        ),
        (
            "benim saatimde 09:00.".into(),
            "tr",
            vec!["09:00 local > -".into()],
        ),
        (
            "09:00 UTC. My time 10:00.".into(),
            "en",
            vec!["09:00 +0 > -".into(), "10:00 local > -".into()],
        ),
        (
            "09:00 UTC. 我这边 10:00。".into(),
            "zh-Hans",
            vec!["09:00 +0 > -".into(), "10:00 local > -".into()],
        ),
        (
            "09:00 UTC → my time.".into(),
            "en",
            vec!["09:00 +0 > local".into()],
        ),
        (
            "09:00 → my time.".into(),
            "en",
            vec!["09:00 local > -".into()],
        ),
        (
            "09:00 my time.".into(),
            "en",
            vec!["09:00 local > -".into()],
        ),
        (
            "09:00 UTC. What time is that in my time? 12:00 UTC.".into(),
            "en",
            vec!["09:00 +0 > local".into(), "12:00 +0 > -".into()],
        ),
        (
            "09:00. What time is that in my time?".into(),
            "en",
            vec!["09:00 local > -".into()],
        ),
        (
            "09:00 UTC → meine Zeit.".into(),
            "de",
            vec!["09:00 +0 > local".into()],
        ),
        (
            "09:00 UTC; wat is dat in mijn tijd?".into(),
            "nl",
            vec!["09:00 +0 > local".into()],
        ),
        (
            "09:00 UTC, 제 시간으로는 몇 시지?".into(),
            "ko",
            vec!["09:00 +0 > local".into()],
        ),
        (
            "09:00 UTC, nel mio fuso orario.".into(),
            "it",
            vec!["09:00 +0 > local".into()],
        ),
        (
            "09:00 UTC, tính theo giờ của tôi.".into(),
            "vi",
            vec!["09:00 +0 > local".into()],
        ),
        (
            "09:00 UTC, benim saatimde.".into(),
            "tr",
            vec!["09:00 +0 > local".into()],
        ),
    ]);
}

#[test]
fn sixteen_languages_unknown_question_target_has_target_role_and_no_source_pollution() {
    let mut cases = Vec::new();
    for &(lang, question, city, _) in QUESTIONS {
        let unknown = question.replace(city, "Tokiio");
        cases.push((
            format!("09:00 UTC. {unknown} 12:00 UTC."),
            lang,
            vec!["09:00 +0 > - !target:Tokiio".into(), "12:00 +0 > -".into()],
        ));
        cases.push((
            format!("09:00, {unknown}"),
            lang,
            vec!["09:00 - > - !target:Tokiio".into()],
        ));
    }
    check(cases);
}

#[test]
fn unknown_arrow_destination_is_not_a_source_or_sentence_suggestion() {
    check(vec![
        (
            "09:00 UTC → Tokiio. 12:00 UTC.".into(),
            "en",
            vec!["09:00 +0 > - !target:Tokiio".into(), "12:00 +0 > -".into()],
        ),
        (
            "09:00 -> Tokiio.".into(),
            "en",
            vec!["09:00 - > - !target:Tokiio".into()],
        ),
        (
            "09:00 UTC. What time is that in Tokiio? 10:00 UTC. What time is that in Berlin?"
                .into(),
            "en",
            vec![
                "09:00 +0 > - !target:Tokiio".into(),
                "10:00 +0 > Europe/Berlin".into(),
            ],
        ),
    ]);
}

#[test]
fn unknown_target_spans_refer_to_original_destination_text() {
    for text in [
        "09:00 UTC. What time is that in Tokiio?",
        "09:00 UTC -> Tokiio.",
        "🙂 09:00 UTC. What time is that in Tokiio?",
        "09:00 UTC. Tokiio'da saat kaç?",
    ] {
        let mentions = read(text, "en");
        assert_eq!(
            snapshot(&mentions),
            ["09:00 +0 > - !target:Tokiio"],
            "{text}"
        );
        let mention = &mentions[0];
        let unresolved = &mention.unresolved[0];
        let utf16: Vec<u16> = text.encode_utf16().collect();
        assert_eq!(
            String::from_utf16(&utf16[unresolved.span[0]..unresolved.span[1]]).unwrap(),
            "Tokiio"
        );
        assert_eq!(unresolved.role, "target");
        assert!(
            !mention
                .parts
                .iter()
                .any(|part| matches!(part.kind, "place" | "zone") && part.span == unresolved.span),
            "{mention:?}"
        );
    }
}

#[test]
fn ordinary_location_or_counterpart_wording_does_not_create_a_target() {
    check(vec![
        (
            "09:00 UTC. The hotel in Sydney is open. 12:00 UTC.".into(),
            "en",
            vec!["09:00 +0 > -".into(), "12:00 +0 > -".into()],
        ),
        (
            "09:00 UTC with the Sydney team.".into(),
            "en",
            vec!["09:00 +0 > -".into()],
        ),
        (
            "09:00 UTC. Sydney?".into(),
            "en",
            vec!["09:00 +0 > -".into()],
        ),
    ]);
}

#[test]
fn contiguous_cjk_clock_topic_and_destination_preserve_the_written_source() {
    check(vec![
        (
            "08:00 UTC. ロンドン午前9時は東京では何時ですか。12:00 UTC.".into(),
            "ja",
            vec![
                "08:00 +0 > -".into(),
                "09:00 Europe/London > Asia/Tokyo".into(),
                "12:00 +0 > -".into(),
            ],
        ),
        (
            "08:00 UTC. 런던오전9시는서울몇시예요? 12:00 UTC.".into(),
            "ko",
            vec![
                "08:00 +0 > -".into(),
                "09:00 Europe/London > Asia/Seoul".into(),
                "12:00 +0 > -".into(),
            ],
        ),
        (
            "08:00 UTC. 東京明早九点是纽约几点？12:00 UTC.".into(),
            "zh-Hans",
            vec![
                "08:00 +0 > -".into(),
                "09:00 Asia/Tokyo > America/New_York".into(),
                "12:00 +0 > -".into(),
            ],
        ),
    ]);
    let mentions = read("東京明早九点是纽约几点？", "zh-Hans");
    assert_eq!(snapshot(&mentions), ["09:00 Asia/Tokyo > America/New_York"]);
    assert_eq!(
        mentions[0].date,
        Some(DateSpec::Offset { days: 1 }),
        "the explicit tomorrow morning remains attached: {mentions:?}"
    );
}

#[test]
fn reverse_questions_target_their_own_later_clock_and_leave_other_sentences_alone() {
    let questions = [
        (
            "es",
            "¿Qué hora será en Madrid a las 09:00 UTC?",
            "Europe/Madrid",
        ),
        (
            "fr",
            "Quelle heure sera-t-il à Paris à 09:00 UTC ?",
            "Europe/Paris",
        ),
        (
            "it",
            "Che ore saranno a Roma alle 09:00 UTC?",
            "Europe/Rome",
        ),
        (
            "nl",
            "Hoe laat is het in Amsterdam om 09:00 UTC?",
            "Europe/Amsterdam",
        ),
        (
            "pl",
            "Która godzina będzie w Warszawie o 09:00 UTC?",
            "Europe/Warsaw",
        ),
        (
            "ru",
            "Во сколько это будет в Москве в 09:00 UTC?",
            "Europe/Moscow",
        ),
        (
            "tr",
            "Berlin'de saat kaç olur, saat 09:00 UTC olduğunda?",
            "Europe/Berlin",
        ),
    ];
    check(
        questions
            .iter()
            .map(|&(lang, question, iana)| {
                (
                    format!("08:00 UTC. {question} 12:00 UTC."),
                    lang,
                    vec![
                        "08:00 +0 > -".into(),
                        format!("09:00 +0 > {iana}"),
                        "12:00 +0 > -".into(),
                    ],
                )
            })
            .collect(),
    );
}

#[test]
fn closed_topic_now_and_particle_questions_keep_destination_role() {
    check(vec![
        (
            "09:00 UTC. 東京は今何時ですか？12:00 UTC.".into(),
            "ja",
            vec!["09:00 +0 > Asia/Tokyo".into(), "12:00 +0 > -".into()],
        ),
        (
            "09:00 UTC. Tokiio은 몇 시인가요? 12:00 UTC.".into(),
            "ko",
            vec!["09:00 +0 > - !target:Tokiio".into(), "12:00 +0 > -".into()],
        ),
        (
            "09:00 UTC. 서울은 몇 시인가요? 12:00 UTC.".into(),
            "ko",
            vec!["09:00 +0 > Asia/Seoul".into(), "12:00 +0 > -".into()],
        ),
    ]);
}

#[test]
fn adjacent_zone_arrow_targets_preserve_source_and_ordinary_local_words_have_no_role() {
    check(vec![
        ("09:00CET→UTC".into(), "en", vec!["09:00 +60 > +0".into()]),
        ("09:00CET->UTC".into(), "en", vec!["09:00 +60 > +0".into()]),
        (
            "09:00CET→Tokiio".into(),
            "en",
            vec!["09:00 +60 > - !target:Tokiio".into()],
        ),
        (
            "09:00 UTC. My time is precious. 12:00 UTC.".into(),
            "en",
            vec!["09:00 +0 > -".into(), "12:00 +0 > -".into()],
        ),
        (
            "09:00 UTC. Mytimeisprecious. 12:00 UTC.".into(),
            "en",
            vec!["09:00 +0 > -".into(), "12:00 +0 > -".into()],
        ),
    ]);
}

#[test]
fn vietnamese_arrow_preserves_written_source_before_multiword_destination() {
    check(vec![
        (
            "Mở cửa: 10:00 giờ Moskva -> Hà Nội.".into(),
            "vi",
            vec!["10:00 Europe/Moscow > Asia/Ho_Chi_Minh".into()],
        ),
        (
            "Mở cửa: 10:00 giờ Moskva → Hà Nội. 12:00 UTC.".into(),
            "vi",
            vec![
                "10:00 Europe/Moscow > Asia/Ho_Chi_Minh".into(),
                "12:00 +0 > -".into(),
            ],
        ),
    ]);
}

#[test]
fn adjacent_local_source_belongs_to_the_following_clock_after_comma_or_semicolon() {
    check(vec![
        (
            "09:00 UTC; my time 10:00.".into(),
            "en",
            vec!["09:00 +0 > -".into(), "10:00 local > -".into()],
        ),
        (
            "09:00 UTC, my time 10:00.".into(),
            "en",
            vec!["09:00 +0 > -".into(), "10:00 local > -".into()],
        ),
        (
            "09:00 UTC my time. 10:00.".into(),
            "en",
            vec!["09:00 +0 > local".into(), "10:00 - > -".into()],
        ),
    ]);
}

#[test]
fn date_before_reverse_question_stays_with_its_own_clock_and_does_not_change_scope() {
    let absolute = "2026-10-02 What time in Tokyo at 09:00 UTC?";
    let relative = "Tomorrow, what time in Tokyo at 09:00 UTC?";
    let prior = "08:00 UTC. Tomorrow, what time in Tokyo at 09:00 UTC?";
    check(vec![
        (absolute.into(), "en", vec!["09:00 +0 > Asia/Tokyo".into()]),
        (relative.into(), "en", vec!["09:00 +0 > Asia/Tokyo".into()]),
        (
            prior.into(),
            "en",
            vec!["08:00 +0 > -".into(), "09:00 +0 > Asia/Tokyo".into()],
        ),
    ]);
    let mentions = read(absolute, "en");
    assert_eq!(
        mentions[0].date,
        Some(DateSpec::Absolute {
            year: 2026,
            month: 10,
            day: 2
        }),
        "{mentions:?}"
    );
    for (text, mention_index) in [(relative, 0), (prior, 1)] {
        let mentions = read(text, "en");
        assert_eq!(
            mentions[mention_index].date,
            Some(DateSpec::Offset { days: 1 }),
            "{text}: {mentions:?}"
        );
        assert!(
            mentions[mention_index].parts.iter().any(|part| part.kind == "date"),
            "{text}: {mentions:?}"
        );
    }
}

#[test]
fn korean_destination_names_starting_with_si_keep_their_first_syllable() {
    let message = "서울 오후 2시 발표는 시드니에서 몇 시인가요? 자료는 3시간 후에 보내 드릴게요.";
    check(vec![
        (
            message.into(),
            "ko",
            vec![
                "14:00 Asia/Seoul > Australia/Sydney".into(),
                "- - > -".into(),
            ],
        ),
        (
            "09:00, 시드니에서 몇 시인가요?".into(),
            "ko",
            vec!["09:00 - > Australia/Sydney".into()],
        ),
        (
            "09:00, 시토키오에서 몇 시인가요?".into(),
            "ko",
            vec!["09:00 - > - !target:시토키오".into()],
        ),
    ]);
    let mentions = read(message, "ko");
    assert_eq!(
        mentions[1].relative_minutes,
        Some(180),
        "the later relative time stays a separate untargeted mention: {mentions:?}"
    );
    let text = "09:00, 시토키오에서 몇 시인가요?";
    let mentions = read(text, "ko");
    let unresolved = &mentions[0].unresolved[0];
    assert_eq!(unresolved.role, "target");
    let utf16: Vec<u16> = text.encode_utf16().collect();
    assert_eq!(
        String::from_utf16(&utf16[unresolved.span[0]..unresolved.span[1]]).unwrap(),
        "시토키오",
        "the span retains the city-name syllable 시"
    );
}

#[test]
fn plain_local_words_require_clock_adjacency_but_allow_a_following_date_and_period() {
    let simplified = "2026-10-02 09:00 UTC. 我这边明天下午4点。";
    let traditional = "2026-10-02 09:00 UTC. 我這邊明天下午4點。";
    let english = "09:00 UTC. My time tomorrow at 10:00.";
    check(vec![
        (
            "09:00 UTC is when I waste my time.".into(),
            "en",
            vec!["09:00 +0 > -".into()],
        ),
        (
            simplified.into(),
            "zh-Hans",
            vec!["09:00 +0 > -".into(), "16:00 local > -".into()],
        ),
        (
            traditional.into(),
            "zh-Hant",
            vec!["09:00 +0 > -".into(), "16:00 local > -".into()],
        ),
        (
            english.into(),
            "en",
            vec!["09:00 +0 > -".into(), "10:00 local > -".into()],
        ),
        (
            "09:00 UTC my time.".into(),
            "en",
            vec!["09:00 +0 > local".into()],
        ),
    ]);
    for (text, lang) in [
        (simplified, "zh-Hans"),
        (traditional, "zh-Hant"),
        (english, "en"),
    ] {
        let mentions = read(text, lang);
        assert_eq!(
            mentions[1].date,
            Some(DateSpec::Offset { days: 1 }),
            "the date belongs to the following local clock: {text}: {mentions:?}"
        );
        assert!(
            !mentions[1].date_inherited,
            "tomorrow is written for this clock: {text}: {mentions:?}"
        );
    }
}

#[test]
fn closed_conversion_connectors_and_glued_turkish_clock_case_preserve_targets() {
    check(vec![
        (
            "Le direct est à 10h, heure de Tokyo, soit mon heure locale.".into(),
            "fr",
            vec!["10:00 Asia/Tokyo > local".into()],
        ),
        (
            "Эфир в 10:00, время в Токио — это по моему времени.".into(),
            "ru",
            vec!["10:00 Asia/Tokyo > local".into()],
        ),
        (
            "Yayın Tokyo'da 10:00'da, benim saatimde.".into(),
            "tr",
            vec!["10:00 Asia/Tokyo > local".into()],
        ),
        (
            "10:00'da → Tokyo.".into(),
            "tr",
            vec!["10:00 - > Asia/Tokyo".into()],
        ),
        (
            "09:00 UTC is when I waste my time.".into(),
            "en",
            vec!["09:00 +0 > -".into()],
        ),
    ]);
}

#[test]
fn my_time_phrase_stays_inside_its_equivalence_group() {
    let groups = |text: &str| -> Vec<usize> { read(text, "en").iter().map(|m| m.group).collect() };
    // 「我这边」是那一处的一部分：斜杠两边仍是同一刻，宿主才能由纽约那处推出写信人的偏移。
    assert_eq!(groups("3pm my time / 9am New York"), vec![0, 0]);
    assert_eq!(groups("I'm in Tokyo. 3pm my time / 9am New York"), vec![0, 0]);
    assert_eq!(groups("9am New York / 3pm my time"), vec![0, 0]);
    // 对照：句号隔开就不是同一刻的两种写法。
    assert_eq!(groups("3pm my time. 9am New York."), vec![0, 1]);
}
