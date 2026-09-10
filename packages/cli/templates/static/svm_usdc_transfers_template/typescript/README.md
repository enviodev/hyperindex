# Solana USDC transfers

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

Indexes every USDC transfer made through the SPL Token program on Solana and
writes one row per instruction — top-level calls and CPIs alike, so the swaps,
routers and lending programs that move most of the volume are included.

## Prerequisites

- **[Node.js v22+ (v24 recommended)](https://nodejs.org/en/download/)**
- **[pnpm](https://pnpm.io/installation)**
- **[Docker](https://www.docker.com/products/docker-desktop/)** or **[Podman](https://podman.io/)**

Add an Envio API token to `.env` — it authenticates the HyperSync source that
streams instructions. Create one at
[envio.dev/app/api-tokens](https://envio.dev/app/api-tokens).

```
ENVIO_API_TOKEN=<YOUR-API-TOKEN>
```

## Running the indexer

```bash
pnpm dev
```

If you change `config.yaml` or `schema.graphql`, regenerate the type files:

```bash
pnpm codegen
```

## Querying

While the indexer is running, open the GraphQL Playground at
[http://localhost:8080](http://localhost:8080) (local password `testing`):

```graphql
{
  Transfer(limit: 10, order_by: { slot: desc }) {
    slot
    amount
    source
    destination
    signer
    checked
  }
}
```

## Test

```bash
pnpm test
```

The tests run the handlers over simulated instructions, so they need no
network and no API token.

## How it works

`config.yaml` declares the two SPL Token instructions that move tokens.
Each names the byte SPL Token dispatches on, the account slots in the order
the program expects them, and the Borsh layout of its arguments — enough for
HyperIndex to decode a call into `instruction.accounts.<name>` and
`instruction.args.<name>`. A program with a published IDL can point `idl:` at
the JSON file instead of listing instructions by hand.

The two instructions need different treatment:

- **`transferChecked`** names the mint in its account list, so
  `where: { accounts: { mint: MINT } }` filters server-side and nothing
  arrives that has to be thrown away.
- **`transfer`** does not — its accounts are `(source, destination, authority)`
  and no mint appears anywhere in the instruction. Which token moved is only
  knowable from the transaction's token balances, which
  `fields.accountActivity` joins onto the named accounts. Roughly a third of all
  USDC transfers take this path, so it is not a tail case.

Reading either token account settles it, because SPL Token rejects a transfer
whose two accounts hold different mints. Reading only the source would lose the
transfers whose source the transaction itself opened: an account with no
balance before the transaction is absent from the balance records.

## Making it your own

- **Another token** — change `MINT` in `src/handlers/SplToken.ts`.
- **A shorter backfill** — raise `start_slot` in `config.yaml`;
  `curl -s https://solana.hypersync.xyz/height` gives the current head, and
  `latest` starts there.
- **Another program** — add it under `programs` with its own instructions, and
  register a handler with `indexer.onInstruction`.
