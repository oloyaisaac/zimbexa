-- Construction reporting, materials, inventory, finance, labor, and document metadata.

create table public.daily_reports (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  author_id uuid references auth.users(id) on delete set null,
  report_date date not null,
  status text not null default 'draft' check (status in ('draft', 'submitted', 'accepted', 'changes_requested')),
  revision integer not null default 1 check (revision > 0),
  work_done text not null default '' check (char_length(work_done) <= 10000),
  labor_summary jsonb not null default '[]'::jsonb check (jsonb_typeof(labor_summary) = 'array'),
  blockers jsonb not null default '[]'::jsonb check (jsonb_typeof(blockers) = 'array'),
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index daily_reports_project_date_idx on public.daily_reports (project_id, report_date desc, created_at desc);
create index daily_reports_project_status_idx on public.daily_reports (project_id, status, created_at desc);

create table public.report_revisions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  report_id uuid not null references public.daily_reports(id) on delete restrict,
  revision integer not null check (revision > 0),
  snapshot jsonb not null check (jsonb_typeof(snapshot) = 'object'),
  edited_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (report_id, revision)
);
create index report_revisions_project_idx on public.report_revisions (project_id, report_id, revision desc);

create table public.report_reviews (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  report_id uuid not null references public.daily_reports(id) on delete restrict,
  revision integer not null check (revision > 0),
  reviewer_id uuid references auth.users(id) on delete set null,
  decision text not null check (decision in ('accepted', 'changes_requested')),
  comment text check (comment is null or char_length(comment) <= 2000),
  created_at timestamptz not null default now(),
  unique (report_id, revision)
);

