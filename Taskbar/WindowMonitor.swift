import AppKit
import ApplicationServices
import OSLog

private func windowMonitorAccessibilityCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<WindowMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.handleAccessibilityEvent(element: element, notification: notification)
}

final class WindowMonitor {
    var onChange: ((TaskbarState) -> Void)?

    private struct DisplaySpaceContext: Hashable {
        let displayIdentifier: CGDirectDisplayID
        let spaceIdentifier: DesktopSpaceProvider.SpaceIdentifier
    }

    private struct PendingWindowPlacement {
        var displayIdentifier: CGDirectDisplayID
        let requestedAt: Date
        let existingWindowIdentifiers: Set<CGWindowID>
        var allowsExistingWindowFallback: Bool
        var presentationIsSuppressed: Bool
    }

    private let provider = AccessibilityWindowProvider()
    private let pinnedStore = PinnedApplicationStore()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Taskbar",
        category: "ApplicationLaunch"
    )
    private let layoutLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Taskbar",
        category: "WindowLayout"
    )
    private var timer: Timer?
    private var isStarted = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var accessibilityObservers: [pid_t: AXObserver] = [:]
    private var accessibilityRefreshScheduled = false
    private var accessibilityRetryGeneration: UInt = 0
    private var reservedWorkAreasByDisplay: [CGDirectDisplayID: ReservedWorkArea] = [:]
    private var manuallyPositionedWindowIdentifiers: Set<CGWindowID> = []
    private var activeSpaceIdentifiersByDisplay: [
        CGDirectDisplayID: DesktopSpaceProvider.SpaceIdentifier
    ] = [:]
    private var applicationOrdersByContext: [
        DisplaySpaceContext: [ApplicationIdentity]
    ] = [:]
    private var runningApplicationsByIdentity: [ApplicationIdentity: [NSRunningApplication]] = [:]
    private var currentWindowsByDisplay: [
        CGDirectDisplayID: [ApplicationIdentity: [WindowSnapshot]]
    ] = [:]
    private var currentWindowIdentifiersByIdentity: [
        ApplicationIdentity: Set<CGWindowID>
    ] = [:]
    private var lastItemsByIdentity: [ApplicationIdentity: TaskbarApplicationItem] = [:]
    private var windowOrderByProcess: [pid_t: [AXUIElement]] = [:]
    private var noWindowSinceByIdentity: [ApplicationIdentity: Date] = [:]
    private var lastTerminationRequestByIdentity: [ApplicationIdentity: Date] = [:]
    private var pendingLaunchesByIdentity: [ApplicationIdentity: Date] = [:]
    private var observedLaunchProcessByIdentity: [ApplicationIdentity: pid_t] = [:]
    private var coldLaunchWindowCommandByIdentity: [ApplicationIdentity: Date] = [:]
    private var launchIndicatorStartedAtByIdentity: [ApplicationIdentity: Date] = [:]
    private var launchApplicationsByIdentity: [ApplicationIdentity: NSRunningApplication] = [:]
    private var launchDisplayByIdentity: [ApplicationIdentity: CGDirectDisplayID] = [:]
    private var pendingWindowPlacementsByIdentity: [
        ApplicationIdentity: PendingWindowPlacement
    ] = [:]
    private let savedGroupOrderKey = "behavior.applicationGroupOrder.v2"
    private let legacyGroupOrderKey = "behavior.applicationGroupOrder"
    private let windowlessTerminationDelay: TimeInterval = 2
    private let pendingLaunchTimeout: TimeInterval = 30
    private let launchProcessObservationTimeout: TimeInterval = 5
    private let existingWindowPlacementFallbackDelay: TimeInterval = 0.8
    private let windowPlacementTimeout: TimeInterval = 8
    private let terminationRetryDelay: TimeInterval = 8
    private let terminationExclusions: Set<String> = ["com.apple.finder"]

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.willLaunchApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]

        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleWorkspaceNotification(notification)
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.25
        refresh()
    }

    private func handleWorkspaceNotification(_ notification: Notification) {
        if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
           let identity = identity(for: application) {
            if notification.name == NSWorkspace.willLaunchApplicationNotification,
               application.activationPolicy == .regular {
                installAccessibilityObserverIfNeeded(for: application)
                beginLaunchIndicator(for: identity, application: application)
            } else if notification.name == NSWorkspace.didLaunchApplicationNotification,
                      application.activationPolicy == .regular {
                installAccessibilityObserverIfNeeded(for: application)
                beginLaunchIndicator(for: identity, application: application)
            }

            if notification.name == NSWorkspace.didLaunchApplicationNotification,
               let requestedAt = pendingLaunchesByIdentity[identity] {
                observedLaunchProcessByIdentity[identity] = application.processIdentifier
                logger.notice(
                    "Workspace observed launched application \(identity.identifier, privacy: .public), pid=\(application.processIdentifier)"
                )
                scheduleColdLaunchWindowRecovery(
                    identity: identity,
                    application: application,
                    requestedAt: requestedAt
                )
            } else if notification.name == NSWorkspace.didTerminateApplicationNotification {
                cancelWindowPlacement(for: identity)
                coldLaunchWindowCommandByIdentity.removeValue(forKey: identity)
                if observedLaunchProcessByIdentity[identity] == application.processIdentifier {
                    pendingLaunchesByIdentity.removeValue(forKey: identity)
                    observedLaunchProcessByIdentity.removeValue(forKey: identity)
                    logger.error(
                        "Launched application terminated before creating a window: \(identity.identifier, privacy: .public), pid=\(application.processIdentifier)"
                    )
                }
                if launchApplicationsByIdentity[identity]?.processIdentifier
                    == application.processIdentifier {
                    clearLaunchIndicator(for: identity)
                }
            }
        }
        refresh()
    }

    func stop() {
        isStarted = false
        accessibilityRetryGeneration &+= 1
        timer?.invalidate()
        timer = nil
        let pendingIdentities = Array(pendingWindowPlacementsByIdentity.keys)
        pendingIdentities.forEach(cancelWindowPlacement)
        removeAllAccessibilityObservers()

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    func refresh() {
        let trusted = provider.isTrusted
        removeExpiredLaunchStates()
        let displayIdentifiers = orderedDisplayIdentifiers()
        let displayIdentifierSet = Set(displayIdentifiers)
        activeSpaceIdentifiersByDisplay = Dictionary(
            uniqueKeysWithValues: displayIdentifiers.map { displayIdentifier in
                (
                    displayIdentifier,
                    provider.currentSpaceIdentifier(
                        forDisplayIdentifier: displayIdentifier
                    )
                )
            }
        )
        if let fallbackDisplayIdentifier = displayIdentifiers.first {
            for identity in launchIndicatorStartedAtByIdentity.keys
            where launchDisplayByIdentity[identity].map({
                !displayIdentifierSet.contains($0)
            }) ?? true {
                launchDisplayByIdentity[identity] = fallbackDisplayIdentifier
            }
        }
        let runningApplications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }

        if trusted {
            provider.refreshWindowCatalog()
            synchronizeAccessibilityObservers(with: runningApplications)
        } else {
            removeAllAccessibilityObservers()
        }

        var runningByIdentity: [ApplicationIdentity: [NSRunningApplication]] = [:]
        var runningIdentityOrder: [ApplicationIdentity] = []
        for application in runningApplications {
            guard let identity = identity(for: application) else { continue }
            if runningByIdentity[identity] == nil {
                runningIdentityOrder.append(identity)
            }
            runningByIdentity[identity, default: []].append(application)
        }
        let runningProcessIDs = Set(runningApplications.map(\.processIdentifier))
        windowOrderByProcess = windowOrderByProcess.filter { runningProcessIDs.contains($0.key) }

        var allWindowsByIdentity: [ApplicationIdentity: [WindowSnapshot]] = [:]
        if trusted {
            for identity in runningIdentityOrder {
                allWindowsByIdentity[identity] = runningByIdentity[identity, default: []]
                    .flatMap(stableWindows(for:))
            }
            if let globalWindowProcessIDs = provider.processIdentifiersWithUserWindows() {
                terminateWindowlessApplications(
                    runningByIdentity: runningByIdentity,
                    windowsByIdentity: allWindowsByIdentity,
                    globalWindowProcessIDs: globalWindowProcessIDs
                )
            } else {
                noWindowSinceByIdentity.removeAll()
                lastTerminationRequestByIdentity.removeAll()
            }
        } else {
            noWindowSinceByIdentity.removeAll()
            lastTerminationRequestByIdentity.removeAll()
        }
        provider.pruneWindowStates(
            keeping: allWindowsByIdentity.values.flatMap { $0 }
        )
        currentWindowIdentifiersByIdentity = allWindowsByIdentity.mapValues { windows in
            Set(windows.compactMap { provider.windowIdentifier(for: $0.element) })
        }
        applyPendingWindowPlacements(to: allWindowsByIdentity)
        let liveWindowIdentifiers = Set(
            allWindowsByIdentity.values
                .flatMap { $0 }
                .compactMap { provider.windowIdentifier(for: $0.element) }
        )
        manuallyPositionedWindowIdentifiers.formIntersection(liveWindowIdentifiers)
        runningApplicationsByIdentity = runningByIdentity

        let globalLaunchIdentityOrder = launchIndicatorStartedAtByIdentity
            .sorted { $0.value < $1.value }
            .map(\.key)
        let pinnedRecords = pinnedStore.records
        currentWindowsByDisplay.removeAll(keepingCapacity: true)
        lastItemsByIdentity.removeAll(keepingCapacity: true)

        for displayIdentifier in displayIdentifiers {
            let spaceIdentifier = activeSpaceIdentifiersByDisplay[displayIdentifier] ?? 0
            let context = DisplaySpaceContext(
                displayIdentifier: displayIdentifier,
                spaceIdentifier: spaceIdentifier
            )
            let windowsByIdentity = allWindowsByIdentity.mapValues { windows in
                windows.filter { snapshot in
                    window(snapshot, belongsTo: displayIdentifier, among: displayIdentifiers)
                        && snapshot.spaceIdentifiers.contains(spaceIdentifier)
                }
            }
            currentWindowsByDisplay[displayIdentifier] = windowsByIdentity

            let isFullScreenActive = windowsByIdentity.values.contains { windows in
                windows.contains { snapshot in
                    snapshot.isFullScreen == true
                }
            }
            if !isFullScreenActive,
               let reservedWorkArea = reservedWorkAreasByDisplay[displayIdentifier] {
                enforceReservedWorkArea(
                    on: windowsByIdentity.values.flatMap { $0 },
                    reservedWorkArea: reservedWorkArea,
                    activeSpaceIdentifier: spaceIdentifier
                )
            }

            let items = taskbarItems(
                for: context,
                windowsByIdentity: windowsByIdentity,
                runningByIdentity: runningByIdentity,
                runningIdentityOrder: runningIdentityOrder,
                pinnedRecords: pinnedRecords,
                globalLaunchIdentityOrder: globalLaunchIdentityOrder
            )
            for item in items {
                if let existing = lastItemsByIdentity[item.identity],
                   existing.windows.count >= item.windows.count {
                    continue
                }
                lastItemsByIdentity[item.identity] = item
            }
            onChange?(
                TaskbarState(
                    displayIdentifier: displayIdentifier,
                    isAccessibilityTrusted: trusted,
                    spaceIdentifier: spaceIdentifier,
                    isFullScreenActive: isFullScreenActive,
                    applications: items
                )
            )
        }
    }

    private func taskbarItems(
        for context: DisplaySpaceContext,
        windowsByIdentity: [ApplicationIdentity: [WindowSnapshot]],
        runningByIdentity: [ApplicationIdentity: [NSRunningApplication]],
        runningIdentityOrder: [ApplicationIdentity],
        pinnedRecords: [PinnedApplicationRecord],
        globalLaunchIdentityOrder: [ApplicationIdentity]
    ) -> [TaskbarApplicationItem] {
        let visibleRunningIdentityOrder = runningIdentityOrder.filter {
            windowsByIdentity[$0]?.isEmpty == false
        }
        let visibleRunningByIdentity = runningByIdentity.filter {
            windowsByIdentity[$0.key]?.isEmpty == false
        }
        let launchIdentityOrder = globalLaunchIdentityOrder.filter {
            launchDisplayByIdentity[$0] == context.displayIdentifier
        }
        let taskbarRunningIdentityOrder = (
            visibleRunningIdentityOrder + launchIdentityOrder
        ).reduce(into: [ApplicationIdentity]()) { identities, identity in
            if !identities.contains(identity) {
                identities.append(identity)
            }
        }

        let pinnedIdentities = Set(pinnedRecords.map(\.identity))
        let launchingIdentities = Set(launchIdentityOrder)
        let validIdentities = Set(visibleRunningIdentityOrder)
            .union(pinnedIdentities)
            .union(launchingIdentities)
        var applicationOrder = applicationOrdersByContext[context] ?? []
        applicationOrder.removeAll { !validIdentities.contains($0) }

        if applicationOrder.isEmpty {
            applicationOrder = pinnedRecords.map(\.identity)
            let savedOrder = UserDefaults.standard.stringArray(
                forKey: savedGroupOrderKey(for: context)
            ) ?? UserDefaults.standard.stringArray(
                forKey: legacySavedGroupOrderKey(for: context.spaceIdentifier)
            ) ?? UserDefaults.standard.stringArray(forKey: savedGroupOrderKey) ?? []
            let legacyOrder = UserDefaults.standard.stringArray(
                forKey: legacyGroupOrderKey
            ) ?? []
            let savedIndexes = Dictionary(
                uniqueKeysWithValues: savedOrder.enumerated().map { ($0.element, $0.offset) }
            )
            let legacyIndexes = Dictionary(
                uniqueKeysWithValues: legacyOrder.enumerated().map { ($0.element, $0.offset) }
            )
            let unpinnedRunning = taskbarRunningIdentityOrder
                .filter { !pinnedIdentities.contains($0) }
                .sorted { lhs, rhs in
                    let lhsIndex = savedIndexes[lhs.identifier]
                        ?? lhs.bundleIdentifier.flatMap { legacyIndexes[$0] }
                    let rhsIndex = savedIndexes[rhs.identifier]
                        ?? rhs.bundleIdentifier.flatMap { legacyIndexes[$0] }
                    switch (lhsIndex, rhsIndex) {
                    case let (.some(left), .some(right)): return left < right
                    case (.some, .none): return true
                    case (.none, .some): return false
                    case (.none, .none):
                        return launchDate(for: lhs, in: runningByIdentity)
                            < launchDate(for: rhs, in: runningByIdentity)
                    }
                }
            applicationOrder.append(contentsOf: unpinnedRunning)
        } else {
            for (index, record) in pinnedRecords.enumerated()
            where !applicationOrder.contains(record.identity) {
                applicationOrder.insert(
                    record.identity,
                    at: min(index, applicationOrder.count)
                )
            }

            let newRunningIdentities = taskbarRunningIdentityOrder
                .filter { !applicationOrder.contains($0) }
                .sorted {
                    taskbarAppearanceDate(for: $0, in: runningByIdentity)
                        < taskbarAppearanceDate(for: $1, in: runningByIdentity)
                }
            applicationOrder.append(contentsOf: newRunningIdentities)
        }
        applicationOrdersByContext[context] = applicationOrder

        let pinnedByIdentity = Dictionary(
            uniqueKeysWithValues: pinnedRecords.map { ($0.identity, $0) }
        )
        return applicationOrder.compactMap { orderedIdentity in
            let isLaunching = launchIndicatorStartedAtByIdentity[orderedIdentity] != nil
                && launchDisplayByIdentity[orderedIdentity] == context.displayIdentifier
            let applications = isLaunching
                ? (runningByIdentity[orderedIdentity] ?? [])
                : (visibleRunningByIdentity[orderedIdentity] ?? [])
            let launchApplication = launchApplicationsByIdentity[orderedIdentity]
            let pinnedRecord = pinnedByIdentity[orderedIdentity]
            guard !applications.isEmpty || pinnedRecord != nil || isLaunching else {
                return nil
            }

            let currentIdentity = applications.first.flatMap(identity(for:))
                ?? launchApplication.flatMap(identity(for:))
                ?? pinnedRecord?.identity
                ?? orderedIdentity
            let applicationURL = applications.first?.bundleURL
                ?? launchApplication?.bundleURL
                ?? resolveApplicationURL(for: currentIdentity)
            let displayName = applications.first?.localizedName
                ?? launchApplication?.localizedName
                ?? pinnedRecord?.displayName
                ?? applicationURL?.deletingPathExtension().lastPathComponent
                ?? L10n.text("app.fallback_name", fallback: "Application")
            let icon = applications.first?.icon?.copy() as? NSImage
                ?? launchApplication?.icon?.copy() as? NSImage
                ?? applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }

            return TaskbarApplicationItem(
                identity: currentIdentity,
                displayName: displayName,
                applicationURL: applicationURL,
                icon: icon,
                isPinned: pinnedRecord != nil,
                isLaunching: isLaunching,
                runningApplications: applications,
                windows: windowsByIdentity[orderedIdentity] ?? []
            )
        }
    }

    func requestPermission() {
        provider.requestPermission()
    }

    func updateReservedWorkArea(
        _ workArea: ReservedWorkArea?,
        for displayIdentifier: CGDirectDisplayID
    ) {
        guard reservedWorkAreasByDisplay[displayIdentifier] != workArea else {
            return
        }
        if let workArea {
            reservedWorkAreasByDisplay[displayIdentifier] = workArea
        } else {
            reservedWorkAreasByDisplay.removeValue(forKey: displayIdentifier)
            activeSpaceIdentifiersByDisplay.removeValue(forKey: displayIdentifier)
            currentWindowsByDisplay.removeValue(forKey: displayIdentifier)
        }
        scheduleAccessibilityRefresh()
        scheduleAccessibilityRefreshRetries()
    }

    func pinApplication(
        _ identity: ApplicationIdentity,
        on displayIdentifier: CGDirectDisplayID
    ) {
        guard let item = lastItemsByIdentity[identity] else { return }
        pinnedStore.pin(identity: item.identity, displayName: item.displayName)
        if let context = context(for: displayIdentifier) {
            var applicationOrder = applicationOrdersByContext[context] ?? []
            if !applicationOrder.contains(item.identity) {
                applicationOrder.append(item.identity)
            }
            applicationOrdersByContext[context] = applicationOrder
            saveApplicationGroupOrder(for: context)
        }
        refresh()
    }

    func unpinApplication(_ identity: ApplicationIdentity) {
        pinnedStore.unpin(identity)
        if runningApplicationsByIdentity[identity]?.isEmpty != false {
            for context in Array(applicationOrdersByContext.keys) {
                applicationOrdersByContext[context]?.removeAll { $0 == identity }
                saveApplicationGroupOrder(for: context)
            }
        }
        refresh()
    }

    func launchApplication(
        _ identity: ApplicationIdentity,
        on displayIdentifier: CGDirectDisplayID
    ) {
        logger.notice(
            "Pinned launch requested for \(identity.identifier, privacy: .public)"
        )
        if let runningApplication = runningApplicationsByIdentity[identity]?
            .first(where: { !$0.isTerminated }) {
            if let requestedAt = pendingLaunchesByIdentity[identity],
               Date().timeIntervalSince(requestedAt) < pendingLaunchTimeout {
                beginWindowPlacement(
                    for: identity,
                    on: displayIdentifier,
                    allowsExistingWindowFallback: true
                )
                logger.debug(
                    "Launch is still pending for \(identity.identifier, privacy: .public)"
                )
                return
            }

            if currentWindowsByDisplay[displayIdentifier]?[identity]?.isEmpty == false {
                logger.notice(
                    "Activating existing window for \(identity.identifier, privacy: .public), pid=\(runningApplication.processIdentifier)"
                )
                runningApplication.activate(
                    options: [.activateAllWindows, .activateIgnoringOtherApps]
                )
            } else {
                logger.notice(
                    "Running application has no window on the active Space: \(identity.identifier, privacy: .public), pid=\(runningApplication.processIdentifier)"
                )
                requestNewWindow(
                    identity,
                    on: displayIdentifier,
                    allowsExistingWindowFallback: true
                )
            }
            return
        }

        if let requestedAt = pendingLaunchesByIdentity[identity],
           Date().timeIntervalSince(requestedAt) < pendingLaunchTimeout {
            beginWindowPlacement(
                for: identity,
                on: displayIdentifier,
                allowsExistingWindowFallback: false
            )
            logger.debug(
                "Ignoring duplicate cold launch request for \(identity.identifier, privacy: .public)"
            )
            return
        }

        guard let applicationURL = resolveApplicationURL(for: identity) else {
            logger.error(
                "Application URL could not be resolved for \(identity.identifier, privacy: .public)"
            )
            NSSound.beep()
            return
        }

        let requestedAt = Date()
        pendingLaunchesByIdentity[identity] = requestedAt
        coldLaunchWindowCommandByIdentity.removeValue(forKey: identity)
        beginWindowPlacement(
            for: identity,
            on: displayIdentifier,
            allowsExistingWindowFallback: false
        )
        beginLaunchIndicator(
            for: identity,
            displayIdentifier: displayIdentifier,
            startedAt: requestedAt
        )
        refresh()
        logger.notice(
            "Cold launch requested for \(identity.identifier, privacy: .public) at \(applicationURL.path, privacy: .public)"
        )
        performColdLaunch(
            identity: identity,
            applicationURL: applicationURL
        )
    }

    private func performColdLaunch(
        identity: ApplicationIdentity,
        applicationURL: URL
    ) {
        let requestedAt = pendingLaunchesByIdentity[identity] ?? Date()
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = [applicationURL.path]
        launcher.environment = cleanDesktopLaunchEnvironment()
        launcher.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        launcher.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                if process.terminationStatus == 0 {
                    self.logger.notice(
                        "Clean desktop launch submitted for \(identity.identifier, privacy: .public)"
                    )
                    return
                }

                guard self.pendingLaunchesByIdentity[identity] == requestedAt else {
                    return
                }
                self.pendingLaunchesByIdentity.removeValue(forKey: identity)
                self.observedLaunchProcessByIdentity.removeValue(forKey: identity)
                self.cancelWindowPlacement(for: identity)
                self.clearLaunchIndicator(for: identity)
                self.refresh()
                self.logger.error(
                    "Desktop launcher failed for \(identity.identifier, privacy: .public), status=\(process.terminationStatus)"
                )
                NSSound.beep()
            }
        }

        do {
            try launcher.run()
            logger.notice(
                "Clean desktop launch helper started for \(identity.identifier, privacy: .public), pid=\(launcher.processIdentifier)"
            )
            scheduleLaunchProcessObservation(
                identity: identity,
                requestedAt: requestedAt
            )
        } catch {
            pendingLaunchesByIdentity.removeValue(forKey: identity)
            observedLaunchProcessByIdentity.removeValue(forKey: identity)
            cancelWindowPlacement(for: identity)
            clearLaunchIndicator(for: identity)
            refresh()
            logger.error(
                "Desktop launcher could not start for \(identity.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            NSSound.beep()
        }
    }

    private func cleanDesktopLaunchEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let preservedKeys = [
            "HOME",
            "USER",
            "LOGNAME",
            "TMPDIR",
            "SHELL",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "SSH_AUTH_SOCK",
            "__CF_USER_TEXT_ENCODING"
        ]
        var environment = preservedKeys.reduce(into: [String: String]()) { result, key in
            if let value = source[key], !value.isEmpty {
                result[key] = value
            }
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }

    private func scheduleLaunchProcessObservation(
        identity: ApplicationIdentity,
        requestedAt: Date
    ) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + launchProcessObservationTimeout
        ) { [weak self] in
            guard let self,
                  self.pendingLaunchesByIdentity[identity] == requestedAt else {
                return
            }

            if let application = NSWorkspace.shared.runningApplications.first(where: {
                !$0.isTerminated && self.identity(for: $0) == identity
            }) {
                self.observedLaunchProcessByIdentity[identity] = application.processIdentifier
                self.logger.notice(
                    "Cold-launch process observed for \(identity.identifier, privacy: .public), pid=\(application.processIdentifier)"
                )
                application.activate(
                    options: [.activateAllWindows, .activateIgnoringOtherApps]
                )
                self.scheduleColdLaunchWindowRecovery(
                    identity: identity,
                    application: application,
                    requestedAt: requestedAt
                )
                self.refresh()
                return
            }

            self.pendingLaunchesByIdentity.removeValue(forKey: identity)
            self.observedLaunchProcessByIdentity.removeValue(forKey: identity)
            self.cancelWindowPlacement(for: identity)
            self.clearLaunchIndicator(for: identity)
            self.refresh()
            self.logger.error(
                "No application process appeared after clean launch for \(identity.identifier, privacy: .public)"
            )
        }
    }

    private func scheduleColdLaunchWindowRecovery(
        identity: ApplicationIdentity,
        application: NSRunningApplication,
        requestedAt: Date
    ) {
        let retryDelays: [TimeInterval] = [0.8, 1.5, 2.5, 4.0]
        for (index, delay) in retryDelays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.isStarted,
                      self.pendingLaunchesByIdentity[identity] == requestedAt,
                      self.coldLaunchWindowCommandByIdentity[identity] != requestedAt,
                      !application.isTerminated else {
                    return
                }

                self.refresh()
                guard self.currentWindowIdentifiersByIdentity[identity]?.isEmpty
                        != false else {
                    return
                }
                guard application.isFinishedLaunching else { return }

                if self.performNewWindowMenuAction(
                    for: application,
                    beforePress: {}
                ) {
                    self.coldLaunchWindowCommandByIdentity[identity] = requestedAt
                    self.logger.notice(
                        "Requested first window after windowless cold launch for \(identity.identifier, privacy: .public), pid=\(application.processIdentifier)"
                    )
                    self.scheduleAccessibilityRefreshRetries()
                    return
                }

                guard index == retryDelays.count - 1 else { return }
                self.coldLaunchWindowCommandByIdentity[identity] = requestedAt
                application.activate(options: [.activateIgnoringOtherApps])
                self.postStandardNewWindowShortcut(
                    to: application.processIdentifier
                )
                self.logger.notice(
                    "Used New Window shortcut after windowless cold launch for \(identity.identifier, privacy: .public), pid=\(application.processIdentifier)"
                )
            }
        }
    }

    func openNewWindow(
        _ identity: ApplicationIdentity,
        on displayIdentifier: CGDirectDisplayID
    ) {
        requestNewWindow(
            identity,
            on: displayIdentifier,
            allowsExistingWindowFallback: false
        )
    }

    private func requestNewWindow(
        _ identity: ApplicationIdentity,
        on displayIdentifier: CGDirectDisplayID,
        allowsExistingWindowFallback: Bool
    ) {
        guard let runningApplication = runningApplicationsByIdentity[identity]?
            .first(where: { !$0.isTerminated }) else {
            launchApplication(identity, on: displayIdentifier)
            return
        }

        beginWindowPlacement(
            for: identity,
            on: displayIdentifier,
            allowsExistingWindowFallback: false
        )

        if performNewWindowMenuAction(
            for: runningApplication,
            beforePress: { [weak self] in
                self?.suppressWindowPresentation(for: identity)
            }
        ) {
            logger.notice(
                "New Window menu action accepted for \(identity.identifier, privacy: .public), pid=\(runningApplication.processIdentifier)"
            )
            return
        }
        releaseWindowPresentationSuppression(for: identity)

        if allowsExistingWindowFallback,
           var pending = pendingWindowPlacementsByIdentity[identity] {
            pending.allowsExistingWindowFallback = true
            pendingWindowPlacementsByIdentity[identity] = pending
        }

        suppressWindowPresentation(for: identity)
        postStandardNewWindowShortcut(
            to: runningApplication.processIdentifier
        )
    }

    func moveApplicationGroup(
        from sourceIdentity: ApplicationIdentity,
        relativeTo targetIdentity: ApplicationIdentity,
        insertAfter: Bool,
        on displayIdentifier: CGDirectDisplayID
    ) {
        guard let context = context(for: displayIdentifier) else { return }
        var applicationOrder = applicationOrdersByContext[context] ?? []
        guard sourceIdentity != targetIdentity,
              let sourceIndex = applicationOrder.firstIndex(of: sourceIdentity) else {
            return
        }

        applicationOrder.remove(at: sourceIndex)
        guard let targetIndex = applicationOrder.firstIndex(of: targetIdentity) else {
            applicationOrder.insert(sourceIdentity, at: min(sourceIndex, applicationOrder.count))
            applicationOrdersByContext[context] = applicationOrder
            return
        }

        let insertionIndex = targetIndex + (insertAfter ? 1 : 0)
        applicationOrder.insert(sourceIdentity, at: insertionIndex)
        applicationOrdersByContext[context] = applicationOrder
        saveApplicationGroupOrder(for: context)
        refresh()
    }

    private func identity(for application: NSRunningApplication) -> ApplicationIdentity? {
        guard let applicationURL = application.bundleURL ?? application.executableURL else {
            return nil
        }
        return ApplicationIdentity(
            bundleIdentifier: application.bundleIdentifier,
            applicationURL: applicationURL
        )
    }

    private func resolveApplicationURL(for identity: ApplicationIdentity) -> URL? {
        let storedURL = URL(fileURLWithPath: identity.applicationPath)
        if FileManager.default.fileExists(atPath: storedURL.path) {
            return storedURL
        }
        if let bundleIdentifier = identity.bundleIdentifier {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
        return nil
    }

    private func launchDate(
        for identity: ApplicationIdentity,
        in applicationsByIdentity: [ApplicationIdentity: [NSRunningApplication]]
    ) -> Date {
        applicationsByIdentity[identity]?
            .compactMap(\.launchDate)
            .min() ?? .distantPast
    }

    private func taskbarAppearanceDate(
        for identity: ApplicationIdentity,
        in applicationsByIdentity: [ApplicationIdentity: [NSRunningApplication]]
    ) -> Date {
        launchIndicatorStartedAtByIdentity[identity]
            ?? launchDate(for: identity, in: applicationsByIdentity)
    }

    private func beginLaunchIndicator(
        for identity: ApplicationIdentity,
        application: NSRunningApplication? = nil,
        displayIdentifier: CGDirectDisplayID? = nil,
        startedAt: Date = Date()
    ) {
        if launchIndicatorStartedAtByIdentity[identity] == nil {
            launchIndicatorStartedAtByIdentity[identity] = startedAt
        }
        if launchDisplayByIdentity[identity] == nil,
           let displayIdentifier = displayIdentifier ?? preferredDisplayIdentifier() {
            launchDisplayByIdentity[identity] = displayIdentifier
        }
        if let application {
            launchApplicationsByIdentity[identity] = application
        }
    }

    private func clearLaunchIndicator(for identity: ApplicationIdentity) {
        launchIndicatorStartedAtByIdentity.removeValue(forKey: identity)
        launchApplicationsByIdentity.removeValue(forKey: identity)
        launchDisplayByIdentity.removeValue(forKey: identity)
    }

    private func beginWindowPlacement(
        for identity: ApplicationIdentity,
        on displayIdentifier: CGDirectDisplayID,
        allowsExistingWindowFallback: Bool
    ) {
        let requestedAt: Date
        if var pending = pendingWindowPlacementsByIdentity[identity],
           Date().timeIntervalSince(pending.requestedAt) < windowPlacementTimeout {
            pending.displayIdentifier = displayIdentifier
            pending.allowsExistingWindowFallback =
                pending.allowsExistingWindowFallback || allowsExistingWindowFallback
            pendingWindowPlacementsByIdentity[identity] = pending
            requestedAt = pending.requestedAt
        } else {
            let pending = PendingWindowPlacement(
                displayIdentifier: displayIdentifier,
                requestedAt: Date(),
                existingWindowIdentifiers: currentWindowIdentifiersByIdentity[identity] ?? [],
                allowsExistingWindowFallback: allowsExistingWindowFallback,
                presentationIsSuppressed: false
            )
            pendingWindowPlacementsByIdentity[identity] = pending
            requestedAt = pending.requestedAt
        }
        scheduleAccessibilityRefreshRetries()
        scheduleWindowPlacementRefreshes(
            for: identity,
            requestedAt: requestedAt
        )
    }

    private func cancelWindowPlacement(for identity: ApplicationIdentity) {
        guard let placement = pendingWindowPlacementsByIdentity.removeValue(
            forKey: identity
        ) else {
            return
        }
        if placement.presentationIsSuppressed {
            provider.endWindowPresentationSuppression()
        }
    }

    private func suppressWindowPresentation(for identity: ApplicationIdentity) {
        guard var placement = pendingWindowPlacementsByIdentity[identity],
              !placement.presentationIsSuppressed,
              provider.beginWindowPresentationSuppression() else {
            return
        }
        placement.presentationIsSuppressed = true
        pendingWindowPlacementsByIdentity[identity] = placement

        // An already-running application normally creates a new window within
        // a few frames. Probe densely so presentation resumes as soon as that
        // window has its final display, without changing the app's launch time.
        for delay in [0.016, 0.04, 0.08, 0.16, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.isStarted,
                      self.pendingWindowPlacementsByIdentity[identity]?
                        .requestedAt == placement.requestedAt,
                      self.pendingWindowPlacementsByIdentity[identity]?
                        .presentationIsSuppressed == true else {
                    return
                }
                self.refresh()
            }
        }

        // Never leave WindowServer presentation held if an application ignores
        // its New Window command or takes an unexpectedly different code path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self,
                  self.pendingWindowPlacementsByIdentity[identity]?
                    .requestedAt == placement.requestedAt else {
                return
            }
            self.releaseWindowPresentationSuppression(for: identity)
        }
    }

    private func releaseWindowPresentationSuppression(
        for identity: ApplicationIdentity
    ) {
        guard var placement = pendingWindowPlacementsByIdentity[identity],
              placement.presentationIsSuppressed else {
            return
        }
        placement.presentationIsSuppressed = false
        pendingWindowPlacementsByIdentity[identity] = placement
        provider.endWindowPresentationSuppression()
    }

    private func scheduleWindowPlacementRefreshes(
        for identity: ApplicationIdentity,
        requestedAt: Date
    ) {
        for delay in [0.85, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.isStarted,
                      self.pendingWindowPlacementsByIdentity[identity]?.requestedAt
                        == requestedAt else {
                    return
                }
                self.refresh()
            }
        }
    }

    private func applyPendingWindowPlacements(
        to windowsByIdentity: [ApplicationIdentity: [WindowSnapshot]]
    ) {
        let now = Date()
        let connectedDisplayIdentifiers = Set(orderedDisplayIdentifiers())
        for (identity, placement) in pendingWindowPlacementsByIdentity {
            guard now.timeIntervalSince(placement.requestedAt) < windowPlacementTimeout,
                  connectedDisplayIdentifiers.contains(placement.displayIdentifier),
                  let targetFrame = targetWindowFrame(
                    for: placement.displayIdentifier
                  ) else {
                cancelWindowPlacement(for: identity)
                continue
            }

            let windows = windowsByIdentity[identity] ?? []
            let newlyCreatedWindows = windows.filter { window in
                guard let identifier = provider.windowIdentifier(for: window.element) else {
                    return false
                }
                return !placement.existingWindowIdentifiers.contains(identifier)
            }
            var candidate = newlyCreatedWindows.first(where: { $0.isFocused })
                ?? newlyCreatedWindows.last
            if candidate == nil,
               placement.allowsExistingWindowFallback,
               now.timeIntervalSince(placement.requestedAt)
                >= existingWindowPlacementFallbackDelay {
                candidate = windows.first(where: { $0.isFocused })
                    ?? windows.last
            }
            guard let candidate else { continue }

            let isOnTargetDisplay = candidate.displayIdentifier
                == placement.displayIdentifier
            let wasPlaced = isOnTargetDisplay || provider.moveWindow(
                candidate,
                to: targetFrame,
                on: placement.displayIdentifier
            )
            guard wasPlaced else { continue }

            cancelWindowPlacement(for: identity)
            activateWindow(candidate)
            logger.notice(
                "Placed window for \(identity.identifier, privacy: .public) on display \(placement.displayIdentifier)"
            )
            scheduleAccessibilityRefresh()
        }
    }

    private func targetWindowFrame(
        for displayIdentifier: CGDirectDisplayID
    ) -> CGRect? {
        if let usableFrame = reservedWorkAreasByDisplay[displayIdentifier]?.usableFrame {
            return usableFrame
        }
        return NSScreen.screens.first {
            self.displayIdentifier(for: $0) == displayIdentifier
        }?.visibleFrame
    }

    private func activateWindow(_ window: WindowSnapshot) {
        let applicationElement = AXUIElementCreateApplication(
            window.application.processIdentifier
        )
        if window.isMinimized {
            _ = AXUIElementSetAttributeValue(
                window.element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            window.element
        )
        _ = AXUIElementSetAttributeValue(
            window.element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            window.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementPerformAction(
            window.element,
            kAXRaiseAction as CFString
        )
        _ = window.application.unhide()
        _ = window.application.activate(options: [.activateIgnoringOtherApps])
    }

    private func orderedDisplayIdentifiers() -> [CGDirectDisplayID] {
        let screenIdentifiers = NSScreen.screens.compactMap(displayIdentifier(for:))
        let additionalIdentifiers = reservedWorkAreasByDisplay.keys.filter {
            !screenIdentifiers.contains($0)
        }
        return screenIdentifiers + additionalIdentifiers.sorted()
    }

    private func preferredDisplayIdentifier() -> CGDirectDisplayID? {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
        return screen.flatMap(displayIdentifier(for:))
    }

    private func displayIdentifier(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private func context(
        for displayIdentifier: CGDirectDisplayID
    ) -> DisplaySpaceContext? {
        guard let spaceIdentifier = activeSpaceIdentifiersByDisplay[displayIdentifier] else {
            return nil
        }
        return DisplaySpaceContext(
            displayIdentifier: displayIdentifier,
            spaceIdentifier: spaceIdentifier
        )
    }

    private func window(
        _ snapshot: WindowSnapshot,
        belongsTo displayIdentifier: CGDirectDisplayID,
        among displayIdentifiers: [CGDirectDisplayID]
    ) -> Bool {
        if let windowDisplayIdentifier = snapshot.displayIdentifier {
            return windowDisplayIdentifier == displayIdentifier
        }
        return displayIdentifiers.count == 1
            && displayIdentifiers.first == displayIdentifier
    }

    private func stableWindows(for application: NSRunningApplication) -> [WindowSnapshot] {
        let processID = application.processIdentifier
        let currentWindows = provider.windows(for: application)
        registerWindowDestructionNotifications(
            for: currentWindows,
            processID: processID
        )
        let previousOrder = windowOrderByProcess[processID] ?? []

        let retainedOrder = previousOrder.filter { previousElement in
            currentWindows.contains { CFEqual(previousElement, $0.element) }
        }
        let newWindows = currentWindows.filter { snapshot in
            !retainedOrder.contains { CFEqual($0, snapshot.element) }
        }
        let stableOrder = retainedOrder + newWindows.map(\.element)
        windowOrderByProcess[processID] = stableOrder

        return stableOrder.compactMap { orderedElement in
            currentWindows.first { CFEqual(orderedElement, $0.element) }
        }
    }

    private func performNewWindowMenuAction(
        for application: NSRunningApplication,
        beforePress: () -> Void
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let menuBar: AXUIElement = copyAccessibilityAttribute(
            kAXMenuBarAttribute as CFString,
            from: applicationElement
        ) else {
            return false
        }

        let preferredTitles = [
            "New Window",
            "New Finder Window",
            "Yeni Pencere",
            "Yeni Finder Penceresi"
        ]
        for title in preferredTitles {
            guard let menuItem = accessibilityMenuItem(
                titled: title,
                in: menuBar,
                remainingDepth: 8
            ) else {
                continue
            }
            let isEnabled: Bool = copyAccessibilityAttribute(
                kAXEnabledAttribute as CFString,
                from: menuItem
            ) ?? true
            guard isEnabled else { continue }
            beforePress()
            let result = AXUIElementPerformAction(
                menuItem,
                kAXPressAction as CFString
            )
            return result == .success
        }
        return false
    }

    private func accessibilityMenuItem(
        titled expectedTitle: String,
        in element: AXUIElement,
        remainingDepth: Int
    ) -> AXUIElement? {
        guard remainingDepth > 0 else { return nil }
        let title: String? = copyAccessibilityAttribute(
            kAXTitleAttribute as CFString,
            from: element
        )
        let role: String? = copyAccessibilityAttribute(
            kAXRoleAttribute as CFString,
            from: element
        )
        if role == (kAXMenuItemRole as String), title == expectedTitle {
            return element
        }

        let children: [AXUIElement] = copyAccessibilityAttribute(
            kAXChildrenAttribute as CFString,
            from: element
        ) ?? []
        for child in children {
            if let match = accessibilityMenuItem(
                titled: expectedTitle,
                in: child,
                remainingDepth: remainingDepth - 1
            ) {
                return match
            }
        }
        return nil
    }

    private func copyAccessibilityAttribute<T>(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }
        return value as? T
    }

    private func postStandardNewWindowShortcut(to processIdentifier: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0x2D,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0x2D,
                keyDown: false
              ) else {
            NSSound.beep()
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
    }

    private func terminateWindowlessApplications(
        runningByIdentity: [ApplicationIdentity: [NSRunningApplication]],
        windowsByIdentity: [ApplicationIdentity: [WindowSnapshot]],
        globalWindowProcessIDs: Set<pid_t>
    ) {
        let now = Date()
        let runningIdentities = Set(runningByIdentity.keys)
        noWindowSinceByIdentity = noWindowSinceByIdentity.filter {
            runningIdentities.contains($0.key)
        }
        lastTerminationRequestByIdentity = lastTerminationRequestByIdentity.filter {
            runningIdentities.contains($0.key)
        }

        for (identity, applications) in runningByIdentity {
            let hasWindowOnAnySpace = applications.contains {
                globalWindowProcessIDs.contains($0.processIdentifier)
            }
            let hasAcceptedTaskbarWindow = windowsByIdentity[identity]?.isEmpty == false
            if hasAcceptedTaskbarWindow {
                let wasTaskbarLaunch = pendingLaunchesByIdentity.removeValue(
                    forKey: identity
                ) != nil
                let wasShowingLaunchIndicator = launchIndicatorStartedAtByIdentity[
                    identity
                ] != nil
                clearLaunchIndicator(for: identity)
                coldLaunchWindowCommandByIdentity.removeValue(forKey: identity)
                if wasTaskbarLaunch {
                    observedLaunchProcessByIdentity.removeValue(forKey: identity)
                    logger.notice(
                        "First window observed for \(identity.identifier, privacy: .public)"
                    )
                    if pendingWindowPlacementsByIdentity[identity] == nil {
                        applications.first(where: { !$0.isTerminated })?.activate(
                            options: [.activateAllWindows, .activateIgnoringOtherApps]
                        )
                    }
                } else if wasShowingLaunchIndicator {
                    logger.notice(
                        "First externally launched window observed for \(identity.identifier, privacy: .public)"
                    )
                }
            }

            if hasWindowOnAnySpace || hasAcceptedTaskbarWindow {
                noWindowSinceByIdentity.removeValue(forKey: identity)
                lastTerminationRequestByIdentity.removeValue(forKey: identity)
                continue
            }

            if let launchStartedAt = launchIndicatorStartedAtByIdentity[identity],
               now.timeIntervalSince(launchStartedAt) < pendingLaunchTimeout {
                noWindowSinceByIdentity.removeValue(forKey: identity)
                lastTerminationRequestByIdentity.removeValue(forKey: identity)
                continue
            }

            if applications.contains(where: { !$0.isFinishedLaunching }) {
                noWindowSinceByIdentity.removeValue(forKey: identity)
                lastTerminationRequestByIdentity.removeValue(forKey: identity)
                continue
            }

            guard identity.bundleIdentifier.map({ !terminationExclusions.contains($0) }) ?? true else {
                noWindowSinceByIdentity.removeValue(forKey: identity)
                lastTerminationRequestByIdentity.removeValue(forKey: identity)
                continue
            }

            let noWindowSince = noWindowSinceByIdentity[identity] ?? now
            noWindowSinceByIdentity[identity] = noWindowSince
            guard now.timeIntervalSince(noWindowSince) >= windowlessTerminationDelay else {
                continue
            }

            if let lastRequest = lastTerminationRequestByIdentity[identity],
               now.timeIntervalSince(lastRequest) < terminationRetryDelay {
                continue
            }

            for application in applications where !application.isTerminated {
                logger.warning(
                    "Terminating windowless application \(identity.identifier, privacy: .public), pid=\(application.processIdentifier)"
                )
                _ = application.terminate()
            }
            lastTerminationRequestByIdentity[identity] = now
        }
    }

    private func removeExpiredLaunchStates() {
        let now = Date()
        let expiredIdentities = launchIndicatorStartedAtByIdentity.compactMap {
            identity,
            startedAt in
            now.timeIntervalSince(startedAt) >= pendingLaunchTimeout ? identity : nil
        }
        for identity in expiredIdentities {
            let wasTaskbarLaunch = pendingLaunchesByIdentity.removeValue(
                forKey: identity
            ) != nil
            observedLaunchProcessByIdentity.removeValue(forKey: identity)
            coldLaunchWindowCommandByIdentity.removeValue(forKey: identity)
            cancelWindowPlacement(for: identity)
            clearLaunchIndicator(for: identity)
            if wasTaskbarLaunch {
                logger.warning(
                    "Cold launch timed out before a window appeared for \(identity.identifier, privacy: .public)"
                )
            } else {
                logger.warning(
                    "External launch indicator timed out before a window appeared for \(identity.identifier, privacy: .public)"
                )
            }
        }
    }

    fileprivate func handleAccessibilityEvent(
        element: AXUIElement,
        notification: CFString
    ) {
        let notificationName = notification as String
        let settledGeometryNotifications = [
            kAXWindowMovedNotification as String,
            kAXWindowResizedNotification as String,
            kAXWindowDeminiaturizedNotification as String
        ]
        if settledGeometryNotifications.contains(notificationName) {
            if primaryMouseButtonIsPressed {
                if notificationName == (kAXWindowMovedNotification as String) {
                    _ = provider.restoreWindowForHeaderDrag(
                        element,
                        mouseLocation: NSEvent.mouseLocation
                    )
                }
                if let windowIdentifier = provider.windowIdentifier(for: element) {
                    manuallyPositionedWindowIdentifiers.insert(windowIdentifier)
                }
            }
            scheduleAccessibilityRefreshRetries()
            return
        }

        scheduleAccessibilityRefresh()
        let windowCreationNotifications = [
            kAXCreatedNotification as String,
            kAXWindowCreatedNotification as String
        ]
        if windowCreationNotifications.contains(notificationName) {
            positionNewlyCreatedWindowIfNeeded(element)
            scheduleAccessibilityRefreshRetries()
        }
    }

    private func positionNewlyCreatedWindowIfNeeded(_ element: AXUIElement) {
        var processIdentifier = pid_t.zero
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              let application = NSRunningApplication(
                processIdentifier: processIdentifier
              ),
              let identity = identity(for: application),
              let placement = pendingWindowPlacementsByIdentity[identity] else {
            return
        }
        logger.notice(
            "Accessibility creation event matched pending placement for \(identity.identifier, privacy: .public)"
        )
        if provider.positionNewlyCreatedWindowBeforePresentation(
            element,
            on: placement.displayIdentifier
        ) {
            logger.notice(
                "Atomically positioned newly created window for \(identity.identifier, privacy: .public) on display \(placement.displayIdentifier)"
            )
            scheduleAccessibilityRefresh()
            return
        }

        guard let targetFrame = targetWindowFrame(
                for: placement.displayIdentifier
              ) else {
            logger.error(
                "No target frame for early window placement on display \(placement.displayIdentifier)"
            )
            return
        }
        guard provider.moveNewlyCreatedWindow(
                element,
                to: targetFrame,
                on: placement.displayIdentifier
              ) else {
            logger.debug(
                "Created accessibility element was not yet a movable application window for \(identity.identifier, privacy: .public)"
            )
            return
        }
        logger.notice(
            "Positioned newly created window for \(identity.identifier, privacy: .public) before taskbar rendering on display \(placement.displayIdentifier)"
        )
        scheduleAccessibilityRefresh()
    }

    private func enforceReservedWorkArea(
        on windows: [WindowSnapshot],
        reservedWorkArea: ReservedWorkArea,
        activeSpaceIdentifier: DesktopSpaceProvider.SpaceIdentifier
    ) {
        guard reservedWorkArea.isEnabled,
              !primaryMouseButtonIsPressed else {
            return
        }

        let adjustedCount = windows.reduce(into: 0) { count, window in
            let windowIdentifier = provider.windowIdentifier(for: window.element)
            let policy: WindowConstraintPolicy = windowIdentifier.map {
                manuallyPositionedWindowIdentifiers.contains($0)
                    ? .systemArrangedOnly
                    : .everyOverlap
            } ?? .systemArrangedOnly
            if provider.constrainWindow(
                window,
                to: reservedWorkArea,
                activeSpaceIdentifier: activeSpaceIdentifier,
                policy: policy
            ) == .adjusted {
                count += 1
                if let windowIdentifier {
                    manuallyPositionedWindowIdentifiers.remove(windowIdentifier)
                }
            }
        }
        if adjustedCount > 0 {
            layoutLogger.debug(
                "Adjusted \(adjustedCount) window(s) to stay above the reserved taskbar area"
            )
        }
    }

    private var primaryMouseButtonIsPressed: Bool {
        NSEvent.pressedMouseButtons & 1 != 0
    }

    private func scheduleAccessibilityRefresh() {
        guard isStarted else { return }
        guard !accessibilityRefreshScheduled else { return }
        accessibilityRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.accessibilityRefreshScheduled = false
            self.refresh()
        }
    }

    private func scheduleAccessibilityRefreshRetries() {
        guard isStarted else { return }
        accessibilityRetryGeneration &+= 1
        let generation = accessibilityRetryGeneration

        for delay in [0.08, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.isStarted,
                      self.accessibilityRetryGeneration == generation else {
                    return
                }
                self.refresh()
            }
        }
    }

    private func synchronizeAccessibilityObservers(
        with applications: [NSRunningApplication]
    ) {
        let runningProcessIDs = Set(applications.map(\.processIdentifier))
        let obsoleteProcessIDs = accessibilityObservers.keys.filter {
            !runningProcessIDs.contains($0)
        }
        for processID in obsoleteProcessIDs {
            removeAccessibilityObserver(for: processID)
        }

        for application in applications {
            installAccessibilityObserverIfNeeded(for: application)
        }
    }

    private func installAccessibilityObserverIfNeeded(
        for application: NSRunningApplication
    ) {
        guard provider.isTrusted else { return }
        let processID = application.processIdentifier
        guard accessibilityObservers[processID] == nil else { return }

        var createdObserver: AXObserver?
        guard AXObserverCreate(
            processID,
            windowMonitorAccessibilityCallback,
            &createdObserver
        ) == .success,
        let observer = createdObserver else {
            return
        }

        let applicationElement = AXUIElementCreateApplication(processID)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXCreatedNotification as CFString,
            kAXWindowCreatedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXMainWindowChangedNotification as CFString
        ]
        var registered = false
        for notification in notifications {
            let result = AXObserverAddNotification(
                observer,
                applicationElement,
                notification,
                refcon
            )
            if result == .success || result == .notificationAlreadyRegistered {
                registered = true
            }
        }
        guard registered else { return }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        accessibilityObservers[processID] = observer
    }

    private func registerWindowDestructionNotifications(
        for windows: [WindowSnapshot],
        processID: pid_t
    ) {
        guard let observer = accessibilityObservers[processID] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for window in windows {
            let notifications = [
                kAXUIElementDestroyedNotification as CFString,
                kAXWindowMovedNotification as CFString,
                kAXWindowResizedNotification as CFString,
                kAXWindowDeminiaturizedNotification as CFString
            ]
            for notification in notifications {
                _ = AXObserverAddNotification(
                    observer,
                    window.element,
                    notification,
                    refcon
                )
            }
        }
    }

    private func removeAccessibilityObserver(for processID: pid_t) {
        guard let observer = accessibilityObservers.removeValue(forKey: processID) else {
            return
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    private func removeAllAccessibilityObservers() {
        let processIDs = Array(accessibilityObservers.keys)
        processIDs.forEach(removeAccessibilityObserver)
    }

    private func saveApplicationGroupOrder(for context: DisplaySpaceContext) {
        let applicationOrder = applicationOrdersByContext[context] ?? []
        UserDefaults.standard.set(
            applicationOrder.map(\.identifier),
            forKey: savedGroupOrderKey(for: context)
        )
    }

    private func savedGroupOrderKey(
        for context: DisplaySpaceContext
    ) -> String {
        "\(savedGroupOrderKey).display.\(context.displayIdentifier).space.\(context.spaceIdentifier)"
    }

    private func legacySavedGroupOrderKey(
        for spaceIdentifier: DesktopSpaceProvider.SpaceIdentifier
    ) -> String {
        "\(savedGroupOrderKey).space.\(spaceIdentifier)"
    }
}
