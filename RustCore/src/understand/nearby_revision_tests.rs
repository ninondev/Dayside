// SPDX-License-Identifier: GPL-3.0-only
use super::*;

fn read(text: &str, language: &str) -> Output {
    understand(text, &Options { region: "US", ui_language: language, lookup: &|name, _| {
        if let Some(country) = places::country_lookup(name) { return Some(country); }
        let name = fold_str(name);
        if !["berlin", "ende", "ドラマ", "柏林", "берлин", "ベルリン", "베를린", "berlim", "berlino"].contains(&name.as_str()) { return None; }
        Some(ZoneRef::City { city_index: if ["ende", "ドラマ"].contains(&name.as_str()) { 3_000 } else { 10 },
            name, iana: "Europe/Berlin".into(), population: None })
    } })
}

#[test]
fn nearby_revision_preserves_existing_definite_source() {
    for (language, text) in [
        ("zh-Hans", "中国全国统一 18点"), ("zh-Hant", "中國全國統一 18點"),
        ("en", "in Berlin at 18:00"), ("de", "in Berlin um 18:00"),
        ("fr", "en France à 18:00"), ("id", "di Singapura pukul 18:00"),
    ] {
        let out = read(text, language);
        assert!(!out.mentions.is_empty(), "{text}: {out:?}");
        assert!(out.mentions.iter().all(|m| m.source.is_some() && !matches!(m.source, Some(ZoneRef::Options { .. }))), "{text}: {out:?}");
        assert!(out.mentions.iter().all(|m| !matches!(m.source,
            Some(ZoneRef::Options { reason: "nearby", .. }))), "{text}: {out:?}");
    }
}

#[test]
fn nearby_revision_rejects_small_cities_even_in_mid_sentence() {
    for (language, text) in [("en", "we have Ende sync at 18:00"),
        ("ja", "ドラマ 会議 18時"), ("id", "Saya tiba sekitar 4:30")] {
        let out = read(text, language);
        assert!(out.mentions.iter().all(|m| !matches!(m.source,
            Some(ZoneRef::Options { reason: "nearby", .. }))), "{text}: {out:?}");
    }
}

