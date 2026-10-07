// SPDX-License-Identifier: GPL-3.0-only
//! 显式生成公开词表；普通测试只读审计，不写文件。
use super::lexicon::{Period, Sem};
use std::fmt::Write as _;
use std::fs::OpenOptions;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;

pub(super) fn string_source(text: &str) -> String {
    let mut result = String::from("\"");
    for c in text.chars() {
        match c {
            '"' => result.push_str("\\\""),
            '\\' => result.push_str("\\\\"),
            '\n' => result.push_str("\\n"),
            '\r' => result.push_str("\\r"),
            '\t' => result.push_str("\\t"),
            c if c.is_control() || matches!(c, '\u{2028}' | '\u{2029}' | '\u{feff}') => {
                write!(result, "\\u{{{:x}}}", c as u32).unwrap();
            }
            c => result.push(c),
        }
    }
    result.push('"');
    result
}

fn period_source(period: Period) -> &'static str {
    match period {
        Period::Am => "Period::Am", Period::Pm => "Period::Pm",
        Period::Morning => "Period::Morning", Period::Midday => "Period::Midday",
        Period::Afternoon => "Period::Afternoon", Period::Evening => "Period::Evening",
        Period::Night => "Period::Night", Period::SmallHours => "Period::SmallHours",
    }
}

