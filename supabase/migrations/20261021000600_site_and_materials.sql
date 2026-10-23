-- Site reporting and progress RPCs.

create or replace function public.create_daily_report(
  p_project_id uuid,
  p_report_date date,
  p_work_done text,
  p_labor_summary jsonb,
  p_blockers jsonb,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_report_id uuid;
  v_revision integer := 1;
  v_snapshot jsonb;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'reports.create') then raise exception using errcode = '42501', message = 'report_create_denied'; end if;
  if not private.project_is_operational(p_project_id) then raise exception using errcode = '55000', message = 'project_not_active'; end if;
  if char_length(coalesce(p_work_done, '')) > 10000 or jsonb_typeof(coalesce(p_labor_summary, '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_blockers, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = '22023', message = 'report_payload_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'create_daily_report', p_project_id,
    jsonb_build_object('report_date', p_report_date, 'work_done', coalesce(p_work_done, ''),
      'labor_summary', coalesce(p_labor_summary, '[]'::jsonb), 'blockers', coalesce(p_blockers, '[]'::jsonb))
  );
  if v_replay is not null then return v_replay; end if;
  insert into public.daily_reports (project_id, author_id, report_date, work_done, labor_summary, blockers)
  values (p_project_id, auth.uid(), p_report_date, coalesce(p_work_done, ''), coalesce(p_labor_summary, '[]'::jsonb), coalesce(p_blockers, '[]'::jsonb))
  returning id into v_report_id;
  v_snapshot := jsonb_build_object('report_date', p_report_date, 'work_done', coalesce(p_work_done, ''),
    'labor_summary', coalesce(p_labor_summary, '[]'::jsonb), 'blockers', coalesce(p_blockers, '[]'::jsonb), 'status', 'draft');
  insert into public.report_revisions (project_id, report_id, revision, snapshot, edited_by)
  values (p_project_id, v_report_id, v_revision, v_snapshot, auth.uid());
  perform private.write_audit_event(p_project_id, null, 'site.report_draft_created', 'daily_report', v_report_id, jsonb_build_object('revision', v_revision));
  v_result := jsonb_build_object('report_id', v_report_id, 'status', 'draft', 'revision', v_revision, 'sync_status', 'committed');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.save_daily_report_draft(
  p_project_id uuid,
  p_report_id uuid,
  p_expected_revision integer,
  p_report_date date,
  p_work_done text,
  p_labor_summary jsonb,
  p_blockers jsonb,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_report public.daily_reports%rowtype;
  v_new_revision integer;
  v_snapshot jsonb;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'reports.create') then raise exception using errcode = '42501', message = 'report_edit_denied'; end if;
  if char_length(coalesce(p_work_done, '')) > 10000 or jsonb_typeof(coalesce(p_labor_summary, '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_blockers, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = '22023', message = 'report_payload_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'save_daily_report_draft', p_project_id,
    jsonb_build_object('report_id', p_report_id, 'expected_revision', p_expected_revision, 'report_date', p_report_date,
      'work_done', coalesce(p_work_done, ''), 'labor_summary', coalesce(p_labor_summary, '[]'::jsonb), 'blockers', coalesce(p_blockers, '[]'::jsonb))
  );
  if v_replay is not null then return v_replay; end if;
  select * into v_report from public.daily_reports r where r.id = p_report_id and r.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'report_not_found'; end if;
  if v_report.author_id <> auth.uid() then raise exception using errcode = '42501', message = 'report_author_only'; end if;
  if v_report.status not in ('draft', 'changes_requested') then raise exception using errcode = '55000', message = 'submitted_report_is_immutable'; end if;
  if p_expected_revision is null or v_report.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'revision_conflict'; end if;
  v_new_revision := v_report.revision + 1;
  update public.daily_reports set report_date = p_report_date, work_done = coalesce(p_work_done, ''),
    labor_summary = coalesce(p_labor_summary, '[]'::jsonb), blockers = coalesce(p_blockers, '[]'::jsonb),
    status = 'draft', revision = v_new_revision, submitted_at = null
  where id = p_report_id;
  v_snapshot := jsonb_build_object('report_date', p_report_date, 'work_done', coalesce(p_work_done, ''),
    'labor_summary', coalesce(p_labor_summary, '[]'::jsonb), 'blockers', coalesce(p_blockers, '[]'::jsonb), 'status', 'draft');
  insert into public.report_revisions (project_id, report_id, revision, snapshot, edited_by)
  values (p_project_id, p_report_id, v_new_revision, v_snapshot, auth.uid());
  perform private.write_audit_event(p_project_id, null, 'site.report_draft_updated', 'daily_report', p_report_id, jsonb_build_object('revision', v_new_revision));
  v_result := jsonb_build_object('report_id', p_report_id, 'status', 'draft', 'revision', v_new_revision);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.submit_daily_report(p_project_id uuid, p_report_id uuid, p_expected_revision integer, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_report public.daily_reports%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'reports.create') then raise exception using errcode = '42501', message = 'report_submit_denied'; end if;
  if not private.project_is_operational(p_project_id) then raise exception using errcode = '55000', message = 'project_not_active'; end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'submit_daily_report', p_project_id, jsonb_build_object('report_id', p_report_id, 'expected_revision', p_expected_revision)
  );
  if v_replay is not null then return v_replay; end if;
  select * into v_report from public.daily_reports r where r.id = p_report_id and r.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'report_not_found'; end if;
  if v_report.author_id <> auth.uid() then raise exception using errcode = '42501', message = 'report_author_only'; end if;
  if p_expected_revision is null or v_report.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'revision_conflict'; end if;
  if v_report.status not in ('draft', 'changes_requested') then raise exception using errcode = '55000', message = 'report_not_submittable'; end if;
  update public.daily_reports set status = 'submitted', submitted_at = now() where id = p_report_id;
  perform private.write_audit_event(p_project_id, null, 'site.report_submitted', 'daily_report', p_report_id, jsonb_build_object('revision', v_report.revision));
  perform private.notify_project_members(p_project_id, 'site.report_submitted', 'A daily site report is ready for review.', 'daily_report', p_report_id, auth.uid());
  v_result := jsonb_build_object('report_id', p_report_id, 'status', 'submitted', 'revision', v_report.revision);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.review_daily_report(
  p_project_id uuid,
  p_report_id uuid,
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
  v_report public.daily_reports%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'reports.review') then raise exception using errcode = '42501', message = 'report_review_denied'; end if;
  if p_decision not in ('accepted', 'changes_requested') then raise exception using errcode = '22023', message = 'report_decision_invalid'; end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'review_daily_report', p_project_id,
    jsonb_build_object('report_id', p_report_id, 'expected_revision', p_expected_revision, 'decision', p_decision, 'comment', p_comment)
  );
  if v_replay is not null then return v_replay; end if;
  select * into v_report from public.daily_reports r where r.id = p_report_id and r.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'report_not_found'; end if;
  if v_report.author_id = auth.uid() then raise exception using errcode = '42501', message = 'self_review_not_allowed'; end if;
  if p_expected_revision is null or v_report.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'revision_conflict'; end if;
  if v_report.status <> 'submitted' then raise exception using errcode = '55000', message = 'report_not_pending_review'; end if;
  insert into public.report_reviews (project_id, report_id, revision, reviewer_id, decision, comment)
  values (p_project_id, p_report_id, p_expected_revision, auth.uid(), p_decision, nullif(btrim(p_comment), ''));
  update public.daily_reports set status = p_decision where id = p_report_id;
  perform private.write_audit_event(p_project_id, null, 'site.report_reviewed', 'daily_report', p_report_id,
    jsonb_build_object('revision', p_expected_revision, 'decision', p_decision));
  v_result := jsonb_build_object('report_id', p_report_id, 'status', p_decision, 'revision', p_expected_revision);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.create_milestone(
  p_project_id uuid,
  p_name text,
  p_description text,
  p_target_start_date date,
  p_target_end_date date,
  p_weight numeric,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_id uuid;
  v_snapshot jsonb;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'milestones.manage') then raise exception using errcode = '42501', message = 'milestone_manage_denied'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 160 then raise exception using errcode = '22023', message = 'milestone_name_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'create_milestone', p_project_id,
    jsonb_build_object('name', btrim(p_name), 'description', p_description, 'start', p_target_start_date, 'end', p_target_end_date, 'weight', p_weight));
  if v_replay is not null then return v_replay; end if;
  insert into public.milestones (project_id, name, description, target_start_date, target_end_date, weight, created_by)
  values (p_project_id, btrim(p_name), nullif(btrim(p_description), ''), p_target_start_date, p_target_end_date, p_weight, auth.uid())
  returning id into v_id;
  select jsonb_build_object('name', m.name, 'description', m.description, 'status', m.status, 'weight', m.weight,
    'completion_fraction', m.completion_fraction, 'target_start_date', m.target_start_date, 'target_end_date', m.target_end_date)
  into v_snapshot from public.milestones m where m.id = v_id;
  insert into public.milestone_history (project_id, milestone_id, revision, snapshot, changed_by)
  values (p_project_id, v_id, 1, v_snapshot, auth.uid());
  perform private.write_audit_event(p_project_id, null, 'site.milestone_created', 'milestone', v_id, '{}'::jsonb);
  v_result := jsonb_build_object('milestone_id', v_id, 'status', 'not_started', 'revision', 1, 'progress_percent', null);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.update_milestone(
  p_project_id uuid,
  p_milestone_id uuid,
  p_expected_revision integer,
  p_name text,
  p_description text,
  p_status text,
  p_completion_fraction numeric,
  p_weight numeric,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_milestone public.milestones%rowtype;
  v_revision integer;
  v_snapshot jsonb;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'milestones.manage') then raise exception using errcode = '42501', message = 'milestone_manage_denied'; end if;
  if p_status not in ('not_started', 'in_progress', 'blocked', 'done') then raise exception using errcode = '22023', message = 'milestone_status_invalid'; end if;
  if p_completion_fraction is null or p_completion_fraction not between 0 and 1 then raise exception using errcode = '22023', message = 'milestone_progress_invalid'; end if;
  if p_status = 'done' and p_completion_fraction <> 1 then raise exception using errcode = '23514', message = 'done_milestone_requires_full_completion'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'update_milestone', p_project_id,
    jsonb_build_object('milestone_id', p_milestone_id, 'expected_revision', p_expected_revision, 'name', btrim(p_name),
      'description', p_description, 'status', p_status, 'completion_fraction', p_completion_fraction, 'weight', p_weight));
  if v_replay is not null then return v_replay; end if;
  select * into v_milestone from public.milestones m where m.id = p_milestone_id and m.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'milestone_not_found'; end if;
  if p_expected_revision is null or v_milestone.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'revision_conflict'; end if;
  v_revision := v_milestone.revision + 1;
  update public.milestones set name = btrim(p_name), description = nullif(btrim(p_description), ''), status = p_status,
    completion_fraction = p_completion_fraction, weight = p_weight, revision = v_revision where id = p_milestone_id;
  select jsonb_build_object('name', m.name, 'description', m.description, 'status', m.status, 'weight', m.weight,
    'completion_fraction', m.completion_fraction, 'revision', m.revision)
  into v_snapshot from public.milestones m where m.id = p_milestone_id;
  insert into public.milestone_history (project_id, milestone_id, revision, snapshot, changed_by)
  values (p_project_id, p_milestone_id, v_revision, v_snapshot, auth.uid());
  perform private.write_audit_event(p_project_id, null, 'site.milestone_updated', 'milestone', p_milestone_id, jsonb_build_object('revision', v_revision));
  v_result := jsonb_build_object('milestone_id', p_milestone_id, 'status', p_status, 'revision', v_revision,
    'progress_percent', case when p_weight is not null then round(p_completion_fraction * 100, 2) else null end);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

