# Leise engine boundary

Leise uses this Swift package as an internal protocol boundary for the local model engines
bundled with the macOS app.

The app presents its fixed local engine and cleanup component as ordinary compile-time
dependencies. The small protocol boundary keeps implementation details isolated without
introducing runtime discovery or lifecycle machinery.

Run the package checks with:

```sh
swift test --package-path LeiseComponents
```

Third-party model licenses still apply to downloaded weights. Those notices are separate
from Leise's GPL application license and must remain visible before a restricted model is
downloaded.
