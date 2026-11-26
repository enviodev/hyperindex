// Posts a GitHub release to a Discord webhook as an embed.
//
// Usage: node discord-release.mjs <release.json>
// The JSON holds {name, tag_name, body, html_url}. Env: DISCORD_WEBHOOK_URL,
// and DRY_RUN=true to print the payload instead of sending it.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const maxDescriptionLength = 4000;
const githubIssueOrPullUrl =
  /https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/(?:pull|issues)\/(\d+)(?![\w/])/g;
const githubCompareUrl =
  /https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/compare\/([\w.-]+?)\.\.\.([\w.-]+)/g;
const githubMention =
  /(?<![/@\w`])@((?!-)(?!.*?--)[a-zA-Z0-9](?:-?[a-zA-Z0-9]){0,37})(?![.\w/-])/g;

// Fenced blocks and inline code spans: Discord shows them verbatim, so a
// mention or URL inside one must stay as written.
const codeSpan = /(```[\s\S]*?(?:```|$)|`[^`\n]*`)/;
const markdownLink = /(\[[^\]\n]*\]\([^)\n]*\))/;

const mapOutside = (text, pattern, transform) =>
  text
    .split(pattern)
    .map((part, index) => (index % 2 === 0 ? transform(part) : part))
    .join("");

const linkifyProse = (prose) =>
  prose
    .replace(githubMention, (_, name) => `[@${name}](https://github.com/${name})`)
    .replace(githubIssueOrPullUrl, (url, number) => `[#${number}](${url})`)
    .replace(githubCompareUrl, (url, from, to) => `[${from}...${to}](${url})`);

const reduceHeading = (line) => {
  const h3 = line.match(/^\s*###\s+(.+?)\s*#*\s*$/);
  if (h3) return `**__${h3[1]}__**`;
  const h2 = line.match(/^\s*##\s+(.+?)\s*#*\s*$/);
  if (h2) return `**${h2[1]}**`;
  return line;
};

export const formatReleaseNotes = (body) => {
  const cleaned = (body ?? "")
    .replace(/\r/g, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/\n\s*\n/g, "\n\n");
  return mapOutside(cleaned, codeSpan, (text) =>
    mapOutside(text, markdownLink, linkifyProse)
      .split("\n")
      .map(reduceHeading)
      .join("\n"),
  ).trim();
};

// Cuts at the last whitespace before the limit and points to the full notes.
const truncateDescription = (description, url) => {
  if (description.length <= maxDescriptionLength) return description;
  const more = `\n([…](${url}))`;
  const cut = description.slice(0, maxDescriptionLength - more.length);
  const lastWhitespace = cut.search(/\s\S*$/);
  return (lastWhitespace > 0 ? cut.slice(0, lastWhitespace) : cut) + more;
};

export const buildWebhookPayload = (release) => ({
  username: "HyperIndex Releases",
  avatar_url: "https://avatars.githubusercontent.com/u/135992464?v=4",
  embeds: [
    {
      title: (release.name || release.tag_name).slice(0, 256),
      url: release.html_url,
      color: 5814783,
      description: truncateDescription(
        formatReleaseNotes(release.body),
        release.html_url,
      ),
      footer: { text: "HyperIndex" },
      timestamp: new Date().toISOString(),
    },
  ],
});

const sendWebhook = async (webhookUrl, payload) => {
  for (let attempt = 0; attempt <= 3; attempt++) {
    const response = await fetch(`${webhookUrl}?wait=true`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (response.status === 429) {
      const retryAfterSeconds = Number(response.headers.get("retry-after") ?? 1);
      await new Promise((resolve) => setTimeout(resolve, retryAfterSeconds * 1000));
      continue;
    }
    if (!response.ok) {
      throw new Error(`Discord webhook error ${response.status}: ${await response.text()}`);
    }
    return;
  }
  throw new Error("Discord kept rate limiting the webhook");
};

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const release = JSON.parse(readFileSync(process.argv[2], "utf8"));
  const payload = buildWebhookPayload(release);
  if (process.env.DRY_RUN === "true") {
    console.log("Dry run. Nothing sent.\n--- description below ---");
    console.log(payload.embeds[0].description);
  } else {
    await sendWebhook(process.env.DISCORD_WEBHOOK_URL, payload);
  }
}
