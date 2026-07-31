import AppKit

extension Notification.Name {
    static let taskbarPreferencesDidChange = Notification.Name("taskbarPreferencesDidChange")
}

enum TaskbarSetting: Int, CaseIterable {
    case barHeight
    case itemHeight
    case maximumItemWidth
    case itemPadding
    case itemSpacing
    case iconSize
    case transitionDuration

    var title: String {
        switch self {
        case .barHeight:
            L10n.text("settings.bar_height", fallback: "Panel height")
        case .itemHeight:
            L10n.text("settings.item_height", fallback: "Item height")
        case .maximumItemWidth:
            L10n.text("settings.maximum_item_width", fallback: "Maximum item width")
        case .itemPadding:
            L10n.text("settings.item_padding", fallback: "Item padding")
        case .itemSpacing:
            L10n.text("settings.item_spacing", fallback: "Item spacing")
        case .iconSize:
            L10n.text("settings.icon_size", fallback: "Icon size")
        case .transitionDuration:
            L10n.text("settings.transition_duration", fallback: "Open/close duration")
        }
    }

    var key: String {
        switch self {
        case .barHeight: "appearance.barHeight"
        case .itemHeight: "appearance.itemHeight"
        case .maximumItemWidth: "appearance.maximumItemWidth"
        case .itemPadding: "appearance.itemPadding"
        case .itemSpacing: "appearance.itemSpacing"
        case .iconSize: "appearance.iconSize"
        case .transitionDuration: "appearance.transitionDurationMilliseconds"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .barHeight: 36...96
        case .itemHeight: 30...72
        case .maximumItemWidth: 100...360
        case .itemPadding: 4...28
        case .itemSpacing: 0...24
        case .iconSize: 16...48
        case .transitionDuration: 50...300
        }
    }

    var defaultValue: Double {
        switch self {
        case .barHeight: 43
        case .itemHeight: 72
        case .maximumItemWidth: 173
        case .itemPadding: 28
        case .itemSpacing: 0
        case .iconSize: 48
        case .transitionDuration: 120
        }
    }

    var unit: String {
        switch self {
        case .transitionDuration: "ms"
        default: "px"
        }
    }
}

struct TaskbarLayoutPreferences {
    let barHeight: CGFloat
    let itemHeight: CGFloat
    let maximumItemWidth: CGFloat
    let itemPadding: CGFloat
    let itemSpacing: CGFloat
    let iconSize: CGFloat
    let transitionDuration: TimeInterval
}

final class TaskbarPreferences {
    static let shared = TaskbarPreferences()

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Dictionary(
            uniqueKeysWithValues: TaskbarSetting.allCases.map { ($0.key, $0.defaultValue) }
        ))

        let styleVersionKey = "appearance.styleVersion"
        if defaults.integer(forKey: styleVersionKey) < 2 {
            TaskbarSetting.allCases.forEach { setting in
                defaults.set(setting.defaultValue, forKey: setting.key)
            }
            defaults.set(2, forKey: styleVersionKey)
        }
    }

    var layout: TaskbarLayoutPreferences {
        TaskbarLayoutPreferences(
            barHeight: value(for: .barHeight),
            itemHeight: value(for: .itemHeight),
            maximumItemWidth: value(for: .maximumItemWidth),
            itemPadding: value(for: .itemPadding),
            itemSpacing: value(for: .itemSpacing),
            iconSize: value(for: .iconSize),
            transitionDuration: TimeInterval(value(for: .transitionDuration) / 1_000)
        )
    }

    func value(for setting: TaskbarSetting) -> CGFloat {
        CGFloat(defaults.double(forKey: setting.key))
    }

    func set(_ value: Double, for setting: TaskbarSetting) {
        let clamped = min(max(value, setting.range.lowerBound), setting.range.upperBound)
        defaults.set(clamped.rounded(), forKey: setting.key)
        NotificationCenter.default.post(name: .taskbarPreferencesDidChange, object: self)
    }

    func resetAppearance() {
        TaskbarSetting.allCases.forEach { setting in
            defaults.set(setting.defaultValue, forKey: setting.key)
        }
        NotificationCenter.default.post(name: .taskbarPreferencesDidChange, object: self)
    }
}

enum TaskbarPalette {
    static let panelBackground = NSColor(calibratedRed: 0.055, green: 0.059, blue: 0.078, alpha: 0.98)
    static let itemBackground = NSColor(calibratedRed: 0.115, green: 0.125, blue: 0.155, alpha: 1)
    static let itemHoverBackground = NSColor(calibratedRed: 0.165, green: 0.178, blue: 0.215, alpha: 1)
    static let activeItemBackground = NSColor(calibratedRed: 0.205, green: 0.215, blue: 0.255, alpha: 1)
    static let itemBorder = NSColor(calibratedWhite: 1, alpha: 0.09)
    static let accent = NSColor.systemBlue
    static let launchingAccent = NSColor.systemOrange
    static let primaryText = NSColor(calibratedWhite: 0.96, alpha: 1)
}
