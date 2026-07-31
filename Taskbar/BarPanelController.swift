import AppKit
import ApplicationServices

private final class TaskbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BarPanelController: NSWindowController {
    private struct GroupDragContext {
        let sourceIdentity: ApplicationIdentity
        let originalOrder: [ApplicationIdentity]
    }

    private let contentStack = NSStackView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let preferences = TaskbarPreferences.shared
    private lazy var settingsController = SettingsWindowController(preferences: preferences)
    private lazy var appMenuButton = makeAppMenuButton()
    private var currentScreen: NSScreen?
    private var lastState: TaskbarState?
    private var lastRenderedSpaceIdentifier: DesktopSpaceProvider.SpaceIdentifier?
    private var pendingStateDuringDrag: TaskbarState?
    private var applicationGroups: [ApplicationIdentity: ApplicationGroupView] = [:]
    private var removingApplicationIdentities = Set<ApplicationIdentity>()
    private var isRenderingApplicationState = false
    private var hasRenderedApplicationState = false
    private var isHiddenForFullScreen = false
    private var activeGroupDrag: GroupDragContext?
    var onRequestPermission: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onMoveApplicationGroup: ((ApplicationIdentity, ApplicationIdentity, Bool) -> Void)?
    var onPinApplication: ((ApplicationIdentity) -> Void)?
    var onUnpinApplication: ((ApplicationIdentity) -> Void)?
    var onLaunchApplication: ((ApplicationIdentity) -> Void)?
    var onNewWindow: ((ApplicationIdentity) -> Void)?
    var onReservedWorkAreaChanged: ((ReservedWorkArea?) -> Void)?

