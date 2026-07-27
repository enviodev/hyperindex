# Fuel test contracts

Sway contracts and deployment tooling behind the Fuel ABI fixtures the test
suite runs against. There is no indexer here — the indexer tests live in
`packages/envio-tests` (`FuelIndexer_test.res`, `FuelSwayTypes_test.res`), which
carry their own copies of the ABIs in `test/helpers/FuelAbiFixtures.res`.

- `contracts/all-events` — Sway contract logging one value of every Sway type.
  Its ABI drives the decoder type assertions in `FuelSwayTypes_test.res`.
- `contracts/interaction-tools` and `contracts/ts-interaction-tools` — deploy
  the contracts and emit events against a live Fuel network.
- `abis/` — the compiled ABIs, kept here as the source of record.

Regenerating an ABI means updating the matching fixture in
`FuelAbiFixtures.res`; the tests never read this directory.
