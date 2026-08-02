import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = WindowMonitor()
    private var barControllers: [CGDirectDisplayID: BarPanelController] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        monitor.onChange = { [weak self] state in
            self?.barControllers[state.displayIdentifier]?.render(state)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        synchronizeBarControllers()
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screenConfigurationChanged() {
        synchronizeBarControllers()
        monitor.refresh()
    }

    private func synchronizeBarControllers() {
        let screensByIdentifier = NSScreen.screens.reduce(
            into: [CGDirectDisplayID: NSScreen]()
        ) { result, screen in
            guard let identifier = displayIdentifier(for: screen) else { return }
            result[identifier] = screen
        }
        let removedIdentifiers = Set(barControllers.keys)
            .subtracting(screensByIdentifier.keys)
        for displayIdentifier in removedIdentifiers {
            barControllers.removeValue(forKey: displayIdentifier)?.close()
            monitor.updateReservedWorkArea(nil, for: displayIdentifier)
        }

        for (displayIdentifier, screen) in screensByIdentifier {
            let controller: BarPanelController
            if let existingController = barControllers[displayIdentifier] {
                controller = existingController
            } else {
                controller = makeBarController(for: displayIdentifier)
                barControllers[displayIdentifier] = controller
            }
            controller.show(on: screen)
        }
    }

    private func makeBarController(
        for displayIdentifier: CGDirectDisplayID
    ) -> BarPanelController {
        let controller = BarPanelController()
        controller.onRequestPermission = { [weak self] in
            self?.monitor.requestPermission()
        }
        controller.onRefresh = { [weak self] in
            self?.monitor.refresh()
        }
        controller.onMoveApplicationGroup = { [weak self] source, target, insertAfter in
            self?.monitor.moveApplicationGroup(
                from: source,
                relativeTo: target,
                insertAfter: insertAfter,
                on: displayIdentifier
            )
        }
        controller.onPinApplication = { [weak self] identity in
            self?.monitor.pinApplication(identity, on: displayIdentifier)
        }
        controller.onUnpinApplication = { [weak self] identity in
            self?.monitor.unpinApplication(identity)
        }
        controller.onLaunchApplication = { [weak self] identity in
            self?.monitor.launchApplication(identity, on: displayIdentifier)
        }
        controller.onNewWindow = { [weak self] identity in
            self?.monitor.openNewWindow(identity, on: displayIdentifier)
        }
        controller.onReservedWorkAreaChanged = { [weak self] workArea in
            self?.monitor.updateReservedWorkArea(
                workArea,
                for: displayIdentifier
            )
        }
        return controller
    }

    private func displayIdentifier(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}

@main
enum TaskbarMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
