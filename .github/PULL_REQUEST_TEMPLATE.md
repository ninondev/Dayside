## What changed and why

Describe the problem and how this change addresses it.

## Verification

List the commands you ran and their results. If you skipped a relevant check, say why.

From `RustCore/`:

```sh
cargo test --locked --offline -j 3 --all-targets
cargo test --locked --offline -j 3 --release --lib
cargo test --locked --offline -j 3 --lib --features intents-only
cargo clippy --locked --offline -j 3 --all-targets -- -D warnings
```

From the repository root:

```sh
python3 Tools/spdx_headers.py --check
python3 Tools/l10n_check.py --check
Tools/check_entitlements.sh
node Tools/site_tests/when_test.mjs
```

On macOS, `Tools/verify_all.sh` also runs the app-hosted Swift tests.
For interface changes, describe what you checked in the app and attach screenshots if helpful.

- [ ] New source files start with `SPDX-License-Identifier: GPL-3.0-only` in a comment, after any shebang.
