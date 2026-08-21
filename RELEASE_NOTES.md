# SplitRoute v0.1

This is the first experimental release of SplitRoute, a native macOS utility
that keeps Wi-Fi primary while routing outbound IPv4 frames through a
same-subnet wired Ethernet interface.

Highlights:

- menu-bar control and dashboard;
- fail-safe privileged routing watchdog;
- automatic and manual prompt-free repair while the watchdog is active;
- IPv4-aware download/upload speed test with per-interface traffic shares; and
- drag-to-Applications DMG.

## Important warning

SplitRoute v0.1 has not been tested extensively. No promise is made that it
works well—or at all. Enabling it changes the Mac's network-service order and
packet-filter state. Read the README and use it only if you understand and
accept that risk.

The app is ad-hoc signed and is not notarized by Apple. macOS may require you to
Control-click the app, choose **Open**, and explicitly confirm the first launch.
