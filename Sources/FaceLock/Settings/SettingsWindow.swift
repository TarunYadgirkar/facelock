import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Sendable {
    case general, detection, privacy, diagnostics

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .detection: return "viewfinder"
        case .privacy: return "hand.raised"
        case .diagnostics: return "stethoscope"
        }
    }
}

/// Settings as a toolbar of tabs, the native preferences layout. Each pane is SwiftUI.
@MainActor
final class SettingsTabController: NSTabViewController {
    init(model: AppModel, windows: WindowManager) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: SettingsPane(tab: tab).environment(model).environment(windows))
            host.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            addTabViewItem(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func select(_ tab: SettingsTab) {
        selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        view.window?.title = item?.label ?? "Settings"
    }
}

struct SettingsPane: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralPane()
            case .detection: DetectionPane()
            case .privacy: PrivacyPane()
            case .diagnostics: DiagnosticsPane()
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: Self.height(tab))
    }

    static func height(_ tab: SettingsTab) -> CGFloat {
        switch tab {
        case .general: return 500
        case .detection: return 720
        case .privacy: return 540
        case .diagnostics: return 520
        }
    }
}
