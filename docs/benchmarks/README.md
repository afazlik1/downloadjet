# Download engine performance — 0.3.0

Measured on 2026-11-05 on an Apple silicon Mac, using release builds. The baseline is the 0.2.0 transfer implementation; the optimized engine is 0.3.0. The benchmark code and data generation are in `Tests/DownloadCoreChecks/Benchmark.swift` and `server.py`.

| Scenario | 0.2.0 median | 0.3.0 median | Download time reduction | TCP connections, including HEAD |
| --- | ---: | ---: | ---: | --- |
| 64 MiB, connection setup overhead | 0.616 s | 0.367 s | 40.3% | 17 → 5 |
| 2 MiB, per-connection limited | 0.479 s | 0.246 s | 48.6% | 2 → 5 |

Both versions requested four workers. Each scenario ran three times. Timings include metadata request, transfer, assembly, synchronization, and destination publication. Output hash verification occurs after the timer stops; every output matched the deterministic source SHA-256. Raw results are in `baseline.json` and `optimized.json`; `comparison.json` records medians and engine source hashes.

The local HTTP/1.1 server adds 80 ms to each new connection independently. For the 64 MiB payload it sleeps 0.5 ms after each 64 KiB write (nominal 128 MiB/s per connection); for the 2 MiB payload it sleeps 8 ms (nominal 8 MiB/s). Actual fixture rates vary with OS timer and scheduling overhead. Loopback has no real packet loss or Internet RTT, these are short transfers, and three repeats do not establish a general speedup. No public-network, TLS/HTTP2, disk-saturation, or long-running power/CPU benchmark was performed.

The smaller payload uses more parallel requests in 0.3.0, so this scenario benefits specifically from per-connection throughput limits. For a server already saturating the user's link, extra ranges can add overhead and may not improve throughput. Tiny files retain a minimum 256 KiB range size to bound overhead. Per-host one/two-worker limits remain respected.

The larger payload uses the same sixteen range requests in both versions. The optimized session reuses four range connections instead of reconnecting for every range; HEAD uses an additional connection in this fixture. HTTP/2 may multiplex requests differently; the observed TCP counts are specific to HTTP/1.1 here. Apple's [URLSession documentation](https://developer.apple.com/documentation/foundation/urlsession) describes the shared session configuration, and [httpMaximumConnectionsPerHost](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/httpmaximumconnectionsperhost) explains the per-session HTTP/1.1 limit and HTTP/2 exception.

Changes:

- One transfer-owned URLSession routes download delegate callbacks by task ID and survives range completion and retries.
- New range sizes are approximately file size divided by requested workers, rounded up to 64 KiB and clamped between 256 KiB and 4 MiB. Compatible resume manifests retain their existing chunk size.
- Per-request progress callbacks are coalesced to roughly 10 Hz, with final-byte updates retained. The aggregate counter updates in constant time instead of repeatedly summing every range.
- All sixteen correctness check groups passed, including byte integrity, 0.2-format cached chunks, retries, cancellation, small-file segmentation, and measured worker concurrency/TCP reuse. See `validation.txt`.

To run the current engine's benchmark:

```sh
./scripts/check-core.sh --benchmark > results.json
```

This command runs only the installed source version. The retained baseline JSON is the measurement taken before editing the engine; rerunning the command will not recreate the old implementation.
