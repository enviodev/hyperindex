# Differential benchmark — Hasura (recorded baseline) vs envio serve

Baseline recorded 2026-07-03T16:12:50.782Z. 1 cases; per-case budget 1500ms, 3-30 iterations, warmup 2; case concurrency 1; sweep 0s.

## Resources (envio serve, this sweep)

| process | cpu seconds | peak rss (MB) | avg rss (MB) |
|---|---|---|---|
| envio serve | 0.0 | 317 | 317 |
| postgres | 0.0 | 284 | 284 |

## Resources (hasura, at baseline recording time)

| process | cpu seconds | peak rss (MB) | avg rss (MB) |
|---|---|---|---|
| hasura | 41.0 | 606 | 388 |
| postgres | 376.4 | 744 | 533 |

## Per case

| case | hasura p50 (ms, baseline) | envio p50 (ms) | envio p90 | speedup (p50) | samples |
|---|---|---|---|---|---|
| error-mutation-public | 0.6 | 0.9 | 4.7 | x0.70 | 30 |

Geometric-mean p50 speedup vs baseline: **x0.70**; cases >5% slower: **1**.
