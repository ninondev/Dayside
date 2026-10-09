// SPDX-License-Identifier: GPL-3.0-only
use super::*;

#[cfg(not(feature = "intents-only"))]
fn read(text: &str, language: &str) -> Output {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../Dayside/Resources/cities.ttcity");
    let opened = crate::dispatch("city.open", serde_json::json!({"path": path})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = memoized_lookup(|name, strong| city_lookup(Some(handle), name, strong));
    let out = understand(text, &Options { region: "US", ui_language: language, lookup: &lookup });
    crate::dispatch("city.close", serde_json::json!({"handle":handle})).unwrap();
    out
}

#[cfg(not(feature = "intents-only"))]
#[test]
fn nearby_exact_lead_reproductions() {
    for (language, sentence) in [
        ("id", "Selasa ada rapat umum jam 10:00."), ("id", "Minggu ada lomba jam 16:00."),
        ("pt-BR", "Na quarta-feira vou ao médico às 14:30."), ("pt-BR", "Vou ao dentista às 14:30."),
        ("id", "ada rapat jam 10:00"),
    ] {
        let out = read(sentence, language);
        assert!(out.mentions.iter().any(|m| m.time.is_some()), "{sentence}: {out:?}");
        assert!(out.mentions.iter().all(|m| !matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{sentence}: {out:?}");
    }
    let out = read("Berlin sync at 18:00", "en");
    assert!(matches!(&out.mentions[0].source, Some(ZoneRef::Options { reason: "nearby", options })
        if matches!(options.as_slice(), [ZoneRef::City { iana, .. }, ZoneRef::Local] if iana == "Europe/Berlin")), "{out:?}");
}

#[cfg(not(feature = "intents-only"))]
#[test]
fn nearby_exact_weekday_verb_time_in_sixteen_languages() {
    for (language, sentence) in [
        ("en", "On Tuesday I arrive around 4:30."), ("zh-Hans", "星期二我们下午4点30分见面。"),
        ("zh-Hant", "星期三我們下午4點30分見面。"), ("ja", "火曜日は4時30分に会います。"),
        ("ko", "화요일에 우리는 16시에 만나요."), ("de", "Am Dienstag komme ich um 16:30."),
        ("fr", "Mardi je viens à 16:30."), ("es", "El martes voy al médico a las 16:30."),
        ("ru", "Во вторник я приду в 16:30."), ("pt-BR", "Na terça-feira vou ao médico às 16:30."),
        ("it", "Martedì vado dal medico alle 16:30."), ("nl", "Op dinsdag kom ik om 16:30."),
        ("pl", "We wtorek przyjdę o 16:30."), ("tr", "Salı günü saat 16:30 gibi gelirim."),
        ("vi", "Thứ ba chúng tôi gặp nhau lúc 16:30."), ("id", "Selasa ada rapat jam 16:30."),
    ] {
        let out = read(sentence, language);
        assert!(out.mentions.iter().any(|m| m.time.is_some()), "{sentence}: {out:?}");
        assert!(out.mentions.iter().all(|m| !matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{sentence}: {out:?}");
    }
}

#[cfg(not(feature = "intents-only"))]
#[test]
fn nearby_exact_accents_language_and_short_case() {
    for (language, sentence) in [("en", "Munchen sync at 18:00"), ("en", "Münih sync at 18:00"),
        ("en", "Berli\u{0301}n sync at 18:00"), ("en", "Berlin\u{0301} sync at 18:00"), ("en", "ufa sync at 18:00"), ("pt-BR", "Áo reunião às 18:00")] {
        let out = read(sentence, language);
        assert!(out.mentions.iter().all(|m| !matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{sentence}: {out:?}");
    }
    for (language, sentence) in [("de", "München Besprechung um 18:00"), ("tr", "Münih toplantı saat 18:00"),
        ("en", "Ufa sync at 18:00"), ("vi", "Áo họp lúc 18:00")] {
        let out = read(sentence, language);
        assert!(out.mentions.iter().any(|m| matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{sentence}: {out:?}");
    }
}

#[test]
fn nearby_exact_country_script_and_language() {
    assert!(places::nearby_country_lookup("奧地利", "zh").is_some());
    assert!(places::nearby_country_lookup("奥地利", "zh").is_some());
    assert!(places::nearby_country_lookup("áo", "vi").is_some());
    assert!(places::nearby_country_lookup("áo", "pt").is_none());
    assert!(places::nearby_country_lookup("ao", "vi").is_none());
}

#[cfg(not(feature = "intents-only"))]
#[test]
fn nearby_exact_complete_multilingual_names() {
    for (language, sentence) in [("en", "New York City sync at 18:00"), ("en", "San José sync at 18:00"),
        ("es", "Los Angeles reunión a las 18:00"), ("pt-BR", "Rio de Janeiro reunião às 18:00"),
        ("zh-Hans", "洛杉矶 同步 18点"), ("zh-Hant", "洛杉磯 同步 18點"), ("zh-Hant", "奧地利 同步 18點")] {
        let out = read(sentence, language);
        assert!(out.mentions.iter().any(|m| matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{sentence}: {out:?}");
    }
}

#[cfg(not(feature = "intents-only"))]
#[test]
fn nearby_exact_ui_language_cannot_supply_missing_detection() {
    let out = read("Münih xyz 18:00", "tr");
    assert!(out.mentions.iter().all(|m| m.language.is_none()), "{out:?}");
    assert!(out.mentions.iter().all(|m| !matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{out:?}");
    let out = read("Münih xyz saat 18:00", "tr");
    assert!(out.mentions.iter().any(|m| matches!(m.source, Some(ZoneRef::Options { reason: "nearby", .. }))), "{out:?}");
}