pub(super) fn sem_source(sem: Sem) -> String {
    // 每个变体显式列出，新增含义时必须更新生成器。
    match sem {
        Sem::Month(a0) => format!("Sem::Month({a0})"),
        Sem::Weekday(a0) => format!("Sem::Weekday({a0})"),
        Sem::WeekdayAbbr(a0) => format!("Sem::WeekdayAbbr({a0})"),
        Sem::RelDay(a0) => format!("Sem::RelDay({a0})"),
        Sem::RelDayPeriod(a0, a1) => format!("Sem::RelDayPeriod({a0},{})", period_source(a1)),
        Sem::NextDay => "Sem::NextDay".to_owned(),
        Sem::NextDayPeriod(a0) => format!("Sem::NextDayPeriod({})", period_source(a0)),
        Sem::RelDayEnd(a0) => format!("Sem::RelDayEnd({a0})"),
        Sem::NextWeek => "Sem::NextWeek".to_owned(),
        Sem::ThisWeek => "Sem::ThisWeek".to_owned(),
        Sem::LastWeek => "Sem::LastWeek".to_owned(),
        Sem::NextAfter => "Sem::NextAfter".to_owned(),
        Sem::Period(a0) => format!("Sem::Period({})", period_source(a0)),
        Sem::Noon => "Sem::Noon".to_owned(),
        Sem::Midnight => "Sem::Midnight".to_owned(),
        Sem::ClockBefore => "Sem::ClockBefore".to_owned(),
        Sem::ClockContextBefore => "Sem::ClockContextBefore".to_owned(),
        Sem::ClockHourBefore => "Sem::ClockHourBefore".to_owned(),
        Sem::ClockContextAfter => "Sem::ClockContextAfter".to_owned(),
        Sem::ClockAfter => "Sem::ClockAfter".to_owned(),
        Sem::MinuteAfter => "Sem::MinuteAfter".to_owned(),
        Sem::HalfAfter => "Sem::HalfAfter".to_owned(),
        Sem::HalfBefore => "Sem::HalfBefore".to_owned(),
        Sem::DayMark => "Sem::DayMark".to_owned(),
        Sem::MonthMark => "Sem::MonthMark".to_owned(),
        Sem::MonthBefore => "Sem::MonthBefore".to_owned(),
        Sem::DayBefore => "Sem::DayBefore".to_owned(),
        Sem::YearMark => "Sem::YearMark".to_owned(),
        Sem::RelIn => "Sem::RelIn".to_owned(),
        Sem::RelLater => "Sem::RelLater".to_owned(),
        Sem::RelAgo => "Sem::RelAgo".to_owned(),
        Sem::RelAgoBefore => "Sem::RelAgoBefore".to_owned(),
        Sem::HourUnit => "Sem::HourUnit".to_owned(),
        Sem::MinuteUnit => "Sem::MinuteUnit".to_owned(),
        Sem::HalfHour => "Sem::HalfHour".to_owned(),
        Sem::OneHour => "Sem::OneHour".to_owned(),
        Sem::OneMinute => "Sem::OneMinute".to_owned(),
        Sem::FixedMinutes(a0) => format!("Sem::FixedMinutes({a0})"),
        Sem::DayUnit => "Sem::DayUnit".to_owned(),
        Sem::HourAndHalfUnit => "Sem::HourAndHalfUnit".to_owned(),
        Sem::RangeSep => "Sem::RangeSep".to_owned(),
        Sem::From => "Sem::From".to_owned(),
        Sem::Between => "Sem::Between".to_owned(),
        Sem::And => "Sem::And".to_owned(),
        Sem::ZoneBefore => "Sem::ZoneBefore".to_owned(),
        Sem::ZoneAfter => "Sem::ZoneAfter".to_owned(),
        Sem::PlaceIn => "Sem::PlaceIn".to_owned(),
        Sem::PlaceInArticle => "Sem::PlaceInArticle".to_owned(),
        Sem::TargetAsk => "Sem::TargetAsk".to_owned(),
        Sem::TargetTo => "Sem::TargetTo".to_owned(),
        Sem::Number(a0) => format!("Sem::Number({a0})"),
        Sem::CommonNoun => "Sem::CommonNoun".to_owned(),
        Sem::Stop => "Sem::Stop".to_owned(),
        Sem::Filler => "Sem::Filler".to_owned(),
        Sem::DurationBefore => "Sem::DurationBefore".to_owned(),
        Sem::DurationAfter => "Sem::DurationAfter".to_owned(),
        Sem::Idiom(a0) => format!("Sem::Idiom({})", string_source(a0)),
        Sem::AfterMinutes(a0) => format!("Sem::AfterMinutes({a0})"),
        Sem::BeforeMinutes(a0) => format!("Sem::BeforeMinutes({a0})"),
        Sem::Minus => "Sem::Minus".to_owned(),
        Sem::ClockShift(a0) => format!("Sem::ClockShift({a0})"),
        Sem::Past => "Sem::Past".to_owned(),
        Sem::ToHour => "Sem::ToHour".to_owned(),
        Sem::HourOrdinal(a0) => format!("Sem::HourOrdinal({a0})"),
        Sem::TrAcc(a0) => format!("Sem::TrAcc({a0})"),
        Sem::TrDat(a0) => format!("Sem::TrDat({a0})"),
        Sem::FixedClock(a0, a1) => format!("Sem::FixedClock({a0},{a1})"),
        Sem::LocalZone => "Sem::LocalZone".to_owned(),
        Sem::UnixCue => "Sem::UnixCue".to_owned(),
        Sem::Connector => "Sem::Connector".to_owned(),
        Sem::SelfLocation => "Sem::SelfLocation".to_owned(),
        Sem::NonTimeBefore => "Sem::NonTimeBefore".to_owned(),
        Sem::NonTimeAfter => "Sem::NonTimeAfter".to_owned(),
        Sem::FractionMeasure => "Sem::FractionMeasure".to_owned(),
    }
}

fn data_source() -> String {
    let mut source = String::from("// SPDX-License-Identifier: GPL-3.0-only\n// 由公开词表生成；普通测试核对完整内容。\n");
    source.push_str("use super::language::{EntryGroup, Lookup, LookupNode, Phrase as LanguagePhrase, RawGroups};\n");
    source.push_str("use super::lexicon::{Period, Sem};\nuse super::table_storage::{Slice, StrMap, Text, WordsMap};\n");
    source.push_str("use super::units::{Matcher, Phrase as UnitPhrase};\nuse std::num::NonZeroUsize;\n");
    source.push_str("pub(super) const GENERATED: bool = true;\n");
    source.push_str(&super::language::generated_language_source());
    source.push_str(&super::units::generated_matcher_source());
    source
}