    init() {
        let panel = TaskbarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: preferences.layout.barHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        configurePanel(panel)
        configureContent(in: panel)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: .taskbarPreferencesDidChange,
            object: preferences
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show(on screen: NSScreen?) {
        guard let window, let screen else {
            onReservedWorkAreaChanged?(nil)
            return
        }
        currentScreen = screen
        let screenFrame = screen.frame
        window.setFrame(
            NSRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: screenFrame.width,
                height: preferences.layout.barHeight
            ),
            display: true
        )
        if isHiddenForFullScreen {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
        publishReservedWorkArea()
    }

    func render(_ state: TaskbarState) {
        updateFullScreenVisibility(state.isFullScreenActive)
        if let lastRenderedSpaceIdentifier,
           lastRenderedSpaceIdentifier != state.spaceIdentifier {
            resetApplicationContentForSpaceChange()
        }
        lastRenderedSpaceIdentifier = state.spaceIdentifier
        lastState = state
        if activeGroupDrag != nil {
            pendingStateDuringDrag = state
            return
        }

        applyLayoutPreferences()
        publishReservedWorkArea()

        if !state.isAccessibilityTrusted {
            isRenderingApplicationState = false
            hasRenderedApplicationState = false
            removingApplicationIdentities.removeAll()
            applicationGroups.removeAll()
            removeAllArrangedSubviews()
            contentStack.addArrangedSubview(appMenuButton)
            renderPermissionRequest()
            return
        }

        if !isRenderingApplicationState {
            removeAllArrangedSubviews()
            contentStack.addArrangedSubview(appMenuButton)
            applicationGroups.removeAll()
            removingApplicationIdentities.removeAll()
            isRenderingApplicationState = true
        }

        renderApplications(
            state.applications,
            animated: hasRenderedApplicationState
        )
        hasRenderedApplicationState = true
    }

    private func updateFullScreenVisibility(_ shouldHide: Bool) {
        guard shouldHide != isHiddenForFullScreen else { return }
        isHiddenForFullScreen = shouldHide
        if shouldHide {
            window?.orderOut(nil)
            publishReservedWorkArea()
        } else if let currentScreen {
            show(on: currentScreen)
        } else {
            window?.orderFrontRegardless()
            publishReservedWorkArea()
        }
    }

    private func publishReservedWorkArea() {
        guard let window,
              let currentScreen,
              let displayIdentifier = displayIdentifier(for: currentScreen) else {
            onReservedWorkAreaChanged?(nil)
            return
        }

        onReservedWorkAreaChanged?(
            ReservedWorkArea(
                displayIdentifier: displayIdentifier,
                screenFrame: currentScreen.frame,
                nativeVisibleFrame: currentScreen.visibleFrame,
                taskbarFrame: window.frame,
                isEnabled: !isHiddenForFullScreen
            )
        )
    }

    private func displayIdentifier(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private func resetApplicationContentForSpaceChange() {
        activeGroupDrag = nil
        pendingStateDuringDrag = nil
        applicationGroups.removeAll()
        removingApplicationIdentities.removeAll()
        isRenderingApplicationState = false
        hasRenderedApplicationState = false
        removeAllArrangedSubviews()
    }

    private func renderApplications(
        _ items: [TaskbarApplicationItem],
        animated: Bool
    ) {
        let duration = effectiveTransitionDuration
        let shouldAnimate = animated && duration > 0
        let windowItemWidth = sharedWindowItemWidth(for: items)
        let desiredIdentities = Set(items.map(\.identity))
        let previousOrder = currentApplicationGroupViews
        let previousIndexes = Dictionary(
            uniqueKeysWithValues: previousOrder.enumerated().map { ($0.element.identity, $0.offset) }
        )
        let desiredGroups = items.map { item -> ApplicationGroupView in
            if let existingGroup = applicationGroups[item.identity] {
                if removingApplicationIdentities.remove(item.identity) != nil {
                    existingGroup.cancelRemoval()
                }
                existingGroup.update(
                    item: item,
                    layout: preferences.layout,
                    windowItemWidth: windowItemWidth,
                    animated: shouldAnimate,
                    duration: duration
                )
                return existingGroup
            }

            let group = makeApplicationGroup(
                item: item,
                windowItemWidth: windowItemWidth
            )
            applicationGroups[item.identity] = group
            if shouldAnimate {
                group.prepareForInsertion()
            }
            return group
        }

        let outgoingGroups = previousOrder.filter { group in
            !desiredIdentities.contains(group.identity)
        }
        let groupsStartingRemoval = outgoingGroups.filter {
            !removingApplicationIdentities.contains($0.identity)
        }
        groupsStartingRemoval.forEach { removingApplicationIdentities.insert($0.identity) }

        var transitionOrder = desiredGroups
        for group in outgoingGroups.sorted(by: {
            previousIndexes[$0.identity, default: 0] < previousIndexes[$1.identity, default: 0]
        }) {
            let insertionIndex = min(
                previousIndexes[group.identity, default: transitionOrder.count],
                transitionOrder.count
            )
            transitionOrder.insert(group, at: insertionIndex)
        }
        applyApplicationGroupOrder(
            transitionOrder,
            animated: false,
            animateSource: false
        )
        contentStack.layoutSubtreeIfNeeded()

        desiredGroups.forEach { $0.runPendingWidthTransition(duration: duration) }

        for group in groupsStartingRemoval {
            let identity = group.identity
            group.animateRemoval(duration: duration) { [weak self, weak group] in
                guard let self,
                      let group,
                      self.removingApplicationIdentities.contains(identity),
                      !desiredIdentities.contains(identity) else {
                    return
                }
                self.contentStack.removeArrangedSubview(group)
                group.removeFromSuperview()
                if self.applicationGroups[identity] === group {
                    self.applicationGroups.removeValue(forKey: identity)
                }
                self.removingApplicationIdentities.remove(identity)
            }
        }

        if items.isEmpty {
            statusLabel.stringValue = L10n.text(
                "taskbar.empty",
                fallback: "No open or pinned applications"
            )
            if !contentStack.arrangedSubviews.contains(statusLabel) {
                contentStack.addArrangedSubview(statusLabel)
            }
        } else if contentStack.arrangedSubviews.contains(statusLabel) {
            contentStack.removeArrangedSubview(statusLabel)
            statusLabel.removeFromSuperview()
        }
    }

    private func configurePanel(_ panel: NSPanel) {
        panel.level = .statusBar
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    private func configureContent(in panel: NSPanel) {
        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = TaskbarPalette.panelBackground.cgColor
        panel.contentView = contentView

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = preferences.layout.itemSpacing
        contentStack.edgeInsets = stackInsets
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        scrollView.documentView = documentView

        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            documentView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),

            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
    }

    private func renderPermissionRequest() {
        let label = NSTextField(
            labelWithString: L10n.text(
                "taskbar.accessibility_required",
                fallback: "Accessibility permission is required to show open windows."
            )
        )
        label.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(label)

        let button = NSButton(
            title: L10n.text(
                "taskbar.grant_permission",
                fallback: "Grant Access"
            ),
            target: self,
            action: #selector(requestAccessibilityPermission)
        )
        button.bezelStyle = .rounded
        contentStack.addArrangedSubview(button)
    }

    private func makeAppMenuButton() -> TaskbarLauncherButton {
        TaskbarLauncherButton(
            size: preferences.layout.barHeight,
            target: self,
            action: #selector(showAppMenu(_:))
        )
    }

    @objc private func requestAccessibilityPermission() {
        onRequestPermission?()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAppMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let settings = NSMenuItem(
            title: L10n.text("taskbar.menu.settings", fallback: "Settings…"),
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)
        let refresh = NSMenuItem(
            title: L10n.text("taskbar.menu.refresh", fallback: "Refresh"),
            action: #selector(refreshWindows),
            keyEquivalent: "r"
        )
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: L10n.text("taskbar.menu.quit", fallback: "Quit Taskbar S"),
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func refreshWindows() {
        onRefresh?()
    }

    @objc private func showSettings() {
        settingsController.showWindow(nil)
    }

    @objc private func preferencesChanged() {
        applyLayoutPreferences()
        if let currentScreen {
            show(on: currentScreen)
        }
        if let lastState {
            render(lastState)
        }
    }

    private func applyLayoutPreferences() {
        contentStack.spacing = preferences.layout.itemSpacing
        contentStack.edgeInsets = stackInsets
        appMenuButton.updateSize(preferences.layout.barHeight)
    }

    private func highlightWindow(_ selectedElement: AXUIElement) {
        currentApplicationGroupViews
            .flatMap(\.windowButtons)
            .forEach { button in
                button.setFocused(button.matches(selectedElement))
            }
    }

    private func makeApplicationGroup(
        item: TaskbarApplicationItem,
        windowItemWidth: CGFloat
    ) -> ApplicationGroupView {
        let group = ApplicationGroupView(
            item: item,
            layout: preferences.layout,
            windowItemWidth: windowItemWidth
        )
        group.onWindowActivated = { [weak self] element in
            self?.highlightWindow(element)
        }
        group.onPinChanged = { [weak self] identity, shouldPin in
            if shouldPin {
                self?.onPinApplication?(identity)
            } else {
                self?.onUnpinApplication?(identity)
            }
        }
        group.onLaunch = { [weak self] identity in
            self?.onLaunchApplication?(identity)
        }
        group.onNewWindow = { [weak self] identity in
            self?.onNewWindow?(identity)
        }
        group.onDragBegan = { [weak self] identity in
            self?.beginApplicationGroupDrag(identity: identity)
        }
        group.onDragMoved = { [weak self] identity, pointInWindow in
            guard let self else { return }
            self.updateApplicationGroupDrag(
                identity: identity,
                location: self.contentStack.convert(pointInWindow, from: nil)
            )
        }
        group.onDragEnded = { [weak self] identity, operation in
            self?.finishApplicationGroupDrag(identity: identity, operation: operation)
        }
        return group
    }

    private func sharedWindowItemWidth(
        for items: [TaskbarApplicationItem]
    ) -> CGFloat {
        let layout = preferences.layout
        let windowItemCount = items.reduce(into: 0) { count, item in
            count += item.windows.count
        }
        guard windowItemCount > 0 else { return layout.maximumItemWidth }

        let pinnedOnlyItemCount = items.reduce(into: 0) { count, item in
            if item.windows.isEmpty {
                count += 1
            }
        }
        let visibleItemCount = windowItemCount + pinnedOnlyItemCount
        let panelWidth = window?.contentView?.bounds.width
            ?? currentScreen?.frame.width
            ?? 0
        let fixedWidth = layout.barHeight
            + CGFloat(pinnedOnlyItemCount) * layout.barHeight
        let totalSpacing = CGFloat(visibleItemCount) * layout.itemSpacing
        let horizontalInsets = stackInsets.left + stackInsets.right
        let distributableWidth = max(
            0,
            panelWidth - fixedWidth - totalSpacing - horizontalInsets
        )
        let fittedWidth = floor(distributableWidth / CGFloat(windowItemCount))
        let minimumWidth = layout.barHeight

        return min(
            layout.maximumItemWidth,
            max(minimumWidth, fittedWidth)
        )
    }

    private func beginApplicationGroupDrag(identity: ApplicationIdentity) {
        guard activeGroupDrag == nil,
              let sourceGroup = applicationGroups[identity] else {
            return
        }
        activeGroupDrag = GroupDragContext(
            sourceIdentity: identity,
            originalOrder: currentApplicationGroupViews.map(\.identity)
        )
        pendingStateDuringDrag = nil
        sourceGroup.alphaValue = 0
    }

    private func updateApplicationGroupDrag(
        identity: ApplicationIdentity,
        location: NSPoint
    ) {
        guard let drag = activeGroupDrag,
              drag.sourceIdentity == identity,
              let sourceGroup = applicationGroups[identity] else {
            return
        }

        let otherGroups = currentApplicationGroupViews.filter { $0 !== sourceGroup }
        let insertionIndex = otherGroups.firstIndex { location.x < $0.frame.midX }
            ?? otherGroups.endIndex
        var desiredOrder = otherGroups
        desiredOrder.insert(sourceGroup, at: insertionIndex)

        if desiredOrder.map(\.identity) != currentApplicationGroupViews.map(\.identity) {
            applyApplicationGroupOrder(
                desiredOrder,
                animated: true,
                animateSource: false
            )
        }
    }

    private func finishApplicationGroupDrag(
        identity: ApplicationIdentity,
        operation: NSDragOperation
    ) {
        guard let drag = activeGroupDrag,
              drag.sourceIdentity == identity,
              let sourceGroup = applicationGroups[identity] else {
            return
        }

        let dropSucceeded = operation.contains(.move)
        if !dropSucceeded {
            let originalGroups = drag.originalOrder.compactMap { applicationGroups[$0] }
            applyApplicationGroupOrder(
                originalGroups,
                animated: true,
                animateSource: true
            )
        }

        sourceGroup.alphaValue = 1
        activeGroupDrag = nil

        let finalOrder = currentApplicationGroupViews.map(\.identity)
        if dropSucceeded, finalOrder != drag.originalOrder {
            pendingStateDuringDrag = nil
            persistApplicationGroupPosition(
                identity: identity,
                orderedIdentities: finalOrder
            )
        } else {
            applyPendingStateAfterDrag(animationDelay: dropSucceeded ? 0 : 0.16)
        }
    }

    private func persistApplicationGroupPosition(
        identity: ApplicationIdentity,
        orderedIdentities: [ApplicationIdentity]
    ) {
        guard orderedIdentities.count > 1,
              let sourceIndex = orderedIdentities.firstIndex(of: identity) else {
            applyPendingStateAfterDrag(animationDelay: 0)
            return
        }

        if sourceIndex == 0 {
            onMoveApplicationGroup?(identity, orderedIdentities[1], false)
        } else {
            onMoveApplicationGroup?(identity, orderedIdentities[sourceIndex - 1], true)
        }
    }

    private func applyApplicationGroupOrder(
        _ orderedGroups: [ApplicationGroupView],
        animated: Bool,
        animateSource: Bool
    ) {
        contentStack.layoutSubtreeIfNeeded()
        let visualCenters = Dictionary(
            uniqueKeysWithValues: currentApplicationGroupViews.map { group in
                (group.identity, visualCenterX(of: group))
            }
        )

        currentApplicationGroupViews.forEach { group in
            contentStack.removeArrangedSubview(group)
            group.removeFromSuperview()
        }
        orderedGroups.enumerated().forEach { offset, group in
            contentStack.insertArrangedSubview(group, at: offset + 1)
        }
        contentStack.layoutSubtreeIfNeeded()

        guard animated,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return
        }

        for group in orderedGroups {
            guard animateSource || group.identity != activeGroupDrag?.sourceIdentity,
                  let oldCenter = visualCenters[group.identity],
                  let layer = group.layer else {
                continue
            }

            let translation = oldCenter - group.frame.midX
            guard abs(translation) > 0.5 else { continue }
            layer.removeAnimation(forKey: "taskbarGroupReorder")
            let animation = CABasicAnimation(keyPath: "transform.translation.x")
            animation.fromValue = translation
            animation.toValue = 0
            animation.duration = 0.14
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "taskbarGroupReorder")
        }
    }

    private func visualCenterX(of group: ApplicationGroupView) -> CGFloat {
        let animatedTranslation = group.layer?.presentation()?.transform.m41
            ?? group.layer?.transform.m41
            ?? 0
        return group.frame.midX + animatedTranslation
    }

    private func applyPendingStateAfterDrag(animationDelay: TimeInterval) {
        guard let pendingState = pendingStateDuringDrag else { return }
        pendingStateDuringDrag = nil
        let apply = { [weak self] in
            guard let self, self.activeGroupDrag == nil else { return }
            self.render(pendingState)
        }
        if animationDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDelay, execute: apply)
        } else {
            apply()
        }
    }

    private func removeAllArrangedSubviews() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private var currentApplicationGroupViews: [ApplicationGroupView] {
        contentStack.arrangedSubviews.compactMap { $0 as? ApplicationGroupView }
    }

    private var stackInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
    }

    private var effectiveTransitionDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0
            : preferences.layout.transitionDuration
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

