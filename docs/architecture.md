# Architecture

Futcheck Runner is an execution repository. The backend owns business orchestration, action-to-platform routing, job records, retries, and callbacks.

This repository owns:

- Action manifests and action implementations under `actions/`.
- The common job and result contracts under `contracts/`.
- A small generic executor that discovers an action manifest, selects a declared execution variant, builds its container image, and runs it.
- Platform adapters that materialize jobs and invoke the generic executor.

The generic GitHub workflow is an adapter. It does not contain action business logic. The local adapter uses the same executor. A future Cloud Run adapter can consume the same action bundle and manifest.

## Action versus execution variant

An action identifies the kind of work. An execution variant selects one declared runtime implementation of that action. For the image action, `svg` and `playwright` are variants of `image_generation`, not separate actions.

## Container boundaries

The current example action has separate SVG and Playwright Dockerfiles. This avoids installing a browser in the SVG image. The generic executor selects the Dockerfile using the manifest's selector and the job payload.

A future action may use one Dockerfile for all its work, or offer multiple declared variants. The repository does not require one Docker image per action, but the current generic executor builds the variant image locally from that action's Dockerfile.

## Portability boundary

Platform adapters may receive jobs differently. They must stage the same `/work/job.json`, `/work/input`, and `/work/output` contract and invoke the action's container entrypoint. Action source code must not depend on GitHub environment variables, GitHub APIs, Cloud Run APIs, or backend endpoints.

## Current execution trade-off

The local Docker executor fingerprints the action bundle and reuses the matching local image. Docker also reuses build layers when an updated fingerprint requires a rebuild. GitHub-hosted runners are ephemeral, so an image built during one workflow run is not guaranteed to remain available to the next run. A persistent self-hosted worker, a platform build cache, or a remote image registry can address that later. Image publishing is deliberately not required by this initial repository.
