// Renders branding/app-icon.svg into Resources/AppIcon.icns and copies it to Resources/AppIcon.svg.
// node branding/make-icns.mjs. Chromium renders the blur filter, which sips and qlmanage do not
// reliably. Needs Playwright: `npm i -D playwright` anywhere, then PLAYWRIGHT=<path to its node_modules/playwright>.
import { readFileSync, copyFileSync, mkdtempSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT ?? 'playwright');

const svg = readFileSync(join(root, 'branding/app-icon.svg'), 'utf8');
const work = mkdtempSync(join(tmpdir(), 'dimmer-icns-'));
const iconset = join(work, 'AppIcon.iconset');
execFileSync('mkdir', ['-p', iconset]);

const browser = await chromium.launch();
const page = await browser.newPage({ deviceScaleFactor: 1 });
const rendered = {};
for (const px of [16, 32, 64, 128, 256, 512, 1024]) {
  await page.setViewportSize({ width: px, height: px });
  await page.setContent(`<style>html,body{margin:0;background:transparent}svg{display:block;width:${px}px;height:${px}px}</style>${svg}`);
  rendered[px] = await page.screenshot({ omitBackground: true, type: 'png' });
}
await browser.close();

const { writeFileSync } = await import('node:fs');
for (const base of [16, 32, 128, 256, 512]) {
  writeFileSync(join(iconset, `icon_${base}x${base}.png`), rendered[base]);
  writeFileSync(join(iconset, `icon_${base}x${base}@2x.png`), rendered[base * 2]);
}
execFileSync('iconutil', ['-c', 'icns', iconset, '-o', join(root, 'Resources/AppIcon.icns')]);
copyFileSync(join(root, 'branding/app-icon.svg'), join(root, 'Resources/AppIcon.svg'));
rmSync(work, { recursive: true });
console.log('Resources/AppIcon.icns and Resources/AppIcon.svg written');
