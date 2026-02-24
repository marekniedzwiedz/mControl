# Architecture Review

This document summarizes the implemented architecture for `mControl` and why it is structured this way.

## High-level design

The app is split into two layers:

1. `BlockingCore` (`Sources/BlockingCore`)
2. `mControlApp` (`Sources/mControlApp`)
3. `mControlPFDaemon` (`Sources/mControlPFDaemon`)

This separation keeps blocking logic deterministic and testable while isolating macOS UI and privileged integration in the app layer.

## Core layer (`BlockingCore`)

- `Models.swift`
  - Domain entities: `BlockGroup`, `BlockInterval`, `BlockSeverity`, `AppState`, `ActiveGroupSnapshot`.
- `DomainSanitizer.swift`
  - Normalizes and validates user domain input.
- `BlockPlanner.swift`
  - Pure computations for active sessions, effective domains, and next schedule change.
- `BlockManager.swift`
  - Stateful API for CRUD on groups, interval scheduling, early-stop rules, and persistence updates.
- `HostsSectionRenderer.swift`
  - Pure text transformation of hosts content using begin/end markers.
- `StateStore.swift`
  - Persistence abstraction (`StateStore`) and JSON implementation (`JSONStateStore`).

### Why this is clean

- Pure logic (`BlockPlanner`, `HostsSectionRenderer`, `DomainSanitizer`) is isolated from side effects.
- Side effects (disk persistence) are behind `StateStore`.
- Severity policy is enforced centrally in `BlockManager`, not spread across UI.

## App layer (`mControlApp`)

- `AppViewModel.swift`
  - Coordinates user actions, periodic refresh, and host synchronization.
- `HostsUpdater.swift`
  - Applies rendered hosts content with admin privileges via AppleScript.
  - Resolves blocked domains to IP addresses and applies PF anchor rules (`com.apple/mcontrol`) for firewall-level blocking.
- `PFRefreshDaemonManager.swift`
  - Installs/updates a root LaunchDaemon (`com.mcontrol.pfrefresh`) that runs hourly PF refresh without repeated prompts.
- `ContentView.swift`
  - Menubar popover UI with active sessions and group controls.
- `GroupEditorView.swift`, `ScheduleIntervalView.swift`, `SettingsView.swift`
  - Editing/scheduling and status UI.
- `mControlApp.swift`
  - App entry point and menubar scene.

### Why this is practical

- UI stays responsive because heavy logic is already pre-shaped by core APIs.
- Privileged operations are localized to one file (`HostsUpdater.swift`).
- The view model computes a minimal delta (`activeDomains` changed) before writing hosts.

## Tradeoffs and current limitations

- Blocking uses `/etc/hosts` plus PF anchor rules.
- Session start/stop still requires privilege to update `/etc/hosts`.
- Optional root PF daemon removes repeated hourly prompts for PF refresh by running under `launchd`.
- PF rules depend on DNS resolution at apply time and may not cover all CDN edge/IP churn instantly.
- Strict mode is app-enforced commitment; users with root access can still manually alter system files.

## Validation status

- Core behavior is covered by unit tests in:
  - `Tests/BlockingCoreTests/BlockManagerTests.swift`
  - `Tests/BlockingCoreTests/DomainSanitizerTests.swift`
  - `Tests/BlockingCoreTests/HostsSectionRendererTests.swift`
- `swift test` and `swift build` pass.
