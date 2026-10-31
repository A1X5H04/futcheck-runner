# Adding an action

An action is a self-contained execution bundle. It is not a GitHub workflow and it does not know which platform launches it.

## Required files

```text
actions/<action-folder>/
├── action.json
├── payload.schema.json
├── entrypoint.sh
├── Dockerfile[.<variant>]
└── src/
```

Templates, assets, tests, and a README are optional.

## `action.json`

The manifest declares:

- Stable action ID and version.
- The action entrypoint.
- An optional selector path into `job.json` for choosing a variant.
- A default variant.
- Each variant's Dockerfile and resource/network hints.
- The payload schema path.
- The shared input and output filesystem locations.

The manifest does not contain platform workflow names, cloud job names, backend URLs, or credentials.

The generic executor searches `actions/*/action.json` for the matching action ID. It does not maintain a second hardcoded action registry.

## Execution variants

An action can expose one default execution variant or several variants. For example, `template-image.render` reads `payload.renderer`:

- `svg` selects `Dockerfile.svg` and the resvg CLI.
- `playwright` selects `Dockerfile.playwright` and Chromium.

The action must reject a renderer/variant mismatch. Playwright is never an automatic fallback after an SVG error.

## Entrypoint

The container entrypoint must:

1. Read `/work/job.json`.
2. Validate the common job envelope and its own payload.
3. Read input files only from `/work/input`.
4. Write generated files only to `/work/output`.
5. Write `/work/output/manifest.json` on success and attempt it on failure.
6. Exit `0` on success and nonzero on failure.

Never evaluate shell commands supplied by the job payload. Job data may select known, declared variants, but it must not supply executable paths or Dockerfile paths.

## Container build context

The action directory is the Docker build context. Keep all files required at runtime inside that directory. Do not depend on another action's files or on repository paths outside the action directory.
