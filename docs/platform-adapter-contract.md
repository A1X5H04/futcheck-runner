# Platform adapter contract v1

## Dispatch inputs

Every platform dispatch receives:

- `execution_id`: backend-created UUID, required;
- either canonical `job_json` or a `job_id` retrievable from the backend;
- optional `control_url` and opaque runner metadata;
- attempt number and platform correlation data where available.

## Runtime adapter

The platform adapter configures `RUNNER_WORK_DIR`, reporting identity and token,
then calls:

```bash
bash runner/entrypoint.sh \
  --execution-id "$execution_id" \
  --job "$work/job.json" \
  --input "$work/input" \
  --output "$work/output" \
  --prepare "adapters/<platform>/prepare-job.sh"
```

The prepare command receives `RUNNER_JOB_FILE`, `RUNNER_INPUT_DIR`,
`RUNNER_OUTPUT_DIR` and `RUNNER_METADATA_FILE` in its environment and must output
the canonical versioned job envelope. It must not map action names, invent action
defaults or contain action business logic.

## Backend platform implementation

A backend platform plugin implements:

```text
dispatch(execution) -> platformRunId
getStatus(platformRunId)
cancel(platformRunId)
getLogs(platformRunId)
getArtifacts(platformRunId)
```

Adding a platform requires a new adapter/plugin, not changes to Runner core files.
The platform plugin must reject or route an action when its declared timeout
exceeds that platform's own execution limit (the GitHub workflow currently has
a 15-minute limit).
