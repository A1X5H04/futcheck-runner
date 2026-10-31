import fs from 'node:fs/promises';
import path from 'node:path';
import { chromium } from 'playwright';

const jobPath = '/work/job.json';
const outputRoot = '/work/output';
const job = JSON.parse(await fs.readFile(jobPath, 'utf8'));
const payload = job.payload ?? {};
const templateId = payload.template;
const data = payload.data ?? {};
const output = payload.output ?? {};

if (!/^[a-z0-9][a-z0-9-]{0,63}$/.test(templateId ?? '')) {
  throw new Error('Invalid template identifier.');
}
if (!Number.isInteger(output.width) || output.width < 64 || output.width > 4096) {
  throw new Error('Output width must be an integer between 64 and 4096.');
}
if (!Number.isInteger(output.height) || output.height < 64 || output.height > 4096) {
  throw new Error('Output height must be an integer between 64 and 4096.');
}
if (output.format !== 'png') {
  throw new Error('Playwright renderer currently supports PNG output only.');
}

const relativeOutput = output.path ?? 'post.png';
if (relativeOutput.startsWith('/') || !/^[A-Za-z0-9._/-]+\.png$/.test(relativeOutput) || relativeOutput.split('/').includes('..') || relativeOutput.split('/').includes('.') || relativeOutput.split('/').includes('')) {
  throw new Error('Invalid output path.');
}

const templatePath = `/action/templates/${templateId}/index.html`;
let html = await fs.readFile(templatePath, 'utf8');

const escapeHtml = (value) => String(value ?? '')
  .replaceAll('&', '&amp;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;')
  .replaceAll("'", '&#39;');

const replacements = {
  '{{TITLE}}': escapeHtml(data.title),
  '{{SUBTITLE}}': escapeHtml(data.subtitle),
  '{{EYEBROW}}': escapeHtml(data.eyebrow ?? 'FUTCHECK'),
  '{{ACCENT}}': /^#[0-9A-Fa-f]{6}$/.test(data.accentColor ?? '') ? data.accentColor : '#B6F23A',
};
for (const [token, value] of Object.entries(replacements)) {
  html = html.split(token).join(value);
}

const finalOutputPath = path.join(outputRoot, relativeOutput);
await fs.mkdir(path.dirname(finalOutputPath), { recursive: true });

const browser = await chromium.launch({
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
});

try {
  const page = await browser.newPage({
    viewport: { width: output.width, height: output.height },
    deviceScaleFactor: 1,
  });

  // Keep the render deterministic and prevent templates from making network calls.
  await page.route('**/*', async (route) => {
    const url = route.request().url();
    if (url.startsWith('data:') || url.startsWith('file:') || url === 'about:blank') {
      await route.continue();
    } else {
      await route.abort();
    }
  });

  await page.setContent(html, { waitUntil: 'load' });
  await page.screenshot({
    path: finalOutputPath,
    type: 'png',
    fullPage: false,
    animations: 'disabled',
  });
} finally {
  await browser.close();
}
