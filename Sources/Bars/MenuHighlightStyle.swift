import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var menuItemHighlighted: Bool = false
    /// Optional live-refresh monitor injected into menu card views so the provider card
    /// subtitle can reflect the in-flight "Refreshing…" state in place while the NSMenu
    /// stays open, without rebuilding the menu during AppKit tracking.
    @Entry var menuCardRefreshMonitor: MenuCardRefreshMonitor?
}

enum MenuHighlightStyle {
    static let selectionText = Color(nsColor: .selectedMenuItemTextColor)
    static let normalPrimaryText = Color(nsColor: .controlTextColor)
    static let normalSecondaryText = Color(nsColor: .secondaryLabelColor)

    static func primary(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : self.normalPrimaryText
    }

    static func secondary(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : self.normalSecondaryText
    }

    static func error(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : Color(nsColor: .systemRed)
    }

    /// Emphasis for a card's status label (for example the active account).
    /// A highlighted row still uses the selection color so contrast is kept.
    static func accent(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : Color(nsColor: .controlAccentColor)
    }

    static func progressTrack(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText.opacity(0.22) : Color(nsColor: .tertiaryLabelColor).opacity(0.22)
    }

    static func progressTint(_ highlighted: Bool, fallback: Color) -> Color {
        highlighted ? self.selectionText : fallback
    }

    /// Hover fill for card rows: a soft neutral wash over the menu's glass, like Control Center menus,
    /// instead of the accent-colored selection. Text keeps its normal colors while hovered.
    static let hoverFillColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.12)
            : NSColor(white: 0, alpha: 0.07)
    }

    /// Tahoe menus inset every row's hover by the same amount and round it with one continuous corner,
    /// concentric with the menu's own corner. Measured on the Battery and Wi-Fi menus: a 7 pt inset and a
    /// 10 pt corner on both 22 pt and 32 pt rows. Rows too short for that corner become capsules.
    static let hoverHorizontalInset: CGFloat = 7
    static let hoverVerticalInset: CGFloat = 2

    static func hoverCornerRadius(forHeight height: CGFloat) -> CGFloat {
        min(10, max(0, height) / 2)
    }
}

/// Hover fill shape whose corner follows `MenuHighlightStyle.hoverCornerRadius(forHeight:)` for its rect.
struct MenuHoverShape: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(
            cornerRadius: MenuHighlightStyle.hoverCornerRadius(forHeight: rect.height),
            style: .continuous)
            .path(in: rect)
    }
}
