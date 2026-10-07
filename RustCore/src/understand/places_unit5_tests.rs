// SPDX-License-Identifier: GPL-3.0-only
use super::*;

fn lookup(text: &str, _: bool) -> Option<ZoneRef> {
    let key = text::fold_str(text);
    let iana = match key.as_str() {
        "berlin" => "Europe/Berlin",
        "tokyo" | "大阪" | "오사카" => "Asia/Tokyo",
        "paris" => "Europe/Paris",
        "нью-иорк" | "нью-иорке" => "America/New_York",
        "bar" => "Europe/Podgorica",
        "log" => "Europe/Warsaw",
        "부에노스아이레스" => "America/Argentina/Buenos_Aires",
        _ => return places::country_lookup(text),
    };
    Some(ZoneRef::City { city_index: 0, name: text.into(), iana: iana.into(), population: None })
}

fn source(text: &str, language: &str) -> Option<ZoneRef> {
    let out = understand(text, &Options { region: "US", ui_language: language, lookup: &lookup });
    assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
    out.mentions[0].source.clone()
}

#[test]
fn sentence_place_is_suggestion_and_attached_place_is_source() {
    let out = understand("The hotel in Berlin confirms check-in at 14:00.", &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert!(matches!(&out.mentions[0].source, Some(ZoneRef::Options { reason: "sentence", options }) if options.len() == 1));
    assert!(out.mentions[0].parts.iter().any(|p| p.kind == "place"));
    assert!(matches!(source("14:00 in Berlin", "en"), Some(ZoneRef::City { iana, .. }) if iana == "Europe/Berlin"));
    assert!(matches!(source("Meet with Alice in Tokyo at 09:00.", "en"), Some(ZoneRef::City { iana, .. }) if iana == "Asia/Tokyo"));
    assert!(matches!(source("Call with Alice at 14:00 in Tokyo.", "en"), Some(ZoneRef::City { iana, .. }) if iana == "Asia/Tokyo"));
    let unknown = understand("The hotel in Tokiio confirms check-in at 14:00.", &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert_eq!(unknown.mentions[0].unresolved[0].text, "Tokiio");
    assert!(matches!(source("The hotel in Tokyo confirms check-in at 14:00 my time.", "en"), Some(ZoneRef::Local)));
}

#[test]
fn counterpart_direction_and_two_places_do_not_suggest() {
    assert!(source("Через 3 часа вылет в Нью-Йорк.", "ru").is_none());
    assert!(matches!(source("Через 3 часа вылет в Нью-Йорке.", "ru"), Some(ZoneRef::City { iana, .. }) if iana == "America/New_York"));
    assert!(matches!(source("Через 3 часа в Нью-Йорке.", "ru"), Some(ZoneRef::City { iana, .. }) if iana == "America/New_York"));
    for text in ["The call with Berlin starts at 14:00.", "The train to Berlin departs at 14:00.", "The hotel in Berlin and office in Paris open at 14:00."] {
        assert!(!matches!(source(text, "en"), Some(ZoneRef::Options { reason: "sentence", .. })), "{text}");
    }
    for text in ["The hotel in Berlin opens at 14:00 and the office in Paris opens at 15:00.", "Çin'deki tedarikçiyle görüşme 08:00'de."] {
        let out = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup });
        assert!(out.mentions.iter().all(|m| !matches!(m.source, Some(ZoneRef::Options { reason: "sentence", .. }))), "{text}: {out:?}");
    }
    assert!(matches!(source("With breakfast included, the hotel in Tokyo opens at 14:00.", "en"), Some(ZoneRef::Options { reason: "sentence", .. })));
    assert!(matches!(source("14:00 in Tokyo. Kyle arrives.", "en"), Some(ZoneRef::City { .. })));
    let unknown = understand("The hotel in Berlin and the office in Tokiio open at 14:00.", &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert!(unknown.mentions[0].source.is_none());
    assert_eq!(unknown.mentions[0].unresolved[0].text, "Tokiio");
    let unknown = understand("The hotel in Berlin opens at 14:00, and the office in Tokiio opens at 15:00.", &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert_eq!(unknown.mentions.len(), 2);
    assert!(matches!(&unknown.mentions[0].source, Some(ZoneRef::Options { reason: "nearby", options })
        if matches!(options.as_slice(), [ZoneRef::City { iana, .. }, ZoneRef::Local] if iana == "Europe/Berlin")));
    assert!(unknown.mentions[1].source.is_none());
    assert!(unknown.mentions.iter().any(|m| m.unresolved.iter().any(|place| place.text == "Tokiio")));
    assert!(matches!(source("The hotel in Berlin and office in Berlin open at 14:00.", "en"), Some(ZoneRef::Options { reason: "sentence", .. })));
    assert!(matches!(source("The hotel in Tokyo has style and opens at 14:00.", "en"), Some(ZoneRef::Options { reason: "sentence", .. })));
}

#[test]
fn german_nouns_need_clues_and_lowercase_places_touch_clocks() {
    assert!(source("Die Bar öffnet um 14:00.", "de").is_none());
    assert!(matches!(source("14:00 in Berlin", "de"), Some(ZoneRef::City { .. })));
    assert!(matches!(source("14:00 berlin", "en"), Some(ZoneRef::City { .. })));
    assert!(source("berlin confirms check-in at 14:00", "en").is_none());
    assert!(source("berlin, check-in at 14:00", "en").is_none());
    assert!(source("14:00, tokyo", "en").is_none());
    assert!(matches!(source("14:00, Tokyo", "en"), Some(ZoneRef::City { .. })));
    assert!(source("Log recorded: 2026-09-29T18:30:00+02:00", "pl").is_none());
}

#[test]
fn korean_complete_place_names_survive_embedded_time_syllables() {
    for name in ["부에노스아이레스", "오사카"] {
        assert!(matches!(source(&format!("15:00 {name}"), "ko"), Some(ZoneRef::City { .. })), "{name}");
    }
}

#[test]
#[cfg(not(feature = "intents-only"))]
fn real_index_place_probe_and_location_morphology() {
    let opened = crate::city_index::dispatch("city.open", serde_json::json!({ "path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity") })).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |t: &str, strong| places::city_lookup(Some(handle), t, strong);
    let flight = understand("Через 3 часа вылет в Нью-Йорк.", &Options { region: "US", ui_language: "ru", lookup: &lookup });
    assert_eq!(flight.mentions.len(), 1);
    assert_eq!(flight.mentions[0].relative_minutes, Some(180));
    assert!(flight.mentions[0].source.is_none(), "{flight:?}");
    let departure = understand("Через 3 часа вылет в Нью-Йорке.", &Options { region: "US", ui_language: "ru", lookup: &lookup });
    assert_eq!(departure.mentions.len(), 1);
    assert_eq!(departure.mentions[0].relative_minutes, Some(180));
    let zone = match departure.mentions[0].source.as_ref() {
        Some(ZoneRef::Options { options, .. }) => options.first(),
        plain => plain,
    };
    assert!(matches!(zone, Some(ZoneRef::City { iana, .. }) if iana == "America/New_York"), "{departure:?}");
    let mut failures = Vec::new();
    for (language, sentence, iana, suggestion) in [
        ("ko", "15:00 부에노스아이레스", "America/Argentina/Buenos_Aires", false),
        ("ko", "15:00 오사카", "Asia/Tokyo", false),
        ("ru", "Фабрика в Китае запускает смену в 8:30.", "Asia/Shanghai", true),
        ("ko", "로스앤젤레스에서 열리는 콘서트는 저녁 7:30에 시작해요.", "America/Los_Angeles", true),
        ("it", "Ok team, il workshop è il 15/10 alle 10:00 a Monaco di Baviera.", "Europe/Berlin", false),
        ("es", "El mercado central abre a las 8:00 en Cracovia.", "Europe/Warsaw", false),
        ("ko", "15:00 오사카에서", "Asia/Tokyo", false),
        ("pt-BR", "15:00 Cidade do México", "America/Mexico_City", false),
        ("ko", "2026년 10월 18일 19:45부터 21:15까지 시드니 기준", "Australia/Sydney", false),
        ("nl", "Onze winkel in Duitsland gaat om 9:00 open.", "Europe/Berlin", true),
        ("vi", "Thứ sáu 18:30 mình ra đón bạn ở Bruxelles.", "Europe/Brussels", false),
        ("ru", "Коллеги на Филиппинах выходят в 10:00.", "Asia/Manila", true),
        ("ru", "В Стамбуле стыковка в 11:20.", "Europe/Istanbul", true),
        ("tr", "Japonya'daki mağazada satış 09:00'da başlıyor.", "Asia/Tokyo", true),
        ("ja", "日本の夕方6時からテレビ放送です。", "Asia/Tokyo", false),
        ("ko", "일본 공장은 오전 8시에 가동을 시작해요.", "Asia/Tokyo", true),
        ("ru", "Встреча в\u{200b} 15:00 в\u{200b} Берлине.", "Europe/Berlin", false),
    ] {
        let out = understand(sentence, &Options { region: "US", ui_language: language, lookup: &lookup });
        let zone = out.mentions.first().and_then(|m| m.source.as_ref());
        let selected = match zone {
            Some(ZoneRef::Options { reason: "sentence", options }) if suggestion => options.first(),
            plain if !suggestion => plain,
            _ => None,
        };
        let selected = match selected { Some(ZoneRef::Options { options, .. }) => options.first(), plain => plain };
        if !matches!(selected, Some(ZoneRef::City { iana: actual, .. } | ZoneRef::Region { iana: actual }) if actual == iana) {
            failures.push(format!("{sentence}: {out:?}"));
        }
    }
    crate::city_index::dispatch("city.close", serde_json::json!({ "handle": handle })).unwrap();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn possessive_time_and_at_our_place_are_distinct() {
    assert!(source("De bus stopt om 7:40 bij ons.", "nl").is_none());
    assert!(source("Вечером в 19:30 у нас йога.", "ru").is_none());
    assert!(source("В 9 часов утра у меня стоматолог.", "ru").is_none());
    assert!(matches!(source("15:00 ora mia", "it"), Some(ZoneRef::Local)));
    assert!(matches!(source("15:00 mon heure", "fr"), Some(ZoneRef::Local)));
    assert!(matches!(source("18:00 МСК", "ru"), Some(ZoneRef::Fixed { minutes: 180, .. })));
}

#[test]
fn writer_location_suggests_only_in_its_sentence() {
    let options = Options { region: "US", ui_language: "en", lookup: &lookup };
    let out = understand("I'm in Berlin, call me at 4pm", &options);
    assert!(out.writer.is_some());
    assert!(matches!(out.mentions[0].source, Some(ZoneRef::Options { reason: "sentence", .. })));
    let out = understand("I'm in Berlin. Call me at 4pm", &options);
    assert!(out.mentions[0].source.is_none());
    let out = understand("I'm in Berlin, call me at 4pm my time", &options);
    assert_eq!(out.mentions[0].source, Some(ZoneRef::Local));
}

#[test]
#[cfg(not(feature = "intents-only"))]
fn country_suggestions_keep_display_identity_and_ordinary_nouns_do_not_supply_zones() {
    let opened = crate::city_index::dispatch("city.open", serde_json::json!({ "path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity") })).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |t: &str, strong| places::city_lookup(Some(handle), t, strong);
    for text in ["I live in Japan; call at 14:00", "日本にいます、14時に電話してください。", "The support team in Japan opens at 14:00."] {
        let out = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup });
        assert_eq!(out.mentions[0].sentence_place_country.as_deref(), Some("JP"), "{text}: {out:?}");
        assert!(serde_json::to_value(&out.mentions[0]).unwrap().get("sentencePlaceCountry").is_some());
    }
    for (language, text) in [
        ("en", "Library story time is at 10:15."),
        ("en", "She texted 5 minutes ago."),
        ("es", "Cita médica: 09:15, consultorio 4, piso 7."),
        ("ja", "ドラマの再放送は13:05から。"),
        ("fr", "La sauvegarde a eu lieu le 2026-12-07T14:30:00Z."),
        ("fr", "L'événement a été enregistré avec unix 1774452000."),
        ("nl", "Gisteren om 19:00 keek ik de wedstrijd op de bank."),
        ("tr", "Zamanlayıcı 12:60'a kurulu."),
        ("vi", "Giờ nghỉ trưa từ 13:00 đến 14:00."),
    ] {
        let out = understand(text, &Options { region: "US", ui_language: language, lookup: &lookup });
        assert!(out.mentions.iter().all(|m| m.source.is_none() && m.target.is_none() && m.unresolved.is_empty()), "{text}: {out:?}");
    }
    let text = "I'm in Berlin, the Toronto office is closed and the meeting is at 09:00.";
    let out = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert!(out.mentions[0].source.is_none(), "{text}: {out:?}");
    let out = understand("I'm in New York, the New York office is open and the call is at 09:00.", &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert!(matches!(out.mentions[0].source, Some(ZoneRef::Options { reason: "sentence", .. })), "{out:?}");
    crate::city_index::dispatch("city.close", serde_json::json!({ "handle": handle })).unwrap();
}

