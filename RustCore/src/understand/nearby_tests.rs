// SPDX-License-Identifier: GPL-3.0-only
use super::*;

fn read(text: &str, language: &str) -> Output {
    understand(text, &Options { region: "US", ui_language: language, lookup: &|name, _| {
        let folded = fold_str(name);
        let iana = match folded.as_str() {
            "berlin" | "柏林" | "ベルリン" | "베를린" | "берлин" | "berlim" | "berlino" => "Europe/Berlin",
            "tokyo" | "東京" | "东京" => "Asia/Tokyo",
            _ => return None,
        };
        Some(proven_city_in(iana, language))
    } })
}

fn assert_nearby(text: &str, language: &str, iana: &str) {
    let out = read(text, language);
    assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
    assert_eq!(out.mentions[0].source, Some(ZoneRef::Options { reason: "nearby", options: vec![
        proven_city_in(iana, language), ZoneRef::Local,
    ] }), "{text}: {out:?}");
}

#[test]
fn nearby_place_lead_defect_preserves_other_mentions() {
    let defect = read("Kickoff tomorrow 9am PST, Berlin sync at 18:00, report due Oct 20.", "en");
    let control = read("Kickoff tomorrow 9am PST, sync 18:00 Berlin, report due Oct 20.", "en");
    assert_eq!(defect.mentions.len(), 3, "{defect:?}");
    let berlin = &defect.mentions[1];
    assert_eq!(berlin.source, Some(ZoneRef::Options { reason: "nearby", options: vec![
        proven_city("Europe/Berlin"), ZoneRef::Local,
    ] }));
    assert_eq!(berlin.time, Some(Clock::at(18, 0)));
    assert_eq!(berlin.date, Some(DateSpec::Offset { days: 1 }));
    assert_eq!(berlin.date_from, Some(0));
    for index in [0, 2] {
        let mut actual = serde_json::to_value(&defect.mentions[index]).unwrap();
        let mut expected = serde_json::to_value(&control.mentions[index]).unwrap();
        actual.as_object_mut().unwrap().remove("span");
        actual.as_object_mut().unwrap().remove("parts");
        expected.as_object_mut().unwrap().remove("span");
        expected.as_object_mut().unwrap().remove("parts");
        assert_eq!(actual, expected);
    }
    for text in [
        "kickoff tmrw 9am PST, sync 18:00 Berlin, report due oct 20",
        "明天9点PST开工，柏林18点同步，10月20日交报告",
        "report due oct 20. kickoff tmrw 9am PST, berlin sync at 18:00 Berlin",
    ] {
        let out = read(text, "en");
        let berlin = out.mentions.iter().find(|m| m.time == Some(Clock::at(18, 0))).unwrap();
        assert_eq!(berlin.source, Some(proven_city("Europe/Berlin")), "{text}: {out:?}");
    }
}

