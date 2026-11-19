## Summary

Describe the change and why it is needed.

## Checklist

- [ ] Library remains strictly read-only over user PDFs
- [ ] Page semantics (`physical` / `/PageLabels` / `printed`) stay separated and fail-closed
- [ ] `Scripts/preflight.sh` passes locally (privacy gate, project regen, L10n check, zero-warning build, all synthetic tests)
- [ ] No real book titles, personal paths, or credentials in fixtures or docs
