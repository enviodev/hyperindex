# Soak load report

Duration 66s, concurrency 24, target http://localhost:8082, 703 requests (10.6 req/s).

## Status codes

- 200: 703 (100.00%)

Error rate (5xx + transport): **0.000%**

## Latency

Overall p50 652.2ms, p99 14909.7ms (n=703).

| window | start (s) | requests | errors | p50 (ms) | p99 (ms) |
|---|---|---|---|---|---|
| 0 | 0 | 203 | 0 | 443.7 | 57095.4 |
| 1 | 10 | 127 | 0 | 461.0 | 14460.8 |
| 2 | 20 | 65 | 0 | 772.2 | 15571.1 |
| 3 | 30 | 117 | 0 | 766.2 | 14544.0 |
| 4 | 40 | 112 | 0 | 662.4 | 14336.0 |
| 5 | 50 | 79 | 0 | 859.6 | 11725.0 |

p99 drift: window 1 (14460.8ms) -> window 5 (11725.0ms), x0.81 (threshold x2).

## Resource usage (pid 17357)

RSS: start 1278MB, stabilized baseline 2052MB, final 1817MB, peak 2230MB, growth -11.4% (threshold 20%).
fd count: start 42, stabilized baseline 74, final 73, growth -1.

## Result

PASS
