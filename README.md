# DownloadJet — Fast downloads for Mac

DownloadJet is an independent native macOS download manager built with SwiftUI. It provides parallel HTTP downloads, resumable queues, scheduling, and automatic recovery inspired by Internet Download Manager's documented workflows.

This project is not affiliated with Internet Download Manager or Tonec. It is an independent Swift implementation; it does not use IDM's proprietary source code or Windows executable. The icon is based on artwork supplied for the project.

## Build and run

Requires macOS 14 or later, Swift 6 or later, and Apple's Command Line Tools or Xcode. There are no third-party Swift package dependencies.

```sh
git clone https://github.com/afazlik1/downloadjet.git
cd downloadjet
./scripts/build-app.sh
open dist/DownloadJet.app
```

Double-click `DownloadJet.app` to launch it. To install locally, drag it from `dist` into Applications, then add it to the Dock if desired. The build also creates `dist/DownloadJet-macOS.zip`.

The app is ad-hoc signed and built for the current machine's architecture. Public binary distribution requires an appropriate Developer ID signing and notarization workflow. This repository contains source and assets; generated app bundles, archives, and build caches are excluded from Git.

## Features

- HTTP and HTTPS downloads with up to two files active at once.
- Configurable 1, 2, 4, or 8 range workers per file, with saved exact-host overrides.
- Shared network sessions for connection reuse, adaptive 256 KiB–4 MiB ranges, and coalesced progress updates.
- Pause/resume and saved queues across launches. Compatible completed chunks are retained when the server supports ranges and provides a strong ETag or Last-Modified validator. Incomplete chunks restart; servers without safe range support restart the file.
- Validated range boundaries and lengths, If-Range checks, and destination collision protection.
- Bounded automatic retries for temporary network failures and HTTP 408/429/500/502/503/504, with exponential backoff and Retry-After support capped at five minutes.
- Slow final-range recovery using an idle worker and at most one backup per range. The first fully validated copy wins; the other is cancelled. One-worker limits and requests in retry backoff are respected.
- Batch URL entry, folder selection, per-file scheduling, categories, search, Finder reveal, native light/dark appearance, and transfer/recovery/assembly status.
- **Download Later** saves links without starting any requests. Saved links persist across launches in the Download Later section; use **Start Download** on a row or its context menu to start one. Resume All leaves these links stopped.

Use **Cmd+N** to add links, then choose **Download Now**, **Download Later**, or enable scheduling and choose **Schedule**. Download Later saves links for manual starting without a scheduled time. Settings controls connection defaults, retries, and per-host worker limits. Rules match the original URL's exact hostname and apply per file, including after redirects; they do not cap the combined connections of multiple files. Pause and resume a transfer to apply changed settings.

## Data and privacy

Queue and preference data are stored locally in `~/Library/Application Support/DownloadJet/`. On first launch after updating, the app automatically moves its earlier storage folder, preserving the queue, settings, and completed chunks. If a DownloadJet folder already exists, it is used without merging or overwriting older data. Completed chunks are in its `Parts` directory. Completed downloads are saved in the selected folder, which defaults to Downloads.

Saved URLs may contain private query parameters. Queue data is unencrypted and should not be shared or committed. Local state, partial files, credentials, agent configuration, and generated outputs are ignored by Git. Removing a stopped queue item clears its partial chunks and retains finished output files.

## Limitations

Browser interception/extensions, authenticated browser sessions, video discovery, HLS/DASH, FTP, website crawling, bandwidth limiting, recurring schedules, and background transfers while the app is closed are not implemented. Scheduled transfers run only while the app is open and the Mac is awake.

Filenames come from URLs rather than Content-Disposition. Servers that advertise ranges but return invalid responses fail visibly. Exhausted retries and permanent failures require manual Resume. Local partial files are app-managed; same-size corruption is not detected without an external trusted checksum. Slow-tail recovery can repeat up to one chunk of traffic per affected range and cannot overcome server-wide or network-wide throttling.

To update during a download: pause, quit, rebuild/reopen, and resume. Compatible completed chunks are retained, while the incomplete chunk may restart.

## Validation

Python 3 must be available on `PATH` for the local HTTP fixture.

```sh
./scripts/check-core.sh
./scripts/check-core.sh --benchmark
./scripts/check-core.sh --tail-benchmark
```

The standalone check executable works with Command Line Tools and does not require XCTest. Its 25 check groups cover storage migration and preservation, exact file integrity, saved-chunk resume, unsupported HEAD, malformed responses, collisions, cancellation, retries/backoff, worker limits, connection reuse, adaptive ranges, and slow-tail recovery/cleanup.

The default check command also compiles the app's real download store into an isolated harness. Four additional checks verify that saved links make no requests, survive relaunch and queue controls, start individually with exact file bytes, and can be removed without downloading.

[Benchmark results and conditions](docs/benchmarks/README.md) include simulated connection-limited workloads. The [slow-tail regression](docs/benchmarks/tail/README.md) reproduces one slow final request. These local measurements are not Internet speed guarantees.

Set `DOWNLOADJET_BUILD_DIR` to an alternate build-cache directory when needed. The default is `.build/`. The build generates macOS icon sizes from `assets/AppIcon.png`.

## Research

[Research notes](docs/RESEARCH.md) describe the public documentation and REA-assisted website observations that informed the app. REA is optional development tooling and is not needed to build or run DownloadJet.
