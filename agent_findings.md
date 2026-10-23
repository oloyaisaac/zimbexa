# Agent findings and implementation notes

**Source reviewed:** `Zimbexa_V1_Engineering_Architecture_and_Implementation_Blueprint.pdf` (35-page attached blueprint; text extraction at `/tmp/zimbexa-blueprint.txt`). Page numbers below refer to the PDF, not source-text line numbers.

## Product and architecture findings

1. **The blueprint's architecture and the selected backend differ.** The source proposes a React Native/Expo application, Django REST Framework, PostgreSQL and background workers (see architecture/delivery sections, pp. 26–30). The product owner instead selected Supabase for this backend-first phase and deferred the client. The repo consequently models the domain in PostgreSQL and uses Supabase Auth, RLS, PostgREST RPC and Storage. This is a deliberate deviation, not a claim that the original architecture was implemented.
2. **Construction records are evidence, not independent truth.** A submitted report, photograph, receipt, manual cash note or payment reference describes what a user reported. Review or external reconciliation is a distinct status; UI copy must not imply Zimbexa independently verified facts it did not verify (pp. 12–18, 23–25).
3. **Project history must survive user lifecycle changes.** Workspaces, project custody, membership, authored records, account deletion and data portability are separate concerns. Deleting a login must not cascade-delete shared evidence or ledgers; departed users' historical authorship must remain interpretable (pp. 10–12, 18–19, 25, 31).
4. **Custody, contractor authority and legal title are not equivalent.** The app can enforce its own operational role/delegation rules but cannot prove land ownership or adjudicate a dispute. The implemented manager-handover flow has independent review and retains the custodian; custody transfer remains a distinct gated workflow. Recovery, custody changes and ownership-like claims still require human governance and cannot be treated as legal proof (pp. 10–11, 19, 25, 31).
5. **Money needs separate ledgers and clear language.** An approved cost, a payment reported by a user, a confirmed external payment, a cash advance, an allocated expense and a cash return are different facts. The schema preserves these distinctions; no payment collection or MoMo payout is in V1 (pp. 14–16, 20, 24).
6. **Stock request/approval is not procurement or delivery.** Material request approval does not imply an order was placed or material arrived. Inventory should change only from an auditable receipt, issue, return, transfer or approved count adjustment with an explicit unit (pp. 13–14, 19, 23–24).
7. **Progress is not closeout.** A progress percentage is only meaningful when the underlying milestone weights are valid. A photo does not complete a milestone or a project; final closeout needs its own exception list, acknowledgement and approval (pp. 12–13, 17, 19, 24, 29).
8. **Offline writes are proposals until accepted by the server.** The eventual mobile client must show local drafts, queued work, synchronization, conflicts and rejection truthfully. Permissions and membership must be rechecked at sync; offline stock/finance cannot be shown as authoritative (pp. 5–8, 23, 27–28).

## High-risk policy questions deliberately left open

The blueprint identifies open decisions around primary custody, recovery, transfer, account removal, privacy, closeout and export (especially pp. 25 and 31). The implementation uses `pending_signoff` gates rather than selecting a legally consequential rule on the owner's behalf:

- Who may activate a project, and what custody evidence is sufficient?
- How is an independent recovery nominee verified and replaced? Who decides contested cases?
- What notice, waiting period or additional approval is required for custody transfer beyond the independent-review workflow? The code distinguishes manager handover from custody change, but product/legal sign-off is still needed for these governance rules.
- What happens to personal profiles, work authored for other people, shared documents, account identifiers, statutory records and project history on deletion?
- Which project data may an owner, contractor, former member or data subject export? Which third-party or worker details must be excluded or redacted?
- What retention period applies to construction evidence, financial records, worker data, audit events and backups? Who can authorize a purge?
- What items block closeout; how are outstanding stock, cash, disputed costs and dissent recorded; can a closed project reopen?
- What support access is permitted in an incident, and who approves and reviews it?

