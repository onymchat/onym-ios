import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { execFileSync } from "node:child_process";

const root = path.resolve(import.meta.dirname, "../..");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "onym-marketing-"));

const campaigns = {
  "en-US": {
    copy: [
      ["Identity stays on your device.", "No phone number. No email. Your keys never leave."],
      ["The messenger is open source.", "Audit the code. Build the app yourself."],
      ["Choose your courier.", "Messages travel over Nostr relays. Run your own."],
      ["Choose your notary.", "Membership is anchored on Stellar, separate from your chats."],
      ["Own the whole path.", "Identity. Messenger. Courier. Notary. No company in the middle."]
    ]
  },
  ru: {
    copy: [
      ["Личность остаётся на устройстве.", "Без номера и почты. Ваши ключи никуда не уходят."],
      ["Мессенджер с открытым кодом.", "Проверьте код. Соберите приложение сами."],
      ["Выберите своего курьера.", "Сообщения идут через релеи Nostr. Запустите свой."],
      ["Выберите своего нотариуса.", "Состав группы закреплён в Stellar отдельно от переписки."],
      ["Владейте всей системой.", "Личность. Мессенджер. Курьер. Нотариус. Без посредника."]
    ]
  }
};

const screenshotNames = [
  "iPhone 17 Pro Max-01_identity.png",
  "iPhone 17 Pro Max-02_create_group.png",
  "iPhone 17 Pro Max-03_chats.png",
  "iPhone 17 Pro Max-04_welcome.png",
  "iPhone 17 Pro Max-05_chat.png"
];

const xml = (value) => value
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(" ", "&#160;");

function wrapText(text, fontSize, maxWidth, maxLines = 2) {
  let size = fontSize;
  while (size >= fontSize * .68) {
    const estimate = (value) => [...value].length * size * .60;
    const lines = [];
    let line = "";
    for (const word of text.split(/\s+/)) {
      const candidate = line ? `${line} ${word}` : word;
      if (line && estimate(candidate) > maxWidth) {
        lines.push(line);
        line = word;
      } else {
        line = candidate;
      }
    }
    if (line) lines.push(line);
    if (lines.length <= maxLines && lines.every((value) => estimate(value) <= maxWidth)) {
      return { lines, size };
    }
    size *= .92;
  }
  return { lines: [text], size };
}

function textElements(lines, x, y, lineHeight, attrs) {
  return lines.map((line, index) =>
    `<text x="${x}" y="${y + index * lineHeight}" ${attrs}>${xml(line)}</text>`
  ).join("");
}

