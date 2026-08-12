# ERC-20 storage write benchmark

Runs the erc20 template end to end against HyperSync over a fixed block range and
reports how long each storage backend spent writing, so a Postgres-only run and a
ClickHouse-only run can be compared on identical event traffic.

The handlers are the template's, minus the entity reads: `context.Account.get()`
is unavailable for ClickHouse-backed entities, so the template's balance
accumulation cannot run on that side at all. Dropping the reads keeps the write
shape identical on both backends.

## Setup

```sh
ln -s ../../packages/envio node_modules/envio
ln -s ../envio/bin.mjs node_modules/.bin/envio
cp .env.example .env   # then point it at your Postgres and ClickHouse
export ENVIO_API_TOKEN=...
```

## Run

```sh
./run.sh pg 10861674 11100000 pg-run
./run.sh ch 10861674 11100000 ch-run
```

Each run resets its own Postgres schema (`bench_pg` / `bench_ch`) and ClickHouse
database, scrapes the Prometheus endpoint while indexing, and writes
`results/<label>.json` with wall time, events processed and per-backend write
seconds.

`prof/analyze.mjs <dir>` summarises `--cpu-prof` output by self and inclusive
time, for attributing write cost between the JS and native halves.
