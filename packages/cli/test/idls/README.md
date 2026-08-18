# IDL fixtures

Real IDLs, unmodified, for `config_parsing::svm_idl` tests. The scenario
projects keep their own under `scenarios/*/idls/`; these are here because no
scenario indexes them.

| Program | File | Version | Format | Source |
|---|---|---|---|---|
| SPL Token | `spl-token.codama.json` | 3.3.0 | Codama | https://raw.githubusercontent.com/solana-program/token/main/idl.json |
| SPL Memo | `memo.codama.json` | 3.0.1 | Codama | https://raw.githubusercontent.com/solana-program/memo/main/idl.json |

Both declare instructions Borsh cannot express — SPL Token's
`uiAmountToAmount` takes a remainder-encoded string and `batch` frames its
inner data with a u8, and Memo's whole payload is a remainder string. That is
why they are here: they pin that one such instruction costs only itself, which
is what keeps SPL Token's other 26 indexable.
