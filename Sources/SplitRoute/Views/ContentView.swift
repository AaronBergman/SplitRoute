import SwiftUI

struct ContentView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(store: store)
            ScrollView {
                VStack(spacing: 0) {
                    HeroSection(store: store)
                    Divider().padding(.horizontal, 28)
                    ConnectionDetails(snapshot: store.snapshot)
                    Divider().padding(.horizontal, 28)
                    SpeedTestSection(store: store, speedTest: store.speedTest)
                    SafetyFooter()
                }
            }
            .background(SplitRouteColors.window)
        }
        .background(SplitRouteColors.window)
        .alert(
            "SplitRoute needs attention",
            isPresented: Binding(
                get: { store.actionError != nil },
                set: { if !$0 { store.dismissActionError() } }
            )
        ) {
            Button("OK", role: .cancel) { store.dismissActionError() }
        } message: {
            Text(store.actionError ?? "Unknown error")
        }
        .task { store.start() }
    }
}

private struct AppHeader: View {
    @ObservedObject var store: AppStore

    var body: some View {
        HStack(spacing: 14) {
            SplitRouteMark()
            Text("SplitRoute")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(HeaderButtonStyle())
            .disabled(store.isRefreshing)
            .accessibilityHint("Refreshes interface and routing status")
        }
        .padding(.leading, 94)
        .padding(.trailing, 22)
        .frame(height: 68)
        .background(SplitRouteColors.header)
    }
}

private struct SplitRouteMark: View {
    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: "arrow.down")
                .foregroundStyle(SplitRouteColors.wifi)
            Image(systemName: "arrow.up")
                .foregroundStyle(SplitRouteColors.ethernet)
        }
        .font(.system(size: 19, weight: .bold))
        .accessibilityHidden(true)
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.65 : 0.94))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct SplitRoutingToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                ZStack {
                    Capsule()
                        .fill(configuration.isOn ? SplitRouteColors.wifi : Color.secondary.opacity(0.28))
                        .frame(width: 48, height: 28)
                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                        .offset(x: configuration.isOn ? 10 : -10)
                }
                .animation(.easeOut(duration: 0.16), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

private struct HeroSection: View {
    @ObservedObject var store: AppStore

    private var toggleDisabled: Bool {
        if store.routingState.isRequested {
            return store.routingState == .enabling || store.routingState == .disabling
        }
        return !store.snapshot.canEnable
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 30) {
                Text("Downloads on Wi-Fi. Uploads on Ethernet.")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .foregroundStyle(SplitRouteColors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 16)

                Toggle(
                    "Split routing",
                    isOn: Binding(
                        get: { store.routingState.isRequested },
                        set: { store.setSplitRequested($0) }
                    )
                )
                .toggleStyle(SplitRoutingToggleStyle())
                .font(.system(size: 16, weight: .semibold))
                .fixedSize()
                .disabled(toggleDisabled)
            }

            InterfaceFlow(snapshot: store.snapshot, routingState: store.routingState)

            HStack(spacing: 7) {
                Image(systemName: explanationIcon)
                    .foregroundStyle(explanationColor)
                Text(explanation)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SplitRouteColors.secondaryInk)
                Spacer()
            }
            .frame(minHeight: 20)
        }
        .padding(.top, 26)
        .padding(.horizontal, 38)
        .padding(.bottom, 20)
    }

    private var explanation: String {
        switch store.routingState {
        case .active:
            return "IPv4 downloads arrive on Wi-Fi while outbound traffic leaves on Ethernet."
        case .unsafeActive(let message):
            return message
        case .waitingForEthernet:
            return "The reroute is safely cleared. SplitRoute will re-apply it when Ethernet returns."
        case .enabling:
            return "Applying service order and validated packet-filter rules…"
        case .repairing:
            return "Repairing routing automatically through the existing safety watchdog—no password needed."
        case .disabling:
            return "Restoring the original service order and stock packet-filter rules…"
        case .failed(let message):
            return message
        case .off:
            return store.snapshot.prerequisiteIssue ?? "Ready. Enabling requires one macOS administrator prompt."
        }
    }

    private var explanationIcon: String {
        store.routingState == .active ? "checkmark.shield.fill" : "info.circle.fill"
    }

    private var explanationColor: Color {
        if case .unsafeActive = store.routingState { return SplitRouteColors.danger }
        return store.routingState == .active ? SplitRouteColors.ethernet : SplitRouteColors.secondaryInk
    }
}

