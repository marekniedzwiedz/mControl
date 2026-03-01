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
  - Resolves blocked domains to IP addresses (system DNS + `dig` + DoH) and applies PF anchor rules (`com.apple/mcontrol`) for firewall-level blocking.
  - Uses aggressive DoH ECS sampling for Akamai-style CNAME chain hosts to increase edge IP coverage.
  - For fast-rotating CDN hosts, increases repeated resolver sampling and retains larger rolling PF unions for longer windows to reduce edge-IP miss gaps.
  - Derives `/24` CIDR entries for high-churn IPv4 pools and writes them to PF to catch rapid same-subnet edge swaps.
  - Keeps a rolling PF IP union for unchanged active domain sets, reducing unblock windows caused by CDN edge rotation.
  - Kills existing PF states for blocked destination IPs so active browser connections cannot survive newly-started blocks.
- `PFRefreshDaemonManager.swift`
  - Installs/updates a root LaunchDaemon (`com.mcontrol.pfrefresh`) that runs PF refresh every 1 minute without repeated prompts.
  - Detects stale daemon installs (binary/plist drift) so app can avoid trusting outdated background refresh.
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
- Optional root PF daemon removes repeated prompts for PF refresh by running under `launchd`.
- PF rules depend on DNS resolution at apply time and may not cover all CDN edge/IP churn instantly.
- Strict mode is app-enforced commitment; users with root access can still manually alter system files.

## Validation status

- Core behavior is covered by unit tests in:
  - `Tests/BlockingCoreTests/BlockManagerTests.swift`
  - `Tests/BlockingCoreTests/DomainSanitizerTests.swift`
  - `Tests/BlockingCoreTests/HostsSectionRendererTests.swift`
- `swift test` and `swift build` pass.
