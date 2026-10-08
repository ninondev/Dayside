// SPDX-License-Identifier: GPL-3.0-only
//! 「听懂时间」的语料测试。地名用一张小表代替城市索引（装配逻辑与索引无关），另有一条用随包索引的端到端测试。
use super::*;
use serde_json::json;

fn fake_lookup(text: &str, _strong: bool) -> Option<ZoneRef> {
    let places: &[(&str, &str)] = &[
        ("tokyo", "Asia/Tokyo"), ("東京", "Asia/Tokyo"), ("东京", "Asia/Tokyo"), ("tokio", "Asia/Tokyo"), ("токио", "Asia/Tokyo"), ("大阪", "Asia/Tokyo"), ("ロンドン", "Europe/London"),
        ("london", "Europe/London"), ("런던", "Europe/London"), ("londres", "Europe/London"), ("伦敦", "Europe/London"), ("londra", "Europe/London"),
        ("londyn", "Europe/London"), ("лондон", "Europe/London"),
        ("new york", "America/New_York"), ("nyc", "America/New_York"), ("纽约", "America/New_York"), ("nueva york", "America/New_York"),
        ("nowy jork", "America/New_York"), ("нью-йорк", "America/New_York"), ("los angeles", "America/Los_Angeles"),
        ("sydney", "Australia/Sydney"), ("сидней", "Australia/Sydney"), ("시드니", "Australia/Sydney"),
        ("singapore", "Asia/Singapore"), ("singapur", "Asia/Singapore"), ("berlin", "Europe/Berlin"), ("берлин", "Europe/Berlin"), ("berliner", "Europe/Berlin"),
        ("paris", "Europe/Paris"), ("paryż", "Europe/Paris"), ("париж", "Europe/Paris"), ("madrid", "Europe/Madrid"), ("上海", "Asia/Shanghai"), ("서울", "Asia/Seoul"),
        ("москва", "Europe/Moscow"), ("roma", "Europe/Rome"), ("amsterdam", "Europe/Amsterdam"), ("warszawa", "Europe/Warsaw"), ("warszawie", "Europe/Warsaw"),
        ("istanbul", "Europe/Istanbul"), ("jakarta", "Asia/Jakarta"), ("ha noi", "Asia/Bangkok"), ("hà nội", "Asia/Bangkok"),
        ("brasilia", "America/Sao_Paulo"), ("brasília", "America/Sao_Paulo"),
        // 多词地名与「城市」通名：chi 模拟真实索引里芝加哥的搜索缩写，kota 是印度的一座城。
        ("ho chi minh city", "Asia/Ho_Chi_Minh"), ("ho chi minh", "Asia/Ho_Chi_Minh"), ("thành phố hồ chí minh", "Asia/Ho_Chi_Minh"),
        ("kota hồ chí minh", "Asia/Ho_Chi_Minh"), ("hô chi minh-ville", "Asia/Ho_Chi_Minh"), ("chi", "America/Chicago"),
        ("kota", "Asia/Kolkata"), ("bandung", "Asia/Jakarta"), ("monaco", "Europe/Monaco"), ("monaco di baviera", "Europe/Berlin"),
        ("città del messico", "America/Mexico_City"), ("thành phố méxico", "America/Mexico_City"), ("thành phố new york", "America/New_York"),
        ("рио-де-жанейро", "America/Sao_Paulo"), ("イスタンブール", "Europe/Istanbul"), ("布宜诺斯艾利斯", "America/Argentina/Buenos_Aires"),
        ("yoga", "Asia/Tokyo"), ("forno", "Europe/Rome"),
        ("リウデジャネイロ", "America/Sao_Paulo"),
    ];
    let folded = fold_str(text);
    places
        .iter()
        .find(|(name, _)| fold_str(name) == folded)
        .map(|(name, iana)| ZoneRef::City { city_index: 0, name: (*name).to_owned(), iana: (*iana).to_owned(), population: None })
}

fn run(text: &str) -> Vec<Mention> {
    run_in(text, "US")
}

fn run_in(text: &str, region: &str) -> Vec<Mention> {
    understand(text, &Options { region, ui_language: "en", lookup: &fake_lookup }).mentions
}

fn zone_id(z: &Option<ZoneRef>) -> String {
    match z {
        None => "-".into(),
        Some(ZoneRef::Region { iana }) => iana.clone(),
        Some(ZoneRef::City { iana, .. }) => iana.clone(),
        Some(ZoneRef::Fixed { minutes, .. }) => format!("{minutes:+}"),
        Some(ZoneRef::Options { reason: "sentence", options }) => options.first()
            .map(|zone| format!("~{}", zone_id(&Some(zone.clone())))).unwrap_or_else(|| "~?sentence0".into()),
        Some(ZoneRef::Options { reason: "city", options }) => options.first()
            .map(|zone| zone_id(&Some(zone.clone()))).unwrap_or_else(|| "?city0".into()),
        Some(ZoneRef::Options { reason, options }) => format!("?{reason}{}", options.len()),
        Some(ZoneRef::Place { query }) => format!("@{query}"),
        Some(ZoneRef::Local) => "local".into(),
    }
}

fn date_text(d: &Option<DateSpec>) -> String {
    match d {
        None => "-".into(),
        Some(DateSpec::Absolute { year, month, day }) => format!("{year}-{month:02}-{day:02}"),
        Some(DateSpec::MonthDay { month, day }) => format!("{month:02}-{day:02}"),
        Some(DateSpec::Offset { days }) => format!("{days:+}d"),
        Some(DateSpec::Weekday { weekday, week }) => format!("w{weekday}{}", week.map(|w| format!(":{w}")).unwrap_or_default()),
    }
}

fn clock_text(c: &Option<Clock>) -> String {
    match c {
        None => "-".into(),
        Some(c) => format!(
            "{:02}:{:02}{}{}",
            c.hour,
            c.minute,
            if c.second != 0 { format!(":{:02}", c.second) } else { String::new() },
            if c.day_offset != 0 { format!("{:+}", c.day_offset) } else { String::new() }
        ),
    }
}

/// 一次提到的简写：`日期[^沿用] 钟点[–终点][ dN 时长] 来源 > 目标`，相对时间写 `+Nm`，精确时刻写 `@秒`，习语给的钟点前加 `~`，
/// 有备选读法时末尾加 ` ?N`，有查不到的地名时加 ` !名字`，写得不成立的部分加 ` #类型:原文`。只有日期的一处钟点写 `-`；秒不为 0 时写出秒。
fn summary(m: &Mention) -> String {
    let time = if let Some(r) = m.relative_minutes {
        format!("{r:+}m")
    } else if let Some(i) = m.instant {
        format!("@{i}")
    } else {
        let mut t = String::new();
        if m.time_implied.is_some() {
            t.push('~');
        }
        t.push_str(&clock_text(&m.time));
        if m.end.is_some() {
            t.push('–');
            t.push_str(&clock_text(&m.end));
        }
        if let Some(d) = m.duration_minutes {
            t.push_str(&format!(" d{d}"));
        }
        t
    };
    let mut out = format!("{}{} {} {} > {}", date_text(&m.date), if m.date_inherited { "^" } else { "" }, time, zone_id(&m.source), zone_id(&m.target));
    if !m.alternatives.is_empty() {
        out.push_str(&format!(" ?{}", m.alternatives.len()));
    }
    for u in &m.unresolved {
        out.push_str(&format!(" !{}", u.text));
    }
    for i in &m.issues {
        out.push_str(&format!(" #{}:{}", i.kind, i.text));
    }
    out
}

