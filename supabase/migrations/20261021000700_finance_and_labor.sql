-- Budget, cost, cash accountability, payment reporting, and labor RPCs.

create or replace function public.create_budget_version(
  p_project_id uuid,
  p_reason text,
  p_lines jsonb,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_version integer;
  v_budget_id uuid;
  v_item jsonb;
  v_category text;
  v_description text;
  v_amount bigint;
  v_count integer := 0;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.submit') then raise exception using errcode = '42501', message = 'budget_write_denied'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 3 and 1000 then raise exception using errcode = '22023', message = 'budget_revision_reason_required'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception using errcode = '22023', message = 'budget_lines_invalid';
  end if;
  if jsonb_array_length(p_lines) < 1 or jsonb_array_length(p_lines) > 200 then
    raise exception using errcode = '22023', message = 'budget_lines_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'create_budget_version', p_project_id,
    jsonb_build_object('reason', btrim(p_reason), 'lines', p_lines));
  if v_replay is not null then return v_replay; end if;
  perform 1 from public.projects p where p.id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'project_not_found'; end if;
  select coalesce(max(bv.version), 0) + 1 into v_version from public.budget_versions bv where bv.project_id = p_project_id;
  insert into public.budget_versions (project_id, version, reason, created_by)
  values (p_project_id, v_version, btrim(p_reason), auth.uid()) returning id into v_budget_id;
  for v_item in select value from jsonb_array_elements(p_lines) loop
    v_category := btrim(coalesce(v_item ->> 'category', ''));
    v_description := btrim(coalesce(v_item ->> 'description', ''));
    v_amount := (v_item ->> 'amount_ugx')::bigint;
    if length(v_category) not between 1 and 80 or length(v_description) not between 1 and 300 or v_amount is null or v_amount < 0 then
      raise exception using errcode = '22023', message = 'budget_line_invalid';
    end if;
    insert into public.budget_lines (project_id, budget_version_id, category, description, amount_ugx)
    values (p_project_id, v_budget_id, v_category, v_description, v_amount);
    v_count := v_count + 1;
  end loop;
  perform private.write_audit_event(p_project_id, null, 'finance.budget_version_created', 'budget_version', v_budget_id,
    jsonb_build_object('version', v_version, 'line_count', v_count));
  v_result := jsonb_build_object('budget_version_id', v_budget_id, 'version', v_version, 'status', 'draft', 'line_count', v_count, 'currency', 'UGX');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.submit_budget_version(p_project_id uuid, p_budget_version_id uuid, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_budget public.budget_versions%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.submit') then raise exception using errcode = '42501', message = 'budget_submit_denied'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'submit_budget_version', p_project_id,
    jsonb_build_object('budget_version_id', p_budget_version_id));
  if v_replay is not null then return v_replay; end if;
  select * into v_budget from public.budget_versions bv where bv.id = p_budget_version_id and bv.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'budget_version_not_found'; end if;
  if v_budget.created_by <> auth.uid() then raise exception using errcode = '42501', message = 'budget_author_only'; end if;
  if v_budget.status <> 'draft' then raise exception using errcode = '55000', message = 'budget_not_draft'; end if;
  update public.budget_versions set status = 'submitted', submitted_at = now() where id = p_budget_version_id;
  perform private.write_audit_event(p_project_id, null, 'finance.budget_submitted', 'budget_version', p_budget_version_id, jsonb_build_object('version', v_budget.version));
  v_result := jsonb_build_object('budget_version_id', p_budget_version_id, 'status', 'submitted', 'version', v_budget.version);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.review_budget_version(
  p_project_id uuid,
  p_budget_version_id uuid,
  p_decision text,
  p_comment text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_budget public.budget_versions%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.approve') then raise exception using errcode = '42501', message = 'budget_approval_denied'; end if;
  if p_decision not in ('approved', 'rejected') then raise exception using errcode = '22023', message = 'budget_decision_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'review_budget_version', p_project_id,
    jsonb_build_object('budget_version_id', p_budget_version_id, 'decision', p_decision, 'comment', p_comment));
  if v_replay is not null then return v_replay; end if;
  select * into v_budget from public.budget_versions bv where bv.id = p_budget_version_id and bv.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'budget_version_not_found'; end if;
  if v_budget.created_by = auth.uid() then raise exception using errcode = '42501', message = 'self_approval_not_allowed'; end if;
  if v_budget.status <> 'submitted' then raise exception using errcode = '55000', message = 'budget_not_pending_review'; end if;
  insert into public.budget_reviews (project_id, budget_version_id, reviewer_id, decision, comment)
  values (p_project_id, p_budget_version_id, auth.uid(), p_decision, nullif(btrim(p_comment), ''));
  update public.budget_versions set status = p_decision, approved_by = case when p_decision = 'approved' then auth.uid() else null end,
    approved_at = case when p_decision = 'approved' then now() else null end where id = p_budget_version_id;
  perform private.write_audit_event(p_project_id, null, 'finance.budget_reviewed', 'budget_version', p_budget_version_id,
    jsonb_build_object('version', v_budget.version, 'decision', p_decision));
  v_result := jsonb_build_object('budget_version_id', p_budget_version_id, 'status', p_decision, 'version', v_budget.version);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.create_cost_record(
  p_project_id uuid,
  p_cost_date date,
  p_category text,
  p_description text,
  p_counterparty text,
  p_amount_ugx bigint,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_cost_id uuid;
  v_result jsonb;
  v_snapshot jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.submit') then raise exception using errcode = '42501', message = 'cost_submit_denied'; end if;
  if p_category not in ('materials', 'labor', 'transport', 'equipment', 'utilities', 'professional', 'other')
     or p_amount_ugx is null or p_amount_ugx <= 0 or char_length(btrim(coalesce(p_description, ''))) not between 1 and 1000 then
    raise exception using errcode = '22023', message = 'cost_payload_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'create_cost_record', p_project_id,
    jsonb_build_object('cost_date', p_cost_date, 'category', p_category, 'description', btrim(p_description),
      'counterparty', nullif(btrim(p_counterparty), ''), 'amount_ugx', p_amount_ugx));
  if v_replay is not null then return v_replay; end if;
  insert into public.cost_records (project_id, created_by, cost_date, category, description, counterparty_snapshot, amount_ugx)
  values (p_project_id, auth.uid(), p_cost_date, p_category, btrim(p_description), nullif(btrim(p_counterparty), ''), p_amount_ugx)
  returning id into v_cost_id;
  select jsonb_build_object('cost_date', c.cost_date, 'category', c.category, 'description', c.description,
    'counterparty_snapshot', c.counterparty_snapshot, 'amount_ugx', c.amount_ugx, 'currency', c.currency)
  into v_snapshot from public.cost_records c where c.id = v_cost_id;
  insert into public.cost_revisions (project_id, cost_record_id, revision, snapshot, changed_by)
  values (p_project_id, v_cost_id, 1, v_snapshot, auth.uid());
  perform private.write_audit_event(p_project_id, null, 'finance.cost_draft_created', 'cost_record', v_cost_id, jsonb_build_object('amount_ugx', p_amount_ugx));
  v_result := jsonb_build_object('cost_record_id', v_cost_id, 'status', 'draft', 'revision', 1, 'currency', 'UGX');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.update_cost_draft(
  p_project_id uuid,
  p_cost_record_id uuid,
  p_expected_revision integer,
  p_cost_date date,
  p_category text,
  p_description text,
  p_counterparty text,
  p_amount_ugx bigint,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_cost public.cost_records%rowtype;
  v_revision integer;
  v_snapshot jsonb;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.submit') then raise exception using errcode = '42501', message = 'cost_edit_denied'; end if;
  if p_amount_ugx is null or p_amount_ugx <= 0 or p_category not in ('materials', 'labor', 'transport', 'equipment', 'utilities', 'professional', 'other')
     or char_length(btrim(coalesce(p_description, ''))) not between 1 and 1000 then raise exception using errcode = '22023', message = 'cost_payload_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'update_cost_draft', p_project_id,
    jsonb_build_object('cost_record_id', p_cost_record_id, 'expected_revision', p_expected_revision, 'cost_date', p_cost_date,
      'category', p_category, 'description', btrim(p_description), 'counterparty', p_counterparty, 'amount_ugx', p_amount_ugx));
  if v_replay is not null then return v_replay; end if;
  select * into v_cost from public.cost_records c where c.id = p_cost_record_id and c.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'cost_record_not_found'; end if;
  if v_cost.created_by <> auth.uid() then raise exception using errcode = '42501', message = 'cost_author_only'; end if;
  if v_cost.status not in ('draft', 'rejected') then raise exception using errcode = '55000', message = 'submitted_or_approved_cost_is_immutable'; end if;
  if p_expected_revision is null or v_cost.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'revision_conflict'; end if;
  v_revision := v_cost.revision + 1;
  update public.cost_records set cost_date = p_cost_date, category = p_category, description = btrim(p_description),
    counterparty_snapshot = nullif(btrim(p_counterparty), ''), amount_ugx = p_amount_ugx, status = 'draft', revision = v_revision
  where id = p_cost_record_id;
  select jsonb_build_object('cost_date', c.cost_date, 'category', c.category, 'description', c.description,
    'counterparty_snapshot', c.counterparty_snapshot, 'amount_ugx', c.amount_ugx, 'currency', c.currency)
  into v_snapshot from public.cost_records c where c.id = p_cost_record_id;
  insert into public.cost_revisions (project_id, cost_record_id, revision, snapshot, changed_by)
  values (p_project_id, p_cost_record_id, v_revision, v_snapshot, auth.uid());
  perform private.write_audit_event(p_project_id, null, 'finance.cost_draft_updated', 'cost_record', p_cost_record_id, jsonb_build_object('revision', v_revision));
  v_result := jsonb_build_object('cost_record_id', p_cost_record_id, 'status', 'draft', 'revision', v_revision);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.submit_cost_record(p_project_id uuid, p_cost_record_id uuid, p_expected_revision integer, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_cost public.cost_records%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.submit') then raise exception using errcode = '42501', message = 'cost_submit_denied'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'submit_cost_record', p_project_id,
    jsonb_build_object('cost_record_id', p_cost_record_id, 'expected_revision', p_expected_revision));
  if v_replay is not null then return v_replay; end if;
  select * into v_cost from public.cost_records c where c.id = p_cost_record_id and c.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'cost_record_not_found'; end if;
  if v_cost.created_by <> auth.uid() then raise exception using errcode = '42501', message = 'cost_author_only'; end if;
  if p_expected_revision is null or v_cost.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'revision_conflict'; end if;
  if v_cost.status not in ('draft', 'rejected') then raise exception using errcode = '55000', message = 'cost_not_submittable'; end if;
  update public.cost_records set status = 'submitted', submitted_at = now() where id = p_cost_record_id;
  perform private.write_audit_event(p_project_id, null, 'finance.cost_submitted', 'cost_record', p_cost_record_id,
    jsonb_build_object('revision', v_cost.revision, 'amount_ugx', v_cost.amount_ugx));
  perform private.notify_project_members(p_project_id, 'finance.cost_submitted', 'A project cost is ready for review.', 'cost_record', p_cost_record_id, auth.uid());
  v_result := jsonb_build_object('cost_record_id', p_cost_record_id, 'status', 'submitted', 'revision', v_cost.revision);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.review_cost_record(
  p_project_id uuid,
  p_cost_record_id uuid,
  p_expected_revision integer,
  p_decision text,
  p_comment text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_cost public.cost_records%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.approve') then raise exception using errcode = '42501', message = 'cost_approval_denied'; end if;
  if p_decision not in ('approved', 'rejected') then raise exception using errcode = '22023', message = 'cost_decision_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'review_cost_record', p_project_id,
    jsonb_build_object('cost_record_id', p_cost_record_id, 'expected_revision', p_expected_revision, 'decision', p_decision, 'comment', p_comment));
  if v_replay is not null then return v_replay; end if;
  select * into v_cost from public.cost_records c where c.id = p_cost_record_id and c.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'cost_record_not_found'; end if;
  if v_cost.created_by = auth.uid() then raise exception using errcode = '42501', message = 'self_approval_not_allowed'; end if;
  if p_expected_revision is null or v_cost.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'revision_conflict'; end if;
  if v_cost.status <> 'submitted' then raise exception using errcode = '55000', message = 'cost_not_pending_review'; end if;
  insert into public.cost_reviews (project_id, cost_record_id, revision, reviewer_id, decision, comment)
  values (p_project_id, p_cost_record_id, p_expected_revision, auth.uid(), p_decision, nullif(btrim(p_comment), ''));
  update public.cost_records set status = p_decision where id = p_cost_record_id;
  perform private.write_audit_event(p_project_id, null, 'finance.cost_reviewed', 'cost_record', p_cost_record_id,
    jsonb_build_object('revision', p_expected_revision, 'decision', p_decision, 'amount_ugx', v_cost.amount_ugx));
  v_result := jsonb_build_object('cost_record_id', p_cost_record_id, 'status', p_decision, 'revision', p_expected_revision);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.request_cost_adjustment(
  p_project_id uuid,
  p_cost_record_id uuid,
  p_delta_ugx bigint,
  p_reason text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_cost public.cost_records%rowtype;
  v_adjustment_id uuid;
  v_effective bigint;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.submit') then raise exception using errcode = '42501', message = 'cost_adjustment_denied'; end if;
  if p_delta_ugx is null or p_delta_ugx = 0 or char_length(btrim(coalesce(p_reason, ''))) not between 3 and 1000 then
    raise exception using errcode = '22023', message = 'cost_adjustment_payload_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'request_cost_adjustment', p_project_id,
    jsonb_build_object('cost_record_id', p_cost_record_id, 'delta_ugx', p_delta_ugx, 'reason', btrim(p_reason)));
  if v_replay is not null then return v_replay; end if;
  select * into v_cost from public.cost_records c where c.id = p_cost_record_id and c.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'cost_record_not_found'; end if;
  if v_cost.status <> 'approved' then raise exception using errcode = '55000', message = 'approved_cost_required'; end if;
  select v_cost.amount_ugx + coalesce(sum(ca.delta_ugx) filter (where ca.status = 'approved'), 0) + p_delta_ugx
  into v_effective from public.cost_adjustments ca where ca.cost_record_id = p_cost_record_id;
  if v_effective <= 0 then raise exception using errcode = '23514', message = 'adjusted_cost_must_remain_positive'; end if;
  insert into public.cost_adjustments (project_id, cost_record_id, delta_ugx, reason, created_by)
  values (p_project_id, p_cost_record_id, p_delta_ugx, btrim(p_reason), auth.uid()) returning id into v_adjustment_id;
  perform private.write_audit_event(p_project_id, null, 'finance.cost_adjustment_submitted', 'cost_adjustment', v_adjustment_id,
    jsonb_build_object('delta_ugx', p_delta_ugx));
  v_result := jsonb_build_object('cost_adjustment_id', v_adjustment_id, 'status', 'submitted');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.review_cost_adjustment(
  p_project_id uuid,
  p_cost_adjustment_id uuid,
  p_decision text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_adjustment public.cost_adjustments%rowtype;
  v_cost public.cost_records%rowtype;
  v_effective bigint;
  v_reported bigint;
  v_allocated bigint;
  v_labor_linked bigint;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.approve') then raise exception using errcode = '42501', message = 'cost_adjustment_review_denied'; end if;
  if p_decision not in ('approved', 'rejected') then raise exception using errcode = '22023', message = 'adjustment_decision_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'review_cost_adjustment', p_project_id,
    jsonb_build_object('cost_adjustment_id', p_cost_adjustment_id, 'decision', p_decision));
  if v_replay is not null then return v_replay; end if;
  select * into v_adjustment from public.cost_adjustments ca where ca.id = p_cost_adjustment_id and ca.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'cost_adjustment_not_found'; end if;
  if v_adjustment.created_by = auth.uid() then raise exception using errcode = '42501', message = 'self_approval_not_allowed'; end if;
  if v_adjustment.status <> 'submitted' then raise exception using errcode = '55000', message = 'adjustment_not_pending_review'; end if;
  if p_decision = 'approved' then
    select * into v_cost from public.cost_records c
    where c.id = v_adjustment.cost_record_id and c.project_id = p_project_id for update;
    if not found or v_cost.status <> 'approved' then raise exception using errcode = '55000', message = 'approved_cost_required'; end if;
    select v_cost.amount_ugx + coalesce(sum(ca.delta_ugx) filter (where ca.status = 'approved'), 0) + v_adjustment.delta_ugx
    into v_effective from public.cost_adjustments ca where ca.cost_record_id = v_cost.id;
    if v_effective <= 0 then raise exception using errcode = '23514', message = 'adjusted_cost_must_remain_positive'; end if;
    select coalesce(sum(rp.amount_ugx), 0) into v_reported
    from public.reported_payments rp where rp.cost_record_id = v_cost.id;
    select coalesce(sum(aa.amount_ugx), 0) into v_allocated
    from public.advance_allocations aa where aa.cost_record_id = v_cost.id;
    select coalesce(sum(lcl.amount_ugx), 0) into v_labor_linked
    from public.labor_cost_links lcl where lcl.cost_record_id = v_cost.id;
    if v_reported > v_effective then raise exception using errcode = '23514', message = 'cost_adjustment_below_reported_payments'; end if;
    if v_allocated > v_effective then raise exception using errcode = '23514', message = 'cost_adjustment_below_advance_allocations'; end if;
    if v_labor_linked > v_effective then raise exception using errcode = '23514', message = 'cost_adjustment_below_labor_cost_links'; end if;
  end if;
  update public.cost_adjustments set status = p_decision, reviewed_by = auth.uid(), reviewed_at = now() where id = p_cost_adjustment_id;
  perform private.write_audit_event(p_project_id, null, 'finance.cost_adjustment_reviewed', 'cost_adjustment', p_cost_adjustment_id,
    jsonb_build_object('decision', p_decision, 'delta_ugx', v_adjustment.delta_ugx));
  v_result := jsonb_build_object('cost_adjustment_id', p_cost_adjustment_id, 'status', p_decision);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.create_cash_advance(
  p_project_id uuid,
  p_custodian_user_id uuid,
  p_amount_ugx bigint,
  p_purpose text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_advance_id uuid;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.advance') then raise exception using errcode = '42501', message = 'advance_create_denied'; end if;
  if p_amount_ugx is null or p_amount_ugx <= 0 or char_length(btrim(coalesce(p_purpose, ''))) not between 3 and 500 then
    raise exception using errcode = '22023', message = 'advance_payload_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'create_cash_advance', p_project_id,
    jsonb_build_object('custodian_user_id', p_custodian_user_id, 'amount_ugx', p_amount_ugx, 'purpose', btrim(p_purpose)));
  if v_replay is not null then return v_replay; end if;
  if not exists (select 1 from public.project_memberships pm where pm.project_id = p_project_id and pm.user_id = p_custodian_user_id and pm.status = 'active') then
    raise exception using errcode = '23514', message = 'advance_custodian_must_be_project_member';
  end if;
  insert into public.cash_advances (project_id, custodian_user_id, amount_ugx, purpose, requested_by)
  values (p_project_id, p_custodian_user_id, p_amount_ugx, btrim(p_purpose), auth.uid()) returning id into v_advance_id;
  perform private.write_audit_event(p_project_id, null, 'finance.advance_requested', 'cash_advance', v_advance_id,
    jsonb_build_object('amount_ugx', p_amount_ugx, 'custodian_user_id', p_custodian_user_id));
  v_result := jsonb_build_object('cash_advance_id', v_advance_id, 'status', 'requested', 'amount_ugx', p_amount_ugx, 'currency', 'UGX');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.issue_cash_advance(p_project_id uuid, p_advance_id uuid, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_advance public.cash_advances%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.advance') then raise exception using errcode = '42501', message = 'advance_approval_denied'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'issue_cash_advance', p_project_id, jsonb_build_object('advance_id', p_advance_id));
  if v_replay is not null then return v_replay; end if;
  select * into v_advance from public.cash_advances ca where ca.id = p_advance_id and ca.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'cash_advance_not_found'; end if;
  if v_advance.requested_by = auth.uid() then raise exception using errcode = '42501', message = 'self_approval_not_allowed'; end if;
  if v_advance.status <> 'requested' then raise exception using errcode = '55000', message = 'advance_not_pending'; end if;
  update public.cash_advances set status = 'issued', approved_by = auth.uid(), issued_at = now() where id = p_advance_id;
  perform private.write_audit_event(p_project_id, null, 'finance.advance_issued', 'cash_advance', p_advance_id,
    jsonb_build_object('amount_ugx', v_advance.amount_ugx));
  v_result := jsonb_build_object('cash_advance_id', p_advance_id, 'status', 'issued', 'amount_ugx', v_advance.amount_ugx, 'currency', 'UGX');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.allocate_advance_cost(
  p_project_id uuid,
  p_advance_id uuid,
  p_cost_record_id uuid,
  p_amount_ugx bigint,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_advance public.cash_advances%rowtype;
  v_cost public.cost_records%rowtype;
  v_advance_used bigint;
  v_cost_allocated bigint;
  v_effective_cost bigint;
  v_allocation_id uuid;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.advance') then raise exception using errcode = '42501', message = 'advance_allocation_denied'; end if;
  if p_amount_ugx is null or p_amount_ugx <= 0 then raise exception using errcode = '22023', message = 'allocation_amount_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'allocate_advance_cost', p_project_id,
    jsonb_build_object('advance_id', p_advance_id, 'cost_record_id', p_cost_record_id, 'amount_ugx', p_amount_ugx));
  if v_replay is not null then return v_replay; end if;
  select * into v_advance from public.cash_advances ca where ca.id = p_advance_id and ca.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'cash_advance_not_found'; end if;
  if v_advance.status not in ('issued', 'reconciled') then raise exception using errcode = '55000', message = 'issued_advance_required'; end if;
  select * into v_cost from public.cost_records c where c.id = p_cost_record_id and c.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'cost_record_not_found'; end if;
  if v_cost.status <> 'approved' then raise exception using errcode = '55000', message = 'approved_cost_required'; end if;
  select coalesce(sum(a.amount_ugx), 0) into v_advance_used from public.advance_allocations a where a.advance_id = p_advance_id;
  select coalesce(sum(a.amount_ugx), 0) into v_cost_allocated from public.advance_allocations a where a.cost_record_id = p_cost_record_id;
  select v_cost.amount_ugx + coalesce(sum(ca.delta_ugx) filter (where ca.status = 'approved'), 0)
  into v_effective_cost from public.cost_adjustments ca where ca.cost_record_id = p_cost_record_id;
  if v_advance_used + coalesce((select sum(cr.amount_ugx) from public.cash_returns cr where cr.advance_id = p_advance_id), 0) + p_amount_ugx > v_advance.amount_ugx then
    raise exception using errcode = '23514', message = 'advance_fully_accounted_or_overallocated';
  end if;
  if v_cost_allocated + p_amount_ugx > v_effective_cost then raise exception using errcode = '23514', message = 'allocation_exceeds_approved_cost'; end if;
  insert into public.advance_allocations (project_id, advance_id, cost_record_id, amount_ugx, allocated_by)
  values (p_project_id, p_advance_id, p_cost_record_id, p_amount_ugx, auth.uid()) returning id into v_allocation_id;
  perform private.write_audit_event(p_project_id, null, 'finance.advance_cost_allocated', 'advance_allocation', v_allocation_id,
    jsonb_build_object('amount_ugx', p_amount_ugx, 'cost_record_id', p_cost_record_id));
  v_result := jsonb_build_object('advance_allocation_id', v_allocation_id, 'amount_ugx', p_amount_ugx);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.record_cash_return(
  p_project_id uuid,
  p_advance_id uuid,
  p_amount_ugx bigint,
  p_received_by uuid,
  p_reason text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_advance public.cash_advances%rowtype;
  v_allocated bigint;
  v_returned bigint;
  v_return_id uuid;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.advance') then raise exception using errcode = '42501', message = 'cash_return_denied'; end if;
  if p_amount_ugx is null or p_amount_ugx <= 0 then raise exception using errcode = '22023', message = 'cash_return_amount_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'record_cash_return', p_project_id,
    jsonb_build_object('advance_id', p_advance_id, 'amount_ugx', p_amount_ugx, 'received_by', p_received_by, 'reason', p_reason));
  if v_replay is not null then return v_replay; end if;
  select * into v_advance from public.cash_advances ca where ca.id = p_advance_id and ca.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'cash_advance_not_found'; end if;
  if v_advance.status not in ('issued', 'reconciled') then raise exception using errcode = '55000', message = 'issued_advance_required'; end if;
  if p_received_by is not null and not exists (select 1 from public.project_memberships pm where pm.project_id = p_project_id and pm.user_id = p_received_by and pm.status = 'active') then
    raise exception using errcode = '23514', message = 'cash_receiver_must_be_project_member';
  end if;
  select coalesce(sum(a.amount_ugx), 0) into v_allocated from public.advance_allocations a where a.advance_id = p_advance_id;
  select coalesce(sum(cr.amount_ugx), 0) into v_returned from public.cash_returns cr where cr.advance_id = p_advance_id;
  if v_allocated + v_returned + p_amount_ugx > v_advance.amount_ugx then raise exception using errcode = '23514', message = 'cash_return_exceeds_unaccounted_balance'; end if;
  insert into public.cash_returns (project_id, advance_id, amount_ugx, received_by, recorded_by, reason)
  values (p_project_id, p_advance_id, p_amount_ugx, p_received_by, auth.uid(), nullif(btrim(p_reason), '')) returning id into v_return_id;
  perform private.write_audit_event(p_project_id, null, 'finance.cash_return_recorded', 'cash_return', v_return_id,
    jsonb_build_object('amount_ugx', p_amount_ugx, 'advance_id', p_advance_id));
  v_result := jsonb_build_object('cash_return_id', v_return_id, 'amount_ugx', p_amount_ugx);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.report_payment(
  p_project_id uuid,
  p_cost_record_id uuid,
  p_amount_ugx bigint,
  p_payment_date date,
  p_method text,
  p_external_reference text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_payment_id uuid;
  v_cost public.cost_records%rowtype;
  v_total_paid bigint;
  v_effective_cost bigint;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.submit') then raise exception using errcode = '42501', message = 'payment_report_denied'; end if;
  if p_amount_ugx is null or p_amount_ugx <= 0 or p_method not in ('cash', 'bank_transfer', 'mobile_money', 'cheque', 'other') then
    raise exception using errcode = '22023', message = 'payment_payload_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'report_payment', p_project_id,
    jsonb_build_object('cost_record_id', p_cost_record_id, 'amount_ugx', p_amount_ugx, 'payment_date', p_payment_date,
      'method', p_method, 'external_reference', p_external_reference));
  if v_replay is not null then return v_replay; end if;
  if p_cost_record_id is not null then
    select * into v_cost from public.cost_records c where c.id = p_cost_record_id and c.project_id = p_project_id for update;
    if not found or v_cost.status <> 'approved' then raise exception using errcode = '23514', message = 'approved_project_cost_required'; end if;
    select v_cost.amount_ugx + coalesce(sum(ca.delta_ugx) filter (where ca.status = 'approved'), 0)
    into v_effective_cost from public.cost_adjustments ca where ca.cost_record_id = p_cost_record_id;
    select coalesce(sum(rp.amount_ugx), 0) into v_total_paid from public.reported_payments rp
    where rp.cost_record_id = p_cost_record_id;
    if v_total_paid + p_amount_ugx > v_effective_cost then raise exception using errcode = '23514', message = 'reported_payment_exceeds_approved_cost'; end if;
  end if;
  insert into public.reported_payments (project_id, cost_record_id, amount_ugx, payment_date, method, external_reference, reported_by)
  values (p_project_id, p_cost_record_id, p_amount_ugx, p_payment_date, p_method, nullif(btrim(p_external_reference), ''), auth.uid())
  returning id into v_payment_id;
  perform private.write_audit_event(p_project_id, null, 'finance.payment_user_reported', 'reported_payment', v_payment_id,
    jsonb_build_object('amount_ugx', p_amount_ugx, 'verification_status', 'user_reported', 'method', p_method));
  v_result := jsonb_build_object('reported_payment_id', v_payment_id, 'amount_ugx', p_amount_ugx, 'verification_status', 'user_reported', 'currency', 'UGX');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.create_worker(p_project_id uuid, p_display_name text, p_trade text, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_worker_id uuid;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'labor.manage') then raise exception using errcode = '42501', message = 'worker_manage_denied'; end if;
  if char_length(btrim(coalesce(p_display_name, ''))) not between 1 and 120 then raise exception using errcode = '22023', message = 'worker_name_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'create_worker', p_project_id,
    jsonb_build_object('display_name', btrim(p_display_name), 'trade', p_trade));
  if v_replay is not null then return v_replay; end if;
  insert into public.workers (project_id, display_name, trade, created_by)
  values (p_project_id, btrim(p_display_name), nullif(btrim(p_trade), ''), auth.uid()) returning id into v_worker_id;
  perform private.write_audit_event(p_project_id, null, 'labor.worker_created', 'worker', v_worker_id, '{}'::jsonb);
  v_result := jsonb_build_object('worker_id', v_worker_id, 'active', true);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.record_labor_entry(
  p_project_id uuid,
  p_worker_id uuid,
  p_work_date date,
  p_work_type text,
  p_quantity numeric,
  p_unit text,
  p_note text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_entry_id uuid;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'labor.manage') then raise exception using errcode = '42501', message = 'labor_record_denied'; end if;
  if not exists (select 1 from public.workers w where w.id = p_worker_id and w.project_id = p_project_id and w.active) then
    raise exception using errcode = '23514', message = 'worker_project_mismatch';
  end if;
  if p_quantity is null or p_quantity <= 0 or p_unit not in ('day', 'hour', 'piece')
     or char_length(btrim(coalesce(p_work_type, ''))) not between 1 and 120 then raise exception using errcode = '22023', message = 'labor_entry_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'record_labor_entry', p_project_id,
    jsonb_build_object('worker_id', p_worker_id, 'work_date', p_work_date, 'work_type', btrim(p_work_type), 'quantity', p_quantity, 'unit', p_unit, 'note', p_note));
  if v_replay is not null then return v_replay; end if;
  insert into public.labor_entries (project_id, worker_id, work_date, work_type, quantity, unit, note, created_by)
  values (p_project_id, p_worker_id, p_work_date, btrim(p_work_type), p_quantity, p_unit, nullif(btrim(p_note), ''), auth.uid())
  returning id into v_entry_id;
  insert into public.labor_entry_revisions (project_id, labor_entry_id, revision, snapshot, authored_by)
  values (p_project_id, v_entry_id, 1, jsonb_build_object(
    'worker_id', p_worker_id, 'work_date', p_work_date, 'work_type', btrim(p_work_type),
    'quantity', p_quantity, 'unit', p_unit, 'note', nullif(btrim(p_note), ''), 'status', 'submitted'
  ), auth.uid());
  perform private.write_audit_event(p_project_id, null, 'labor.entry_recorded', 'labor_entry', v_entry_id, jsonb_build_object('work_date', p_work_date));
  v_result := jsonb_build_object('labor_entry_id', v_entry_id, 'status', 'submitted', 'quantity', p_quantity, 'unit', p_unit);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.update_labor_entry(
  p_project_id uuid,
  p_labor_entry_id uuid,
  p_expected_revision integer,
  p_work_date date,
  p_work_type text,
  p_quantity numeric,
  p_unit text,
  p_note text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_entry public.labor_entries%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'labor.manage') then
    raise exception using errcode = '42501', message = 'labor_update_denied';
  end if;
  if p_work_date is null or p_quantity is null or p_quantity <= 0 or p_unit is null or p_unit not in ('day', 'hour', 'piece')
     or char_length(btrim(coalesce(p_work_type, ''))) not between 1 and 120
     or char_length(coalesce(p_note, '')) > 1000 then
    raise exception using errcode = '22023', message = 'labor_entry_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'update_labor_entry', p_project_id,
    jsonb_build_object('labor_entry_id', p_labor_entry_id, 'expected_revision', p_expected_revision,
      'work_date', p_work_date, 'work_type', btrim(p_work_type), 'quantity', p_quantity,
      'unit', p_unit, 'note', nullif(btrim(p_note), '')));
  if v_replay is not null then return v_replay; end if;
  select * into v_entry from public.labor_entries le
  where le.id = p_labor_entry_id and le.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'labor_entry_not_found'; end if;
  if v_entry.created_by is distinct from auth.uid()
     and not private.has_project_permission(p_project_id, 'project.update') then
    raise exception using errcode = '42501', message = 'labor_entry_author_or_manager_required';
  end if;
  if p_expected_revision is null or v_entry.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'revision_conflict'; end if;
  if v_entry.status not in ('changes_requested', 'accepted') then
    raise exception using errcode = '55000', message = 'labor_entry_not_correctable';
  end if;
  if v_entry.status = 'accepted' and exists (
    select 1 from public.labor_cost_links lcl where lcl.labor_entry_id = p_labor_entry_id
  ) then
    raise exception using errcode = '55000', message = 'linked_labor_cost_requires_finance_adjustment';
  end if;
  update public.labor_entries set work_date = p_work_date, work_type = btrim(p_work_type),
    quantity = p_quantity, unit = p_unit, note = nullif(btrim(p_note), ''),
    status = 'submitted', revision = revision + 1
  where id = p_labor_entry_id;
  insert into public.labor_entry_revisions (project_id, labor_entry_id, revision, snapshot, authored_by)
  values (p_project_id, p_labor_entry_id, v_entry.revision + 1, jsonb_build_object(
    'worker_id', v_entry.worker_id, 'work_date', p_work_date, 'work_type', btrim(p_work_type),
    'quantity', p_quantity, 'unit', p_unit, 'note', nullif(btrim(p_note), ''), 'status', 'submitted'
  ), auth.uid());
  perform private.write_audit_event(p_project_id, null, 'labor.entry_revised', 'labor_entry', p_labor_entry_id,
    jsonb_build_object('from_revision', v_entry.revision, 'to_revision', v_entry.revision + 1));
  v_result := jsonb_build_object('labor_entry_id', p_labor_entry_id, 'revision', v_entry.revision + 1, 'status', 'submitted');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.review_labor_entry(
  p_project_id uuid,
  p_labor_entry_id uuid,
  p_expected_revision integer,
  p_decision text,
  p_comment text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_entry public.labor_entries%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'labor.manage') then raise exception using errcode = '42501', message = 'labor_review_denied'; end if;
  if p_decision not in ('accepted', 'changes_requested') then raise exception using errcode = '22023', message = 'labor_decision_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'review_labor_entry', p_project_id,
    jsonb_build_object('labor_entry_id', p_labor_entry_id, 'expected_revision', p_expected_revision, 'decision', p_decision, 'comment', p_comment));
  if v_replay is not null then return v_replay; end if;
  select * into v_entry from public.labor_entries le where le.id = p_labor_entry_id and le.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'labor_entry_not_found'; end if;
  if v_entry.created_by = auth.uid() then raise exception using errcode = '42501', message = 'self_review_not_allowed'; end if;
  if p_expected_revision is null or v_entry.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'revision_conflict'; end if;
  if v_entry.status <> 'submitted' then raise exception using errcode = '55000', message = 'labor_entry_not_pending_review'; end if;
  insert into public.labor_entry_reviews (project_id, labor_entry_id, revision, reviewer_id, decision, comment)
  values (p_project_id, p_labor_entry_id, p_expected_revision, auth.uid(), p_decision, nullif(btrim(p_comment), ''));
  update public.labor_entries set status = p_decision where id = p_labor_entry_id;
  perform private.write_audit_event(p_project_id, null, 'labor.entry_reviewed', 'labor_entry', p_labor_entry_id,
    jsonb_build_object('decision', p_decision, 'revision', p_expected_revision));
  v_result := jsonb_build_object('labor_entry_id', p_labor_entry_id, 'status', p_decision, 'revision', p_expected_revision);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.link_labor_cost(
  p_project_id uuid,
  p_labor_entry_id uuid,
  p_cost_record_id uuid,
  p_amount_ugx bigint,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_entry public.labor_entries%rowtype;
  v_cost public.cost_records%rowtype;
  v_link_id uuid;
  v_total bigint;
  v_effective_cost bigint;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'finance.submit') then raise exception using errcode = '42501', message = 'labor_cost_link_denied'; end if;
  if p_amount_ugx is null or p_amount_ugx <= 0 then raise exception using errcode = '22023', message = 'labor_cost_amount_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'link_labor_cost', p_project_id,
    jsonb_build_object('labor_entry_id', p_labor_entry_id, 'cost_record_id', p_cost_record_id, 'amount_ugx', p_amount_ugx));
  if v_replay is not null then return v_replay; end if;
  select * into v_entry from public.labor_entries le
  where le.id = p_labor_entry_id and le.project_id = p_project_id for update;
  if not found or v_entry.status <> 'accepted' then raise exception using errcode = '23514', message = 'accepted_labor_entry_required'; end if;
  select * into v_cost from public.cost_records c where c.id = p_cost_record_id and c.project_id = p_project_id for update;
  if not found or v_cost.category <> 'labor' then raise exception using errcode = '23514', message = 'labor_cost_record_required'; end if;
  if v_cost.status <> 'approved' then raise exception using errcode = '55000', message = 'approved_labor_cost_required'; end if;
  select v_cost.amount_ugx + coalesce(sum(ca.delta_ugx) filter (where ca.status = 'approved'), 0)
  into v_effective_cost from public.cost_adjustments ca where ca.cost_record_id = p_cost_record_id;
  select coalesce(sum(lcl.amount_ugx), 0) into v_total from public.labor_cost_links lcl where lcl.cost_record_id = p_cost_record_id;
  if v_total + p_amount_ugx > v_effective_cost then raise exception using errcode = '23514', message = 'labor_links_exceed_cost_amount'; end if;
  insert into public.labor_cost_links (project_id, labor_entry_id, cost_record_id, amount_ugx, created_by)
  values (p_project_id, p_labor_entry_id, p_cost_record_id, p_amount_ugx, auth.uid()) returning id into v_link_id;
  perform private.write_audit_event(p_project_id, null, 'labor.cost_linked', 'labor_cost_link', v_link_id,
    jsonb_build_object('amount_ugx', p_amount_ugx));
  v_result := jsonb_build_object('labor_cost_link_id', v_link_id, 'amount_ugx', p_amount_ugx);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;
