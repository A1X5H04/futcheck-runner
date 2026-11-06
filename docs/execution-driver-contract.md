# Execution driver contract v1

An action variant selects a driver by name. The generic action router exports:

- `RUNNER_ROOT_DIR`
- `RUNNER_JOB_FILE`
- `RUNNER_INPUT_DIR`
- `RUNNER_OUTPUT_DIR`
- `RUNNER_ACTION_ID`
- `RUNNER_ACTION_VERSION`
- `RUNNER_ACTION_MANIFEST`
- `RUNNER_ACTION_DIR`
- `RUNNER_ACTION_VARIANT`

It then executes `runner/drivers/<name>.sh` with exactly one operation:

- `validate`: validate driver-specific manifest configuration without executing;
- `preflight`: validate action-specific input without durable side effects;
- `execute`: run the worker and return its exit status.

Every variant declares `timeoutSeconds`, `maxInputBytes` and `maxOutputBytes`.
The supervisor independently enforces the resolved timeout, so a defective or
third-party driver cannot leave an execution running forever. Driver-specific
settings belong in the open `config` object; adding them does not change Runner
core or the versioned action schema.

On successful execution, the driver must leave `manifest.json` and optional
`result.json` under `RUNNER_OUTPUT_DIR`. The generic runner enforces the input
and output byte limits and validates the manifest, file paths, byte counts and
digests after every successful driver execution.

Driver files are Bash scripts invoked by the generic executor. Adding a driver
must not require changes to `runner/entrypoint.sh`, `runner/supervisor.sh` or
`runner/execute.sh`.