fn check(cases: &[(&str, &[&str])]) {
    let mut failures = Vec::new();
    for (text, expected) in cases {
        let got: Vec<String> = run(text).iter().map(summary).collect();
        let want: Vec<String> = expected.iter().map(|s| s.to_string()).collect();
        if got != want {
            failures.push(format!("{text}\n    want {want:?}\n    got  {got:?}"));
        }
    }
    assert!(failures.is_empty(), "{} of {} failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
}

#[test]
fn language_evidence_followup_regressions() {
    check(&[
        ("后天 午後 5時 Tokyo。", &["+2d 17:00 Asia/Tokyo > -"]),
        ("我這邊晚上八點可以開會。", &["- 20:00 local > -"]),
        ("O ônibus parte às seis.", &["- 06:00 - > -"]),
        ("Anteontem cheguei às 7:15 no escritório.", &["-2d 07:15 - > -"]),
        ("Call-nya besok at 9:15 ya.", &["+1d 09:15 - > -"]),
        ("21 ago - 2025 • 09:30", &["2025-08-21 09:30 - > -"]),
        ("Sent 3 days ago at 09:30.", &["-3d 09:30 - > -"]),
        ("Wednesday, December 9, 10–11am ET", &["12-09 10:00–11:00 America/New_York > -"]),
        ("Friday, September 4, 2–3pm PT", &["09-04 14:00–15:00 America/Los_Angeles > -"]),
    ]);
}

#[test]
fn language_evidence_followup_contrasts() {
    check(&[
        ("明天 午後 4時 Tokyo。", &["+1d 16:00 Asia/Tokyo > -"]),
        ("我這邊晚上三點可以開會。", &["- 15:00 local > -"]),
        ("O ônibus parte às cinco.", &["- 05:00 - > -"]),
        ("Meet anteontem at 9:15.", &["-2d 09:15 - > -"]),
        ("Meet besok at 9:15.", &["+1d 09:15 - > -"]),
        ("Meet domani at 18:00.", &["+1d 18:00 - > -"]),
        ("The code is ABC; domani at 18:00.", &["+1d 18:00 - > -"]),
        ("The token is besok at 9:15.", &["- 09:15 - > -"]),
        ("Meet 21 ago at 09:30.", &["08-21 09:30 - > -"]),
        ("Meet 21 ago 三點", &["08-21 03:00 - > -"]),
        ("Meet 21 mai 午後三時 Tokyo。", &["05-21 15:00 Asia/Tokyo > -"]),
        ("21 ago - 2025", &["2025-08-21 - - > -"]),
    ]);
}

#[test]
fn language_evidence_followup_local_and_literal_contrasts() {
    check(&[
        ("Spotkamy się 3 razy o 18:00", &["- 18:00 - > -"]),
        ("Spotkamy sie 3 o 18:00", &["08-03 18:00 - > -"]),
        ("The count is 3 gen and the meeting is at 18:00", &["- 18:00 - > -"]),
        ("The code is domani at 18:00.", &["- 18:00 - > -"]),
        ("The identifier: domani at 18:00.", &["- 18:00 - > -"]),
        ("The token = besok at 9:15.", &["- 09:15 - > -"]),
    ]);
}

/// 日期、钟点与区间边界的回归用例。
#[test]
fn review_regressions_read_what_was_written() {
    check(&[
        // 带日期的一段时间：「–10:00」是终点，不是 UTC−10 的偏移（此前读成 UTC 19:00，差 10 小时）。
        ("2026-10-02 09:00–10:00 UTC", &["2026-10-02 09:00–10:00 +0 > -"]),
        ("2026-10-02 09:00 - 10:00 UTC", &["2026-10-02 09:00–10:00 +0 > -"]),
        ("2026-10-02 09:00-10:00 UTC", &["2026-10-02 09:00–10:00 +0 > -"]),
        // ISO 写法里紧贴的「-10:00」才是偏移。
        ("2026-10-02T09:00-10:00", &["- @1790967600 - > -"]),
        // 旧版读对的时间段与 Z。
        ("1pm–3", &["- 13:00–15:00 - > -"]),
        ("1–3pm", &["- 13:00–15:00 - > -"]),
        ("9am Z", &["- 09:00 +0 > -"]),
        // 写得不成立的部分要说出来，不能丢掉后照常换算。
        ("2026-02-30 09:00 UTC", &["- 09:00 +0 > - #invalidDate:2026-02-30"]),
        ("2026-13-40 09:00 UTC", &["- 09:00 +0 > - #invalidDate:2026-13-40"]),
        ("10:20:99 UTC", &["- - +0 > - #invalidTime:10:20:99"]),
        ("9am UTC+99", &["- 09:00 - > - #invalidOffset:UTC+99"]),
        // 秒要留住：10 秒的一段不是跨夜。
        ("10:20:10–10:20:20", &["- 10:20:10–10:20:20 - > -"]),
        // 并进星期的日期后面的钟点不能被跳过。
        ("Friday, October 2 2026 at 18:00 UTC", &["2026-10-02 18:00 +0 > -"]),
        // 各处各归各的：截止只有日期，通话在另一天；两处钟点中间有内容词就不是一段时间。
        ("Oct 3 is the deadline, and the call is Oct 4 at 9am UTC", &["10-03 - - > -", "10-04 09:00 +0 > -"]),
        ("9am and then we leave at 5pm", &["- 09:00 - > -", "- 17:00 - > -"]),
        // 下一句只问目标、前面恰好一处时接上。
        ("Webinar: 2 October 2026, 18:00–19:30 CEST. What time in Tokyo?", &["2026-10-02 18:00–19:30 +120 > Asia/Tokyo"]),
        // 截止与钟点同句各成一处；截止习语默认 17:00。
        ("Call at 9 and submit by EOD", &["- 09:00 - > -", "- ~17:00 - > -"]),
    ]);
}

/// 旧引擎的 30 句基线，历史结果为读对 6 句；这些句子保留作回归用例。
#[test]
fn the_thirty_real_world_sentences_from_the_baseline() {
    check(&[
        ("3pm tokyo", &["- 15:00 Asia/Tokyo > -"]),
        ("9 am PST in London", &["- 09:00 -480 > Europe/London"]),
        ("Let's meet Thursday at 3pm ET", &["w4 15:00 America/New_York > -"]),
        ("Can we do tomorrow 10:30 CET?", &["+1d 10:30 +60 > -"]),
        ("Webinar: 2 October 2026, 18:00–19:30 CEST", &["2026-10-02 18:00–19:30 +120 > -"]),
        ("Sync at 18:00 IDT", &["- 18:00 +180 > -"]),
        ("Deadline: Oct 3, 11:59 PM AoE", &["10-03 23:59 Etc/GMT+12 > -"]),
        ("The launch is at 17:00 UTC on 2026-10-01", &["2026-10-01 17:00 +0 > -"]),
        ("Standup at 9:30 PT", &["- 09:30 America/Los_Angeles > -"]),
        ("when is 9am sydney in new york", &["- 09:00 Australia/Sydney > America/New_York"]),
        ("Call at noon Berlin time", &["- 12:00 Europe/Berlin > -"]),
        ("9am NYC / 2pm London / 11pm Singapore", &["- 09:00 America/New_York > -", "- 14:00 Europe/London > -", "- 23:00 Asia/Singapore > -"]),
        ("2026-09-24T14:00:00Z", &["- @1790258400 - > -"]),
        ("1727179200", &["- @1727179200 - > -"]),
        ("next Monday 9am", &["w1:next 09:00 - > -"]),
        ("in 3 hours", &["- +180m - > -"]),
        ("会议定在周四下午三点（北京时间）", &["w4 15:00 Asia/Shanghai > -"]),
        ("东京明早九点是纽约几点", &["+1d 09:00 Asia/Tokyo > America/New_York"]),
        ("下周一上午10点 伦敦", &["w1:next 10:00 Europe/London > -"]),
        ("10月3日晚上8点 上海", &["10-03 20:00 Asia/Shanghai > -"]),
        ("明日の15時(日本時間)で大丈夫ですか", &["+1d 15:00 Asia/Tokyo > -"]),
        ("来週の月曜日 午前10時 ロンドン", &["w1:next 10:00 Europe/London > -"]),
        ("내일 오후 3시 서울", &["+1d 15:00 Asia/Seoul > -"]),
        ("Podemos hablar el jueves a las 15:00 hora de Madrid", &["w4 15:00 Europe/Madrid > -"]),
        ("Rendez-vous vendredi à 14h heure de Paris", &["w5 14:00 Europe/Paris > -"]),
        ("Treffen wir uns am Dienstag um 9 Uhr Berliner Zeit?", &["w2 09:00 Europe/Berlin > -"]),
        ("Встреча завтра в 10:00 по московскому времени", &["+1d 10:00 Europe/Moscow > -"]),
        ("Reunião amanhã às 10h horário de Brasília", &["+1d 10:00 America/Sao_Paulo > -"]),
        ("3 октября в 18:00 Москва", &["10-03 18:00 Europe/Moscow > -"]),
        ("le 3 octobre à 18h Paris", &["10-03 18:00 Europe/Paris > -"]),
        ("am 3. Oktober um 18 Uhr Berlin", &["10-03 18:00 Europe/Berlin > -"]),
    ]);
}

#[test]
fn nothing_is_invented_from_text_without_a_time() {
    for text in ["I have 3 cats", "Room 1205 on floor 3", "version 2.10 is out", "call me at +1 415 555 0123", "Order #4155551234 shipped",
                 "the 1/2 cup of flour", "今天天气不错", "Thanks, see you soon!", "", "   ", "Nice to meet you in Reading"] {
        let got: Vec<String> = run(text).iter().map(summary).collect();
        assert!(got.is_empty(), "{text:?} → {got:?}");
    }
}

#[test]
fn ordinary_words_of_another_language_are_not_time_words() {
    check(&[
        ("Mon service commence à 7h05.", &["- 07:05 - > -"]),
        ("Mon 9:00 standup", &["w1 09:00 - > -"]),
        ("Tôi đến phòng thu khoảng 15:30.", &["- 15:30 - > -"]),
        ("De les is om 18:00 hier.", &["- 18:00 local > -"]),
        ("Save it at once.", &[]),
        ("La reunión es a las once.", &["- 11:00 - > -"]),
        ("Biblioteka jest czynna do 18:00.", &["- 18:00 - > -"]),
    ]);
}

#[test]
fn clue_words_need_their_own_language() {
    check(&[
        ("La lezione di yoga è alle 18:00.", &["- 18:00 - > -"]),
        ("La pizza è in forno alle 18:00.", &["- 18:00 - > -"]),
        ("Rapat di Jakarta pukul 10.00.", &["- 10:00 Asia/Jakarta > -"]),
        ("Rapat di Yoga pukul 10.00.", &["- 10:00 Asia/Tokyo > -"]),
        ("La riunione in Tokyo è alle 18:00.", &["- 18:00 ~Asia/Tokyo > -"]),
        ("Meet in tokyo at 18:00.", &["- 18:00 Asia/Tokyo > -"]),
    ]);
}

#[test]
fn number_words_do_not_match_inside_other_words() {
    check(&[
        ("인도네시아", &[]),
        ("네시에 만나요", &["- 04:00 - > -"]),
        ("인도네시아에서 10:00에 만나요", &["- 10:00 ?country4 > -"]),
    ]);
}

#[test]
fn independent_language_guards_months_days_and_script_units() {
    check(&[
        ("The count is 3 gen.", &[]),
        ("Il corso è il 3 gen alle 10:00.", &["01-03 10:00 - > -"]),
        ("The code is domani at 18:00.", &["- 18:00 - > -"]),
        ("Ci vediamo domani alle 18:00.", &["+1d 18:00 - > -"]),
        ("세시풍속", &[]),
        ("세시에 만나요", &["- 03:00 - > -"]),
        ("네시빌", &[]),
        ("Mon 9:00 standup 서울", &["w1 09:00 Asia/Seoul > -"]),
        ("Meet at 18:00 tokyo.", &["- 18:00 Asia/Tokyo > -"]),
    ]);
}

#[test]
fn language_votes_exclude_place_names_and_unrelated_sentences() {
    check(&[
        ("Mon 9:00 standup 시드니", &["w1 09:00 Australia/Sydney > -"]),
        ("Mon 9:00 standup Monaco di Baviera", &["w1 09:00 Europe/Berlin > -"]),
        ("4시드니", &[]),
        ("4시에 만나요", &["- 04:00 - > -"]),
        ("4시는 어때요?", &["- 04:00 - > -"]),
        ("네시반에 만나요", &["- 04:30 - > -"]),
        ("Meet at 18:00 tokyo. Ask Bob.", &["- 18:00 Asia/Tokyo > -"]),
    ]);
}

fn check_in(region: &str, cases: &[(&str, &[&str])]) {
    let mut failures = Vec::new();
    for (text, expected) in cases {
        let got: Vec<String> = run_in(text, region).iter().map(summary).collect();
        let want: Vec<String> = expected.iter().map(|s| s.to_string()).collect();
        if got != want {
            failures.push(format!("{text}\n    want {want:?}\n    got  {got:?}"));
        }
    }
    assert!(failures.is_empty(), "{} of {} failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
}

/// 时长：有线索的（for / 持续 / dauert / lang / 동안 / boyunca…）与紧跟钟点的光秃秃的量。
#[test]
fn durations_attach_to_their_clock() {
    check(&[
        ("Call at 3pm for 2 hours", &["- 15:00 d120 - > -"]),
        ("Standup 9:30 ET, 15 minutes", &["- 09:30 d15 America/New_York > -"]),
        ("会议下午三点开始，持续两小时", &["- 15:00 d120 - > -"]),
        ("Meeting um 15 Uhr, dauert 2 Stunden", &["- 15:00 d120 - > -"]),
        ("Om 15.00 uur, 2 uur lang", &["- 15:00 d120 - > -"]),
        ("15시부터 2시간 동안", &["- 15:00 d120 - > -"]),
        ("Toplantı saat 15:00, 2 saat sürecek", &["- 15:00 d120 - > -"]),
        ("Rapat pukul 15.00 selama 2 jam", &["- 15:00 d120 - > -"]),
        ("Réunion à 15h, durée 1h30", &["- 15:00 d90 - > -"]),
        // 有终点也保留写明的时长；光秃秃的量不紧跟钟点就不算。
        ("14:00–16:00 CET, 2 hours", &["- 14:00–16:00 d120 +60 > -"]),
        ("I worked 3 hours and then called at 3pm", &["- 15:00 - > -"]),
    ]);
}

/// 截止习语只在没有显式钟点时成为一处；AoE 截止没写钟点按 23:59。
#[test]
fn deadline_idioms_and_aoe() {
    check(&[
        ("Please send it by EOD", &["- ~17:00 - > -"]),
        ("下班前发我", &["- ~17:00 - > -"]),
        ("Bitte bis Feierabend", &["- ~17:00 - > -"]),
        ("Envíalo antes de medianoche", &["- ~23:59 - > -"]),
        ("Deadline: Oct 3 AoE", &["10-03 ~23:59 Etc/GMT+12 > -"]),
        ("Deadline: Oct 3, 11:59 PM AoE", &["10-03 23:59 Etc/GMT+12 > -"]),
        // 与显式钟点同现：读钟点，习语只是普通词。
        ("EOD is 6pm here", &["- 18:00 local > -"]),
        ("by noon", &["- 12:00 - > -"]),
    ]);
}

/// 只有日期的一处：写明的公历日期才成事；日期沿用同一段落里前一处的，空行不沿用。
#[test]
fn date_only_mentions_and_inheritance() {
    check(&[
        ("The conference runs October 3", &["10-03 - - > -"]),
        ("Sent: Sep 20, 2026", &["2026-09-20 - - > -"]),
        ("See you tomorrow", &[]),
        ("Let's do next Monday", &[]),
        ("Oct 3: 9:00 Berlin, 14:00 Tokyo", &["10-03 09:00 Europe/Berlin > -", "10-03^ 14:00 Asia/Tokyo > -"]),
        ("Oct 3, 9:00 Berlin\n14:00 Tokyo", &["10-03 09:00 Europe/Berlin > -", "10-03^ 14:00 Asia/Tokyo > -"]),
        ("Oct 3, 9:00 Berlin\n\n14:00 Tokyo", &["10-03 09:00 Europe/Berlin > -", "- 14:00 Asia/Tokyo > -"]),
        ("Thursday, October 2\n18:00–19:30 CEST", &["10-02 18:00–19:30 +120 > -"]),
        ("9am NYC / 2pm London / 11pm Singapore", &["- 09:00 America/New_York > -", "- 14:00 Europe/London > -", "- 23:00 Asia/Singapore > -"]),
        ("9am Tokyo, 2pm London", &["- 09:00 Asia/Tokyo > -", "- 14:00 Europe/London > -"]),
        ("Tokyo 9am, London 2pm", &["- 09:00 Asia/Tokyo > -", "- 14:00 Europe/London > -"]),
        // 钟点后面隔得远的公历日期自成一处（换算页转储查出：此前 10 月 3 日被 18:00 借走、只有日期的一处丢了）；紧跟的照旧归钟点。
        ("Kickoff tomorrow 9am, sync 18:00 Berlin, report due Oct 3.", &["+1d 09:00 - > -", "+1d^ 18:00 Europe/Berlin > -", "10-03 - - > -"]),
        ("Meeting 18:00 Berlin, Oct 3", &["10-03 18:00 Europe/Berlin > -"]),
        ("Call at 9am, on Oct 3", &["10-03 09:00 - > -"]),
    ]);
}

/// 沿用的日期记下来自哪一处（宿主改了那一处的读法，沿用它的跟着变）；太长的文字说出只读到哪儿。
#[test]
fn inherited_dates_name_their_source_and_long_text_says_where_reading_stopped() {
    let out = understand("10/3: 9:00 Berlin, 14:00 Tokyo, 18:00 London", &Options { region: "US", ui_language: "en", lookup: &fake_lookup });
    let from: Vec<Option<usize>> = out.mentions.iter().map(|m| m.date_from).collect();
    assert_eq!(from, [None, Some(0), Some(0)]);
    assert_eq!(out.truncated_at, None);

    // 4,000 字节之后的钟点不读；位置按原文的 UTF-16 算（中文一个字 3 字节、1 个 UTF-16 单位）。
    let long = format!("{}明天 9:00 东京", "东".repeat(1_400));
    let out = understand(&long, &Options { region: "US", ui_language: "zh-Hans", lookup: &fake_lookup });
    assert!(out.mentions.is_empty(), "截断之后的钟点不该读出：{:?}", out.mentions.iter().map(summary).collect::<Vec<_>>());
    assert_eq!(out.truncated_at, Some(1_333), "4,000 字节在字符边界上退到 3,999 = 1,333 个汉字");
    let short = format!("{}9:00 Tokyo", "x ".repeat(100));
    assert_eq!(understand(&short, &Options { region: "US", ui_language: "en", lookup: &fake_lookup }).truncated_at, None);
}

/// 性质测试（从旧 `converter.rs` 移来，判据不变）：随机公历日期时刻与固定偏移「YYYY-MM-DD HH:MM[:SS] UTC±H[:MM]」
/// → 引擎读出的日期、钟点、偏移逐字段等于写的；再用一套独立的公历↔Unix 算法（Hinnant days_from_civil，不经 libc）算出瞬间，
/// `converter.timestamps` 渲染的 ISO 8601 必须与输入逐字段相同、`unix` 等于独立算出的值。
#[test]
fn random_explicit_inputs_read_exactly_and_render_back() {
    struct Xor(u64);
    impl Xor {
        fn next(&mut self) -> u64 {
            let mut x = self.0;
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            self.0 = x;
            x
        }
        fn below(&mut self, n: u64) -> u64 {
            self.next() % n.max(1)
        }
    }
    fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
        let y = if m <= 2 { y - 1 } else { y };
        let era = if y >= 0 { y } else { y - 399 } / 400;
        let yoe = y - era * 400;
        let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        era * 146_097 + doe - 719_468
    }
    let iterations: u64 = std::env::var("MEANTIME_FUZZ_ITERATIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(5_000);
    let seed_offset: u64 = std::env::var("MEANTIME_FUZZ_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
    let mut rng = Xor(0xC0F1_E5EE_D000_0001_u64.wrapping_add(seed_offset));
    for i in 0..iterations {
        let year = 1900 + rng.below(201) as i64;
        let month = 1 + rng.below(12) as i64;
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
        let limit = match month { 2 if leap => 29, 2 => 28, 4 | 6 | 9 | 11 => 30, _ => 31 };
        let day = 1 + rng.below(limit) as i64;
        let (h, mi, sec) = (rng.below(24) as i64, rng.below(60) as i64, rng.below(60) as i64);
        let sign = if rng.below(2) == 0 { 1 } else { -1 };
        let oh = rng.below(19) as i64;
        let om = if oh == 18 { 0 } else { [0, 30, 45, rng.below(60) as i64][rng.below(4) as usize] };
        let offset = sign * (oh * 3600 + om * 60);
        let zone_text = if om == 0 && rng.below(2) == 0 { format!("UTC{}{oh}", if sign > 0 { "+" } else { "-" }) } else { format!("UTC{}{oh:02}:{om:02}", if sign > 0 { "+" } else { "-" }) };
        let with_seconds = sec != 0 || rng.below(2) == 0;
        let second = if with_seconds { sec } else { 0 };
        let input = if with_seconds { format!("{year:04}-{month:02}-{day:02} {h:02}:{mi:02}:{sec:02} {zone_text}") } else { format!("{year:04}-{month:02}-{day:02} {h:02}:{mi:02} {zone_text}") };
        let out = understand(&input, &Options { region: "US", ui_language: "en", lookup: &fake_lookup });
        let [m] = &out.mentions[..] else { panic!("#{i} {input:?} 读出 {} 处", out.mentions.len()) };
        assert!(m.issues.is_empty(), "#{i} {input:?} 报了问题 {:?}", m.issues);
        assert_eq!(m.date, Some(DateSpec::Absolute { year: year as i32, month: month as u8, day: day as u8 }), "#{i} {input:?}");
        assert_eq!(m.time, Some(Clock { hour: h as u8, minute: mi as u8, second: second as u8, day_offset: 0 }), "#{i} {input:?}");
        assert!(matches!(m.source, Some(ZoneRef::Fixed { minutes, .. }) if i64::from(minutes) * 60 == offset), "#{i} {input:?} 偏移 {:?}", m.source);
        let unix = days_from_civil(year, month, day) * 86_400 + h * 3600 + mi * 60 + second - offset;
        let Ok(rendered) = crate::dispatch("converter.timestamps", json!({"timestamp": unix as f64, "offsetSeconds": offset})) else { continue };
        if rendered.get("error").is_some() {
            continue; // 1900 年头几小时在负偏移下会落到范围外，timestamps 本来就拒绝
        }
        // 零偏移一律写 +00:00（RFC 3339 里 -00:00 另有含义）。
        let suffix = format!("{}{oh:02}:{om:02}", if offset < 0 { '-' } else { '+' });
        let expected = format!("{year:04}-{month:02}-{day:02}T{h:02}:{mi:02}:{second:02}{suffix}");
        assert_eq!(rendered["iso8601"], expected, "#{i} {input:?}");
        assert_eq!(rendered["unix"], unix.to_string(), "#{i} {input:?}");
    }
}

/// 「10/3」按语言与地区定顺序，两边都 ≤ 12 时附另一种；点号连的两数按语言定。
#[test]
fn slash_and_dot_pairs_follow_language_then_region() {
    check_in("US", &[
        ("10/3 9am", &["10-03 09:00 - > - ?1"]),
        ("10/3/2026 9am", &["2026-10-03 09:00 - > - ?1"]),
        ("13/3 9am", &["03-13 09:00 - > -"]),
        ("10/3 下午3点 东京", &["10-03 15:00 Asia/Tokyo > - ?1"]),
        ("le 10/3 à 9h", &["03-10 09:00 - > - ?1"]),
        ("version 2.10 is out", &[]),
    ]);
    check_in("DE", &[
        ("10/3 9am", &["03-10 09:00 - > - ?1"]),
        ("10/3 下午3点 东京", &["10-03 15:00 Asia/Tokyo > - ?1"]),
        ("am 3.10. um 15 Uhr", &["10-03 15:00 - > -"]),
        ("Treffen am 03.10 um 15 Uhr", &["10-03 15:00 - > -"]),
        ("Treffen 15.30 in Berlin", &["- 15:30 Europe/Berlin > -"]),
    ]);
    check_in("ID", &[
        ("besok 09.00 Tokyo", &["+1d 09:00 Asia/Tokyo > -"]),
        ("rapat 15.30 WIB", &["- 15:30 +420 > -"]),
        ("rapat besok 10.05 di Jakarta", &["+1d 10:05 Asia/Jakarta > - ?1"]),
    ]);
    check_in("RU", &[
        ("Встреча 03.10 в 15:00 Москва", &["10-03 15:00 Europe/Moscow > -"]),
    ]);
    check_in("CN", &[
        ("3.15 下午两点 上海", &["03-15 14:00 Asia/Shanghai > -"]),
    ]);
    check_in("PL", &[
        ("spotkanie jutro 15.30 Warszawa", &["+1d 15:30 Europe/Warsaw > -"]),
        ("spotkanie 12.10 w Warszawie", &["- 12:10 Europe/Warsaw > - ?1"]),
    ]);
}

/// 刻、半、分钟词序与数词钟点，十五种语言。
#[test]
fn quarters_halves_and_number_words() {
    check(&[
        ("quarter past three", &["- 03:15 - > -"]), ("at half past 3", &["- 03:30 - > -"]), ("ten to four", &["- 03:50 - > -"]),
        ("twenty past three in the afternoon", &["- 15:20 - > -"]), ("three o'clock", &["- 03:00 - > -"]),
        ("um viertel vor vier", &["- 03:45 - > -"]), ("halb vier", &["- 03:30 - > -"]), ("10 vor 4", &["- 03:50 - > -"]),
        ("um drei Uhr", &["- 03:00 - > -"]), ("dreiviertel vier", &["- 03:45 - > -"]),
        ("kwart over drie", &["- 03:15 - > -"]), ("om 10 voor 4", &["- 03:50 - > -"]), ("om drie uur", &["- 03:00 - > -"]),
        ("a las tres y cuarto", &["- 03:15 - > -"]), ("a las cuatro menos cuarto", &["- 03:45 - > -"]), ("a las 4 menos 10", &["- 03:50 - > -"]),
        ("a las tres de la tarde", &["- 15:00 - > -"]),
        ("alle tre e un quarto", &["- 03:15 - > -"]), ("alle quattro meno un quarto", &["- 03:45 - > -"]), ("alle tre", &["- 03:00 - > -"]),
        ("à quatre heures moins le quart", &["- 03:45 - > -"]), ("à trois heures et quart", &["- 03:15 - > -"]),
        ("às três e meia", &["- 03:30 - > -"]), ("às três e quinze", &["- 03:15 - > -"]),
        ("o wpół do czwartej", &["- 03:30 - > -"]), ("kwadrans po trzeciej", &["- 03:15 - > -"]), ("za kwadrans czwarta", &["- 03:45 - > -"]),
        ("o trzeciej", &["- 03:00 - > -"]),
        ("четверть третьего", &["- 02:15 - > -"]), ("без четверти четыре", &["- 03:45 - > -"]), ("без десяти четыре", &["- 03:50 - > -"]),
        ("полчетвёртого", &["- 03:30 - > -"]), ("в три часа дня", &["- 15:00 - > -"]),
        ("üçü çeyrek geçe", &["- 03:15 - > -"]), ("dörde çeyrek kala", &["- 03:45 - > -"]), ("saat 3'ü on geçe", &["- 03:10 - > -"]),
        ("4'e on kala", &["- 03:50 - > -"]), ("üç buçuk", &["- 03:30 - > -"]), ("saat üçte", &["- 03:00 - > -"]),
        ("三点一刻", &["- 03:15 - > -"]), ("三点三刻", &["- 03:45 - > -"]), ("十月三日下午三点", &["10-03 15:00 - > -"]),
        ("ba giờ chiều", &["- 15:00 - > -"]), ("jam tiga sore", &["- 15:00 - > -"]), ("setengah empat", &["- 03:30 - > -"]),
        ("jam setengah empat sore", &["- 15:30 - > -"]),
        ("세 시", &["- 03:00 - > -"]), ("明日三時に", &["+1d 03:00 - > -"]),
    ]);
}

/// 句中的 Unix 时间戳、箭头目标、本地时间、括号星期、下周的星期。
#[test]
fn unix_cues_arrows_local_time_and_parenthesized_weekdays() {
    check(&[
        ("created at unix 1727179200", &["- @1727179200 - > -"]),
        ("ts=1727179200 in the log", &["- @1727179200 - > -"]),
        ("event at 1727179200000 ms", &["- @1727179200 - > -"]),
        ("order 1727179200 shipped", &[]),
        ("9am ET → London", &["- 09:00 America/New_York > Europe/London"]),
        ("9:00 Tokyo -> Berlin", &["- 09:00 Asia/Tokyo > Europe/Berlin"]),
        ("10am Tokyo in my time", &["- 10:00 Asia/Tokyo > local"]),
        ("3pm my time", &["- 15:00 local > -"]),
        ("10月3日（金）15時", &["10-03 15:00 - > -"]),
        ("Oct 3 (Fri) 3pm", &["10-03 15:00 - > -"]),
        ("10월 3일 (금) 오후 3시", &["10-03 15:00 - > -"]),
        ("Tuesday next week 3pm", &["w2:next 15:00 - > -"]),
        ("call at 3pm in Springfieldia", &["- 15:00 - > - !Springfieldia"]),
    ]);
}

/// （一次提到的简写，写这句话的人在哪儿）：小表查地名，writer 的地方用 `zone_id`。
fn run_with_writer(text: &str) -> (Vec<String>, String) {
    let out = understand(text, &Options { region: "US", ui_language: "en", lookup: &fake_lookup });
    (out.mentions.iter().map(summary).collect(), out.writer.as_ref().map_or("-".into(), |w| zone_id(&Some(w.place.clone()))))
}

/// 「我在哪儿」的说法：第一个成立的说法报出写这句话的人在哪儿（`writer`）；说法里的地名被它吃掉，
/// 不再成为任何一处提到的来源或目标。查不到地名的 cue（I'm in a meeting、ich bin in Eile）不算说法，
/// 没有说法的句子读法与从前一字不差。
#[test]
fn writer_statements_are_found_and_do_not_touch_mentions() {
    let cases: &[(&str, &[&str], &str)] = &[
        ("I'm in Berlin. Can we talk at 3pm my time?", &["- 15:00 local > -"], "Europe/Berlin"),
        ("我在上海，明天下午3点我这边方便", &["+1d 15:00 local > -"], "Asia/Shanghai"),
        ("Ich bin in Berlin, 15 Uhr bei mir", &["- 15:00 local > -"], "Europe/Berlin"),
        ("東京にいます。午後3時こちらの時間で", &["- 15:00 local > -"], "Asia/Tokyo"),
        ("서울에 있어요. 오후 3시 제 시간", &["- 15:00 local > -"], "Asia/Seoul"),
        ("Estoy en Madrid, a las 15:00 mi hora", &["- 15:00 local > -"], "Europe/Madrid"),
        ("I'm in Berlin", &[], "Europe/Berlin"),
        // 地名属于说法，不属于钟点。
        ("I'm in Berlin, call me at 4pm", &["- 16:00 ~Europe/Berlin > -"], "Europe/Berlin"),
        ("I'm in a meeting at 3pm", &["- 15:00 - > -"], "-"),
        // 没有说法的句子照旧读（改动前就是这么读的）。
        ("The office in Berlin opens at 9am", &["- 09:00 ~Europe/Berlin > -"], "-"),
        ("我在开会，下午3点再说", &["- 15:00 - > -"], "-"),
    ];
    let mut failures = Vec::new();
    for (text, mentions, writer) in cases {
        let (got, got_writer) = run_with_writer(text);
        let want: Vec<String> = mentions.iter().map(|s| s.to_string()).collect();
        if got != want || got_writer != *writer {
            failures.push(format!("{text}\n    want {want:?} + {writer}\n    got  {got:?} + {got_writer}"));
        }
    }
    assert!(failures.is_empty(), "{} of {} failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
}

/// 等价组：同一行、中间只有分隔符或连接词的几处同组；有实词或换行就分开。
#[test]
fn equivalence_groups_follow_separators_and_lines() {
    let groups = |text: &str| -> Vec<usize> { run(text).iter().map(|m| m.group).collect() };
    assert_eq!(groups("9:00 New York / 14:00 London / 23:00 Singapore"), vec![0, 0, 0]);
    assert_eq!(groups("9am ET, which is 3pm CET"), vec![0, 0]);
    assert_eq!(groups("9am ET (15:00 Berlin)"), vec![0, 0]);
    assert_eq!(groups("Keynote 9:00 ET / Workshop 15:00 CET"), vec![0, 1]);
    assert_eq!(groups("9:00 New York\n14:00 London"), vec![0, 1]);
    assert_eq!(groups("9:00 New York. 14:00 London."), vec![0, 1]);
    assert_eq!(groups("15時 東京 = 8時 ベルリン"), vec![0, 0]);
}

/// 端到端：随包城市索引查地名（精确命中、零散词要够有名）。与上面同一批句子，地点换成真实索引给的时区。
#[cfg(not(feature = "intents-only"))] // 随包城市索引 intents-only 不带
#[test]
fn the_baseline_resolves_places_against_the_bundled_city_index() {
    let opened = crate::city_index::dispatch(
        "city.open",
        json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")}),
    )
    .unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |t: &str, strong: bool| city_lookup(Some(handle), t, strong);
    let cases: &[(&str, &str)] = &[
        ("3pm tokyo", "- 15:00 Asia/Tokyo > -"),
        ("when is 9am sydney in new york", "- 09:00 Australia/Sydney > America/New_York"),
        ("9am NYC / 2pm London / 11pm Singapore", "- 09:00 America/New_York > -|- 14:00 Europe/London > -|- 23:00 Asia/Singapore > -"),
        ("东京明早九点是纽约几点", "+1d 09:00 Asia/Tokyo > America/New_York"),
        ("下周一上午10点 伦敦", "w1:next 10:00 Europe/London > -"),
        ("10月3日晚上8点 上海", "10-03 20:00 Asia/Shanghai > -"),
        ("来週の月曜日 午前10時 ロンドン", "w1:next 10:00 Europe/London > -"),
        ("내일 오후 3시 서울", "+1d 15:00 Asia/Seoul > -"),
        ("Treffen wir uns am Dienstag um 9 Uhr Berliner Zeit?", "w2 09:00 Europe/Berlin > -"),
        ("3 октября в 18:00 Москва", "10-03 18:00 Europe/Moscow > -"),
        ("le 3 octobre à 18h Paris", "10-03 18:00 Europe/Paris > -"),
        ("am 3. Oktober um 18 Uhr Berlin", "10-03 18:00 Europe/Berlin > -"),
        ("Встреча в 10:00 в Москве", "- 10:00 Europe/Moscow > -"),
        ("Toplantı saat 15:00'te İstanbul'da", "- 15:00 Europe/Istanbul > -"),
        // 国家名赢过同名小镇（此前「Brazil」读成美国印第安纳州的 Brazil 镇），国家给全部时区；
        // 城市只认精确的键（此前「bali」按拼音读成巴黎）；变格只收列出来的词尾（此前「Москвzz」被截成莫斯科）。
        ("9am in Brazil", "- 09:00 ?country16 > -"),
        ("9am in Indonesia", "- 09:00 ?country4 > -"),
        ("9am in China", "- 09:00 Asia/Shanghai > -"),
        ("9am in Japan", "- 09:00 Asia/Tokyo > -"),
        // 「bali」现在只认精确的键：对上的是印度拉贾斯坦邦真叫 Bali 的小城（不再是巴黎的拼音）。巴厘岛是印尼的省，
        // 行政区与岛名还不当地名认（已知缺口），所以换算页「读懂了」要连国家写出读到的地点，让人一眼看出不对。
        ("9am in bali", "- 09:00 Asia/Kolkata > -"),
        ("9am in Москвzz", "- 09:00 - > - !Москвzz"),
        ("spotkanie o 9:00 w Warszawie", "- 09:00 Europe/Warsaw > -"),
        ("Встреча в 10:00 в Берлине", "- 10:00 Europe/Berlin > -"),
        ("Let's meet Thursday at 3pm", "w4 15:00 - > -"),
        ("Can we do tomorrow 10:30?", "+1d 10:30 - > -"),
        // 冠词带出的国家要整段识别；冠词后面不是地名时不报「没认出」，也不查小地方
        // （「la plaza」的别名能对上阿根廷的 Presidencia de la Plaza）；本来就带冠词的城市照旧。
        ("9am in the United States", "- 09:00 ?country29 > -"),
        ("9am in the US", "- 09:00 ?country29 > -"),
        ("3pm in the U.S.", "- 15:00 ?country29 > -"),
        ("9am in the Philippines", "- 09:00 Asia/Manila > -"),
        ("a las 9 en los Estados Unidos", "- 09:00 ?country29 > -"),
        ("9 Uhr in den USA", "- 09:00 ?country29 > -"),
        ("9 Uhr im Iran", "- 09:00 Asia/Tehran > -"),
        ("9:00 in de Verenigde Staten", "- 09:00 ?country29 > -"),
        ("9h aux États-Unis", "- 09:00 ?country29 > -"),
        ("9h au Japon", "- 09:00 Asia/Tokyo > -"),
        ("às 9h no Brasil", "- 09:00 ?country16 > -"),
        ("alle 9 negli Stati Uniti", "- 09:00 ?country29 > -"),
        ("what time is 3pm Berlin in the UK?", "- 15:00 Europe/Berlin > Europe/London"),
        ("9am in the office", "- 09:00 - > -"),
        ("9am in the morning", "- 09:00 - > -"),
        ("a las 9 en la plaza", "- 09:00 - > -"),
        ("9h au bureau", "- 09:00 - > -"),
        ("9 Uhr im Büro", "- 09:00 - > -"),
        ("no problem, 9am works", "- 09:00 - > -"),
        ("join us at 9am", "- 09:00 - > -"),
        ("9am in La Paz", "- 09:00 America/La_Paz > -"),
        ("9am in The Hague", "- 09:00 Europe/Amsterdam > -"),
        // 连字符与撇号夹在词中间是地名的一部分（此前「-」在词表里是时间段分隔符，连字符地名一直拼不起来）。
        ("9h à Aix-en-Provence", "- 09:00 Europe/Paris > -"),
        ("9am in Côte d'Ivoire", "- 09:00 Africa/Abidjan > -"),
        ("9am in Winston-Salem", "- 09:00 America/New_York > -"),
        // 没连成时间段的短横把两处隔开，东京归后面那一处（此前归了前面、被丢掉）。
        ("Berlin 9:00 - Tokyo 16:00", "- 09:00 Europe/Berlin > -|- 16:00 Asia/Tokyo > -"),
        ("9:00 - 10:00 Tokyo", "- 09:00–10:00 Asia/Tokyo > -"),
        // 零散词只对上多词地名里的一个词：只认大城（「place」是 University Place 的别名，此前读成洛杉矶时间）。
        ("14:00 missing/place", "- 14:00 - > -"),
        ("3pm Rio", "- 15:00 America/Sao_Paulo > -"),
        ("tanaka san 3pm", "- 15:00 - > -"),
        // 零散词里的连字符地名整个去查（此前在连字符处切开：Нью-Йорк 的「Йорк」对上英国约克，Winston-Salem 的 Salem 对上印度）。
        ("через 3 часа Нью-Йорк", "- +180m America/New_York > -"),
        ("3pm Winston-Salem", "- 15:00 America/New_York > -"),
        // 零散词要不要看首字母大写按句判：后面另一句大写开头不改前面的读法（此前按整段判）。
        ("by noon tokyo\n\nThanks!", "- 12:00 Asia/Tokyo > -"),
        // ：法语句首的「Par」对上巴黎的代码别名 PAR；韩语「뉴욕처럼」的助词；印尼语用点号写的整点。
        ("Par exemple 14:00, demain 9:00 Tokyo", "- 14:00 - > -|+1d 09:00 Asia/Tokyo > -"),
        ("3시간 후 뉴욕처럼 입력할 수 있습니다.", "- +180m America/New_York > -"),
        ("Coba ketik 14.00, besok 09.00 Tokyo", "- 14:00 - > -|+1d 09:00 Asia/Tokyo > -"),
        ("It costs 14.00 USD", ""),
    ];
    let mut failures = Vec::new();
    for (text, want) in cases {
        let got = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup }).mentions.iter().map(summary).collect::<Vec<_>>().join("|");
        if got != *want {
            failures.push(format!("{text}\n    want {want}\n    got  {got}"));
        }
    }
    let _ = crate::city_index::dispatch("city.close", json!({"handle": handle}));
    assert!(failures.is_empty(), "{} failed:\n{}", failures.len(), failures.join("\n"));
}

/// 十六语公开通知与日程中的时间写法，用随包城市索引、按那条消息的语言读。
/// 反例（不该读成时间或地名的）同样在表里。
#[cfg(not(feature = "intents-only"))] // 随包城市索引 intents-only 不带
#[test]
fn real_message_forms_read_what_was_written() {
    let opened = crate::city_index::dispatch(
        "city.open",
        json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")}),
    )
    .unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |t: &str, strong: bool| city_lookup(Some(handle), t, strong);
    let cases: &[(&str, &str, &str)] = &[
        // 线索词同时是区间词（a / às / à / alle）、前面又是钟点：那是时间段的「到」，不是另一处。
        ("es", "De 10:00 a 12:00 hrs", "- 10:00–12:00 - > -"),
        ("pt", "das 9h às 18h", "- 09:00–18:00 - > -"),
        ("pt", "14h30 às 16h30 (horário de Brasília)", "- 14:30–16:30 America/Sao_Paulo > -"),
        ("fr", "de 22h à 6h", "- 22:00–06:00 - > -"),
        ("it", "dalle 9 alle 12", "- 09:00–12:00 - > -"),
        // 光秃秃的起点，另一端带钟点词。
        ("de", "von 9 bis 12 Uhr", "- 09:00–12:00 - > -"),
        ("nl", "van 9 tot 12 uur", "- 09:00–12:00 - > -"),
        ("ru", "с 9 до 12 часов", "- 09:00–12:00 - > -"),
        ("fr", "9-12h", "- 09:00–12:00 - > -"),
        // 反例：数量区间与价钱。
        ("es", "de 9 a 12 años", ""),
        ("en", "It costs 10.00 - 12.00 USD", ""),
        // 点号钟点在时间段里：另一端是写明的钟点，或后面紧跟时区。
        ("id", "Kamis, 22 Mei 2025, Jam: 10.00 – 12.00 WIB", "2025-05-22 10:00–12:00 +420 > -"),
        ("de", "01.04.2025 | 17.00 - 19.00 Uhr", "2025-04-01 17:00–19:00 - > -"),
        // 韩语：「5시간」是五个小时；「2025. 7. 10.」是日期；「∼」是区间符号；同一段后面没写年的沿用前面的年。
        ("ko", "(최대 5시간)", ""),
        ("ko", "2025. 7. 10. (목) 19:00 ~ 22:30", "2025-07-10 19:00–22:30 - > -"),
        ("ko", "일시: 2025. 7. 26.(토) 07:00 ∼ 07:20 (20분)", "2025-07-26 07:00–07:20 d20 - > -"),
        ("ko", "2026. 4. 27.(월) 10:00 마감 5. 13.(수) 23:59", "2026-04-27 10:00 - > -|2026-05-13 23:59 - > -"),
        ("ko", "2025년 2월 15일(토) 23:00 ~ 2월 16일(일) 07:00", "2025-02-15 23:00 - > -|2025-02-16 07:00 - > -"),
        // 日语、中文：后一端自己带上下午；终点跟着上午套成 0 点时再加 12 小时；民国纪年。
        ("ja", "午前2時～午前4時は運休", "- 02:00–04:00 - > -"),
        ("ja", "2時間", ""),
        ("zh", "114年9月26日(五)上午9:00~12:00", "2025-09-26 09:00–12:00 - > -"),
        ("zh", "上午11点到1点", "- 11:00–13:00 - > -"),
        // 独立日期标题可跨空行合入首个钟点，已有钟点的日期沿用仍不跨段。
        ("pl", "08 października 2025 (środa)\n\ngodz 15:00 - 17:00", "2025-10-08 15:00–17:00 - > -"),
        ("pl", "środa 03 grudnia 2025 r.\n\nGodzina : ⏱️ 10.00", "2025-12-03 10:00 - > -"),
        ("pl", "do 24 marca 2025 r. (poniedziałek) do godziny 12:00.", "2025-03-24 12:00 - > -"),
        ("pl", "19 listopada 2025, godz. 11", "2025-11-19 11:00 - > -"),
        ("en", "Oct 3 is the deadline. Call at 9am", "10-03 09:00 - > -"),
        ("pt", "18 ago - 2025 • 10:00", "2025-08-18 10:00 - > -"),
        // 首字母大写是语法要求的词不当地名：句首、冒号后、德语名词；零散的单个词只认大城。
        ("de", "Beginn: 22.09.2025   Ende: 27.09.2025", "2025-09-22 - - > -|2025-09-27 - - > -"),
        ("fr", "Date limite d’inscription : 25 juin 2025", "2025-06-25 - - > -"),
        ("tr", "Son Kayıt Tarihi: 05.02.2025", "2025-02-05 - - > -"),
        ("tr", "(Seminer Saati: 21 Eylül 2024 saat: 16:00 – 21:00)", "2024-09-21 16:00–21:00 - > -"),
        ("en", "Mobile: call at 3pm", "- 15:00 - > -"),
        ("fr", "vendredi 14:00 Genève", "w5 14:00 Europe/Zurich > -"),
        ("en", "3pm Boise", "- 15:00 America/Boise > -"),
        // 时区以它命名的小城不受名次限制（「2011-12-30 12:00 Apia」在前 5,000 的限制下会丢失萨摩亚）。
        ("en", "Reykjavik 15:00", "- 15:00 Atlantic/Reykjavik > -"),
        ("en", "2011-12-30 12:00 Apia", "2011-12-30 12:00 Pacific/Apia > -"),
        // 有线索的也不认地名里的一个普通词（En ruso = 用俄语），小写的普通词跟在介词后面不报「没认出」。
        ("es", "En ruso: 4 de marzo (09:00 hora de Ginebra)", "03-04 09:00 Europe/Zurich > -"),
        // 只挨着终点的时段词说的是终点；下班前写了 AoE 是那天 23:59。
        ("de", "Gearbeitet wird in der Nacht, jeweils von 22 Uhr bis 6 Uhr morgens.", "- 22:00–06:00 - > -"),
        ("en", "1 Sept 2025, End of Day, AoE", "2025-09-01 ~23:59 Etc/GMT+12 > -"),
    ];
    let mut failures = Vec::new();
    for (lang, text, want) in cases {
        let got = understand(text, &Options { region: "US", ui_language: lang, lookup: &lookup }).mentions.iter().map(summary).collect::<Vec<_>>().join("|");
        if got != *want {
            failures.push(format!("[{lang}] {text}\n    want {want}\n    got  {got}"));
        }
    }
    let _ = crate::city_index::dispatch("city.close", json!({"handle": handle}));
    assert!(failures.is_empty(), "{} of {} failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
}

/// 公开日程中的时间写法：四位数字写的钟点做时间段的一端、日本元号、终点前的「翌」、两头都写日期的时间段、
/// 西语不带 de 的时区词。反例（不该读成时间的）同样在表里。
#[test]
fn exam_round_three_forms() {
    check(&[
        // 四位数字的钟点只在它是时间段的一端、另一端是写明的钟点时才算：2000 像年，两头都光秃秃的也不算。
        ("dinsdag 9 december 2025 | 1500 - 17:00 uur", &["2025-12-09 15:00–17:00 - > -"]),
        ("2000 - 23:00", &["- 23:00 - > -"]),
        ("1500 - 1700 m", &[]),
        // 日本の元号：令和 n = 2018+n、平成 n = 1988+n、元年 = 1；括号里的星期照旧并进日期。
        ("令和7年5月1日(木)", &["2025-05-01 - - > -"]),
        ("令和元年5月1日", &["2019-05-01 - - > -"]),
        ("平成31年4月30日", &["2019-04-30 - - > -"]),
        // 终点前的「翌 / 翌日」把终点挪到第二天，即使终点比起点晚；地区名（京阪神）不是地名。
        ("京阪神は4時～翌2時", &["- 04:00–02:00+1 - > -"]),
        ("20時～翌21時", &["- 20:00–21:00+1 - > -"]),
        ("4時～翌日2時", &["- 04:00–02:00+1 - > -"]),
        // 两头都写日期的时间段：同一天并成一处（终点保持同一天）、差一天并成一处（终点在第二天）、
        // 差得多是两次提到。箭头与「>」只有后面跟日期或钟点时才是分隔，后面是地名照旧当目标。
        ("24 fev - 2025 • 13:00 > 24 fev - 2025 • 19:00", &["2025-02-24 13:00–19:00 - > -"]),
        ("24 fev - 2025 • 22:00 > 24 fev - 2025 • 02:00", &["2025-02-24 22:00–02:00 - > -"]),
        ("24 fev - 2025 • 22:00 → 25 fev - 2025 • 02:00", &["2025-02-24 22:00–02:00+1 - > -"]),
        ("24 fev - 2025 • 13:00 > 27 fev - 2025 • 19:00", &["2025-02-24 13:00 - > -", "2025-02-27 19:00 - > -"]),
        ("9am ET → London", &["- 09:00 America/New_York > Europe/London"]),
    ]);
    // 西语时区词不带 de：与带 de 的读法相同，时区也真的读到（不是「-」）。
    for (with_de, bare, zone) in [
        ("12 de junio de 2025, 12:00 h (hora de España)", "12 de junio de 2025, 12:00 h (hora España)", "Europe/Madrid"),
        ("12 de junio de 2025, 12:00 h (hora de Canarias)", "12 de junio de 2025, 12:00 h (hora Canarias)", "Atlantic/Canary"),
    ] {
        let a: Vec<String> = run(with_de).iter().map(summary).collect();
        let b: Vec<String> = run(bare).iter().map(summary).collect();
        assert_eq!(a, b, "{with_de} 与 {bare} 要读出同样的时区");
        assert_eq!(a, vec![format!("2025-06-12 12:00 {zone} > -")], "{with_de}");
    }
}

/// 往返造句器查出的缺口：波兰语区间的「到」被当德语星期四、波兰语方位格与俄语前置格的城市名、
/// 日语韩语「下一 + 星期」、越南语不带 năm 的年、印尼语 besok lusa、韩语「X 시간」里的悉尼。
#[test]
fn round_trip_gaps_are_closed() {
    check(&[
        // 波兰语 od…do…：do 是区间的「到」，不是德语星期四的缩写；光秃秃数字的两端也算。
        ("od 13:05 do 21:05", &["- 13:05–21:05 - > -"]),
        ("od 9:00 do 17:00", &["- 09:00–17:00 - > -"]),
        ("od 9 do 17", &["- 09:00–17:00 - > -"]),
        // 德语里 Do 14:00 仍是星期四（全文没有别的语言证据）。
        ("Do 14:00", &["w4 14:00 - > -"]),
        // 波兰语方位格的城市名（w Nowym Jorku → Nowy Jork）；不变格的照旧直接命中。
        ("2:00, czas w Nowym Jorku", &["- 02:00 America/New_York > -"]),
        ("26 marca 2027 o 18:15 w Nowym Jorku", &["2027-03-26 18:15 America/New_York > -"]),
        ("w Singapurze 8:00", &["- 08:00 Asia/Singapore > -"]),
        ("w Berlinie 9:30", &["- 09:30 Europe/Berlin > -"]),
        ("w Paryżu 10:00", &["- 10:00 Europe/Paris > -"]),
        ("w Londynie 7:15", &["- 07:15 Europe/London > -"]),
        ("w Tokio 12:00", &["- 12:00 Asia/Tokyo > -"]),
        ("czas w Sydney 3:00", &["- 03:00 Australia/Sydney > -"]),
        // 俄语前置格（в Сиднее → Сидней、в Нью-Йорке → Нью-Йорк）。
        ("сегодня, 19:20, время в Сиднее", &["+0d 19:20 Australia/Sydney > -"]),
        ("в Лондоне 20:00", &["- 20:00 Europe/London > -"]),
        ("в Париже 8:05", &["- 08:05 Europe/Paris > -"]),
        ("в Нью-Йорке 23:10", &["- 23:10 America/New_York > -"]),
        ("в Берлине 6:45", &["- 06:45 Europe/Berlin > -"]),
        ("в Токио 1:00", &["- 01:00 Asia/Tokyo > -"]),
        // 「次の / 次回の / 다음」+ 星期 = 下一周的星期（英语 next Thursday 原本就行）。
        ("次の土曜日の0:30", &["w6:next 00:30 - > -"]),
        ("次回の木曜日の5:00", &["w4:next 05:00 - > -"]),
        ("다음 목요일 4:00", &["w4:next 04:00 - > -"]),
        // 越南语：tháng N 后面紧跟的四位数是年，不写 năm 也算。
        ("8 tháng 2 2025 lúc 20:00", &["2025-02-08 20:00 - > -"]),
        ("20 tháng 3 2026 lúc 18:20 ở Los Angeles", &["2026-03-20 18:20 America/Los_Angeles > -"]),
        // 印尼语 besok lusa = 后天，不是先后两天。
        ("besok lusa pukul 7:45", &["+2d 07:45 - > -"]),
        // 韩语「X 시간」：地名换悉尼也要查得到（런던 시간 原本就行）。
        ("21:55 시드니 시간", &["- 21:55 Australia/Sydney > -"]),
    ]);
}

/// 地名要整个读、不能被中间一个词劫走（Ho Chi Minh 被读成芝加哥、Kota X 被读成印度的科塔、
/// Monaco di Baviera 被读成摩纳哥、七字以上的中日韩名被窗口截去末字）。三条规则：更长的段先查（中日韩 12 个单元、
/// 其他文字 5 个词，连字符照写）；整段查不到时只有段的第一个词（或城市通名后面的专名）单独去查；「城市」通名自己不是地名。
#[test]
fn place_names_are_read_whole_and_not_hijacked() {
    check(&[
        // 多词地名整个先查，靠后的单个词不再单独去查（minh、del 在词表里是虚词，不再把段切碎）。
        ("15:00 Ho Chi Minh City", &["- 15:00 Asia/Ho_Chi_Minh > -"]),
        ("15:00 Ciudad Ho Chi Minh", &["- 15:00 Asia/Ho_Chi_Minh > -"]),
        ("15:00 Cidade de Ho Chi Minh", &["- 15:00 Asia/Ho_Chi_Minh > -"]),
        ("15:00 Hô Chi Minh-Ville", &["- 15:00 Asia/Ho_Chi_Minh > -"]),
        ("15:00 Ho Chi Minh Kenti", &["- 15:00 Asia/Ho_Chi_Minh > -"]),
        ("15:00 Thành phố Hồ Chí Minh", &["- 15:00 Asia/Ho_Chi_Minh > -"]),
        ("15:00 Kota Hồ Chí Minh", &["- 15:00 Asia/Ho_Chi_Minh > -"]),
        // 「城市」通名（kota / thành phố…）自己不是地名，它后面的专名才是。
        ("15:00 Kota Bandung", &["- 15:00 Asia/Jakarta > -"]),
        ("15:00 Kota", &["- 15:00 - > -"]),
        ("15:00 Thành phố", &["- 15:00 - > -"]),
        ("15:00 Thành phố México", &["- 15:00 America/Mexico_City > -"]),
        ("15:00 Thành phố New York", &["- 15:00 America/New_York > -"]),
        // 线索词也是名字的一部分：意语的 di 被当成印尼语的「在」时，整段（连线索词）先查。
        ("15:00 Monaco di Baviera", &["- 15:00 Europe/Berlin > -"]),
        ("15:00 Città del Messico", &["- 15:00 America/Mexico_City > -"]),
        // 连字符地名按原样整个查（Рио-де-Жанейро 的每一段算一个词）。
        ("15:00 Рио-де-Жанейро", &["- 15:00 America/Sao_Paulo > -"]),
        // 中日韩长名不再被截去末字；钟点后隔一个空格的시也不是钟点词。
        ("15:00 イスタンブール", &["- 15:00 Europe/Istanbul > -"]),
        ("15:00 布宜诺斯艾利斯", &["- 15:00 America/Argentina/Buenos_Aires > -"]),
        ("15:00 リウデジャネイロ", &["- 15:00 America/Sao_Paulo > -"]),
        ("3시 30분 시드니", &["- 03:30 Australia/Sydney > -"]),
        // 整段查不到：没有地点（零散词不报「没认出」），不是芝加哥。
        ("15:00 Ho Chi Xyz Abc", &["- 15:00 - > -"]),
        // 缩写自己成一段时照旧认。
        ("15:00 Chi", &["- 15:00 America/Chicago > -"]),
    ]);
}

/// 公开消息批量探针：`EXAM_FILE=<JSON 数组，每条 id / lang / text>` 逐条用随包城市索引读，
/// 每条打一行 JSON（id 与引擎的 Output），交 `Tools/`之外的跑分脚本比对另一个模型标的答案。
#[cfg(not(feature = "intents-only"))] // 随包城市索引 intents-only 不带
#[test]
#[ignore]
fn exam_probe() {
    let path = std::env::var("EXAM_FILE").expect("EXAM_FILE");
    let items: Vec<serde_json::Value> = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let opened = crate::city_index::dispatch("city.open", json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |t: &str, strong: bool| city_lookup(Some(handle), t, strong);
    for item in items {
        let text = item["text"].as_str().unwrap_or("");
        let lang = item["lang"].as_str().unwrap_or("en");
        let out = understand(text, &Options { region: "US", ui_language: lang, lookup: &lookup });
        println!("EXAM {}", json!({"id": item["id"], "output": out}));
    }
}

#[cfg(not(feature = "intents-only"))] // 随包城市索引 intents-only 不带
#[test]
#[ignore]
fn debug_probe() {
    let text = std::env::var("PROBE").unwrap_or_default();
    let folded = fold(&text);
    let u = units(&folded);
    println!("units: {:?}", u.iter().map(|t| (t.text.as_str().to_owned(), t.capital)).collect::<Vec<_>>());
    let mut scanner = Scanner { u: &u, out: Vec::new() };
    scanner.scan();
    for a in &scanner.out {
        println!("atom {:?} [{}..{}]", a.atom, a.from, a.to);
    }
    let opened = crate::city_index::dispatch("city.open", json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |t: &str, strong: bool| { let r = city_lookup(Some(handle), t, strong); println!("lookup {t:?} strong={strong} -> {r:?}"); r };
    let language = std::env::var("PROBE_LANG").unwrap_or_else(|_| "en".into());
    for m in understand(&text, &Options { region: "US", ui_language: &language, lookup: &lookup }).mentions {
        println!("{}", summary(&m));
    }
}

/// 语料核对（ignored）：`PROBE_FILE` 是 JSONL（`{"lang","text","expect":[…]}`），用随包城市索引逐条读，
/// 打印不一致的条目与每种语言的通过数。`PROBE_REGION=US` 时按美国日期顺序读「10/3」。
#[cfg(not(feature = "intents-only"))] // 随包城市索引 intents-only 不带
#[test]
#[ignore]
fn corpus_probe() {
    let path = std::env::var("PROBE_FILE").expect("PROBE_FILE");
    let region = std::env::var("PROBE_REGION").unwrap_or_default();
    let opened = crate::city_index::dispatch("city.open", json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |t: &str, strong: bool| city_lookup(Some(handle), t, strong);
    let mut tally: std::collections::BTreeMap<String, (usize, usize)> = Default::default();
    for line in std::fs::read_to_string(&path).unwrap().lines().filter(|l| !l.trim().is_empty()) {
        let case: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(e) => { println!("BAD JSON {e}: {line}"); continue; }
        };
        let lang = case["lang"].as_str().unwrap_or("?").to_owned();
        let text = case["text"].as_str().unwrap_or_default();
        let want: Vec<String> = case["expect"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect()).unwrap_or_default();
        // 每句自带的 region（数字日期的日月顺序靠它）优先，没有才用 PROBE_REGION。
        let line_region = case["region"].as_str().unwrap_or(&region).to_owned();
        let got: Vec<String> = understand(text, &Options { region: &line_region, ui_language: "en", lookup: &lookup }).mentions.iter().map(summary).collect();
        let entry = tally.entry(lang.clone()).or_default();
        entry.1 += 1;
        if got == want {
            entry.0 += 1;
        } else {
            println!("FAIL [{lang}] {text}\n    want {want:?}\n    got  {got:?}");
        }
    }
    for (lang, (pass, total)) in &tally {
        println!("{lang}: {pass}/{total}");
    }
}

/// 迁移清单：从旧 colloquial.rs 测试表抽出的 JSONL（正例：日期、钟点、有没有地名；相对时间：分钟数；负例：不许读出成立的钟点），
/// 用随包城市索引逐条读新引擎。返回（类，原文，对不对，期望）。删旧解析器之前，每条差异要归成「保持 / 批准的扩展 /
/// 修正的缺陷」。
#[cfg(not(feature = "intents-only"))]
fn migration_results(path: &str) -> Vec<(String, String, bool, String, Vec<String>)> {
    let opened = crate::city_index::dispatch("city.open", json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |t: &str, strong: bool| city_lookup(Some(handle), t, strong);
    let mut out = Vec::new();
    for line in std::fs::read_to_string(path).unwrap().lines().filter(|l| !l.trim().is_empty()) {
        let case: serde_json::Value = serde_json::from_str(line).unwrap();
        let kind = case["kind"].as_str().unwrap_or("?").to_owned();
        let text = case["text"].as_str().unwrap_or_default().to_owned();
        let mentions = understand(&text, &Options { region: "US", ui_language: "en", lookup: &lookup }).mentions;
        let clocked: Vec<&Mention> = mentions.iter().filter(|m| m.time.is_some() && m.issues.is_empty()).collect();
        let relative: Vec<&Mention> = mentions.iter().filter(|m| m.relative_minutes.is_some()).collect();
        let has_place = |m: &Mention| matches!(m.source, Some(ZoneRef::City { .. } | ZoneRef::Region { .. } | ZoneRef::Fixed { .. } | ZoneRef::Options { .. } | ZoneRef::Place { .. }));
        let want_place = case["place"].is_string();
        let ok = match kind.as_str() {
            "positive" => clocked.first().is_some_and(|m| {
                let t = m.time.unwrap();
                let day_ok = match (&case["day"], &m.date) {
                    (serde_json::Value::Null, None) => true,
                    (d, Some(DateSpec::Offset { days })) if d["offset"].is_i64() => d["offset"].as_i64() == Some(*days as i64),
                    (d, Some(DateSpec::Weekday { weekday, week })) if d["weekday"].is_u64() => {
                        d["weekday"].as_u64() == Some(*weekday as u64) && (d["next"].as_bool() == Some(true)) == (*week == Some("next"))
                    }
                    _ => false,
                };
                t.hour as u64 == case["hour"].as_u64().unwrap() && t.minute as u64 == case["minute"].as_u64().unwrap() && day_ok && has_place(m) == want_place
            }),
            "relative" => relative.first().is_some_and(|m| m.relative_minutes == case["minutes"].as_i64() && has_place(m) == want_place),
            _ => clocked.is_empty() && relative.is_empty(),
        };
        let mut want = case.clone();
        if let Some(o) = want.as_object_mut() {
            o.remove("text");
        }
        out.push((kind, text, ok, want.to_string(), mentions.iter().map(summary).collect()));
    }
    out
}

/// 打印迁移清单里和旧版不一致的条目与每类通过数（ignored；`MIGRATION_FILE` 缺省用入库的那份）。
#[cfg(not(feature = "intents-only"))]
#[test]
#[ignore]
fn migration_probe() {
    let path = std::env::var("MIGRATION_FILE").unwrap_or_else(|_| concat!(env!("CARGO_MANIFEST_DIR"), "/tests/corpus/migration-colloquial.jsonl").to_owned());
    let mut tally: std::collections::BTreeMap<String, (usize, usize)> = Default::default();
    for (kind, text, ok, want, got) in migration_results(&path) {
        let entry = tally.entry(kind.clone()).or_default();
        entry.1 += 1;
        if ok {
            entry.0 += 1;
        } else {
            println!("FAIL [{kind}] {text}\n    want {want}\n    got  {got:?}");
        }
    }
    for (kind, (pass, total)) in &tally {
        println!("{kind}: {pass}/{total}");
    }
}

/// 迁移门：旧版的句子新引擎要读对；还读不对的逐条列在 `migration-known-gaps.txt`（每行「原文 \t 归类」）。
/// 清单外的读错了（退步）会挂，清单里的读对了也会挂（提醒把它删掉，清单只紧不松）。
#[cfg(not(feature = "intents-only"))]
#[test]
fn migration_gate_old_sentences_stay_read() {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/corpus");
    let gaps_text = std::fs::read_to_string(format!("{dir}/migration-known-gaps.txt")).unwrap();
    let gaps: std::collections::HashSet<&str> =
        gaps_text.lines().filter(|l| !l.starts_with('#') && !l.trim().is_empty()).filter_map(|l| l.split('\t').next()).collect();
    let mut regressions = Vec::new();
    let mut fixed = Vec::new();
    for (kind, text, ok, want, got) in migration_results(&format!("{dir}/migration-colloquial.jsonl")) {
        match (ok, gaps.contains(text.as_str())) {
            (false, false) => regressions.push(format!("[{kind}] {text}\n    want {want}\n    got  {got:?}")),
            (true, true) => fixed.push(text),
            _ => {}
        }
    }
    assert!(regressions.is_empty(), "{} 条旧版读对的句子新引擎读错了：\n{}", regressions.len(), regressions.join("\n"));
    assert!(fixed.is_empty(), "这些句子已经读对，从 migration-known-gaps.txt 删掉：{fixed:?}");
}

/// 严格写法的迁移：旧 converter::parse 对 `converter-inputs.txt` 每句冻结的答案（`migration-converter.jsonl`），新引擎要读出
/// 同样的钟点（含秒）、终点、日期、时区；旧版读不懂的，新引擎不许读出成立的钟点。返回（原文，对不对，旧答案，新读法）。
#[cfg(not(feature = "intents-only"))]
fn converter_migration_results() -> Vec<(String, bool, String, Vec<String>)> {
    let opened = crate::city_index::dispatch("city.open", json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |t: &str, strong: bool| city_lookup(Some(handle), t, strong);
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/corpus/migration-converter.jsonl");
    let mut out = Vec::new();
    for line in std::fs::read_to_string(path).unwrap().lines().filter(|l| !l.trim().is_empty()) {
        let case: serde_json::Value = serde_json::from_str(line).unwrap();
        let text = case["text"].as_str().unwrap_or_default().to_owned();
        let mentions = understand(&text, &Options { region: "US", ui_language: "en", lookup: &lookup }).mentions;
        let valid: Vec<&Mention> = mentions.iter().filter(|m| (m.time.is_some() || m.instant.is_some()) && m.issues.is_empty()).collect();
        let ok = if case["ok"].as_bool() == Some(true) {
            let p = &case["parsed"];
            valid.first().is_some_and(|m| {
                let Some(t) = m.time else { return false };
                let days = match &m.date {
                    Some(DateSpec::Offset { days }) => *days as i64,
                    _ => 0,
                };
                let same_clock = t.hour as u64 == p["hour"].as_u64().unwrap_or(99)
                    && t.minute as u64 == p["minute"].as_u64().unwrap_or(99)
                    && t.second as u64 == p["second"].as_u64().unwrap_or(99)
                    && days + t.day_offset as i64 == p["dayOffset"].as_i64().unwrap_or(0);
                let same_date = match (&m.date, p["year"].as_u64()) {
                    (Some(DateSpec::Absolute { year, month, day }), Some(y)) => {
                        *year as u64 == y && *month as u64 == p["month"].as_u64().unwrap_or(0) && *day as u64 == p["day"].as_u64().unwrap_or(0)
                    }
                    (Some(DateSpec::Absolute { .. }), None) => false,
                    (_, Some(_)) => false,
                    _ => true,
                };
                let same_end = match (&m.end, p["endHour"].as_u64()) {
                    (Some(e), Some(h)) => e.hour as u64 == h && e.minute as u64 == p["endMinute"].as_u64().unwrap_or(99),
                    (None, None) => true,
                    _ => false,
                };
                let same_zone = match (&m.source, p["zone"].as_str(), p["offsetSeconds"].as_i64()) {
                    (None, None, None) => true,
                    // 旧版把「成都时间」「osaka time」的地名原样交宿主去查；新版直接查到时区。
                    (Some(ZoneRef::City { .. } | ZoneRef::Region { .. } | ZoneRef::Options { .. }), Some(z), _) if !z.contains('/') => true,
                    (Some(ZoneRef::Region { iana } | ZoneRef::City { iana, .. }), Some(z), _) => iana.eq_ignore_ascii_case(z),
                    (Some(ZoneRef::Place { query }), Some(z), _) => query.eq_ignore_ascii_case(z),
                    (Some(ZoneRef::Fixed { minutes, .. }), None, Some(s)) => *minutes as i64 * 60 == s,
                    // 世界时 / zulu：旧版存偏移 0，新版存 UTC 时区，同一件事。
                    (Some(ZoneRef::Region { iana }), None, Some(0)) => iana == "UTC" || iana == "Etc/UTC",
                    _ => false,
                };
                same_clock && same_date && same_end && same_zone
            })
        } else {
            valid.is_empty()
        };
        let old = if case["ok"].as_bool() == Some(true) { case["parsed"].to_string() } else { format!("error {}", case["error"]) };
        out.push((text, ok, old, mentions.iter().map(summary).collect()));
    }
    out
}

/// 打印严格写法迁移里和旧版不一致的条目（ignored）。
#[cfg(not(feature = "intents-only"))]
#[test]
#[ignore]
fn converter_migration_probe() {
    let results = converter_migration_results();
    let pass = results.iter().filter(|r| r.1).count();
    for (text, ok, old, got) in &results {
        if !ok {
            println!("FAIL {text:?}\n    old  {old}\n    got  {got:?}");
        }
    }
    println!("converter: {pass}/{}", results.len());
}

/// 严格写法的迁移门：还读不对的逐条列在 `migration-converter-known-gaps.txt`（每行「原文 \t 归类」，原文用 JSON 字符串写，
/// 保住首尾空格）；清单外的读错了会挂，清单里的读对了也会挂。
#[cfg(not(feature = "intents-only"))]
#[test]
fn converter_migration_gate_strict_forms_stay_read() {
    let gaps_text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/corpus/migration-converter-known-gaps.txt")).unwrap();
    let gaps: std::collections::HashSet<String> = gaps_text
        .lines()
        .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
        .filter_map(|l| l.split('\t').next().and_then(|s| serde_json::from_str::<String>(s).ok()))
        .collect();
    let mut regressions = Vec::new();
    let mut fixed = Vec::new();
    for (text, ok, old, got) in converter_migration_results() {
        match (ok, gaps.contains(&text)) {
            (false, false) => regressions.push(format!("{text:?}\n    old  {old}\n    got  {got:?}")),
            (true, true) => fixed.push(text),
            _ => {}
        }
    }
    assert!(regressions.is_empty(), "{} 条旧版读对的严格写法新引擎读错了：\n{}", regressions.len(), regressions.join("\n"));
    assert!(fixed.is_empty(), "这些已经读对，从 migration-converter-known-gaps.txt 删掉：{fixed:?}");
}

/// 核对走 dispatch 的一整圈：纽约 9:00 / 伦敦 14:00 / 新加坡 23:00（新加坡那处差 2 小时）；坏载荷报错不崩。
#[test]
fn crosscheck_dispatch_round_trip() {
    let t = 1_790_600_400_i64;
    let payload = json!({ "mentions": [
        { "index": 0, "group": 0, "instant": t, "zone": "America/New_York", "zoned": true, "hasClock": true },
        { "index": 1, "group": 0, "instant": t, "zone": "Europe/London", "zoned": true, "hasClock": true },
        { "index": 2, "group": 0, "instant": t + 7200, "zone": "Asia/Singapore", "zoned": true, "hasClock": true },
    ]});
    let out = dispatch("understand.crosscheck", payload).unwrap();
    assert_eq!(out, json!({ "same": [[0, 1]], "notes": [{ "a": 0, "b": 2, "deltaMinutes": 120, "kind": "dstSuspect" }] }));
    assert!(dispatch("understand.crosscheck", json!({ "mentions": [{ "index": 0 }] })).is_err());
    assert!(dispatch("understand.crosscheck", json!({})).is_err());
}

/// 反向生成器往返：造句器按十六语模板造句、给出标准答案，引擎用随包城市索引读回来比：恰好读出一处、
/// 简写相同才算对。报每语读对数，读错的逐条打出（`GEN_PER_LANG`、`GEN_SEED` 可调）；先当报告，差距看清后再定门槛。
#[cfg(not(feature = "intents-only"))] // 随包城市索引 intents-only 不带
#[test]
#[ignore]
fn sentencegen_round_trip_report() {
    let opened = crate::city_index::dispatch(
        "city.open",
        json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")}),
    )
    .unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |t: &str, strong: bool| city_lookup(Some(handle), t, strong);
    let per_lang = std::env::var("GEN_PER_LANG").ok().and_then(|v| v.parse().ok()).unwrap_or(200);
    let seed = std::env::var("GEN_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or(1);
    let mut tally: std::collections::BTreeMap<&str, (usize, usize)> = std::collections::BTreeMap::new();
    let mut failures = Vec::new();
    for case in super::sentencegen::cases(seed, per_lang) {
        // 界面语言按 App 的传法只给语言码（pt、zh）。
        let ui = case.lang.split('-').next().unwrap_or(case.lang);
        let got: Vec<String> = understand(&case.text, &Options { region: "US", ui_language: ui, lookup: &lookup }).mentions.iter().map(summary).collect();
        let entry = tally.entry(case.lang).or_insert((0, 0));
        entry.1 += 1;
        if got.len() == 1 && got[0] == case.want {
            entry.0 += 1;
        } else {
            failures.push(format!("GENFAIL {}\t{}\t{}\t{}", case.lang, case.text, case.want, got.join("|")));
        }
    }
    for (lang, (pass, total)) in &tally {
        println!("GEN {lang} {pass}/{total}");
    }
    for line in &failures {
        println!("{line}");
    }
}
#[test]
fn number_spans_are_classified_before_clocks() {
    check(&[
        ("Der Kaffee kostet hier 4.50.", &[]),
        ("Die Basketballer gewannen mit 94:88.", &[]),
        ("Am Ende stand 27:24.", &[]),
        ("Skończyło się 3-1 po rzutach karnych.", &[]),
        ("Seride durum 2-2'ye geldi.", &[]),
        ("Der Kaffee kostet 4.50", &[]),
        ("Beginn um 4.50", &["- 04:50 - > -"]),
        ("2026.09.29", &["2026-09-29 - - > -"]),
        ("Version 9.2.1", &[]),
        ("The build took 15h30", &[]),
        ("Le train part à 15h30", &["- 15:30 - > -"]),
        ("Die App ist jetzt in Version 2.10.", &[]),
        ("The tote bag is 12.50 dollars.", &[]),
        ("Lunch special is 8.50 USD with soup.", &[]),
        ("They raised the fare to 3.20 pounds.", &[]),
        ("The docs cover API version 3.14.", &[]),
        ("The app store build is 9.2.1.", &[]),
        ("Interest rose by two percent.", &[]),
        ("La entrada cuesta 12.50 euros.", &[]),
        ("Actualiza a la versión 4.2.1.", &[]),
        ("El termómetro marca 3 grados bajo cero.", &[]),
        ("L'entrée coûte 12.50 euros.", &[]),
        ("Mets l'application à jour vers la version 4.2.1.", &[]),
        ("Le cours est pour les enfants de 9 à 12 ans.", &[]),
        ("L'abonnement coûte de 10 à 15 euros selon l'âge.", &[]),
        ("アップデートはバージョン 2.10 で安定しました。", &[]),
        ("앱이 버전 2.10으로 업데이트됐어요.", &[]),
        ("펌웨어 4.2.1을 설치하세요.", &[]),
        ("이 티켓은 12.50달러였어요.", &[]),
        ("Grupa dla dzieci od 6 do 12 lat.", &[]),
        ("Wejściówka kosztuje od 10 do 15 zł.", &[]),
        ("Kurs dla początkujących od 9 do 99 lat.", &[]),
        ("Обнови приложение до версии 4.2.1.", &[]),
        ("Sürüm 2.10 dün yayına alındı.", &[]),
        ("Ứng dụng nâng cấp lên phiên bản 2.10.", &[]),
        ("costs 4.50", &[]),
        ("Support version 2.10 until 15:00.", &["- 15:00 - > -"]),
        ("starts at 4.50", &["- 04:50 - > -"]),
        ("Price is 12.50 dollars; call at 15:30.", &["- 15:30 - > -"]),
        ("Version 2.10; call at 15:30.", &["- 15:30 - > -"]),
        ("Children aged 9 to 12 years; call at 15:30.", &["- 15:30 - > -"]),
        ("Costs 10 to 15 euros; call at 15:30.", &["- 15:30 - > -"]),
        ("2026.10.15", &["2026-10-15 - - > -"]),
        ("15.10.2026", &["2026-10-15 - - > -"]),
        ("2026-10-15", &["2026-10-15 - - > -"]),
        ("10/15/2026", &["2026-10-15 - - > -"]),
        ("Release 2026-10-01 at 15:00.", &["2026-10-01 15:00 - > -"]),
        ("Release 2026.10.01 at 15:00.", &["2026-10-01 15:00 - > -"]),
        ("Release 01.10.2026 at 15:00.", &["2026-10-01 15:00 - > -"]),
        ("Release 2026/10/01 at 15:00.", &["2026-10-01 15:00 - > -"]),
        ("Release 15/10/2026 at 15:00.", &["2026-10-15 15:00 - > -"]),
        ("Release 10/15/2026 at 15:00.", &["2026-10-15 15:00 - > -"]),
        ("Release 3.14 at 15:00.", &["- 15:00 - > -"]),
        ("between two and three percent", &[]),
        ("It costs between 10 and 15 euros. Call at 15:00.", &["- 15:00 - > -"]),
        ("Children between 9 and 12 years old meet at 15:00.", &["- 15:00 - > -"]),
        ("The fare is between two and three euros, call at 15:00.", &["- 15:00 - > -"]),
        ("Children from 9 to 12 years old meet at 15:00.", &["- 15:00 - > -"]),
        ("2025. 9. 12.(금) 14:00 ~ 16:30 세미나", &["2025-09-12 14:00–16:30 - > -"]),
        ("12세", &[]),
    ]);
}

#[test]
fn durations_attach_or_stay_out() {
    check(&[
        ("The build took 15h30", &[]),
        ("Le train part à 15h30", &["- 15:30 - > -"]),
        ("The build took 15h30 in CI.", &[]),
        ("La reunión es a las 15:00 y durará 2 horas.", &["- 15:00 d120 - > -"]),
        ("La sesión de fotos es a las 11:30 y durará 2 horas.", &["- 11:30 d120 - > -"]),
        ("Taller de 15:00 a 17:00 CET, 2 horas.", &["- 15:00–17:00 d120 +60 > -"]),
        ("La réunion est à 15h et durera 2 heures.", &["- 15:00 d120 - > -"]),
        ("Webinaire à 19h, 1 heure, avec questions à la fin.", &["- 19:00 d60 - > -"]),
        ("La riunione è alle 15:00 e durerà 2 ore.", &["- 15:00 d120 - > -"]),
        ("Il volo ha 30 minuti di ritardo.", &[]),
        ("15時から2時間の営業相談会です。", &["- 15:00 d120 - > -"]),
        ("10時から1時間半のピアノレッスン。", &["- 10:00 d90 - > -"]),
        ("17時から45分の掃除当番。", &["- 17:00 d45 - > -"]),
        ("土曜の13時から3時間の映像教室。", &["w6 13:00 d180 - > -"]),
        ("9時から30分の朝礼があります。", &["- 09:00 d30 - > -"]),
        ("午後1時から2時間45分の実技試験。", &["- 13:00 d165 - > -"]),
        ("下班前把演示稿发我。下周二上午9点（新加坡时间）给客户演示45分钟。", &["- ~17:00 - > -", "w2:next 09:00 d45 Asia/Singapore > -"]),
        ("月報會議排在11月5日14:00，半小時就好；明天早上9點先內部對一次。", &["11-05 14:00 d30 - > -", "+1d 09:00 - > -"]),
        ("来週の金曜日 午後3時（大阪時間）から2時間、販促会議があります。午前10時のリハーサルは各自で参加してください。", &["w5:next 15:00 d120 Asia/Tokyo > -", "w5:next^ 10:00 - > -"]),
        ("La junta de vecinos es el jueves a las 19:00 y durará una hora. La limpieza queda el sábado a las 9:30 de la mañana.", &["w4 19:00 d60 - > -", "w6 09:30 - > -"]),
        ("A manutenção começa amanhã às 4 da tarde e vai durar 3 horas. Antes disso, às 15h, enviaremos o aviso.", &["+1d 16:00 d180 - > -", "+1d^ 15:00 - > -"]),
        ("Bijeenkomst om 10:00, duur 90 minuten.", &["- 10:00 d90 - > -"]),
        ("Webinar om 19:00, 1 uur, daarna vragen.", &["- 19:00 d60 - > -"]),
        ("Webinar o 19:00, 1 godzina.", &["- 19:00 d60 - > -"]),
        ("Trening trwał 2h bez przerwy.", &[]),
        ("Тренировка в 18:00, длительность 45 минут.", &["- 18:00 d45 - > -"]),
        ("Лекция в 17:00, 1 час, потом вопросы.", &["- 17:00 d60 - > -"]),
        ("Экскурсия в 11:30, длится полтора часа.", &["- 11:30 d90 - > -"]),
        ("Kulüp toplantısı 11:30'da, 2 saat sürüyor.", &["- 11:30 d120 - > -"]),
        ("Lớp của thứ bảy là lúc 10:00, thời lượng 90 phút.", &["w6 10:00 d90 - > -"]),
        ("Vở kịch dài 3 giờ.", &[]),
        ("took 15h30", &[]),
        ("starts at 15h30", &["- 15:30 - > -"]),
        ("15h30", &["- 15:30 - > -"]),
        ("for 2 hours", &[]),
        ("durera 2 heures", &[]),
        ("3時間", &[]),
        ("半小時", &[]),
        ("90 phút", &[]),
        ("trwał 2h", &[]),
        ("6 h 10 du matin, heure de Tokyo", &["- 06:10 Asia/Tokyo > -"]),
        ("7 h 15 du soir", &["- 19:15 - > -"]),
        ("Le train de quatre heures moins dix est complet.", &["- 03:50 - > -"]),
        ("De winkel is open van 9 tot 12 uur.", &["- 09:00–12:00 - > -"]),
        ("van 10 uur tot 12 uur", &["- 10:00–12:00 - > -"]),
        ("с 9 до 12 часов", &["- 09:00–12:00 - > -"]),
        ("Lớp phụ đạo bắt đầu 9 giờ rưỡi.", &["- 09:30 - > -"]),
        ("Ca sáng của tôi bắt đầu 7:05.", &["- 07:05 - > -"]),
        ("tôi bắt đầu 7:05", &["- 07:05 - > -"]),
        ("9am, lunch in Tokyo, 2 hours", &["- 09:00 ~Asia/Tokyo > -"]),
    ]);
}

#[test]
fn russian_clock_prepositions_win_over_duration_units() {
    let literal_cases: &[(&str, &[&str])] = &[
        ("Работаем с 9 часов до 18 часов.", &["- 09:00–18:00 - > -"]),
        ("Работаем с 9 часов до 18 часов 2 июня.", &["06-02 09:00–18:00 - > -"]),
        ("Встреча в 5 часов.", &["- 05:00 - > -"]),
        ("Дорога заняла 5 часов.", &[]),
        ("Позвоню через 5 часов.", &["- +300m - > -"]),
        ("Ремонт длился 2 часа 30 минут.", &[]),
        ("Дорога заняла 1час.", &[]),
        ("Встреча в 1 час 30 минут.", &["- 01:30 - > -"]),
        ("Работаем с 9 часов до 18 часов2 июня.", &["06-02 09:00–18:00 - > -"]),
        ("Пятница с 9 часов до 18 часов 2 июня.", &["06-02 09:00–18:00 - > -"]),
    ];
    let mut cases: Vec<(String, Vec<String>)> = literal_cases.iter().map(|(text, expected)| {
        ((*text).to_owned(), expected.iter().map(|reading| (*reading).to_owned()).collect())
    }).collect();
    // 每个封闭介词与小时词形都分别检查独立钟点和紧邻日期。
    for prefix in ["с", "до", "в", "к", "около", "после", "от"] {
        for (hour, unit) in [(1, "час"), (2, "часа"), (5, "часов")] {
            cases.push((format!("Встреча {prefix} {hour} {unit}."), vec![format!("- {hour:02}:00 - > -")]));
            cases.push((format!("Встреча {prefix} {hour} {unit} 2 июня."), vec![format!("06-02 {hour:02}:00 - > -")]));
        }
    }
    let expected: Vec<Vec<&str>> = cases.iter().map(|(_, readings)| readings.iter().map(String::as_str).collect()).collect();
    let checks: Vec<(&str, &[&str])> = cases.iter().zip(&expected).map(|((text, _), readings)| (text.as_str(), readings.as_slice())).collect();
    check(&checks);
}

#[test]
fn russian_hour_followed_by_date_keeps_the_day() {
    check(&[
        ("Звоните до 6 часов 15 июня.", &["06-15 06:00 - > -"]),
        ("Встреча в 5 часов 30 минут.", &["- 05:30 - > -"]),
        ("Поезд в 5 часов 30.", &["- 05:30 - > -"]),
    ]);
}

#[test]
fn relative_times_and_timestamps() {
    check(&[
        ("Der Datensatz trägt den Zeitstempel 1789041600.", &["- @1789041600 - > -"]),
        ("El evento se guardó con unix 1789041600.", &["- @1789041600 - > -"]),
        ("L'événement a été enregistré avec unix 1774452000.", &["- @1774452000 - > -"]),
        ("L'evento è stato salvato con unix 1789041600.", &["- @1789041600 - > -"]),
        ("unix タイムスタンプ 1727179200 の通知。", &["- @1727179200 - > -"]),
        ("The build finished at unix 1789555200. Standup tomorrow is at 9.30 am and runs for 45 minutes.", &["- @1789555200 - > -", "+1d 09:30 d45 - > -"]),
        ("Het dossier is aangemaakt op unix 1727179200.", &["- @1727179200 - > -"]),
        ("Через полтора часа обед.", &["- +90m - > -"]),
        ("Событие сохранено: unix 1727179200.", &["- @1727179200 - > -"]),
        ("Через минуту буду.", &["- +1m - > -"]),
        ("Yarım saat içinde sonuçlar açıklanacak.", &["- +30m - > -"]),
        ("15 dakika içinde evdeyim.", &["- +15m - > -"]),
        ("Trong 2 giờ nữa tôi có cuộc gọi video.", &["- +120m - > -"]),
        ("Thợ sửa khóa đến trong 3 giờ.", &["- +180m - > -"]),
        ("Trong 2 giờ 30 phút nữa cửa hàng đóng.", &["- +150m - > -"]),
        ("Trong 1 giờ rưỡi nhà hàng mở cửa.", &["- +90m - > -"]),
        ("Sự kiện được lưu với unix 1700000000.", &["- @1700000000 - > -"]),
        ("演示45分钟后开始", &["- +45m - > -"]),
        ("took 15h30 later", &["- +930m - > -"]),
    ]);
}

#[test]
fn next_weekday_forms() {
    check(&[
        ("Nächste Woche Donnerstag um 17:30", &["w4:next 17:30 - > -"]),
        ("Donnerstag um 17:30", &["w4 17:30 - > -"]),
        ("Il prossimo mercoledì alle 19:00", &["w3:next 19:00 - > -"]),
        ("gelecek hafta çarşamba 09:00", &["w3:next 09:00 - > -"]),
        ("Volgende week maandag om 20:00", &["w1:next 20:00 - > -"]),
        ("Volgende week donderdag om 19:30", &["w4:next 19:30 - > -"]),
        ("W następną środę o 19:00", &["w3:next 19:00 - > -"]),
        ("On Monday we meet at 9:00 and on Thursday at 15:00.", &["w1 09:00 - > -", "w4 15:00 - > -"]),
        ("We meet at 9:00 on Monday and at 15:00 on Thursday.", &["w1 09:00 - > -", "w4 15:00 - > -"]),
    ]);
}

#[test]
fn inflected_month_names() {
    check(&[
        ("1 Eylül'de 09:00", &["09-01 09:00 - > -"]),
        ("24 Ağustos'ta 21:00", &["08-24 21:00 - > -"]),
        ("8 Mayıs'ta 15:00", &["05-08 15:00 - > -"]),
        ("30 Temmuz'da 17:00", &["07-30 17:00 - > -"]),
        ("1 Eylul’de 09:00", &["09-01 09:00 - > -"]),
        ("3 października", &["10-03 - - > -"]),
        ("5 czerwca o 8:00", &["06-05 08:00 - > -"]),
        ("12 marca 2026", &["2026-03-12 - - > -"]),
        ("Spotkanie 09 listopada 2025 (niedziela) o 10:00.", &["2025-11-09 10:00 - > -"]),
        ("czwartek 04 września 2025 r.", &["2025-09-04 - - > -"]),
        ("Termin: 07 marca 2026.", &["2026-03-07 - - > -"]),
        ("Wyjazd 1 maja 2026 r. o 6:30.", &["2026-05-01 06:30 - > -"]),
        ("Konferencja zaczyna się 3 października.", &["10-03 - - > -"]),
        ("Szkolenie odbędzie się 12 marca 2026 w godz. 10:00 - 14:00.", &["2026-03-12 10:00–14:00 - > -"]),
        ("Sesja zaczyna się 5 czerwca o 8:00.", &["06-05 08:00 - > -"]),
        ("Konferencja zaczyna sie 3 pazdziernika.", &["10-03 - - > -"]),
        ("Spotkanie 3 sie. o 18:00.", &["08-03 18:00 - > -"]),
        ("się 3 razy zmieniła.", &[]),
        ("Встреча 3-го октября в 18:00.", &["10-03 18:00 - > -"]),
        ("Встреча 3 октября в 18:00.", &["10-03 18:00 - > -"]),
    ]);
}

#[test]
fn numeric_dates_by_region() {
    check(&[
        ("Giao sofa vào 15/10/2026 lúc 9:00.", &["2026-10-15 09:00 - > -"]),
        ("Workshop vào 15/10 lúc 10:00.", &["10-15 10:00 - > -"]),
        ("Họp vào 15:00.", &["- 15:00 - > -"]),
        ("Bilans zamkniemy 20.11 o 18:00.", &["11-20 18:00 - > -"]),
        ("Pociąg odjeżdża o 20.11.", &["- 20:11 - > -"]),
        ("Spotkanie o 20.11 i o 18:00.", &["- 20:11 - > -", "- 18:00 - > -"]),
        ("25 tháng 10 năm 2026", &["2026-10-25 - - > -"]),
        ("Ngày 25 tháng 10 năm 2026", &["2026-10-25 - - > -"]),
        ("25 tháng 10", &["10-25 - - > -"]),
    ]);
}

#[test]
fn relative_day_words() {
    check(&[
        ("昨夜の23時10分に資料を送りました。", &["-1d 23:10 - > -"]),
        ("Evvelsi gün 07:00'de yola çıktık.", &["-2d 07:00 - > -"]),
        ("Questa sera alle 22:00", &["+0d 22:00 - > -"]),
        ("stasera alle 22:00", &["+0d 22:00 - > -"]),
        ("HỌP MAI 15:00 TOKYO.", &["+1d 15:00 Asia/Tokyo > -"]),
        ("Mai kiểm tra sức khỏe lúc 7:45 sáng.", &["+1d 07:45 - > -"]),
        ("Cuộc hẹn\tthợ\tmai\t9:30\tHà Nội.", &["+1d 09:30 Asia/Bangkok > -"]),
        ("Le 3 mai à 10h", &["05-03 10:00 - > -"]),
        ("Le 3 mai à 10h, họp lúc 15:00.", &["05-03 10:00 - > -", "05-03^ 15:00 - > -"]),
        ("Hop on 3 mai at 10:00.", &["05-03 10:00 - > -"]),
        ("mai 3", &["05-03 - - > -"]),
        ("Le 3 mai à 10h. Họp lúc 15:00.", &["05-03 10:00 - > -", "05-03^ 15:00 - > -"]),
    ]);
}

#[test]
fn inheritance_and_next_day_words() {
    check(&[
        ("12월 1일 일정:\n\n09:00에 병원 예약이 있어요.", &["12-01 09:00 - > -"]),
        ("Party on Sep 12. Cake at 20:00.", &["09-12 20:00 - > -"]),
        ("11월 15일 안내입니다:\n09:30 KST 워크숍\n13:00 KST 점심", &["11-15 09:30 +540 > -", "11-15^ 13:00 +540 > -"]),
        ("Standup tomorrow 9:30. Sync at 15:00 Singapore time.", &["+1d 09:30 - > -", "+1d^ 15:00 Asia/Singapore > -"]),
        ("Standup tomorrow 9:30.\n\nSync at 15:00 Singapore time.", &["+1d 09:30 - > -", "- 15:00 Asia/Singapore > -"]),
        ("Standup tomorrow 9:30. Sync Thursday at 15:00.", &["+1d 09:30 - > -", "w4 15:00 - > -"]),
        ("リリースは10月3日18:00～19:00（日本時間）です。翌朝9時に振り返り会をします。", &["10-03 18:00–19:00 Asia/Tokyo > -", "10-04 09:00 - > -"]),
        ("tomorrow 18:00. The next morning 9:00.", &["+1d 18:00 - > -", "+2d 09:00 - > -"]),
        ("10月3日18時。翌日。9時", &["10-03 18:00 - > -", "10-04 09:00 - > -"]),
        ("4時～翌日2時", &["- 04:00–02:00+1 - > -"]),
        ("翌朝9時", &["+1d 09:00 - > -"]),
        ("10月31日18時。翌朝9時", &["10-31 18:00 - > -", "11-01 09:00 - > -"]),
        ("2026年12月31日18時。翌朝9時", &["2026-12-31 18:00 - > -", "2027-01-01 09:00 - > -"]),
        ("2024年2月28日18時。翌朝9時", &["2024-02-28 18:00 - > -", "2024-02-29 09:00 - > -"]),
        ("2026年2月28日18時。翌朝9時", &["2026-02-28 18:00 - > -", "2026-03-01 09:00 - > -"]),
        ("2月28日18時。翌朝9時。10時", &["02-28 18:00 - > -", "- 09:00 - > - #unsupportedRelativeDate:翌朝", "- 10:00 - > -"]),
        ("10/3 18:00. The next morning 9:00.", &["10-03 18:00 - > - ?1", "- 09:00 - > - #unsupportedRelativeDate:The next morning"]),
        ("10月3日18時。\n\n翌朝9時", &["10-03 18:00 - > -", "+1d 09:00 - > -"]),
    ]);
}

#[test]
fn date_headings_across_blank_lines() {
    check(&[
        ("09 listopada 2025 (niedziela)\n\n\nGodzina: 10.00", &["2025-11-09 10:00 - > -"]),
        ("Konferencja\n\nczwartek 04 września 2025 r.\n\ngodz. 15:00 - 17:00", &["2025-09-04 15:00–17:00 - > -"]),
        ("12 March 2026:\n\nDoors open 18:30", &["2026-03-12 18:30 - > -"]),
        ("Call tomorrow at 9:00.\n\nLunch at 13:00.", &["+1d 09:00 - > -", "- 13:00 - > -"]),
        // 后来的日期截断标题，合并后的日期只在钟点所在段落继续沿用。
        ("12 March 2026:\n\n13 March 2026:\n\nDoors open 18:30", &["2026-03-12 - - > -", "2026-03-13 18:30 - > -"]),
        ("12 March 2026:\n\nDoors open 18:30. Dinner at 20:00.\n\nLunch at 13:00.", &["2026-03-12 18:30 - > -", "2026-03-12^ 20:00 - > -", "- 13:00 - > -"]),
        ("Oct 3 is the deadline.\n\nCall at 9am", &["10-03 - - > -", "- 09:00 - > -"]),
    ]);
}

#[test]
fn date_heading_boundaries() {
    check(&[
        // 标题词按完整词认，正文不会因为地名扩大了提到范围而变成标题。
        ("12월 1일 일정\n\n09:00에 병원 예약이 있어요.", &["12-01 09:00 - > -"]),
        ("2026年3月12日 日程\n\n18:30", &["2026-03-12 18:30 - > -"]),
        ("12 March 2026 Thursday\n\nDoors open 18:30", &["2026-03-12 18:30 - > -"]),
        ("12 March 2026 passed.\n\nDoors open 18:30", &["2026-03-12 - - > -", "- 18:30 - > -"]),
        ("12 March 2026: has passed.\n\nDoors open 18:30", &["2026-03-12 - - > -", "- 18:30 - > -"]),
        ("12 March 2026 was the deadline in Tokyo.\n\nDoors open 18:30", &["2026-03-12 - Asia/Tokyo > -", "- 18:30 - > -"]),
        // 没有独立提到的日期也截断旧标题；相对分钟不是新日期。
        ("12 March 2026:\n\nTomorrow.\n\nDoors open 18:30", &["2026-03-12 - - > -", "- 18:30 - > -"]),
        ("12 March 2026:\n\n03/04.\n\nDoors open 18:30", &["2026-03-12 - - > -", "03-04 18:30 - > - ?1"]),
        ("12 March 2026:\n\nReminder in 30 minutes.\nDoors open 18:30", &["2026-03-12 18:30 - > -", "- +30m - > -"]),
        ("12 March 2026:\n\nEvent information\n\nDoors open 18:30", &["2026-03-12 18:30 - > -"]),
    ]);
}

#[test]
fn bare_hours_take_the_nearest_half_day() {
    check(&[
        ("Wir starten um 9:30, Pause um viertel vor eins.", &["- 09:30 - > -", "- 12:45 - > - ?1"]),
        ("Meeting at 15:00, wrap-up at quarter to three?", &["- 15:00 - > -", "- 14:45 - > - ?1"]),
        ("Meeting at 15:30, wrap-up at quarter past three.", &["- 15:30 - > -", "- 15:15 - > - ?1"]),
        ("Pause um viertel vor eins.", &["- 00:45 - > -"]),
        ("Meeting at 15:00. Break at three. Finish at five.", &["- 15:00 - > -", "- 15:00 - > - ?1", "- 05:00 - > -"]),
        ("Meeting at 15:00. Break at 3am.", &["- 15:00 - > -", "- 03:00 - > -"]),
        ("Meeting at 15:00.\n\nBreak at three.", &["- 15:00 - > -", "- 03:00 - > -"]),
        ("Meeting at 15:00. Break at 03:00.", &["- 15:00 - > -", "- 03:00 - > -"]),
        ("120 days ago at 15:00. In 120 days at three.", &["-120d 15:00 - > -", "+120d 03:00 - > - ?1"]),
    ]);
    let mentions = run("Wir starten um 9:30, Pause um viertel vor eins.");
    let alternative = serde_json::to_value(&mentions[1].alternatives).unwrap();
    assert_eq!(alternative[0]["time"]["hour"], 0);
    assert_eq!(alternative[0]["time"]["minute"], 45);
}

#[test]
fn range_connectors() {
    check(&[
        ("The office is open 9 to 5 on weekdays.", &["- 09:00–05:00 - > -"]),
        ("The office is open 9 tickets.", &[]),
        ("The office is open 9 to 5 tickets.", &[]),
        ("The office is open 9 to 5 dollars.", &[]),
        ("from 9 to 5", &["- 09:00–05:00 - > -"]),
        ("dalle 22:00 all'01:00", &["- 22:00–01:00 - > -"]),
        ("오전 9시부터 낮 12시까지", &["- 09:00–12:00 - > -"]),
        ("밤 10시~새벽 2시", &["- 22:00–02:00 - > -"]),
        ("dalle 22:00 alle 01:00", &["- 22:00–01:00 - > -"]),
        ("오전 9시, 낮 12시", &["- 09:00 - > -", "- 12:00 - > -"]),
        ("22:00–翌日01:00", &["- 22:00–01:00+1 - > -"]),
        ("10pm–2", &["- 22:00–02:00 - > -"]),
        ("2026-10-02 22:00–2026-10-02 24:00", &["2026-10-02 22:00–00:00+1 - > -"]),
        ("2026-10-02 22:00–2026-10-03 24:00", &["2026-10-02 22:00–00:00+2 - > -"]),
        ("22:00–06:00 abends", &["- 22:00–18:00 - > -"]),
        ("9am–3am in the afternoon", &["- 09:00–03:00 - > - #conflictingPeriod:afternoon"]),
        ("22:00–15:00 morgens", &["- 22:00–15:00 - > - #conflictingPeriod:morgens"]),
        ("9am–3pm in the morning", &["- 09:00–15:00 - > - #conflictingPeriod:morning"]),
    ]);
}

#[test]
fn issue_text_has_no_preposition() {
    check(&[
        ("um 25:61", &["- - - > - #invalidTime:25:61"]),
        ("at 25:61 UTC", &["- - +0 > - #invalidTime:25:61"]),
        ("a las 25:61 UTC", &["- - +0 > - #invalidTime:25:61"]),
        ("25:61 UTC", &["- - +0 > - #invalidTime:25:61"]),
        ("um 23:59 UTC", &["- 23:59 +0 > -"]),
    ]);
    let mentions = run("um 25:61");
    assert_eq!(mentions[0].issues[0].span, [3, 8]);
    for (text, payload) in [
        ("15:00 in the morning", "morning"),
        ("15:00 de la mañana", "mañana"),
        ("by noon at 3pm", "noon"),
        ("Prima di mezzanotte alle 24:00", "mezzanotte"),
        ("Przed północą o 24:00", "północą"),
    ] {
        let mentions = run(text);
        assert_eq!(mentions.len(), 1, "{text}");
        assert_eq!(mentions[0].issues.len(), 1, "{text}");
        let issue = &mentions[0].issues[0];
        assert_eq!(issue.text, payload, "{text}");
        let chars: Vec<char> = text.chars().collect();
        assert_eq!(chars[issue.span[0]..issue.span[1]].iter().collect::<String>(), payload, "{text}");
    }
}
#[test]
fn deadline_idioms_more_languages() {
    check(&[
        ("Bis heute Feierabend muss die Liste fertig sein.", &["+0d ~17:00 - > -"]),
        ("Ich brauche den Bericht bis Freitag, Feierabend.", &["w5 ~17:00 - > -"]),
        ("Manda il modulo prima di mezzanotte.", &["- ~23:59 - > -"]),
        ("Oggi prima di mezzanotte chiudono le iscrizioni.", &["+0d ~23:59 - > -"]),
        ("Gửi báo cáo trước khi tan tầm nhé. Cuộc họp khởi động khoảng 9h sáng mai.", &["- ~17:00 - > -", "+1d 09:00 - > -"]),
        ("Lever het rapport in vóór het einde van de dag.", &["- ~17:00 - > -"]),
        ("Stuur je reactie uiterlijk vrijdag einde van de dag.", &["w5 ~17:00 - > -"]),
        ("Vul de enquête vandaag nog in, vóór het einde van de dag.", &["+0d ~17:00 - > -"]),
        ("De aanmelding loopt tot einde van de dag.", &["- ~17:00 - > -"]),
        ("Zgłoszenia przyjmujemy przed północą.", &["- ~23:59 - > -"]),
        ("Dziś przed północą kończy się przedsprzedaż.", &["+0d ~23:59 - > -"]),
        ("Отчёт нужен к концу рабочего дня в пятницу.", &["w5 ~17:00 - > -"]),
        ("Gửi bản thảo trước cuối ngày nhé.", &["- ~17:00 - > -"]),
        ("Bis Feierabend bitte", &["- ~17:00 - > -"]),
        ("Prima di mezzanotte alle 23:30", &["- 23:30 - > -"]),
        ("Feierabend um 18:00", &["- 18:00 - > -"]),
        ("Einde van de dag om 18:00", &["- 18:00 - > -"]),
        ("Przed północą o 23:30", &["- 23:30 - > -"]),
        ("К концу рабочего дня в 18:00", &["- 18:00 - > -"]),
        ("Trước cuối ngày lúc 18:00", &["- 18:00 - > -"]),
        ("Trước khi tan tầm lúc 18:00", &["- 18:00 - > -"]),
        ("Manda il modulo a mezzanotte.", &["- 00:00+1 - > -"]),
    ]);
    // 固定午夜截止与次日零点相冲突；下班时间是默认值，显式钟点可以替换。
    for text in ["Prima di mezzanotte alle 24:00", "Przed północą o 24:00"] {
        let conflict = run(text);
        assert_eq!(conflict.len(), 1, "{text}");
        assert_eq!(conflict[0].time, Some(Clock { hour: 0, minute: 0, second: 0, day_offset: 1 }), "{text}");
        assert!(conflict[0].issues.iter().any(|issue| issue.kind == "conflictingDeadline"), "{text}");
    }
}
#[test]
fn noon_is_read_once() {
    check(&[
        ("a las 12 del mediodía", &["- 12:00 - > -"]),
        ("öğlen 12'de", &["- 12:00 - > -"]),
        ("at noon", &["- 12:00 - > -"]),
        ("a las 12:30 del mediodía", &["- 12:30 - > -"]),
        ("öğlen", &["- 12:00 - > -"]),
    ]);
}

#[test]
fn half_and_quarter_forms() {
    check(&[
        ("midi et demi", &["- 12:30 - > -"]),
        ("mezzogiorno e mezzo", &["- 12:30 - > -"]),
        ("üç buçukta", &["- 03:30 - > -"]),
        ("dörde çeyrek kala", &["- 03:45 - > -"]),
        ("à midi et quart", &["- 12:15 - > -"]),
        ("midi moins vingt", &["- 11:40 - > -"]),
        ("3時15分前", &["- 02:45 - > -"]),
        ("3時15分", &["- 03:15 - > -"]),
        ("za piętnaście piąta", &["- 04:45 - > -"]),
        ("o piątej", &["- 05:00 - > -"]),
        ("6 giờ kém 15", &["- 05:45 - > -"]),
        ("lúc 6 giờ 15 phút", &["- 06:15 - > -"]),
        ("üç buçuk", &["- 03:30 - > -"]),
        ("saat üçte", &["- 03:00 - > -"]),
    ]);
}

#[test]
fn clock_word_followups() {
    check(&[
        ("am Mittag", &["- 12:00 - > -"]),
        ("am 9:00", &["- 09:00 - > -"]),
        ("The race starts at seven thirty.", &["- 07:30 - > -"]),
        ("at seven", &["- 07:00 - > -"]),
        ("Le train part à 8 heures 40.", &["- 08:40 - > -"]),
        ("alle tre e venti", &["- 03:20 - > -"]),
        ("all'una di notte", &["- 01:00 - > -"]),
        ("L'après-midi est pluvieux.", &[]),
        ("Passe-moi voir dans l'après-midi.", &[]),
        ("深夜0時", &["- 00:00 - > -"]),
        ("真夜中", &["- 00:00+1 - > -"]),
        ("여섯 시 십오 분", &["- 06:15 - > -"]),
        ("9 UTC", &["- 09:00 +0 > -"]),
        ("9 items", &[]),
        ("Khách sạn phục vụ bữa sáng tới 10:30.", &["- 10:30 - > -"]),
        ("tối 10:30", &["- 22:30 - > -"]),
        ("lúc trưa", &["- 12:00 - > -"]),
        ("rond het middaguur", &["- 12:00 - > -"]),
    ]);
}
#[test]
fn clock_period_prefixes_and_inflected_midnight() {
    check(&[
        ("밤 12시에 광고가 바뀝니다.", &["- 00:00 - > -"]),
        ("자정", &["- 00:00+1 - > -"]),
        ("오전 15시", &["- 15:00 - > - #conflictingPeriod:오전"]),
        ("오후\u{200b} 3:00 회의", &["- 15:00 - > -"]),
        ("오전\u{200b} 3:00 회의", &["- 03:00 - > -"]),
        ("오전 10:00 CET 또는 오후 2:00 EDT 중 편한 때로 참석하세요.", &["- 10:00 +60 > -", "- 14:00 -240 > -"]),
        ("Около полуночи вернусь домой.", &["- 00:00+1 - > -"]),
        ("до полуночи", &["- ~23:59 - > -"]),
    ]);
}


/// New texts supplied after independent evaluation; expectations come from the
/// caller and CONVENTIONS, using the shipped city index rather than a fake map.
#[cfg(not(feature = "intents-only"))]
#[test]
fn places_followup_regressions() {
    let opened = crate::city_index::dispatch("city.open", json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |text: &str, strong: bool| city_lookup(Some(handle), text, strong);
    // The retained conflicting request uses an exact indexed alternate name,
    // independently confirmed as tier 2 by single_query_probe at e6d0d23.
    assert!(matches!(city_lookup(Some(handle), "Bandunq", true),
        Some(ZoneRef::City { name, iana, .. }) if name == "Bandung" && iana == "Asia/Jakarta"));
    let mut failures = Vec::new();
    for line in include_str!("../../tests/corpus/places_followup.jsonl").lines()
        .chain(include_str!("../../tests/corpus/places_followup_extra.jsonl").lines()) {
        let case: serde_json::Value = serde_json::from_str(line).unwrap();
        // The requested !Bandunq reading is preserved in the fixture and report.
        // It conflicts with exact alias recognition, so it is not an accepted
        // regression expectation. The ignored corpus probe still reports it.
        if case["conventionConflict"].is_string() { continue; }
        let text = case["text"].as_str().unwrap();
        let got: Vec<_> = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup }).mentions.iter().map(summary).collect();
        let want: Vec<_> = case["expect"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_owned()).collect();
        if got != want { failures.push(format!("{text}\n    want {want:?}\n    got  {got:?}")); }
    }
    crate::city_index::dispatch("city.close", json!({"handle": handle})).unwrap();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// Preserve the non-zone readings while rejecting lowercase words after place cues.
#[cfg(not(feature = "intents-only"))]
#[test]
fn lowercase_words_after_place_prepositions() {
    let opened = crate::city_index::dispatch("city.open", json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |text: &str, strong: bool| city_lookup(Some(handle), text, strong);
    let mut failures = Vec::new();
    for line in include_str!("../../tests/corpus/places_lowercase.jsonl").lines() {
        let case: serde_json::Value = serde_json::from_str(line).unwrap();
        let text = case["text"].as_str().unwrap();
        let got: Vec<_> = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup }).mentions.iter().map(summary).collect();
        let want: Vec<_> = case["expect"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_owned()).collect();
        if got != want { failures.push(format!("{text}\n    want {want:?}\n    got  {got:?}")); }
    }
    crate::city_index::dispatch("city.close", json!({"handle": handle})).unwrap();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn lowercase_place_city_rank_and_exact_lookup() {
    let lookup = |text: &str, strong: bool| {
        let (city_index, name) = match fold_str(text).as_str() {
            "bigville" => (places::BIG_CITY_LIMIT - 1, "Bigville"),
            "la bigville" => (places::BIG_CITY_LIMIT - 1, "La Bigville"),
            "la" => (0, "Los Angeles"),
            "smallville" => (places::BIG_CITY_LIMIT, "Smallville"),
            "restored" if strong => (0, "Restored City"),
            _ => return None,
        };
        Some(ZoneRef::City { city_index, name: name.into(), iana: "Asia/Tokyo".into(), population: None })
    };
    for (text, admitted) in [
        ("Meet in bigville at 18:00.", true),
        ("Meet in smallville at 18:00.", false),
        ("Meet in restored at 18:00.", false),
        ("Meet in Smallville at 18:00.", true),
        ("meet in smallville at 18:00", true),
        ("Das Treffen in smallville beginnt um 18:00.", true),
        ("The hotel in bigville confirms check-in at 18:00.", true),
        ("Meet in la bigville at 18:00.", true),
        ("Meet in la\tbigville headquarters at 18:00.", false),
        ("Nos vemos a las 18:00 en la plaza.", false),
    ] {
        let out = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup });
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(out.mentions[0].source.is_some(), admitted, "{text}: {out:?}");
        assert!(out.mentions[0].unresolved.is_empty(), "{text}: {out:?}");
    }
}

#[cfg(not(feature = "intents-only"))]
#[test]
fn lowercase_place_written_diacritics_keep_exact_city_spelling() {
    fn primary_zone(zone: &ZoneRef) -> &ZoneRef {
        match zone {
            ZoneRef::Options { options, .. } => options.first().map(primary_zone).unwrap_or(zone),
            city => city,
        }
    }
    let opened = crate::city_index::dispatch("city.open", json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |text: &str, strong: bool| city_lookup(Some(handle), text, strong);
    for (text, want) in [
        ("Wstęp na salę o godz. 9:30.", None),
        ("Za pół godziny wchodzimy na salę.", None),
        ("Meet in salé at 18:00.", Some("Africa/Casablanca")),
        ("Meet in parís at 18:00.", Some("Europe/Paris")),
        ("Meet in münchen at 18:00.", Some("Europe/Berlin")),
        ("new york'da Toplantı 18:00.", Some("America/New_York")),
        ("meet in salę at 18:00", Some("Africa/Casablanca")),
        ("Das Treffen in salę beginnt um 18:00.", Some("Africa/Casablanca")),
    ] {
        let out = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup });
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        let got = out.mentions[0].source.as_ref().map(primary_zone);
        assert_eq!(got.map(|zone| match zone { ZoneRef::City { iana, .. } => iana.as_str(), _ => "not a city" }), want, "{text}: {out:?}");
    }
    let out = understand("salę'dayım. Toplantı 18:00.", &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert!(out.writer.is_some(), "the all-lowercase writer sentence keeps its old rule: {out:?}");
    let out = understand("salę'dayım Bugün toplantı 18:00.", &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert!(out.writer.is_none(), "mixed-case writer must retain written city spelling: {out:?}");
    let out = understand("Londra'da 09:00 iken Tokyo'da saat kaç?", &Options { region: "US", ui_language: "en", lookup: &lookup });
    assert_eq!(out.mentions.iter().map(summary).collect::<Vec<_>>(), ["- 09:00 Europe/London > Asia/Tokyo"]);
    places::with_exact_city_spelling(|| {
        assert!(places::with_exact_city_spelling(|| lookup("salę", false)).is_none());
        assert!(lookup("salę", false).is_none());
    });
    assert!(lookup("salę", false).is_some());
    let panic = std::panic::catch_unwind(|| places::with_exact_city_spelling(|| panic!("test spelling-policy restoration")));
    assert!(panic.is_err());
    assert!(lookup("salę", false).is_some());
    crate::city_index::dispatch("city.close", json!({"handle": handle})).unwrap();
}

#[test]
fn dotted_dates_before_clocks_followup() {
    check(&[
        ("Встреча 15.10 в 10:00.", &["10-15 10:00 - > -"]),
        ("Ревизия 22.11 в 8:00.", &["11-22 08:00 - > -"]),
        ("Встреча в 15.10.", &["- 15:10 - > -"]),
        ("Rapat 15.10 pukul 10.05.", &["10-15 10:05 - > -"]),
    ]);
}

#[test]
fn slash_fraction_measures_followup() {
    check(&[
        ("Add 3/4 cup of flour.", &[]),
        ("Tambahkan 2/3 sendok teh garam.", &[]),
        ("Misture 1/3 de xícara de açúcar.", &[]),
        ("放 1/4 杯糖。", &[]),
        ("再加 3/4 茶匙鹽。", &[]),
        ("Delivery on 3/4 at 10:00.", &["03-04 10:00 - > - ?1"]),
    ]);
}

#[test]
fn dotted_dates_before_clocks_allow_soft_separators_followup() {
    check(&[
        ("Встреча 15.10\nв 10:00.", &["10-15 10:00 - > -"]),
        ("Встреча 15.10, в 10:00.", &["10-15 10:00 - > -"]),
        ("Встреча (15.10) в 10:00.", &["10-15 10:00 - > -"]),
    ]);
}

#[test]
fn bare_dotted_pair_without_following_clock_keeps_its_alternative_followup() {
    let out = understand("Rapat besok 10.05", &Options { region: "ID", ui_language: "id", lookup: &|_, _| None });
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert_eq!(out.mentions[0].time, Some(Clock::at(10, 5)), "{out:?}");
    assert_eq!(out.mentions[0].alternatives, [types::Alternative::DotDate { date: DateSpec::MonthDay { month: 5, day: 10 } }], "{out:?}");
}

#[test]
fn dotted_dates_before_clocks_across_prose_followup() {
    check(&[
        ("Встреча 15.10 начинается в 10:00.", &["10-15 10:00 - > -"]),
        ("Meeting 15.10 starts at 10:00.", &["10-15 10:00 - > -"]),
        ("会议15.10开始于10点。", &["10-15 10:00 - > -"]),
        ("會議15.10開始於10點。", &["10-15 10:00 - > -"]),
    ]);
}

#[test]
fn real9_next_day_ranges() {
    check(&[
        ("保安值班 22点到次日6点。", &["- 22:00–06:00+1 - > -"]),
        ("值班從 20:15 到隔天 04:30。", &["- 20:15–04:30+1 - > -"]),
        ("巡逻 21:40 到隔天 02:10 UTC。", &["- 21:40–02:10+1 +0 > -"]),
    ]);
}

#[test]
fn real9_yesterday_evening() {
    check(&[
        ("昨晚九点取了快递。", &["-1d 21:00 - > -"]),
        ("昨夜十一點收到回覆。", &["-1d 23:00 - > -"]),
    ]);
}

#[test]
fn real9_relative_start_without_clock() {
    check(&[
        ("自即日起至 2024年4月30日下午6:00止接受报名。", &["2024-04-30 18:00 - > -"]),
        ("即日起至 2024年4月30日下午6:00止接受報名。", &["2024-04-30 18:00 - > -"]),
    ]);
}

#[test]
fn real9_workday_idioms() {
    check(&[
        ("Kirim berkas sebelum pulang kerja.", &["- ~17:00 - > -"]),
        ("Kirim berkas besok sebelum pulang kerja.", &["+1d ~17:00 - > -"]),
        ("Kirim berkas Jumat sebelum pulang kerja.", &["w5 ~17:00 - > -"]),
        ("O relatório chega no fim do expediente.", &["- ~17:00 - > -"]),
        ("O relatório chega amanhã no fim do expediente.", &["+1d ~17:00 - > -"]),
        ("O relatório chega sexta-feira no fim do expediente.", &["w5 ~17:00 - > -"]),
    ]);
}

#[test]
fn real9_indonesian_weekday_abbreviations() {
    check(&[
        ("Sen 18.00 WIB rapat dimulai.", &["w1 18:00 +420 > -"]),
        ("Sel 18.00 WIB rapat dimulai.", &["w2 18:00 +420 > -"]),
        ("Rab 18.00 WIB rapat dimulai.", &["w3 18:00 +420 > -"]),
        ("Kam 18.00 WIB rapat dimulai.", &["w4 18:00 +420 > -"]),
        ("Jum 18.00 WIB rapat dimulai.", &["w5 18:00 +420 > -"]),
        ("Sab 18.00 WIB rapat dimulai.", &["w6 18:00 +420 > -"]),
        ("Min 18.00 WIB rapat dimulai.", &["w7 18:00 +420 > -"]),
    ]);
}

#[test]
fn real9_indonesian_clocks_and_zones() {
    check(&[
        ("18.00 WIB → Tokyo", &["- 18:00 +420 > Asia/Tokyo"]),
        ("19.00 CET atau 13.00 EDT", &["- 19:00 +60 > -", "- 13:00 -240 > -"]),
        ("11.00 jakarta time", &["- 11:00 Asia/Jakarta > -"]),
        ("JAM 8AM, 1PM, DAN 21.00", &["- 08:00 - > -", "- 13:00 - > -", "- 21:00 - > -"]),
        ("Warung buka 07.00 hingga 20.00.", &["- 07:00–20:00 - > -"]),
        ("Warung buka 07.00 sampai 20.00.", &["- 07:00–20:00 - > -"]),
        ("Rapat pukul 13.15 Waktu Indonesia Barat.", &["- 13:15 Asia/Jakarta > -"]),
        ("Rapat pukul 13.15 Waktu Indonesia Tengah.", &["- 13:15 Asia/Makassar > -"]),
        ("Rapat pukul 13.15 Waktu Indonesia Timur.", &["- 13:15 Asia/Jayapura > -"]),
    ]);
}


#[test]
fn real9_chinese_clock_forms_and_count_boundaries() {
    check(&[
        ("每天差十分四点开门", &["- 03:50 - > -"]),
        ("班车差一刻五点发车", &["- 04:45 - > -"]),
        ("提醒差五分钟八点出发", &["- 07:55 - > -"]),
        ("跳操七点过十分开始", &["- 07:10 - > -"]),
        ("签到六点过一刻截止", &["- 06:15 - > -"]),
        ("讲解下午两点过五分开始", &["- 14:05 - > -"]),
        ("系统零点重启", &["- 00:00 - > -"]),
        ("餐车中午左右出现", &["- 12:00 - > -"]),
        ("请在中午前送到", &["- ~12:00 - > -"]),
        ("这三点意见请记下", &[]),
        ("这三点建议请记下", &[]),
        ("我们三点见", &["- 03:00 - > -"]),
        ("每天差十分四點開門", &["- 03:50 - > -"]),
        ("班車差一刻五點發車", &["- 04:45 - > -"]),
        ("提醒差五分鐘八點出發", &["- 07:55 - > -"]),
        ("跳操七點過十分開始", &["- 07:10 - > -"]),
        ("簽到六點過一刻截止", &["- 06:15 - > -"]),
        ("講解下午兩點過五分開始", &["- 14:05 - > -"]),
        ("系統零點重啟", &["- 00:00 - > -"]),
        ("餐車中午左右出現", &["- 12:00 - > -"]),
        ("請在中午前送到", &["- ~12:00 - > -"]),
        ("這三點意見請記下", &[]),
        ("這三點建議請記下", &[]),
        ("我們三點見", &["- 03:00 - > -"]),
    ]);
}

#[test]
fn real9_portuguese_quarter_clocks() {
    check(&[
        ("O ensaio é às oito e quarto", &["- 08:15 - > -"]),
        ("A sessão abre às duas e quarto da tarde", &["- 14:15 - > -"]),
    ]);
}

#[test]
fn real9_japanese_written_zero_is_same_day() {
    check(&[
        ("更新は零時に始まります", &["- 00:00 - > -"]),
        ("更新は0時に始まります", &["- 00:00 - > -"]),
        ("更新は真夜中に始まります", &["- 00:00+1 - > -"]),
    ]);
}


#[test]
fn u9_chinese_numeral_relative_quantities() {
    check(&[("过四十五分钟后通知我", &["- +45m - > -"])]);
    check(&[("两小时十五分钟后再检查", &["- +135m - > -"])]);
    check(&[("三十五分鐘後再聯絡", &["- +35m - > -"])]);
    check(&[("四十五分後に集合します", &["- +45m - > -"])]);
    check(&[("二時間十五分後に確認します", &["- +135m - > -"])]);
}

#[test]
fn u9_chinese_local_version_blockers() {
    check(&[("固件版本号 7.4", &[])]);
    check(&[("套件版本號 6.2", &[])]);
    check(&[("这是版本 6.2 的说明", &[])]);
    check(&[("目前版本 7.4 已安裝", &[])]);
    check(&[("软件版本号 7.4，说明会在 16:20", &["- 16:20 - > -"])]);
    check(&[("套件版本號 6.2，說明會在 16:20", &["- 16:20 - > -"])]);
}

#[test]
fn u9_trailing_durations_in_every_language() {
    check(&[("音乐会 18:20，进行两个小时", &["- 18:20 d120 - > -"])]);
    check(&[("音樂會 18:20，進行兩個小時", &["- 18:20 d120 - > -"])]);
    check(&[("课程在 13:20 开始，持续三十五分钟", &["- 13:20 d35 - > -"])]);
    check(&[("課程在 13:20 開始，持續三十五分鐘", &["- 13:20 d35 - > -"])]);
    check(&[("Workshop at 13:20, lasting 45 minutes", &["- 13:20 d45 - > -"])]);
    check(&[("講習は13:20開始、所要時間四十五分です", &["- 13:20 d45 - > -"])]);
    check(&[("강의는 13:20 시작, 45분 동안 진행합니다", &["- 13:20 d45 - > -"])]);
    check(&[("Workshop um 13:20, dauert 45 Minuten", &["- 13:20 d45 - > -"])]);
    check(&[("Atelier à 13:20, durée 45 minutes", &["- 13:20 d45 - > -"])]);
    check(&[("Taller a las 13:20, dura 45 minutos", &["- 13:20 d45 - > -"])]);
    check(&[("Oficina às 13:20, com duração de 45 minutos", &["- 13:20 d45 - > -"])]);
    check(&[("Laboratorio alle 13:20, durata 45 minuti", &["- 13:20 d45 - > -"])]);
    check(&[("Workshop om 13:20, duurt 45 minuten", &["- 13:20 d45 - > -"])]);
    check(&[("Warsztat o 13:20, trwa 45 minut", &["- 13:20 d45 - > -"])]);
    check(&[("Занятие в 13:20, длится 45 минут", &["- 13:20 d45 - > -"])]);
    check(&[("Ders saat 13:20, 45 dakika sürecek", &["- 13:20 d45 - > -"])]);
    check(&[("Lớp lúc 13:20, kéo dài 45 phút", &["- 13:20 d45 - > -"])]);
    check(&[("Pelatihan jam 13.20 WIB, durasi 45 menit", &["- 13:20 d45 +420 > -"])]);
    check(&[("进行两个小时的准备工作", &[])]);
    check(&[("Durasi 45 menit", &[])]);
    check(&[("Com duração de 45 minutos", &[])]);
}

#[test]
fn u9_unit_quantities_are_not_dates() {
    check(&[("O ar está a 8 graus", &[])]);
    check(&[("A equipe chegou com 35 minutos de atraso", &[])]);
    check(&[("Suhu naik 6 derajat", &[])]);
    check(&[("Vídeo às 8:10", &["- 08:10 - > -"])]);
    check(&[("Latihan pukul 06.20 WIB", &["- 06:20 +420 > -"])]);
}



#[test]
#[cfg(not(feature = "intents-only"))]
fn real9_places_targets_and_attached_local() {
    let opened = crate::city_index::dispatch("city.open", json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |text: &str, strong: bool| city_lookup(Some(handle), text, strong);
    let cases: &[(&str, &[&str])] = &[
        ("周三四点在大阪游览", &["w3 04:00 Asia/Tokyo > -"]),
        ("明早八點在首爾聚餐", &["+1d 08:00 Asia/Seoul > -"]),
        ("九点在悉尼汇合", &["- 09:00 Australia/Sydney > -"]),
        ("现在先吃饭，九点出发", &["- 09:00 - > -"]),
        ("正在開會，九點散場", &["- 09:00 - > -"]),
        ("客服在线到九点", &["- 09:00 - > -"]),
        ("九点在家休息", &["- 09:00 - > -"]),
        ("九點在門口等", &["- 09:00 - > -"]),
        ("九点放在办公室", &["- 09:00 - > -"]),
        ("九点在火星基地等", &["- 09:00 - > -"]),
        ("东京十点，对应纽约几点？", &["- 10:00 Asia/Tokyo > America/New_York"]),
        ("東京十點，相當於紐約幾點？", &["- 10:00 Asia/Tokyo > America/New_York"]),
        ("东京十点，纽约那边是几点？", &["- 10:00 Asia/Tokyo > America/New_York"]),
        ("東京十點，紐約那邊是幾點？", &["- 10:00 Asia/Tokyo > America/New_York"]),
        ("东京十点，纽约那边几点？", &["- 10:00 Asia/Tokyo > America/New_York"]),
        ("東京十點，紐約那邊幾點？", &["- 10:00 Asia/Tokyo > America/New_York"]),
        ("新加坡全国九点启程", &["- 09:00 Asia/Singapore > -"]),
        ("新加坡全國九點啟程", &["- 09:00 Asia/Singapore > -"]),
        ("Rapat 09.00 WIB, jam berapa di sini?", &["- 09:00 +420 > local"]),
        ("Saya duduk di sini, rapat pukul 09.00", &["- 09:00 - > -"]),
        ("Pertemuan pukul 08.00 di Moskow", &["- 08:00 Europe/Moscow > -"]),
        ("O mercado da praça abre às 7:15", &["- 07:15 - > -"]),
        ("O passeio começa às 8:15 em Xangai", &["- 08:15 Asia/Shanghai > -"]),
        ("A coleta é às 8:00 aqui", &["- 08:00 local > -"]),
        ("O entregador ficou aqui; coleta às 8:00", &["- 08:00 - > -"]),
        ("O entregador passou aqui e voltou às 8:00", &["- 08:00 - > -"]),
        ("シンガポール全国で10時に開店", &["- 10:00 Asia/Singapore > -"]),
        ("15時に家で休む", &["- 15:00 - > -"]),
        ("七点在門口集合", &["- 07:00 - > -"]),
        ("七點在樓下等", &["- 07:00 - > -"]),
        ("七点在家等", &["- 07:00 - > -"]),
        ("客服在線，八點回覆", &["- 08:00 - > -"]),
        ("現在先吃飯，八點出發", &["- 08:00 - > -"]),
        ("正在工作，八點回家", &["- 08:00 - > -"]),
        ("東京十點，對應紐約幾點？", &["- 10:00 Asia/Tokyo > America/New_York"]),
        ("东京十点，相当于纽约几点？", &["- 10:00 Asia/Tokyo > America/New_York"]),
        ("新加坡全国统一九点启程", &["- 09:00 Asia/Singapore > -"]),
        ("新加坡全國統一九點啟程", &["- 09:00 Asia/Singapore > -"]),
        ("九点在 办公室 等我", &["- 09:00 - > -"]),
        ("九點在 家 等我", &["- 09:00 - > -"]),
        ("在三河八点集合", &["- 08:00 Asia/Shanghai > -"]),
        ("在三河八點集合", &["- 08:00 Asia/Shanghai > -"]),
        ("四日市で八時に会う", &["- 08:00 Asia/Tokyo > -"]),
    ];
    let mut failures = Vec::new();
    for &(text, want) in cases {
        let got: Vec<_> = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup }).mentions.iter().map(summary).collect();
        if got != want { failures.push(format!("{text}\n    want {want:?}\n    got {got:?}")); }
    }
    crate::city_index::dispatch("city.close", json!({"handle": handle})).unwrap();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}


#[test]
#[cfg(not(feature = "intents-only"))]
fn real9_portuguese_fair_is_common_noun_but_full_city_survives() {
    let opened = crate::city_index::dispatch("city.open", json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |text: &str, strong: bool| city_lookup(Some(handle), text, strong);
    for (text, want) in [
        ("A feira da praça abre às 7:15", "- 07:15 - > -"),
        ("Feira começa às 7:15", "- 07:15 - > -"),
        ("O trem chega às 8:00 em Feira de Santana", "- 08:00 America/Bahia > -"),
        ("Às 8:15 em Xangai", "- 08:15 Asia/Shanghai > -"),
    ] {
        let got: Vec<_> = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup }).mentions.iter().map(summary).collect();
        assert_eq!(got, [want], "{text}");
    }
    crate::city_index::dispatch("city.close", json!({"handle": handle})).unwrap();
}

#[test]
fn real9_relative_range_start_with_clock_keeps_its_day() {
    check(&[
        ("08:30 今天至 2024年4月30日18:00", &["+0d 08:30 - > -", "2024-04-30 18:00 - > -"]),
        ("08:30 今日至 2024年4月30日18:00", &["+0d 08:30 - > -", "2024-04-30 18:00 - > -"]),
    ]);
}

#[test]
fn real9_independent_place_cue_and_dotted_date_priority() {
    check(&[
        ("其实在大阪八点集合", &["- 08:00 Asia/Tokyo > -"]),
        ("確實在東京八點集合", &["- 08:00 Asia/Tokyo > -"]),
        ("出现在大阪八点的新闻里", &["- 08:00 Asia/Tokyo > -"]),
        ("出現在東京八點的新聞裡", &["- 08:00 Asia/Tokyo > -"]),
        ("在大阪十三点集合", &["- 13:00 Asia/Tokyo > -"]),
        ("在大阪二十三點集合", &["- 23:00 Asia/Tokyo > -"]),
        ("東京で十三時に集合", &["- 13:00 Asia/Tokyo > -"]),
        ("這二十三點意見請留著", &[]),
        ("Sen 03.10 pukul 15.00 WIB", &["10-03 15:00 +420 > -"]),
    ]);
}


#[test]
#[cfg(not(feature = "intents-only"))]
fn here_copulas_attach_only_to_clocks() {
    let opened = crate::city_index::dispatch("city.open", json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |text: &str, strong: bool| city_lookup(Some(handle), text, strong);
    let cases: &[(&str, &[&str])] = &[
        ("Se aqui são 9:00, que horas são em Tóquio?", &["- 09:00 local > Asia/Tokyo"]),
        ("aqui é meio-dia", &["- 12:00 local > -"]),
        ("hier ist es 9 Uhr", &["- 09:00 local > -"]),
        ("ici il est 9h", &["- 09:00 local > -"]),
        ("aquí son las 9", &["- 09:00 local > -"]),
        ("here it is 9:00", &["- 09:00 local > -"]),
        ("hier is het 9:00", &["- 09:00 local > -"]),
        ("Ở đây là 9:00", &["- 09:00 local > -"]),
        ("Di sini adalah pukul 9:00", &["- 09:00 local > -"]),
        ("我这边是九点", &["- 09:00 local > -"]),
        ("我這邊是九點", &["- 09:00 local > -"]),
        ("8:00 aqui e 9:00 em Tóquio", &["- 08:00 local > -", "- 09:00 Asia/Tokyo > -"]),
        ("Aqui são 9:00; aqui são 10:00", &["- 09:00 local > -", "- 10:00 local > -"]),
        ("Há 15 minutos a entrega chegou aqui.", &["- -15m - > -"]),
        ("Há 15 minutos aqui.", &["- -15m - > -"]),
        ("15 minutes ago here.", &["- -15m - > -"]),
        ("15 minuten geleden hier.", &["- -15m - > -"]),
        ("15 phút trước ở đây.", &["- -15m - > -"]),
        ("O entregador passou aqui e voltou às 8:00", &["- 08:00 - > -"]),
        ("Aqui chegou a entrega às 9:00", &["- 09:00 - > -"]),
        ("The courier stopped here and returned at 8:00", &["- 08:00 - > -"]),
        ("Hier il était 9h.", &["-1d 09:00 - > -"]),
    ];
    let mut failures = Vec::new();
    for &(text, want) in cases {
        let got: Vec<_> = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup }).mentions.iter().map(summary).collect();
        if got != want { failures.push(format!("{text}\n    want {want:?}\n    got {got:?}")); }
    }
    crate::city_index::dispatch("city.close", json!({"handle": handle})).unwrap();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn word_and_numeric_clock_restatements_are_one_mention() {
    check(&[
        ("零点切换：00:00 UTC。", &["- 00:00 +0 > -"]),
        ("零點切換：00:00 UTC。", &["- 00:00 +0 > -"]),
        ("正午：12:00 JST", &["- 12:00 +540 > -"]),
        ("midnight (00:00 UTC)", &["- 00:00 +0 > -"]),
        ("noon (12:00 UTC)", &["- 12:00 +0 > -"]),
        ("零点和 00:30 各发一次", &["- 00:00 - > -", "- 00:30 - > -"]),
        ("零点和 00:00 各发一次", &["- 00:00 - > -", "- 00:00 - > -"]),
        ("midnight and 00:00 UTC", &["- 00:00+1 - > -", "- 00:00 +0 > -"]),
        ("midnight (00:30 UTC)", &["- 00:00+1 - > -", "- 00:30 +0 > -"]),
        ("midnight (00:00:30 UTC)", &["- 00:00+1 - > -", "- 00:00:30 +0 > -"]),
        ("00:00 (00:00 UTC)", &["- 00:00 - > -", "- 00:00 +0 > -"]),
        ("noon. 12:00 UTC.", &["- 12:00 - > -", "- 12:00 +0 > -"]),
        ("noon (12:00am UTC)", &["- 12:00 - > -", "- 00:00 +0 > -"]),
        ("UTC noon (12:00 JST)", &["- 12:00 +0 > -", "- 12:00 +540 > -"]),
        ("UTC noon (12:00 UTC)", &["- 12:00 +0 > -"]),
        ("midnight", &["- 00:00+1 - > -"]),
    ]);
}

/// 地名与钟点之间的完整民用日期仍属于同一个来源。
#[cfg(not(feature = "intents-only"))]
#[test]
fn alarm_city_before_iso_date_keeps_its_clock_source() {
    let opened = crate::city_index::dispatch("city.open", json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |text: &str, strong: bool| city_lookup(Some(handle), text, strong);
    let mut failures = Vec::new();
    for (text, language) in [
        ("Los Angeles 2030-11-03 1:30", "en"),
        ("2030-11-03 1:30 Los Angeles", "en"),
        ("Los Angeles 1:30 on 2030-11-03", "en"),
        ("洛杉矶 2030-11-03 1:30", "zh-Hans"),
        ("Лос-Анджелес 2030-11-03 1:30", "ru"),
        ("Los Angeles 2030-11-03 1:30", "de"),
        ("ロサンゼルス 2030-11-03 1:30", "ja"),
    ] {
        let output = understand(text, &Options { region: "US", ui_language: language, lookup: &lookup });
        println!("{language} {text}: {}", serde_json::to_string(&output).unwrap());
        println!("structured {text}: {}", serde_json::to_string(&output).unwrap());
        let clocks: Vec<_> = output.mentions.iter().filter(|mention| mention.time.is_some()).collect();
        if output.mentions.len() != 1 || clocks.len() != 1
            || date_text(&clocks[0].date) != "2030-11-03"
            || !clocks[0].time.as_ref().is_some_and(|clock| clock.hour == 1 && clock.minute == 30)
            || zone_id(&clocks[0].source) != "America/Los_Angeles" {
            failures.push(format!("{language} {text}: {:?}", output.mentions.iter().map(summary).collect::<Vec<_>>()));
        }
    }
    for text in [
        "Flight to Los Angeles 2030-11-03 1:30",
        "Call with Los Angeles 2030-11-03 1:30",
    ] {
        let output = understand(text, &Options { region: "US", ui_language: "en", lookup: &lookup });
        println!("structured {text}: {}", serde_json::to_string(&output).unwrap());
        let clocks: Vec<_> = output.mentions.iter().filter(|mention| mention.time.is_some()).collect();
        if output.mentions.len() != 1 || clocks.len() != 1
            || date_text(&clocks[0].date) != "2030-11-03"
            || !clocks[0].time.as_ref().is_some_and(|clock| clock.hour == 1 && clock.minute == 30)
            || clocks[0].source.is_some() {
            failures.push(format!("非来源地点被附着：{text}: {:?}", output.mentions.iter().map(summary).collect::<Vec<_>>()));
        }
    }
    crate::city_index::dispatch("city.close", json!({"handle": handle})).unwrap();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// 越南语写明年份时不能丢年：逗号、ngày 前缀都一样（2030-11-03 洛杉矶 1:30 正落在夏令时回拨上）。
#[test]
fn vietnamese_calendar_year_suffix_keeps_explicit_year() {
    for text in [
        "Los Angeles ngày 3 tháng 11, 2030 1:30",
        "Los Angeles ngày 3 tháng 11 2030 1:30",
        "Los Angeles Ngày 3 tháng 11, 2030 1:30",
        "Los Angeles 3 tháng 11, 2030 1:30",
        "Los Angeles 3 tháng 11 2030 1:30",
        "Los Angeles ngày 3 tháng 11 năm 2030 1:30",
        "Los Angeles ngày 3 tháng 11, năm 2030 1:30",
    ] {
        let mentions = run(text);
        let [m] = &mentions[..] else { panic!("{text:?} 读出 {} 处", mentions.len()) };
        assert_eq!(m.date, Some(DateSpec::Absolute { year: 2030, month: 11, day: 3 }), "{text}");
        assert_eq!(zone_id(&m.source), "America/Los_Angeles", "{text}");
        assert_eq!(m.time, Some(Clock { hour: 1, minute: 30, second: 0, day_offset: 0 }), "{text}");
    }
}

/// 不写年份时仍是月日；后面没有四位数年份时，逗号也不能吞掉钟点。
#[test]
fn vietnamese_calendar_without_year_keeps_month_day() {
    for text in [
        "Los Angeles ngày 3 tháng 11 1:30",
        "Los Angeles ngày 3 tháng 11, 1:30",
        "Los Angeles 3 tháng 11 1:30",
        "Los Angeles 3 tháng 11, 1:30",
    ] {
        let mentions = run(text);
        let [m] = &mentions[..] else { panic!("{text:?} 读出 {} 处", mentions.len()) };
        assert_eq!(m.date, Some(DateSpec::MonthDay { month: 11, day: 3 }), "{text}");
        assert_eq!(zone_id(&m.source), "America/Los_Angeles", "{text}");
        assert_eq!(m.time, Some(Clock { hour: 1, minute: 30, second: 0, day_offset: 0 }), "{text}");
    }
}
