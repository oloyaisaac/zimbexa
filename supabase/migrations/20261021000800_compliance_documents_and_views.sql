-- Governance workflows that can be safely opened/recorded now; final protected transitions remain gated.

create unique index closeout_one_open_case_per_project_idx
  on public.closeout_cases (project_id) where status in ('submitted', 'disputed', 'approved');

create or replace function public.open_closeout_case(
  p_project_id uuid,
  p_checklist jsonb,
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
  v_project public.projects%rowtype;
  v_case_id uuid;
  v_snapshot jsonb;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'closeout.submit') then raise exception using errcode = '42501', message = 'closeout_submit_denied'; end if;
  if jsonb_typeof(coalesce(p_checklist, '{}'::jsonb)) <> 'object' then raise exception using errcode = '22023', message = 'closeout_checklist_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'open_closeout_case', p_project_id,
    jsonb_build_object('checklist', coalesce(p_checklist, '{}'::jsonb), 'reason', p_reason));
  if v_replay is not null then return v_replay; end if;
  select * into v_project from public.projects p where p.id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'project_not_found'; end if;
  if v_project.status not in ('active', 'paused', 'changes_required') then raise exception using errcode = '55000', message = 'project_not_ready_for_closeout'; end if;
  select jsonb_build_object(
    'currency', 'UGX',
    'approved_cost_ugx', coalesce((select sum(c.amount_ugx + coalesce((select sum(ca.delta_ugx) from public.cost_adjustments ca where ca.cost_record_id = c.id and ca.status = 'approved'), 0))
      from public.cost_records c where c.project_id = p_project_id and c.status = 'approved'), 0),
    'reported_payment_ugx', coalesce((select sum(rp.amount_ugx) from public.reported_payments rp where rp.project_id = p_project_id), 0),
    'open_material_requests', coalesce((select count(*) from public.material_requests mr where mr.project_id = p_project_id and mr.status not in ('fulfilled', 'closed', 'rejected')), 0),
    'stock_positions', coalesce((select count(*) from public.stock_balances sb where sb.project_id = p_project_id and sb.available_quantity > 0), 0),
    'approved_costs_are_not_payment_confirmation', true
  ) into v_snapshot;
  insert into public.closeout_cases (project_id, submitted_by, checklist, summary_snapshot, reason)
  values (p_project_id, auth.uid(), coalesce(p_checklist, '{}'::jsonb), v_snapshot, nullif(btrim(p_reason), ''))
  returning id into v_case_id;
  update public.projects set status = 'closeout_requested', revision = revision + 1 where id = p_project_id;
  insert into public.project_status_events (project_id, from_status, to_status, reason, actor_id, revision)
  values (p_project_id, v_project.status, 'closeout_requested', nullif(btrim(p_reason), ''), auth.uid(), v_project.revision + 1);
  perform private.write_audit_event(p_project_id, v_project.workspace_id, 'project.closeout_submitted', 'closeout_case', v_case_id,
    jsonb_build_object('project_revision', v_project.revision + 1));
  perform private.notify_project_members(p_project_id, 'project.closeout_submitted', 'A project closeout is ready for review.', 'closeout_case', v_case_id, auth.uid());
  v_result := jsonb_build_object('closeout_case_id', v_case_id, 'status', 'submitted', 'snapshot', v_snapshot,
    'final_completion_enabled', private.policy_gate_is_enabled('project_closeout_completion'));
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.review_closeout(
  p_project_id uuid,
  p_closeout_case_id uuid,
  p_decision text,
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
  v_case public.closeout_cases%rowtype;
  v_project public.projects%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'closeout.approve') then raise exception using errcode = '42501', message = 'closeout_review_denied'; end if;
  if p_decision not in ('changes_required', 'disputed', 'approved') then raise exception using errcode = '22023', message = 'closeout_decision_invalid'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception using errcode = '22023', message = 'closeout_review_reason_required'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'review_closeout', p_project_id,
    jsonb_build_object('closeout_case_id', p_closeout_case_id, 'decision', p_decision, 'reason', btrim(p_reason)));
  if v_replay is not null then return v_replay; end if;
  select * into v_case from public.closeout_cases c where c.id = p_closeout_case_id and c.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'closeout_case_not_found'; end if;
  if v_case.submitted_by = auth.uid() then raise exception using errcode = '42501', message = 'independent_closeout_review_required'; end if;
  if v_case.status not in ('submitted', 'changes_required', 'disputed') then raise exception using errcode = '55000', message = 'closeout_case_not_reviewable'; end if;
  update public.closeout_cases set status = p_decision, reviewed_by = auth.uid(), review_reason = btrim(p_reason), reviewed_at = now()
  where id = p_closeout_case_id;
  select * into v_project from public.projects p where p.id = p_project_id for update;
  update public.projects set status = case when p_decision = 'changes_required' then 'changes_required' when p_decision = 'disputed' then 'disputed' else 'closeout_requested' end,
    revision = revision + 1 where id = p_project_id;
  insert into public.project_status_events (project_id, from_status, to_status, reason, actor_id, revision)
  values (p_project_id, v_project.status, case when p_decision = 'changes_required' then 'changes_required' when p_decision = 'disputed' then 'disputed' else 'closeout_requested' end,
    btrim(p_reason), auth.uid(), v_project.revision + 1);
  insert into public.closeout_acknowledgements (project_id, closeout_case_id, acknowledged_by, acknowledgement, case_revision, comment)
  values (p_project_id, p_closeout_case_id, auth.uid(), p_decision, v_case.revision, btrim(p_reason));
  perform private.write_audit_event(p_project_id, null, 'project.closeout_reviewed', 'closeout_case', p_closeout_case_id,
    jsonb_build_object('decision', p_decision, 'case_revision', v_case.revision));
  v_result := jsonb_build_object('closeout_case_id', p_closeout_case_id, 'status', p_decision, 'project_status',
    case when p_decision = 'changes_required' then 'changes_required' when p_decision = 'disputed' then 'disputed' else 'closeout_requested' end);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.complete_closeout(p_project_id uuid, p_closeout_case_id uuid, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_case public.closeout_cases%rowtype;
  v_project public.projects%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'closeout.approve') then raise exception using errcode = '42501', message = 'closeout_completion_denied'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'complete_closeout', p_project_id, jsonb_build_object('closeout_case_id', p_closeout_case_id));
  if v_replay is not null then return v_replay; end if;
  perform private.require_policy_gate('project_closeout_completion');
  select * into v_case from public.closeout_cases c where c.id = p_closeout_case_id and c.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'closeout_case_not_found'; end if;
  if v_case.status <> 'approved' then raise exception using errcode = '55000', message = 'approved_closeout_review_required'; end if;
  if not exists (select 1 from public.closeout_acknowledgements a where a.closeout_case_id = p_closeout_case_id and a.acknowledgement = 'approved'
    and a.acknowledged_by <> v_case.submitted_by) then raise exception using errcode = '42501', message = 'independent_closeout_acknowledgement_required'; end if;
  if exists (select 1 from public.material_requests mr where mr.project_id = p_project_id and mr.status not in ('fulfilled', 'closed', 'rejected')) then
    raise exception using errcode = '23514', message = 'unresolved_material_requests_block_closeout';
  end if;
  select * into v_project from public.projects p where p.id = p_project_id for update;
  if v_project.status not in ('closeout_requested', 'changes_required') then raise exception using errcode = '55000', message = 'project_not_in_closeout'; end if;
  update public.projects set status = 'completed', revision = revision + 1 where id = p_project_id;
  update public.closeout_cases set status = 'completed', reviewed_at = now() where id = p_closeout_case_id;
  insert into public.project_status_events (project_id, from_status, to_status, actor_id, revision)
  values (p_project_id, v_project.status, 'completed', auth.uid(), v_project.revision + 1);
  perform private.write_audit_event(p_project_id, v_project.workspace_id, 'project.closeout_completed', 'closeout_case', p_closeout_case_id,
    jsonb_build_object('revision', v_project.revision + 1));
  v_result := jsonb_build_object('project_id', p_project_id, 'closeout_case_id', p_closeout_case_id, 'status', 'completed');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.request_project_export(
  p_project_id uuid,
  p_export_scope text,
  p_filters jsonb,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_export_id uuid;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'exports.request') then raise exception using errcode = '42501', message = 'export_request_denied'; end if;
  if p_export_scope not in ('summary', 'project_records', 'financial', 'documents', 'full') then raise exception using errcode = '22023', message = 'export_scope_invalid'; end if;
  if jsonb_typeof(coalesce(p_filters, '{}'::jsonb)) <> 'object' then raise exception using errcode = '22023', message = 'export_filters_invalid'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'request_project_export', p_project_id,
    jsonb_build_object('export_scope', p_export_scope, 'filters', coalesce(p_filters, '{}'::jsonb)));
  if v_replay is not null then return v_replay; end if;
  perform private.require_policy_gate('project_data_export');
  insert into public.export_jobs (project_id, requested_by, export_scope, filters)
  values (p_project_id, auth.uid(), p_export_scope, coalesce(p_filters, '{}'::jsonb)) returning id into v_export_id;
  insert into public.export_access_log (project_id, export_job_id, accessed_by, action)
  values (p_project_id, v_export_id, auth.uid(), 'requested');
  perform private.write_audit_event(p_project_id, null, 'project.export_requested', 'export_job', v_export_id, jsonb_build_object('scope', p_export_scope));
  perform private.enqueue_outbox_event('project.export_requested', p_project_id, auth.uid(), jsonb_build_object('export_job_id', v_export_id));
  v_result := jsonb_build_object('export_job_id', v_export_id, 'status', 'requested');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.open_support_case(
  p_project_id uuid,
  p_category text,
  p_detail text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_case_id uuid;
  v_scope_project_id uuid := p_project_id;
  v_result jsonb;
begin
  if p_category not in ('account', 'security', 'project_access', 'data_request', 'abuse', 'other') then raise exception using errcode = '22023', message = 'support_category_invalid'; end if;
  if char_length(btrim(coalesce(p_detail, ''))) not between 10 and 4000 then raise exception using errcode = '22023', message = 'support_detail_invalid'; end if;
  if p_project_id is not null and not private.has_project_permission(p_project_id, 'project.read') then
    -- Do not let a caller associate support text with an inaccessible tenant.
    v_scope_project_id := null;
  end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'open_support_case', v_scope_project_id,
    jsonb_build_object('project_id', v_scope_project_id, 'category', p_category, 'detail', btrim(p_detail)));
  if v_replay is not null then return v_replay; end if;
  insert into public.support_cases (created_by, project_id, category, detail)
  values (auth.uid(), v_scope_project_id, p_category, btrim(p_detail)) returning id into v_case_id;
  insert into public.support_case_events (support_case_id, actor_id, event_type, details)
  values (v_case_id, auth.uid(), 'created', jsonb_build_object('category', p_category));
  perform private.write_audit_event(v_scope_project_id, null, 'support.case_created', 'support_case', v_case_id, jsonb_build_object('category', p_category));
  v_result := jsonb_build_object('support_case_id', v_case_id, 'status', 'open');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.mark_notification_read(p_notification_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_project_id uuid;
begin
  update public.app_notifications set read_at = coalesce(read_at, now())
  where id = p_notification_id and recipient_user_id = auth.uid()
  returning project_id into v_project_id;
  if not found then raise exception using errcode = 'P0002', message = 'notification_not_found'; end if;
  return jsonb_build_object('notification_id', p_notification_id, 'read', true);
end;
$function$;

create or replace function public.set_notification_preference(
  p_event_type text,
  p_in_app_enabled boolean,
  p_email_enabled boolean,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_event_type text := btrim(coalesce(p_event_type, ''));
  v_result jsonb;
begin
  if v_event_type !~ '^[a-z0-9_.-]{1,100}$' or p_in_app_enabled is null or p_email_enabled is null then
    raise exception using errcode = '22023', message = 'notification_preference_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'set_notification_preference', null,
    jsonb_build_object('event_type', v_event_type, 'in_app_enabled', p_in_app_enabled, 'email_enabled', p_email_enabled));
  if v_replay is not null then return v_replay; end if;
  insert into public.notification_preferences (user_id, event_type, in_app_enabled, email_enabled, updated_at)
  values (auth.uid(), v_event_type, p_in_app_enabled, p_email_enabled, now())
  on conflict (user_id, event_type) do update
    set in_app_enabled = excluded.in_app_enabled, email_enabled = excluded.email_enabled, updated_at = now();
  v_result := jsonb_build_object('event_type', v_event_type,
    'in_app_enabled', p_in_app_enabled, 'email_enabled', p_email_enabled);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

-- Private evidence bucket. Uploads must correspond to an authenticated upload-intent row.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('zimbexa-project-evidence', 'zimbexa-project-evidence', false, 20971520,
  array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']::text[])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create or replace function private.record_belongs_to_project(p_record_type text, p_record_id uuid, p_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select case p_record_type
    when 'project' then exists (select 1 from public.projects r where r.id = p_record_id and r.id = p_project_id)
    when 'daily_report' then exists (select 1 from public.daily_reports r where r.id = p_record_id and r.project_id = p_project_id)
    when 'milestone' then exists (select 1 from public.milestones r where r.id = p_record_id and r.project_id = p_project_id)
    when 'material_request' then exists (select 1 from public.material_requests r where r.id = p_record_id and r.project_id = p_project_id)
    when 'stock_movement' then exists (select 1 from public.stock_movements r where r.id = p_record_id and r.project_id = p_project_id)
    when 'stock_count' then exists (select 1 from public.stock_counts r where r.id = p_record_id and r.project_id = p_project_id)
    when 'cost_record' then exists (select 1 from public.cost_records r where r.id = p_record_id and r.project_id = p_project_id)
    when 'cash_advance' then exists (select 1 from public.cash_advances r where r.id = p_record_id and r.project_id = p_project_id)
    when 'reported_payment' then exists (select 1 from public.reported_payments r where r.id = p_record_id and r.project_id = p_project_id)
    when 'labor_entry' then exists (select 1 from public.labor_entries r where r.id = p_record_id and r.project_id = p_project_id)
    when 'closeout_case' then exists (select 1 from public.closeout_cases r where r.id = p_record_id and r.project_id = p_project_id)
    when 'recovery_case' then exists (select 1 from public.recovery_cases r where r.id = p_record_id and r.project_id = p_project_id)
    when 'transfer_proposal' then exists (select 1 from public.transfer_proposals r where r.id = p_record_id and r.project_id = p_project_id)
    else false
  end;
$function$;

create or replace function private.can_upload_storage_object(p_object_key text, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1 from public.documents d
    where d.object_key = p_object_key and d.uploaded_by = p_user_id and d.status = 'upload_pending'
      and private.has_project_permission(d.project_id, 'documents.upload')
  );
$function$;

create or replace function private.can_read_storage_object(p_object_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1 from public.documents d
    where d.object_key = p_object_key and d.status = 'available'
      and private.has_project_permission(d.project_id, 'documents.read')
  );
$function$;

create or replace function public.create_document_upload_intent(
  p_project_id uuid,
  p_record_type text,
  p_record_id uuid,
  p_purpose text,
  p_original_filename text,
  p_mime_type text,
  p_size_bytes bigint,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_document_id uuid;
  v_object_key text;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'documents.upload') then raise exception using errcode = '42501', message = 'document_upload_denied'; end if;
  if p_mime_type not in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf')
     or p_size_bytes is null or p_size_bytes not between 1 and 20971520
     or char_length(coalesce(p_original_filename, '')) not between 1 and 255
     or char_length(btrim(coalesce(p_purpose, ''))) not between 1 and 300 then
    raise exception using errcode = '22023', message = 'document_upload_metadata_invalid';
  end if;
  if (p_record_type is null) <> (p_record_id is null) then
    raise exception using errcode = '22023', message = 'document_record_link_incomplete';
  end if;
  if p_record_id is not null and not private.record_belongs_to_project(p_record_type, p_record_id, p_project_id) then
    raise exception using errcode = '23514', message = 'document_record_must_belong_to_same_project';
  end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'create_document_upload_intent', p_project_id,
    jsonb_build_object('record_type', p_record_type, 'record_id', p_record_id, 'purpose', btrim(p_purpose),
      'filename', p_original_filename, 'mime_type', p_mime_type, 'size_bytes', p_size_bytes));
  if v_replay is not null then return v_replay; end if;
  v_document_id := gen_random_uuid();
  v_object_key := p_project_id::text || '/' || v_document_id::text;
  insert into public.documents (
    id, project_id, uploaded_by, record_type, record_id, purpose, original_filename, object_key, mime_type, size_bytes
  ) values (
    v_document_id, p_project_id, auth.uid(), nullif(btrim(p_record_type), ''), p_record_id, btrim(p_purpose),
    p_original_filename, v_object_key, p_mime_type, p_size_bytes
  );
  perform private.write_audit_event(p_project_id, null, 'documents.upload_intent_created', 'document', v_document_id,
    jsonb_build_object('mime_type', p_mime_type, 'size_bytes', p_size_bytes));
  v_result := jsonb_build_object('document_id', v_document_id, 'bucket', 'zimbexa-project-evidence',
    'object_key', v_object_key, 'status', 'upload_pending', 'maximum_bytes', 20971520);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.finalize_document_upload(p_project_id uuid, p_document_id uuid, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_document public.documents%rowtype;
  v_storage_size bigint;
  v_storage_mime text;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'documents.upload') then raise exception using errcode = '42501', message = 'document_finalize_denied'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'finalize_document_upload', p_project_id,
    jsonb_build_object('document_id', p_document_id));
  if v_replay is not null then return v_replay; end if;
  select * into v_document from public.documents d where d.id = p_document_id and d.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'document_not_found'; end if;
  if v_document.uploaded_by <> auth.uid() then raise exception using errcode = '42501', message = 'document_uploader_only'; end if;
  if v_document.status <> 'upload_pending' then raise exception using errcode = '55000', message = 'document_not_pending_upload'; end if;
  select nullif(o.metadata ->> 'size', '')::bigint, o.metadata ->> 'mimetype'
  into v_storage_size, v_storage_mime from storage.objects o
  where o.bucket_id = 'zimbexa-project-evidence' and o.name = v_document.object_key;
  if not found then raise exception using errcode = 'P0002', message = 'uploaded_object_not_found'; end if;
  if v_storage_size is null or v_storage_size <> v_document.size_bytes then
    raise exception using errcode = '22023', message = 'uploaded_object_size_mismatch';
  end if;
  if v_storage_mime is null or v_storage_mime <> v_document.mime_type then
    raise exception using errcode = '22023', message = 'uploaded_object_type_mismatch';
  end if;
  update public.documents set status = 'scanning', uploaded_at = now() where id = p_document_id;
  perform private.enqueue_outbox_event('documents.scan_requested', p_project_id, auth.uid(), jsonb_build_object('document_id', p_document_id));
  perform private.write_audit_event(p_project_id, null, 'documents.upload_finalized', 'document', p_document_id,
    jsonb_build_object('status', 'scanning'));
  v_result := jsonb_build_object('document_id', p_document_id, 'status', 'scanning', 'readable', false);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.record_document_scan_result(
  p_document_id uuid,
  p_scan_result text,
  p_sha256 bytea
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_document public.documents%rowtype;
  v_status text;
begin
  if p_scan_result not in ('clean', 'rejected') then raise exception using errcode = '22023', message = 'document_scan_result_invalid'; end if;
  if p_sha256 is null or octet_length(p_sha256) <> 32 then raise exception using errcode = '22023', message = 'document_hash_required'; end if;
  select * into v_document from public.documents d where d.id = p_document_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'document_not_found'; end if;
  if v_document.status in ('available', 'rejected') and v_document.scan_result = p_scan_result
     and v_document.sha256 is not distinct from p_sha256 then
    return jsonb_build_object('document_id', p_document_id, 'status', v_document.status, 'replayed', true);
  end if;
  if v_document.status <> 'scanning' then raise exception using errcode = '55000', message = 'document_not_awaiting_scan'; end if;
  v_status := case when p_scan_result = 'clean' then 'available' else 'rejected' end;
  update public.documents set status = v_status, scan_result = p_scan_result, scanned_at = now(), sha256 = p_sha256 where id = p_document_id;
  insert into public.document_versions (project_id, document_id, version, object_key, sha256, size_bytes, mime_type, created_by)
  values (v_document.project_id, p_document_id, 1, v_document.object_key, p_sha256,
    v_document.size_bytes, v_document.mime_type, v_document.uploaded_by);
  perform private.write_audit_event(v_document.project_id, null, 'documents.scan_completed', 'document', p_document_id,
    jsonb_build_object('scan_result', p_scan_result));
  return jsonb_build_object('document_id', p_document_id, 'status', v_status);
end;
$function$;

-- Service-role-only outbox leasing. Delivery integrations can be attached without weakening business writes.
create or replace function public.claim_outbox_events(p_worker_id text, p_limit integer)
returns setof public.outbox_events
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if char_length(btrim(coalesce(p_worker_id, ''))) not between 1 and 120 then raise exception using errcode = '22023', message = 'worker_id_invalid'; end if;
  return query
  with candidates as (
    select e.id
    from public.outbox_events e
    where ((e.status in ('pending', 'retry') and e.available_at <= now())
       or (e.status = 'processing' and e.lease_until < now()))
    order by e.available_at, e.created_at
    for update skip locked
    limit least(greatest(coalesce(p_limit, 20), 1), 100)
  )
  update public.outbox_events e
  set status = 'processing', attempts = attempts + 1, lease_until = now() + interval '2 minutes', lease_owner = p_worker_id
  from candidates c where e.id = c.id
  returning e.*;
end;
$function$;

create or replace function public.finish_outbox_event(p_event_id uuid, p_worker_id text, p_succeeded boolean, p_error_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_event public.outbox_events%rowtype;
begin
  update public.outbox_events e
  set status = case when p_succeeded then 'delivered' when e.attempts >= 8 then 'dead_letter' else 'retry' end,
      delivered_at = case when p_succeeded then now() else null end,
      available_at = case when p_succeeded then e.available_at else now() + make_interval(secs => least(3600, greatest(30, e.attempts * 60))) end,
      last_error_code = case when p_succeeded then null else left(coalesce(p_error_code, 'delivery_failed'), 120) end,
      lease_until = null, lease_owner = null
  where e.id = p_event_id and e.status = 'processing' and e.lease_owner = p_worker_id
  returning e.* into v_event;
  if not found then raise exception using errcode = '42501', message = 'outbox_lease_not_owned'; end if;
  return jsonb_build_object('event_id', v_event.id, 'status', v_event.status, 'attempts', v_event.attempts);
end;
$function$;

-- RLS-aware views; finance is separately authorized and never conflated with cash movement/payment.
create or replace view public.project_financial_summary
with (security_invoker = true)
as
select
  p.id as project_id,
  'UGX'::text as currency,
  coalesce((
    select sum(bl.amount_ugx)
    from public.budget_versions bv join public.budget_lines bl on bl.budget_version_id = bv.id
    where bv.project_id = p.id and bv.status = 'approved'
      and bv.version = (select max(bv2.version) from public.budget_versions bv2 where bv2.project_id = p.id and bv2.status = 'approved')
  ), 0)::bigint as approved_budget_ugx,
  coalesce((
    select sum(c.amount_ugx + coalesce((select sum(ca.delta_ugx) from public.cost_adjustments ca where ca.cost_record_id = c.id and ca.status = 'approved'), 0))
    from public.cost_records c where c.project_id = p.id and c.status = 'approved'
  ), 0)::bigint as approved_costs_ugx,
  coalesce((select sum(rp.amount_ugx) from public.reported_payments rp where rp.project_id = p.id), 0)::bigint as reported_payments_ugx,
  coalesce((select sum(rp.amount_ugx) from public.reported_payments rp where rp.project_id = p.id and rp.verification_status = 'independently_reconciled'), 0)::bigint as independently_reconciled_payments_ugx,
  'reported payments are not provider-confirmed by default'::text as payment_status_note
from public.projects p
where private.has_project_permission(p.id, 'finance.read');

create or replace view public.cash_advance_summary
with (security_invoker = true)
as
select
  ca.id as cash_advance_id,
  ca.project_id,
  ca.custodian_user_id,
  ca.amount_ugx,
  ca.status,
  coalesce((select sum(a.amount_ugx) from public.advance_allocations a where a.advance_id = ca.id), 0)::bigint as allocated_to_approved_costs_ugx,
  coalesce((select sum(r.amount_ugx) from public.cash_returns r where r.advance_id = ca.id), 0)::bigint as cash_returned_ugx,
  greatest(ca.amount_ugx - coalesce((select sum(a.amount_ugx) from public.advance_allocations a where a.advance_id = ca.id), 0)
    - coalesce((select sum(r.amount_ugx) from public.cash_returns r where r.advance_id = ca.id), 0), 0)::bigint as unaccounted_ugx,
  'cash advance is not a project expense'::text as accounting_note
from public.cash_advances ca
where private.has_project_permission(ca.project_id, 'finance.read');

create or replace view public.project_progress_summary
with (security_invoker = true)
as
select
  p.id as project_id,
  count(m.id)::integer as milestone_count,
  count(*) filter (where m.status = 'done')::integer as completed_milestone_count,
  case when count(m.id) > 0 and count(*) filter (where m.weight is null) = 0 and sum(m.weight) > 0
    then round(100 * sum(m.weight * m.completion_fraction) / sum(m.weight), 2)
    else null end as weighted_progress_percent,
  case when count(m.id) = 0 or count(*) filter (where m.weight is null) > 0 or coalesce(sum(m.weight), 0) = 0
    then 'Progress not calculated: milestones need reviewed weights.'
    else 'Weighted reported milestone progress; not independent verification.' end as progress_basis
from public.projects p
left join public.milestones m on m.project_id = p.id
where private.has_project_permission(p.id, 'project.read')
group by p.id;

create or replace view public.project_invitation_summaries
with (security_barrier = true)
as
select i.id, i.project_id, i.recipient_email, i.role, i.permission_keys,
  case when i.status = 'pending' and i.expires_at <= now() then 'expired' else i.status end as status,
  i.invited_by, i.accepted_by, i.expires_at, i.accepted_at, i.created_at
from public.project_invitations i
where private.has_project_permission(i.project_id, 'project.invite');

create or replace view public.project_stock_summary
with (security_invoker = true)
as
select sb.project_id, sb.location_id, sl.name as location_name, sb.material_id, m.name as material_name,
  m.specification, m.base_unit, sb.available_quantity, sb.revision, sb.updated_at
from public.stock_balances sb
join public.stock_locations sl on sl.id = sb.location_id and sl.project_id = sb.project_id
join public.materials m on m.id = sb.material_id and m.project_id = sb.project_id
where private.has_project_permission(sb.project_id, 'materials.read');

-- Private object rules: every upload/download is bound to an authorized metadata row, never a guessed public URL.
alter table storage.objects enable row level security;
create policy zimbexa_evidence_upload on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'zimbexa-project-evidence'
    and private.can_upload_storage_object(name, auth.uid())
  );
create policy zimbexa_evidence_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'zimbexa-project-evidence'
    and private.can_read_storage_object(name)
  );
