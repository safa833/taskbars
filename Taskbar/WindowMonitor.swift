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
    private var reservedWorkArea: ReservedWorkArea?
    private var manuallyPositionedWindowIdentifiers: Set<CGWindowID> = []
    private var activeSpaceIdentifier: DesktopSpaceProvider.SpaceIdentifier = 0
    private var applicationOrdersBySpace: [
        DesktopSpaceProvider.SpaceIdentifier: [ApplicationIdentity]
    ] = [:]
    private var runningApplicationsByIdentity: [ApplicationIdentity: [NSRunningApplication]] = [:]
    private var currentSpaceWindowsByIdentity: [ApplicationIdentity: [WindowSnapshot]] = [:]
    private var lastItemsByIdentity: [ApplicationIdentity: TaskbarApplicationItem] = [:]
    private var windowOrderByProcess: [pid_t: [AXUIElement]] = [:]
    private var noWindowSinceByIdentity: [ApplicationIdentity: Date] = [:]
    private var lastTerminationRequestByIdentity: [ApplicationIdentity: Date] = [:]
    private var pendingLaunchesByIdentity: [ApplicationIdentity: Date] = [:]
    private var observedLaunchProcessByIdentity: [ApplicationIdentity: pid_t] = [:]
    private var launchIndicatorStartedAtByIdentity: [ApplicationIdentity: Date] = [:]
    private var launchApplicationsByIdentity: [ApplicationIdentity: NSRunningApplication] = [:]
    private let savedGroupOrderKey = "behavior.applicationGroupOrder.v2"
    private let legacyGroupOrderKey = "behavior.applicationGroupOrder"
    private let windowlessTerminationDelay: TimeInterval = 2
    private let pendingLaunchTimeout: TimeInterval = 30
    private let launchProcessObservationTimeout: TimeInterval = 5
    private let terminationRetryDelay: TimeInterval = 8
    private let terminationExclusions: Set<String> = ["com.apple.finder"]

    private var applicationOrder: [ApplicationIdentity] {
        get { applicationOrdersBySpace[activeSpaceIdentifier] ?? [] }
        set { applicationOrdersBySpace[activeSpaceIdentifier] = newValue }
    }

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
                beginLaunchIndicator(for: identity, application: application)
            } else if notification.name == NSWorkspace.didLaunchApplicationNotification,
                      application.activationPolicy == .regular {
                beginLaunchIndicator(for: identity, application: application)
            }

            if notification.name == NSWorkspace.didLaunchApplicationNotification,
               pendingLaunchesByIdentity[identity] != nil {
                observedLaunchProcessByIdentity[identity] = application.processIdentifier
                logger.notice(
                    "Workspace observed launched application \(identity.identifier, privacy: .public), pid=\(application.processIdentifier)"
                )
                application.activate(
                    options: [.activateAllWindows, .activateIgnoringOtherApps]
                )
            } else if notification.name == NSWorkspace.didTerminateApplicationNotification {
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
        removeAllAccessibilityObservers()

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    func refresh() {
        let trusted = provider.isTrusted
        removeExpiredLaunchStates()
        activeSpaceIdentifier = provider.currentSpaceIdentifier(
            forDisplayIdentifier: reservedWorkArea?.displayIdentifier
        )
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
        let liveWindowIdentifiers = Set(
            allWindowsByIdentity.values
                .flatMap { $0 }
                .compactMap { provider.windowIdentifier(for: $0.element) }
        )
        manuallyPositionedWindowIdentifiers.formIntersection(liveWindowIdentifiers)

        let windowsByIdentity = allWindowsByIdentity.mapValues { windows in
            windows.filter { snapshot in
                snapshot.spaceIdentifiers.contains(activeSpaceIdentifier)
            }
        }
        let isFullScreenActive = allWindowsByIdentity.values.contains { windows in
            windows.contains { snapshot in
                !snapshot.spaceIdentifiers.isEmpty
                    && snapshot.spaceIdentifiers.contains(activeSpaceIdentifier)
                    && snapshot.isFullScreen == true
            }
        }
        currentSpaceWindowsByIdentity = windowsByIdentity
        if !isFullScreenActive, let reservedWorkArea {
            enforceReservedWorkArea(
                on: windowsByIdentity.values.flatMap { $0 },
                reservedWorkArea: reservedWorkArea
            )
        }

        let visibleRunningIdentityOrder = runningIdentityOrder.filter {
            windowsByIdentity[$0]?.isEmpty == false
        }
        let visibleRunningByIdentity = runningByIdentity.filter {
            windowsByIdentity[$0.key]?.isEmpty == false
        }
        runningApplicationsByIdentity = runningByIdentity

        let launchIdentityOrder = launchIndicatorStartedAtByIdentity
            .sorted { $0.value < $1.value }
            .map(\.key)
        let taskbarRunningIdentityOrder = (
            visibleRunningIdentityOrder + launchIdentityOrder
        ).reduce(into: [ApplicationIdentity]()) { identities, identity in
            if !identities.contains(identity) {
                identities.append(identity)
            }
        }

        let pinnedRecords = pinnedStore.records
        let pinnedIdentities = Set(pinnedRecords.map(\.identity))
        let launchingIdentities = Set(launchIndicatorStartedAtByIdentity.keys)
        let validIdentities = Set(visibleRunningIdentityOrder)
            .union(pinnedIdentities)
            .union(launchingIdentities)
        applicationOrder.removeAll { !validIdentities.contains($0) }

        if applicationOrder.isEmpty {
            applicationOrder = pinnedRecords.map(\.identity)
            let savedOrder = UserDefaults.standard.stringArray(
                forKey: savedGroupOrderKey(for: activeSpaceIdentifier)
            ) ?? UserDefaults.standard.stringArray(forKey: savedGroupOrderKey) ?? []
            let legacyOrder = UserDefaults.standard.stringArray(forKey: legacyGroupOrderKey) ?? []
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
                applicationOrder.insert(record.identity, at: min(index, applicationOrder.count))
            }

            let newRunningIdentities = taskbarRunningIdentityOrder
                .filter { !applicationOrder.contains($0) }
                .sorted {
                    taskbarAppearanceDate(for: $0, in: runningByIdentity)
                        < taskbarAppearanceDate(for: $1, in: runningByIdentity)
                }
            applicationOrder.append(contentsOf: newRunningIdentities)
        }

        let pinnedByIdentity = Dictionary(
            uniqueKeysWithValues: pinnedRecords.map { ($0.identity, $0) }
        )
        let items = applicationOrder.compactMap { orderedIdentity -> TaskbarApplicationItem? in
            let isLaunching = launchIndicatorStartedAtByIdentity[orderedIdentity] != nil
            let applications = isLaunching
                ? (runningByIdentity[orderedIdentity] ?? [])
                : (visibleRunningByIdentity[orderedIdentity] ?? [])
            let launchApplication = launchApplicationsByIdentity[orderedIdentity]
            let pinnedRecord = pinnedByIdentity[orderedIdentity]
            guard !applications.isEmpty || pinnedRecord != nil || isLaunching else { return nil }

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
            let windows = windowsByIdentity[orderedIdentity] ?? []

            return TaskbarApplicationItem(
                identity: currentIdentity,
                displayName: displayName,
                applicationURL: applicationURL,
                icon: icon,
                isPinned: pinnedRecord != nil,
                isLaunching: isLaunching,
                runningApplications: applications,
                windows: windows
            )
        }
        lastItemsByIdentity = Dictionary(uniqueKeysWithValues: items.map { ($0.identity, $0) })
        onChange?(
            TaskbarState(
                isAccessibilityTrusted: trusted,
                spaceIdentifier: activeSpaceIdentifier,
                isFullScreenActive: isFullScreenActive,
                applications: items
            )
        )
    }

    func requestPermission() {
        provider.requestPermission()
    }

    func updateReservedWorkArea(_ workArea: ReservedWorkArea?) {
        guard reservedWorkArea != workArea else { return }
        reservedWorkArea = workArea
        scheduleAccessibilityRefresh()
        scheduleAccessibilityRefreshRetries()
    }

    func pinApplication(_ identity: ApplicationIdentity) {
        guard let item = lastItemsByIdentity[identity] else { return }
        pinnedStore.pin(identity: item.identity, displayName: item.displayName)
        if !applicationOrder.contains(item.identity) {
            applicationOrder.append(item.identity)
        }
        saveApplicationGroupOrder()
        refresh()
    }

    func unpinApplication(_ identity: ApplicationIdentity) {
        pinnedStore.unpin(identity)
        if runningApplicationsByIdentity[identity]?.isEmpty != false {
            applicationOrder.removeAll { $0 == identity }
        }
        saveApplicationGroupOrder()
        refresh()
    }

    func launchApplication(_ identity: ApplicationIdentity) {
        logger.notice(
            "Pinned launch requested for \(identity.identifier, privacy: .public)"
        )
        if let runningApplication = runningApplicationsByIdentity[identity]?
            .first(where: { !$0.isTerminated }) {
            if let requestedAt = pendingLaunchesByIdentity[identity],
               Date().timeIntervalSince(requestedAt) < pendingLaunchTimeout {
                logger.debug(
                    "Launch is still pending for \(identity.identifier, privacy: .public)"
                )
                runningApplication.activate(
                    options: [.activateAllWindows, .activateIgnoringOtherApps]
                )
                return
            }

            if currentSpaceWindowsByIdentity[identity]?.isEmpty == false {
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
                openNewWindow(identity)
            }
            return
        }

        if let requestedAt = pendingLaunchesByIdentity[identity],
           Date().timeIntervalSince(requestedAt) < pendingLaunchTimeout {
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
        beginLaunchIndicator(for: identity, startedAt: requestedAt)
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
            clearLaunchIndicator(for: identity)
            refresh()
            logger.error(
                "Desktop launcher could not start for \(identity.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            NSSound.beep()
        }
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
                self.refresh()
                return
            }

            self.pendingLaunchesByIdentity.removeValue(forKey: identity)
            self.observedLaunchProcessByIdentity.removeValue(forKey: identity)
            self.clearLaunchIndicator(for: identity)
            self.refresh()
            self.logger.error(
                "No application process appeared after clean launch for \(identity.identifier, privacy: .public)"
            )
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

    func openNewWindow(_ identity: ApplicationIdentity) {
        guard let runningApplication = runningApplicationsByIdentity[identity]?
            .first(where: { !$0.isTerminated }) else {
            launchApplication(identity)
            return
        }

        if performNewWindowMenuAction(for: runningApplication) {
            logger.notice(
                "New Window menu action accepted for \(identity.identifier, privacy: .public), pid=\(runningApplication.processIdentifier)"
            )
            return
        }

        runningApplication.activate(options: [.activateIgnoringOtherApps])
        openNewWindowWhenApplicationIsFrontmost(
            identity: identity,
            application: runningApplication,
            remainingAttempts: 20
        )
    }

    func moveApplicationGroup(
        from sourceIdentity: ApplicationIdentity,
        relativeTo targetIdentity: ApplicationIdentity,
        insertAfter: Bool
    ) {
        guard sourceIdentity != targetIdentity,
              let sourceIndex = applicationOrder.firstIndex(of: sourceIdentity) else {
            return
        }

        applicationOrder.remove(at: sourceIndex)
        guard let targetIndex = applicationOrder.firstIndex(of: targetIdentity) else {
            applicationOrder.insert(sourceIdentity, at: min(sourceIndex, applicationOrder.count))
            return
        }

        let insertionIndex = targetIndex + (insertAfter ? 1 : 0)
        applicationOrder.insert(sourceIdentity, at: insertionIndex)
        saveApplicationGroupOrder()
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
        startedAt: Date = Date()
    ) {
        if launchIndicatorStartedAtByIdentity[identity] == nil {
            launchIndicatorStartedAtByIdentity[identity] = startedAt
        }
        if let application {
            launchApplicationsByIdentity[identity] = application
        }
    }

    private func clearLaunchIndicator(for identity: ApplicationIdentity) {
        launchIndicatorStartedAtByIdentity.removeValue(forKey: identity)
        launchApplicationsByIdentity.removeValue(forKey: identity)
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
        for application: NSRunningApplication
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
            return AXUIElementPerformAction(
                menuItem,
                kAXPressAction as CFString
            ) == .success
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

    private func openNewWindowWhenApplicationIsFrontmost(
        identity: ApplicationIdentity,
        application: NSRunningApplication,
        remainingAttempts: Int
    ) {
        guard !application.isTerminated else {
            launchApplication(identity)
            return
        }

        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == application.processIdentifier
        guard isFrontmost else {
            guard remainingAttempts > 0 else {
                NSSound.beep()
                return
            }
            application.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self, weak application] in
                guard let self, let application else { return }
                self.openNewWindowWhenApplicationIsFrontmost(
                    identity: identity,
                    application: application,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }

        if !performNewWindowMenuAction(for: application) {
            postStandardNewWindowShortcut()
        }
    }

    private func postStandardNewWindowShortcut() {
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
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
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
                if wasTaskbarLaunch {
                    observedLaunchProcessByIdentity.removeValue(forKey: identity)
                    logger.notice(
                        "First window observed for \(identity.identifier, privacy: .public)"
                    )
                    applications.first(where: { !$0.isTerminated })?.activate(
                        options: [.activateAllWindows, .activateIgnoringOtherApps]
                    )
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
        if notificationName == (kAXWindowCreatedNotification as String) {
            scheduleAccessibilityRefreshRetries()
        }
    }

    private func enforceReservedWorkArea(
        on windows: [WindowSnapshot],
        reservedWorkArea: ReservedWorkArea
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
            let processID = application.processIdentifier
            guard accessibilityObservers[processID] == nil else { continue }

            var createdObserver: AXObserver?
            guard AXObserverCreate(
                processID,
                windowMonitorAccessibilityCallback,
                &createdObserver
            ) == .success,
            let observer = createdObserver else {
                continue
            }

            let applicationElement = AXUIElementCreateApplication(processID)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let notifications = [
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
            guard registered else { continue }

            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
            accessibilityObservers[processID] = observer
        }
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

    private func saveApplicationGroupOrder() {
        UserDefaults.standard.set(
            applicationOrder.map(\.identifier),
            forKey: savedGroupOrderKey(for: activeSpaceIdentifier)
        )
    }

    private func savedGroupOrderKey(
        for spaceIdentifier: DesktopSpaceProvider.SpaceIdentifier
    ) -> String {
        "\(savedGroupOrderKey).space.\(spaceIdentifier)"
    }
}
