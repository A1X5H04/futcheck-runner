# Project status

- Initial portable Runner framework created.
- Includes one example action: `image_generation`.
- SVG rendering uses the native Linebender `resvg` CLI v0.49.0.
- Playwright rendering is an explicit variant pinned to v1.64.1. It is never an automatic fallback.
- A generic GitHub Actions workflow can execute any action discovered by the generic Runner.
- The GitHub adapter accepts either inline job JSON or a stored `job_id` retrieved from an HTTPS API.
- The local executor fingerprints action contents and reuses matching Docker images on persistent hosts.
- Static validation, JSON Schema checks, shell syntax checks, JavaScript syntax checks, executor-routing tests, and mocked action-entrypoint tests pass.
- A real Docker image build and render have not been run in the creation environment because Docker is unavailable and outbound network access is blocked. The GitHub CI workflow includes a real SVG container smoke test.
