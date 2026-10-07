// SPDX-License-Identifier: GPL-3.0-only
//! Usage: build_city_index <cities.txt> <admin1CodesASCII.txt> <out.ttcity> [alternateNamesV2.txt]
//!        build_city_index --transcode <in-TTCITY07…12.ttcity> <out-TTCITY12.ttcity>
//!        build_city_index --population-report <in.ttcity> <cities500.txt>
//!        build_city_index --add-population <in.ttcity> <cities500.txt> <out.ttcity>
//!        build_city_index --add-languages <in.ttcity> <cities500.txt> <admin1CodesASCII.txt> <out.ttcity> it,nl,pl,tr,vi,id [alternateNamesV2.txt]
//! `--transcode` 同时套上 `rules::SEARCH_KEY_ERRATA`（只补搜索键）；对已带补丁的镜像重跑，输出逐字节相同。
//!        build_city_index --repair-names <in.ttcity> <cities500.txt> <admin1CodesASCII.txt> <out.ttcity> <alternateNamesV2.txt> <改动.tsv>
//! `--repair-names`修旧九语里带限定语、没有 GeoNames 依据的名字，逐条改动写进 TSV（`index_builder::repair_old_names`）。
//!        build_city_index --repair-selected-names <in.ttcity> <cities500.txt> <admin1CodesASCII.txt> <out.ttcity> <alternateNamesV2.txt> <allowlist.tsv>
//! 点名表：kind,index,language,geonameid,primary,before,after,source；八列 TSV，来源为 geonames/geonames-generic/wikidata/primary。
//! `--add-languages`在现有镜像上加语言：名字只来自 `data/*_wikidata.tsv`；记录按名字、坐标、时区、国家与
//! 一份 cities500 逐条对上（不要求是构建原索引的转储；对不上的跳过并报数，超过 1% 不写）。
pub use dayside_core::{fsst, ttcity};
#[cfg(test)]
pub use dayside_core::{mt_core_call, mt_core_free};

#[path = "../index_builder_rules.rs"]
mod index_builder_rules;

#[path = "../index_builder.rs"]
mod index_builder;

fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if (args.len() == 3 && args[0] == "--population-report")
        || (args.len() == 4 && args[0] == "--add-population")
    {
        let input = std::fs::read(&args[1]).unwrap_or_else(|error| {
            eprintln!("读取 {} 失败: {error}", args[1].to_string_lossy());
            std::process::exit(1)
        });
        match index_builder::add_population(&input, args[2].as_ref()) {
            Ok((output, report)) => {
                let matches = report.matches;
                println!("Population matches: {}/{}; unmatched {}; ambiguous {}",
                    matches.matched, matches.records, matches.unmatched, matches.ambiguous);
                println!("Unmatched by country:");
                for (country, count) in report.unmatched_by_country {
                    println!("{country}\t{count}");
                }
                println!("Unmatched records (index, country, name, latitude, longitude, zone):");
                for record in report.unmatched_records {
                    println!("{record}");
                }
                let Some((image, companion)) = output else {
                    eprintln!("Population match rate is below 99%; no output written");
                    std::process::exit(1);
                };
                if args[0] == "--add-population" {
                    let population_path = std::path::Path::new(&args[3]).with_extension("ttpop");
                    for (path, bytes) in [(std::path::Path::new(&args[3]), image.as_slice()),
                                           (population_path.as_path(), companion.as_slice())] {
                        if let Err(error) = std::fs::write(path, bytes) {
                            eprintln!("写入 {} 失败: {error}", path.display());
                            std::process::exit(1);
                        }
                    }
                    println!("Population companion: {} B; index preserved outside [116,128)", companion.len());
                }
                return;
            }
            Err(error) => {
                eprintln!("人口匹配失败: {error}");
                std::process::exit(1);
            }
        }
    }
    if args.len() == 3 && args[0] == "--transcode" {
        // 转换既有镜像并套上搜索键补丁；不重读任何 GeoNames 输入。
        let input = match std::fs::read(&args[1]) {
            Ok(bytes) => bytes,
            Err(error) => {
                eprintln!("读取 {} 失败: {error}", args[1].to_string_lossy());
                std::process::exit(1);
            }
        };
        let companion = std::fs::read(std::path::Path::new(&args[1]).with_extension("ttpop")).ok();
        let valid_population = companion.as_deref()
            .is_some_and(|bytes| index_builder::population_payload(&input, bytes).is_some());
        match index_builder::transcode_primary_names_with_population(
            &input, companion.as_deref(), index_builder_rules::SEARCH_KEY_ERRATA,
        ) {
            Ok((output, population, report)) => {
                if let Err(error) = std::fs::write(&args[2], &output) {
                    eprintln!("写入 {} 失败: {error}", args[2].to_string_lossy());
                    std::process::exit(1);
                }
                if let Some(bytes) = population {
                    let path = std::path::Path::new(&args[2]).with_extension("ttpop");
                    if let Err(error) = std::fs::write(&path, bytes) {
                        eprintln!("写入 {} 失败: {error}", path.to_string_lossy());
                        std::process::exit(1);
                    }
                } else if valid_population {
                    eprintln!("警告：转码改变了城市顺序，未写入人口文件");
                }
                println!(
                    "{} B -> TTCITY12 {} B（相差 {:+} B）",
                    input.len(),
                    output.len(),
                    output.len() as i64 - input.len() as i64
                );
                println!(
                    "搜索键补丁：新键 {}，新倒排 {}，已存在 {}",
                    report.keys_added, report.postings_added, report.already_present
                );
                return;
            }
            Err(error) => {
                eprintln!("转码失败: {error}");
                std::process::exit(1);
            }
        }
    }
    if args.len() == 7 && args[0] == "--repair-selected-names" {
        let result = (|| -> Result<_, Box<dyn std::error::Error>> {
            let input = std::fs::read(&args[1])?;
            let population_path = std::path::Path::new(&args[1]).with_extension("ttpop");
            let companion = match std::fs::read(&population_path) {
                Ok(bytes) => Some(bytes),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                Err(error) => return Err(error.into()),
            };
            let inputs = index_builder::SelectedNameInputs {
                cities: args[2].as_ref(), admins: args[3].as_ref(),
                alternates: args[5].as_ref(), selection: args[6].as_ref(),
            };
            let labels = index_builder::bundled_wikidata_labels()?;
            index_builder::repair_selected_names(&input, companion.as_deref(), &inputs, &labels)
        })();
        match result {
            Ok(repaired) => {
                let result = (|| -> Result<(), std::io::Error> {
                    std::fs::write(&args[4], &repaired.image)?;
                    if let Some(population) = &repaired.population {
                        std::fs::write(std::path::Path::new(&args[4]).with_extension("ttpop"), population)?;
                    }
                    Ok(())
                })();
                if let Err(error) = result {
                    eprintln!("写入点名修正结果失败: {error}");
                    std::process::exit(1);
                }
                println!("kind\tindex\tlanguage\tgeonameid\tbefore\tafter\tsource\tevidence");
                for change in repaired.changes {
                    println!("{change}");
                }
                println!("完整模型核对通过；点名范围之外的逻辑变化为零");
                return;
            }
            Err(error) => {
                eprintln!("点名修正失败: {error}");
                std::process::exit(1);
            }
        }
    }
    if args.len() == 7 && args[0] == "--repair-names" {
        let input = std::fs::read(&args[1]).unwrap_or_else(|error| {
            eprintln!("读取 {} 失败: {error}", args[1].to_string_lossy());
            std::process::exit(1)
        });
        let result = index_builder::bundled_wikidata_labels().and_then(|labels| {
            index_builder::repair_old_names(&input, args[2].as_ref(), args[3].as_ref(), &labels, args[5].as_ref())
        });
        match result {
            Ok((output, matches, reports, changes)) => {
                println!("记录 {}：对上 {}；行政区 {}：对上 {}", matches.records, matches.matched, matches.admins, matches.admins_matched);
                if (matches.unmatched + matches.ambiguous) * 100 > matches.records {
                    eprintln!("对不上的记录超过 1%，不写输出");
                    std::process::exit(1);
                }
                let mut log = String::from("# 语言\t城市|行政区\t记录号\t主名\t旧名\t新名（空 = 拿掉）\t原因\n");
                for line in &changes {
                    log.push_str(line);
                    log.push('\n');
                }
                for (path, bytes) in [(&args[4], output.as_slice()), (&args[6], log.as_bytes())] {
                    if let Err(error) = std::fs::write(path, bytes) {
                        eprintln!("写入 {} 失败: {error}", path.to_string_lossy());
                        std::process::exit(1);
                    }
                }
                for r in reports {
                    println!("{}：去掉限定语 {}，换成别名 {}，拿掉 {}", r.language, r.stripped, r.replaced, r.removed);
                }
                return;
            }
            Err(error) => {
                eprintln!("修旧名失败: {error}");
                std::process::exit(1);
            }
        }
    }
    if (6..=7).contains(&args.len()) && args[0] == "--add-languages" {
        let input = std::fs::read(&args[1]).unwrap_or_else(|error| {
            eprintln!("读取 {} 失败: {error}", args[1].to_string_lossy());
            std::process::exit(1)
        });
        let languages: Vec<String> = args[5].to_string_lossy().split(',').map(|l| l.trim().to_owned()).filter(|l| !l.is_empty()).collect();
        let languages: Vec<&str> = languages.iter().map(String::as_str).collect();
        let result = index_builder::bundled_wikidata_labels().and_then(|labels| {
            index_builder::add_languages(&input, args[2].as_ref(), args[3].as_ref(), &languages, &labels,
                                         args.get(6).map(|path| path.as_ref()))
        });
        match result {
            Ok((output, matches, reports)) => {
                println!(
                    "记录 {}：对上 {}，对不上 {}，有重 {}；行政区 {}：对上 {}",
                    matches.records, matches.matched, matches.unmatched, matches.ambiguous, matches.admins, matches.admins_matched
                );
                // 转储离构建索引那天越久，对不上的越多；超过 1% 多半是拿错了文件（或错了国家 / 时区表），不写。
                if (matches.unmatched + matches.ambiguous) * 100 > matches.records {
                    eprintln!("对不上的记录超过 1%，不写输出");
                    std::process::exit(1);
                }
                if let Err(error) = std::fs::write(&args[4], &output) {
                    eprintln!("写入 {} 失败: {error}", args[4].to_string_lossy());
                    std::process::exit(1);
                }
                println!("{} B -> {} B（{:+} B）", input.len(), output.len(), output.len() as i64 - input.len() as i64);
                for r in reports {
                    println!(
                        "{}：城市名 {}，行政区名 {}，新键 {}，新倒排 {}；没依据的 Wikidata 标签 {}，只多一个通名的 {}，Wikidata 确认写主名的 {}，另起旧名的 {}",
                        r.language, r.cities, r.admins, r.new_keys, r.new_postings, r.unbacked, r.generic, r.confirmed, r.renamed
                    );
                }
                return;
            }
            Err(error) => {
                eprintln!("加语言失败: {error}");
                std::process::exit(1);
            }
        }
    }
    if !(3..=4).contains(&args.len()) {
        eprintln!("用法: build_city_index <cities.txt> <admin1CodesASCII.txt> <out.ttcity> [alternateNamesV2.txt]");
        eprintln!("      build_city_index --transcode <in-TTCITY07…12.ttcity> <out-TTCITY12.ttcity>");
        eprintln!("      build_city_index --repair-selected-names <in.ttcity> <cities500.txt> <admin1CodesASCII.txt> <out.ttcity> <alternateNamesV2.txt> <allowlist.tsv>");
        std::process::exit(2);
    }
    match index_builder::build(
        args[0].as_ref(),
        args[1].as_ref(),
        args[2].as_ref(),
        args.get(3).map(|p| p.as_ref()),
    ) {
        Ok(stats) => {
            println!(
                "城市 {}  键 {}  倒排 {}  时区 {}  国家 {}  行政区 {}",
                stats.cities,
                stats.keys,
                stats.postings,
                stats.timezones,
                stats.countries,
                stats.admins
            );
            println!(
                "本地化显示名 {} 条  行政区本地化名 {} 条",
                stats.localized, stats.admin_localized
            );
            println!("体积 {:.2} MB", stats.bytes as f64 / 1_048_576.0);
        }
        Err(error) => {
            eprintln!("城市索引构建失败: {error}");
            std::process::exit(1);
        }
    }
}
