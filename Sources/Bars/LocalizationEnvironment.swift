import Foundation
import SwiftUI

func barsLocalizedLayoutDirection() -> LayoutDirection {
    Locale.Language(identifier: barsLocalizedResourceLocale().identifier).characterDirection == .rightToLeft
        ? .rightToLeft : .leftToRight
}

private struct BarsLocalizationEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(
                \.locale,
                barsLocalizationSignature().isEmpty
                    ? barsLocalizedLocale() : barsLocalizedResourceLocale())
            .environment(\.layoutDirection, barsLocalizedLayoutDirection())
    }
}

extension View {
    /// Keep native formatting and layout in the same language as the selected string resources.
    func barsLocalized() -> some View {
        self.modifier(BarsLocalizationEnvironment())
    }
}
