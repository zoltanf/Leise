# Leise architecture

Leise ships two fixed, compile-time components from the local
`LeiseComponents` Swift package:

```text
Leise.app
├── ServiceContainer (the process composition root)
│   ├── BuiltInComponents
│   │   ├── ParakeetEngine
│   │   └── FillerWordCleanup
│   ├── launch graph
│   │   ├── hotkey and audio services
│   │   ├── DictationViewModel
│   │   ├── ModelManagerService
│   │   └── insertion, history, dictionary, and profile services
│   └── memoized feature graphs
│       ├── file transcription
│       ├── failed-dictation recovery
│       ├── history editor
│       ├── profile editor
│       └── dictionary and term-pack editor
└── LeiseComponents
    ├── LeiseCore (request/result contracts and dictionary values)
    ├── ParakeetEngine
    └── FillerWordCleanup
```

There is no runtime discovery layer. The app does not scan bundles, read
component manifests, look up principal classes, or activate plugin lifecycle
objects. `ModelManagerService` owns one injected `TranscriptionEngine`, and the
post-processing pipeline owns an ordered array of injected `TextPostProcessor`
values.

`ServiceContainer.shared` is the one process-global composition owner because
AppKit delegates, event monitors, panels, and other callback entry points cannot
receive SwiftUI environment values. View models do not maintain their own
global storage. Retained feature view models use `MemoizedFeature`, so opening a
destination repeatedly returns the same graph without duplicating tasks or
observers.

Hotkey monitoring starts before retained store opening. Actions received while
the dictation callbacks are being attached are queued and replayed in order.
Model-selection metadata is restored after the callbacks are ready. Statistics
backfill and history retention run afterward in one owned maintenance task;
aggregation is performed in bounded utility batches and retention deletes are
cancellable, bounded, and idempotent.

History, dictionary, and profile stores remain in the launch graph because the
first hotkey must apply corrections, profile matching, and durable history
without a second initialization state. Their editors and term-pack network work
remain on demand. The final performance report records the resulting startup
tradeoff.
