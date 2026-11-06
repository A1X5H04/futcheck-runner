# Architecture

Futcheck Runner is a small execution OS with three extension contracts.

```text
platform adapter --prepare--> canonical /work contract
                                  |
generic runner --> execution driver --> action worker
       |
       +--> JSONL outbox --> backend control endpoint
```

## Core responsibilities

The Bash-only core under `runner/` owns:

- execution identity, locking, supervision, timeout and cancellation;
- action discovery and version/variant selection;
- startup acknowledgement and one terminal result event;
- immutable outbox batches and acknowledged delivery;
- result-manifest, path, byte-count and digest verification.

The generic controller contains no action aliases, platform mappings or Docker
commands. Docker is one optional execution driver.

## Platform adapter contract

A platform adapter receives provider-specific input and exposes one executable
prepare command. The command takes configuration from its environment and must:

1. Materialize the canonical job at the path passed to `runner/entrypoint.sh`.
2. Create the input and output directories.
3. Write optional opaque callback metadata to `RUNNER_METADATA_FILE`.
4. Return nonzero on any preparation failure.

The adapter calls `runner/entrypoint.sh` with the backend-created execution UUID,
expected paths and its prepare executable. Preparation runs inside the supervised
lifecycle, so preparation failures become terminal runner events.

Backend-side platform integrations implement `dispatch`, `getStatus`, `cancel`,
`getLogs` and `getArtifacts`. That control-plane interface is outside the Runner
process but uses the same execution UUID and provider run ID.

## Execution driver contract

An action variant names a driver. The generic router exports resolved action and
filesystem context, then invokes:

```text
runner/drivers/<driver>.sh validate|preflight|execute
```

Drivers read the documented `RUNNER_ACTION_*`, `RUNNER_JOB_FILE`,
`RUNNER_INPUT_DIR` and `RUNNER_OUTPUT_DIR` environment variables. A new runtime
is added by adding a driver file; `runner/execute.sh` remains unchanged.

The bundled `docker` driver builds and caches action images, applies declared
resources and executes preflight in an isolated temporary output directory. The
generic controller verifies every successful driver's output contract.

## Action contract

Actions are discovered from `actions/*/action.json`. An action owns its payload
schema, preflight, runtime files and result production. It knows nothing about
GitHub, backend endpoints or orchestration.

## Reporting

Only meaningful events are generated:

1. `STARTED / RUNNER_STARTED`, after platform preparation and action preflight.
2. Exactly one terminal `COMPLETED`, `FAILED` or `CANCELLED` event.

Workers may additionally request a user-facing message through `runner.send`.
Those messages are durable but are not lifecycle events and are never generated
automatically by the Runner.

Every event is appended before delivery. The dispatcher atomically claims source
events into uniquely named immutable pending batches. A batch is deleted only
when the backend explicitly acknowledges every event or message ID in that
specific batch.
Failed batches remain available for retry and platform recovery artifacts.

The backend still owns final reconciliation when an entire execution platform is
lost before the Runner can communicate.