#[test]
fn nearby_place_positive_and_negative_in_sixteen_languages() {
    for (language, positive, negative) in [
        ("en", "Berlin sync at 18:00", "Berlin sync, at 18:00"),
        ("zh-Hans", "柏林 同步 18点", "柏林那边同步，18点"),
        ("zh-Hant", "柏林 同步 18點", "柏林那邊同步，18點"),
        ("ja", "ベルリン 会議 18時", "ベルリン 会議、18時"),
        ("ko", "베를린 회의 18시", "베를린 회의, 18시"),
        ("de", "Berlin Besprechung um 18:00", "Berlin Besprechung, um 18:00"),
        ("fr", "Berlin réunion à 18:00", "Berlin réunion, à 18:00"),
        ("es", "Berlin reunión a las 18:00", "Berlin reunión, a las 18:00"),
        ("ru", "Берлин встреча в 18:00", "Берлин встреча, в 18:00"),
        ("pt-BR", "Berlim reunião às 18:00", "Berlim reunião, às 18:00"),
        ("it", "Berlino riunione alle 18:00", "Berlino riunione, alle 18:00"),
        ("nl", "Berlin overleg om 18:00", "Berlin overleg, om 18:00"),
        ("pl", "Berlin spotkanie o 18:00", "Berlin spotkanie, o 18:00"),
        ("tr", "Berlin toplantı saat 18:00", "Berlin toplantı, saat 18:00"),
        ("vi", "Berlin hop luc 18:00", "Berlin hop, luc 18:00"),
        ("id", "Berlin rapat pukul 18:00", "Berlin rapat, pukul 18:00"),
    ] {
        assert_nearby(positive, language, "Europe/Berlin");
        let out = read(negative, language);
        assert!(out.mentions.iter().all(|m| !matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{negative}: {out:?}");
    }
}

#[test]
fn nearby_place_distance_mentions_direction_and_adjacency() {
    for text in ["Tokyo call 9am", "call with Tokyo team at 9", "Berlin one two three 18:00"] {
        assert_nearby(text, "en", if text.contains("Tokyo") { "Asia/Tokyo" } else { "Europe/Berlin" });
    }
    for text in ["Berlin one two three four 18:00", "Berlin sync 9am at 18:00", "Berlin sync tomorrow at 18:00",
        "Berlin sync UTC at 18:00", "Berlin sync; at 18:00", "Berlin sync. at 18:00", "Berlin sync - at 18:00",
        "Berlin sync\n\nat 18:00", "9am Berlin sync at 18:00", "18:00 sync with Berlin", "San sync at 18:00", "Ende sync at 18:00"] {
        let out = read(text, "en");
        let last = out.mentions.iter().find(|m| m.time == Some(Clock::at(18, 0))).unwrap();
        assert!(!matches!(last.source, Some(ZoneRef::Options { reason: "nearby", .. })), "{text}: {out:?}");
    }
    for text in ["Berlin 18:00", "18:00 Berlin", "Berlin time 18:00", "in Berlin at 18:00"] {
        let out = read(text, "en");
        assert_eq!(out.mentions[0].source, Some(if text == "Berlin time 18:00" {
            ZoneRef::Region { iana: "Europe/Berlin".into() }
        } else { proven_city("Europe/Berlin") }), "{text}: {out:?}");
    }
}

#[test]
fn nearby_place_keeps_existing_cjk_name_boundaries_and_german_strength() {
    for text in ["柏林墙展览 18点", "东京塔参观 18点", "柏林墙 展览 18点"] {
        let out = read(text, "zh-Hans");
        assert!(out.mentions.iter().all(|m| !matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{text}: {out:?}");
    }
    let out = understand("Zum Ende sync um 18:00", &Options { region: "US", ui_language: "en", lookup: &|name, _| {
        (fold_str(name) == "ende").then(|| ZoneRef::City { city_index: 3_000, name: "Ende".into(), iana: "Asia/Makassar".into(), population: Some(100_000) })
    } });
    assert!(out.mentions.iter().all(|m| !matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{out:?}");
    assert!(matches!(read("in Berlin sync at 18:00", "en").mentions[0].source, Some(ZoneRef::Options { reason: "sentence", .. })));
}

#[cfg(not(feature = "intents-only"))]
#[test]
fn nearby_place_real_index_respects_strength_and_country_table() {
    let opened = crate::city_index::dispatch("city.open", serde_json::json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    for text in ["Berlin sync at 18:00", "柏林 同步 18点", "call with Tokyo team at 9", "China sync at 18:00"] {
        let lookup = |name: &str, strong: bool| city_lookup(Some(handle), name, strong);
        let out = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup });
        assert!(out.mentions.iter().any(|m| matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{text}: {out:?}");
    }
    for text in ["Cita médica: 09:15, consultorio 4, piso 7.", "San sync at 18:00", "Vize sync at 18:00", "Zum Ende sync um 18:00", "柏林墙展览 18点", "ドラマの再放送は13:05から。"] {
        let lookup = |name: &str, strong: bool| city_lookup(Some(handle), name, strong);
        let out = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup });
        assert!(out.mentions.iter().all(|m| !matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{text}: {out:?}");
    }
    crate::city_index::dispatch("city.close", serde_json::json!({"handle": handle})).unwrap();
}

// 城市候选需要明确的索引排名；仅给地区时区不能证明知名度。
fn proven_city(iana: &str) -> ZoneRef {
    ZoneRef::City { city_index: 0, name: if iana == "Asia/Tokyo" { "Tokyo" } else { "Berlin" }.into(),
        iana: iana.into(), population: None }
}

fn proven_city_in(iana: &str, language: &str) -> ZoneRef {
    let mut city = proven_city(iana);
    if let ZoneRef::City { name, .. } = &mut city {
        *name = if iana == "Asia/Tokyo" { "Tokyo" } else { match language {
            "zh-Hans" => "柏林", "zh-Hant" => "柏林", "ja" => "ベルリン", "ko" => "베를린",
            "ru" => "Берлин", "pt-BR" => "Berlim", "it" => "Berlino", _ => "Berlin",
        } }.into();
    }
    city
}
