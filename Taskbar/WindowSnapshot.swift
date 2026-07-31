import AppKit
import ApplicationServices

struct ReservedWorkArea: Equatable {
    let displayIdentifier: CGDirectDisplayID
    let screenFrame: CGRect
    let nativeVisibleFrame: CGRect
    let taskbarFrame: CGRect
    let isEnabled: Bool

    var usableFrame: CGRect? {
        guard isEnabled else { return nil }

        let lowerBoundary = max(nativeVisibleFrame.minY, taskbarFrame.maxY)
        guard lowerBoundary < nativeVisibleFrame.maxY else { return nil }

        return CGRect(
            x: nativeVisibleFrame.minX,
            y: lowerBoundary,
            width: nativeVisibleFrame.width,
            height: nativeVisibleFrame.maxY - lowerBoundary
        )
    }
}

struct ApplicationIdentity: Codable, Hashable {
    let identifier: String
    let bundleIdentifier: String?
    let applicationPath: String

    init(bundleIdentifier: String?, applicationURL: URL) {
        let standardizedPath = applicationURL.standardizedFileURL.path
        self.bundleIdentifier = bundleIdentifier
        applicationPath = standardizedPath
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            identifier = "bundle:\(bundleIdentifier)"
        } else {
            identifier = "path:\(standardizedPath)"
        }
    }

    static func == (lhs: ApplicationIdentity, rhs: ApplicationIdentity) -> Bool {
        lhs.identifier == rhs.identifier
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

struct WindowSnapshot {
    let element: AXUIElement
    let application: NSRunningApplication
    let title: String
    let isMinimized: Bool
    let isFocused: Bool
    let isFullScreen: Bool?
    let spaceIdentifiers: Set<DesktopSpaceProvider.SpaceIdentifier>

    var displayTitle: String {
        let appName = application.localizedName ?? L10n.text(
            "app.fallback_name",
            fallback: "Application"
        )
        return title.isEmpty ? appName : title
    }

    var accessibilityLabel: String {
        let appName = application.localizedName ?? L10n.text(
            "app.fallback_name",
            fallback: "Application"
        )
        return "\(appName), \(displayTitle)"
    }
}

struct TaskbarState {
    let isAccessibilityTrusted: Bool
    let spaceIdentifier: DesktopSpaceProvider.SpaceIdentifier
    let isFullScreenActive: Bool
    let applications: [TaskbarApplicationItem]
}

struct TaskbarApplicationItem {
    let identity: ApplicationIdentity
    let displayName: String
    let applicationURL: URL?
    let icon: NSImage?
    let isPinned: Bool
    let isLaunching: Bool
    let runningApplications: [NSRunningApplication]
    let windows: [WindowSnapshot]

    var isRunning: Bool {
        !runningApplications.isEmpty
    }

    var primaryRunningApplication: NSRunningApplication? {
        runningApplications.first
    }
}
