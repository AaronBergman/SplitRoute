# SplitRoute

SplitRoute is an experimental native macOS utility for a specific same-LAN
setup: downloads arrive on Wi-Fi while outbound IPv4 traffic—including uploads
and download acknowledgements—leaves through wired Ethernet.

![SplitRoute app icon](Assets/AppIcon-1024.png)

## Download v0.1

- [Download SplitRoute v0.1 for macOS](https://github.com/AaronBergman/SplitRoute/releases/download/v0.1/SplitRoute-v0.1.dmg)
- [SHA-256 checksum](https://github.com/AaronBergman/SplitRoute/releases/download/v0.1/SplitRoute-v0.1.dmg.sha256)

> [!WARNING]
> SplitRoute v0.1 has not been tested extensively. No promise is made that it
> works well—or at all. It changes system network-service order and packet-filter
> state; use it only if you understand and accept that risk.

This build is ad-hoc signed, not signed with an Apple Developer ID certificate,
and not notarized by Apple. If macOS blocks the first launch, Control-click the
app in Finder, choose **Open**, and confirm only if you accept the warning.

To install it:

1. Download and open the DMG.
2. Drag **SplitRoute** to the **Applications** shortcut.
3. Eject the DMG and launch SplitRoute from Applications.

SplitRoute v0.1 requires macOS 14 or newer on an Apple silicon Mac.

## How it works

When both interfaces are active on the same IPv4 subnet, SplitRoute:

1. saves the complete macOS network-service order;
2. makes Wi-Fi primary so new connections bind the Wi-Fi address;
3. validates and loads a temporary `pf route-to` rule that sends that Wi-Fi
   source traffic through Ethernet without rewriting the source address;
4. starts a root watchdog that clears the reroute within about one second if
   Ethernet or addressing changes, then re-applies it when the wired path is
   healthy again; and
5. continuously verifies that Wi-Fi is still primary, `pf` is enabled, and the
   expected `route-to` rule remains loaded.

If the app sees persistent subnet, service-order, or waiting-state drift, it
writes a data-free `repair.request` marker. The already-authorized root watchdog
performs a complete rediscovery and validated reapply, so automatic and manual
**Repair now** actions do not open another administrator prompt. A prompt is
still required when starting a new privileged session after disabling or
rebooting.

Disabling restores `/etc/pf.conf`, restores the saved service order, and releases
the `pfctl -E` token. The rules are not persistent across reboot. IPv6 is not
changed in v0.1.

## Requirements

- macOS 14 or newer on Apple silicon
- active Wi-Fi and wired Ethernet interfaces on the same IPv4 subnet
- an IPv4 default gateway
- administrator authorization when enabling

## Background and menu bar

SplitRoute is a menu-bar app (`LSUIElement`), so it does not occupy the Dock.
Closing the dashboard leaves the process, status polling, and menu-bar control
running. The status icon changes for active, repairing/waiting, failed, and off
states. Its panel provides the split-routing toggle, interface addresses,
prompt-free repair, refresh, speed test, dashboard, and quit controls.

## Speed test

The built-in test measures download and upload sequentially for about seven
seconds each. It uses macOS's system TLS client in forced-IPv4 mode so the test
measures the IPv4 routing rule rather than silently taking an IPv6 path. During
both phases, SplitRoute samples macOS interface byte counters and reports the
proportion received on Wi-Fi and sent on Ethernet. Cloudflare-compliant chunks
are repeated to fill the timed phase. If Cloudflare rate-limits a download run,
SplitRoute continues with Hetzner's IPv4 bandwidth-test file instead of
discarding the test.

## Build and run

```sh
swift test
./script/build_and_run.sh
./script/package_release.sh
```

The local app bundle is created at `dist/SplitRoute.app`. The release-packaging
script creates `release/SplitRoute-v0.1.dmg` and its SHA-256 checksum. Both are
ad-hoc signed local artifacts; packaging does not notarize them.

## Scope and caveats

- This relies on both NICs sharing a LAN/subnet and on the router accepting the
  asymmetric same-source path.
- LAN, multicast, broadcast, and IPv4 link-local destinations are exempted from
  rerouting.
- A cable pull can drop outbound packets for up to the watchdog interval before
  the stock rules are restored.
- Quitting the UI does not disable an active split; the root safety watchdog
  continues until **Split routing** is switched off or the machine reboots.
- The app intentionally does not modify IPv6 routing.

## Contributors

- **OpenAI Codex** — primary implementation contributor; wrote the main codebase
  as an AI coding agent.
- **Aaron Bergman** — project direction, product decisions, and testing.

## License

No open-source license has been selected. Unless and until one is added, all
rights remain with the copyright owner.
