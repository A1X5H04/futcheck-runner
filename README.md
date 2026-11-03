# Futcheck Runner

A portable, Docker-first execution repository for Futcheck automation actions.

The backend owns business orchestration and action-to-platform routing. This repository owns action definitions and execution. Platform adapters prepare the standard `/work` filesystem contract and invoke the generic Runner.

## Current implementation

- One generic action executor: `runner/execute.sh`.
- One generic supervisor: `runner/supervisor.sh`, which captures lifecycle,
  phases and log tails without knowing workflow or checkpoint semantics.
- One singleton outbox relay: `runner/dispatcher.sh`, which batches durable
  JSONL events and retries them until the backend acknowledges them.
- One example action: `image_generation`.
- SVG is the default renderer and uses the native Linebender `resvg` CLI.
- Playwright is an explicit renderer option with a separate image variant. It is never used as an SVG fallback.
- One generic GitHub Actions workflow can execute any action added to the action catalog.
- Jobs are provided inline as JSON or retrieved by job ID from a configured HTTPS API. The adapter materializes either input as `/work/job.json`.
- Local execution uses the same action manifest, job contract, and Docker entrypoint.

## Requirements

For local execution:

- Docker Engine with the Docker CLI.
- `bash`, `jq`, `realpath`, and `sha256sum` on the host.
- Python 3 for `scripts/validate.sh` (validation only).

The SVG action image contains the native `resvg` CLI v0.49.0 and does not require Node.js. The HTML variant uses the official Playwright v1.64.1 container image and the matching Playwright package. Both versions are pinned.

## Run locally

```bash
./scripts/validate.sh
./scripts/run-local.sh examples/jobs/render-svg.json
```

The output is written to `.work/output/`.

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

The workflow checks out this repository, materializes `/work/job.json`, and
invokes the supervisor around `runner/execute.sh`. The adapter publishes the
artifact, writes a result document, and leaves backend delivery to the outbox
dispatcher. The backend supplies opaque checkpoint correlation metadata; the
runner echoes it unchanged.

Required GitHub repository configuration:

- `FUTCHECK_JOB_API_URL` variable: backend base URL.
- `FUTCHECK_CALLBACK_URL` variable: `/api/workflow/runner/webhook/callback`.
- `FUTCHECK_ALLOWED_JOB_HOSTS` variable: exact backend hostname allowlist.
- `FUTCHECK_JOB_TOKEN` secret: same value as the backend's
  `WORKFLOW_RUNNER_SECRET`.

The outbox provides at-least-once delivery. The backend deduplicates events by
the opaque execution id and monotonically increasing sequence number. The job
token is never mounted into an action container or written to `job.json`.

## Add an action

1. Create a directory under `actions/`.
2. Add `action.json`, `payload.schema.json`, an executable `entrypoint.sh`, and one or more Dockerfiles.
3. Add each execution variant to `action.json`. The generic executor reads the manifest and selects the Dockerfile.
4. Make the action consume `/work/job.json`, `/work/input`, and `/work/output`.
5. Write a `manifest.json` using the shared result contract.
6. Add an example job under `examples/jobs/` and tests or validation rules.

The executor discovers actions by reading `actions/*/action.json`. There is no separate in-runner action registry service. The backend still maintains its own action-to-platform mapping.

See [Action authoring](docs/action-authoring.md) and [Execution contract](docs/execution-contract.md).

## Security notes

- Never put credentials or secrets in `job.json`.
- The generic executor accepts only actions present in this repository.
- The action manifest controls the Dockerfile and execution variant. Job data cannot provide shell commands or Dockerfile paths.
- Network access is disabled for action containers by default. Enable it only for actions that need it.
- Job retrieval uses an HTTPS API base URL restricted by an explicit hostname allowlist. Redirects are disabled.
- SVG templates and HTML templates are trusted repository assets. Do not treat user-supplied HTML as trusted code.

## Verification status

The repository validation and static checks can run without Docker. A real container render requires Docker and access to the pinned image/binary sources. Do not treat a successful static validation as proof that the Docker render has run.
