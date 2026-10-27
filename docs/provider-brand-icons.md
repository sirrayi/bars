---
summary: "Usage & Spend brand artwork provenance and monochrome rendering boundaries."
read_when:
  - Adding or updating colored provider artwork
  - Changing Usage & Spend icon presentation
---

# Usage & Spend provider artwork

Provider-level icons request `ProviderBrandIcon.Style.brand`. Account/source and model child rows
retain bars's existing monochrome provider artwork and 76% opacity, adapting to light and dark
appearance. The existing provider association is preserved. Menu bar and other settings callers
retain the default monochrome rendering.

`Brand-ProviderIcon-*` assets are opt-in. They preserve their stored fills, masks and gradients;
SwiftUI must render them as original images, without applying the configurable chart accent color.
Brand and monochrome requests have separate cached NSImage instances. Curated names use the
provider identifier.

If no curated asset exists, or it cannot be decoded, use the existing adaptive template. Existing
provider SVGs often contain white silhouettes and must not simply be switched to original rendering.
This fallback does not assert that the provider has an officially monochrome-only identity.

All production Usage & Spend icons share a 20-point slot, including account/source and model child
rows. Transparent padding is compensated for in both brand and monochrome artwork; see
[spend-chart-brand-icons.md](spend-chart-brand-icons.md) for the shared sizing rules.
Single-model
groups omit the repeated Models heading, while multi-model, multi-source and partial-history groups
retain it. Long model names truncate in the middle and expose the full name in a tooltip.

## Sources

Reviewed 2026-10-01.
These files identify the corresponding third-party products; their marks remain
the property of their owners. Colors are not sampled from screenshots or chosen from chart palettes.

| Asset | Primary source | Local transformation |
| --- | --- | --- |
| Claude | [Anthropic brand guidelines](https://github.com/anthropics/skills/blob/8a1541c4a3ffa5a20a5a91de0dcf3f0bab1d1ef4/skills/brand-guidelines/SKILL.md) | Existing bundled silhouette, replacing white with the documented primary accent `#D97757`. This is a palette-backed variant, not an unmodified logo download. |
| Devin (monochrome) | [Official brand symbol](https://devin.ai/assets/brand/logos/devin/symbol-light.svg) from [devin.ai/brand](https://devin.ai/brand), verified 2026-10-12 against [docs.devin.ai](https://docs.devin.ai/get-started/devin-intro) and [devin.ai/favicon.svg](https://devin.ai/favicon.svg) | Preserved the official 128×128 path; removed the opaque white background rect; replaced `fill="black"` with `currentColor` for adaptive template rendering. The app, website logo, and embedded CLI dashboard share the same SVG bytes. |


When adding another brand, verify artwork against a primary source and document the transformation
here before enabling original rendering. Do not infer a brand color from provider progress-bar colors.


## Checksums

SHA-256 pins the reviewed local bytes; a later asset update should update this table and the source notes.

| File | SHA-256 |
| --- | --- |
| `Brand-ProviderIcon-claude.svg` | `4cd39a3832c842390c21a6598dba20d4db91632a978cb34e39aa1659fe88fe5c` |

## Validation

`ProviderIconResourcesTests` verifies independent caches in both load orders, adaptive fallback and
actual colored pixels in decoded assets. Render synthetic
light/dark UI proof, including narrow windows and incomplete model history, with:

```sh
BARS_BRAND_ICON_PROOF_DIR=docs/screenshots/usage-spend-brand-icons \
  make test-fast FILTER='test_renderBrandIconScreenshots|test_renderProviderDetailPolishScreenshots'
```

The screenshot fixtures use synthetic usage data and an unrelated purple tint to reveal accidental
brand tinting. Model aggregation and monochrome child icons retain the existing provider association;
no model-to-vendor identity inference is added.

The contributor's [historical packaged application proof](https://github.com/Yuxin-Qiao/bars/blob/404b28c5b1021fccbd868286ec26fc52349c9d16/docs/screenshots/usage-spend-brand-icons/native/README.md)
records the production settings window with synthetic inputs. The maintained regression path is the
component rendering suite above; no temporary application-entrypoint overlay is shipped here.
Menu and widget accent overrides continue to follow the existing palette policy.