private struct InterfaceFlow: View {
    let snapshot: NetworkSnapshot
    let routingState: RoutingState

    var body: some View {
        HStack(spacing: 22) {
            InterfaceNode(
                kind: .wifi,
                title: "Wi-Fi",
                details: interfaceDetail(snapshot.wifi),
                connected: snapshot.wifi?.isActive == true
            )

            DirectionLine(
                color: SplitRouteColors.wifi,
                label: "Receives downloads",
                arrowPointsTowardCenter: true
            )

            VStack(spacing: 8) {
                Text(snapshot.gateway ?? "No gateway")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SplitRouteColors.ink)
                RoutingStateControl(state: routingState)
                Text(snapshot.isSameSubnet ? "Same subnet" : "Subnet mismatch")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SplitRouteColors.secondaryInk)
            }
            .frame(width: 178)

            DirectionLine(
                color: SplitRouteColors.ethernet,
                label: "Sends uploads",
                arrowPointsTowardCenter: true
            )

            InterfaceNode(
                kind: .ethernet,
                title: "Ethernet",
                details: interfaceDetail(snapshot.ethernet),
                connected: snapshot.ethernet?.isActive == true
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func interfaceDetail(_ interface: InterfaceDetails?) -> String {
        guard let interface else { return "Not detected" }
        return "\(interface.device) · \(interface.ipv4 ?? "No IPv4")"
    }
}

private enum InterfaceKind {
    case wifi
    case ethernet

    var color: Color {
        switch self {
        case .wifi: SplitRouteColors.wifi
        case .ethernet: SplitRouteColors.ethernet
        }
    }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .ethernet: "cable.connector.horizontal"
        }
    }
}

private struct InterfaceNode: View {
    let kind: InterfaceKind
    let title: String
    let details: String
    let connected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(kind.color)
                    .frame(width: 52, height: 52)
                    .background(kind.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(kind.color.opacity(0.75), lineWidth: 1.5)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(kind.color)
                    Text(details)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(SplitRouteColors.secondaryInk)
                        .lineLimit(1)
                }
            }

            Label(connected ? "Connected" : "Unavailable", systemImage: connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(connected ? SplitRouteColors.healthy : SplitRouteColors.warning)
                .padding(.leading, 64)
        }
        .frame(width: 220, alignment: .leading)
    }
}

private struct DirectionLine: View {
    let color: Color
    let label: String
    let arrowPointsTowardCenter: Bool

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(height: 3)
                Image(systemName: arrowPointsTowardCenter ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(color)
            }
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(minWidth: 90, maxWidth: 150)
        .accessibilityElement(children: .combine)
    }
}

private struct RoutingStateControl: View {
    let state: RoutingState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(state.label)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.07), in: Capsule())
        .overlay { Capsule().stroke(color.opacity(0.8), lineWidth: 1.4) }
    }

    private var color: Color {
        switch state {
        case .active: SplitRouteColors.healthy
        case .unsafeActive: SplitRouteColors.danger
        case .waitingForEthernet, .enabling, .repairing, .disabling: SplitRouteColors.warning
        case .failed: SplitRouteColors.danger
        case .off: SplitRouteColors.secondaryInk
        }
    }
}

