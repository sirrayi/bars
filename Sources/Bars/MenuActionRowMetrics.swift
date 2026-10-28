import AppKit

struct MenuActionRowMetrics: Equatable {
    static let defaults = Self(
        rowHeight: 24,
        selectionHorizontalInset: MenuHighlightStyle.hoverHorizontalInset,
        selectionVerticalInset: 0,
        // Align the custom row's image/title frames with native NSMenuItem columns.
        leadingPadding: 15,
        trailingPadding: 8,
        iconWidth: 16,
        iconSymbolPointSize: 16,
        iconSymbolWeight: .regular,
        iconTitleSpacing: 4.5,
        shortcutFontSize: 13,
        shortcutXOffset: -9.5,
        shortcutYOffset: 0)

    let rowHeight: CGFloat
    let selectionHorizontalInset: CGFloat
    let selectionVerticalInset: CGFloat
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let iconWidth: CGFloat
    let iconSymbolPointSize: CGFloat
    let iconSymbolWeight: NSFont.Weight
    let iconTitleSpacing: CGFloat
    let shortcutFontSize: CGFloat
    let shortcutXOffset: CGFloat
    let shortcutYOffset: CGFloat
}
