# Zimbexa V1 backend API contract

## API transport

Supabase PostgREST exposes client-safe reads from `public` and write operations through `POST /rest/v1/rpc/<function_name>`. The signed-in Supabase access token is sent as a bearer token. The database—not the client—derives the current user from `auth.uid()` and applies RLS and project capabilities. There is no direct Postgres connection in the mobile client and no service-role key in a client build.

The PDF proposed a custom `/api/v1` Django/DRF API. The product owner selected Supabase and asked for backend-first work, so this implementation uses Supabase RPC names as its contract. If a separate versioned HTTP façade is required later, it must call the same database workflows rather than reimplementing authorization in a second place.

## Shared write contract

- Every mutating RPC uses a caller-generated UUID `p_operation_id`. Repeating that operation with the same actor and payload returns the stored result without repeating the business effect. Reusing it with a different operation or payload fails.
- Editable records take an expected revision where applicable. A stale revision returns a conflict; the client should preserve its draft and reload rather than overwrite.
- Amounts are integer UGX shillings. Quantities are `numeric(18,3)` and must use the material's explicit base unit. No implicit unit conversion is performed.
- A successful database write means committed in Supabase. It does not mean an external payment was verified, a photo was scanned, or an email was delivered.
- SQLSTATEs are returned by PostgREST as structured database errors. Suggested client mapping:

| SQLSTATE / message family | Client treatment |
|---|---|
| `28000` | Re-authenticate; do not retry a protected write anonymously. |
| `42501` | Permission denied; do not retry blindly. |
| `P0002` | Not found or out of scope; do not reveal cross-project existence. |
| `22023` | Invalid input; retain draft and show field feedback. |
| `23514` | Business invariant failed; explain the specific safe reason. |
| `23505` | Duplicate or idempotency-key misuse; reload/resolve. |
| `40001` | Revision, stock-count, or governance conflict; refresh and reconcile. |
| `55000` | Invalid lifecycle state or a closed release gate; show pending review/sign-off. |
| `429` / `5xx` from Supabase | Respect provider retry guidance; retry a write only with the same operation UUID. |

## Identity, workspace and project

Supabase Auth provides signup, email confirmation, login, password recovery and session revocation. A database trigger creates a minimal profile when an Auth user is created. Signup confirmation is enabled in `supabase/config.toml`.

| RPC / read | Purpose / authorization |
|---|---|
| `create_workspace(p_name, p_kind, p_operation_id)` | Create a personal/organization workspace and its first admin membership transactionally. |
| `create_project(p_workspace_id, p_name, p_project_type, p_region, p_district, p_town, p_planned_start_date, p_operation_id)` | Create a UUID project in `draft`, assign the creator the operational `custodian` role, create a default stock location and initial governance version. |
| `update_project_details(p_project_id, p_expected_revision, ...details, p_operation_id)` | Update draft/active details using optimistic revision control. |
| `activate_project(p_project_id, p_expected_revision, p_operation_id)` | Requires custodian, a verified independent recovery route and the `project_activation` release gate. The gate is closed by default. |
| `pause_project(p_project_id, p_expected_revision, p_reason, p_operation_id)` | Pause an active project with a reason and history event. |
| `invite_project_member(p_project_id, p_email, p_role, p_permission_keys, p_expires_in_hours, p_operation_id)` | Custodian/manager invite. Manager/accountant invitations and delegated capabilities require custodian authority. A 256-bit bearer token is returned only in the first response; only its SHA-256 hash is stored. Only one live pending invitation per project/email is allowed. Expired pending invitations are marked expired (with audit) when replaced; live duplicate attempts return `invitation_already_pending`. Email delivery is not configured. |
| `revoke_project_invitation(p_project_id, p_invitation_id, p_reason, p_operation_id)` | Revoke an unused invitation. |
| `accept_project_invitation(p_token, p_operation_id)` | Requires a signed-in user with a verified email matching the invitation. Link-forwarding alone cannot grant membership. |
| `revoke_project_member(p_project_id, p_membership_id, p_reason, p_operation_id)` | Revoke active project access; authored history remains. The custodian cannot be removed through this operation. |
| `grant_project_permission(p_project_id, p_user_id, p_permission_key, p_reason, p_operation_id)` | Custodian-only explicit delegation; self-grants are blocked. |
| `project_invitation_summaries` | Sanitized view for users allowed to invite; never returns token hashes. |

