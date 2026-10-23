# Zimbexa V1 requirements

**Source:** `Zimbexa_V1_Engineering_Architecture_and_Implementation_Blueprint.pdf` (engineering baseline 1.0, 21 October 2026). This file is the human-readable companion to [`requirements.json`](requirements.json).

## Status legend

- **Implemented + tested** — present in database/RPC code and covered by local PGlite checks; this is not production certification.
- **Implemented, gate closed** — data model/flow exists, but the final protected transition is disabled pending explicit sign-off.
- **Implemented, runtime pending** — code exists but needs actual Supabase services or an unconfigured external worker/provider.
- **Schema/contract only** — storage/API contract exists, but not a complete production operation.
- **Deferred** — later client/product phase.

## Identity, tenant and project

| ID | Requirement | Priority | Status |
|---|---|---:|---|
| AUTH-01 | Verified email identity, minimal profile, separate identity from project authority. | MUST | Implemented; actual Supabase Auth runtime not started here. |
| WS-01 | Create personal/organization workspace plus first admin atomically; reads are membership-scoped. | MUST | Implemented + tested. |
| PRJ-01 | Create durable UUID project in `DRAFT`; assign custodian; preserve records independently of the creator account. | MUST | Implemented + tested. |
| PRJ-02 | Require a signed-off policy and accepted independent recovery route before project activation. | MUST | Implemented; activation gate is closed by default. |
| MEM-01 | Use expiring, single-use invitations bound to the intended verified identity. | MUST | Implemented + tested; email delivery remains unconfigured. |
| MEM-02 | Scope memberships and delegated permissions per project; revoke access without deleting authored history. | MUST | Implemented + tested. |

## Governance and continuity

| ID | Requirement | Priority | Status |
|---|---|---:|---|
| GOV-01 | Distinguish manager handover from custody transfer, preserve versioned approvals and reject stale governance. | MUST | Manager handover + independent review tested; custody transfer remains gated. |
| GOV-02 | Open a traceable recovery case; never auto-award authority based on inactivity or submitted documents. | MUST | Case opening implemented; adjudication gate closed. |
| PRIV-01 | Track account deletion requests without cascading shared project history; execute deletion only under approved retention rules. | MUST | Request-only path implemented; execution gate closed. |
| PRIV-02 | Provide scoped, auditable project export with redaction and expiry rules. | MUST | Request schema exists; export gate closed and generator not configured. |

## Construction operations

| ID | Requirement | Priority | Status |
|---|---|---:|---|
| SITE-01 | Support multiple daily reports, revision history, submission and independent review. | MUST | Implemented + tested. |
| SITE-02 | Calculate milestone progress only from valid weights and reviewed completion fractions. | MUST | Implemented + tested; otherwise reports “not calculated.” |
| MAT-01 | Create explicit-unit material requests; allow changes-requested corrections with snapshots; bind independent approval to a frozen revision; approval is not stock. | MUST | Implemented + PGlite tested. |
| MAT-02 | Record stock as immutable movements; lock balances; reject negative stock, duplicate retries and stale counts. | MUST | Implemented + tested sequentially; multi-connection contention remains a required Supabase test. |
| DOC-01 | Keep photos/receipts/plans in private storage; authorize every object and require a clean scan before read. | MUST | Policies and lifecycle implemented; real Storage/scanner runtime pending. |

## Finance and labor

| ID | Requirement | Priority | Status |
|---|---|---:|---|
| FIN-01 | Separate approved budget, incurred cost, review and correction events; store UGX as integer shillings. | MUST | Implemented; approval path tested. |
| FIN-02 | Treat advances as funds transferred to a custodian, not costs; track approved cost allocations and cash returns separately. | MUST | Implemented + tested against the UGX 500k / 320k / 80k example. |
| FIN-03 | Mark manual bank/MoMo records as user-reported unless independently reconciled. | MUST | Implemented + tested; no payment provider is integrated. |
| LAB-01 | Use a minimal project worker roster and attendance; preserve correction snapshots; do not require national ID; hide private pay details from general viewers. | MUST | Implemented + PGlite tested; live Supabase role matrix still needs review. |

## System operations and exclusions

| ID | Requirement | Priority | Status |
|---|---|---:|---|
| NOT-01 | Write durable notification/outbox events transactionally, respect in-app preferences, and support safe worker retry. | SHOULD | In-app preferences and service-only lease RPCs implemented; email/push provider not configured. |
| END-01 | Treat closeout proposal, review, completion and archive as separate lifecycle events. | MUST | Proposal/review implemented; final completion gate closed; archive/reopen needs a signed-off policy. |
| OPS-01 | Use ordered additive migrations, stable UUIDs, tested backup restore and upgrade path. | MUST | Initial migrations and PGlite tests implemented; Supabase restore/upgrade test remains pending. |
| MOB-01 | Future Android client must show local-only/sending/synced/conflict/rejected states and secure offline storage. | MUST | Deferred to the Android frontend phase. |
| FUT-01 | Exclude marketplace, payment collection, subscriptions and AI decisions from free V1. | MUST | Respected; only human-reported payment notes exist. |

## Non-negotiable release checks

1. No cross-project read from tables, Storage, dashboard views, support, notifications or exports.
2. No sensitive mutation without current server-side permission, valid state/revision and idempotency check.
3. No negative committed inventory balance and no duplicate movement from a retry.
4. Cost is not payment; cash advance is not expense; user-entered payment reference is not provider confirmation.
5. Project records outlive membership changes; project custody is not inferred as legal title.
6. No final activation, contested recovery, custody transfer, deletion/retention purge, export or closeout completion while the corresponding sign-off gate is closed.
7. Passing `npm test` is not launch approval. Real Supabase, two-session concurrency, Storage, restore, security and Uganda privacy/legal checks remain mandatory.
