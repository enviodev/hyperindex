// Usage: node release-announce.mjs <discord|telegram> <release.json>
// release.json is a GitHub release object. DRY_RUN=true prints instead of sending.
// Discord reads DISCORD_WEBHOOK_URL; Telegram reads BOT_TOKEN, CHAT_ID, TOPIC_ID.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const prosePattern = new RegExp(
  [
    String.raw`\[(?<linkLabel>[^\]\n]*)\]\((?<linkUrl>[^)\s]+)\)`,
    String.raw`(?<refUrl>https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/(?:pull|issues)\/(?<refUrlNumber>\d+))(?![\w/])`,
    String.raw`(?<compareUrl>https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/compare\/(?<compareRange>[\w.-]+?\.\.\.[\w.-]+))`,
    String.raw`(?<![\w&#/])#(?<refNumber>\d+)(?!\w)`,
    // GitHub logins: 1-39 alphanumerics, single inner hyphens. A trailing
    // ".word" means a domain such as @example.com; a sentence's period is fine.
    String.raw`(?<![/@\w])@(?<mention>[a-zA-Z0-9](?:-?[a-zA-Z0-9]){0,38})(?![\w/-]|\.\w)`,
  ].join("|"),
  "g",
);

const repositoryUrlOf = (releaseUrl) =>
  releaseUrl.match(/^https:\/\/github\.com\/[^/]+\/[^/]+/)?.[0];

const renderProse = (prose, renderer, repositoryUrl) => {
  let out = "";
  let last = 0;
  for (const match of prose.matchAll(prosePattern)) {
    const { linkLabel, linkUrl, refUrl, refUrlNumber, compareUrl, compareRange, refNumber, mention } =
      match.groups;
    let rendered;
    if (linkUrl) rendered = renderer.link(linkLabel, linkUrl);
    else if (refUrl) rendered = renderer.link(`#${refUrlNumber}`, refUrl);
    else if (compareUrl) rendered = renderer.link(compareRange, compareUrl);
    else if (refNumber && repositoryUrl)
      rendered = renderer.link(`#${refNumber}`, `${repositoryUrl}/pull/${refNumber}`);
    else if (mention && renderer.linkMentions)
      rendered = renderer.link(`@${mention}`, `https://github.com/${mention}`);
    else continue;
    out += renderer.text(prose.slice(last, match.index)) + rendered;
    last = match.index + match[0].length;
  }
  return out + renderer.text(prose.slice(last));
};

// Code is shown verbatim on both channels, so nothing inside it is rewritten.
const renderLine = (line, renderer, repositoryUrl) =>
  line
    .split(/(`[^`\n]+`)/)
    .map((part, index) =>
      index % 2 === 1
        ? renderer.inlineCode(part.slice(1, -1))
        : renderProse(part, renderer, repositoryUrl),
    )
    .join("");

const renderProseBlock = (block, renderer, repositoryUrl) =>
  block
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/\n\s*\n/g, "\n\n")
    .split("\n")
    .map((line) => {
      const heading = line.match(/^\s*(#{1,6})\s+(.+?)\s*#*\s*$/);
      const wrap = heading && renderer.heading(heading[1].length);
      return wrap
        ? wrap(renderLine(heading[2], renderer, repositoryUrl))
        : renderLine(line, renderer, repositoryUrl);
    })
    .join("\n");

// An unclosed fence runs to the end of the notes, as on GitHub.
export const renderNotes = (body, renderer, releaseUrl) => {
  const repositoryUrl = repositoryUrlOf(releaseUrl ?? "");
  const blocks = [];
  let prose = [];
  let fence = null;
  for (const line of (body ?? "").replace(/\r/g, "").split("\n")) {
    if (fence) {
      if (/^\s*```\s*$/.test(line)) {
        blocks.push(renderer.fence(fence));
        fence = null;
      } else fence.lines.push(line);
    } else if (/^\s*```/.test(line)) {
      blocks.push(renderProseBlock(prose.join("\n"), renderer, repositoryUrl));
      prose = [];
      fence = { opening: line, lines: [] };
    } else prose.push(line);
  }
  if (fence) {
    while (fence.lines.at(-1)?.trim() === "") fence.lines.pop();
    blocks.push(renderer.fence(fence));
  } else blocks.push(renderProseBlock(prose.join("\n"), renderer, repositoryUrl));
  return blocks
    .map((block) => block.replace(/^\s*\n|\n\s*$/g, ""))
    .filter((block) => block.trim() !== "")
    .join("\n\n")
    .trim();
};

const discordRenderer = {
  linkMentions: true,
  text: (text) => text,
  link: (label, url) => `[${label}](${url})`,
  inlineCode: (code) => `\`${code}\``,
  fence: ({ opening, lines }) => [opening, ...lines, "```"].join("\n"),
  heading: (level) =>
    level === 2 ? (inner) => `**${inner}**` : level === 3 ? (inner) => `**__${inner}__**` : null,
};

