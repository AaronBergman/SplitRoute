# SplitRoute project guide

## What this is

SplitRoute is a SwiftUI macOS utility that keeps Wi-Fi primary (so connections
use the Wi-Fi IPv4 source address) while a `pf route-to` rule sends outbound IPv4
frames over a same-subnet wired Ethernet interface. IPv6 is intentionally left
unchanged.

## Build, test, and run

- `swift build` compiles the SwiftPM executable.
- `swift test` runs parser and prerequisite tests.
- `./script/build_and_run.sh` is the canonical kill/build/bundle/launch path.
- `./script/build_and_run.sh --verify` additionally confirms the launched app
  process stays alive.
- The packaged local app is `dist/SplitRoute.app` and is ad-hoc signed.
- `./script/package_release.sh` is the no-argument v0.1 release path. It creates
  `release/SplitRoute-v0.1.dmg` plus its SHA-256 checksum and verifies the image,
  mounted app signature, version, and Applications shortcut.
- Run `swift test`, app builds, and release packaging serially because they
  share SwiftPM's `.build` directory and packaging outputs.
- v0.1 is experimental and not extensively tested. There is no Developer ID
  signing identity in the current environment, so local/release bundles are
  ad-hoc signed and unnotarized; never describe them as Gatekeeper-clean.
- The Codex Run action is wired through `.codex/environments/environment.toml`.

## Architecture and safety contract

- `AppStore` polls interface and persisted routing state. It owns the UI actions
  but never constructs or executes privileged `pf` rules.
- `NetworkProbe` parses `networksetup`, `route`, and `ifconfig`; Ethernet is
  selected dynamically from active same-subnet wired hardware.
- `Resources/splitroute-controller.sh` is the complete privileged surface. It
  discovers all network values independently, validates generated rules with
  `pfctl -nf`, saves/restores the full service order, and holds the `pfctl -E`
  reference token.
- The detached root watchdog polls every second. Loss or change of carrier,
  interface, IPv4 address, mask, or gateway immediately reloads `/etc/pf.conf`;
  valid Ethernet return re-applies the split. The unprivileged Disable action
  only creates `stop.request`.
- While active, the watchdog also audits Wi-Fi service priority, `pf` enabled
  state, and the loaded `route-to` rule every five seconds. The app debounces a
  persistent subnet/service-order/waiting-state drift, then creates the
  data-free `repair.request` marker. The existing root watchdog consumes it and
  performs full rediscovery/reapply without another authorization prompt. Never
  put interface names, addresses, paths, or rule contents in that marker.
- Prompt-free repair requires `controller.version` 2 or newer. The UI must keep
  repair disabled for an older live watchdog and ask for one deliberate off/on
  upgrade instead of dropping a marker that the old process cannot consume.
- Watchdog launch uses zsh disowning with all standard streams redirected;
  macOS `nohup` is intentionally not used because it fails to detach under an
  authorized AppleScript shell. Enable verifies the PID and rolls everything
  back if launch fails. The app detects a missing PID and its Disable path falls
  back to the same audited controller with a new administrator prompt.
- Per-user transient state is `/private/tmp/splitroute-<uid>/`. A reboot clears
  both that directory and non-persistent `pf` rules.
- The speed test deliberately invokes the system TLS client with forced IPv4.
  A dual-stack URLSession may choose IPv6 and therefore cannot verify this
  IPv4-only routing rule. Cloudflare chunks are capped at 25 MB down and 10 MB
  up, then repeated to fill each seven-second phase.
- If Cloudflare returns HTTP 429 for downloads, the test continues against
  Hetzner's documented `fsn1-speed.hetzner.com/100MB.bin` IPv4 test file.
- Never broaden the root controller to accept shell snippets, interface names,
  IP addresses, paths, or rule text from the app.
- `SplitRouteApp` owns the single shared `AppStore` used by both the dashboard
  and `MenuBarExtra`. `LSUIElement` plus accessory activation keeps the app out
  of the Dock; closing the dashboard must not terminate the app. Use the menu
  bar's **Quit** command for process termination. Quitting intentionally leaves
  any active root-watchdog routing session intact.
- The 750 ms status poll must call `refresh(indicateActivity: false)`. Only a
  user-initiated refresh may toggle `isRefreshing`; otherwise Refresh controls
  repeatedly disable/re-enable and visibly flicker at the polling cadence.
- A real split-routing test changes service order and packet-filter state. Do not
  run it casually: launch/UI tests may proceed without switching the toggle on.

## UI system

- `Design/splitroute-concept.png` is the visual source of truth.
- The window is designed at 1120×820, with true white content, graphite chrome,
  blue for Wi-Fi/download, and green for Ethernet/upload.
- `Assets/AppIcon-1024.png` is the generated icon source;
  `Assets/AppIcon.appiconset` contains native scale variants and
  `Assets/AppIcon.icns` is the compiled bundle icon.
