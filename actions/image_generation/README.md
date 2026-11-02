# image_generation

This is a software rendering action. The `image_generation` identifier is an internal Runner action ID. It converts existing, trusted SVG or HTML templates into PNG files. It does not generate image content and does not call an image model.

## Renderers

- `svg` is the default. It uses the native Linebender `resvg` CLI. The SVG image does not install Node.js.
- `playwright` is an explicit HTML rendering option. It uses Chromium in a separate Docker image. It is never selected as a fallback after an SVG error.

## Payload

See `payload.schema.json` and the example jobs in `../../examples/jobs/`.

Required payload fields are `template`, `data`, and `output`. `renderer` defaults to `svg`.

### SVG fit modes

`fitMode` applies to the SVG renderer:

- `contain`: preserve the full design and add transparent space where needed.
- `cover`: fill the requested canvas and crop overflow.
- `stretch`: fill the requested canvas without preserving the source aspect ratio.

All modes produce a PNG with the exact requested width and height. The HTML renderer uses the requested dimensions as its browser viewport and clips content outside that viewport.

## Templates and assets

- SVG templates live at `templates/<template-id>/template.svg`.
- HTML templates live at `templates/<template-id>/index.html`.
- Supported placeholders are `{{TITLE}}`, `{{SUBTITLE}}`, `{{EYEBROW}}`, and `{{ACCENT}}`.
- Values are XML-escaped or HTML-escaped before substitution.
- Local template assets can be referenced with relative paths. Remote requests are blocked.
- Put licensed `.ttf` or `.otf` files in `assets/fonts/` for the SVG renderer.

Templates are trusted repository code. Do not place untrusted user HTML or SVG in this action bundle. If end users need to supply templates, introduce a separate sanitization and isolation boundary first.

## Output

The action writes PNG files under `/work/output` and a common `manifest.json`. The manifest records the exact dimensions, file size, SHA-256, renderer, engine version, and execution timing.
