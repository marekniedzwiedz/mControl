# mControl

`mControl` is a native macOS menubar blocker inspired by [SelfControl](https://selfcontrolapp.com/).

It focuses on the same core behavior (time-bound blocking) and extends it with group-based scheduling and severity modes.

## What it does

- Runs as a macOS menubar app using `MenuBarExtra`.
- Uses a compact menubar shield indicator (outline when idle, green-filled when any session is active).
- Menubar popover uses the same dark visual palette as the dashboard.
- Menubar popover has an `All Groups` section with quick start (`1h`/`4h`/`24h`/`7d`) and custom duration for starting every group at once.
- Group rows in menubar are start-focused (quick start + custom). Active session stopping is handled in `Active Sessions`.
- Settings include `Launch at Login`, `Ask before Quit from menubar`, and `Default custom duration`.
- Lets you define multiple block groups, each with its own domain list.
- Supports multiple intervals per group (overlapping across groups is allowed).
- Shows live status in the menubar popover and opens a full Dashboard window for editing/scheduling.
- Supports severity per group:
  - `strict`: interval cannot be stopped early.
  - `flexible`: interval can be stopped early.
- Persists app state in JSON at:
  `~/Library/Application Support/mControl/state.json`.

## How blocking works

mControl uses two layers in one synchronized apply operation:

1. `/etc/hosts` managed block section.
2. macOS Packet Filter (`pf`) anchor rules (`com.apple/mcontrol`) to block resolved IPs.

This mirrors SelfControl-style hardening better than hosts-only blocking and helps when browsers use Secure DNS / DoH.

mControl still manages a marker-based section inside `/etc/hosts`:

- Begin marker: `# >>> mControl BEGIN`
- End marker: `# <<< mControl END`

When active domains change, the app rewrites only that managed hosts section and also refreshes the PF anchor.
PF IP resolution samples multiple DNS answers per domain to catch rotating CDN edge IPs more reliably.
If DNS resolution temporarily returns no routable IPs, mControl reuses the last PF anchor IP set instead of weakening an active block.

Because both `/etc/hosts` and `pf` updates are privileged, macOS prompts for administrator approval when changes are applied. Updates are batched into one elevated command to minimize repeated prompts.
If admin authorization is canceled, mControl rolls back the attempted UI/state change so sessions are not shown as active/stopped unless system blocking actually succeeded.
On app launch, if any session is active, mControl forces one startup sync to re-assert both hosts and PF rules.
If no session is active but a stale mControl PF anchor is detected, launch also triggers a cleanup sync.

## Project layout

- Core logic: `Sources/BlockingCore`
- Menubar UI + orchestration: `Sources/mControlApp`
- Tests: `Tests/BlockingCoreTests`
- Architecture notes: `ARCHITECTURE.md`

## Run

From the repository root:

```bash
swift run mControlApp
```

After launch:

- Click the menubar icon.
- Use `Open Dashboard` to manage groups and schedules.
- Starting/stopping/scheduling sessions applies system blocking automatically.

## Build a DMG Installer

From the repository root:

```bash
./scripts/package_dmg.sh
```

This creates:

- `dist/mControl.dmg`

Open the DMG and drag `mControl.app` into `Applications`.

The script generates a shield icon and applies it to both `mControl.app` and the resulting `mControl.dmg`.

## Test

From the repository root:

```bash
swift test
swift build
```

## Notes on strict sessions

`strict` sessions are intentionally hard to bypass from inside the app:

- The UI disallows early stop for strict intervals.
- Strict intervals lock domains at session start (`lockedDomains`) so editing the group later does not change that running strict session.

This matches the intent of SelfControl-style commitment sessions while still allowing flexible sessions where needed.
