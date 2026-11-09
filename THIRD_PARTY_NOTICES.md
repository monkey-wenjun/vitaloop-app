# Third-party notices

Vitaloop is distributed under AGPL-3.0. This file summarizes dependencies whose
licenses and notices must be preserved in source and binary distributions.

## Gadgetbridge protocol sources

Files under
`android/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/` include copied
or adapted Gadgetbridge Java protocol/model sources.

Copyright (C) Gadgetbridge contributors. Licensed under AGPL-3.0.
Upstream: <https://codeberg.org/Freeyourgadget/Gadgetbridge>.

## Flutter and Dart

Copyright Google LLC and Dart project authors. BSD-3-Clause.

## MapLibre and Protomaps

`maplibre_gl` and MapLibre Native are BSD-3-Clause, Copyright MapLibre
contributors. Protomaps PMTiles tooling is BSD-3-Clause, Copyright Protomaps
LLC. Public default map data is derived from OpenStreetMap under ODbL and must
retain OpenStreetMap attribution.

## Kotlin, AndroidX, OkHttp, Gson, SLF4J

Each dependency retains its upstream license. The public source tree records the
exact versions in Gradle files and lock files.

## Rust crates

Direct dependencies include `flutter_rust_bridge`, `rusqlite`, `anyhow`,
`serde_json`, `chrono`, and `aes-gcm`. Exact versions are pinned in
`rust/Cargo.lock`; retain the licenses from each crate.

## Cargokit

The build glue under `rust_builder/cargokit/` is copied from Cargokit.
Copyright 2022 Matej Knopp. MIT License; the full text is retained at
`rust_builder/cargokit/LICENSE`.

## Flutter/Dart packages

Packages include `flutter_rust_bridge`, `path_provider`, `path`, `intl`, and
`flutter_lints`. Exact versions are pinned in `pubspec.lock`.

## Assets and maps

Material Icons are Apache-2.0. Map tiles and geocoding/routing services are
provided by their selected vendors and remain subject to those vendors' terms.
No commercial font is bundled.