private final class ApplicationGroupView: NSView {
    let identity: ApplicationIdentity
    private var item: TaskbarApplicationItem
    private let windowsStack = NSStackView()
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var pendingWidthTarget: CGFloat?
    private var pendingInsertedViews: [NSView] = []
    private var isPreparedForInsertion = false
    private var removalGeneration = 0
    private(set) var windowButtons: [WindowButton] = []
    var onWindowActivated: ((AXUIElement) -> Void)?
    var onPinChanged: ((ApplicationIdentity, Bool) -> Void)?
    var onLaunch: ((ApplicationIdentity) -> Void)?
    var onNewWindow: ((ApplicationIdentity) -> Void)?
    var onDragBegan: ((ApplicationIdentity) -> Void)?
    var onDragMoved: ((ApplicationIdentity, NSPoint) -> Void)?
    var onDragEnded: ((ApplicationIdentity, NSDragOperation) -> Void)?

    init(
        item: TaskbarApplicationItem,
        layout: TaskbarLayoutPreferences,
        windowItemWidth: CGFloat
    ) {
        identity = item.identity
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        windowsStack.orientation = .horizontal
        windowsStack.alignment = .centerY
        windowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(windowsStack)
        NSLayoutConstraint.activate([
            windowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            windowsStack.topAnchor.constraint(equalTo: topAnchor),
            windowsStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        update(
            item: item,
            layout: layout,
            windowItemWidth: windowItemWidth,
            animated: false,
            duration: 0
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        item: TaskbarApplicationItem,
        layout: TaskbarLayoutPreferences,
        windowItemWidth: CGFloat,
        animated: Bool,
        duration: TimeInterval
    ) {
        let previousButtons = windowButtons
        let previousWidth = currentVisualWidth
        if animated {
            previousButtons
                .filter { oldButton in
                    !item.windows.contains { oldButton.matches($0.element) }
                }
                .forEach { animateDisappearance(of: $0, duration: duration) }
        }

        self.item = item
        windowsStack.spacing = layout.itemSpacing
        windowsStack.arrangedSubviews.forEach { view in
            windowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        var insertedViews: [NSView] = []
        windowButtons = item.windows.map { snapshot in
            let button = WindowButton(
                snapshot: snapshot,
                layout: layout,
                itemWidth: windowItemWidth
            )
            button.applicationGroup = self
            button.applicationIdentity = item.identity
            button.applicationIsPinned = item.isPinned
            button.onActivated = { [weak self] element in
                self?.onWindowActivated?(element)
            }
            button.onPinChanged = { [weak self] shouldPin in
                guard let self else { return }
                self.onPinChanged?(self.item.identity, shouldPin)
            }
            button.onNewWindow = { [weak self] in
                guard let self else { return }
                self.onNewWindow?(self.item.identity)
            }
            windowsStack.addArrangedSubview(button)
            if animated,
               !previousButtons.contains(where: { $0.matches(snapshot.element) }) {
                insertedViews.append(button)
            }
            return button
        }

        var totalWidth = windowButtons.reduce(CGFloat.zero) { $0 + $1.preferredWidth }
        if windowButtons.isEmpty {
            let button = PinnedApplicationButton(item: item, layout: layout)
            button.applicationGroup = self
            button.onLaunch = { [weak self] in
                guard let self else { return }
                self.onLaunch?(self.item.identity)
            }
            button.onPinChanged = { [weak self] shouldPin in
                guard let self else { return }
                self.onPinChanged?(self.item.identity, shouldPin)
            }
            button.onNewWindow = { [weak self] in
                guard let self else { return }
                self.onNewWindow?(self.item.identity)
            }
            windowsStack.addArrangedSubview(button)
            if animated, !previousButtons.isEmpty {
                insertedViews.append(button)
            }
            totalWidth = button.preferredWidth
        }

        let totalSpacing = layout.itemSpacing * CGFloat(max(0, windowsStack.arrangedSubviews.count - 1))
        let targetWidth = totalWidth + totalSpacing
        if widthConstraint == nil {
            widthConstraint = widthAnchor.constraint(equalToConstant: targetWidth)
            widthConstraint?.isActive = true
        } else if animated, abs(previousWidth - targetWidth) > 0.5 {
            widthConstraint?.constant = previousWidth
            pendingWidthTarget = targetWidth
        } else {
            widthConstraint?.constant = targetWidth
            pendingWidthTarget = nil
        }
        pendingInsertedViews = insertedViews

        if heightConstraint == nil {
            heightConstraint = heightAnchor.constraint(equalToConstant: layout.barHeight)
            heightConstraint?.isActive = true
        } else {
            heightConstraint?.constant = layout.barHeight
        }
    }

    func prepareForInsertion() {
        guard let widthConstraint else { return }
        isPreparedForInsertion = true
        pendingWidthTarget = widthConstraint.constant
        widthConstraint.constant = 0
        alphaValue = 0
    }

    func runPendingWidthTransition(duration: TimeInterval) {
        let insertedViews = isPreparedForInsertion ? [] : pendingInsertedViews
        pendingInsertedViews.removeAll()
        insertedViews.forEach { animateAppearance(of: $0, duration: duration) }

        guard let targetWidth = pendingWidthTarget,
              let widthConstraint else {
            isPreparedForInsertion = false
            return
        }
        pendingWidthTarget = nil

        guard duration > 0 else {
            widthConstraint.constant = targetWidth
            alphaValue = 1
            isPreparedForInsertion = false
            superview?.layoutSubtreeIfNeeded()
            return
        }

        superview?.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            widthConstraint.constant = targetWidth
            self.alphaValue = 1
            self.superview?.layoutSubtreeIfNeeded()
        }
        isPreparedForInsertion = false
    }

    func animateRemoval(duration: TimeInterval, completion: @escaping () -> Void) {
        removalGeneration += 1
        let generation = removalGeneration
        pendingWidthTarget = nil
        pendingInsertedViews.removeAll()
        let startingWidth = max(0, currentVisualWidth)
        widthConstraint?.constant = startingWidth
        superview?.layoutSubtreeIfNeeded()

        guard duration > 0, let widthConstraint else {
            widthConstraint?.constant = 0
            alphaValue = 0
            completion()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            widthConstraint.constant = 0
            self.alphaValue = 0
            self.superview?.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            guard let self, self.removalGeneration == generation else { return }
            completion()
        }
    }

    func cancelRemoval() {
        removalGeneration += 1
        layer?.removeAllAnimations()
        alphaValue = 1
    }

    private var currentVisualWidth: CGFloat {
        layer?.presentation()?.bounds.width
            ?? (frame.width > 0 ? frame.width : widthConstraint?.constant)
            ?? 0
    }

    private func animateAppearance(of view: NSView, duration: TimeInterval) {
        guard duration > 0 else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }

        let scale = CABasicAnimation(keyPath: "transform.scale.x")
        scale.fromValue = 0.05
        scale.toValue = 1
        scale.duration = duration
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = duration * 0.75
        layer.add(scale, forKey: "taskbarItemInsertionScale")
        layer.add(opacity, forKey: "taskbarItemInsertionOpacity")
    }

    private func animateDisappearance(of view: NSView, duration: TimeInterval) {
        guard duration > 0,
              let window,
              let contentView = window.contentView,
              !view.bounds.isEmpty,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)

        let overlay = NSImageView(frame: view.convert(view.bounds, to: contentView))
        overlay.image = image
        overlay.imageScaling = .scaleAxesIndependently
        overlay.wantsLayer = true
        contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
        guard let layer = overlay.layer else {
            overlay.removeFromSuperview()
            return
        }

        layer.transform = CATransform3DMakeScale(0.05, 1, 1)
        layer.opacity = 0
        let scale = CABasicAnimation(keyPath: "transform.scale.x")
        scale.fromValue = 1
        scale.toValue = 0.05
        scale.duration = duration
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1
        opacity.toValue = 0
        opacity.duration = duration
        layer.add(scale, forKey: "taskbarItemRemovalScale")
        layer.add(opacity, forKey: "taskbarItemRemovalOpacity")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak overlay] in
            overlay?.removeFromSuperview()
        }
    }

    func beginApplicationGroupDrag(
        with event: NSEvent,
        initialMouseDownLocation: NSPoint
    ) {
        guard !bounds.isEmpty,
              let window,
              let contentView = window.contentView,
              let dragImage = snapshotImage() else {
            return
        }

        let groupFrameInWindow = convert(bounds, to: nil)
        let grabOffsetX = initialMouseDownLocation.x - groupFrameInWindow.minX
        let preview = NSImageView(frame: groupFrameInWindow)
        preview.image = dragImage
        preview.imageScaling = .scaleAxesIndependently
        preview.wantsLayer = true
        preview.layer?.shadowColor = NSColor.black.cgColor
        preview.layer?.shadowOpacity = 0.35
        preview.layer?.shadowRadius = 7
        preview.layer?.shadowOffset = NSSize(width: 0, height: 2)
        contentView.addSubview(preview, positioned: .above, relativeTo: nil)
        onDragBegan?(item.identity)

        let updatePreview = { [weak self, weak preview] (dragEvent: NSEvent) in
            guard let self, let preview else { return }
            var previewFrame = preview.frame
            let maximumOriginX = max(
                contentView.bounds.minX,
                contentView.bounds.maxX - previewFrame.width
            )
            previewFrame.origin.x = min(
                max(
                    dragEvent.locationInWindow.x - grabOffsetX,
                    contentView.bounds.minX
                ),
                maximumOriginX
            )
            previewFrame.origin.y = groupFrameInWindow.minY
            preview.frame = previewFrame
            self.onDragMoved?(
                self.item.identity,
                NSPoint(x: previewFrame.midX, y: previewFrame.midY)
            )
        }

        updatePreview(event)
        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            updatePreview(nextEvent)
            guard nextEvent.type == .leftMouseUp else { continue }

            contentView.layoutSubtreeIfNeeded()
            let destinationFrame = convert(bounds, to: contentView)
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.10
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                preview.animator().frame = destinationFrame
            } completionHandler: { [weak self, weak preview] in
                preview?.removeFromSuperview()
                guard let self else { return }
                self.onDragEnded?(self.item.identity, .move)
            }
            return
        }

        preview.removeFromSuperview()
        onDragEnded?(item.identity, [])
    }

    private func snapshotImage() -> NSImage? {
        layoutSubtreeIfNeeded()
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }
}