create table public.milestones (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  name text not null check (char_length(btrim(name)) between 1 and 160),
  description text check (description is null or char_length(description) <= 4000),
  target_start_date date,
  target_end_date date,
  weight numeric(8, 4) check (weight is null or weight >= 0),
  completion_fraction numeric(6, 5) not null default 0 check (completion_fraction between 0 and 1),
  status text not null default 'not_started' check (status in ('not_started', 'in_progress', 'blocked', 'done')),
  revision integer not null default 1 check (revision > 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (target_end_date is null or target_start_date is null or target_end_date >= target_start_date),
  check (status <> 'done' or completion_fraction = 1)
);
create index milestones_project_status_idx on public.milestones (project_id, status, target_end_date);

create table public.milestone_history (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  milestone_id uuid not null references public.milestones(id) on delete restrict,
  revision integer not null check (revision > 0),
  snapshot jsonb not null check (jsonb_typeof(snapshot) = 'object'),
  changed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (milestone_id, revision)
);

create table public.materials (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  name text not null check (char_length(btrim(name)) between 1 and 160),
  specification text not null default '' check (char_length(specification) <= 500),
  base_unit text not null check (base_unit in ('BAG_50KG', 'KG', 'TONNE', 'PIECE', 'M', 'M2', 'M3', 'LITRE', 'BUNDLE', 'DAY', 'OTHER')),
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (project_id, name, specification, base_unit)
);
create index materials_project_idx on public.materials (project_id, active, name);

create table public.stock_locations (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  name text not null check (char_length(btrim(name)) between 1 and 120),
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (project_id, name)
);

create table public.stock_balances (
  project_id uuid not null references public.projects(id) on delete restrict,
  location_id uuid not null references public.stock_locations(id) on delete restrict,
  material_id uuid not null references public.materials(id) on delete restrict,
  available_quantity numeric(18, 3) not null default 0 check (available_quantity >= 0),
  revision bigint not null default 0 check (revision >= 0),
  updated_at timestamptz not null default now(),
  primary key (project_id, location_id, material_id)
);

create table public.material_requests (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  purpose text not null check (char_length(btrim(purpose)) between 1 and 1000),
  required_date date,
  status text not null default 'draft' check (status in (
    'draft', 'submitted', 'approved', 'rejected', 'changes_requested',
    'ordered_external', 'part_received', 'fulfilled', 'closed'
  )),
  revision integer not null default 1 check (revision > 0),
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index material_requests_project_status_idx on public.material_requests (project_id, status, created_at desc);

create table public.material_request_lines (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  request_id uuid not null references public.material_requests(id) on delete restrict,
  material_id uuid not null references public.materials(id) on delete restrict,
  quantity_requested numeric(18, 3) not null check (quantity_requested > 0),
  unit text not null check (unit in ('BAG_50KG', 'KG', 'TONNE', 'PIECE', 'M', 'M2', 'M3', 'LITRE', 'BUNDLE', 'DAY', 'OTHER')),
  received_quantity numeric(18, 3) not null default 0 check (received_quantity >= 0),
  estimated_unit_cost_ugx bigint check (estimated_unit_cost_ugx is null or estimated_unit_cost_ugx >= 0),
  created_at timestamptz not null default now(),
  check (received_quantity <= quantity_requested)
);
create index material_request_lines_request_idx on public.material_request_lines (request_id, material_id);

create table public.material_request_revisions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  request_id uuid not null references public.material_requests(id) on delete restrict,
  revision integer not null check (revision > 0),
  snapshot jsonb not null check (jsonb_typeof(snapshot) = 'object'),
  changed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (request_id, revision)
);

create table public.material_request_reviews (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  request_id uuid not null references public.material_requests(id) on delete restrict,
  revision integer not null check (revision > 0),
  reviewer_id uuid references auth.users(id) on delete set null,
  decision text not null check (decision in ('approved', 'rejected', 'changes_requested')),
  comment text check (comment is null or char_length(comment) <= 2000),
  created_at timestamptz not null default now(),
  unique (request_id, revision)
);

create table public.stock_counts (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  location_id uuid not null references public.stock_locations(id) on delete restrict,
  material_id uuid not null references public.materials(id) on delete restrict,
  ledger_quantity numeric(18, 3) not null check (ledger_quantity >= 0),
  ledger_revision bigint not null check (ledger_revision >= 0),
  counted_quantity numeric(18, 3) not null check (counted_quantity >= 0),
  variance numeric(18, 3) generated always as (counted_quantity - ledger_quantity) stored,
  reason text not null check (char_length(btrim(reason)) between 3 and 1000),
  status text not null default 'pending_review' check (status in ('pending_review', 'approved', 'rejected')),
  counted_by uuid references auth.users(id) on delete set null,
  reviewed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index stock_counts_project_status_idx on public.stock_counts (project_id, status, created_at desc);

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  location_id uuid not null references public.stock_locations(id) on delete restrict,
  material_id uuid not null references public.materials(id) on delete restrict,
  movement_type text not null check (movement_type in ('receipt', 'issue', 'adjustment', 'reversal')),
  quantity_delta numeric(18, 3) not null check (quantity_delta <> 0),
  request_line_id uuid references public.material_request_lines(id) on delete restrict,
  stock_count_id uuid references public.stock_counts(id) on delete restrict,
  reason text,
  operation_id uuid not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (project_id, operation_id),
  check ((movement_type = 'receipt' and quantity_delta > 0) or movement_type <> 'receipt'),
  check ((movement_type = 'issue' and quantity_delta < 0) or movement_type <> 'issue'),
  check ((movement_type in ('adjustment', 'reversal') and reason is not null and char_length(btrim(reason)) >= 3) or movement_type in ('receipt', 'issue'))
);
create index stock_movements_project_material_idx on public.stock_movements (project_id, material_id, created_at desc);
create index stock_movements_request_line_idx on public.stock_movements (request_line_id) where request_line_id is not null;

create table public.budget_versions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  version integer not null check (version > 0),
  status text not null default 'draft' check (status in ('draft', 'submitted', 'approved', 'rejected', 'superseded')),
  reason text not null check (char_length(btrim(reason)) between 3 and 1000),
  created_by uuid references auth.users(id) on delete set null,
  submitted_at timestamptz,
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  unique (project_id, version)
);
create index budget_versions_project_idx on public.budget_versions (project_id, version desc);

create table public.budget_lines (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  budget_version_id uuid not null references public.budget_versions(id) on delete restrict,
  category text not null check (char_length(btrim(category)) between 1 and 80),
  description text not null check (char_length(btrim(description)) between 1 and 300),
  amount_ugx bigint not null check (amount_ugx >= 0),
  created_at timestamptz not null default now()
);
create index budget_lines_version_idx on public.budget_lines (budget_version_id);

