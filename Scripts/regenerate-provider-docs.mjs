#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// New providers opt into generated directory rows through their provider-owned documentation.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const check = process.argv.includes("--check");
const update = (file, transform) => {
  const before = fs.existsSync(path.join(root, file)) ? read(file) : "";
  const after = transform(before);
  if (check) assert.equal(before, after, `${file} is stale; run Scripts/regenerate-provider-docs.mjs`);
  else if (before !== after) fs.writeFileSync(path.join(root, file), after);
};
const body = read("Sources/BarsCore/Providers/Providers.swift").match(
  /public enum UsageProvider:[^{]+\{([\s\S]*?)\n\}/,
)[1];
const ids = [...body.matchAll(/^\s*case (\w+)$/gm)].map((match) => match[1]);
const count = ids.length;
assert(count > 0 && new Set(ids).size === count);
const entries = fs
  .readdirSync(path.join(root, "docs"))
  .filter((file) => file.endsWith(".md"))
  .flatMap((file) => {
    const front = read(`docs/${file}`).match(/^---\n([\s\S]*?)\n---/u)?.[1] ?? "";
    const field = (key) => front.match(new RegExp(`^${key}: (.+)$`, "m"))?.[1];
    const id = field("provider_id");
    if (!id) return [];
    assert(ids.includes(id), `Unregistered provider ${id}`);
    const entry = {
      id,
      file,
      name: field("provider_name"),
      source: field("provider_source"),
      scope: field("plugin_scope"),
    };
    assert(entry.name && entry.source && entry.scope);
    return [entry];
  })
  .sort((a, b) => ids.indexOf(a.id) - ids.indexOf(b.id));
const providerRoot = "Sources/BarsCore/Providers";
const descriptors = fs
  .readdirSync(path.join(root, providerRoot), { recursive: true })
  .filter((file) => file.endsWith("ProviderDescriptor.swift"))
  .map((file) => read(`${providerRoot}/${file}`));
for (const entry of entries) {
  const descriptor = descriptors.find((source) => source.includes(`id: .${entry.id},`));
  entry.color = descriptor?.match(/color: (?:ProviderColor|\.init)\(hex: 0x([A-Fa-f0-9]{6})\)/u)?.[1];
  assert(entry.color, `Missing hex branding for ${entry.id}`);
}
const section = (text, lines) => {
  const start = "<!-- Generated provider additions: Scripts/regenerate-provider-docs.mjs -->";
  const end = "<!-- End generated provider additions -->";
  const generated = `${start}\n${lines.join("\n")}\n${end}`;
  assert(text.includes(start) && text.includes(end), "Missing generated provider section");
  return text.slice(0, text.indexOf(start)) + generated + text.slice(text.indexOf(end) + end.length);
};
update("README.md", (text) =>
  section(
    text.replace(/\d+ providers\."/u, `${count} providers."`),
    entries.map((entry) => `- [${entry.name}](docs/${entry.file}) — ${entry.source}`),
  ),
);
update("docs/providers.md", (text) =>
  section(text.replace(/currently registers \d+ provider IDs/u, `currently registers ${count} provider IDs`), [
    "",
    "| Provider | Source |",
    "|---|---|",
    ...entries.map((entry) => `| [${entry.name}](${entry.file}) | ${entry.source} |`),
    "",
  ]),
);
console.log(`Provider documentation ${check ? "current" : "generated"}: ${count} registered providers`);
