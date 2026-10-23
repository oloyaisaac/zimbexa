# Security and operations baseline

## Trust boundaries

1. **Client** — future Android/Expo app. It may cache approved minimal data, but it never decides permissions or authoritative stock/finance state.
2. **Supabase Auth** — verified email identity, bounded JWT sessions and password recovery. A claimed title or profile role is not authority.
3. **PostgREST / RPC** — authenticated reads are protected by PostgreSQL RLS. Mutations go through security-definer RPCs that recheck membership, state and revision inside the transaction.
4. **PostgreSQL** — authoritative records, idempotency, immutable ledgers, audit events and transactional outbox. No client-side database credentials.
5. **Supabase Storage** — private bucket. The Storage policy checks a project-scoped upload-intent row; downloads require a fresh authorization check and `available` scan status.
6. **Service workers** — trusted service-role-only boundary for outbox delivery, document scanning and eventual export/deletion processing. These providers/workers are not configured in this repository.

Never embed the `service_role` key in the Android app, browser bundle, analytics, logs or issue tracker. Use provider secret storage for server-only integrations.

## Controls implemented

- **Project isolation:** public project-owned tables have RLS. Queries and helper functions scope by current `auth.uid()` and active project membership. A UUID is an identifier, not permission.
- **Least privilege:** project roles have defaults; protected capabilities require explicit custodian delegation. RLS is the enforcement layer; hiding a frontend button is not enough.
- **Definer hardening:** security-definer functions set an empty `search_path`, schema-qualify relations and are granted per function. Public RPC execution is explicitly revoked then granted to allowed roles.
- **Invitation security:** raw 256-bit invite tokens are returned only on first creation, stored as SHA-256 hashes, time-limited, single-use, and bound to the recipient's verified email. The durable idempotency response deliberately omits the bearer token.
- **Retry safety:** mutations use actor-scoped operation UUIDs with payload hashes. Same operation/same payload replays a stored result; reusing a key for different input fails.
- **Concurrent inventory:** stock balances are row-locked; ledger movement and balance change commit or roll back together. A stock issue that would make a balance negative is rejected. Stock-count approval requires the ledger balance and revision to be unchanged since the count.
- **Finance integrity:** UGX is integer shillings. Cost, advance, cash return, allocation and reported payment are separate records. Manual payment entries stay `user_reported`; an external reference does not imply MoMo/bank verification.
- **Revision history:** reports, milestones, requests, budgets and costs have revision snapshots or review records. Append-only triggers protect audit events, stock movements, status events, revisions and approvals from update/delete.
- **Private evidence:** uploads are type/size-limited (20 MiB); object names are generated from project/document UUIDs. File metadata must exist before upload. Storage reads are blocked until a trusted scan marks the file clean.
- **No silent support takeover:** support cases do not grant operator impersonation; special support grants remain service-side and require reason/approval data.
- **No destructive cascade:** project/workspace records are not deleted when an Auth user is removed. User deletion is a request workflow; deletion execution and retention are not enabled.

## Release gates (closed in a fresh database)

`private.policy_gates` begins with `pending_signoff` for:

- `project_activation` — requires signed-off custody/recovery policy and an accepted independent recovery nominee.
- `custody_transfer` — requires approved operational/contractual transfer rules and independent review.
- `recovery_adjudication` — cannot automatically award custody based on inactivity or submitted files.
- `account_deletion_execution` — requires approved data-rights, retention and responsibility-handling rules.
- `project_closeout_completion` — final completion is separate from a visual progress indicator and requires approval/acknowledgement.
- `project_data_export` — export scope/redaction rights need a documented policy.
- `document_retention_purge` — no arbitrary silent evidence deletion.
- `sensitive_support_access` — privileged support access is not exposed to customers.

The service-only `private.set_policy_gate(...)` function requires a policy version, evidence reference and approving user for `approved`/`enabled` states. Changes are recorded in `private.policy_gate_events` and `audit_events`. `private` is not exposed through PostgREST. Gate changes must be made only by an authorized operator through a reviewed, audited process; do not use direct SQL to bypass a closed gate.

A gate being opened does **not** prove the deployment is safe. The exact approved policy, test evidence, sign-off and provider setup must be independently reviewed first.

## Required before a real pilot

### Product and governance

- Approve owner-/contractor-managed custody terms, who may activate, who nominates/reviews recovery, handover and dispute handling.
- Approve information rights after leaving a project, export scope/redaction, retention schedule, deletion exceptions and external web deletion-request path.
- Approve closeout checklist, outstanding stock/cost exceptions, archive/reopen rules and whether/how disagreement is represented.
- Validate expense approval, cash advance, labor visibility and material-unit workflows with Ugandan site teams.

### Supabase and infrastructure

- Select a dedicated active Supabase project and region with an approved data-location/privacy assessment. The connected project inspected during implementation was inactive in `eu-north-1`; it was not restored or modified.
- Run every migration using the Supabase CLI against a clean Supabase local stack and the selected staging Postgres major version. Review the SQL diff and exercise rollback/restore procedures before production.
- Configure verified-email delivery, allowed redirect URLs, rate limits, abuse controls, password-recovery support and session revocation.
- Configure a private-object scanner (content sniffing, malware inspection, hash verification), outbox delivery, export generation and deletion-request processing. Make each worker idempotent, observable and least-privileged.
- Set up monitored backups, a documented restoration test, managed secrets, TLS, dependency updates, incident response and alerting. The blueprint's proposed pilot RPO/RTO are planning values, not guarantees.

### Security and testing

- Run RLS probes as `anon`, ordinary authenticated members, each project role, a removed member and service role. Include malicious UUID tests for queries, file downloads and exports.
- Test independent Supabase connections racing stock issues (e.g. stock 50, simultaneous issues 30 and 25); only valid committed quantity may remain.
- Test duplicate API retries after timeouts, stale edits, invitation expiry/revocation, removed-member offline submissions and account-recovery abuse.
- Verify Storage cannot be enumerated or read from another project, and that raw bucket access is private.
- Review definer functions, grants, role assignment, audit visibility, PII/log retention and service-role usage against a current ASVS/MASVS security checklist.
- Complete Uganda-specific privacy/legal review before collecting real personal, labor, financial or construction evidence.

## Test limitations

`npm test` uses PGlite (a single-connection PostgreSQL-in-WASM engine) and a small `auth`/`storage` compatibility harness. It applies every migration and tests key stateful workflows and RLS policies. It does not run Supabase Auth, PostgREST, the actual Storage service, concurrent database sessions, a mobile device, backup restore, external email/scanning providers or a production security review. Docker and the Supabase CLI were not available in the implementation environment; the CLI itself was available through `npx`, but no Supabase stack was started.
