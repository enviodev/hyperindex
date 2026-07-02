# Soak load report

Duration 57s, concurrency 24, target http://localhost:8081, 614 requests (10.9 req/s).

## Status codes

- 200: 614 (100.00%)

Error rate (5xx + transport): **0.000%**

## Latency

Overall p50 474.6ms, p99 14837.3ms (n=614).

| window | start (s) | requests | errors | p50 (ms) | p99 (ms) |
|---|---|---|---|---|---|
| 0 | 0 | 210 | 0 | 345.0 | 27927.3 |
| 1 | 8 | 57 | 0 | 696.4 | 11129.9 |
| 2 | 15 | 120 | 0 | 559.4 | 13691.8 |
| 3 | 23 | 76 | 0 | 713.6 | 25742.6 |
| 4 | 30 | 62 | 0 | 792.2 | 15141.0 |
| 5 | 38 | 89 | 0 | 472.7 | 13083.4 |

p99 drift: window 1 (11129.9ms) -> window 5 (13083.4ms), x1.18 (threshold x2).

## Resource usage (pid 29637)

RSS: start 533MB, stabilized baseline 1381MB, final 1728MB, peak 1906MB, growth 25.1% (threshold 20%).
fd count: start 40, stabilized baseline 71, final 72, growth 1.

## Result

FAIL:
- RSS grew 25.1% from stabilized baseline (1381MB -> 1728MB), threshold 20%.
