-- Zimbexa V1 backend foundation (Supabase/PostgreSQL)
-- IDs are UUIDs, all timestamps are timestamptz, and no project records cascade
-- from a user/account deletion.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated, service_role;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 100),
  preferred_locale text not null default 'en' check (preferred_locale in ('en')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 120),
  kind text not null check (kind in ('personal', 'organization')),
  status text not null default 'active' check (status in ('active', 'archived')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.workspace_memberships (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  role text not null check (role in ('admin', 'member')),
  status text not null default 'active' check (status in ('active', 'revoked')),
  joined_at timestamptz not null default now(),
  ended_at timestamptz,
  unique (workspace_id, user_id),
  check ((status = 'active' and ended_at is null) or (status = 'revoked' and ended_at is not null))
);
create index workspace_memberships_user_idx on public.workspace_memberships (user_id, status, workspace_id);

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete restrict,
  name text not null check (char_length(btrim(name)) between 1 and 160),
  project_type text not null default 'residential' check (char_length(btrim(project_type)) between 1 and 80),
  region text check (region is null or char_length(region) <= 100),
  district text check (district is null or char_length(district) <= 100),
  town text check (town is null or char_length(town) <= 100),
  precise_address text check (precise_address is null or char_length(precise_address) <= 500),
  planned_start_date date,
  currency text not null default 'UGX' check (currency = 'UGX'),
  status text not null default 'draft' check (status in (
    'draft', 'active', 'paused', 'closeout_requested', 'changes_required',
    'disputed', 'completed', 'archived', 'governance_restricted'
  )),
  revision integer not null default 1 check (revision > 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index projects_workspace_status_idx on public.projects (workspace_id, status, created_at desc);

create table public.project_memberships (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  role text not null check (role in ('custodian', 'manager', 'supervisor', 'storekeeper', 'accountant', 'engineer', 'viewer')),
  status text not null default 'active' check (status in ('active', 'revoked')),
  joined_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (project_id, user_id),
  check ((status = 'active' and revoked_at is null) or (status = 'revoked' and revoked_at is not null))
);
create unique index project_one_active_custodian_idx
  on public.project_memberships(project_id) where role = 'custodian' and status = 'active';
create index project_memberships_user_idx on public.project_memberships (user_id, status, project_id);
create index project_memberships_project_role_idx on public.project_memberships (project_id, role, status);

create table public.project_permission_grants (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  permission_key text not null check (permission_key in (
    'reports.review', 'milestones.manage', 'materials.approve', 'materials.adjust',
    'finance.read', 'finance.approve', 'finance.advance', 'labor.pay.read',
    'documents.upload', 'exports.request', 'closeout.approve', 'governance.approve'
  )),
  granted_by uuid references auth.users(id) on delete set null,
  reason text not null check (char_length(btrim(reason)) between 3 and 500),
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (project_id, user_id, permission_key)
);
create index project_permission_grants_active_idx
  on public.project_permission_grants (project_id, user_id, permission_key) where revoked_at is null;

create table public.project_membership_events (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  membership_id uuid not null references public.project_memberships(id) on delete restrict,
  actor_id uuid references auth.users(id) on delete set null,
  event_type text not null check (event_type in ('invited', 'joined', 'role_changed', 'permission_granted', 'permission_revoked', 'removed', 'left')),
  details jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),
  created_at timestamptz not null default now()
);
create index project_membership_events_project_idx on public.project_membership_events (project_id, created_at desc);

create table public.project_invitations (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  recipient_email text not null check (recipient_email = lower(btrim(recipient_email)) and char_length(recipient_email) between 3 and 320),
  role text not null check (role in ('manager', 'supervisor', 'storekeeper', 'accountant', 'engineer', 'viewer')),
  permission_keys text[] not null default '{}',
  token_hash bytea not null unique check (octet_length(token_hash) = 32),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'revoked', 'expired')),
  invited_by uuid references auth.users(id) on delete set null,
  accepted_by uuid references auth.users(id) on delete set null,
  expires_at timestamptz not null,
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  check (expires_at > created_at),
  check (permission_keys <@ array[
    'reports.review', 'milestones.manage', 'materials.approve', 'materials.adjust',
    'finance.read', 'finance.approve', 'finance.advance', 'labor.pay.read',
    'documents.upload', 'exports.request', 'closeout.approve', 'governance.approve'
  ]::text[])
);
create unique index project_one_pending_invite_per_email_idx
  on public.project_invitations (project_id, recipient_email) where status = 'pending';
create index project_invitations_project_status_idx on public.project_invitations (project_id, status, expires_at);

create table public.project_governance_versions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  version integer not null check (version > 0),
  policy_snapshot jsonb not null default '{}'::jsonb check (jsonb_typeof(policy_snapshot) = 'object'),
  policy_hash text,
  status text not null default 'draft' check (status in ('draft', 'approved', 'superseded')),
  created_by uuid references auth.users(id) on delete set null,
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  unique (project_id, version),
  check ((status = 'approved' and approved_at is not null) or status <> 'approved')
);

create table public.project_recovery_routes (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  nominee_user_id uuid not null references auth.users(id) on delete restrict,
  nominated_by uuid references auth.users(id) on delete set null,
  status text not null default 'pending' check (status in ('pending', 'verified', 'revoked', 'rejected')),
  accepted_at timestamptz,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  unique (project_id, nominee_user_id),
  check ((status = 'verified' and accepted_at is not null and verified_at is not null) or status <> 'verified')
);
create index project_recovery_routes_project_idx on public.project_recovery_routes (project_id, status);

