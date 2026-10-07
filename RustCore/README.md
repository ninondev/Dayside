# Dayside Rust core

English · [简体中文](README.zh-Hans.md)

Rust handles portable algorithms, rules, and state machines. Swift connects Apple frameworks and presents the interface. Preference keys and JSON shapes stay compatible. Time and region facts come from the system, so the app does not bundle a separate ICU or tzdata that could disagree with the device.

All Dayside features are free, and the source is licensed under GPL-3.0-only. Times are read out of text by a local, deterministic engine.

## Code boundaries

| Module | Responsibility | Host responsibility |
| --- | --- | --- |
| `model`, `settings`, `store` | Place editing, settings validation, scheduling, recovery, and migration rules | Observation, Task, UserDefaults, and system integration |
| `catalog`, `city_index` | City index, query folding, ranking, localization, and subtitle rules | Resource paths, system Locale and TimeZone, and script conversion |
| `understand` | Dates, times, ranges, relative times, places, and time zones in sixteen languages; ambiguous candidates and issues | Foundation date resolution, DST gaps and repeated times, and user choices |
| `converter` | ISO 8601, Unix, and chat-platform timestamps from actual offsets | Clipboard and system offsets |
| `planner`, `meeting`, `people`, `agenda` | Shared availability, rotation, ICS, people, and agenda rules | Calendar, EventKit, Contacts, permissions, and date formatting |
| `solar`, `astronomy`, `sky`, `worldmap`, `lane` | Sun and moon calculations, sky colors, map geometry, and day/night lanes | Local dates, drawing buffers, and SwiftUI |
| `timers`, `travel`, `dst_watch` | Timers, travel schedules, and clock-change reminders | Monotonic clocks, system events, and notifications |
| `sharing`, `automation`, `presentation` | Sharing, entry-point validation, and presentation rules | Files, URLs, App Intents, and interface lifecycles |
| `presence` | Menu-bar recovery | Menu-bar events |

Normal builds include every feature. The `intents-only` feature builds a reduced core for checks; App Intents run in the main app. Installed packages need neither a Rust runtime nor Cargo.

## Build and verification

See the [root README](../README.md) for full commands. `Cargo.lock` pins dependency versions. Xcode's `DaysideCore` target calls `Tools/build_rust_core.sh` to produce a static library for each architecture. Release uses thin LTO. Signing follows dSYM generation and symbol stripping.

The two `understand` migration checks use frozen answers in `tests/corpus/migration-*.jsonl` and their known-gap lists. When a known gap is fixed, the test asks for its removal from the list. Tests on real messages, negative examples, and properties run with the normal suite. The sentence-generator report and the large probes are marked `#[ignore]`.

## City index

The bundled `TahoeTime/Resources/cities.ttcity` uses TTCITY12: columnar fixed-point records, static symbol tables, prefix-compressed search keys, and grouped localized-name streams. The reader uses mmap on demand. Menu-bar display names are saved with each place; displaying saved places does not query the index.

`src/bin/build_city_index.rs` supports builds from raw GeoNames data, transcoding old images, adding languages, and repairing names. The raw dumps come from GeoNames. Normal builds do not rebuild the index. `data/*_names_wikidata.tsv` supplies Wikidata labels; `data/admin1_zh_supplement.tsv` fills missing Chinese administrative-region names. A place without a translated label keeps its primary name.

Search-key patches live in `src/index_builder_rules.rs::SEARCH_KEY_ERRATA`. They add keys and postings without changing display names, coordinates, or time zones. Transcoding must be idempotent; a fixed-point test enforces it. After changing the index format or its data, compare every record and localized name before and after, and keep the tests for malformed segments, queries, and handle release.

See the root [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for third-party data licenses and sources.