private struct ConnectionDetails: View {
    let snapshot: NetworkSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Connection details")
                .sectionHeading()

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    GridLabel("Interface")
                    GridHeader("Wi-Fi", color: SplitRouteColors.wifi)
                    GridHeader("Ethernet", color: SplitRouteColors.ethernet)
                    GridHeader("Primary service", color: SplitRouteColors.ink)
                    GridHeader("Gateway", color: SplitRouteColors.ink)
                }
                tableDivider
                detailsRow("Device", snapshot.wifi?.device, snapshot.ethernet?.device, snapshot.primaryService, snapshot.gateway)
                tableDivider
                detailsRow("IP address", snapshot.wifi?.ipv4, snapshot.ethernet?.ipv4, primaryIPAddress, snapshot.gateway)
                tableDivider
                detailsRow(
                    "Status",
                    snapshot.wifi?.isActive == true ? "Connected" : "Unavailable",
                    snapshot.ethernet?.isActive == true ? "Connected" : "Unavailable",
                    snapshot.primaryService == nil ? "Unavailable" : "Active",
                    snapshot.gateway == nil ? "Unavailable" : "Reachable"
                )
                tableDivider
                detailsRow("Subnet", snapshot.wifi?.cidr, snapshot.ethernet?.cidr, snapshot.subnetDescription, snapshot.subnetDescription)
            }
        }
        .padding(.horizontal, 38)
        .padding(.vertical, 18)
    }

    private var primaryDevice: String? {
        snapshot.serviceOrder.first(where: { $0.name == snapshot.primaryService })?.device
    }

    private var primaryIPAddress: String? {
        guard let primaryDevice else { return nil }
        if primaryDevice == snapshot.wifi?.device { return snapshot.wifi?.ipv4 }
        if primaryDevice == snapshot.ethernet?.device { return snapshot.ethernet?.ipv4 }
        return nil
    }

    private var tableDivider: some View {
        Divider().gridCellColumns(5)
    }

    private func detailsRow(
        _ label: String,
        _ wifi: String?,
        _ ethernet: String?,
        _ primary: String?,
        _ gateway: String?
    ) -> some View {
        GridRow {
            GridLabel(label)
            GridValue(wifi ?? "—", color: SplitRouteColors.wifi)
            GridValue(ethernet ?? "—", color: SplitRouteColors.ethernet)
            GridValue(primary ?? "—", color: SplitRouteColors.ink)
            GridValue(gateway ?? "—", color: SplitRouteColors.ink)
        }
        .frame(minHeight: 27)
    }
}

private struct GridLabel: View {
    let value: String
    init(_ value: String) { self.value = value }

