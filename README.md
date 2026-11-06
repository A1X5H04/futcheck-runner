# Futcheck Runner

A portable, contract-driven execution repository for Futcheck automation actions.

The backend owns business orchestration and action-to-platform routing. This repository owns action definitions and execution. Platform adapters prepare the standard `/work` filesystem contract and invoke the generic Runner.

## Current implementation

- One generic action router: `runner/execute.sh`, which delegates runtime work
  to the driver selected by the action variant.
- One generic OS entrypoint: `runner/entrypoint.sh`, used by adapters to run
  validation, startup acknowledgement, supervision, and execution consistently.
- One generic supervisor: `runner/supervisor.sh`, which emits only startup and
  terminal events.
- One outbox relay: `runner/dispatcher.sh`, which uses immutable JSONL batches
  and sequence acknowledgements.
- One example action: `image_generation`.
- SVG is the default renderer and uses the native Linebender `resvg` CLI.
- Playwright is an explicit renderer option with a separate image variant. It is never used as an SVG fallback.
- One generic GitHub Actions workflow can execute any action added to the action catalog.
- Jobs are provided inline as JSON or retrieved by job ID from a configured HTTPS API. The adapter materializes either input as `/work/job.json`.
- Local execution uses the same action manifest, job contract, and Docker entrypoint.

## Requirements

For local execution:

- Docker Engine with the Docker CLI.
- `bash`, GNU `timeout`, `jq`, `realpath`, `sha256sum`, `flock`, and standard
  coreutils (`du`, `stat`) on the host.
- Python 3 for `scripts/validate.sh` (validation only).

The SVG action image contains the native `resvg` CLI v0.49.0 and does not require Node.js. The HTML variant uses the official Playwright v1.64.1 container image and the matching Playwright package. Both versions are pinned.

## Run locally

```bash
./scripts/validate.sh
./scripts/run-local.sh examples/jobs/render-svg.json
```

The output is written under `.work/<execution-id>/output/`. Set
`FUTCHECK_WORK_DIR` when a fixed local destination is preferred.

Run the Playwright variant explicitly:

```bash
./scripts/run-local.sh examples/jobs/render-playwright.json
```

The executor fingerprints the action bundle and reuses the matching local Docker image. On a persistent machine, unchanged action images are not rebuilt. A fresh GitHub-hosted runner does not retain its local Docker image cache between workflow runs.

## Job input

Every action receives one common job envelope:

```json
{
  "schemaVersion": 1,
  "jobId": "social-001",
  "action": "image_generation",
  "actionVersion": "1.0.0",
  "payload": {}
}
```

The `payload` is action-specific. The action's `payload.schema.json` describes it.

The host adapter prepares:

```text
/work/
├── job.json       # read-only job envelope
├── input/         # read-only job assets
└── output/        # writable action results
```

The action writes `/work/output/manifest.json` on success and attempts to write it on failure.

## GitHub Actions adapter

The generic workflow is `.github/workflows/execute.yml`.

It supports either:

- `job_id`: the ID of a job stored by Futcheck. Configure the repository variable `FUTCHECK_JOB_API_URL` with the base endpoint, the secret `FUTCHECK_JOB_TOKEN` with an internal API token, and `FUTCHECK_ALLOWED_JOB_HOSTS` with the exact API hostname (comma-separated if needed).
- `job_json`: the complete JSON job, useful for local testing and small manual runs.

The workflow starts the supervisor first; the GitHub prepare hook then
materializes the canonical job inside that lifecycle. The worker writes its result
document and the adapter leaves backend delivery to the outbox dispatcher. The
GitHub artifact is retained for seven days; any external artifact publication
must be implemented by the relevant worker, not by the generic runner or
adapter. The backend supplies opaque checkpoint correlation metadata; the
runner echoes it unchanged.

Required GitHub repository configuration:

- `FUTCHECK_JOB_API_URL` variable: backend base URL.
- `FUTCHECK_CALLBACK_URL` variable: `/api/workflow/runner/webhook/callback`.
- `FUTCHECK_ALLOWED_CALLBACK_HOSTS` variable: exact callback hostname allowlist.
- `FUTCHECK_ALLOWED_JOB_HOSTS` variable: exact backend hostname allowlist.
- `FUTCHECK_JOB_TOKEN` secret: same value as the backend's
  `WORKFLOW_RUNNER_SECRET`.

Every dispatch must provide `execution_id`, a UUID created and persisted by the
backend before it calls the platform.

Before GitHub starts a worker, the generic OS entrypoint validates the job and
action, then the supervisor validates the HTTPS control URL, token, and callback
hostname allowlist. It synchronously delivers `STARTED` / `RUNNER_STARTED`; if
that acknowledgement fails, the worker is refused and the workflow fails. The
per-run `control_url` workflow input takes priority over `FUTCHECK_CALLBACK_URL`;
the latter remains a fallback. A broken callback cannot receive its own refusal
event, so that failure is retained in the outbox and visible in the workflow result.

The outbox provides at-least-once delivery. The backend deduplicates events by
execution ID and sequence, then returns `acceptedThrough`. The job
token is never mounted into an action container or written to `job.json`.
The outbox retains lifecycle events, a terminal state journal, and logs. On
GitHub, that recovery evidence is uploaded as a seven-day artifact even when
execution fails or callback delivery remains unavailable.

## Add an action

1. Create a directory under `actions/`.
2. Add `action.json`, `payload.schema.json`, an executable `entrypoint.sh`, and the files needed by its selected driver.
3. Add each execution variant to `action.json`, including its `driver`.
   Optionally declare a `preflight` command that accepts `--preflight` to
   validate action-specific input before the runner-started acknowledgement.
4. Make the action consume `/work/job.json`, `/work/input`, and `/work/output`.
5. Write a `manifest.json` using the shared result contract, plus an optional
   `result.json` if the action has result data for the backend.
6. Add an example job under `examples/jobs/` and tests or validation rules.

The executor discovers actions by reading `actions/*/action.json`. There is no separate in-runner action registry service. The backend still maintains its own action-to-platform mapping.

See [Action authoring](docs/action-authoring.md), [Execution contract](docs/execution-contract.md),
[Execution driver contract](docs/execution-driver-contract.md), and
[Platform adapter contract](docs/platform-adapter-contract.md). Backend control
messages are defined in [Runner control protocol](docs/runner-control.md).

## Security notes

- Never put credentials or secrets in `job.json`.
- The generic executor accepts only actions present in this repository.
- The action manifest controls the execution driver and variant. Job data cannot provide shell commands or runtime paths.
- Network access is disabled for action containers by default. Enable it only for actions that need it.
- Job retrieval uses an HTTPS API base URL restricted by an explicit hostname allowlist. Redirects are disabled.
- GitHub control delivery is HTTPS-only and restricted by an explicit callback hostname allowlist; a per-run control URL may override only the configured fallback URL.
- The OS verifies result identity, output paths, output byte counts, and SHA-256 values before it reports job success.
- SVG templates and HTML templates are trusted repository assets. Do not treat user-supplied HTML as trusted code.

## Verification status

The repository validation and static checks can run without Docker. A real container render requires Docker and access to the pinned image/binary sources. Do not treat a successful static validation as proof that the Docker render has run.
