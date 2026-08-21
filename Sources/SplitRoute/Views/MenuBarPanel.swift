import AppKit
import SwiftUI

struct MenuBarStatusLabel: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Image(systemName: store.routingState.menuBarSymbol)
            .accessibilityLabel("SplitRoute: \(store.routingState.label)")
            .help("SplitRoute — \(store.routingState.label)")
            .task { store.start() }
    }
}

struct MenuBarPanel: View {
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Image(systemName: "arrow.down")
                        .foregroundStyle(.blue)
                    Image(systemName: "arrow.up")
                        .foregroundStyle(.green)
                }
                .font(.system(size: 17, weight: .bold))

                VStack(alignment: .leading, spacing: 2) {
                    Text("SplitRoute")
                        .font(.headline)
                    Text(store.routingState.label)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }

                Spacer()

                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
            }

            Text(statusSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "Split routing",
                isOn: Binding(
                    get: { store.routingState.isRequested },
                    set: { store.setSplitRequested($0) }
                )
            )
            .toggleStyle(.switch)
            .disabled(toggleDisabled)

            Divider()

            VStack(spacing: 7) {
                interfaceRow(
                    title: "Wi-Fi",
                    symbol: "wifi",
                    detail: interfaceDetail(store.snapshot.wifi),
                    color: .blue
                )
                interfaceRow(
                    title: "Ethernet",
                    symbol: "cable.connector.horizontal",
                    detail: interfaceDetail(store.snapshot.ethernet),
                    color: .green
                )
            }

            HStack(spacing: 8) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)

                Button {
                    store.requestRepair()
                } label: {
                    Label("Repair now", systemImage: "wrench.and.screwdriver")
                }
                .disabled(!store.canRequestPromptFreeRepair)
            }

            if store.needsWatchdogUpgrade {
                Label(
                    "Switch routing off and on once to install automatic repair.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                store.runSpeedTest()
            } label: {
                Label("Run speed test", systemImage: "gauge.with.dots.needle.67percent")
                    .frame(maxWidth: .infinity)
            }
            .disabled(
                store.speedTest.phase.isRunning ||
                    store.snapshot.wifi?.isActive != true ||
                    store.snapshot.ethernet?.isActive != true
            )

            Divider()

            HStack {
                Button("Open SplitRoute") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("o")

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 330)
        .task { store.start() }
    }

    private var toggleDisabled: Bool {
        if store.routingState.isRequested {
            return store.routingState == .enabling || store.routingState == .disabling
        }
        return !store.snapshot.canEnable
    }

    private var statusColor: Color {
        switch store.routingState {
        case .active: .green
        case .repairing, .waitingForEthernet, .enabling, .disabling: .orange
        case .unsafeActive, .failed: .red
        case .off: .secondary
        }
    }

    private var statusSummary: String {
        switch store.routingState {
        case .active:
            "Downloads on Wi-Fi; uploads on Ethernet."
        case .repairing:
            "Repairing through the existing watchdog without an administrator prompt."
        case .waitingForEthernet:
            "Stock routing is restored. The split will return automatically when prerequisites recover."
        case .unsafeActive(let message), .failed(let message):
            message
        case .enabling:
            "Validating and applying split routing…"
        case .disabling:
            "Restoring stock routing…"
        case .off:
            store.snapshot.prerequisiteIssue ?? "Ready to enable."
        }
    }

    private func interfaceDetail(_ interface: InterfaceDetails?) -> String {
        guard let interface else { return "Not detected" }
        let address = interface.ipv4 ?? "No IPv4"
        return "\(interface.device) · \(address)"
    }

    private func interfaceRow(
        title: String,
        symbol: String,
        detail: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title)
                .font(.callout.weight(.semibold))
            Spacer()
            Text(detail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

private extension RoutingState {
    var menuBarSymbol: String {
        switch self {
        case .active:
            "arrow.up.arrow.down.circle.fill"
        case .repairing, .waitingForEthernet, .enabling, .disabling:
            "arrow.triangle.2.circlepath.circle.fill"
        case .unsafeActive, .failed:
            "exclamationmark.triangle.fill"
        case .off:
            "arrow.up.arrow.down.circle"
        }
    }
}