## Governance and continuity

| RPC / read | Purpose / authorization |
|---|---|
| `nominate_recovery_route(p_project_id, p_nominee_user_id, p_operation_id)` | Custodian nominates a different active project member; no legal authority is inferred. |
| `accept_recovery_route(p_project_id, p_route_id, p_operation_id)` | Nominee accepts using their own authenticated account. This verifies account control only. |
| `open_recovery_case(p_project_id, p_proposed_successor_id, p_reason, p_contact_attempts, p_evidence_document_ids, p_operation_id)` | Opens a traceable review case; does not change custody. Evidence must already be available in the same project. |
| `propose_project_transfer(...)`, `accept_project_transfer(...)`, `review_project_transfer(...)`, `apply_project_transfer(...)` | Version-bound proposal/acceptance/review with independent approval. A `manager_handover` changes the operational manager while retaining the custodian; `custody_transfer` changes custody and remains blocked by the closed `custody_transfer` gate. |
| `request_account_deletion(p_reason, p_operation_id)` | Records a user deletion request. It does not delete Auth credentials, shared records or evidence. Execution is gated. |
| `open_closeout_case(p_project_id, p_checklist, p_reason, p_operation_id)` | Captures a reviewable closeout proposal and labeled snapshot; it does not set the project to completed. |
| `review_closeout(...)` | Records review/acknowledgement against the case revision. |
| `complete_closeout(p_project_id, p_closeout_case_id, p_operation_id)` | Requires approved review, acknowledgement, no open material requests and the closed `project_closeout_completion` gate. |
| `request_project_export(...)` | Data export is blocked until the `project_data_export` policy gate is approved. |
| `open_support_case(...)` | Creates a support record. A project identifier outside the caller's access is not retained on the ticket. |

These gates exist because the source blueprint explicitly requires business/legal sign-off before public custody transfer, contested recovery, final closeout, deletion/retention and export behavior. The API does not automatically decide property title or resolve disputes.

## Site reports and progress

| RPC / read | Purpose / authorization |
|---|---|
| `create_daily_report(p_project_id, p_report_date, p_work_done, p_labor_summary, p_blockers, p_operation_id)` | Creates a draft report; multiple reports per date are allowed. |
| `save_daily_report_draft(p_project_id, p_report_id, p_expected_revision, ...payload, p_operation_id)` | Saves only an author's draft/changes-requested revision. Submitted history cannot be overwritten. |
| `submit_daily_report(p_project_id, p_report_id, p_expected_revision, p_operation_id)` | Submits online for review. |
| `review_daily_report(p_project_id, p_report_id, p_expected_revision, p_decision, p_comment, p_operation_id)` | A delegated reviewer accepts or requests changes; self-review is blocked. |
| `create_milestone(...)`, `update_milestone(...)` | Store milestones with optional weights and explicit completion fractions. No photo automatically completes a project. |
| `project_progress_summary` | Shows weighted reported progress only when all milestones have weights and total weight is positive; otherwise progress is not calculated. |

## Materials and inventory

| RPC / read | Purpose / authorization |
|---|---|
| `create_material(p_project_id, p_name, p_specification, p_base_unit, p_operation_id)` | Creates project-scoped specification and explicit unit. |
| `create_material_request(p_project_id, p_purpose, p_required_date, p_lines, p_operation_id)` | Creates a draft request from JSON lines; at least one line is required, and every material/unit must match the project catalog. |
| `save_material_request_draft(p_project_id, p_request_id, p_expected_revision, p_purpose, p_required_date, p_lines, p_operation_id)` | Author-only draft/corrections-requested edit; replaces unreceived lines, stores an immutable revision snapshot and increments the revision. |
| `submit_material_request(...)`, `review_material_request(...)` | Submit/review a frozen revision. Creator self-approval is blocked. Approval never adds stock. |
| `mark_material_ordered_external(...)` | Records a manual external purchase state; no marketplace or supplier dependency. |
| `record_stock_movement(p_project_id, p_location_id, p_material_id, p_movement_type, p_quantity_delta, p_request_line_id, p_reason, p_operation_id)` | Locks the stock balance and inserts one immutable movement in the same transaction. Receipts are positive, issues negative; no negative balance. Linked partial receipts update the frozen request line. |
| `submit_stock_count(...)`, `review_stock_count(...)` | Captures a physical count and requires an unchanged ledger revision before an authorized adjustment. A stale count must be repeated. |
| `project_stock_summary` | Authorized project-scoped balance read. |