-- Material requests and stock ledger RPCs.
create or replace function public.create_material(
  p_project_id uuid,
  p_name text,
  p_specification text,
  p_base_unit text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_id uuid;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'materials.request') then raise exception using errcode = '42501', message = 'material_manage_denied'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 160 then raise exception using errcode = '22023', message = 'material_name_invalid'; end if;
  if p_base_unit not in ('BAG_50KG', 'KG', 'TONNE', 'PIECE', 'M', 'M2', 'M3', 'LITRE', 'BUNDLE', 'DAY', 'OTHER') then
    raise exception using errcode = '22023', message = 'material_unit_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'create_material', p_project_id,
    jsonb_build_object('name', btrim(p_name), 'specification', coalesce(btrim(p_specification), ''), 'base_unit', p_base_unit));
  if v_replay is not null then return v_replay; end if;
  insert into public.materials (project_id, name, specification, base_unit, created_by)
  values (p_project_id, btrim(p_name), coalesce(btrim(p_specification), ''), p_base_unit, auth.uid()) returning id into v_id;
  perform private.write_audit_event(p_project_id, null, 'materials.spec_created', 'material', v_id, jsonb_build_object('base_unit', p_base_unit));
  v_result := jsonb_build_object('material_id', v_id, 'base_unit', p_base_unit, 'active', true);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.create_material_request(
  p_project_id uuid,
  p_purpose text,
  p_required_date date,
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
  v_request_id uuid;
  v_item jsonb;
  v_material_id uuid;
  v_quantity numeric(18, 3);
  v_unit text;
  v_estimate bigint;
  v_line_count integer := 0;
  v_snapshot jsonb;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'materials.request') then raise exception using errcode = '42501', message = 'material_request_denied'; end if;
  if char_length(btrim(coalesce(p_purpose, ''))) not between 1 and 1000 then raise exception using errcode = '22023', message = 'material_request_purpose_required'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception using errcode = '22023', message = 'material_request_lines_invalid';
  end if;
  if jsonb_array_length(p_lines) < 1 or jsonb_array_length(p_lines) > 100 then
    raise exception using errcode = '22023', message = 'material_request_lines_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'create_material_request', p_project_id,
    jsonb_build_object('purpose', btrim(p_purpose), 'required_date', p_required_date, 'lines', p_lines));
  if v_replay is not null then return v_replay; end if;
  insert into public.material_requests (project_id, created_by, purpose, required_date)
  values (p_project_id, auth.uid(), btrim(p_purpose), p_required_date) returning id into v_request_id;
  for v_item in select value from jsonb_array_elements(p_lines) loop
    v_material_id := (v_item ->> 'material_id')::uuid;
    v_quantity := (v_item ->> 'quantity')::numeric;
    v_unit := v_item ->> 'unit';
    v_estimate := nullif(v_item ->> 'estimated_unit_cost_ugx', '')::bigint;
    if v_quantity is null or v_quantity <= 0 then raise exception using errcode = '22023', message = 'material_quantity_must_be_positive'; end if;
    if not exists (select 1 from public.materials m where m.id = v_material_id and m.project_id = p_project_id and m.active and m.base_unit = v_unit) then
      raise exception using errcode = '23514', message = 'material_or_unit_mismatch';
    end if;
    insert into public.material_request_lines (project_id, request_id, material_id, quantity_requested, unit, estimated_unit_cost_ugx)
    values (p_project_id, v_request_id, v_material_id, v_quantity, v_unit, v_estimate);
    v_line_count := v_line_count + 1;
  end loop;
  select jsonb_build_object('purpose', mr.purpose, 'required_date', mr.required_date, 'status', mr.status,
    'lines', coalesce(jsonb_agg(jsonb_build_object('material_id', l.material_id, 'quantity', l.quantity_requested,
      'unit', l.unit, 'estimated_unit_cost_ugx', l.estimated_unit_cost_ugx) order by l.id), '[]'::jsonb))
  into v_snapshot from public.material_requests mr left join public.material_request_lines l on l.request_id = mr.id
  where mr.id = v_request_id group by mr.id;
  insert into public.material_request_revisions (project_id, request_id, revision, snapshot, changed_by)
  values (p_project_id, v_request_id, 1, v_snapshot, auth.uid());
  perform private.write_audit_event(p_project_id, null, 'materials.request_draft_created', 'material_request', v_request_id, jsonb_build_object('line_count', v_line_count));
  v_result := jsonb_build_object('request_id', v_request_id, 'status', 'draft', 'revision', 1, 'line_count', v_line_count);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.save_material_request_draft(
  p_project_id uuid,
  p_request_id uuid,
  p_expected_revision integer,
  p_purpose text,
  p_required_date date,
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
  v_request public.material_requests%rowtype;
  v_item jsonb;
  v_material_id uuid;
  v_quantity numeric(18, 3);
  v_unit text;
  v_estimate bigint;
  v_line_count integer := 0;
  v_snapshot jsonb;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'materials.request') then
    raise exception using errcode = '42501', message = 'material_request_denied';
  end if;
  if char_length(btrim(coalesce(p_purpose, ''))) not between 1 and 1000 then
    raise exception using errcode = '22023', message = 'material_request_purpose_required';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception using errcode = '22023', message = 'material_request_lines_invalid';
  end if;
  if jsonb_array_length(p_lines) < 1 or jsonb_array_length(p_lines) > 100 then
    raise exception using errcode = '22023', message = 'material_request_lines_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'save_material_request_draft', p_project_id,
    jsonb_build_object('request_id', p_request_id, 'expected_revision', p_expected_revision,
      'purpose', btrim(p_purpose), 'required_date', p_required_date, 'lines', p_lines));
  if v_replay is not null then return v_replay; end if;
  select * into v_request from public.material_requests mr
  where mr.id = p_request_id and mr.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'material_request_not_found'; end if;
  if v_request.created_by <> auth.uid() then raise exception using errcode = '42501', message = 'material_request_author_only'; end if;
  if p_expected_revision is null or v_request.revision <> p_expected_revision then
    raise exception using errcode = '40001', message = 'revision_conflict';
  end if;
  if v_request.status not in ('draft', 'changes_requested') then
    raise exception using errcode = '55000', message = 'material_request_not_editable';
  end if;
  if exists (select 1 from public.material_request_lines l where l.request_id = p_request_id and l.received_quantity > 0) then
    raise exception using errcode = '55000', message = 'received_request_lines_not_editable';
  end if;
  delete from public.material_request_lines where request_id = p_request_id;
  update public.material_requests set purpose = btrim(p_purpose), required_date = p_required_date,
    status = 'draft', revision = revision + 1, submitted_at = null
  where id = p_request_id;
  for v_item in select value from jsonb_array_elements(p_lines) loop
    v_material_id := (v_item ->> 'material_id')::uuid;
    v_quantity := (v_item ->> 'quantity')::numeric;
    v_unit := v_item ->> 'unit';
    v_estimate := nullif(v_item ->> 'estimated_unit_cost_ugx', '')::bigint;
    if v_quantity is null or v_quantity <= 0 then
      raise exception using errcode = '22023', message = 'material_quantity_must_be_positive';
    end if;
    if not exists (select 1 from public.materials m where m.id = v_material_id and m.project_id = p_project_id and m.active and m.base_unit = v_unit) then
      raise exception using errcode = '23514', message = 'material_or_unit_mismatch';
    end if;
    insert into public.material_request_lines (project_id, request_id, material_id, quantity_requested, unit, estimated_unit_cost_ugx)
    values (p_project_id, p_request_id, v_material_id, v_quantity, v_unit, v_estimate);
    v_line_count := v_line_count + 1;
  end loop;
  select jsonb_build_object('purpose', mr.purpose, 'required_date', mr.required_date, 'status', mr.status,
    'lines', coalesce(jsonb_agg(jsonb_build_object('material_id', l.material_id, 'quantity', l.quantity_requested,
      'unit', l.unit, 'estimated_unit_cost_ugx', l.estimated_unit_cost_ugx) order by l.id), '[]'::jsonb))
  into v_snapshot from public.material_requests mr left join public.material_request_lines l on l.request_id = mr.id
  where mr.id = p_request_id group by mr.id;
  insert into public.material_request_revisions (project_id, request_id, revision, snapshot, changed_by)
  values (p_project_id, p_request_id, v_request.revision + 1, v_snapshot, auth.uid());
  perform private.write_audit_event(p_project_id, null, 'materials.request_draft_saved', 'material_request', p_request_id,
    jsonb_build_object('from_revision', v_request.revision, 'to_revision', v_request.revision + 1, 'line_count', v_line_count));
  v_result := jsonb_build_object('request_id', p_request_id, 'status', 'draft', 'revision', v_request.revision + 1, 'line_count', v_line_count);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.submit_material_request(p_project_id uuid, p_request_id uuid, p_expected_revision integer, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_request public.material_requests%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'materials.request') then raise exception using errcode = '42501', message = 'material_request_denied'; end if;
  if not private.project_is_operational(p_project_id) then raise exception using errcode = '55000', message = 'project_not_active'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'submit_material_request', p_project_id,
    jsonb_build_object('request_id', p_request_id, 'expected_revision', p_expected_revision));
  if v_replay is not null then return v_replay; end if;
  select * into v_request from public.material_requests mr where mr.id = p_request_id and mr.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'material_request_not_found'; end if;
  if v_request.created_by <> auth.uid() then raise exception using errcode = '42501', message = 'material_request_author_only'; end if;
  if p_expected_revision is null or v_request.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'revision_conflict'; end if;
  if v_request.status not in ('draft', 'changes_requested') then raise exception using errcode = '55000', message = 'material_request_not_submittable'; end if;
  update public.material_requests set status = 'submitted', submitted_at = now() where id = p_request_id;
  perform private.write_audit_event(p_project_id, null, 'materials.request_submitted', 'material_request', p_request_id, jsonb_build_object('revision', v_request.revision));
  perform private.notify_project_members(p_project_id, 'materials.request_submitted', 'A material request is ready for review.', 'material_request', p_request_id, auth.uid());
  v_result := jsonb_build_object('request_id', p_request_id, 'status', 'submitted', 'revision', v_request.revision);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.review_material_request(
  p_project_id uuid,
  p_request_id uuid,
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
  v_request public.material_requests%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'materials.approve') then raise exception using errcode = '42501', message = 'material_approval_denied'; end if;
  if p_decision not in ('approved', 'rejected', 'changes_requested') then raise exception using errcode = '22023', message = 'material_decision_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'review_material_request', p_project_id,
    jsonb_build_object('request_id', p_request_id, 'expected_revision', p_expected_revision, 'decision', p_decision, 'comment', p_comment));
  if v_replay is not null then return v_replay; end if;
  select * into v_request from public.material_requests mr where mr.id = p_request_id and mr.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'material_request_not_found'; end if;
  if v_request.created_by = auth.uid() then raise exception using errcode = '42501', message = 'self_approval_not_allowed'; end if;
  if p_expected_revision is null or v_request.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'revision_conflict'; end if;
  if v_request.status <> 'submitted' then raise exception using errcode = '55000', message = 'material_request_not_pending_review'; end if;
  insert into public.material_request_reviews (project_id, request_id, revision, reviewer_id, decision, comment)
  values (p_project_id, p_request_id, p_expected_revision, auth.uid(), p_decision, nullif(btrim(p_comment), ''));
  update public.material_requests set status = p_decision where id = p_request_id;
  perform private.write_audit_event(p_project_id, null, 'materials.request_reviewed', 'material_request', p_request_id,
    jsonb_build_object('revision', p_expected_revision, 'decision', p_decision));
  v_result := jsonb_build_object('request_id', p_request_id, 'status', p_decision, 'revision', p_expected_revision);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.mark_material_ordered_external(p_project_id uuid, p_request_id uuid, p_expected_revision integer, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_request public.material_requests%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'project.update') then raise exception using errcode = '42501', message = 'material_order_update_denied'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'mark_material_ordered_external', p_project_id,
    jsonb_build_object('request_id', p_request_id, 'expected_revision', p_expected_revision));
  if v_replay is not null then return v_replay; end if;
  select * into v_request from public.material_requests mr where mr.id = p_request_id and mr.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'material_request_not_found'; end if;
  if p_expected_revision is null or v_request.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'revision_conflict'; end if;
  if v_request.status <> 'approved' then raise exception using errcode = '55000', message = 'approved_request_required'; end if;
  update public.material_requests set status = 'ordered_external', revision = revision + 1 where id = p_request_id;
  perform private.write_audit_event(p_project_id, null, 'materials.ordered_external', 'material_request', p_request_id, '{}'::jsonb);
  v_result := jsonb_build_object('request_id', p_request_id, 'status', 'ordered_external', 'revision', p_expected_revision + 1);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.record_stock_movement(
  p_project_id uuid,
  p_location_id uuid,
  p_material_id uuid,
  p_movement_type text,
  p_quantity_delta numeric,
  p_request_line_id uuid,
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
  v_balance numeric(18, 3);
  v_new_balance numeric(18, 3);
  v_movement_id uuid;
  v_line public.material_request_lines%rowtype;
  v_project_status text;
  v_result jsonb;
begin
  if p_movement_type not in ('receipt', 'issue', 'adjustment', 'reversal') then raise exception using errcode = '22023', message = 'stock_movement_type_invalid'; end if;
  if p_quantity_delta is null or p_quantity_delta = 0 then raise exception using errcode = '22023', message = 'stock_quantity_delta_must_be_nonzero'; end if;
  if (p_movement_type = 'receipt' and (p_quantity_delta <= 0 or not private.has_project_permission(p_project_id, 'materials.receive')))
     or (p_movement_type = 'issue' and (p_quantity_delta >= 0 or not private.has_project_permission(p_project_id, 'materials.issue')))
     or (p_movement_type in ('adjustment', 'reversal') and not private.has_project_permission(p_project_id, 'materials.adjust')) then
    raise exception using errcode = '42501', message = 'stock_movement_permission_or_sign_invalid';
  end if;
  if p_movement_type in ('adjustment', 'reversal') and char_length(btrim(coalesce(p_reason, ''))) < 3 then
    raise exception using errcode = '22023', message = 'stock_adjustment_reason_required';
  end if;
  if not exists (select 1 from public.projects p where p.id = p_project_id and p.status = 'active') then
    raise exception using errcode = '55000', message = 'project_not_active';
  end if;
  if not exists (select 1 from public.materials m where m.id = p_material_id and m.project_id = p_project_id and m.active)
     or not exists (select 1 from public.stock_locations sl where sl.id = p_location_id and sl.project_id = p_project_id and sl.active) then
    raise exception using errcode = '23514', message = 'stock_project_scope_mismatch';
  end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'record_stock_movement', p_project_id,
    jsonb_build_object('location_id', p_location_id, 'material_id', p_material_id, 'movement_type', p_movement_type,
      'quantity_delta', p_quantity_delta, 'request_line_id', p_request_line_id, 'reason', p_reason));
  if v_replay is not null then return v_replay; end if;

  if p_request_line_id is not null then
    if p_movement_type <> 'receipt' then raise exception using errcode = '22023', message = 'request_line_only_valid_for_receipt'; end if;
    select * into v_line from public.material_request_lines l where l.id = p_request_line_id and l.project_id = p_project_id for update;
    if not found then raise exception using errcode = 'P0002', message = 'material_request_line_not_found'; end if;
    if v_line.material_id <> p_material_id then raise exception using errcode = '23514', message = 'receipt_material_mismatch'; end if;
    if v_line.received_quantity + p_quantity_delta > v_line.quantity_requested then
      raise exception using errcode = '23514', message = 'receipt_exceeds_requested_quantity';
    end if;
    if not exists (select 1 from public.material_requests mr where mr.id = v_line.request_id and mr.status in ('approved', 'ordered_external', 'part_received')) then
      raise exception using errcode = '55000', message = 'approved_request_required_for_linked_receipt';
    end if;
  end if;

  insert into public.stock_balances (project_id, location_id, material_id, available_quantity)
  values (p_project_id, p_location_id, p_material_id, 0)
  on conflict (project_id, location_id, material_id) do nothing;
  select sb.available_quantity into v_balance from public.stock_balances sb
  where sb.project_id = p_project_id and sb.location_id = p_location_id and sb.material_id = p_material_id for update;
  v_new_balance := v_balance + p_quantity_delta;
  if v_new_balance < 0 then raise exception using errcode = '23514', message = 'insufficient_stock'; end if;

  insert into public.stock_movements (
    project_id, location_id, material_id, movement_type, quantity_delta, request_line_id, reason, operation_id, created_by
  ) values (
    p_project_id, p_location_id, p_material_id, p_movement_type, p_quantity_delta, p_request_line_id,
    nullif(btrim(p_reason), ''), p_operation_id, auth.uid()
  ) returning id into v_movement_id;
  update public.stock_balances set available_quantity = v_new_balance, revision = revision + 1, updated_at = now()
  where project_id = p_project_id and location_id = p_location_id and material_id = p_material_id;
  if p_request_line_id is not null then
    update public.material_request_lines set received_quantity = received_quantity + p_quantity_delta where id = p_request_line_id;
    update public.material_requests mr set status = case
      when not exists (select 1 from public.material_request_lines l where l.request_id = mr.id and l.received_quantity < l.quantity_requested) then 'fulfilled'
      else 'part_received' end
    where mr.id = v_line.request_id;
  end if;
  perform private.write_audit_event(p_project_id, null, 'materials.stock_movement_recorded', 'stock_movement', v_movement_id,
    jsonb_build_object('movement_type', p_movement_type, 'quantity_delta', p_quantity_delta, 'balance_after', v_new_balance));
  v_result := jsonb_build_object('movement_id', v_movement_id, 'balance', v_new_balance, 'movement_type', p_movement_type, 'status', 'committed');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.submit_stock_count(
  p_project_id uuid,
  p_location_id uuid,
  p_material_id uuid,
  p_counted_quantity numeric,
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
  v_ledger_quantity numeric(18, 3);
  v_ledger_revision bigint;
  v_count_id uuid;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'materials.receive') then raise exception using errcode = '42501', message = 'stock_count_denied'; end if;
  if p_counted_quantity is null or p_counted_quantity < 0 then raise exception using errcode = '22023', message = 'counted_quantity_invalid'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception using errcode = '22023', message = 'stock_count_reason_required'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'submit_stock_count', p_project_id,
    jsonb_build_object('location_id', p_location_id, 'material_id', p_material_id, 'counted_quantity', p_counted_quantity, 'reason', btrim(p_reason)));
  if v_replay is not null then return v_replay; end if;
  insert into public.stock_balances (project_id, location_id, material_id, available_quantity)
  values (p_project_id, p_location_id, p_material_id, 0) on conflict (project_id, location_id, material_id) do nothing;
  select sb.available_quantity, sb.revision into v_ledger_quantity, v_ledger_revision from public.stock_balances sb
  where sb.project_id = p_project_id and sb.location_id = p_location_id and sb.material_id = p_material_id for update;
  insert into public.stock_counts (project_id, location_id, material_id, ledger_quantity, ledger_revision, counted_quantity, reason, counted_by)
  values (p_project_id, p_location_id, p_material_id, v_ledger_quantity, v_ledger_revision, p_counted_quantity, btrim(p_reason), auth.uid())
  returning id into v_count_id;
  perform private.write_audit_event(p_project_id, null, 'materials.stock_count_submitted', 'stock_count', v_count_id,
    jsonb_build_object('variance', p_counted_quantity - v_ledger_quantity));
  v_result := jsonb_build_object('stock_count_id', v_count_id, 'status', 'pending_review', 'variance', p_counted_quantity - v_ledger_quantity);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.review_stock_count(
  p_project_id uuid,
  p_stock_count_id uuid,
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
  v_count public.stock_counts%rowtype;
  v_current_balance numeric(18, 3);
  v_current_revision bigint;
  v_variance numeric(18, 3);
  v_movement_id uuid;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'materials.adjust') then raise exception using errcode = '42501', message = 'stock_adjustment_review_denied'; end if;
  if p_decision not in ('approved', 'rejected') then raise exception using errcode = '22023', message = 'stock_count_decision_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'review_stock_count', p_project_id,
    jsonb_build_object('stock_count_id', p_stock_count_id, 'decision', p_decision));
  if v_replay is not null then return v_replay; end if;
  select * into v_count from public.stock_counts sc where sc.id = p_stock_count_id and sc.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'stock_count_not_found'; end if;
  if v_count.status <> 'pending_review' then raise exception using errcode = '55000', message = 'stock_count_not_pending'; end if;
  if v_count.counted_by = auth.uid() then raise exception using errcode = '42501', message = 'self_review_not_allowed'; end if;
  if p_decision = 'approved' then
    select sb.available_quantity, sb.revision into v_current_balance, v_current_revision from public.stock_balances sb
    where sb.project_id = p_project_id and sb.location_id = v_count.location_id and sb.material_id = v_count.material_id for update;
    if v_current_balance is distinct from v_count.ledger_quantity or v_current_revision <> v_count.ledger_revision then
      raise exception using errcode = '40001', message = 'stock_count_stale_recount_required';
    end if;
    v_variance := v_count.counted_quantity - v_current_balance;
    if v_variance <> 0 then
      insert into public.stock_movements (project_id, location_id, material_id, movement_type, quantity_delta, stock_count_id, reason, operation_id, created_by)
      values (p_project_id, v_count.location_id, v_count.material_id, 'adjustment', v_variance, p_stock_count_id,
        'Approved physical stock count: ' || v_count.reason, p_operation_id, auth.uid()) returning id into v_movement_id;
      update public.stock_balances set available_quantity = v_count.counted_quantity, revision = revision + 1, updated_at = now()
      where project_id = p_project_id and location_id = v_count.location_id and material_id = v_count.material_id;
    end if;
  end if;
  update public.stock_counts set status = p_decision, reviewed_by = auth.uid(), reviewed_at = now() where id = p_stock_count_id;
  perform private.write_audit_event(p_project_id, null, 'materials.stock_count_reviewed', 'stock_count', p_stock_count_id,
    jsonb_build_object('decision', p_decision, 'adjustment_movement_id', v_movement_id));
  v_result := jsonb_build_object('stock_count_id', p_stock_count_id, 'status', p_decision, 'adjustment_movement_id', v_movement_id);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;