**No policy gate has been opened.** `private.set_policy_gate(...)` is intentionally service-only and audit-recorded. Closed gates currently cover project activation, custody transfer, recovery adjudication, account-deletion execution, closeout completion, project export, document purge and sensitive support access.

## Implemented domain safeguards

- Project access is derived from current membership and permission data, not a client-supplied role or an unguessable UUID.
- Project RPCs authorize within database transactions; RLS protects reads, and public function execution is revoked before selected functions are granted.
- Manager handovers require version-bound acceptance and independent approval, retain the custodian, and reject a custodian as the new manager; custody transfers remain separately blocked by the closed custody gate.
- Invitations use a 32-byte random token, persist only its SHA-256 digest, bind acceptance to the verified recipient, expire/revoke, allow audited replacement after expiry, limit each project/email to one live invitation, and do not re-expose a bearer token on idempotent replay.
- Operation idempotency is actor-scoped and payload-bound, so retrying one request is safe and changing a payload under the same operation key fails.
- Stock movements and balance changes are atomic; the balance row is locked and negative issues fail. Physical-count submissions bind to a ledger revision.
- Budgets, costs, advance issuance, cost allocation, cash returns and reported payments are separate. UGX amounts use integer shillings. Labor corrections preserve immutable JSON snapshots; wage links require an accepted entry and approved labor cost, and sensitive cost/payment/labor access has narrower permission checks.
- Reports and approvals preserve revision history; the reviewer cannot approve their own submission. Stale revision writes return a conflict rather than overwrite newer state.
- Document paths are generated, buckets are private, record links are same-project, and an available/clean scan is required before reads.
- Outbox events commit with the business transaction; service-only claim/finish RPCs make external side effects retryable without elevating the customer client.
- Append-only triggers protect selected audit, ledger, report and review histories. Membership removal does not cascade through project records.

## Testing and verification findings

- A single PGlite integration test applies the nine migrations and covers important project isolation, invitations/expiry, policy-gate history, manager handover with custody transfer still gated, document scans, stock, finance/labor, report and material-request revisions, null-line validation, budget summaries, closeout, deletion requests and outbox behavior.
- PGlite is a local PostgreSQL-compatible test harness, not a live Supabase deployment. The current harness has a single database connection; it cannot prove multi-session row-lock contention or service concurrency.
- The tests mock enough Auth/Storage surface to exercise SQL policy and function behavior, but they do not replace tests against Supabase Auth, PostgREST, the actual Storage API, verified email, malware scanning or provider delivery.
- Docker and Supabase CLI were unavailable as installed executables in the environment. Supabase CLI can be invoked using `npx`, but without Docker no local Supabase stack was started.
- No existing database upgrade, populated restore, backup recovery point, mobile offline queue, production threat model, independent penetration test or Uganda-specific legal/privacy review was performed.
- Therefore passing `npm test` means the repository's current local test suite passed; it is not a launch gate or a production-readiness statement.

## Source page map

| PDF pages | Relevant areas |
|---:|---|
| 2–4 | Product framing and V1 boundary |
| 5–8 | Mobile/offline, permissions and user flows |
| 9–11 | Identity, workspace/project, custody and recovery |
| 12–13 | Site reports, milestones and progress |
| 14–16 | Materials, stock, finance and labor |
| 16–18 | Documents, notifications, closeout and exports |
| 19–24 | Domain entities, transactions, errors and invariants |
| 25 | Privacy, account lifecycle and governance risks |
| 26–30 | Architecture, implementation stages and delivery/acceptance |
| 31 | Unresolved policy and product decisions |

## Handoff recommendation

Keep changes on `arena/46466686-zimbexa`. The current PGlite suite, documentation check and whitespace check passed on 2026-10-23. Before any pilot, have a Supabase/PostgreSQL reviewer inspect function grants, Storage policy behavior and actual RLS semantics; run against a disposable local Supabase stack, add two-connection stock contention and role-matrix tests, exercise backup restore, configure server workers, and obtain the policy/legal/security approvals listed in [`docs/security-and-operations.md`](docs/security-and-operations.md).
