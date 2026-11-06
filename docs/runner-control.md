# Runner control protocol v1

The backend creates an execution UUID before platform dispatch. Every event uses
that UUID, an attempt number and a monotonically increasing sequence.

## Event envelope

Existing fields are preserved; additive identity fields make retries and
platform reconciliation explicit.

```json
{
  "executionId": "11111111-1111-4111-8111-111111111111",
  "jobId": "social-001",
  "attempt": 1,
  "platform": "github",
  "platformRunId": "123456789",
  "seq": 1,
  "timestamp": 1760000000000,
  "status": "STARTED",
  "phase": "starting",
  "code": "RUNNER_STARTED",
  "message": "Runner accepted the job and is starting the worker.",
  "logs": "",
  "result": null,
  "error": null,
  "metadata": {}
}
```

`code` is stable and machine-readable. `message` is user-facing text.

## Events

The Runner emits no progress or heartbeat events.

| Status | Code | Meaning |
| --- | --- | --- |
| `STARTED` | `RUNNER_STARTED` | Preparation and action preflight passed. Worker starts only after acknowledgement. |
| `FAILED` | `CONFIGURATION_INVALID` | Required control configuration is unavailable. |
| `FAILED` | `JOB_VALIDATION_FAILED` | Platform preparation or action preflight failed. |
| `FAILED` | `CALLBACK_UNAVAILABLE` | Startup was not acknowledged; worker did not start. |
| `COMPLETED` | `JOB_COMPLETED` | Worker completed and verified outputs are attached. |
| `FAILED` | `JOB_FAILED` | Worker returned a nonzero result. |
| `FAILED` | `JOB_TIMED_OUT` | Worker exceeded the action variant's execution limit. |
| `FAILED` | `RUNNER_INTERNAL_ERROR` | The Runner failed outside normal worker execution. |
| `CANCELLED` | `JOB_CANCELLED` | Execution was cancelled. |

## Delivery request

```json
{
  "activeJobs": [],
  "events": []
}
```

The backend stores events idempotently by `(executionId, seq)` and applies state
changes atomically before acknowledging them.

## Delivery acknowledgement

For each single-execution batch, the backend responds:

```json
{
  "acceptedThrough": 2,
  "abortJobs": []
}
```

`acceptedThrough` is required. It is the highest sequence durably stored for the
execution. The Runner deletes a pending batch only when this value covers the
batch's highest sequence. Duplicate delivery must return the previously accepted
sequence, making retries safe.

The backend advances `acceptedThrough` only across a contiguous sequence. Event
storage and execution-state mutation occur in one transaction. A terminal state
is idempotent: redelivery of the same `(executionId, seq)` is accepted, while a
different later terminal outcome does not overwrite the first accepted terminal
outcome.

## Endpoint selection

`RUNNER_CONTROL_URL` supplied for the execution is tried first. If it is invalid,
expired or unavailable, the dispatcher tries the configured
`FUTCHECK_CALLBACK_URL` fallback. Both must match the callback hostname allowlist
and use the single `RUNNER_TOKEN`.

If no startup event arrives, or a terminal event misses its backend deadline, the
backend reconciles through the stored platform run ID.

When a terminal event remains unacknowledged after the final delivery window,
the Runner exits with code `74` and retains the immutable pending batch and state
journal for platform reconciliation.
