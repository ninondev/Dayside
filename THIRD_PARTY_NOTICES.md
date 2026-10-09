# Third-party notices

Dayside's own code is licensed under GPL-3.0-only (see `LICENSE` and `COPYING`). The data and
components below come from other sources and keep their own licenses.

## GeoNames (city data)

`Dayside/Resources/cities.ttcity` is a read-only index compiled from the GeoNames `cities500`
dump: place names, alternate names, coordinates, time zone, country and first-level
administrative region. Localized display names come from the GeoNames `alternateNamesV2` dump.
`RustCore/data/lights.bin` (the night-time city lights on the map) is derived from the population
column of the same `cities500` dump by `Tools/make_lights_bin.py`.

- Source: https://www.geonames.org
- License: Creative Commons Attribution 4.0 (CC BY 4.0), https://creativecommons.org/licenses/by/4.0/
- Changes: the data was selected, checked and packed into a compact binary format by
  `RustCore/src/bin/build_city_index.rs` (format in `RustCore/src/index_builder.rs`).
- GeoNames is not affiliated with this project and does not endorse it. As with the upstream
  data, it is provided "as is", without warranty of accuracy, timeliness or completeness.

The dump files are available at https://download.geonames.org/export/dump/. To rebuild the index:

```
cargo run --manifest-path RustCore/Cargo.toml --locked --release --bin build_city_index -- \
    cities500.txt admin1CodesASCII.txt /tmp/cities.ttcity alternateNamesV2.txt
```

## Wikidata (place-name labels)

`RustCore/data/city_names_wikidata.tsv`, `RustCore/data/admin1_names_wikidata.tsv` and the rows
marked `wikidata` in `RustCore/data/admin1_zh_supplement.tsv` hold labels from Wikidata
(https://www.wikidata.org), matched by GeoNames ID (property P1566) or by name and coordinates
(`Tools/wikidata_labels.py`). Wikidata's structured data is published under CC0 1.0
(https://creativecommons.org/publicdomain/zero/1.0/).

The other rows of `admin1_zh_supplement.tsv` are Chinese names of first-level administrative
regions translated for this project, partly by machine translation; the `source` column says
which method was used for each row.

## IANA Time Zone Database

Time zone rules come from the tzdata that ships with macOS and are read at run time.
`Dayside/Resources/tzcoords.json` holds reference coordinates taken from the time zone
database's `zone.tab`; it is used only when the system copy cannot be read. The time zone
database is in the public domain. `RustCore/data/country_zones.tsv` is generated from
its `zone.tab` by `Tools/make_country_zones.py`.

`RustCore/data/country_names.tsv` is generated from macOS Foundation region names in all
16 interface languages by `Tools/make_country_names.swift`. `RustCore/src/day_words.rs`
uses Unicode CLDR day-period rules and localized names, adapted for standalone clock labels.
Unicode data is covered by the Unicode License v3, reproduced in the bundled notices.

## Natural Earth (map relief)

`Dayside/Resources/relief.png` is derived from Natural Earth "Gray Earth with Shaded Relief,
Hypsography, and Ocean Bottom" at 1:50m (https://www.naturalearthdata.com), which is in the public
domain. It was cropped and resized by `Tools/make_relief.swift`.

## Liu Jian Mao Cao (epigraph artwork)

The brush-calligraphy image `Dayside/Assets.xcassets/EpigraphZh.imageset/Epigraph.pdf` is made
from glyph outlines of Liu Jian Mao Cao (Copyright 2018 The Liu Jian Mao Cao Project Authors,
https://github.com/googlefonts/liujianmaocao; designers Liu Zhengjiang, Kimberly Geswein and
ZhongQi), licensed under the SIL Open Font License, Version 1.1 (https://openfontlicense.org).
The font itself is not included; `Tools/make_epigraph.swift` arranged five glyph outlines into
one column. The epigraph lines are from Zhang Jiuling (Tang dynasty) and from John Muir, "John of
the Mountains" (1938).

## Rust crates

The versions of the Rust dependencies are pinned in `RustCore/Cargo.lock`. Their license and
attribution texts are reproduced in `Dayside/Resources/ThirdPartyNotices.txt`, which ships inside
the app bundle.
