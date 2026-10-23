# Zimbexa — V1 backend

**Building Made Smarter** · Construction operations for Ugandan project teams.

This repository now contains the backend foundation for the Zimbexa V1 blueprint. The work is intentionally **backend-first**: the Android/Expo client is deferred, as requested. This is a Supabase implementation of the selected backend—not the blueprint's proposed Django/DRF API—and the change is recorded in the PRD and findings.

> **Release status: engineering foundation, not production-approved.** The blueprint leaves custody/recovery, retention/deletion, export rights and final closeout policies awaiting sign-off. Those workflows are represented, but protected actions are closed by default. Do not use this backend with real customer records or claim it is production-ready until the release gates below are completed.

## What is included

- Supabase Auth configuration for verified email signup and 12-character minimum passwords.
- PostgreSQL schema and ordered migrations for profiles, workspaces, projects, memberships, invitations, governance, reports, milestones, materials, stock, budgets, costs, cash advances, labor, private document metadata, notifications, outbox, audit, exports and support cases.
- Row-level security on public data; scoped reads and permission-checked write RPCs. Direct client table writes are not granted for business records.
- Idempotency keys for mutating workflows, optimistic revisions on editable records, append-only audit/history records, transactional stock balances and separate reported-payment/cost/advance ledgers.
- A private evidence bucket with upload intents, record-level project checks and a scan-before-download state.
- Local PostgreSQL-in-WASM integration tests using PGlite. No production seed data is included.
- The requested project handoff files: `changelog.md`, `PRD.json`, `requirements.json`, `requirements.md`, `agent_state.md`, and `agent_findings.md`.

## Quick checks

```bash
npm install
npm test
npm run check
```

The tests apply every migration to an ephemeral PostgreSQL-compatible database and exercise role/RLS boundaries, invitations and expiry, idempotent retries, author-only material-request revisions, null-safe budget/material validation, stock, costs and adjustments, advances, labor correction/pay visibility, reports, manager handover versus gated custody transfer, append-only gate history, document scan/hash access, notification preferences and closed release gates. PGlite is a useful local regression check; it is **not** a substitute for testing the migrations on Supabase, multi-connection concurrency tests, a security review or a real Android device.

## Run Supabase locally

Docker and the Supabase CLI are required for the full local Supabase stack. Docker was unavailable in this sandbox; the CLI was not preinstalled but can be invoked with `npx`. The full Supabase runtime was therefore not started here.

```bash
npx supabase start
npx supabase db reset
```

Signup confirmation emails are captured by the local Supabase mail inbox. Migrations are in `supabase/migrations/`; there is no seed file and no fabricated customer data. The project creates a private Storage bucket named `zimbexa-project-evidence`.

To inspect local services, run `npx supabase status`. Do not put a Supabase service-role key in browser/mobile code or commit secrets. When a frontend is built, it should use the public/anon key with a signed-in user session; the database still enforces permissions server-side.

## Backend shape

- **Identity:** Supabase Auth owns credentials and verified email. A trigger creates only a minimal profile; account identity is not project authority.
- **Database/API:** Supabase PostgreSQL is the authoritative store. Reads use RLS-scoped PostgREST queries. Business writes use named RPCs in `public` under `/rest/v1/rpc/<function_name>`.
- **Permissions:** roles are project-scoped; optional delegated capabilities are explicit. Supplied project IDs are not treated as authorization.
- **Evidence:** file bytes stay in a private bucket. An upload-intent row is required, and the file stays unreadable until a trusted scanner records a clean result.
- **Side effects:** operations can enqueue durable outbox rows. Email delivery, antivirus scanning, exports and operational monitoring still need configured workers/providers before a pilot.
- **Money and inventory:** UGX is integer shillings; stock is an immutable movement ledger with a transactionally locked balance; advance money is not itself an expense; manual payments remain `user_reported`.

See [`contracts/backend-api.md`](contracts/backend-api.md) for the RPC contract and [`docs/security-and-operations.md`](docs/security-and-operations.md) for controls, gates and the deployment checklist.

## Closed release gates

The migration seeds these policy gates as `pending_signoff`: project activation, custody transfer, recovery adjudication, account-deletion execution, closeout completion, project export, evidence purge, and sensitive support access. An activation also requires an accepted independent recovery nominee. A service-role-only gate function requires a policy version and evidence reference; every change is audited. The backend does not infer legal ownership from role labels, names, uploads or inactivity.

Before a pilot, the product owner must approve the applicable Uganda-specific privacy/retention, custody/recovery, deletion/export and closeout rules. Then a qualified security reviewer must test the exact Supabase deployment, RLS, restore process, Storage policies, provider integrations and backup recovery. This repo does not itself constitute legal advice, security certification or permission to launch.

## Cloud project status

The connected Supabase account exposed an inactive project named **“oloyaisaac’s Project”** in `eu-north-1`. Per your direction, no cloud project was restored, created or modified. These migrations are versioned in Git and ready for a deliberate local/approved environment after review.
