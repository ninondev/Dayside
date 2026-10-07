# Dayside Rust 核心

[English](README.md) · 简体中文

Rust 承接可移植的算法、规则和状态机，Swift 接入 Apple 框架并呈现界面。偏好键与 JSON 形状保持兼容；时间与地区事实来自系统，避免另带一套与设备不同的 ICU 或 tzdata。

Dayside 全部功能免费，源码采用 GPL-3.0-only。文本理解由本地确定性引擎完成。

## 代码边界

| 模块 | 职责 | 宿主负责 |
| --- | --- | --- |
| `model`、`settings`、`store` | 地点编辑、设置校验、调度、恢复与迁移规则 | Observation、Task、UserDefaults 与系统集成 |
| `catalog`、`city_index` | 城市索引、查询折叠、排名、本地化与副标题规则 | 资源定位、系统 Locale、TimeZone 与字形转换 |
| `understand` | 十六语文本中的日期、钟点、区间、相对时间、地点与时区；歧义候选与问题 | Foundation 日期落成、夏令时缺口与重复、用户选择 |
| `converter` | 按实际偏移输出 ISO 8601、Unix 与聊天平台时间戳 | 剪贴板与系统偏移 |
| `planner`、`meeting`、`people`、`agenda` | 共同空档、轮换、ICS、人物与日程规则 | Calendar、EventKit、Contacts、权限与日期格式 |
| `solar`、`astronomy`、`sky`、`worldmap`、`lane` | 太阳月亮、天色、地图与昼夜条几何 | 本地日期、绘图缓冲与 SwiftUI |
| `timers`、`travel`、`dst_watch` | 计时、旅行作息与换钟提醒 | 单调时钟、系统事件与通知 |
| `sharing`、`automation`、`presentation` | 分享、入口校验与显示规则 | 文件、URL、App Intents 与界面生命周期 |
| `presence` | 菜单栏恢复 | 菜单栏事件 |

普通构建开放全部功能。保留的 `intents-only` 编译选项用于验证精简核心；当前 App Intents 在主程序中运行。安装包不需要 Rust 运行时或 Cargo。

## 构建与验证

完整命令见[仓根 README](../README.md)。`Cargo.lock` 固定依赖版本，Xcode 的 `DaysideCore` 调用 `Tools/build_rust_core.sh` 按架构生成静态库。Release 使用 thin LTO，签名发生在 dSYM 生成与符号裁剪之后。

`understand` 的两道迁移门使用 `tests/corpus/migration-*.jsonl` 的冻结答案及对应已知差异表。修正了已知差异时，测试会提醒删除已经恢复的那条。实际消息、负例与性质测试保留为常规测试；造句器报告与大规模报告探针保持 ignored。

## 城市索引

随包 `TahoeTime/Resources/cities.ttcity` 使用 TTCITY12：列式定点记录、静态符号表、前缀压缩搜索键及分组本地化名字流。读取器按需 mmap；菜单栏显示名随地点保存，显示已保存地点时不查询索引。

`src/bin/build_city_index.rs` 支持 GeoNames 原始数据构建、旧镜像转码、增加语言和修正名字。构建所需的原始转储来自 GeoNames，重建不会由普通构建自动触发。`data/*_names_wikidata.tsv` 提供 Wikidata 标签；`data/admin1_zh_supplement.tsv` 补充缺失的中文行政区名。现有标签必须有数据依据，缺失时保留主名。

搜索键补丁在 `src/index_builder_rules.rs::SEARCH_KEY_ERRATA`，只增加键与倒排，不改显示名、坐标或时区。转码应幂等；更改索引格式或数据时，须核对完整记录和本地化名字，并保留坏段、查询与句柄释放测试。

所有第三方数据的许可与出处见仓根 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