#[cfg(not(feature = "intents-only"))]
#[test]
fn nearby_revision_real_index_ordinary_sentences_in_all_languages() {
    let opened = crate::city_index::dispatch("city.open", serde_json::json!({"path":
        concat!(env!("CARGO_MANIFEST_DIR"), "/../Dayside/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    for (language, text) in [
        ("en", "I arrive around 4:30"), ("zh-Hans", "我大约4点30分到"),
        ("zh-Hant", "我們12點見面"), ("ja", "私は4時30分ごろ到着します"),
        ("ko", "우리는 12시에 만나요"), ("de", "Ich komme gegen 4:30 an"),
        ("fr", "Je viens vers 4:30"), ("es", "Nos vemos a las 12:00"),
        ("ru", "Я приду около 4:30"), ("pt-BR", "Eu chego por volta de 4:30"),
        ("it", "Ci vediamo alle 12:00"), ("nl", "Ik kom rond 4:30"),
        ("pl", "Spotykamy się o 12:00"), ("tr", "Saat 4:30 gibi gelirim"),
        ("vi", "Chúng tôi gặp nhau lúc 4:30"), ("id", "Saya tiba sekitar 4:30"), ("id", "Kota ini sepi sekitar 4:30"),
    ] {
        let lookup = |name: &str, strong: bool| city_lookup(Some(handle), name, strong);
        let out = understand(text, &Options { region: "US", ui_language: language, lookup: &lookup });
        assert!(out.mentions.iter().any(|m| m.time.is_some()), "{text}: {out:?}");
        assert!(out.mentions.iter().all(|m| !matches!(m.source,
            Some(ZoneRef::Options { reason: "nearby", .. }))), "{text}: {out:?}");
    }
    crate::city_index::dispatch("city.close", serde_json::json!({"handle": handle})).unwrap();
}

#[test]
fn nearby_revision_ranked_city_candidates_in_all_languages() {
    for (language, text) in [
        ("en", "Berlin sync at 18:00"), ("zh-Hans", "柏林 同步 18点"),
        ("zh-Hant", "柏林 同步 18點"), ("ja", "ベルリン 会議 18時"),
        ("ko", "베를린 회의 18시"), ("de", "Berlin Besprechung um 18:00"),
        ("fr", "Berlin réunion à 18:00"), ("es", "Berlin reunión a las 18:00"),
        ("ru", "Берлин встреча в 18:00"), ("pt-BR", "Berlim reunião às 18:00"),
        ("it", "Berlino riunione alle 18:00"), ("nl", "Berlin overleg om 18:00"),
        ("pl", "Berlin spotkanie o 18:00"), ("tr", "Berlin toplantı saat 18:00"),
        ("vi", "Berlin hop luc 18:00"), ("id", "Berlin rapat pukul 18:00"),
    ] {
        let out = read(text, language);
        assert!(matches!(&out.mentions[0].source, Some(ZoneRef::Options { reason: "nearby", options })
            if matches!(options.first(), Some(ZoneRef::City { city_index: 10, .. })) && options.last() == Some(&ZoneRef::Local)), "{text}: {out:?}");
    }
}

#[test]
fn nearby_revision_filters_every_city_alternative() {
    let city = |rank| ZoneRef::City { city_index: rank, name: "Berlin".into(), iana: "Europe/Berlin".into(), population: None };
    let out = understand("Berlin sync at 18:00", &Options { region: "US", ui_language: "en", lookup: &|name, _|
        (fold_str(name) == "berlin").then(|| ZoneRef::Options { reason: "city", options: vec![city(10), city(3_000)] }) });
    assert_eq!(out.mentions[0].source, Some(ZoneRef::Options { reason: "nearby", options: vec![city(10), ZoneRef::Local] }));
}

#[cfg(not(feature = "intents-only"))]
#[test]
fn nearby_revision_complete_names_and_cjk_prefixes() {
    let opened = crate::city_index::dispatch("city.open", serde_json::json!({"path":
        concat!(env!("CARGO_MANIFEST_DIR"), "/../Dayside/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    for (text, language, iana) in [("Los Angeles team at 9", "en", "America/Los_Angeles"),
        ("New York sync at 18:00", "en", "America/New_York"), ("San José sync at 18:00", "en", "America/Costa_Rica"),
        ("上海 同步 18点", "zh-Hans", "Asia/Shanghai")] {
        let lookup = |name: &str, strong: bool| city_lookup(Some(handle), name, strong);
        let out = understand(text, &Options { region: "US", ui_language: language, lookup: &lookup });
        assert!(matches!(&out.mentions[0].source, Some(ZoneRef::Options { reason: "nearby", options })
            if options.iter().any(|z| matches!(z, ZoneRef::City { iana: zone, .. } if zone == iana)
                || matches!(z, ZoneRef::Options { reason: "city", options } if options.iter().any(|z| matches!(z, ZoneRef::City { iana: zone, .. } if zone == iana))))
            && options.last() == Some(&ZoneRef::Local)), "{text}: {out:?}");
    }
    crate::city_index::dispatch("city.close", serde_json::json!({"handle": handle})).unwrap();
}

#[test]
fn nearby_revision_keeps_existing_country_options() {
    let out = read("di Indonesia pukul 18:00", "id");
    assert_eq!(out.mentions[0].source, places::country_lookup("Indonesia"));
}

#[test]
fn nearby_revision_lead_reproduction_ranked_source_and_other_mentions() {
    let text = "Kickoff tomorrow 9am PST, Berlin sync at 18:00, report due Oct 20.";
    let out = read(text, "en");
    let control = read("Kickoff tomorrow 9am PST, sync 18:00 Berlin, report due Oct 20.", "en");
    assert_eq!(out.mentions.len(), 3);
    assert!(matches!(&out.mentions[1].source, Some(ZoneRef::Options { reason: "nearby", options })
        if matches!(options.first(), Some(ZoneRef::City { city_index: 10, iana, .. }) if iana == "Europe/Berlin")
        && options.last() == Some(&ZoneRef::Local)));
    assert_eq!(out.mentions[1].date, Some(DateSpec::Offset { days: 1 }));
    assert_eq!(out.mentions[1].time, Some(Clock::at(18, 0)));
    for index in [0, 2] {
        let mut actual = serde_json::to_value(&out.mentions[index]).unwrap();
        let mut expected = serde_json::to_value(&control.mentions[index]).unwrap();
        for key in ["span", "parts"] {
            actual.as_object_mut().unwrap().remove(key);
            expected.as_object_mut().unwrap().remove(key);
        }
        assert_eq!(actual, expected);
    }
}

#[test]
fn nearby_revision_never_uses_an_article_as_a_city() {
    for (language, text) in [("fr", "La Conversation à 18:00"), ("es", "Los Documentos a las 18:00")] {
        let out = understand(text, &Options { region: "US", ui_language: language, lookup: &|name, _|
            ["la", "los"].contains(&fold_str(name).as_str()).then(|| ZoneRef::City {
                city_index: 10, name: "Los Angeles".into(), iana: "America/Los_Angeles".into(), population: None }) });
        assert!(out.mentions.iter().all(|m| !matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{text}: {out:?}");
    }
}

#[test]
fn nearby_revision_unknown_lowercase_prose_does_not_hide_city() {
    let out = read("support berlin sync at 18:00", "en");
    assert!(matches!(&out.mentions[0].source, Some(ZoneRef::Options { reason: "nearby", options })
        if matches!(options.first(), Some(ZoneRef::City { city_index: 10, .. })) && options.last() == Some(&ZoneRef::Local)));
}

#[test]
fn nearby_revision_common_nouns_use_the_sentence_language() {
    let lookup = |name: &str, _: bool| (fold_str(name) == "reading").then(|| ZoneRef::City {
        city_index: 10, name: "Reading".into(), iana: "Europe/London".into(), population: None });
    let french = understand("Reading réunion à 18:00", &Options { region: "US", ui_language: "fr", lookup: &lookup });
    assert!(matches!(french.mentions[0].source, Some(ZoneRef::Options { reason: "nearby", .. })), "{french:?}");
    let english = understand("Reading discussion at 18:00", &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert!(english.mentions.iter().all(|m| !matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{english:?}");
}

#[test]
fn nearby_revision_multiple_famous_places_remain_candidates() {
    let lookup = |name: &str, _: bool| {
        let (index, name, iana) = match fold_str(name).as_str() {
            "berlin" => (10, "Berlin", "Europe/Berlin"), "tokyo" => (20, "Tokyo", "Asia/Tokyo"), _ => return None,
        };
        Some(ZoneRef::City { city_index: index, name: name.into(), iana: iana.into(), population: None })
    };
    let out = understand("Berlin Tokyo sync at 18:00", &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert!(matches!(&out.mentions[0].source, Some(ZoneRef::Options { reason: "nearby", options })
        if matches!(options.as_slice(), [ZoneRef::City { city_index: 20, .. }, ZoneRef::City { city_index: 10, .. }, ZoneRef::Local])), "{out:?}");
}

#[cfg(not(feature = "intents-only"))]
#[test]
fn nearby_new_york_primary_and_previous_spelling_offer_city_then_local() {
    let opened = crate::city_index::dispatch("city.open", serde_json::json!({"path":
        concat!(env!("CARGO_MANIFEST_DIR"), "/../Dayside/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    for text in ["New York sync at 18:00", "New York City sync at 18:00"] {
        let lookup = |name: &str, strong: bool| city_lookup(Some(handle), name, strong);
        let out = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup });
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(out.mentions[0].time, Some(Clock::at(18, 0)));
        assert!(matches!(&out.mentions[0].source, Some(ZoneRef::Options { reason: "nearby", options })
            if matches!(options.as_slice(), [ZoneRef::City { name, iana, .. }, ZoneRef::Local]
                if name == "New York" && iana == "America/New_York")), "{text}: {out:?}");
        println!("{text} => {:?}", out.mentions[0].source);
    }
    crate::city_index::dispatch("city.close", serde_json::json!({"handle": handle})).unwrap();
}
