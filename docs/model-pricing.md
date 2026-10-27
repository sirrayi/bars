---
summary: "models.dev pricing metadata pipeline, custom-pricing overlay, cache, lookup rules, and token-cost units."
read_when:
  - Updating models.dev pricing metadata support
  - Debugging model-pricing cache refresh or lookup behavior
  - Routing provider cost calculations through shared pricing metadata
  - Adding or documenting custom-pricing.json overlays
---

# Model pricing metadata

bars uses models.dev as an additive pricing source alongside bundled fallback rates.

## Source and cache

- Source API: `https://models.dev/api.json`
- No API key is required.
- Local cache: `~/Library/Caches/bars/model-pricing/models-dev-v1.json`
- TTL: 24 hours

The pipeline lets future scanner code read the last valid cache synchronously with `ModelsDevPricingPipeline.lookup` and refresh stale metadata separately with `ModelsDevPricingPipeline.refreshIfNeeded`. If a refresh fails, the last valid cache remains usable.

Changed catalogs use a single atomic write. After fallback pricing is merged, an identical
catalog instead atomically updates `models-dev-v1.json.refresh`, preserving the catalog stamp and cached Claude
reports. The sidecar stores the successful fetch time bound to the catalog's device/inode, size, and modification
time. Both file stamps validate the bounded in-memory catalog memo; missing, corrupt, or mismatched sidecars
fall back to the catalog's embedded fetch time. The 24-hour TTL and 15-minute unknown-model retry cooldown
use the effective fetch time, including after relaunch. The version-1 catalog remains readable by older releases,
which ignore the sidecar and use its embedded fetch time. Successful saves invalidate the decoded catalog memo.

Refreshes preserve cached pricing for removed models using a provider-local stable-identity index. The index and model-ID normalization memo exist only during the merge; lookups likewise build their normalized-ID index only for the current provider and call. These indexes do not change cache lifetimes, provider boundaries, alias precedence, or dated snapshot pricing.

## Lookup rules

Pricing is scoped by provider id and model id. This prevents two providers with the same model id or display name from sharing pricing accidentally.

Local cost scanners preserve that scope when selecting a catalog:

- Recognizable bare Claude-session model families use their first-party vendor catalog, including Anthropic, OpenAI, Google, Moonshot/Kimi, MiniMax, and DeepSeek.
- Other bare Claude-session IDs are priced only when exactly one selected first-party catalog matches. Ambiguous cross-vendor matches remain unpriced.
- Provider-qualified Claude-session IDs stay on an approved explicit route and never fall through to another vendor.
- Claude's [documented `k3[1m]` alias](https://www.kimi.com/code/docs/en/third-party-tools/claude-code.html) resolves to `kimi-for-coding/k3` after exact-row lookup, including the existing `kimi-coding/` and `kimi-for-coding/` routes. Recorded model names stay unchanged; other context variants and paid Moonshot routes are not inferred. Catalog zero rates remain known estimates, not a claim that subscriptions or extra usage are free.
- OpenAI's [Daybreak aliases](https://developers.openai.com/api/docs/pricing) resolve like the unsuffixed `gpt-5.6` alias: `gpt-daybreak-blue-latest` prices as `gpt-5.6-sol` and `gpt-daybreak-red-latest` as `gpt-5.6-cyber`. Native usage rows retain raw model evidence.

Dollar amounts remain list-price estimates; recorded token usage is not a billing receipt. Rows lacking
input/output counts, an exact price, or a consumed cache class's rate stay unpriced. An unpriced current day is not
shown as $0.

## Units

models.dev publishes costs as USD per 1M tokens. bars converts those to USD per token in the metadata layer:

```text
perToken = modelsDevCost / 1_000_000
```

When models.dev includes `cost.context_over_200k`, bars converts those rates with the same per-1M-token rule.
The legacy field name does not establish the threshold: a matching `cost.tiers` entry with `tier.type = "context"`
supplies its explicit `tier.size`. Only the tier matching the legacy lane's rates is used; this does not add
arbitrary multi-tier pricing. Older catalogs without that metadata use the bundled OpenAI model threshold,
or 200,000 tokens when no provider-specific contract is known. Other providers never inherit OpenAI thresholds.

OpenAI's [pricing table](https://developers.openai.com/api/docs/pricing) defines short context as **at most 272,000
input tokens**, and long context as **more than 272,000**, including cached input. This applies to GPT-6 Astra,
GPT-6.1 Sol, GPT-6 Sol, GPT-6 Luna, GPT-5.6 Sol/Terra/Luna, GPT-5.4/5.5, and their Pro variants where listed.
The bundled table preserves that boundary for old catalogs, including the GPT-5.6 and Daybreak Blue aliases.
For example, GPT-6.1 Sol with 210,000 input tokens (200,000 cached) and 1,000 output tokens costs **$0.050** at
Standard rates. At 272,001 input tokens the full request uses long-context rates, not just the excess tokens.
Recorded authoritative costs and explicit custom-pricing overrides retain their existing precedence.

## Custom pricing overlay

Exact-match list-price overrides live in the platform Application Support directory:

```text
~/Library/Application Support/bars/custom-pricing.json
```

Values are USD per million tokens. Resolution order is **overlay > models.dev > builtin**. The overlay applies to
Devin local cost estimates. Claude's local scanner does not read this file; a key such as `anthropic/claude-…` does
not change Claude scanner list prices.

Keys are case-insensitive and may be a bare model id (`gpt-5.4`) or `provider/model` (`openai/gpt-5.4`). Only an exact normalized key matches; there is no prefix or family glob. If both forms exist for the same model, the **bare key wins** and the provider-qualified row is ignored. Do not define both unless the bare override is the one you want.

```json
{
  "gpt-5.4": {
    "input": 1.25,
    "output": 10,
    "cacheRead": 0.125,
    "cacheWrite": 1.25
  },
  "openai/gpt-5.4-mini": {
    "input": 0,
    "output": 0
  }
}
```

Field rules:

- `0` is a free rate for that token class.
- A missing field stays unknown. bars does not fill it from models.dev or bundled tables, so a partial overlay row is unpriced rather than a mix of overlay and catalog rates.
- Negative and non-finite numbers are ignored.
- Alternate spellings `cache_read`, `cache_write`, `cacheCreation`, and `cache_creation` are accepted for cache fields.

Tests never read this file from the developer Application Support directory; they use fixtures or an empty overlay.