private final class LeadingInsetButtonCell: NSButtonCell {
    var leadingContentInset: CGFloat = 0

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        var imageRect = super.imageRect(forBounds: rect)
        imageRect.origin.x += contentShift(forBounds: rect, imageRect: imageRect)
        return imageRect
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var titleRect = super.titleRect(forBounds: rect)
        let shift = contentShift(
            forBounds: rect,
            imageRect: super.imageRect(forBounds: rect)
        )
        titleRect.origin.x += shift
        titleRect.size.width = max(0, titleRect.width - shift)
        return titleRect
    }

    private func contentShift(forBounds bounds: NSRect, imageRect: NSRect) -> CGFloat {
        max(0, bounds.minX + leadingContentInset - imageRect.minX)
    }
}

private final class WindowButton: NSButton {
    private let snapshot: WindowSnapshot
    private var windowIsFocused: Bool
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private let visualHeight: CGFloat
    let preferredWidth: CGFloat
    weak var applicationGroup: ApplicationGroupView?
    var applicationIdentity: ApplicationIdentity?
    var applicationIsPinned = false
    var onActivated: ((AXUIElement) -> Void)?
    var onPinChanged: ((Bool) -> Void)?
    var onNewWindow: (() -> Void)?

    init(
        snapshot: WindowSnapshot,
        layout: TaskbarLayoutPreferences,
        itemWidth: CGFloat
    ) {
        self.snapshot = snapshot
        windowIsFocused = snapshot.isFocused
        visualHeight = min(layout.itemHeight, layout.barHeight - 4)
        let actualIconSize = min(layout.iconSize, visualHeight - 8)
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        preferredWidth = itemWidth
        super.init(frame: .zero)

        let contentCell = LeadingInsetButtonCell(textCell: "")
        contentCell.leadingContentInset = max(
            0,
            (layout.barHeight - actualIconSize) / 2
        )
        cell = contentCell

        title = snapshot.displayTitle
        toolTip = snapshot.accessibilityLabel
        image = snapshot.application.icon?.copy() as? NSImage
        image?.size = NSSize(width: actualIconSize, height: actualIconSize)
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        alignment = .left
        isBordered = false
        self.font = font
        contentTintColor = TaskbarPalette.primaryText
        cell?.lineBreakMode = .byTruncatingTail
        target = self
        action = #selector(activateWindow)
        setAccessibilityLabel(snapshot.accessibilityLabel)
        alphaValue = snapshot.isMinimized ? 0.65 : 1

        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: preferredWidth).isActive = true
        heightAnchor.constraint(equalToConstant: layout.barHeight).isActive = true
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }

        let initialLocation = event.locationInWindow
        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if nextEvent.type == .leftMouseUp {
                let localPoint = convert(nextEvent.locationInWindow, from: nil)
                if bounds.contains(localPoint) {
                    performClick(nil)
                }
                return
            }

            let deltaX = nextEvent.locationInWindow.x - initialLocation.x
            let deltaY = nextEvent.locationInWindow.y - initialLocation.y
            if hypot(deltaX, deltaY) >= 4 {
                applicationGroup?.beginApplicationGroupDrag(
                    with: nextEvent,
                    initialMouseDownLocation: initialLocation
                )
                return
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let cardRect = NSRect(
            x: 0.5,
            y: (bounds.height - visualHeight) / 2,
            width: bounds.width - 1,
            height: visualHeight
        )
        let path = NSBezierPath(roundedRect: cardRect, xRadius: 5, yRadius: 5)
        currentBackgroundColor.setFill()
        path.fill()
        (windowIsFocused ? TaskbarPalette.accent : TaskbarPalette.itemBorder).setStroke()
        path.lineWidth = 1
        path.stroke()
        super.draw(dirtyRect)
    }

    private func updateAppearance() {
        needsDisplay = true
    }

    private var currentBackgroundColor: NSColor {
        if isHovered {
            return TaskbarPalette.itemHoverBackground
        }
        if windowIsFocused {
            return TaskbarPalette.activeItemBackground
        }
        return TaskbarPalette.itemBackground
    }

    func matches(_ element: AXUIElement) -> Bool {
        CFEqual(snapshot.element, element)
    }

    func setFocused(_ focused: Bool) {
        guard windowIsFocused != focused else { return }
        windowIsFocused = focused
        updateAppearance()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onNewWindow?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let open = NSMenuItem(
            title: L10n.text(
                "taskbar.menu.go_to_window",
                fallback: "Go to Window"
            ),
            action: #selector(activateWindow),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        let newWindow = NSMenuItem(
            title: L10n.text("taskbar.menu.new_window", fallback: "New Window"),
            action: #selector(openNewWindow),
            keyEquivalent: ""
        )
        newWindow.target = self
        menu.addItem(newWindow)

        let minimizeTitle = snapshot.isMinimized
            ? L10n.text("taskbar.menu.restore", fallback: "Restore")
            : L10n.text("taskbar.menu.minimize", fallback: "Minimize")
        let minimize = NSMenuItem(title: minimizeTitle, action: #selector(toggleMinimize), keyEquivalent: "")
        minimize.target = self
        menu.addItem(minimize)

        let close = NSMenuItem(
            title: L10n.text("taskbar.menu.close_window", fallback: "Close Window"),
            action: #selector(closeWindow),
            keyEquivalent: ""
        )
        close.target = self
        menu.addItem(close)

        menu.addItem(.separator())
        let pinTitle = applicationIsPinned
            ? L10n.text("taskbar.menu.unpin", fallback: "Unpin from Taskbar")
            : L10n.text("taskbar.menu.pin", fallback: "Pin to Taskbar")
        let pin = NSMenuItem(title: pinTitle, action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)

        let quit = NSMenuItem(
            title: L10n.text(
                "taskbar.menu.quit_application",
                fallback: "Quit Application"
            ),
            action: #selector(quitOwnerApplication),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func activateWindow() {
        if snapshot.isMinimized {
            _ = AXUIElementSetAttributeValue(
                snapshot.element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }

        let applicationElement = AXUIElementCreateApplication(
            snapshot.application.processIdentifier
        )

        // Select the requested window before activating its application. AppKit's
        // default activation then raises only the main/key window instead of the
        // application's complete window group.
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            snapshot.element
        )
        _ = AXUIElementSetAttributeValue(
            snapshot.element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            snapshot.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementPerformAction(snapshot.element, kAXRaiseAction as CFString)

        _ = snapshot.application.activate(options: [.activateIgnoringOtherApps])

        // Some applications choose their previous key window while activation is
        // settling. Reassert only the requested window; never activateAllWindows.
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            snapshot.element
        )
        _ = AXUIElementSetAttributeValue(
            snapshot.element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            snapshot.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementPerformAction(snapshot.element, kAXRaiseAction as CFString)
        onActivated?(snapshot.element)
    }

    @objc private func toggleMinimize() {
        let newValue: CFBoolean = snapshot.isMinimized ? kCFBooleanFalse : kCFBooleanTrue
        AXUIElementSetAttributeValue(
            snapshot.element,
            kAXMinimizedAttribute as CFString,
            newValue
        )
    }

    @objc private func closeWindow() {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            snapshot.element,
            kAXCloseButtonAttribute as CFString,
            &value
        )
        guard result == .success, let closeButton = value else { return }
        AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
    }

    @objc private func quitOwnerApplication() {
        snapshot.application.terminate()
    }

    @objc private func togglePin() {
        onPinChanged?(!applicationIsPinned)
    }

    @objc private func openNewWindow() {
        onNewWindow?()
    }
}

private final class PinnedApplicationButton: NSButton {
    private let item: TaskbarApplicationItem
    private let visualHeight: CGFloat
    let preferredWidth: CGFloat
    weak var applicationGroup: ApplicationGroupView?
    var onLaunch: (() -> Void)?
    var onPinChanged: ((Bool) -> Void)?
    var onNewWindow: (() -> Void)?

    init(item: TaskbarApplicationItem, layout: TaskbarLayoutPreferences) {
        self.item = item
        visualHeight = min(layout.itemHeight, layout.barHeight - 4)
        preferredWidth = layout.barHeight
        super.init(frame: .zero)

        title = ""
        if item.isLaunching {
            toolTip = L10n.format(
                "taskbar.tooltip.launching",
                fallback: "%@ — Launching",
                item.displayName
            )
        } else {
            toolTip = item.isRunning
                ? item.displayName
                : L10n.format(
                    "taskbar.tooltip.pinned",
                    fallback: "%@ — Pinned",
                    item.displayName
                )
        }
        image = item.icon?.copy() as? NSImage
        let iconSize = min(layout.iconSize, visualHeight - 7)
        image?.size = NSSize(width: iconSize, height: iconSize)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        target = self
        action = #selector(openApplication)
        setAccessibilityLabel(toolTip ?? item.displayName)
        alphaValue = item.applicationURL == nil && !item.isRunning ? 0.55 : 1

        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: preferredWidth).isActive = true
        heightAnchor.constraint(equalToConstant: layout.barHeight).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }

        let initialLocation = event.locationInWindow
        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if nextEvent.type == .leftMouseUp {
                let localPoint = convert(nextEvent.locationInWindow, from: nil)
                if bounds.contains(localPoint) {
                    performClick(nil)
                }
                return
            }

            let deltaX = nextEvent.locationInWindow.x - initialLocation.x
            let deltaY = nextEvent.locationInWindow.y - initialLocation.y
            if hypot(deltaX, deltaY) >= 4 {
                applicationGroup?.beginApplicationGroupDrag(
                    with: nextEvent,
                    initialMouseDownLocation: initialLocation
                )
                return
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let cardRect = NSRect(
            x: 0.5,
            y: (bounds.height - visualHeight) / 2,
            width: bounds.width - 1,
            height: visualHeight
        )
        let path = NSBezierPath(roundedRect: cardRect, xRadius: 5, yRadius: 5)
        let active = item.primaryRunningApplication?.isActive == true
        (active ? TaskbarPalette.activeItemBackground : TaskbarPalette.itemBackground).setFill()
        path.fill()
        let borderColor = item.isLaunching
            ? TaskbarPalette.launchingAccent
            : (active ? TaskbarPalette.accent : TaskbarPalette.itemBorder)
        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        super.draw(dirtyRect)

        if item.isRunning && !item.isLaunching {
            TaskbarPalette.accent.setFill()
            NSBezierPath.fill(
                NSRect(x: 7, y: 2, width: max(4, bounds.width - 14), height: 2)
            )
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onNewWindow?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let open = NSMenuItem(
            title: L10n.text("taskbar.menu.open", fallback: "Open"),
            action: #selector(openApplication),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        let newWindow = NSMenuItem(
            title: L10n.text("taskbar.menu.new_window", fallback: "New Window"),
            action: #selector(openNewWindow),
            keyEquivalent: ""
        )
        newWindow.target = self
        menu.addItem(newWindow)
        menu.addItem(.separator())

        let pinTitle = item.isPinned
            ? L10n.text("taskbar.menu.unpin", fallback: "Unpin from Taskbar")
            : L10n.text("taskbar.menu.pin", fallback: "Pin to Taskbar")
        let pin = NSMenuItem(title: pinTitle, action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openApplication() {
        guard !item.isLaunching else { return }
        onLaunch?()
    }

    @objc private func togglePin() {
        onPinChanged?(!item.isPinned)
    }

    @objc private func openNewWindow() {
        onNewWindow?()
    }
}

private final class TaskbarLauncherButton: NSButton {
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var widthConstraintReference: NSLayoutConstraint?
    private var heightConstraintReference: NSLayoutConstraint?

    init(size: CGFloat, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        toolTip = L10n.text("taskbar.tooltip.menu", fallback: "Taskbar S menu")
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = TaskbarPalette.itemBorder.cgColor
        layer?.backgroundColor = TaskbarPalette.itemBackground.cgColor

        let symbol = NSImage(
            systemSymbolName: "square.grid.2x2.fill",
            accessibilityDescription: L10n.text(
                "taskbar.accessibility_label",
                fallback: "Taskbar S"
            )
        )
        let configuration = NSImage.SymbolConfiguration(
            paletteColors: [.systemRed, .systemBlue, .systemGreen, .systemPurple]
        )
        image = symbol?.withSymbolConfiguration(configuration)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown

        translatesAutoresizingMaskIntoConstraints = false
        updateSize(size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateSize(_ size: CGFloat) {
        widthConstraintReference?.isActive = false
        heightConstraintReference?.isActive = false
        widthConstraintReference = widthAnchor.constraint(equalToConstant: size)
        heightConstraintReference = heightAnchor.constraint(equalToConstant: size)
        widthConstraintReference?.isActive = true
        heightConstraintReference?.isActive = true
        image?.size = NSSize(width: min(21, size - 8), height: min(21, size - 8))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = TaskbarPalette.itemHoverBackground.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = TaskbarPalette.itemBackground.cgColor
    }
}