create table public.project_status_events (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  from_status text,
  to_status text not null check (to_status in (
    'draft', 'active', 'paused', 'closeout_requested', 'changes_required',
    'disputed', 'completed', 'archived', 'governance_restricted'
  )),
  reason text,
  actor_id uuid references auth.users(id) on delete set null,
  revision integer not null check (revision > 0),
  created_at timestamptz not null default now()
);
create index project_status_events_project_idx on public.project_status_events (project_id, created_at desc);

create table public.transfer_proposals (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  transfer_type text not null check (transfer_type in ('manager_handover', 'custody_transfer')),
  from_user_id uuid not null references auth.users(id) on delete restrict,
  recipient_user_id uuid not null references auth.users(id) on delete restrict,
  governance_version integer not null check (governance_version > 0),
  scope_snapshot jsonb not null default '{}'::jsonb check (jsonb_typeof(scope_snapshot) = 'object'),
  reason text not null check (char_length(btrim(reason)) between 3 and 1000),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'approved', 'applied', 'rejected', 'expired', 'disputed')),
  proposed_at timestamptz not null default now(),
  accepted_at timestamptz,
  decided_at timestamptz,
  applied_at timestamptz,
  created_by uuid not null references auth.users(id) on delete restrict,
  check (from_user_id <> recipient_user_id)
);
create index transfer_proposals_project_status_idx on public.transfer_proposals (project_id, status, proposed_at desc);

create table public.recovery_cases (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  claimant_id uuid not null references auth.users(id) on delete restrict,
  proposed_successor_id uuid references auth.users(id) on delete restrict,
  reason text not null check (char_length(btrim(reason)) between 10 and 2000),
  contact_attempts jsonb not null default '[]'::jsonb check (jsonb_typeof(contact_attempts) = 'array'),
  evidence_document_ids uuid[] not null default '{}',
  status text not null default 'pending_review' check (status in ('pending_review', 'reviewing', 'restricted', 'approved', 'rejected', 'closed')),
  reviewer_id uuid references auth.users(id) on delete set null,
  decision text,
  decision_reason text,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index recovery_cases_project_status_idx on public.recovery_cases (project_id, status, created_at desc);

create table public.closeout_cases (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  revision integer not null default 1 check (revision > 0),
  submitted_by uuid not null references auth.users(id) on delete restrict,
  checklist jsonb not null default '{}'::jsonb check (jsonb_typeof(checklist) = 'object'),
  summary_snapshot jsonb not null default '{}'::jsonb check (jsonb_typeof(summary_snapshot) = 'object'),
  reason text,
  status text not null default 'submitted' check (status in ('submitted', 'changes_required', 'disputed', 'approved', 'completed', 'rejected')),
  reviewed_by uuid references auth.users(id) on delete set null,
  review_reason text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index closeout_cases_project_idx on public.closeout_cases (project_id, created_at desc);

create table public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  status text not null default 'requested' check (status in ('requested', 'verified', 'responsibilities_pending', 'processing', 'completed', 'rejected')),
  reason text,
  requested_at timestamptz not null default now(),
  verified_at timestamptz,
  completed_at timestamptz,
  retention_decision jsonb not null default '{}'::jsonb check (jsonb_typeof(retention_decision) = 'object')
);
create unique index account_one_open_deletion_request_idx
  on public.account_deletion_requests (user_id) where status in ('requested', 'verified', 'responsibilities_pending', 'processing');

create table public.export_jobs (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  requested_by uuid not null references auth.users(id) on delete restrict,
  export_scope text not null check (export_scope in ('summary', 'project_records', 'financial', 'documents', 'full')),
  filters jsonb not null default '{}'::jsonb check (jsonb_typeof(filters) = 'object'),
  status text not null default 'requested' check (status in ('requested', 'queued', 'processing', 'completed', 'failed', 'expired', 'rejected')),
  storage_key text,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index export_jobs_requester_idx on public.export_jobs (requested_by, created_at desc);

create table public.support_cases (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references auth.users(id) on delete restrict,
  project_id uuid references public.projects(id) on delete restrict,
  category text not null check (category in ('account', 'security', 'project_access', 'data_request', 'abuse', 'other')),
  detail text not null check (char_length(btrim(detail)) between 10 and 4000),
  status text not null default 'open' check (status in ('open', 'triaged', 'in_review', 'resolved', 'closed')),
  priority text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  disposition text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index support_cases_project_idx on public.support_cases (project_id, status, created_at desc);
create index support_cases_user_idx on public.support_cases (created_by, created_at desc);

create table private.policy_gates (
  gate_key text primary key,
  status text not null default 'pending_signoff' check (status in ('pending_signoff', 'approved', 'enabled', 'suspended')),
  policy_version text,
  evidence_reference text,
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  updated_at timestamptz not null default now(),
  check (
    (status in ('approved', 'enabled') and approved_at is not null and policy_version is not null and evidence_reference is not null and approved_by is not null)
    or status = 'pending_signoff'
    or (status = 'suspended' and approved_at is not null)
  )
);
insert into private.policy_gates (gate_key, status) values
  ('project_activation', 'pending_signoff'),
  ('custody_transfer', 'pending_signoff'),
  ('recovery_adjudication', 'pending_signoff'),
  ('account_deletion_execution', 'pending_signoff'),
  ('project_closeout_completion', 'pending_signoff'),
  ('project_data_export', 'pending_signoff'),
  ('document_retention_purge', 'pending_signoff'),
  ('sensitive_support_access', 'pending_signoff');

comment on table public.project_memberships is 'Project-scoped authority; membership removal does not delete authored records.';
comment on table public.project_invitations is 'Invitation tokens are stored only as SHA-256 hashes; raw tokens are returned once by the invitation RPC.';
comment on table public.project_recovery_routes is 'A nominee acceptance proves account control, not land title or legal authority.';
comment on table private.policy_gates is 'Security/product release gates. Default closed pending documented sign-off.';
