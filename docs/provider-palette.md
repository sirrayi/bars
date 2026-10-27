---
summary: "Audited provider accents, official sources, and fixed-surface contrast decisions for the September 2026 palette refresh."
read_when:
  - Updating provider brand colors or website palette data
  - Reviewing palette contrast or regenerating the social preview
---

# Provider palette audit

The September 28, 2026 audit of upstream #4075 reviewed provider accents against official sources. The rows below
cover the providers bars still ships; Claude is not part of this audit. Menu-bar icons remain system-tinted templates.
Saved custom accent overrides still take precedence, and burn-down widget colors remain independent. All touched
Swift color values use `ProviderColor(hex:)`.

The controlled comparison uses white and `#222222` for light/dark menu-card surfaces. A material
regression means falling below 3:1 while losing at least 0.5 in contrast ratio compared with the previous accent.
This is a non-regression check, not an accessibility certification of translucent desktop backgrounds or existing
colors. Highlighted menu rows use the system selection tint instead.
Old decimal RGB values are expressed as their nearest 8-bit sRGB hex (at most half a channel step of rounding).

“Supported” means the exact proposed value was found in an official asset or site stylesheet; it does not mean
it is that provider's only canonical brand color.
“Unverified” means the old accent is retained, not that the old value has been newly certified.

| Provider ID | Old | Proposed | Final | Official source | Contrast / decision |
| --- | --- | --- | --- | --- | --- |
| deepseek | `#527DF0` | `#4D6BFE` | `#4D6BFE` | [Source](https://www.deepseek.com/_next/static/css/3da1ce676c85d262.css) | Adopt; light 3.78 → 4.33:1; dark 3.67:1. |
| devin | `#46B482` | `#317CFF` | `#317CFF` | [Source](https://devin.ai/_next/static/immutable/chunks/111m80s9d-n0-.css) | Adopt; light 2.59 → 3.85:1; dark 4.13:1. |
| opencode | `#3B82F6` | `#3B7DD8` | `#3B82F6` | [Source](https://opencode.ai/brand) | Unverified; retain. #007AFF (UI accent); grayscale logo |
