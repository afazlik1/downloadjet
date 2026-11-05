# Slow final range regression — 0.3.1

A final range can remain active indefinitely when a server sends occasional bytes slowly enough to avoid an idle timeout. In 0.3.0, workers whose ranges had finished could not help that request. This matches the class of slowdown shown by the user, although the remote server's actual cause was not traced or proven.

The local fixture serves a 9 MiB file with different SHA-256-derived content in every 64 KiB block, so swapped or misplaced chunks are detectable. The first request for the final range receives only 64 KiB every 180 ms. Other requests, including a backup for that range, are unthrottled. Four workers are requested.

| Release | Completion time | Final-range requests | Output SHA-256 |
| --- | ---: | ---: | --- |
| 0.3.0 | 6.451 s | 1 | Verified |
| 0.3.1 | 2.105 s | 2, slower copy cancelled | Verified |

This is one reproduction run per version, with approximately 67% less completion time in this particular fixture. Timing includes assembly and publication. It establishes that the slow original does not hold up completion after a validated backup wins, not a general Internet performance guarantee. Raw request logs and timings are in `baseline.json` and `optimized.json`.

The fix issues at most one speculative backup per unfinished range after a two-second grace period, only when ordinary pending ranges are exhausted and a configured worker slot is idle. Byte-range boundaries, total length, payload length, and If-Range continue to be checked. A successful copy is committed once; the losing task is cancelled and awaited. Progress uses the maximum bytes for each range, rather than adding duplicate traffic. Per-attempt staging files are removed after every task has drained.

One-worker mode disables speculative recovery. A request that has entered retry backoff is ineligible, so this mechanism does not bypass its Retry-After delay or retry budget. Temporary transport failures can leave a still-active peer running; malformed ranges and permanent failures remain errors. The app also labels final assembly separately and clears stale speed readings after two seconds without progress.

Tradeoffs: a backup may repeat up to one chunk (at most 4 MiB) of network traffic per affected range. If both requests are slow because of a shared server, IP, disk, or network limit, a new request may not help. Existing valid completed chunks and their manifest layout remain compatible; partial chunks still restart after pause/relaunch.

All 21 check groups passed. New cases verify recovery time, exact output, bounded progress, at-most-one backup, cancellation of the loser, saved-chunk reuse, cleanup after user cancellation, malformed-backup rejection, one-worker exclusion, and server Retry-After behavior. Tests shorten the grace period to run quickly; the reported reproduction uses the production two-second value.

```sh
./scripts/check-core.sh
./scripts/check-core.sh --tail-benchmark
```