#[test]
fn lowercase_place_heads_do_not_resolve_or_become_targets() {
    // Lead, 10-02: in cased text a lowercase word after a place cue counts only when it names one of the 2,000 largest
    // cities; a misspelled or small one is ignored.
    let out = understand("The hotel in tokiio Berlin opens at 14:00.", &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert!(out.mentions[0].source.is_none(), "{out:?}");
    assert!(out.mentions[0].unresolved.is_empty(), "{out:?}");
    assert!(matches!(source("The hotel in berlin confirms check-in at 14:00.", "en"), Some(ZoneRef::Options { reason: "sentence", .. })));
    // "<time> <zone> in <city>" keeps the converter's target reading, lowercase or not.
    let out = understand("The call is at 14:00 UTC in berlin.", &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert!(matches!(out.mentions[0].source, Some(ZoneRef::Fixed { minutes: 0, .. })), "{out:?}");
    assert!(matches!(&out.mentions[0].target, Some(ZoneRef::City { iana, .. }) if iana == "Europe/Berlin"), "{out:?}");
    let out = understand("Rapat jam 14:00 UTC di berlin jam berapa?", &Options { region: "US", ui_language: "id", lookup: &lookup });
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert!(matches!(out.mentions[0].source, Some(ZoneRef::Fixed { minutes: 0, .. })), "{out:?}");
    assert!(matches!(&out.mentions[0].target, Some(ZoneRef::City { iana, .. }) if iana == "Europe/Berlin"), "{out:?}");
    assert!(matches!(source("the hotel in berlin confirms check-in at 14:00", "en"), Some(ZoneRef::Options { reason: "sentence", .. })));
    assert!(matches!(source("Das Hotel in berlin öffnet um 14:00.", "de"), Some(ZoneRef::Options { reason: "sentence", .. })));
    let uncased_lookup = |text: &str, _: bool| (text == "القاهرة").then(|| ZoneRef::City { city_index: 0, name: text.into(), iana: "Africa/Cairo".into(), population: None });
    let out = understand("The hotel in القاهرة confirms check-in at 14:00.", &Options { region: "US", ui_language: "en", lookup: &uncased_lookup });
    assert!(matches!(out.mentions[0].source, Some(ZoneRef::Options { reason: "sentence", .. })), "{out:?}");
}

#[test]
fn lowercase_explicit_prepositional_targets_need_capitals_in_cased_text() {
    // Lead, 10-02: lowercase big cities ("tokyo") are targets like capitalised ones; only a misspelled or small one is ignored.
    for text in ["Convert 14:00 UTC to tokyo.", "14:00 UTC, What time in tokyo?", "14:00 UTC. What time in tokyo?"] {
        let out = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup });
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert!(matches!(&out.mentions[0].target, Some(ZoneRef::City { iana, .. }) if iana == "Asia/Tokyo"), "{text}: {out:?}");
    }
    let out = understand("14:00 UTC. What time in tokiio?", &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert!(matches!(out.mentions[0].source, Some(ZoneRef::Fixed { minutes: 0, .. })), "{out:?}");
    assert!(out.mentions[0].target.is_none(), "{out:?}");
    assert_eq!(out.mentions[0].unresolved.iter().map(|u| (u.text.as_str(), u.role)).collect::<Vec<_>>(), vec![("tokiio", "target")], "{out:?}");
    for (text, language) in [
        ("Convert 14:00 UTC to Tokyo.", "en"),
        ("14:00 UTC. What time in Tokyo?", "en"),
        ("convert 14:00 utc to tokyo", "en"),
        ("14:00 utc. what time in tokyo?", "en"),
        ("Konvertiere 14:00 UTC nach tokyo.", "de"),
        ("Convert 14:00 UTC → tokyo.", "en"),
        ("14:00 UTC 换成 tokyo", "zh"),
    ] {
        let out = understand(text, &Options { region: "US", ui_language: language, lookup: &lookup });
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert!(matches!(&out.mentions[0].target, Some(ZoneRef::City { iana, .. }) if iana == "Asia/Tokyo"), "{text}: {out:?}");
    }
}
