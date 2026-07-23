# OpenMNK Releases

Installers and auto-update manifests for the OpenMNK desktop app. Download the latest DMG from Releases.

## Agent toolkits

Each agent ships its own self-contained toolkit directory — setup scripts install pinned
dependencies and the agent's tools, and are idempotent (safe to re-run; final output line
is exactly `SETUP-OK` or `SETUP-FAIL:<step>`).

- `tax-analyst/` — the Tax Analyst agent: Python + document libraries (OCR, PDF, office
  files) and the `digitize` command that converts a client intake folder into a
  machine-readable twin.
- `setup/` — general-purpose bootstrap for the default assistant (node, python, uv, and
  optional CLIs, stage-selectable via `-Only`/`--skip`).