const escapeHtml = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const escapeHtmlAttribute = (text) => escapeHtml(text).replace(/"/g, "&quot;");

const telegramRenderer = {
  linkMentions: false,
  text: (text) => escapeHtml(text.replace(/\*\*/g, "")),
  link: (label, url) => `<a href="${escapeHtmlAttribute(url)}">${escapeHtml(label)}</a>`,
  inlineCode: (code) => `<code>${escapeHtml(code)}</code>`,
  fence: ({ lines }) => `<pre>${escapeHtml(lines.join("\n"))}</pre>`,
  heading: () => (inner) => `<b>${inner}</b>`,
};

const discordMaxDescriptionLength = 4000;

const truncateDiscordDescription = (description, url) => {
  if (description.length <= discordMaxDescriptionLength) return description;
  const more = `\n([…](${url}))`;
  const cut = description.slice(0, discordMaxDescriptionLength - more.length);
  const lastWhitespace = cut.search(/\s\S*$/);
  return (lastWhitespace > 0 ? cut.slice(0, lastWhitespace) : cut) + more;
};

export const buildDiscordPayload = (release) => ({
  username: "HyperIndex Releases",
  avatar_url: "https://avatars.githubusercontent.com/u/135992464?v=4",
  embeds: [
    {
      title: (release.name || release.tag_name).slice(0, 256),
      url: release.html_url,
      color: 5814783,
      description: truncateDiscordDescription(
        renderNotes(release.body, discordRenderer, release.html_url),
        release.html_url,
      ),
      footer: { text: "HyperIndex" },
      timestamp: new Date().toISOString(),
    },
  ],
});

// Telegram counts message length in UTF-16 units, as JS strings do.
const telegramMaxLength = 4096;
const telegramMaxNotesLength = 3000;

// Drops a dangling high surrogate, so a cut never splits an emoji.
const cutUtf16 = (text, length) => text.slice(0, length).replace(/[\uD800-\uDBFF]$/, "");

// Cuts at the last whole line: a URL cut short, say /pull/18 of /pull/1875,
// would otherwise still be linked and point at another PR.
const truncateTelegramNotes = (body, budget) => {
  if (body.length <= budget) return body;
  const cut = body.slice(0, budget);
  const lastNewline = cut.lastIndexOf("\n");
  return `${lastNewline > 0 ? cut.slice(0, lastNewline) : cut}\n… read the full notes on GitHub`;
};

export const buildTelegramMessage = (release) => {
  const title = release.name || release.tag_name;
  const header = `🚢 <b>HyperIndex ${escapeHtml(title)} released</b>`;
  const link = `<a href="${escapeHtmlAttribute(release.html_url)}">View on GitHub</a>`;
  const budget = Math.max(
    0,
    Math.min(telegramMaxNotesLength, telegramMaxLength - header.length - link.length - 72),
  );
  const notes = renderNotes(
    truncateTelegramNotes(release.body ?? "", budget),
    telegramRenderer,
    release.html_url,
  );
  const html = `${header}\n\n${notes}\n\n${link}`;
  if (html.length <= telegramMaxLength) return { text: html, parseMode: "HTML" };

  // Escaping and tags can push HTML past the limit; plain text cannot break
  // when cut, and keeps the link back to the release.
  const plainHeader = `🚢 HyperIndex ${title} released`;
  const plainBudget = Math.max(
    0,
    telegramMaxLength - plainHeader.length - release.html_url.length - 4,
  );
  const plainNotes = cutUtf16(release.body ?? "", plainBudget);
  return { text: `${plainHeader}\n\n${plainNotes}\n\n${release.html_url}`, parseMode: undefined };
};

const postJson = async (url, payload) => {
  for (let attempt = 0; attempt <= 3; attempt++) {
    const response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(30_000),
    });
    if (response.status === 429) {
      const retryAfterSeconds = Number(response.headers.get("retry-after") ?? 1);
      await new Promise((resolve) => setTimeout(resolve, retryAfterSeconds * 1000));
      continue;
    }
    if (!response.ok) {
      throw new Error(`${new URL(url).host} answered ${response.status}: ${await response.text()}`);
    }
    return;
  }
  throw new Error(`${new URL(url).host} kept rate limiting the request`);
};

const requireEnv = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set`);
  return value;
};

const channels = {
  discord: {
    preview: (release) => buildDiscordPayload(release).embeds[0].description,
    send: (release) =>
      postJson(`${requireEnv("DISCORD_WEBHOOK_URL")}?wait=true`, buildDiscordPayload(release)),
  },
  telegram: {
    preview: (release) => {
      const { text, parseMode } = buildTelegramMessage(release);
      return `parse_mode=${parseMode ?? "none (plain text)"}\n${text}`;
    },
    send: (release) => {
      const { text, parseMode } = buildTelegramMessage(release);
      const topicId = process.env.TOPIC_ID;
      return postJson(`https://api.telegram.org/bot${requireEnv("BOT_TOKEN")}/sendMessage`, {
        chat_id: requireEnv("CHAT_ID"),
        text,
        disable_web_page_preview: false,
        ...(parseMode && { parse_mode: parseMode }),
        ...(topicId && { message_thread_id: Number(topicId) }),
      });
    },
  },
};

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [channelName, releasePath] = process.argv.slice(2);
  const channel = channels[channelName];
  if (!channel) throw new Error(`Unknown channel "${channelName}", expected discord or telegram`);
  const release = JSON.parse(readFileSync(releasePath, "utf8"));
  if (process.env.DRY_RUN === "true") {
    console.log(`Dry run. Nothing sent.\n--- ${channelName} message below ---`);
    console.log(channel.preview(release));
  } else {
    await channel.send(release);
  }
}
