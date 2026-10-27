---
summary: "Official artwork used by spend chart legends and amount inspectors."
read_when:
  - Updating spend chart provider icons
---

# Spend chart provider artwork

Chart legends and amount inspectors request `ProviderBrandIcon.Style.brand`. Brand images retain
their original colors; a separate account color swatch matches the chart. Provider headings and
subscription summaries also use brand artwork, while account/source and model child rows retain
adaptive monochrome artwork. Menu bar and other settings callers keep the default monochrome style.

All production Usage & Spend provider icons share a 20-point square slot, including chart legends,
amount inspectors, provider headings, account/source rows, model rows and subscription summaries.
Rendering tests can enlarge the slot for pixel inspection. Source image bytes and aspect ratios
remain unchanged. Both chart locations use the same 8-point account swatch.

Brand and monochrome images have independent cache entries. Claude has curated brand artwork
(`Brand-ProviderIcon-claude.svg`); other providers fall back to their adaptive monochrome template.
Artwork identifies third-party products and remains owned by its creators. Assets load from the
application bundle without any network requests.

Resource tests check separate caches in both load orders, original color pixels, transparent padding,
and adaptive fallback.