Offline capture belongs in the later Android client. Until it exists, clients must not show a local receipt/issue as confirmed. A retry uses the original operation UUID; a membership revoked before synchronization must be rejected by the server.

## Finance and labor

| RPC / read | Purpose / authorization |
|---|---|
| `create_budget_version(...)`, `submit_budget_version(...)`, `review_budget_version(...)` | Versioned budget lines; the reviewer cannot approve their own submission. |
| `create_cost_record(...)`, `update_cost_draft(...)`, `submit_cost_record(...)`, `review_cost_record(...)` | Costs are revisioned; approved amounts are not edited in place. |
| `request_cost_adjustment(...)`, `review_cost_adjustment(...)` | Corrections are separate reasoned events and require review. |
| `create_cash_advance(...)`, `issue_cash_advance(...)` | An advance is requested, then issued by a different authorized actor. It is not automatically project spending. |
| `allocate_advance_cost(...)`, `record_cash_return(...)` | Only approved same-project costs can be allocated; allocations plus returns cannot exceed the advance. |
| `report_payment(...)` | Creates a manual payment record with `verification_status = user_reported`. A MoMo/bank reference is not provider confirmation. |
| `create_worker(...)`, `record_labor_entry(...)`, `update_labor_entry(...)`, `review_labor_entry(...)`, `link_labor_cost(...)` | Minimal roster and dated work records. Corrections preserve JSON snapshots and resubmit at a new revision; self-review is blocked. A wage link requires an accepted labor entry and an approved `labor` cost, and general supervisors cannot read private pay links. National IDs are not requested. |
| `project_financial_summary` | Returns approved budget, approved costs, reported payments and independently reconciled payments separately. |
| `cash_advance_summary` | Returns advances, approved-cost allocations, returns and unaccounted cash separately. |

## Documents, notifications and support

- `create_document_upload_intent(...)` validates project permission, MIME type and size (20 MiB maximum); the object path is generated by the backend.
- Upload the file to the private `zimbexa-project-evidence` bucket using the signed-in user's Supabase Storage session and returned object key. Only the exact pending metadata row permits insertion.
- `finalize_document_upload(p_project_id, p_document_id, p_operation_id)` confirms the object exists and its Storage metadata exactly matches the declared size and MIME type, then moves it to `scanning`. Downloads remain denied.
- A trusted scanner calls service-role-only `record_document_scan_result(p_document_id, p_scan_result, p_sha256)` with a 32-byte SHA-256 digest; missing/invalid hashes are rejected. A duplicate callback with the same result and digest is safe to replay. Only `clean` makes the document readable. The scanner/provider is not configured in this repository.
- `app_notifications` is recipient-scoped; `mark_notification_read(p_notification_id)` updates only the caller's inbox. `set_notification_preference(p_event_type,p_in_app_enabled,p_email_enabled,p_operation_id)` is idempotent and updates only the caller's per-event preferences. In-app generation respects `in_app_enabled`; email delivery remains unconfigured and `email_enabled` is only a stored preference.
- `outbox_events` records transactional side effects. Service-role-only `claim_outbox_events(p_worker_id,p_limit)` and `finish_outbox_event(...)` provide retry/lease handling; no email/push provider is configured yet.

## Release and testing boundary

The migration set and PGlite test cover deterministic database workflows. Before using a Supabase environment: review migration diffs; test with Supabase local/target Postgres; run `EXPLAIN` and RLS probes under `anon`, `authenticated`, and service-role identities; test two-session stock contention; validate Storage policies and bucket limits; set a restore-tested backup; configure verification email, scanner, outbox and export/deletion workers; and pass privacy/security/legal review. No remote project was changed in this task.
