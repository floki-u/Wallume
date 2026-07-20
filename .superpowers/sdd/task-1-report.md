# Task 1 report — Settings preferences and low-power policy

## Scope delivered

- Added `ApplicationSettings`, an observable `SettingsStore`, and the `LoginItemControlling` boundary.
- Added the production `SMAppService.mainApp` adapter; ServiceManagement is confined to that adapter.
- Kept ordinary preferences behind injected `UserDefaults`, retaining the stable `openGalleryAtLaunch` key.
- Made the login-item state system-authoritative after registration/unregistration. Failures retain the prior value and expose only the closed, user-safe message `无法更新登录启动设置，请稍后重试。`.
- Added low-power policy to `RuntimeEnvironmentMonitor`. The monitor retains the physical low-power signal while the policy removes or re-adds `.lowPower` from the emitted effective environment immediately.
- Deliberately did not change UI, `ApplicationController`, export functionality, or application composition; those are later plan tasks.

## TDD evidence

1. Added `SettingsStoreTests` with an isolated UserDefaults suite and `FakeLoginItem` seam. Coverage includes defaults, legacy `openGalleryAtLaunch` decoding, ordinary preference persistence, system-authoritative login state, and register/unregister rollback with redaction of a raw system-error description.
2. Added a monitor test proving `.lowPower` is removed and restored immediately while physical low-power state remains enabled.
3. RED command: `swift test --filter SettingsStoreTests && swift test --filter RuntimeEnvironmentMonitorTests` failed as expected before implementation because `ApplicationSettings`, `SettingsStore`, `LoginItemControlling`, and `setLowPowerPauseEnabled(_:)` were absent.
4. GREEN command: `swift test --filter SettingsStoreTests && swift test --filter RuntimeEnvironmentMonitorTests` passed: 7 SettingsStore tests and 3 RuntimeEnvironmentMonitor tests (10 total).

## Verification and review

- `swift test` passed: 386 tests, 0 failures.
- `git diff --check` passed.
- Reviewed scope and production imports: direct `ServiceManagement`/`SMAppService` use exists only in `Sources/WallumeAppSupport/Settings/LoginItemController.swift`.
- No known concerns for Task 1. Runtime/application wiring of the new preference is intentionally deferred to Task 3.
