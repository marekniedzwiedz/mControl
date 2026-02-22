# Build `mControl`: a macOS menubar blocker inspired by SelfControl

This ExecPlan is a living document. The sections `Progress`, `Surprises & Discoveries`, `Decision Log`, and `Outcomes & Retrospective` must be kept up to date as work proceeds.

This document follows `/PLANS.md` from the repository root and must be maintained in accordance with that file.

## Purpose / Big Picture

After this change, a user can run a native macOS menubar app that blocks configured domains in timed sessions, see active timers and blocked domains from the menubar popover, and manage multiple block groups with independent schedules. The user can also choose block severity per group: strict sessions cannot be stopped early, while flexible sessions can be stopped from the UI. The result is observable by running the app, creating groups, starting sessions, and verifying generated host-block entries and live countdowns.

## Progress

- [x] (2026-02-22 08:33Z) Read `/AGENTS.md` and `/PLANS.md` and extracted implementation constraints.
- [x] (2026-02-22 08:33Z) Analyzed public SelfControl behaviors to mirror: timed blocking, multi-site lists, and strict sessions that do not allow early stop.
- [x] (2026-02-22 08:35Z) Scaffolded Swift package structure for app + core + tests.
- [x] (2026-02-22 08:41Z) Implemented core domain models, scheduling logic, severity handling, and host-file section rendering.
- [x] (2026-02-22 08:45Z) Implemented menubar SwiftUI app with active info panels, group editing, interval scheduling, and severity-aware controls.
- [x] (2026-02-22 08:47Z) Added automated tests for scheduling, severity rules, domain parsing, and host-file section behavior.
- [x] (2026-02-22 08:47Z) Ran `swift test` and `swift build` successfully.
- [x] (2026-02-22 08:48Z) Added architecture review and usage documentation (`README.md`, `ARCHITECTURE.md`).
- [x] (2026-02-22 10:47Z) Addressed runtime UX/ops issues: moved editing to persistent Dashboard window and added explicit hosts-sync controls/status.
- [x] (2026-02-22 11:00Z) Added firewall-level blocking (`pf` anchor `com.apple/mcontrol`) to harden against browser DNS bypass.
- [x] (2026-02-22 11:08Z) Reduced privilege friction by batching hosts+PF updates into one elevated command and removed startup auto-sync prompt.
- [x] (2026-02-22 11:10Z) Improved UI contrast palette and switched menubar label to compact icon + status dot.
- [x] (2026-02-22 11:15Z) Reduced duplicate sync prompts by avoiding forced sync on every action and added single-instance process lock.
- [x] (2026-02-22 11:19Z) Added sync coalescing lock/cooldown to prevent overlapping timer/action system-sync invocations.
- [x] (2026-02-22 11:28Z) UX refactor: removed manual sync controls, merged dashboard focus around group management, added custom-duration start, and enabled start/stop directly in menubar popover.
- [x] (2026-02-22 11:40Z) Updated menubar to shield-empty/shield-filled semantics, added `Stop All`, and hardened resolver (`getaddrinfo` + dig fallback) to improve coverage for domains like `x.com`.

## Surprises & Discoveries

- Observation: No existing source code was present in the repository beyond planning docs.
  Evidence: `find . -maxdepth 3 -type f` initially returned only `AGENTS.md` and `PLANS.md`.

- Observation: Running `swift test` in sandbox failed due cache/module directories being inaccessible.
  Evidence: SwiftPM reported module cache write failures under `~/.cache/clang/ModuleCache`; rerunning with escalated permissions resolved this.

- Observation: Swift 6 actor isolation flagged cleanup in `@MainActor` view model deinit.
  Evidence: compiler error for `refreshTimer` access in nonisolated deinit; resolved by removing the deinit cleanup path.

- Observation: `onChange` closure variant used initially required macOS 14.
  Evidence: compile error for macOS 13 target; replaced with `.onReceive(viewModel.$errorMessage)`.

- Observation: Editing flows presented from `MenuBarExtra` popup were unreliable because the popup can collapse on focus changes.
  Evidence: user-reported sheet dismissal while attempting to edit text fields; mitigated by moving editing into a dedicated dashboard window scene.

- Observation: Browser access could persist despite correct `/etc/hosts` entries due secure-DNS/browser-level DNS bypass behavior.
  Evidence: user reported access while hosts block existed; mitigated by adding PF anchor rules for resolved destination IPs.

## Decision Log

- Decision: Build as a Swift Package with a SwiftUI executable target (`MenuBarExtra`) and a separate core library for business logic.
  Rationale: This keeps logic testable with `swift test` while still producing a native macOS menubar application.
  Date/Author: 2026-02-22 / Codex

- Decision: Implement domain blocking through managed sections in `/etc/hosts` with clear begin/end markers.
  Rationale: It is feasible in a user-space app, testable by text transformation, and does not require private APIs.
  Date/Author: 2026-02-22 / Codex

- Decision: Strict sessions lock domains at session start (`lockedDomains`).
  Rationale: This preserves “commitment mode” semantics even if the group domain list is edited while a strict interval is active.
  Date/Author: 2026-02-22 / Codex

- Decision: Keep scheduling and policy enforcement in `BlockManager` and keep UI as a thin orchestration layer.
  Rationale: Centralized policy avoids UI drift and makes behavior testable with unit tests.
  Date/Author: 2026-02-22 / Codex

