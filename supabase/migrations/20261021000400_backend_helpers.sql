-- Reusable authorization, idempotency, audit, and identity hooks.
-- Security-definer functions always use an empty search_path and schema-qualified objects.

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;
revoke all on function public.touch_updated_at() from public, anon, authenticated;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_display_name text;
begin
  v_display_name := left(btrim(coalesce(
    new.raw_user_meta_data ->> 'display_name',
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'name',
    'New user'
  )), 100);
  if v_display_name = '' then
    v_display_name := 'New user';
  end if;
  insert into public.profiles (id, display_name)
  values (new.id, v_display_name)
  on conflict (id) do nothing;
  return new;
end;
$function$;
revoke all on function public.handle_new_auth_user() from public, anon, authenticated;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

create trigger profiles_touch_updated_at before update on public.profiles
  for each row execute function public.touch_updated_at();
create trigger workspaces_touch_updated_at before update on public.workspaces
  for each row execute function public.touch_updated_at();
create trigger projects_touch_updated_at before update on public.projects
  for each row execute function public.touch_updated_at();
create trigger support_cases_touch_updated_at before update on public.support_cases
  for each row execute function public.touch_updated_at();
create trigger daily_reports_touch_updated_at before update on public.daily_reports
  for each row execute function public.touch_updated_at();
create trigger milestones_touch_updated_at before update on public.milestones
  for each row execute function public.touch_updated_at();
create trigger material_requests_touch_updated_at before update on public.material_requests
  for each row execute function public.touch_updated_at();
create trigger cost_records_touch_updated_at before update on public.cost_records
  for each row execute function public.touch_updated_at();
create trigger labor_entries_touch_updated_at before update on public.labor_entries
  for each row execute function public.touch_updated_at();

create or replace function private.has_workspace_access(p_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.workspace_memberships wm
    join public.workspaces w on w.id = wm.workspace_id and w.status = 'active'
    where wm.workspace_id = p_workspace_id
      and wm.user_id = auth.uid()
      and wm.status = 'active'
  );
$function$;

create or replace function private.has_workspace_admin(p_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.workspace_memberships wm
    where wm.workspace_id = p_workspace_id
      and wm.user_id = auth.uid()
      and wm.status = 'active'
      and wm.role = 'admin'
  );
$function$;

