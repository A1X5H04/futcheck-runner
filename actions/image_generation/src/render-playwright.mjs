import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { chromium } from 'playwright';

const job = JSON.parse(await fs.readFile('/work/job.json', 'utf8'));
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

const outputRoot = path.resolve('/work/output');
const relativeOutput = output.path ?? 'post.png';
if (
  path.isAbsolute(relativeOutput) ||
  !/^[A-Za-z0-9][A-Za-z0-9._/-]*\.png$/.test(relativeOutput) ||
  relativeOutput.split('/').some((part) => !part || part === '.' || part === '..')
) {
  throw new Error('Invalid output path.');
}
const finalOutputPath = path.resolve(outputRoot, relativeOutput);
if (!finalOutputPath.startsWith(`${outputRoot}${path.sep}`)) {
  throw new Error('Output path resolves outside the output directory.');
}

const templateDirectory = `/action/templates/${templateId}`;
const templatePath = path.join(templateDirectory, 'index.html');
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

// Keep relative template assets local and block every remote request.
const baseHref = pathToFileURL(`${templateDirectory}${path.sep}`).href;
if (/<head(?:\s[^>]*)?>/i.test(html)) {
  html = html.replace(/<head(?:\s[^>]*)?>/i, (head) => `${head}<base href="${baseHref}">`);
} else {
  html = `<base href="${baseHref}">${html}`;
}

await fs.mkdir(path.dirname(finalOutputPath), { recursive: true });
const browser = await chromium.launch({
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--allow-file-access-from-files'],
});

try {
  const page = await browser.newPage({
    viewport: { width: output.width, height: output.height },
    deviceScaleFactor: 1,
  });

  await page.route('**/*', async (route) => {
    const url = route.request().url();
    if (url.startsWith('data:') || url.startsWith('file:') || url === 'about:blank') {
      await route.continue();
    } else {
      await route.abort('blockedbyclient');
    }
  });

  await page.setContent(html, { waitUntil: 'load' });
  await page.evaluate(async () => {
    await document.fonts.ready;
    const images = Array.from(document.images);
    await Promise.all(images.map(async (image) => {
      if (!image.complete) {
        await new Promise((resolve, reject) => {
          image.addEventListener('load', resolve, { once: true });
          image.addEventListener('error', () => reject(new Error(`Failed to load image: ${image.src}`)), { once: true });
        });
      }
      if (image.naturalWidth === 0) {
        throw new Error(`Image could not be loaded: ${image.src}`);
      }
      if (typeof image.decode === 'function') await image.decode();
    }));
  });

  await page.screenshot({
    path: finalOutputPath,
    type: 'png',
    fullPage: false,
    animations: 'disabled',
  });

  const png = await fs.readFile(finalOutputPath);
  if (png.length < 24 || !png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    throw new Error('Playwright did not produce a valid PNG file.');
  }
  const actualWidth = png.readUInt32BE(16);
  const actualHeight = png.readUInt32BE(20);
  if (actualWidth !== output.width || actualHeight !== output.height) {
    throw new Error(`PNG dimensions are ${actualWidth}x${actualHeight}; expected ${output.width}x${output.height}.`);
  }
} finally {
  await browser.close();
}