## Outcomes & Retrospective

Implemented a working menubar blocker with group-level severity, multiple per-group intervals, active-session visibility, and live hosts synchronization. Core policy and rendering logic are covered by automated tests and compile cleanly. The architecture is modular enough for future migration to stronger network controls (for example, packet filter or extension-based blocking) without replacing UI and persistence code.

Remaining gap relative to full SelfControl-style hardening is system-level tamper resistance: this implementation intentionally enforces strictness at the app-policy level and hosts-file ownership, but root-capable users can still manually modify system files.

## Context and Orientation

The repository now contains a complete implementation:

- `Package.swift` defines:
  - library product `BlockingCore`
  - executable product `mControlApp`
  - test target `BlockingCoreTests`
- `Sources/BlockingCore/` contains models, planning logic, state persistence, and hosts rendering.
- `Sources/mControlApp/` contains the menubar app, view model, privileged hosts updater, and SwiftUI views.
- `Tests/BlockingCoreTests/` contains behavior tests.
- `README.md` and `ARCHITECTURE.md` provide operational and design guidance.

Key terms in this repository:

- Block group: named domain list + severity mode.
- Block interval: start/end session attached to one group.
- Strict severity: cannot stop early; locks domains at interval creation.
- Flexible severity: can stop early; active domains reflect current group edits.
- Managed hosts section: text between `# >>> mControl BEGIN` and `# <<< mControl END`.

## Plan of Work

Completed. Work was executed in this sequence:

1. Scaffold package and targets.
2. Implement `BlockingCore` logic and persistence.
3. Implement `mControlApp` menubar UI and orchestration.
4. Add tests for policy and rendering behavior.
5. Resolve Swift 6/macOS target compatibility issues.
6. Validate via build/tests.
7. Document usage and architecture.

## Concrete Steps

Working directory:
`<repo-root>`

Commands executed:

1. `swift test`
2. `swift build`

Observed output excerpts:

- `swift test`:
  `Test run with 11 tests in 3 suites passed`
- `swift build`:
  `Build complete!`

Manual run command for interactive validation:

- `swift run mControlApp`

Expected manual validation behavior:

- Create two groups with different severities.
- Start one strict interval and one flexible interval with different durations.
- Confirm both appear concurrently with independent countdowns.
- Confirm strict cannot stop early and flexible can.

## Validation and Acceptance

Acceptance criteria status:

- Multiple groups with independent active intervals: implemented and tested.
- Active sessions display remaining time and blocked domains: implemented in menubar UI.
- Strict sessions cannot stop early: implemented and tested.
- Flexible sessions can stop early: implemented and tested.
- Hosts managed section deterministic and removable: implemented and tested.
- Automated validation:
  - `swift test`: passed
  - `swift build`: passed

## Idempotence and Recovery

Build and test commands are idempotent and safe to rerun. Hosts updates are marker-based and overwrite only app-owned section boundaries. If privilege elevation is declined, the app keeps scheduled state and surfaces an error so the user can retry without data loss.

## Artifacts and Notes

Primary implementation artifacts:

- Core:
  - `Sources/BlockingCore/Models.swift`
  - `Sources/BlockingCore/BlockManager.swift`
  - `Sources/BlockingCore/BlockPlanner.swift`
  - `Sources/BlockingCore/DomainSanitizer.swift`
  - `Sources/BlockingCore/HostsSectionRenderer.swift`
  - `Sources/BlockingCore/StateStore.swift`
- App:
  - `Sources/mControlApp/mControlApp.swift`
  - `Sources/mControlApp/AppViewModel.swift`
  - `Sources/mControlApp/HostsUpdater.swift`
  - `Sources/mControlApp/ContentView.swift`
  - `Sources/mControlApp/GroupEditorView.swift`
  - `Sources/mControlApp/ScheduleIntervalView.swift`
- Tests:
  - `Tests/BlockingCoreTests/BlockManagerTests.swift`
  - `Tests/BlockingCoreTests/DomainSanitizerTests.swift`
  - `Tests/BlockingCoreTests/HostsSectionRendererTests.swift`
- Documentation:
  - `README.md`
  - `ARCHITECTURE.md`

## Interfaces and Dependencies

Implemented interfaces:

- `BlockingCore.BlockSeverity`: `strict`, `flexible`.
- `BlockingCore.BlockGroup`: group identity, domains, severity, intervals.
- `BlockingCore.BlockInterval`: session window and optional strict-domain lock.
- `BlockingCore.BlockPlanner`: active snapshots/domains and next change calculations.
- `BlockingCore.HostsSectionRenderer`: managed hosts section render/remove.
- `BlockingCore.StateStore`, `BlockingCore.JSONStateStore`, `BlockingCore.InMemoryStateStore`.
- `BlockingCore.BlockManager`: persistence-backed CRUD and policy enforcement.
- `mControlApp.AppViewModel`: UI orchestration and host synchronization trigger.
- `mControlApp.ManagedHostsUpdater`: privileged `/etc/hosts` writer.

External dependencies:

- Swift standard library + Foundation.
- SwiftUI/AppKit from macOS SDK.
- No third-party package dependency.

Revision note: Updated from planning draft to completed execution state after implementation, testing, compatibility fixes, and documentation.
