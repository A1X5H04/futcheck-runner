# template-image.render

Example action bundle for rendering template-based social images.

## Renderers

- `svg` (default): interpolates a local SVG template and rasterizes it with the native `resvg` CLI. The SVG image does not install Node.js.
- `playwright` (explicit): interpolates a local HTML template and screenshots it with Chromium. It is a separate Docker build variant and is never selected as a fallback.

## Payload

See `payload.schema.json` and the example jobs in `../../examples/jobs/`.

## Add templates

- SVG templates live at `templates/<template-id>/template.svg`.
- HTML templates live at `templates/<template-id>/index.html`.
- Supported placeholders in the example are `{{TITLE}}`, `{{SUBTITLE}}`, `{{EYEBROW}}`, and `{{ACCENT}}`.
- The SVG path uses `jq` for safe XML escaping and literal token replacement.
- The HTML path uses HTML escaping before token replacement.

Place licensed `.ttf` or `.otf` files in `assets/fonts/` to make them available to the SVG renderer. The default image also includes DejaVu Sans for the sample template.

The example is intentionally small. Add a richer template composition layer only when real templates require loops, components, text measurement, or layout calculations.
