import AppKit

final class SettingsWindowController: NSWindowController {
    private let preferences: TaskbarPreferences
    private var sliders: [TaskbarSetting: NSSlider] = [:]
    private var valueLabels: [TaskbarSetting: NSTextField] = [:]

    init(preferences: TaskbarPreferences = .shared) {
        self.preferences = preferences

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text(
            "settings.window_title",
            fallback: "Taskbar S Settings"
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = TaskbarPalette.panelBackground
        window.center()

        super.init(window: window)
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        refreshValues()
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(
            labelWithString: L10n.text(
                "settings.appearance",
                fallback: "Appearance"
            )
        )
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let subtitle = NSTextField(
            wrappingLabelWithString: L10n.text(
                "settings.subtitle",
                fallback: "Changes are applied immediately and preserved for future launches."
            )
        )
        subtitle.textColor = .secondaryLabelColor

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 14

        TaskbarSetting.allCases.forEach { setting in
            rows.addArrangedSubview(makeRow(for: setting))
        }

        let resetButton = NSButton(
            title: L10n.text("settings.reset", fallback: "Restore Defaults"),
            target: self,
            action: #selector(resetAppearance)
        )
        resetButton.bezelStyle = .rounded

        let mainStack = NSStackView(views: [title, subtitle, rows, resetButton])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 16
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            subtitle.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            rows.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        ])

        refreshValues()
    }

    private func makeRow(for setting: TaskbarSetting) -> NSView {
        let label = NSTextField(labelWithString: setting.title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let slider = NSSlider(
            value: setting.defaultValue,
            minValue: setting.range.lowerBound,
            maxValue: setting.range.upperBound,
            target: self,
            action: #selector(sliderChanged(_:))
        )
        slider.tag = setting.rawValue
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        sliders[setting] = slider

        let valueLabel = NSTextField(labelWithString: "")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        valueLabels[setting] = valueLabel

        let row = NSStackView(views: [label, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func refreshValues() {
        TaskbarSetting.allCases.forEach { setting in
            let value = Double(preferences.value(for: setting))
            sliders[setting]?.doubleValue = value
            valueLabels[setting]?.stringValue = "\(Int(value.rounded())) \(setting.unit)"
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let setting = TaskbarSetting(rawValue: sender.tag) else { return }
        preferences.set(sender.doubleValue, for: setting)
        refreshValues()
    }

    @objc private func resetAppearance() {
        preferences.resetAppearance()
        refreshValues()
    }
}
