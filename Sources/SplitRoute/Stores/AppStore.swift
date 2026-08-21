import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var snapshot: NetworkSnapshot = .empty
    @Published private(set) var routingState: RoutingState
    @Published private(set) var probeError: String?
    @Published private(set) var actionError: String?
    @Published private(set) var isRefreshing = false

    let speedTest = SpeedTestService()

    private let probe = NetworkProbe()
    private let routingController = RoutingController()
    private var pollingTask: Task<Void, Never>?
    private var disableRequestedAt: Date?
    private var repairConditionSince: Date?
    private var lastRepairRequestedAt: Date?

    private let automaticRepairGracePeriod: TimeInterval = 2.5
    private let automaticRepairCooldown: TimeInterval = 15

    init() {
        routingState = routingController.readState()
    }

    deinit {
        pollingTask?.cancel()
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(indicateActivity: false)
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    func refresh(indicateActivity: Bool = true) async {
        if indicateActivity {
            isRefreshing = true
        }
        defer {
            if indicateActivity {
                isRefreshing = false
            }
        }

        let captureResult = await Task.detached(priority: .utility) { [probe] in
            Result { try probe.capture() }
        }.value

        switch captureResult {
        case .success(let snapshot):
            self.snapshot = snapshot
            probeError = nil
        case .failure(let error):
            probeError = error.localizedDescription
        }

        let persistedState = routingController.readState()
        if let disableRequestedAt,
           Date().timeIntervalSince(disableRequestedAt) < 5,
           persistedState != .off {
            routingState = .disabling
        } else {
            self.disableRequestedAt = nil
            routingState = persistedState
        }
        requestAutomaticRepairIfNeeded(now: Date())
    }

    func setSplitRequested(_ requested: Bool) {
        actionError = nil
        if requested {
            guard snapshot.canEnable else {
                actionError = snapshot.prerequisiteIssue
                return
            }
            routingState = .enabling
            Task { [weak self] in
                guard let self else { return }
                let result = await Task.detached(priority: .userInitiated) { [routingController] in
                    Result { try routingController.enable() }
                }.value
                switch result {
                case .success:
                    routingState = routingController.readState()
                case .failure(let error):
                    routingState = .failed(error.localizedDescription)
                    actionError = error.localizedDescription
                }
                await refresh()
            }
        } else {
            routingState = .disabling
            disableRequestedAt = Date()
            Task { [weak self] in
                guard let self else { return }
                let result = await Task.detached(priority: .userInitiated) { [routingController] in
                    Result { try routingController.requestDisable() }
                }.value
                if case .failure(let error) = result {
                    routingState = routingController.readState()
                    actionError = "Could not request a safe shutdown: \(error.localizedDescription)"
                }
                await refresh()
            }
        }
    }

    func runSpeedTest() {
        guard let wifi = snapshot.wifi?.device, let ethernet = snapshot.ethernet?.device else {
            actionError = "Both Wi-Fi and Ethernet must be connected to compare interface traffic."
            return
        }
        speedTest.run(wifiDevice: wifi, ethernetDevice: ethernet)
    }

    func requestRepair() {
        actionError = nil
        do {
            try routingController.requestRepair()
            routingState = .repairing
        } catch {
            actionError = "Could not request a prompt-free repair: \(error.localizedDescription)"
        }
    }

    var canRequestPromptFreeRepair: Bool {
        routingState.isRequested && routingController.supportsPromptFreeRepair
    }

    var needsWatchdogUpgrade: Bool {
        routingState.isRequested &&
            routingController.isWatchdogRunning &&
            !routingController.supportsPromptFreeRepair
    }

    func dismissActionError() {
        actionError = nil
    }

    private func requestAutomaticRepairIfNeeded(now: Date) {
        guard AutomaticRepairPolicy.shouldRequestRepair(
            snapshot: snapshot,
            routingState: routingState
        ) else {
            repairConditionSince = nil
            return
        }

        guard let repairConditionSince else {
            self.repairConditionSince = now
            return
        }
        guard now.timeIntervalSince(repairConditionSince) >= automaticRepairGracePeriod else {
            return
        }
        if let lastRepairRequestedAt,
           now.timeIntervalSince(lastRepairRequestedAt) < automaticRepairCooldown {
            return
        }

        do {
            try routingController.requestRepair()
            lastRepairRequestedAt = now
            routingState = .repairing
        } catch {
            // A dead watchdog is surfaced by readState as unsafeActive. Never
            // replace a prompt-free repair with a surprise authorization dialog.
            self.repairConditionSince = nil
        }
    }
}