create or replace function private.has_project_permission(p_project_id uuid, p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select
    exists (
      select 1
      from public.project_memberships pm
      where pm.project_id = p_project_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and case p_permission
          when 'project.read' then true
          when 'project.update' then pm.role in ('custodian', 'manager')
          when 'project.invite' then pm.role in ('custodian', 'manager')
          when 'project.manage_members' then pm.role = 'custodian'
          when 'project.archive' then pm.role = 'custodian'
          when 'reports.read' then pm.role in ('custodian', 'manager', 'supervisor', 'storekeeper', 'accountant', 'engineer', 'viewer')
          when 'reports.create' then pm.role in ('custodian', 'manager', 'supervisor', 'storekeeper')
          when 'reports.review' then pm.role in ('custodian', 'manager')
          when 'milestones.manage' then pm.role in ('custodian', 'manager')
          when 'materials.read' then pm.role in ('custodian', 'manager', 'supervisor', 'storekeeper', 'accountant', 'engineer', 'viewer')
          when 'materials.request' then pm.role in ('custodian', 'manager', 'supervisor', 'storekeeper')
          when 'materials.approve' then pm.role = 'custodian'
          when 'materials.receive' then pm.role in ('custodian', 'manager', 'supervisor', 'storekeeper')
          when 'materials.issue' then pm.role in ('custodian', 'manager', 'supervisor', 'storekeeper')
          when 'materials.adjust' then pm.role = 'custodian'
          when 'finance.read' then pm.role in ('custodian', 'manager', 'accountant')
          when 'finance.submit' then pm.role in ('custodian', 'manager', 'supervisor', 'accountant')
          when 'finance.approve' then pm.role = 'custodian'
          when 'finance.advance' then pm.role in ('custodian', 'manager', 'accountant')
          when 'labor.read' then pm.role in ('custodian', 'manager', 'supervisor', 'storekeeper', 'accountant')
          when 'labor.manage' then pm.role in ('custodian', 'manager', 'supervisor')
          when 'labor.pay.read' then pm.role in ('custodian', 'manager', 'accountant')
          when 'documents.read' then pm.role in ('custodian', 'manager', 'supervisor', 'storekeeper', 'accountant', 'engineer', 'viewer')
          when 'documents.upload' then pm.role in ('custodian', 'manager', 'supervisor', 'storekeeper', 'accountant', 'engineer')
          when 'audit.read' then pm.role in ('custodian', 'manager')
          when 'closeout.submit' then pm.role in ('custodian', 'manager')
          when 'closeout.approve' then pm.role = 'custodian'
          when 'exports.request' then pm.role in ('custodian', 'manager', 'accountant')
          else false
        end
    )
    or exists (
      select 1
      from public.project_permission_grants pg
      join public.project_memberships pm
        on pm.project_id = pg.project_id
       and pm.user_id = pg.user_id
       and pm.status = 'active'
      where pg.project_id = p_project_id
        and pg.user_id = auth.uid()
        and pg.permission_key = p_permission
        and pg.revoked_at is null
    );
$function$;

create or replace function private.is_project_custodian(p_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1 from public.project_memberships pm
    where pm.project_id = p_project_id
      and pm.user_id = auth.uid()
      and pm.role = 'custodian'
      and pm.status = 'active'
  );
$function$;

create or replace function private.policy_gate_is_enabled(p_gate_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1 from private.policy_gates g
    where g.gate_key = p_gate_key and g.status = 'enabled'
  );
$function$;

create or replace function private.require_policy_gate(p_gate_key text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if not private.policy_gate_is_enabled(p_gate_key) then
    raise exception using
      errcode = '55000',
      message = 'release_gate_blocked',
      detail = p_gate_key || ' is closed pending documented product, legal, privacy, and security sign-off';
  end if;
end;
$function$;

create or replace function private.begin_idempotent_operation(
  p_operation_id uuid,
  p_operation_name text,
  p_project_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_hash bytea;
  v_rows integer;
  v_existing private.idempotency_records%rowtype;
begin
  if v_actor_id is null then
    raise exception using errcode = '28000', message = 'authentication_required';
  end if;
  if p_operation_id is null then
    raise exception using errcode = '22023', message = 'operation_id_required';
  end if;
  v_hash := extensions.digest(convert_to(coalesce(p_payload, '{}'::jsonb)::text, 'UTF8'), 'sha256');

  insert into private.idempotency_records (actor_id, operation_id, operation_name, project_id, request_hash)
  values (v_actor_id, p_operation_id, p_operation_name, p_project_id, v_hash)
  on conflict (actor_id, operation_id) do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 1 then
    return null;
  end if;

  select * into v_existing
  from private.idempotency_records ir
  where ir.actor_id = v_actor_id and ir.operation_id = p_operation_id
  for update;
  if v_existing.operation_name <> p_operation_name
     or v_existing.project_id is distinct from p_project_id
     or v_existing.request_hash <> v_hash then
    raise exception using errcode = '23505', message = 'operation_id_reused_with_different_request';
  end if;
  if v_existing.response is null then
    raise exception using errcode = '40001', message = 'operation_still_processing_retry_same_id';
  end if;
  return v_existing.response;
end;
$function$;

create or replace function private.complete_idempotent_operation(p_operation_id uuid, p_response jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  update private.idempotency_records
  set response = p_response
  where actor_id = auth.uid() and operation_id = p_operation_id and response is null;
  if not found then
    raise exception using errcode = '40001', message = 'idempotency_record_not_claimed';
  end if;
end;
$function$;

create or replace function private.write_audit_event(
  p_project_id uuid,
  p_workspace_id uuid,
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_id uuid;
  v_actor uuid := auth.uid();
  v_actor_display text;
  v_request_id text;
begin
  if v_actor is not null then
    select p.display_name into v_actor_display from public.profiles p where p.id = v_actor;
  end if;
  v_request_id := nullif(current_setting('request.jwt.claim.request_id', true), '');
  insert into public.audit_events (
    project_id, workspace_id, actor_id, actor_display_snapshot,
    action, entity_type, entity_id, request_id, metadata
  ) values (
    p_project_id, p_workspace_id, v_actor, v_actor_display,
    p_action, p_entity_type, p_entity_id, v_request_id, coalesce(p_metadata, '{}'::jsonb)
  ) returning id into v_id;
  return v_id;
end;
$function$;

create or replace function private.enqueue_outbox_event(
  p_event_type text,
  p_project_id uuid,
  p_recipient_user_id uuid,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language sql
security definer
set search_path = ''
as $function$
  insert into public.outbox_events (event_type, project_id, recipient_user_id, payload)
  values (p_event_type, p_project_id, p_recipient_user_id, coalesce(p_payload, '{}'::jsonb))
  returning id;
$function$;

create or replace function private.notify_project_members(
  p_project_id uuid,
  p_event_type text,
  p_summary text,
  p_entity_type text,
  p_entity_id uuid,
  p_exclude_user_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_count integer;
begin
  insert into public.app_notifications (recipient_user_id, project_id, event_type, summary, entity_type, entity_id)
  select pm.user_id, p_project_id, p_event_type, p_summary, p_entity_type, p_entity_id
  from public.project_memberships pm
  left join public.notification_preferences np
    on np.user_id = pm.user_id and np.event_type = p_event_type
  where pm.project_id = p_project_id
    and pm.status = 'active'
    and coalesce(np.in_app_enabled, true)
    and (p_exclude_user_id is null or pm.user_id <> p_exclude_user_id);
  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

create or replace function private.project_is_operational(p_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1 from public.projects p
    where p.id = p_project_id and p.status = 'active'
  );
$function$;

create or replace function private.prevent_immutable_change()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  raise exception using errcode = '55000', message = 'record_is_append_only';
end;
$function$;

create or replace function private.audit_policy_gate_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if old.status is distinct from new.status
     or old.policy_version is distinct from new.policy_version
     or old.evidence_reference is distinct from new.evidence_reference
     or old.approved_by is distinct from new.approved_by
     or old.approved_at is distinct from new.approved_at then
    insert into private.policy_gate_events (gate_key, previous_status, new_status, policy_version, evidence_reference, approved_by)
    values (new.gate_key, old.status, new.status, new.policy_version, new.evidence_reference, new.approved_by);
    perform private.write_audit_event(null, null, 'platform.policy_gate_changed', 'platform', gen_random_uuid(),
      jsonb_build_object('gate_key', new.gate_key, 'from', old.status, 'to', new.status,
        'policy_version', new.policy_version, 'evidence_reference', new.evidence_reference, 'approved_by', new.approved_by));
  end if;
  return new;
end;
$function$;
create trigger policy_gate_change_audit after update on private.policy_gates
  for each row execute function private.audit_policy_gate_change();

create or replace function private.set_policy_gate(
  p_gate_key text,
  p_status text,
  p_policy_version text,
  p_evidence_reference text,
  p_approved_by uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_old_status text;
begin
  if p_status not in ('pending_signoff', 'approved', 'enabled', 'suspended') then
    raise exception using errcode = '22023', message = 'policy_gate_status_invalid';
  end if;
  if p_status in ('approved', 'enabled') then
    if char_length(btrim(coalesce(p_policy_version, ''))) < 1 or char_length(btrim(coalesce(p_evidence_reference, ''))) < 3 or p_approved_by is null then
      raise exception using errcode = '22023', message = 'documented_signoff_required';
    end if;
  end if;
  select g.status into v_old_status from private.policy_gates g where g.gate_key = p_gate_key for update;
  if not found then raise exception using errcode = 'P0002', message = 'policy_gate_not_found'; end if;
  update private.policy_gates set status = p_status,
    policy_version = case when p_status in ('approved', 'enabled') then btrim(p_policy_version) when p_status = 'pending_signoff' then null else policy_version end,
    evidence_reference = case when p_status in ('approved', 'enabled') then btrim(p_evidence_reference) when p_status = 'pending_signoff' then null else evidence_reference end,
    approved_by = case when p_status in ('approved', 'enabled') then p_approved_by when p_status = 'pending_signoff' then null else approved_by end,
    approved_at = case when p_status in ('approved', 'enabled') then now() when p_status = 'pending_signoff' then null else approved_at end,
    updated_at = now()
  where gate_key = p_gate_key;
  return jsonb_build_object('gate_key', p_gate_key, 'previous_status', v_old_status, 'status', p_status);
end;
$function$;

-- Functions in the private schema are callable only by the policies/RPCs that need them.
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.has_workspace_access(uuid) to authenticated, service_role;
grant execute on function private.has_workspace_admin(uuid) to authenticated, service_role;
grant execute on function private.has_project_permission(uuid, text) to authenticated, service_role;
grant execute on function private.is_project_custodian(uuid) to authenticated, service_role;
grant execute on function private.policy_gate_is_enabled(text) to authenticated, service_role;
grant execute on function private.require_policy_gate(text) to authenticated, service_role;
grant execute on function private.begin_idempotent_operation(uuid, text, uuid, jsonb) to authenticated, service_role;
grant execute on function private.complete_idempotent_operation(uuid, jsonb) to authenticated, service_role;
grant execute on function private.write_audit_event(uuid, uuid, text, text, uuid, jsonb) to authenticated, service_role;
grant execute on function private.enqueue_outbox_event(text, uuid, uuid, jsonb) to authenticated, service_role;
grant execute on function private.notify_project_members(uuid, text, text, text, uuid, uuid) to authenticated, service_role;
grant execute on function private.project_is_operational(uuid) to authenticated, service_role;
grant execute on function private.prevent_immutable_change() to service_role;
grant execute on function private.set_policy_gate(text, text, text, text, uuid) to service_role;
