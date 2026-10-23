-- Governance decisions remain data-backed but release-gated pending policy sign-off.
-- No user-facing function in this migration grants legal title or silently deletes history.

create table public.transfer_approvals (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  transfer_proposal_id uuid not null references public.transfer_proposals(id) on delete restrict,
  governance_version integer not null check (governance_version > 0),
  approver_id uuid not null references auth.users(id) on delete restrict,
  decision text not null check (decision in ('approved', 'rejected')),
  reason text check (reason is null or char_length(reason) <= 2000),
  created_at timestamptz not null default now(),
  unique (transfer_proposal_id, approver_id)
);

create table public.recovery_case_events (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  recovery_case_id uuid not null references public.recovery_cases(id) on delete restrict,
  actor_id uuid references auth.users(id) on delete set null,
  event_type text not null check (event_type in ('opened', 'evidence_added', 'review_started', 'restricted', 'decision_recorded', 'closed')),
  details jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),
  created_at timestamptz not null default now()
);

create table public.closeout_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  closeout_case_id uuid not null references public.closeout_cases(id) on delete restrict,
  acknowledged_by uuid not null references auth.users(id) on delete restrict,
  acknowledgement text not null check (acknowledgement in ('approved', 'changes_required', 'disputed')),
  case_revision integer not null check (case_revision > 0),
  comment text check (comment is null or char_length(comment) <= 2000),
  created_at timestamptz not null default now(),
  unique (closeout_case_id, acknowledged_by, case_revision)
);

create table public.export_access_log (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  export_job_id uuid not null references public.export_jobs(id) on delete restrict,
  accessed_by uuid references auth.users(id) on delete set null,
  action text not null check (action in ('requested', 'generated', 'downloaded', 'expired', 'revoked')),
  request_id text,
  created_at timestamptz not null default now()
);
create index export_access_log_job_idx on public.export_access_log (export_job_id, created_at desc);

create table public.support_case_events (
  id uuid primary key default gen_random_uuid(),
  support_case_id uuid not null references public.support_cases(id) on delete restrict,
  actor_id uuid references auth.users(id) on delete set null,
  event_type text not null check (event_type in ('created', 'triaged', 'access_requested', 'access_granted', 'decision_recorded', 'resolved', 'closed')),
  details jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),
  created_at timestamptz not null default now()
);

create table public.support_access_grants (
  id uuid primary key default gen_random_uuid(),
  support_case_id uuid not null references public.support_cases(id) on delete restrict,
  operator_user_id uuid not null references auth.users(id) on delete restrict,
  approved_by uuid references auth.users(id) on delete restrict,
  reason text not null check (char_length(btrim(reason)) between 10 and 1000),
  status text not null default 'pending' check (status in ('pending', 'approved', 'revoked', 'expired')),
  requested_at timestamptz not null default now(),
  expires_at timestamptz not null,
  approved_at timestamptz,
  check (expires_at > requested_at),
  check (approved_by is null or approved_by <> operator_user_id)
);

create table public.app_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null references auth.users(id) on delete restrict,
  project_id uuid references public.projects(id) on delete restrict,
  event_type text not null check (char_length(btrim(event_type)) between 1 and 100),
  summary text not null check (char_length(btrim(summary)) between 1 and 240),
  entity_type text,
  entity_id uuid,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index app_notifications_recipient_idx on public.app_notifications (recipient_user_id, read_at, created_at desc);

create table public.notification_preferences (
  user_id uuid not null references auth.users(id) on delete restrict,
  event_type text not null check (char_length(btrim(event_type)) between 1 and 100),
  in_app_enabled boolean not null default true,
  email_enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (user_id, event_type)
);

create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  project_id uuid references public.projects(id) on delete restrict,
  workspace_id uuid references public.workspaces(id) on delete restrict,
  actor_id uuid references auth.users(id) on delete set null,
  actor_display_snapshot text,
  action text not null check (char_length(btrim(action)) between 1 and 120),
  entity_type text not null check (char_length(btrim(entity_type)) between 1 and 80),
  entity_id uuid,
  request_id text,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default now(),
  check (project_id is not null or workspace_id is not null or entity_type in ('account', 'platform', 'support_case'))
);
create index audit_events_project_time_idx on public.audit_events (project_id, created_at desc) where project_id is not null;
create index audit_events_workspace_time_idx on public.audit_events (workspace_id, created_at desc) where workspace_id is not null;
create index audit_events_actor_time_idx on public.audit_events (actor_id, created_at desc);

create table public.outbox_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null check (char_length(btrim(event_type)) between 1 and 120),
  project_id uuid references public.projects(id) on delete restrict,
  recipient_user_id uuid references auth.users(id) on delete restrict,
  payload jsonb not null default '{}'::jsonb check (jsonb_typeof(payload) = 'object'),
  status text not null default 'pending' check (status in ('pending', 'processing', 'delivered', 'retry', 'dead_letter')),
  attempts integer not null default 0 check (attempts >= 0),
  available_at timestamptz not null default now(),
  lease_until timestamptz,
  lease_owner text,
  last_error_code text,
  created_at timestamptz not null default now(),
  delivered_at timestamptz
);
create index outbox_claim_idx on public.outbox_events (status, available_at, created_at) where status in ('pending', 'retry');

create table private.idempotency_records (
  actor_id uuid not null references auth.users(id) on delete restrict,
  operation_id uuid not null,
  operation_name text not null,
  project_id uuid references public.projects(id) on delete restrict,
  request_hash bytea not null check (octet_length(request_hash) = 32),
  response jsonb,
  created_at timestamptz not null default now(),
  primary key (actor_id, operation_id)
);
create index idempotency_records_project_idx on private.idempotency_records (project_id, created_at desc) where project_id is not null;

create table private.policy_gate_events (
  id uuid primary key default gen_random_uuid(),
  gate_key text not null references private.policy_gates(gate_key) on delete restrict,
  previous_status text not null,
  new_status text not null,
  policy_version text,
  evidence_reference text,
  approved_by uuid references auth.users(id) on delete set null,
  changed_at timestamptz not null default now()
);

comment on table public.audit_events is 'Append-only business and security audit trail; data retention remains subject to approved policy.';
comment on table public.outbox_events is 'Transactional outbox for retry-safe notifications, exports, and document scanning jobs.';
comment on table public.transfer_approvals is 'Approval is bound to a governance version; applying a transfer remains behind a release gate.';
comment on table public.export_jobs is 'Export requests are rejected while the product/data-rights policy gate is closed.';