    var body: some View {
        Text(value)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(SplitRouteColors.secondaryInk)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GridHeader: View {
    let value: String
    let color: Color
    init(_ value: String, color: Color) {
        self.value = value
        self.color = color
    }

    var body: some View {
        Text(value)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GridValue: View {
    let value: String
    let color: Color
    init(_ value: String, color: Color) {
        self.value = value
        self.color = color
    }

    var body: some View {
        Text(value)
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpeedTestSection: View {
    @ObservedObject var store: AppStore
    @ObservedObject var speedTest: SpeedTestService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speed test")
                .sectionHeading()

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Button(action: store.runSpeedTest) {
                        Label(
                            speedTest.phase.isRunning ? "Testing…" : "Run speed test",
                            systemImage: "gauge.with.dots.needle.67percent"
                        )
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SplitRouteColors.wifi)
                    .disabled(speedTest.phase.isRunning || store.snapshot.wifi == nil || store.snapshot.ethernet == nil)

                    Text(speedTest.phase.detail)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(speedTest.phase.failureMessage == nil ? SplitRouteColors.secondaryInk : SplitRouteColors.danger)
                        .fixedSize(horizontal: false, vertical: true)

                    ProgressView(value: speedTest.progress)
                        .tint(speedTest.phase == .uploading ? SplitRouteColors.ethernet : SplitRouteColors.wifi)
                }
                .frame(width: 190)

                MetricReadout(
                    title: "Download",
                    value: speedTest.downloadMbps,
                    evidence: speedTest.downloadViaWifiPercent.map { "\(Int($0.rounded()))% arrived via Wi-Fi" },
                    color: SplitRouteColors.wifi
                )

                MetricReadout(
                    title: "Upload",
                    value: speedTest.uploadMbps,
                    evidence: speedTest.uploadViaEthernetPercent.map { "\(Int($0.rounded()))% sent via Ethernet" },
                    color: SplitRouteColors.ethernet
                )

                Divider().frame(height: 112)

                LiveTrafficReadout(traffic: speedTest.liveTraffic)
                    .frame(width: 270)
            }
        }
        .padding(.horizontal, 38)
        .padding(.top, 18)
        .padding(.bottom, 17)
    }
}

private extension SpeedTestPhase {
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var detail: String {
        failureMessage ?? label
    }
}

private struct MetricReadout: View {
    let title: String
    let value: Double?
    let evidence: String?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value.map { String(Int($0.rounded())) } ?? "—")
                    .font(.system(size: 43, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .monospacedDigit()
                Text("Mbps")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
            }
            Capsule().fill(color).frame(height: 7)
            Text(evidence ?? "Waiting for test data")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(evidence == nil ? SplitRouteColors.secondaryInk : color)
                .lineLimit(1)
        }
        .frame(minWidth: 175, maxWidth: .infinity, alignment: .leading)
    }
}

private struct LiveTrafficReadout: View {
    let traffic: LiveTraffic

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Live traffic (per interface)")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(SplitRouteColors.secondaryInk)

            trafficRow(
                title: "Wi-Fi",
                symbol: "wifi",
                down: traffic.wifiDownBytesPerSecond,
                up: traffic.wifiUpBytesPerSecond,
                color: SplitRouteColors.wifi
            )
            Divider()
            trafficRow(
                title: "Ethernet",
                symbol: "cable.connector.horizontal",
                down: traffic.ethernetDownBytesPerSecond,
                up: traffic.ethernetUpBytesPerSecond,
                color: SplitRouteColors.ethernet
            )
        }
    }

    private func trafficRow(
        title: String,
        symbol: String,
        down: Double,
        up: Double,
        color: Color
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 82, alignment: .leading)
            Text("↓ \(Self.rate(down))")
            Text("↑ \(Self.rate(up))")
        }
        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
        .foregroundStyle(color)
    }

    private static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        }
        return "0 KB/s"
    }
}

private struct SafetyFooter: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(SplitRouteColors.secondaryInk)
            Text("Cable changes are handled automatically. IPv6 is unchanged.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SplitRouteColors.secondaryInk)
            Spacer()
            Image(systemName: "info.circle")
                .foregroundStyle(SplitRouteColors.secondaryInk)
                .help("SplitRoute only changes IPv4 routing. Its packet-filter rules clear on reboot.")
        }
        .padding(.horizontal, 38)
        .frame(height: 44)
        .overlay(alignment: .top) { Divider() }
    }
}

private enum SplitRouteColors {
    static let window = Color.white
    static let header = Color(red: 0.105, green: 0.11, blue: 0.115)
    static let ink = Color(red: 0.06, green: 0.065, blue: 0.075)
    static let secondaryInk = Color(red: 0.35, green: 0.37, blue: 0.40)
    static let wifi = Color(red: 0.02, green: 0.34, blue: 0.93)
    static let ethernet = Color(red: 0.02, green: 0.50, blue: 0.10)
    static let healthy = Color(red: 0.02, green: 0.50, blue: 0.10)
    static let warning = Color(red: 0.83, green: 0.48, blue: 0.02)
    static let danger = Color(red: 0.80, green: 0.12, blue: 0.13)
}

private extension View {
    func sectionHeading() -> some View {
        font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(SplitRouteColors.ink)
    }
}
