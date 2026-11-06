# Adding an action

An action is a self-contained execution bundle. It is not a GitHub workflow and it does not know which platform launches it.

## Required files

```text
actions/<action-folder>/
├── action.json
├── payload.schema.json
├── entrypoint.sh
├── Dockerfile[.<variant>] # when using the Docker driver
└── src/
```

Templates, assets, tests, and a README are optional.

## `action.json`

The manifest declares:

- Stable action ID and version.
- The action entrypoint.
- An optional selector path into `job.json` for choosing a variant.
- A default variant.
- Each variant's execution driver, driver configuration and resource hints.
- The payload schema path.
- The shared input and output filesystem locations.

The manifest does not contain platform workflow names, cloud job names, backend URLs, or credentials.

The generic executor searches `actions/*/action.json` for the matching action ID. It does not maintain a second hardcoded action registry.

## Execution variants

An action can expose one default execution variant or several variants. For example, `image_generation` reads `payload.renderer`:

- `svg` selects `Dockerfile.svg` and the resvg CLI.
- `playwright` selects `Dockerfile.playwright` and Chromium.

Both variants currently select the `docker` execution driver. Another action can
select another installed driver without changing the generic executor.

The action must reject a renderer/variant mismatch. Playwright is never an automatic fallback after an SVG error.

## Preflight

Actions may declare `execution.preflight`; it defaults to the action entrypoint.
The runner invokes that command with `--preflight` inside the selected container
before sending the runner-started acknowledgement. It must validate the
action-specific payload and exit without producing side effects or outputs.

## Entrypoint

The container entrypoint must:

1. Read `/work/job.json`.
2. Validate the common job envelope and its own payload.
3. Read input files only from `/work/input`.
4. Write generated files only to `/work/output`.
5. Write `/work/output/manifest.json` on success and attempt it on failure.
6. Exit `0` on success and nonzero on failure.

An action may write `/work/output/result.json` for action-owned result data.
If an artifact must be published to an external service, implement that in the
action (or its dedicated worker-side publisher) and declare the required network
access in the action manifest. The generic runner never owns publisher logic or
publisher credentials.

Never evaluate shell commands supplied by the job payload. Job data may select known, declared variants, but it must not supply executable paths or Dockerfile paths.

## Docker build context

For Docker variants, the action directory is the build context. Keep all files
required at runtime inside that directory. Do not depend on another action's
files or on repository paths outside the action directory.
