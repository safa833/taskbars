import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = WindowMonitor()
    private var barController: BarPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let controller = BarPanelController()
        barController = controller

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
                insertAfter: insertAfter
            )
        }
        controller.onPinApplication = { [weak self] identity in
            self?.monitor.pinApplication(identity)
        }
        controller.onUnpinApplication = { [weak self] identity in
            self?.monitor.unpinApplication(identity)
        }
        controller.onLaunchApplication = { [weak self] identity in
            self?.monitor.launchApplication(identity)
        }
        controller.onNewWindow = { [weak self] identity in
            self?.monitor.openNewWindow(identity)
        }
        controller.onReservedWorkAreaChanged = { [weak self] workArea in
            self?.monitor.updateReservedWorkArea(workArea)
        }

        monitor.onChange = { [weak controller] state in
            controller?.render(state)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        controller.show(on: preferredScreen)
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screenConfigurationChanged() {
        barController?.show(on: preferredScreen)
        monitor.refresh()
    }

    private var preferredScreen: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
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
