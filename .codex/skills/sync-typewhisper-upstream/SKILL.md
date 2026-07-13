---
name: sync-typewhisper-upstream
description: Safely inspect, select, and integrate improvements from the TypeWhisper/typewhisper-mac upstream repository into the Leise fork. Use when Codex is asked to check upstream changes, sync the fork, import an upstream fix or feature, cherry-pick upstream commits, resolve upstream merge conflicts, or assess whether Leise is behind upstream.
---

# Sync TypeWhisper Upstream

Import upstream improvements deliberately while preserving Leise's GPL-only, local-first product boundary.

## Establish context

1. Work from the repository containing `Leise.xcodeproj`.
2. Read `AGENTS.md` and inspect the worktree before changing anything.
3. Verify the remotes:
   - `origin` must point to the Leise fork.
   - `upstream` must point to `TypeWhisper/typewhisper-mac`.
4. Preserve unrelated user changes. Never clean, reset, or overwrite a dirty worktree.
5. Fetch `upstream` before comparing commits. Fetching is read-only; merging, cherry-picking, committing, and pushing require matching user intent.

## Choose the integration method

Prefer the smallest safe unit:

- For one bug fix or self-contained improvement, create a branch from current Leise `main` and cherry-pick the relevant upstream commit.
- For a PR with several inseparable commits, cherry-pick the complete ordered commit set.
- For a broad release sync, create `upstream-sync/<date-or-release>` from Leise `main`, merge `upstream/main` with `--no-commit`, resolve deliberately, and test before committing.
- For inspection-only requests, report candidate commits and risks without modifying the worktree.

Do not use GitHub's **Sync fork** button or blindly fast-forward Leise. The products intentionally diverge.

## Assess candidate changes

Before integration:

1. Inspect the commit and its parent diff.
2. Identify dependencies on renamed symbols, removed licensing services, marketplace UI, external plugin loading, cloud providers, release infrastructure, bundle identifiers, or TypeWhisper assets.
3. Classify the candidate:
   - **Direct**: isolated logic or tests with no removed-system dependency.
   - **Adapt**: useful behavior that must be translated into Leise names or local-only architecture.
   - **Reject**: commercial, supporter, payment, marketplace, trademarked branding, or upstream distribution infrastructure.
4. Explain material adaptations in the handoff.

## Preserve Leise invariants

Never reintroduce:

- Polar or other product-entitlement validation.
- Commercial-license, supporter, purchase, pricing, or premium feature gates.
- License or premium settings screens and onboarding prompts.
- The external plugin marketplace or arbitrary bundle loading from Application Support.
- Cloud transcription, LLM, or TTS providers as user-selectable model options.
- TypeWhisper product names, icons, bundle identifiers, update feeds, signing identifiers, or release URLs except truthful provenance and upstream references.

Keep transcription, LLM, and TTS choices restricted to enabled, bundled, locally hosted providers. Keep third-party model-license acceptance where a model's own license requires it; that is not a Leise product entitlement.

## Resolve conflicts

- Preserve Leise names and paths (`Leise`, `LeisePluginSDK`, `leise-cli`, `com.leise.*`).
- Port behavior into current Leise structures instead of restoring deleted upstream files.
- Prefer Leise's local-model UI and bundled-engine boundary when upstream changes marketplace or provider selection code.
- Preserve upstream attribution in `LICENSE`, `FORK.md`, and `TRADEMARK.md`.
- Update or add tests for the adapted behavior; delete tests only when they exclusively test a deliberately removed subsystem.

## Verify

Run the bundled guard first:

```sh
.codex/skills/sync-typewhisper-upstream/scripts/audit_sync.sh
```

Then run checks proportional to the change:

```sh
git diff --check
rg --files Leise LeiseTests LeisePluginSDK/Sources -g '*.swift' -0 | xargs -0 swiftc -frontend -parse
find Leise LeisePluginSDK -name '*.json' -print0 | xargs -0 -n1 jq empty
plutil -lint Leise/Resources/Info.plist Leise/Resources/Leise.entitlements LeiseWidgetExtension/LeiseWidgetExtension.entitlements
```

With full Xcode selected, also run:

```sh
xcodebuild test -project Leise.xcodeproj -scheme Leise -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
swift test --package-path LeisePluginSDK
```

If full verification is unavailable, state the exact environmental blocker and do not claim the sync is fully validated.

## Handoff

Report:

- Upstream commits inspected and integrated.
- Whether each was direct or adapted.
- Conflicts and architectural decisions.
- Guard and test results.
- Any remaining risk or follow-up before pushing.
