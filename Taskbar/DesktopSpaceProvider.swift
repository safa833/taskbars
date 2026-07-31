import AppKit
import ApplicationServices
import Darwin

final class DesktopSpaceProvider {
    typealias SpaceIdentifier = UInt64

    private typealias MainConnectionFunction = @convention(c) () -> UInt32
    private typealias ActiveSpaceFunction = @convention(c) (UInt32) -> SpaceIdentifier
    private typealias SpacesForWindowsFunction = @convention(c) (
        UInt32,
        Int32,
        CFArray
    ) -> Unmanaged<CFArray>?
    private typealias ManagedDisplaySpacesFunction = @convention(c) (
        UInt32
    ) -> Unmanaged<CFArray>?
    private typealias WindowIdentifierFunction = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private let mainConnection: MainConnectionFunction?
    private let activeSpace: ActiveSpaceFunction?
    private let spacesForWindows: SpacesForWindowsFunction?
    private let managedDisplaySpaces: ManagedDisplaySpacesFunction?
    private let windowIdentifier: WindowIdentifierFunction?

    init() {
        let skyLight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )
        let applicationServices = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_LAZY
        )

        mainConnection = Self.loadFunction(
            named: "CGSMainConnectionID",
            from: skyLight,
            as: MainConnectionFunction.self
        )
        activeSpace = Self.loadFunction(
            named: "CGSGetActiveSpace",
            from: skyLight,
            as: ActiveSpaceFunction.self
        )
        spacesForWindows = Self.loadFunction(
            named: "CGSCopySpacesForWindows",
            from: skyLight,
            as: SpacesForWindowsFunction.self
        )
        managedDisplaySpaces = Self.loadFunction(
            named: "CGSCopyManagedDisplaySpaces",
            from: skyLight,
            as: ManagedDisplaySpacesFunction.self
        )
        windowIdentifier = Self.loadFunction(
            named: "_AXUIElementGetWindow",
            from: applicationServices,
            as: WindowIdentifierFunction.self
        )
    }

    var currentSpaceIdentifier: SpaceIdentifier {
        guard let mainConnection, let activeSpace else { return 0 }
        return activeSpace(mainConnection())
    }

    func currentSpaceIdentifier(
        forDisplayIdentifier displayIdentifier: CGDirectDisplayID
    ) -> SpaceIdentifier? {
        guard let mainConnection,
              let managedDisplaySpaces,
              let displayUUID = CGDisplayCreateUUIDFromDisplayID(
                displayIdentifier
              )?.takeRetainedValue(),
              let displayUUIDString = CFUUIDCreateString(nil, displayUUID) as String?,
              let displays = managedDisplaySpaces(
                mainConnection()
              )?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }

        let matchingDisplay = displays.first {
            ($0["Display Identifier"] as? String) == displayUUIDString
        } ?? (displays.count == 1 ? displays[0] : nil)
        guard let currentSpace = matchingDisplay?["Current Space"] as? [String: Any],
              let identifier = currentSpace["id64"] as? NSNumber else {
            return nil
        }
        return identifier.uint64Value
    }

    func spaceIdentifiers(for element: AXUIElement) -> Set<SpaceIdentifier> {
        guard let identifier = windowIdentifier(for: element) else {
            return []
        }

        return spaceIdentifiers(forWindowIdentifier: identifier)
    }

    func windowIdentifier(for element: AXUIElement) -> CGWindowID? {
        guard let windowIdentifier else { return nil }

        var identifier = CGWindowID.zero
        guard windowIdentifier(element, &identifier) == .success,
              identifier != .zero else {
            return nil
        }
        return identifier
    }

    func spaceIdentifiers(
        forWindowIdentifier identifier: CGWindowID
    ) -> Set<SpaceIdentifier> {
        guard identifier != .zero,
              let mainConnection,
              let spacesForWindows,
              let values = spacesForWindows(
                mainConnection(),
                0x7,
                [identifier] as CFArray
              )?.takeRetainedValue() as? [NSNumber] else {
            return []
        }

        return Set(values.map(\.uint64Value))
    }

    private static func loadFunction<T>(
        named name: String,
        from handle: UnsafeMutableRawPointer?,
        as type: T.Type
    ) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}