create table public.budget_reviews (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  budget_version_id uuid not null references public.budget_versions(id) on delete restrict,
  reviewer_id uuid references auth.users(id) on delete set null,
  decision text not null check (decision in ('approved', 'rejected')),
  comment text check (comment is null or char_length(comment) <= 2000),
  created_at timestamptz not null default now()
);

create table public.cost_records (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  cost_date date not null,
  category text not null check (category in ('materials', 'labor', 'transport', 'equipment', 'utilities', 'professional', 'other')),
  description text not null check (char_length(btrim(description)) between 1 and 1000),
  counterparty_snapshot text check (counterparty_snapshot is null or char_length(counterparty_snapshot) <= 200),
  amount_ugx bigint not null check (amount_ugx > 0),
  currency text not null default 'UGX' check (currency = 'UGX'),
  status text not null default 'draft' check (status in ('draft', 'submitted', 'approved', 'rejected', 'correction_pending')),
  revision integer not null default 1 check (revision > 0),
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index cost_records_project_status_date_idx on public.cost_records (project_id, status, cost_date desc);

create table public.cost_revisions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  cost_record_id uuid not null references public.cost_records(id) on delete restrict,
  revision integer not null check (revision > 0),
  snapshot jsonb not null check (jsonb_typeof(snapshot) = 'object'),
  changed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (cost_record_id, revision)
);

create table public.cost_reviews (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  cost_record_id uuid not null references public.cost_records(id) on delete restrict,
  revision integer not null check (revision > 0),
  reviewer_id uuid references auth.users(id) on delete set null,
  decision text not null check (decision in ('approved', 'rejected')),
  comment text check (comment is null or char_length(comment) <= 2000),
  created_at timestamptz not null default now(),
  unique (cost_record_id, revision)
);

