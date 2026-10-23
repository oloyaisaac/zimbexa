# Changelog

All notable changes to the Zimbexa backend implementation are recorded here. This repository began as a README-only baseline; there is not yet a public release.

## [Unreleased] — 2026-10-23

### Added
- Translated the supplied Zimbexa V1 engineering blueprint into a traceable `PRD.json`, `requirements.json`, and `requirements.md`.
- Added a Supabase/PostgreSQL backend foundation: ordered migrations, project-scoped roles/RLS, idempotent workflow RPCs, audit history, transactional outbox, private evidence bucket policies and finance/stock summaries.
- Added workflows for workspace/project creation, invitations, recovery nomination/cases, site reports, milestones, material requests, stock movements/counts, budgets, costs, cash advances, payments reported outside Zimbexa, labor, documents, support and closeout proposals.
- Added closed-by-default governance/policy gates for activation, custody transfer, recovery decisions, account deletion, closeout completion, exports, document purge and sensitive support access.
- Added revisioned labor correction snapshots, per-event in-app notification preferences, audited expired-invite replacement, mandatory document scan SHA-256 digests and null-safe revision-conflict checks.
- Added author-only, revisioned material-request corrections, null-safe material/budget line validation, budget summaries, append-only policy-gate history coverage, and independent-review manager handovers that do not require the closed custody-transfer gate.
- Added PGlite database integration tests and handoff/security documentation for the later Android frontend team.

### Changed
- Replaced the one-line README with backend setup, architecture, testing and release-readiness guidance.
- Adopted the product owner's selected Supabase backend for this phase instead of the PDF's proposed Django/DRF service. The native Android/Expo frontend is deferred as requested.

### Not included / not released
- No Android UI, production deployment, real-user seed data, remote database changes, email provider, malware scanner, export/deletion worker, legal approval or production security certification.
- The inactive connected Supabase project was not restored or modified.
