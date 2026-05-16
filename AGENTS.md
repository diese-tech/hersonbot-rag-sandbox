# Agent Instructions

This repository is a local-first RAG sandbox for the Grid homelab. Keep changes
small, operationally safe, and easy to review.

## Scope Boundaries

- Do not change API behavior unless the user explicitly asks for a runtime fix.
- Do not change Docker ports, host bindings, Qdrant collection behavior,
  embedding model defaults, or script side effects during hygiene-only work.
- Treat `RUNBOOK.md` as the operator source of truth.
- Keep `.env.example` secret-free. Never commit real keys or host-specific
  credentials.

## Expected Layout

- `api/`: FastAPI application code.
- `docs/`: Sample ingestible text files.
- `scripts/`: Operator scripts for smoke testing and Qdrant backup/restore.
- `.github/`: Repository workflow and contribution metadata.

## Validation

For docs and metadata-only changes:

```bash
python -m py_compile api/*.py
git diff --check
```

PowerShell equivalent:

```powershell
python -m py_compile (Get-ChildItem api -Filter *.py).FullName
git diff --check
```

For runtime-affecting changes on the Grid host:

```bash
/opt/grid/repos/hersonbot/scripts/smoke-test.sh
```

If the Docker stack is unavailable, say so clearly in the final handoff and list
which validation was skipped.
