# Experimental rust-analyzer source pin

This draft CI fixture starts from [rust-lang/rust-analyzer](https://github.com/rust-lang/rust-analyzer) commit `a0b58c0fe3e924302c1155e88c4a9454f86280c2`. The reviewed source change is `reviewed-v12.patch` (SHA256 `2DA3C80CEFFDA7934C6A9186E8C6F424F0ECF0B26D3F75FC843015C9DC3F712A`), applied to that exact commit and its `Cargo.lock` (SHA256 `B89F654112D04F4F562061AB717DB444BD4D6387D37A52E13DD93115643235C3`). Eight rust-analyzer source files change. The patch was AI-assisted and independently source-reviewed for this CodeStrike draft; it is not an upstream rust-analyzer pull request.

`test-hooks.patch` (SHA256 `450D849112C3EB0F28F9AD446A320C992412EEB6C51EA1955480B480736062D2`) adds deterministic cancellation and delayed-save acknowledgements **only** to a second, disposable CI checkout. It must never be applied to the analyzer binary used by the native GUI or an installed/default server.

The [source](https://github.com/rust-lang/rust-analyzer) is MIT OR Apache-2.0. The upstream `LICENSE-MIT` and `LICENSE-APACHE` are retained here. The CodeStrike workflow builds from source for verification only; this draft adds no executable, release, installer, credential, user fixture, or default language-server setting.

The local reviewed binary used Rust 1.97.1 (`rustc` commit `8bab26f4f68e0e26f0bb7960be334d5b520ea452`), 105 library tests, the requested Clippy check, a nine-scenario LSP matrix, push/pull capability checks, acknowledged race gates, and native GUI probes. CI must rebuild and retest from this source pin; the local binary SHA256 `422B0BA3A0C1AC123385639A3A84B4BE25307E6EC708055DEE6C582502ADA1B7` is provenance, not an expected hosted-build hash.