function buildTextSvg(locale, index) {
  const width = 1320;
  const height = 2868;
  const renderCanvas = 2868;
  const left = 82;
  const maxTextWidth = 1156;
  const title = wrapText(campaigns[locale].copy[index][0], 106, maxTextWidth);
  const titleLineHeight = Math.round(title.size * 1.04);
  const titleY = 260;
  const subtitleY = titleY + (title.lines.length - 1) * titleLineHeight + Math.round(title.size * .95);
  const subtitle = wrapText(campaigns[locale].copy[index][1], 38, maxTextWidth, 2);
  const titleMarkup = textElements(
    title.lines, left, titleY, titleLineHeight,
    `fill="#0a0a0a" font-family="SF Pro Display, Helvetica Neue, sans-serif" font-size="${title.size}" font-weight="700" letter-spacing="-4"`
  );
  const subtitleMarkup = textElements(
    subtitle.lines, left + 3, subtitleY, Math.round(subtitle.size * 1.25),
    `fill="#6e6e73" font-family="SF Pro Display, Helvetica Neue, sans-serif" font-size="${subtitle.size}" font-weight="400"`
  );

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${renderCanvas}" height="${renderCanvas}" viewBox="0 0 ${renderCanvas} ${renderCanvas}">
<rect width="${renderCanvas}" height="${renderCanvas}" fill="#00ff00"/>
<text x="${left}" y="91" fill="#6e6e73" font-family="SF Mono, Menlo, monospace" font-size="23" font-weight="600" letter-spacing="6">ONYM&#160;·&#160;PRIVATE&#160;MESSENGER</text>
<text x="1238" y="91" text-anchor="end" fill="#6e6e73" font-family="SF Mono, Menlo, monospace" font-size="23">${String(index + 1).padStart(2, "0")}&#160;/&#160;05</text>
<line x1="${left}" y1="127" x2="1238" y2="127" stroke="#0a0a0a" stroke-opacity=".08"/>
<rect x="570" y="780" width="180" height="54" rx="27" fill="#000000"/>
${titleMarkup}
${subtitleMarkup}
</svg>`;
}

const maskSvg = path.join(tmp, "screen-mask.svg");
fs.writeFileSync(maskSvg, `<svg xmlns="http://www.w3.org/2000/svg" width="2868" height="2868" viewBox="0 0 2868 2868"><rect width="2868" height="2868" fill="#000"/><rect width="840" height="1825" rx="98" fill="#fff"/></svg>`);
execFileSync("/usr/bin/qlmanage", ["-t", "-s", "2868", "-o", tmp, maskSvg], { stdio: "ignore" });
const screenMask = `${maskSvg}.png`;

const shellSvg = path.join(tmp, "iphone-shell.svg");
fs.writeFileSync(shellSvg, `<svg xmlns="http://www.w3.org/2000/svg" width="2868" height="2868" viewBox="0 0 2868 2868">
<rect width="2868" height="2868" fill="#00ff00"/>
<rect x="201" y="720" width="918" height="1905" rx="142" fill="#08080a"/>
<rect x="207" y="726" width="906" height="1893" rx="136" fill="none" stroke="#424247" stroke-width="5"/>
<rect x="193" y="910" width="12" height="104" rx="6" fill="#3a3a3e"/>
<rect x="193" y="1045" width="12" height="174" rx="6" fill="#3a3a3e"/>
<rect x="1115" y="1000" width="12" height="210" rx="6" fill="#3a3a3e"/>
</svg>`);
execFileSync("/usr/bin/qlmanage", ["-t", "-s", "2868", "-o", tmp, shellSvg], { stdio: "ignore" });
const shellLayer = `${shellSvg}.png`;

for (const locale of Object.keys(campaigns)) {
  const outDir = path.join(root, "marketing/screenshots", locale);
  fs.mkdirSync(outDir, { recursive: true });
  screenshotNames.forEach((_, index) => {
    const base = `${String(index + 1).padStart(2, "0")}-onym`;
    const svg = path.join(tmp, `${locale}-${base}.svg`);
    const output = path.join(outDir, `${base}.png`);
    const screenshot = path.join(root, "fastlane/screenshots", locale, screenshotNames[index]);
    const roundedScreen = path.join(tmp, `${locale}-${base}-screen.png`);
    fs.writeFileSync(svg, buildTextSvg(locale, index));
    execFileSync("/usr/bin/qlmanage", ["-t", "-s", "2868", "-o", tmp, svg], { stdio: "ignore" });
    const textLayer = `${svg}.png`;
    execFileSync("/opt/homebrew/bin/ffmpeg", [
      "-y", "-loglevel", "error",
      "-i", screenshot,
      "-i", screenMask,
      "-filter_complex",
      "[0:v]scale=840:1825[shot];[1:v]crop=840:1825:0:0,format=gray[mask];[shot][mask]alphamerge[out]",
      "-map", "[out]", "-frames:v", "1", roundedScreen
    ]);
    execFileSync("/opt/homebrew/bin/ffmpeg", [
      "-y", "-loglevel", "error",
      "-f", "lavfi", "-i", "color=c=0xf5f5f7:s=1320x2868",
      "-i", roundedScreen,
      "-i", textLayer,
      "-i", shellLayer,
      "-filter_complex",
      "[2:v]crop=1320:2868:0:0,format=rgba,colorkey=0x00FF00:0.30:0.10[text];" +
      "[3:v]crop=1320:2868:0:0,format=rgba,colorkey=0x00FF00:0.30:0.10[shell];" +
      "[0:v][shell]overlay=0:0[framed];" +
      "[framed][1:v]overlay=240:760:format=auto[device];" +
      "[device][text]overlay=0:0:format=auto[out]",
      "-map", "[out]", "-frames:v", "1", output
    ]);
    console.log(path.relative(root, output));
  });
}