const INPUTS: &[(&str, &[u8])] = &[
    ("Cargo.toml", include_bytes!("../../Cargo.toml")),
    ("Cargo.lock", include_bytes!("../../Cargo.lock")),
    ("src/understand/lexicon.rs", include_bytes!("lexicon.rs")),
    ("src/understand/text.rs", include_bytes!("text.rs")),
    ("src/understand/units.rs", include_bytes!("units.rs")),
    ("src/understand/language.rs", include_bytes!("language.rs")),
    ("src/understand/mod.rs", include_bytes!("mod.rs")),
    ("src/understand/table_storage.rs", include_bytes!("table_storage.rs")),
    ("src/understand/table_generation.rs", include_bytes!("table_generation.rs")),
    ("src/understand/generated_tables_bootstrap.rs", include_bytes!("generated_tables_bootstrap.rs")),
];

fn sha256(path: &Path) -> String {
    let output = Command::new("shasum").args(["-a", "256"]).arg(path).output().expect("run host SHA256 tool");
    assert!(output.status.success(), "SHA256 tool failed");
    let stdout = String::from_utf8(output.stdout).expect("SHA256 output is UTF-8");
    let hash = stdout.split_whitespace().next().expect("SHA256 output contains a hash");
    assert!(hash.len() == 64 && hash.bytes().all(|c| c.is_ascii_hexdigit()), "invalid SHA256 output");
    hash.to_owned()
}

fn write_new(path: &Path, bytes: &[u8]) {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path).expect("create a new output file");
    file.write_all(bytes).expect("write generated output");
    file.sync_all().expect("flush generated output");
}

fn require_table_state(condition: bool, message: &'static str) {
    assert!(condition, "{message}");
}

#[test]
fn compiled_parser_tables_reconstruct_all_public_inputs() {
    require_table_state(!cfg!(feature = "parser-table-generator"), "generation mode cannot pass ordinary table audit");
    require_table_state(super::generated_tables::GENERATED, "generated parser tables are missing");
    super::language::audit_generated_language();
    super::units::audit_generated_matcher();
}

#[test]
#[ignore = "explicit generation into a fresh owned scratch directory"]
fn generate_parser_tables() {
    require_table_state(cfg!(feature = "parser-table-generator"), "generator requires its explicit bootstrap feature");
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let output = PathBuf::from(std::env::var_os("DAYSIDE_TABLE_OUTPUT_DIR").expect("explicit output directory"));
    assert!(output.is_absolute(), "output directory must be absolute");
    assert!(!output.starts_with(root), "generate outside the source checkout");
    std::fs::create_dir(&output).expect("output directory must be fresh");
    let mut inputs = serde_json::Map::new();
    for &(relative, compiled_bytes) in INPUTS {
        let path = root.join(relative);
        assert_eq!(std::fs::read(&path).expect("read public generator input"), compiled_bytes,
            "generator binary is stale for {relative}");
        inputs.insert(relative.to_owned(), serde_json::Value::String(sha256(&path)));
    }
    let rustc = std::env::var_os("RUSTC").unwrap_or_else(|| "rustc".into());
    let version = Command::new(rustc).args(["--version", "--verbose"]).output().expect("read Rust toolchain identity");
    assert!(version.status.success(), "Rust toolchain identity failed");
    let toolchain = String::from_utf8(version.stdout).expect("Rust toolchain identity is UTF-8");
    let source = data_source();
    let source_path = output.join("generated_tables.rs");
    write_new(&source_path, source.as_bytes());
    let manifest = serde_json::json!({
        "generated": true, "schema": 1, "spdx_license": "GPL-3.0-only",
        "inputs_relative_to": "RustCore", "source_sha256": inputs,
        "rustc_version_verbose": toolchain,
        "generated_files": {"generated_tables.rs": sha256(&source_path)},
        "normalization": {"language": "units(fold(phrase))", "matcher": "phrase_units(fold_str(phrase))"}
    });
    let mut bytes = serde_json::to_vec_pretty(&manifest).expect("serialize public provenance");
    bytes.push(b'\n');
    write_new(&output.join("generated_tables.provenance.json"), &bytes);
    println!("generated immutable parser tables and public provenance");
}
