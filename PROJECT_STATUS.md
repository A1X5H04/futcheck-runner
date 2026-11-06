# Project status

- Initial portable Runner framework created.
- Includes one example action: `image_generation`.
- SVG rendering uses the native Linebender `resvg` CLI v0.49.0.
- Playwright rendering is an explicit variant pinned to v1.64.1. It is never an automatic fallback.
- A generic GitHub Actions workflow can execute any conforming action discovered by the generic Runner.
- Action variants select execution drivers; the bundled driver is `docker`.
- The GitHub adapter accepts either inline job JSON or a stored `job_id` retrieved from an HTTPS API.
- The local executor fingerprints action contents and reuses matching Docker images on persistent hosts.
- Static validation, shell syntax checks, driver-routing tests, supervisor tests,
  and immutable-outbox acknowledgement tests are included in CI.
- A real Docker image build and render have not been run in the creation environment because Docker is unavailable. GitHub CI includes real SVG and Playwright smoke tests.
