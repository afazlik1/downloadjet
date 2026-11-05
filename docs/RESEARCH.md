# Research and implementation notes

Current is an independent implementation informed by public product documentation and validated with local HTTP fixtures. No IDM Windows executable was decompiled or run, and no proprietary IDM source code was used.

## References

- [Awesome REA catalog](https://github.com/AIshihzong/awesome-reverse-engineer-anything): evidence-first investigation and explicit distinctions between binary analysis and independent rebuilds.
- [REA](https://github.com/morluto/rea): optional reverse-engineering tooling used to inspect the public documentation website.
- [IDM overview](https://www.internetdownloadmanager.com/): download, queue, resume, and category workflows.
- [IDM feature descriptions](https://www.internetdownloadmanager.com/features2.html): publicly described segmentation and scheduling behavior.
- [IDM options](https://www.internetdownloadmanager.com/support/using_idm/options.html): per-server connection controls.
- [IDM scheduler](https://www.internetdownloadmanager.com/support/idm-scheduler/idm_scheduler.html): retry controls for failed queue items.

REA-assisted browser observations confirmed what those public help pages describe. They did not establish the Windows application's internal implementation. Local tool registrations, installation reports, browser captures, and workstation configuration are not part of this source distribution.

## Independent engineering choices

Current uses a fixed-range worker pool with adaptive 256 KiB–4 MiB ranges, rather than claiming to reproduce IDM's proprietary dynamic segmentation algorithm. A transfer-owned URLSession supports connection reuse; bounded buffers assemble validated chunks on disk.

Completed chunks are retained with a resource validator and compatible manifest layout. Temporary failures use a bounded per-request retry budget, exponential backoff, and Retry-After handling. These policies are independent choices, not a claim of identical IDM behavior.

For slow final ranges, an idle worker can issue one backup after a grace period. The first validated result is committed once and its peer is cancelled. Progress does not add duplicate bytes. One-worker limits and requests already in retry backoff remain respected. A shared server or network bottleneck may still limit both requests.

## Validation boundaries

The local fixtures verify range boundaries, byte integrity, saved-chunk reuse, cancellation, permanent-error handling, retry budgets, actual worker concurrency, TCP reuse, and cleanup of speculative tail requests. Benchmark conditions and raw measurements are retained in [benchmarks](benchmarks/README.md) and [the slow-tail regression](benchmarks/tail/README.md).

No general download speed multiplier is claimed. Performance depends on server policy, network capacity, protocol, and disk speed. Browser integration and the other limitations listed in the main README remain outside the current implementation.
