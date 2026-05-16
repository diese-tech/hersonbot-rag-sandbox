## Summary

- 

## Scope

- [ ] Docs or metadata only
- [ ] Runtime behavior change
- [ ] Operational script change

## Safety Checklist

- [ ] API behavior is unchanged, or runtime changes are called out above.
- [ ] Docker ports and localhost-only bindings are unchanged.
- [ ] Qdrant collection, storage, and backup/restore behavior are unchanged.
- [ ] No secrets or host-local `.env` files are included.

## Validation

- [ ] `python -m py_compile api/*.py`
- [ ] `git diff --check`
- [ ] `/opt/grid/repos/hersonbot/scripts/smoke-test.sh` if runtime behavior changed or the stack was touched

## Notes

- 
