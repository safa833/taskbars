import AppKit
import ApplicationServices
import Darwin

enum WindowConstraintResult {
    case unchanged
    case adjusted
    case unavailable
}

enum WindowConstraintPolicy {
    case everyOverlap
    case systemArrangedOnly
}

final class AccessibilityWindowProvider {
    private typealias MainConnectionFunction = @convention(c) () -> Int32
    private typealias GetWindowBoundsFunction = @convention(c) (
        Int32,
        CGWindowID,
        UnsafeMutablePointer<CGRect>
    ) -> CGError
    private typealias GetWindowAlphaFunction = @convention(c) (
        Int32,
        CGWindowID,
        UnsafeMutablePointer<Float>
    ) -> CGError
    private typealias SetWindowAlphaFunction = @convention(c) (
        Int32,
        CGWindowID,
        Float
    ) -> CGError
    private typealias MoveWindowFunction = @convention(c) (
        Int32,
        CGWindowID,
        UnsafePointer<CGPoint>
    ) -> CGError
    private typealias UpdateFunction = @convention(c) (Int32) -> CGError

    private enum TaskbarWindowDisposition {
        case definite
        case ambiguous
        case rejected
    }

    private struct WindowCatalogEntry {
        let identifier: CGWindowID
        let processIdentifier: pid_t
        let layer: Int
        let width: CGFloat
        let height: CGFloat
    }

    private struct AmbiguousWindowKey: Hashable {
        let identifier: CGWindowID
        let processIdentifier: pid_t
    }

    private struct AmbiguousWindowState {
        var observationCount: Int
        var lastSeenAt: Date
    }

    private struct WindowMutationState {
        let targetFrame: CGRect
        var attempts: Int
        var lastMutationAt: Date
    }

    private struct WindowArrangementState {
        let restoreFrame: CGRect
        let constrainedFrame: CGRect
    }

