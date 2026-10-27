import Foundation
import Testing
@testable import Bars

/// Regression coverage for the localized-bundle caching added for #1347.
///
/// The cache is process-global and these tests run in a parallel suite, so identity (`===`) assertions
/// would race against any other test that resolves a different language. Instead these assert the
/// concurrency-safe property that matters for correctness: every call resolves to the right `.lproj`
/// regardless of what is currently cached, so a language switch (and switch-back) is always honored and
/// the cache can never serve a stale localization.
struct LocalizationBundleCacheTests {
    @Test
    func `resolves the correct lproj per language and re-resolves on switch`() {
        resetBarsLocalizationCacheForTesting()

        let fr = BarsLocalizationOverride.$appLanguage.withValue("fr") {
            barsLocalizedBundleForTesting()
        }
        #expect(fr.bundleURL.lastPathComponent == "fr.lproj")

        // Switching language must re-resolve rather than return the cached French bundle.
        let es = BarsLocalizationOverride.$appLanguage.withValue("es") {
            barsLocalizedBundleForTesting()
        }
        #expect(es.bundleURL.lastPathComponent == "es.lproj")

        // Switching back must still produce the French bundle (cache key is the language).
        let frAgain = BarsLocalizationOverride.$appLanguage.withValue("fr") {
            barsLocalizedBundleForTesting()
        }
        #expect(frAgain.bundleURL.lastPathComponent == "fr.lproj")
    }

    @Test
    func `repeated same-language calls keep resolving the same lproj`() {
        resetBarsLocalizationCacheForTesting()

        for _ in 0..<5 {
            let bundle = BarsLocalizationOverride.$appLanguage.withValue("es") {
                barsLocalizedBundleForTesting()
            }
            #expect(bundle.bundleURL.lastPathComponent == "es.lproj")
        }
    }

    @Test
    func `unknown language falls back to en lproj`() {
        resetBarsLocalizationCacheForTesting()

        let bundle = BarsLocalizationOverride.$appLanguage.withValue("zz-unknown") {
            barsLocalizedBundleForTesting()
        }
        #expect(bundle.bundleURL.lastPathComponent == "en.lproj")
    }

    @Test
    func `format locale follows the resolved resource bundle`() {
        let english = BarsLocalizationOverride.$appLanguage.withValue("en") {
            barsLocalizedResourceLocale()
        }
        #expect(english.language.languageCode?.identifier == "en")

        let fallback = BarsLocalizationOverride.$appLanguage.withValue("zz-unknown") {
            barsLocalizedResourceLocale()
        }
        #expect(fallback.language.languageCode?.identifier == "en")
    }

    @Test
    func `resource locale expands English stringsdict singular forms`() {
        let rendered = BarsLocalizationOverride.$appLanguage.withValue("en") {
            String(
                format: L("≈%d full 5h windows of weekly left · %d windows until reset"),
                locale: barsLocalizedResourceLocale(),
                arguments: [1, 1])
        }

        #expect(rendered == "≈1 full 5h window of weekly left · 1 window until reset")
    }

    @Test
    func `resolution survives an explicit cache reset`() {
        let first = BarsLocalizationOverride.$appLanguage.withValue("uk") {
            barsLocalizedBundleForTesting()
        }
        #expect(first.bundleURL.lastPathComponent == "uk.lproj")

        resetBarsLocalizationCacheForTesting()

        let afterReset = BarsLocalizationOverride.$appLanguage.withValue("uk") {
            barsLocalizedBundleForTesting()
        }
        #expect(afterReset.bundleURL.lastPathComponent == "uk.lproj")
    }
}