create table public.cost_adjustments (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  cost_record_id uuid not null references public.cost_records(id) on delete restrict,
  delta_ugx bigint not null check (delta_ugx <> 0),
  reason text not null check (char_length(btrim(reason)) between 3 and 1000),
  created_by uuid not null references auth.users(id) on delete restrict,
  status text not null default 'submitted' check (status in ('submitted', 'approved', 'rejected')),
  reviewed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index cost_adjustments_cost_idx on public.cost_adjustments (cost_record_id, created_at);

create table public.cash_advances (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  custodian_user_id uuid not null references auth.users(id) on delete restrict,
  amount_ugx bigint not null check (amount_ugx > 0),
  purpose text not null check (char_length(btrim(purpose)) between 3 and 500),
  status text not null default 'requested' check (status in ('requested', 'issued', 'reconciled', 'cancelled')),
  requested_by uuid not null references auth.users(id) on delete restrict,
  approved_by uuid references auth.users(id) on delete set null,
  requested_at timestamptz not null default now(),
  issued_at timestamptz,
  check ((status = 'issued' and issued_at is not null and approved_by is not null) or status <> 'issued')
);
create index cash_advances_project_status_idx on public.cash_advances (project_id, status, requested_at desc);

create table public.advance_allocations (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  advance_id uuid not null references public.cash_advances(id) on delete restrict,
  cost_record_id uuid not null references public.cost_records(id) on delete restrict,
  amount_ugx bigint not null check (amount_ugx > 0),
  allocated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.cash_returns (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  advance_id uuid not null references public.cash_advances(id) on delete restrict,
  amount_ugx bigint not null check (amount_ugx > 0),
  received_by uuid references auth.users(id) on delete set null,
  recorded_by uuid references auth.users(id) on delete set null,
  reason text,
  created_at timestamptz not null default now()
);

create table public.reported_payments (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  cost_record_id uuid references public.cost_records(id) on delete restrict,
  amount_ugx bigint not null check (amount_ugx > 0),
  payment_date date not null,
  method text not null check (method in ('cash', 'bank_transfer', 'mobile_money', 'cheque', 'other')),
  external_reference text check (external_reference is null or char_length(external_reference) <= 200),
  verification_status text not null default 'user_reported' check (verification_status in ('user_reported', 'independently_reconciled')),
  evidence_document_id uuid,
  reported_by uuid references auth.users(id) on delete set null,
  reconciled_by uuid references auth.users(id) on delete set null,
  reconciled_at timestamptz,
  created_at timestamptz not null default now(),
  check ((verification_status = 'user_reported' and reconciled_at is null) or (verification_status = 'independently_reconciled' and reconciled_at is not null))
);
create index reported_payments_project_idx on public.reported_payments (project_id, payment_date desc);

create table public.workers (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 120),
  trade text check (trade is null or char_length(trade) <= 100),
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index workers_project_idx on public.workers (project_id, active, display_name);

create table public.labor_entries (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  worker_id uuid not null references public.workers(id) on delete restrict,
  work_date date not null,
  work_type text not null check (char_length(btrim(work_type)) between 1 and 120),
  quantity numeric(10, 3) not null check (quantity > 0),
  unit text not null check (unit in ('day', 'hour', 'piece')),
  note text check (note is null or char_length(note) <= 1000),
  status text not null default 'submitted' check (status in ('submitted', 'accepted', 'changes_requested')),
  revision integer not null default 1 check (revision > 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (project_id, worker_id, work_date, work_type, created_by)
);
create index labor_entries_project_date_idx on public.labor_entries (project_id, work_date desc);

create table public.labor_entry_revisions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  labor_entry_id uuid not null references public.labor_entries(id) on delete restrict,
  revision integer not null check (revision > 0),
  snapshot jsonb not null check (jsonb_typeof(snapshot) = 'object'),
  authored_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (labor_entry_id, revision)
);
create index labor_entry_revisions_project_idx on public.labor_entry_revisions (project_id, labor_entry_id, revision);

create table public.labor_entry_reviews (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  labor_entry_id uuid not null references public.labor_entries(id) on delete restrict,
  revision integer not null check (revision > 0),
  reviewer_id uuid references auth.users(id) on delete set null,
  decision text not null check (decision in ('accepted', 'changes_requested')),
  comment text check (comment is null or char_length(comment) <= 1000),
  created_at timestamptz not null default now()
);

create table public.labor_cost_links (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  labor_entry_id uuid not null references public.labor_entries(id) on delete restrict,
  cost_record_id uuid not null references public.cost_records(id) on delete restrict,
  amount_ugx bigint not null check (amount_ugx > 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (labor_entry_id)
);

create table public.documents (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  uploaded_by uuid not null references auth.users(id) on delete restrict,
  record_type text,
  record_id uuid,
  purpose text not null check (char_length(btrim(purpose)) between 1 and 300),
  original_filename text not null check (char_length(original_filename) between 1 and 255),
  object_key text not null unique,
  mime_type text not null check (mime_type in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf')),
  size_bytes bigint not null check (size_bytes between 1 and 20971520),
  sha256 bytea check (sha256 is null or octet_length(sha256) = 32),
  retention_class text not null default 'pending_policy' check (retention_class in ('pending_policy', 'operational', 'financial_evidence', 'support_evidence')),
  status text not null default 'upload_pending' check (status in ('upload_pending', 'scanning', 'available', 'rejected', 'retained', 'deleted')),
  created_at timestamptz not null default now(),
  uploaded_at timestamptz,
  scanned_at timestamptz,
  scan_result text check (scan_result is null or scan_result in ('clean', 'rejected'))
);
create index documents_project_status_idx on public.documents (project_id, status, created_at desc);
create index documents_record_idx on public.documents (project_id, record_type, record_id) where record_id is not null;

create table public.document_versions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  document_id uuid not null references public.documents(id) on delete restrict,
  version integer not null check (version > 0),
  object_key text not null unique,
  sha256 bytea check (sha256 is null or octet_length(sha256) = 32),
  size_bytes bigint not null check (size_bytes between 1 and 20971520),
  mime_type text not null check (mime_type in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (document_id, version)
);

create table public.evidence_links (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  document_id uuid not null references public.documents(id) on delete restrict,
  record_type text not null check (char_length(btrim(record_type)) between 1 and 80),
  record_id uuid not null,
  linked_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (document_id, record_type, record_id)
);
create index evidence_links_record_idx on public.evidence_links (project_id, record_type, record_id);

comment on table public.stock_movements is 'Immutable inventory ledger; authoritative balances are updated transactionally by RPC.';
comment on table public.reported_payments is 'Manual records remain USER_REPORTED unless a separate authorized reconciliation process proves otherwise.';
comment on table public.cash_advances is 'An advance is a transfer of cash to a custodian, never a project cost by itself.';
comment on table public.documents is 'Metadata only; file bytes live in a private Supabase Storage bucket and stay unavailable until scanning succeeds.';