    private let desktopSpaces = DesktopSpaceProvider()
    private let geometryEpsilon: CGFloat = 0.5
    private let maximumMutationAttempts = 3
    private let ambiguousWindowObservationLimit = 2
    private let ambiguousWindowStateLifetime: TimeInterval = 1
    private var mutationStates: [CGWindowID: WindowMutationState] = [:]
    private var lastObservedFrames: [CGWindowID: CGRect] = [:]
    private var arrangementStates: [CGWindowID: WindowArrangementState] = [:]
    private var windowCatalog: [CGWindowID: WindowCatalogEntry]?
    private var ambiguousWindowStates: [AmbiguousWindowKey: AmbiguousWindowState] = [:]
    private var windowServerUpdateSuppressionDepth = 0
    private static let skyLightHandle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )
    private static let mainConnection: MainConnectionFunction? = loadFunction(
        named: "SLSMainConnectionID",
        as: MainConnectionFunction.self
    )
    private static let getWindowBounds: GetWindowBoundsFunction? = loadFunction(
        named: "SLSGetWindowBounds",
        as: GetWindowBoundsFunction.self
    )
    private static let getWindowAlpha: GetWindowAlphaFunction? = loadFunction(
        named: "SLSGetWindowAlpha",
        as: GetWindowAlphaFunction.self
    )
    private static let setWindowAlpha: SetWindowAlphaFunction? = loadFunction(
        named: "SLSSetWindowAlpha",
        as: SetWindowAlphaFunction.self
    )
    private static let moveWindow: MoveWindowFunction? = loadFunction(
        named: "SLSMoveWindow",
        as: MoveWindowFunction.self
    )
    private static let disableUpdates: UpdateFunction? = loadFunction(
        named: "SLSDisableUpdate",
        as: UpdateFunction.self
    )
    private static let reenableUpdates: UpdateFunction? = loadFunction(
        named: "SLSReenableUpdate",
        as: UpdateFunction.self
    )
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func currentSpaceIdentifier(
        forDisplayIdentifier displayIdentifier: CGDirectDisplayID?
    ) -> DesktopSpaceProvider.SpaceIdentifier {
        if let displayIdentifier,
           let identifier = desktopSpaces.currentSpaceIdentifier(
            forDisplayIdentifier: displayIdentifier
           ) {
            return identifier
        }
        return NSScreen.screens.count == 1
            ? desktopSpaces.currentSpaceIdentifier
            : 0
    }

    func requestPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func refreshWindowCatalog() {
        guard let rows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            windowCatalog = nil
            return
        }

        windowCatalog = rows.reduce(into: [:]) { catalog, row in
            guard let identifier = (row[kCGWindowNumber] as? NSNumber)?.uint32Value,
                  identifier != 0,
                  let processIdentifier = (row[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
                  let layer = (row[kCGWindowLayer] as? NSNumber)?.intValue,
                  let bounds = row[kCGWindowBounds] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else {
                return
            }

            catalog[identifier] = WindowCatalogEntry(
                identifier: identifier,
                processIdentifier: processIdentifier,
                layer: layer,
                width: width,
                height: height
            )
        }

        let expirationDate = Date().addingTimeInterval(-ambiguousWindowStateLifetime)
        ambiguousWindowStates = ambiguousWindowStates.filter {
            $0.value.lastSeenAt >= expirationDate
        }
    }

    func windows(for application: NSRunningApplication) -> [WindowSnapshot] {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return []
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let windowElements: [AXUIElement] = copyAttribute(
            kAXWindowsAttribute as CFString,
            from: appElement
        ) else {
            return []
        }

        let focusedWindow: AXUIElement? = copyAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: appElement
        )

        return windowElements.compactMap { element in
            guard let windowIdentifier = desktopSpaces.windowIdentifier(for: element),
                  let catalogEntry = windowCatalog?[windowIdentifier],
                  catalogEntry.processIdentifier == application.processIdentifier else {
                return nil
            }

            let spaceIdentifiers = desktopSpaces.spaceIdentifiers(
                forWindowIdentifier: windowIdentifier
            )
            let disposition = taskbarWindowDisposition(
                for: element,
                catalogEntry: catalogEntry,
                spaceIdentifiers: spaceIdentifiers
            )
            let ambiguousKey = AmbiguousWindowKey(
                identifier: windowIdentifier,
                processIdentifier: application.processIdentifier
            )
            switch disposition {
            case .definite:
                ambiguousWindowStates.removeValue(forKey: ambiguousKey)
            case .ambiguous:
                guard hasPassedAmbiguousWindowStabilization(for: ambiguousKey) else {
                    return nil
                }
            case .rejected:
                ambiguousWindowStates.removeValue(forKey: ambiguousKey)
                return nil
            }

            let title: String = copyAttribute(kAXTitleAttribute as CFString, from: element) ?? ""
            let minimized: Bool = copyAttribute(kAXMinimizedAttribute as CFString, from: element) ?? false
            let isMain: Bool = copyAttribute(kAXMainAttribute as CFString, from: element) ?? false
            let isFullScreen: Bool? = copyAttribute(
                "AXFullScreen" as CFString,
                from: element
            )
            let isFocused = application.isActive && (
                focusedWindow.map { CFEqual($0, element) } ?? isMain
            )
            let displayIdentifier = copyAppKitFrame(from: element)
                .flatMap(displayIdentifier(forWindowFrame:))

            return WindowSnapshot(
                element: element,
                application: application,
                displayIdentifier: displayIdentifier,
                title: title,
                isMinimized: minimized,
                isFocused: isFocused,
                isFullScreen: isFullScreen,
                spaceIdentifiers: spaceIdentifiers
            )
        }
    }

    func processIdentifiersWithUserWindows() -> Set<pid_t>? {
        guard let windowCatalog else { return nil }

        return Set(windowCatalog.values.compactMap { entry -> pid_t? in
            guard entry.layer == 0,
                  entry.width >= 80,
                  entry.height >= 80,
                  !desktopSpaces.spaceIdentifiers(
                    forWindowIdentifier: entry.identifier
                  ).isEmpty else {
                return nil
            }
            return entry.processIdentifier
        })
    }

    func pruneWindowStates(keeping windows: [WindowSnapshot]) {
        let liveWindowIdentifiers = Set(windows.compactMap {
            desktopSpaces.windowIdentifier(for: $0.element)
        })
        mutationStates = mutationStates.filter {
            liveWindowIdentifiers.contains($0.key)
        }
        lastObservedFrames = lastObservedFrames.filter {
            liveWindowIdentifiers.contains($0.key)
        }
        arrangementStates = arrangementStates.filter {
            liveWindowIdentifiers.contains($0.key)
        }
    }

    func windowIdentifier(for element: AXUIElement) -> CGWindowID? {
        desktopSpaces.windowIdentifier(for: element)
    }

    /// Holds WindowServer presentation while a running application creates a
    /// new window. The application continues creating the window normally;
    /// only the intermediate frame on its previously used display is omitted.
    @discardableResult
    func beginWindowPresentationSuppression() -> Bool {
        if windowServerUpdateSuppressionDepth > 0 {
            windowServerUpdateSuppressionDepth += 1
            return true
        }
        guard let mainConnection = Self.mainConnection,
              let disableUpdates = Self.disableUpdates,
              disableUpdates(mainConnection()) == .success else {
            return false
        }
        windowServerUpdateSuppressionDepth = 1
        return true
    }

    func endWindowPresentationSuppression() {
        guard windowServerUpdateSuppressionDepth > 0 else { return }
        windowServerUpdateSuppressionDepth -= 1
        guard windowServerUpdateSuppressionDepth == 0,
              let mainConnection = Self.mainConnection,
              let reenableUpdates = Self.reenableUpdates else {
            return
        }
        _ = reenableUpdates(mainConnection())
    }

    /// Moves a just-created window using one WindowServer update batch. This
    /// avoids the multiple AX round trips that otherwise allow the window's
    /// saved frame to be presented on its previous display first.
    func positionNewlyCreatedWindowBeforePresentation(
        _ element: AXUIElement,
        on targetDisplayIdentifier: CGDirectDisplayID
    ) -> Bool {
        guard let windowIdentifier = desktopSpaces.windowIdentifier(for: element),
              let mainConnection = Self.mainConnection,
              let getWindowBounds = Self.getWindowBounds,
              let setWindowAlpha = Self.setWindowAlpha,
              let moveWindow = Self.moveWindow else {
            return false
        }

        let connection = mainConnection()
        var currentBounds = CGRect.zero
        guard getWindowBounds(
            connection,
            windowIdentifier,
            &currentBounds
        ) == .success,
        currentBounds.width >= 80,
        currentBounds.height >= 40 else {
            return false
        }

        let targetDisplayBounds = CGDisplayBounds(targetDisplayIdentifier)
        guard targetDisplayBounds.width > 0,
              targetDisplayBounds.height > 0 else {
            return false
        }
        let intersection = targetDisplayBounds.intersection(currentBounds)
        let intersectionArea = max(0, intersection.width)
            * max(0, intersection.height)
        let windowArea = currentBounds.width * currentBounds.height
        if intersectionArea >= windowArea * 0.5 {
            return true
        }

        let targetSize = CGSize(
            width: min(currentBounds.width, targetDisplayBounds.width),
            height: min(currentBounds.height, targetDisplayBounds.height)
        )
        var targetOrigin = CGPoint(
            x: targetDisplayBounds.midX - targetSize.width / 2,
            y: targetDisplayBounds.midY - targetSize.height / 2
        )
        var originalAlpha: Float = 1
        _ = Self.getWindowAlpha?(
            connection,
            windowIdentifier,
            &originalAlpha
        )

        let updatesWereDisabled = beginWindowPresentationSuppression()
        _ = setWindowAlpha(connection, windowIdentifier, 0)
        let moveResult = moveWindow(
            connection,
            windowIdentifier,
            &targetOrigin
        )
        _ = setWindowAlpha(
            connection,
            windowIdentifier,
            originalAlpha
        )
        if updatesWereDisabled {
            endWindowPresentationSuppression()
        }
        return moveResult == .success
    }

    func moveWindow(
        _ window: WindowSnapshot,
        to targetFrame: CGRect,
        on targetDisplayIdentifier: CGDirectDisplayID
    ) -> Bool {
        guard window.isFullScreen != true else {
            return false
        }
        if window.isMinimized {
            _ = AXUIElementSetAttributeValue(
                window.element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }

        return moveWindowElement(
            window.element,
            to: targetFrame,
            on: targetDisplayIdentifier
        )
    }

    func moveNewlyCreatedWindow(
        _ element: AXUIElement,
        to targetFrame: CGRect,
        on targetDisplayIdentifier: CGDirectDisplayID
    ) -> Bool {
        let isFullScreen: Bool? = copyAttribute(
            "AXFullScreen" as CFString,
            from: element
        )
        guard isFullScreen != true else { return false }
        let isMinimized: Bool = copyAttribute(
            kAXMinimizedAttribute as CFString,
            from: element
        ) ?? false
        if isMinimized {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }
        return moveWindowElement(
            element,
            to: targetFrame,
            on: targetDisplayIdentifier
        )
    }

    private func moveWindowElement(
        _ element: AXUIElement,
        to targetFrame: CGRect,
        on targetDisplayIdentifier: CGDirectDisplayID
    ) -> Bool {
        guard isStandardWindow(element),
              let windowIdentifier = desktopSpaces.windowIdentifier(for: element),
              let currentFrame = copyAppKitFrame(from: element),
              currentFrame.width >= 80,
              currentFrame.height >= 40,
              targetFrame.width > 0,
              targetFrame.height > 0,
              isAttributeSettable(kAXPositionAttribute as CFString, on: element) else {
            return false
        }

        var targetSize = currentFrame.size
        targetSize.width = min(targetSize.width, targetFrame.width)
        targetSize.height = min(targetSize.height, targetFrame.height)

        let sourceFrame = NSScreen.screens.first {
            displayIdentifier(for: $0)
                == displayIdentifier(forWindowFrame: currentFrame)
        }?.visibleFrame ?? currentFrame
        let sourceHorizontalTravel = max(1, sourceFrame.width - currentFrame.width)
        let sourceVerticalTravel = max(1, sourceFrame.height - currentFrame.height)
        let horizontalRatio = min(
            1,
            max(0, (currentFrame.minX - sourceFrame.minX) / sourceHorizontalTravel)
        )
        let verticalRatio = min(
            1,
            max(0, (sourceFrame.maxY - currentFrame.maxY) / sourceVerticalTravel)
        )
        let targetHorizontalTravel = max(0, targetFrame.width - targetSize.width)
        let targetVerticalTravel = max(0, targetFrame.height - targetSize.height)
        let targetOrigin = CGPoint(
            x: targetFrame.minX + targetHorizontalTravel * horizontalRatio,
            y: targetFrame.maxY - targetSize.height - targetVerticalTravel * verticalRatio
        )
        let positionedFrame = CGRect(origin: targetOrigin, size: targetSize)

        if !sizesApproximatelyEqual(targetSize, currentFrame.size) {
            guard isAttributeSettable(kAXSizeAttribute as CFString, on: element),
                  setSize(targetSize, on: element) == .success else {
                return false
            }
        }
        guard setPosition(
            appKitPosition(for: positionedFrame),
            on: element
        ) == .success else {
            if !sizesApproximatelyEqual(targetSize, currentFrame.size) {
                _ = setSize(currentFrame.size, on: element)
                _ = setPosition(appKitPosition(for: currentFrame), on: element)
            }
            return false
        }

        guard let verifiedFrame = copyAppKitFrame(from: element),
              displayIdentifier(forWindowFrame: verifiedFrame) == targetDisplayIdentifier else {
            return false
        }
        mutationStates.removeValue(forKey: windowIdentifier)
        arrangementStates.removeValue(forKey: windowIdentifier)
        lastObservedFrames[windowIdentifier] = verifiedFrame
        return true
    }

    func constrainWindow(
        _ window: WindowSnapshot,
        to reservedWorkArea: ReservedWorkArea,
        activeSpaceIdentifier: DesktopSpaceProvider.SpaceIdentifier,
        policy: WindowConstraintPolicy
    ) -> WindowConstraintResult {
        guard activeSpaceIdentifier != 0,
              let usableFrame = reservedWorkArea.usableFrame,
              !window.isMinimized,
              window.isFullScreen == false,
              !window.spaceIdentifiers.isEmpty,
              window.spaceIdentifiers.contains(activeSpaceIdentifier),
              isStandardWindow(window.element),
              let windowIdentifier = desktopSpaces.windowIdentifier(for: window.element),
              isWindowOnScreen(
                windowIdentifier,
                expectedProcessIdentifier: window.application.processIdentifier
              ),
              let currentFrame = copyAppKitFrame(from: window.element),
              displayIdentifier(forWindowFrame: currentFrame)
                == reservedWorkArea.displayIdentifier else {
            return .unavailable
        }

        let previousFrame = lastObservedFrames[windowIdentifier]

        guard currentFrame.minY < usableFrame.minY - geometryEpsilon else {
            recordObservedFrame(currentFrame, for: windowIdentifier)
            if let state = mutationStates[windowIdentifier],
               !framesApproximatelyEqual(currentFrame, state.targetFrame)
                || Date().timeIntervalSince(state.lastMutationAt) >= 1 {
                mutationStates.removeValue(forKey: windowIdentifier)
            }
            return .unchanged
        }

        if policy == .systemArrangedOnly,
           !isSystemArrangedFrame(currentFrame, in: reservedWorkArea.nativeVisibleFrame) {
            recordObservedFrame(currentFrame, for: windowIdentifier)
            mutationStates.removeValue(forKey: windowIdentifier)
            return .unchanged
        }

        let isSystemArranged = isSystemArrangedFrame(
            currentFrame,
            in: reservedWorkArea.nativeVisibleFrame
        )

        var targetFrame = currentFrame
        if targetFrame.height > usableFrame.height + geometryEpsilon {
            targetFrame.size.height = usableFrame.height
        }
        targetFrame.origin.y = usableFrame.minY

        var mutationState = mutationStates[windowIdentifier]
        if let existingState = mutationState {
            if !framesApproximatelyEqual(existingState.targetFrame, targetFrame) {
                mutationState = nil
            }
        }
        if mutationState == nil {
            mutationState = WindowMutationState(
                targetFrame: targetFrame,
                attempts: 0,
                lastMutationAt: .distantPast
            )
        }
        guard var mutationState,
              mutationState.attempts < maximumMutationAttempts else {
            return .unavailable
        }
        mutationState.attempts += 1
        mutationState.lastMutationAt = Date()
        mutationStates[windowIdentifier] = mutationState

        guard isAttributeSettable(
            kAXPositionAttribute as CFString,
            on: window.element
        ) else {
            return .unavailable
        }

        if abs(targetFrame.height - currentFrame.height) > geometryEpsilon {
            guard isAttributeSettable(
                kAXSizeAttribute as CFString,
                on: window.element
            ), setSize(targetFrame.size, on: window.element) == .success else {
                return .unavailable
            }
        }

        guard setPosition(
            appKitPosition(for: targetFrame),
            on: window.element
        ) == .success else {
            if abs(targetFrame.height - currentFrame.height) > geometryEpsilon {
                _ = setSize(currentFrame.size, on: window.element)
                _ = setPosition(
                    appKitPosition(for: currentFrame),
                    on: window.element
                )
            }
            return .unavailable
        }

        guard let verifiedFrame = copyAppKitFrame(from: window.element),
              verifiedFrame.minY >= usableFrame.minY - geometryEpsilon else {
            return .unavailable
        }

        mutationStates[windowIdentifier] = WindowMutationState(
            targetFrame: targetFrame,
            attempts: mutationState.attempts,
            lastMutationAt: mutationState.lastMutationAt
        )
        if isSystemArranged,
           arrangementStates[windowIdentifier] == nil,
           let previousFrame,
           !framesApproximatelyEqual(previousFrame, currentFrame) {
            arrangementStates[windowIdentifier] = WindowArrangementState(
                restoreFrame: previousFrame,
                constrainedFrame: targetFrame
            )
        }
        lastObservedFrames[windowIdentifier] = targetFrame
        return .adjusted
    }

    func restoreWindowForHeaderDrag(
        _ element: AXUIElement,
        mouseLocation: CGPoint
    ) -> Bool {
        guard let windowIdentifier = desktopSpaces.windowIdentifier(for: element),
              let arrangementState = arrangementStates[windowIdentifier],
              isStandardWindow(element),
              let currentFrame = copyAppKitFrame(from: element) else {
            return false
        }

        guard sizesApproximatelyEqual(
            currentFrame.size,
            arrangementState.constrainedFrame.size
        ) else {
            arrangementStates.removeValue(forKey: windowIdentifier)
            lastObservedFrames[windowIdentifier] = currentFrame
            return false
        }

        let titlebarHeight = min(64, max(32, currentFrame.height * 0.08))
        guard mouseLocation.x >= currentFrame.minX - geometryEpsilon,
              mouseLocation.x <= currentFrame.maxX + geometryEpsilon,
              mouseLocation.y >= currentFrame.maxY - titlebarHeight,
              mouseLocation.y <= currentFrame.maxY + 8 else {
            return false
        }

        let restoreFrame = arrangementState.restoreFrame
        guard restoreFrame.width >= 80,
              restoreFrame.height >= 40,
              isAttributeSettable(kAXPositionAttribute as CFString, on: element),
              isAttributeSettable(kAXSizeAttribute as CFString, on: element) else {
            return false
        }

        let horizontalAnchor = min(
            0.9,
            max(0.1, (mouseLocation.x - currentFrame.minX) / currentFrame.width)
        )
        let titlebarOffset = min(
            titlebarHeight,
            max(0, currentFrame.maxY - mouseLocation.y)
        )
        var restoredFrame = restoreFrame
        restoredFrame.origin.x = mouseLocation.x - restoredFrame.width * horizontalAnchor
        restoredFrame.origin.y = mouseLocation.y + titlebarOffset - restoredFrame.height
        restoredFrame = frameKeepingTitlebarOnScreen(restoredFrame, near: mouseLocation)

        guard setSize(restoredFrame.size, on: element) == .success,
              setPosition(appKitPosition(for: restoredFrame), on: element) == .success else {
            _ = setSize(currentFrame.size, on: element)
            _ = setPosition(appKitPosition(for: currentFrame), on: element)
            return false
        }

        guard let verifiedFrame = copyAppKitFrame(from: element),
              sizesApproximatelyEqual(verifiedFrame.size, restoredFrame.size) else {
            return false
        }

        arrangementStates.removeValue(forKey: windowIdentifier)
        mutationStates.removeValue(forKey: windowIdentifier)
        lastObservedFrames[windowIdentifier] = verifiedFrame
        return true
    }

    private func recordObservedFrame(_ frame: CGRect, for windowIdentifier: CGWindowID) {
        if let arrangementState = arrangementStates[windowIdentifier],
           !framesApproximatelyEqual(frame, arrangementState.constrainedFrame) {
            arrangementStates.removeValue(forKey: windowIdentifier)
        }
        lastObservedFrames[windowIdentifier] = frame
    }

    private func frameKeepingTitlebarOnScreen(_ frame: CGRect, near point: CGPoint) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.screens.first else {
            return frame
        }

        let visibleFrame = screen.visibleFrame
        var frame = frame
        if frame.width <= visibleFrame.width {
            frame.origin.x = min(
                max(frame.minX, visibleFrame.minX),
                visibleFrame.maxX - frame.width
            )
        }
        frame.origin.y = min(frame.origin.y, visibleFrame.maxY - frame.height)
        return frame
    }

    private func isSystemArrangedFrame(
        _ frame: CGRect,
        in nativeVisibleFrame: CGRect
    ) -> Bool {
        guard nativeVisibleFrame.height > 0 else { return false }

        // macOS Fill/Zoom and left-right tiling use almost the full vertical
        // visible area. A small tolerance preserves the optional tiled-window
        // margins while excluding ordinary windows that the user drags down.
        let maximumTilingInset: CGFloat = 24
        let topInset = nativeVisibleFrame.maxY - frame.maxY
        let bottomInset = frame.minY - nativeVisibleFrame.minY
        let visibleHeightRatio = frame.height / nativeVisibleFrame.height

        return abs(topInset) <= maximumTilingInset
            && abs(bottomInset) <= maximumTilingInset
            && visibleHeightRatio >= 0.9
    }

    private func framesApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= geometryEpsilon
            && abs(lhs.minY - rhs.minY) <= geometryEpsilon
            && abs(lhs.width - rhs.width) <= geometryEpsilon
            && abs(lhs.height - rhs.height) <= geometryEpsilon
    }

    private func sizesApproximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 2
            && abs(lhs.height - rhs.height) <= 2
    }

    private static func loadFunction<T>(named name: String, as type: T.Type) -> T? {
        guard let skyLightHandle,
              let symbol = dlsym(skyLightHandle, name) else {
            return nil
        }
        return unsafeBitCast(symbol, to: type)
    }

    private func taskbarWindowDisposition(
        for element: AXUIElement,
        catalogEntry: WindowCatalogEntry,
        spaceIdentifiers: Set<DesktopSpaceProvider.SpaceIdentifier>
    ) -> TaskbarWindowDisposition {
        let role: String? = copyAttribute(kAXRoleAttribute as CFString, from: element)
        guard role == (kAXWindowRole as String),
              catalogEntry.layer == 0,
              !spaceIdentifiers.isEmpty else {
            return .rejected
        }

        let subrole: String? = copyAttribute(kAXSubroleAttribute as CFString, from: element)
        let rejectedSubroles = [
            kAXDialogSubrole as String,
            kAXSystemDialogSubrole as String,
            kAXFloatingWindowSubrole as String,
            kAXSystemFloatingWindowSubrole as String
        ]
        if let subrole, rejectedSubroles.contains(subrole) {
            return .rejected
        }

        let size: CGSize? = copySize(from: element)
        if let size, size.width < 80 || size.height < 40 {
            return .rejected
        }

        let isModal: Bool = copyAttribute(
            kAXModalAttribute as CFString,
            from: element
        ) ?? false
        guard !isModal else { return .rejected }

        let hasIndependentWindowControl = [
            kAXCloseButtonAttribute as CFString,
            kAXMinimizeButtonAttribute as CFString,
            kAXZoomButtonAttribute as CFString
        ].contains { copyAttributeValue($0, from: element) != nil }
        let supportsMainState: Bool? = copyAttribute(
            kAXMainAttribute as CFString,
            from: element
        )
        let supportsMinimizedState: Bool? = copyAttribute(
            kAXMinimizedAttribute as CFString,
            from: element
        )

        if subrole == (kAXStandardWindowSubrole as String),
           hasIndependentWindowControl {
            return .definite
        }

        if subrole == (kAXStandardWindowSubrole as String),
           supportsMainState != nil,
           supportsMinimizedState != nil {
            return .ambiguous
        }

        if hasIndependentWindowControl,
           supportsMainState != nil,
           supportsMinimizedState != nil {
            return .ambiguous
        }

        return .rejected
    }

    private func hasPassedAmbiguousWindowStabilization(
        for key: AmbiguousWindowKey
    ) -> Bool {
        let now = Date()
        var state = ambiguousWindowStates[key]
        if let existingState = state,
           now.timeIntervalSince(existingState.lastSeenAt) > ambiguousWindowStateLifetime {
            state = nil
        }
        if state == nil {
            state = AmbiguousWindowState(observationCount: 0, lastSeenAt: now)
        }
        guard var state else { return false }
        state.observationCount = min(
            ambiguousWindowObservationLimit,
            state.observationCount + 1
        )
        state.lastSeenAt = now
        ambiguousWindowStates[key] = state
        return state.observationCount >= ambiguousWindowObservationLimit
    }

    private func copyAttributeValue(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    private func isStandardWindow(_ element: AXUIElement) -> Bool {
        let role: String? = copyAttribute(kAXRoleAttribute as CFString, from: element)
        guard role == (kAXWindowRole as String) else { return false }

        let subrole: String? = copyAttribute(kAXSubroleAttribute as CFString, from: element)
        return subrole == (kAXStandardWindowSubrole as String)
    }

    private func copyAppKitFrame(from element: AXUIElement) -> CGRect? {
        guard let primaryScreen = NSScreen.screens.first,
              let position = copyPoint(from: element),
              let size = copySize(from: element),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return CGRect(
            x: primaryScreen.frame.minX + position.x,
            y: primaryScreen.frame.maxY - position.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func appKitPosition(for frame: CGRect) -> CGPoint {
        guard let primaryScreen = NSScreen.screens.first else {
            return frame.origin
        }
        return CGPoint(
            x: frame.minX - primaryScreen.frame.minX,
            y: primaryScreen.frame.maxY - frame.maxY
        )
    }

    private func displayIdentifier(forWindowFrame frame: CGRect) -> CGDirectDisplayID? {
        var bestMatch: (screen: NSScreen, area: CGFloat)?
        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(frame)
            let area = max(0, intersection.width) * max(0, intersection.height)
            guard area > 0 else { continue }
            if let bestMatch, area <= bestMatch.area {
                continue
            }
            bestMatch = (screen, area)
        }

        guard let screen = bestMatch?.screen else { return nil }
        return displayIdentifier(for: screen)
    }

    private func displayIdentifier(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private func isWindowOnScreen(
        _ windowIdentifier: CGWindowID,
        expectedProcessIdentifier: pid_t
    ) -> Bool {
        guard let rows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            windowIdentifier
        ) as? [[CFString: Any]],
        let row = rows.first(where: {
            ($0[kCGWindowNumber] as? NSNumber)?.uint32Value == windowIdentifier
        }),
        (row[kCGWindowOwnerPID] as? NSNumber)?.int32Value == expectedProcessIdentifier,
        (row[kCGWindowLayer] as? NSNumber)?.intValue == 0 else {
            return false
        }

        if let isOnScreen = row[kCGWindowIsOnscreen] as? Bool {
            return isOnScreen
        }
        return (row[kCGWindowIsOnscreen] as? NSNumber)?.boolValue == true
    }

    private func isAttributeSettable(
        _ attribute: CFString,
        on element: AXUIElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }

    private func setPosition(_ point: CGPoint, on element: AXUIElement) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else {
            return .illegalArgument
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            value
        )
    }

    private func setSize(_ size: CGSize, on element: AXUIElement) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else {
            return .illegalArgument
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            value
        )
    }

    private func copyAttribute<T>(_ attribute: CFString, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        return value as? T
    }

    private func copySize(from element: AXUIElement) -> CGSize? {
        guard let value: AXValue = copyAttribute(kAXSizeAttribute as CFString, from: element),
              AXValueGetType(value) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func copyPoint(from element: AXUIElement) -> CGPoint? {
        guard let value: AXValue = copyAttribute(
            kAXPositionAttribute as CFString,
            from: element
        ), AXValueGetType(value) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }
}
