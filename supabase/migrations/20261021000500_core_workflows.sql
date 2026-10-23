-- Authenticated RPCs for workspace/project lifecycle, invitations, membership, and gated governance.

create or replace function public.create_workspace(p_name text, p_kind text, p_operation_id uuid)
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
  if auth.uid() is null then raise exception using errcode = '28000', message = 'authentication_required'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 120 then
    raise exception using errcode = '22023', message = 'workspace_name_invalid';
  end if;
  if p_kind not in ('personal', 'organization') then
    raise exception using errcode = '22023', message = 'workspace_kind_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'create_workspace', null,
    jsonb_build_object('name', btrim(p_name), 'kind', p_kind)
  );
  if v_replay is not null then return v_replay; end if;

  insert into public.workspaces (name, kind, created_by)
  values (btrim(p_name), p_kind, auth.uid())
  returning id into v_id;
  insert into public.workspace_memberships (workspace_id, user_id, role)
  values (v_id, auth.uid(), 'admin');
  perform private.write_audit_event(null, v_id, 'workspace.created', 'workspace', v_id, jsonb_build_object('kind', p_kind));
  v_result := jsonb_build_object('workspace_id', v_id, 'status', 'active');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.create_project(
  p_workspace_id uuid,
  p_name text,
  p_project_type text,
  p_region text,
  p_district text,
  p_town text,
  p_planned_start_date date,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_project_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception using errcode = '28000', message = 'authentication_required'; end if;
  if not private.has_workspace_access(p_workspace_id) then
    raise exception using errcode = '42501', message = 'workspace_access_denied';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 160 then
    raise exception using errcode = '22023', message = 'project_name_invalid';
  end if;
  if char_length(btrim(coalesce(p_project_type, ''))) not between 1 and 80 then
    raise exception using errcode = '22023', message = 'project_type_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'create_project', null,
    jsonb_build_object('workspace_id', p_workspace_id, 'name', btrim(p_name), 'project_type', btrim(p_project_type),
      'region', p_region, 'district', p_district, 'town', p_town, 'planned_start_date', p_planned_start_date)
  );
  if v_replay is not null then return v_replay; end if;

  insert into public.projects (
    workspace_id, name, project_type, region, district, town, planned_start_date, created_by
  ) values (
    p_workspace_id, btrim(p_name), btrim(p_project_type), nullif(btrim(p_region), ''),
    nullif(btrim(p_district), ''), nullif(btrim(p_town), ''), p_planned_start_date, auth.uid()
  ) returning id into v_project_id;

  insert into public.project_memberships (project_id, user_id, role)
  values (v_project_id, auth.uid(), 'custodian');
  insert into public.project_governance_versions (project_id, version, policy_snapshot, created_by)
  values (v_project_id, 1, jsonb_build_object('custody_policy', 'pending_signoff', 'recovery_policy', 'pending_signoff'), auth.uid());
  insert into public.stock_locations (project_id, name, created_by)
  values (v_project_id, 'Main site', auth.uid());
  insert into public.project_status_events (project_id, from_status, to_status, actor_id, revision)
  values (v_project_id, null, 'draft', auth.uid(), 1);
  insert into public.project_membership_events (project_id, membership_id, actor_id, event_type, details)
  select v_project_id, pm.id, auth.uid(), 'joined', jsonb_build_object('role', 'custodian')
  from public.project_memberships pm where pm.project_id = v_project_id and pm.user_id = auth.uid();
  perform private.write_audit_event(v_project_id, p_workspace_id, 'project.created', 'project', v_project_id, jsonb_build_object('status', 'draft'));
  v_result := jsonb_build_object('project_id', v_project_id, 'status', 'draft', 'revision', 1);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.update_project_details(
  p_project_id uuid,
  p_expected_revision integer,
  p_name text,
  p_project_type text,
  p_region text,
  p_district text,
  p_town text,
  p_planned_start_date date,
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
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'project.update') then
    raise exception using errcode = '42501', message = 'project_update_denied';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 160
     or char_length(btrim(coalesce(p_project_type, ''))) not between 1 and 80 then
    raise exception using errcode = '22023', message = 'project_details_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'update_project_details', p_project_id,
    jsonb_build_object('expected_revision', p_expected_revision, 'name', btrim(p_name), 'project_type', btrim(p_project_type),
      'region', p_region, 'district', p_district, 'town', p_town, 'planned_start_date', p_planned_start_date)
  );
  if v_replay is not null then return v_replay; end if;

  select * into v_project from public.projects p where p.id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'project_not_found'; end if;
  if p_expected_revision is null or v_project.revision <> p_expected_revision then
    raise exception using errcode = '40001', message = 'revision_conflict', detail = 'Reload the current project before retrying.';
  end if;
  if v_project.status not in ('draft', 'active') then
    raise exception using errcode = '55000', message = 'project_not_editable_in_current_state';
  end if;
  update public.projects
  set name = btrim(p_name), project_type = btrim(p_project_type),
      region = nullif(btrim(p_region), ''), district = nullif(btrim(p_district), ''),
      town = nullif(btrim(p_town), ''), planned_start_date = p_planned_start_date,
      revision = revision + 1
  where id = p_project_id;
  v_result := jsonb_build_object('project_id', p_project_id, 'revision', p_expected_revision + 1);
  perform private.write_audit_event(p_project_id, v_project.workspace_id, 'project.details_updated', 'project', p_project_id,
    jsonb_build_object('revision', p_expected_revision + 1));
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.activate_project(p_project_id uuid, p_expected_revision integer, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_project public.projects%rowtype;
  v_result jsonb;
begin
  if not private.is_project_custodian(p_project_id) then
    raise exception using errcode = '42501', message = 'custodian_authority_required';
  end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'activate_project', p_project_id, jsonb_build_object('expected_revision', p_expected_revision)
  );
  if v_replay is not null then return v_replay; end if;
  perform private.require_policy_gate('project_activation');
  select * into v_project from public.projects p where p.id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'project_not_found'; end if;
  if p_expected_revision is null or v_project.revision <> p_expected_revision then
    raise exception using errcode = '40001', message = 'revision_conflict';
  end if;
  if v_project.status <> 'draft' then raise exception using errcode = '55000', message = 'project_must_be_draft'; end if;
  if not exists (
    select 1 from public.project_recovery_routes rr
    where rr.project_id = p_project_id and rr.status = 'verified'
      and rr.nominee_user_id <> auth.uid()
  ) then
    raise exception using errcode = '23514', message = 'verified_recovery_route_required';
  end if;
  update public.projects set status = 'active', revision = revision + 1 where id = p_project_id;
  insert into public.project_status_events (project_id, from_status, to_status, actor_id, revision)
  values (p_project_id, 'draft', 'active', auth.uid(), p_expected_revision + 1);
  perform private.write_audit_event(p_project_id, v_project.workspace_id, 'project.activated', 'project', p_project_id,
    jsonb_build_object('revision', p_expected_revision + 1));
  v_result := jsonb_build_object('project_id', p_project_id, 'status', 'active', 'revision', p_expected_revision + 1);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.pause_project(p_project_id uuid, p_expected_revision integer, p_reason text, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_project public.projects%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'project.update') then
    raise exception using errcode = '42501', message = 'project_update_denied';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 3 and 1000 then
    raise exception using errcode = '22023', message = 'pause_reason_required';
  end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'pause_project', p_project_id,
    jsonb_build_object('expected_revision', p_expected_revision, 'reason', btrim(p_reason))
  );
  if v_replay is not null then return v_replay; end if;
  select * into v_project from public.projects p where p.id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'project_not_found'; end if;
  if p_expected_revision is null or v_project.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'revision_conflict'; end if;
  if v_project.status <> 'active' then raise exception using errcode = '55000', message = 'only_active_project_can_be_paused'; end if;
  update public.projects set status = 'paused', revision = revision + 1 where id = p_project_id;
  insert into public.project_status_events (project_id, from_status, to_status, reason, actor_id, revision)
  values (p_project_id, 'active', 'paused', btrim(p_reason), auth.uid(), p_expected_revision + 1);
  perform private.write_audit_event(p_project_id, v_project.workspace_id, 'project.paused', 'project', p_project_id, '{}'::jsonb);
  v_result := jsonb_build_object('project_id', p_project_id, 'status', 'paused', 'revision', p_expected_revision + 1);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.invite_project_member(
  p_project_id uuid,
  p_email text,
  p_role text,
  p_permission_keys text[],
  p_expires_in_hours integer,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_invitation_id uuid;
  v_expired_invitation_id uuid;
  v_token text;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'project.invite') then
    raise exception using errcode = '42501', message = 'project_invite_denied';
  end if;
  if not exists (select 1 from public.projects p where p.id = p_project_id and p.status in ('draft', 'active')) then
    raise exception using errcode = '55000', message = 'project_not_accepting_invitations';
  end if;
  if length(v_email) < 3 or length(v_email) > 320 or position('@' in v_email) < 2
     or position('.' in split_part(v_email, '@', 2)) < 2 then
    raise exception using errcode = '22023', message = 'recipient_email_invalid';
  end if;
  if p_role not in ('manager', 'supervisor', 'storekeeper', 'accountant', 'engineer', 'viewer') then
    raise exception using errcode = '22023', message = 'invitation_role_invalid';
  end if;
  if p_expires_in_hours not between 1 and 168 then
    raise exception using errcode = '22023', message = 'invitation_expiry_must_be_1_to_168_hours';
  end if;
  if p_role in ('manager', 'accountant') and not private.is_project_custodian(p_project_id) then
    raise exception using errcode = '42501', message = 'custodian_required_for_protected_role_invite';
  end if;
  if coalesce(cardinality(p_permission_keys), 0) > 0 and not private.is_project_custodian(p_project_id) then
    raise exception using errcode = '42501', message = 'custodian_required_to_delegate_permissions';
  end if;
  if coalesce(cardinality(p_permission_keys), 0) > 0 and not (p_permission_keys <@ array[
    'reports.review', 'milestones.manage', 'materials.approve', 'materials.adjust',
    'finance.read', 'finance.approve', 'finance.advance', 'labor.pay.read',
    'documents.upload', 'exports.request', 'closeout.approve', 'governance.approve'
  ]::text[]) then
    raise exception using errcode = '22023', message = 'permission_key_invalid';
  end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'invite_project_member', p_project_id,
    jsonb_build_object('email', v_email, 'role', p_role, 'permission_keys', coalesce(p_permission_keys, '{}'::text[]), 'expires_in_hours', p_expires_in_hours)
  );
  if v_replay is not null then return v_replay; end if;

  -- Expired invitations no longer occupy the one-pending-invite slot for an email.
  for v_expired_invitation_id in
    update public.project_invitations
    set status = 'expired'
    where project_id = p_project_id and recipient_email = v_email
      and status = 'pending' and expires_at <= now()
    returning id
  loop
    perform private.write_audit_event(p_project_id, null, 'project.invitation_expired', 'project_invitation',
      v_expired_invitation_id, jsonb_build_object('expiration_detected_by', 'replacement_invite'));
  end loop;
  if exists (
    select 1 from public.project_invitations i
    where i.project_id = p_project_id and i.recipient_email = v_email
      and i.status = 'pending' and i.expires_at > now()
  ) then
    raise exception using errcode = '23505', message = 'invitation_already_pending';
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.project_invitations (
    project_id, recipient_email, role, permission_keys, token_hash, invited_by, expires_at
  ) values (
    p_project_id, v_email, p_role, coalesce(p_permission_keys, '{}'::text[]),
    extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'), auth.uid(), now() + make_interval(hours => p_expires_in_hours)
  ) returning id into v_invitation_id;
  perform private.write_audit_event(p_project_id, null, 'project.invitation_created', 'project_invitation', v_invitation_id,
    jsonb_build_object('role', p_role));
  v_result := jsonb_build_object(
    'invitation_id', v_invitation_id, 'invite_token', v_token,
    'expires_at', now() + make_interval(hours => p_expires_in_hours), 'delivery', 'manual_or_future_email_provider'
  );
  -- The bearer token is returned only in the first response, never copied into the
  -- durable idempotency table. A retry gets the safe response and must rotate the invite.
  perform private.complete_idempotent_operation(p_operation_id,
    (v_result - 'invite_token') || jsonb_build_object('invite_token_available', false));
  return v_result;
end;
$function$;

create or replace function public.revoke_project_invitation(p_project_id uuid, p_invitation_id uuid, p_reason text, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_invitation public.project_invitations%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'project.invite') then raise exception using errcode = '42501', message = 'project_invite_denied'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 3 and 500 then raise exception using errcode = '22023', message = 'invitation_revoke_reason_required'; end if;
  v_replay := private.begin_idempotent_operation(p_operation_id, 'revoke_project_invitation', p_project_id,
    jsonb_build_object('invitation_id', p_invitation_id, 'reason', btrim(p_reason)));
  if v_replay is not null then return v_replay; end if;
  select * into v_invitation from public.project_invitations i
  where i.id = p_invitation_id and i.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'invitation_not_found'; end if;
  if v_invitation.status <> 'pending' or v_invitation.expires_at <= now() then
    raise exception using errcode = '55000', message = 'invitation_not_revocable';
  end if;
  update public.project_invitations set status = 'revoked' where id = p_invitation_id;
  perform private.write_audit_event(p_project_id, null, 'project.invitation_revoked', 'project_invitation', p_invitation_id,
    jsonb_build_object('reason', btrim(p_reason)));
  v_result := jsonb_build_object('invitation_id', p_invitation_id, 'status', 'revoked');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.accept_project_invitation(p_token text, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_invitation public.project_invitations%rowtype;
  v_user_email text;
  v_membership_id uuid;
  v_hash bytea;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception using errcode = '28000', message = 'authentication_required'; end if;
  if length(coalesce(p_token, '')) <> 64 then raise exception using errcode = '22023', message = 'invitation_token_invalid'; end if;
  v_hash := extensions.digest(convert_to(lower(p_token), 'UTF8'), 'sha256');
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'accept_project_invitation', null,
    jsonb_build_object('token_hash', encode(v_hash, 'hex'))
  );
  if v_replay is not null then return v_replay; end if;

  select lower(u.email) into v_user_email from auth.users u
  where u.id = auth.uid() and u.email_confirmed_at is not null;
  if v_user_email is null then raise exception using errcode = '42501', message = 'verified_email_required'; end if;
  select * into v_invitation from public.project_invitations i where i.token_hash = v_hash for update;
  if not found then raise exception using errcode = 'P0002', message = 'invitation_not_found'; end if;
  if v_invitation.status <> 'pending' or v_invitation.expires_at <= now() then
    raise exception using errcode = '55000', message = 'invitation_expired_or_unavailable';
  end if;
  if v_invitation.recipient_email <> v_user_email then
    raise exception using errcode = '42501', message = 'invitation_recipient_mismatch';
  end if;
  if exists (select 1 from public.project_memberships pm where pm.project_id = v_invitation.project_id and pm.user_id = auth.uid() and pm.status = 'active') then
    raise exception using errcode = '23505', message = 'already_project_member';
  end if;

  insert into public.project_memberships (project_id, user_id, role, status, joined_at, revoked_at)
  values (v_invitation.project_id, auth.uid(), v_invitation.role, 'active', now(), null)
  on conflict (project_id, user_id) do update
    set role = excluded.role, status = 'active', joined_at = now(), revoked_at = null
    where public.project_memberships.status = 'revoked'
  returning id into v_membership_id;
  if v_membership_id is null then raise exception using errcode = '23505', message = 'membership_already_exists'; end if;

  update public.project_invitations
  set status = 'accepted', accepted_by = auth.uid(), accepted_at = now()
  where id = v_invitation.id;
  insert into public.project_permission_grants (project_id, user_id, permission_key, granted_by, reason)
  select v_invitation.project_id, auth.uid(), key, v_invitation.invited_by, 'Delegated by project custodian at invitation'
  from unnest(v_invitation.permission_keys) as key
  on conflict (project_id, user_id, permission_key) do update set revoked_at = null, granted_by = excluded.granted_by, granted_at = now(), reason = excluded.reason;
  insert into public.project_membership_events (project_id, membership_id, actor_id, event_type, details)
  values (v_invitation.project_id, v_membership_id, auth.uid(), 'joined', jsonb_build_object('role', v_invitation.role));
  perform private.write_audit_event(v_invitation.project_id, null, 'project.invitation_accepted', 'project_membership', v_membership_id,
    jsonb_build_object('role', v_invitation.role));
  perform private.notify_project_members(v_invitation.project_id, 'member.joined', 'A project member accepted an invitation.', 'project_membership', v_membership_id, auth.uid());
  v_result := jsonb_build_object('project_id', v_invitation.project_id, 'membership_id', v_membership_id, 'role', v_invitation.role, 'status', 'active');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.revoke_project_member(
  p_project_id uuid,
  p_membership_id uuid,
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
  v_target public.project_memberships%rowtype;
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'project.invite') then
    raise exception using errcode = '42501', message = 'membership_change_denied';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception using errcode = '22023', message = 'membership_change_reason_required';
  end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'revoke_project_member', p_project_id,
    jsonb_build_object('membership_id', p_membership_id, 'reason', btrim(p_reason))
  );
  if v_replay is not null then return v_replay; end if;
  select * into v_target from public.project_memberships pm
  where pm.id = p_membership_id and pm.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'membership_not_found'; end if;
  if v_target.status <> 'active' then raise exception using errcode = '55000', message = 'membership_not_active'; end if;
  if v_target.role = 'custodian' then
    raise exception using errcode = '55000', message = 'custody_transfer_required';
  end if;
  if not private.is_project_custodian(p_project_id) and v_target.role in ('manager', 'accountant') then
    raise exception using errcode = '42501', message = 'custodian_required_for_protected_membership';
  end if;
  update public.project_memberships set status = 'revoked', revoked_at = now() where id = p_membership_id;
  update public.project_permission_grants set revoked_at = now()
  where project_id = p_project_id and user_id = v_target.user_id and revoked_at is null;
  update public.project_invitations set status = 'revoked'
  where project_id = p_project_id and recipient_email = (select lower(u.email) from auth.users u where u.id = v_target.user_id) and status = 'pending';
  insert into public.project_membership_events (project_id, membership_id, actor_id, event_type, details)
  values (p_project_id, p_membership_id, auth.uid(), 'removed', jsonb_build_object('reason', btrim(p_reason), 'role', v_target.role));
  perform private.write_audit_event(p_project_id, null, 'project.member_revoked', 'project_membership', p_membership_id,
    jsonb_build_object('reason', btrim(p_reason), 'role', v_target.role));
  v_result := jsonb_build_object('membership_id', p_membership_id, 'status', 'revoked');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.grant_project_permission(
  p_project_id uuid,
  p_user_id uuid,
  p_permission_key text,
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
  v_grant_id uuid;
  v_membership_id uuid;
  v_result jsonb;
begin
  if not private.is_project_custodian(p_project_id) then
    raise exception using errcode = '42501', message = 'custodian_authority_required';
  end if;
  if p_user_id = auth.uid() then raise exception using errcode = '42501', message = 'cannot_delegate_privilege_to_self'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception using errcode = '22023', message = 'permission_reason_required';
  end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'grant_project_permission', p_project_id,
    jsonb_build_object('user_id', p_user_id, 'permission_key', p_permission_key, 'reason', btrim(p_reason))
  );
  if v_replay is not null then return v_replay; end if;
  select pm.id into v_membership_id from public.project_memberships pm
  where pm.project_id = p_project_id and pm.user_id = p_user_id and pm.status = 'active';
  if v_membership_id is null then raise exception using errcode = 'P0002', message = 'active_project_member_required'; end if;
  insert into public.project_permission_grants (project_id, user_id, permission_key, granted_by, reason)
  values (p_project_id, p_user_id, p_permission_key, auth.uid(), btrim(p_reason))
  on conflict (project_id, user_id, permission_key) do update
    set granted_by = excluded.granted_by, reason = excluded.reason, granted_at = now(), revoked_at = null
  returning id into v_grant_id;
  insert into public.project_membership_events (project_id, membership_id, actor_id, event_type, details)
  values (p_project_id, v_membership_id, auth.uid(), 'permission_granted', jsonb_build_object('permission_key', p_permission_key));
  perform private.write_audit_event(p_project_id, null, 'project.permission_granted', 'project_permission_grant', v_grant_id,
    jsonb_build_object('permission_key', p_permission_key, 'user_id', p_user_id));
  v_result := jsonb_build_object('grant_id', v_grant_id, 'permission_key', p_permission_key, 'user_id', p_user_id);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.nominate_recovery_route(p_project_id uuid, p_nominee_user_id uuid, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_route_id uuid;
  v_workspace_id uuid;
  v_result jsonb;
begin
  if not private.is_project_custodian(p_project_id) then raise exception using errcode = '42501', message = 'custodian_authority_required'; end if;
  if p_nominee_user_id = auth.uid() then raise exception using errcode = '22023', message = 'independent_recovery_nominee_required'; end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'nominate_recovery_route', p_project_id, jsonb_build_object('nominee_user_id', p_nominee_user_id)
  );
  if v_replay is not null then return v_replay; end if;
  if not exists (select 1 from public.project_memberships pm where pm.project_id = p_project_id and pm.user_id = p_nominee_user_id and pm.status = 'active') then
    raise exception using errcode = '23514', message = 'recovery_nominee_must_be_active_project_member';
  end if;
  insert into public.project_recovery_routes (project_id, nominee_user_id, nominated_by, status)
  values (p_project_id, p_nominee_user_id, auth.uid(), 'pending')
  on conflict (project_id, nominee_user_id) do update set
    nominated_by = excluded.nominated_by, status = 'pending', accepted_at = null, verified_at = null, created_at = now()
  returning id into v_route_id;
  select p.workspace_id into v_workspace_id from public.projects p where p.id = p_project_id;
  perform private.write_audit_event(p_project_id, v_workspace_id, 'governance.recovery_route_nominated', 'recovery_route', v_route_id, '{}'::jsonb);
  perform private.enqueue_outbox_event('recovery_route.nominated', p_project_id, p_nominee_user_id, jsonb_build_object('route_id', v_route_id));
  v_result := jsonb_build_object('recovery_route_id', v_route_id, 'status', 'pending');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.accept_recovery_route(p_project_id uuid, p_route_id uuid, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_route public.project_recovery_routes%rowtype;
  v_result jsonb;
begin
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'accept_recovery_route', p_project_id, jsonb_build_object('recovery_route_id', p_route_id)
  );
  if v_replay is not null then return v_replay; end if;
  select * into v_route from public.project_recovery_routes rr
  where rr.id = p_route_id and rr.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'recovery_route_not_found'; end if;
  if v_route.nominee_user_id <> auth.uid() then raise exception using errcode = '42501', message = 'recovery_nominee_only'; end if;
  if v_route.status <> 'pending' then raise exception using errcode = '55000', message = 'recovery_route_not_pending'; end if;
  if not exists (select 1 from public.project_memberships pm where pm.project_id = p_project_id and pm.user_id = auth.uid() and pm.status = 'active') then
    raise exception using errcode = '42501', message = 'active_recovery_nominee_membership_required';
  end if;
  update public.project_recovery_routes set status = 'verified', accepted_at = now(), verified_at = now() where id = p_route_id;
  perform private.write_audit_event(p_project_id, null, 'governance.recovery_route_accepted', 'recovery_route', p_route_id, '{}'::jsonb);
  v_result := jsonb_build_object('recovery_route_id', p_route_id, 'status', 'verified');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.open_recovery_case(
  p_project_id uuid,
  p_proposed_successor_id uuid,
  p_reason text,
  p_contact_attempts jsonb,
  p_evidence_document_ids uuid[],
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
  v_result jsonb;
begin
  if not private.has_project_permission(p_project_id, 'project.read') then raise exception using errcode = '42501', message = 'project_access_denied'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 10 and 2000 then raise exception using errcode = '22023', message = 'recovery_reason_required'; end if;
  if jsonb_typeof(coalesce(p_contact_attempts, '[]'::jsonb)) <> 'array' then raise exception using errcode = '22023', message = 'contact_attempts_must_be_array'; end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'open_recovery_case', p_project_id,
    jsonb_build_object('proposed_successor_id', p_proposed_successor_id, 'reason', btrim(p_reason),
      'contact_attempts', coalesce(p_contact_attempts, '[]'::jsonb), 'evidence_document_ids', coalesce(p_evidence_document_ids, '{}'::uuid[]))
  );
  if v_replay is not null then return v_replay; end if;
  if exists (
    select 1
    from unnest(coalesce(p_evidence_document_ids, '{}'::uuid[])) as evidence(document_id)
    left join public.documents d on d.id = evidence.document_id
    where d.id is null or d.project_id <> p_project_id or d.status <> 'available'
  ) then
    raise exception using errcode = '23514', message = 'recovery_evidence_must_be_available_in_same_project';
  end if;
  insert into public.recovery_cases (project_id, claimant_id, proposed_successor_id, reason, contact_attempts, evidence_document_ids)
  values (p_project_id, auth.uid(), p_proposed_successor_id, btrim(p_reason), coalesce(p_contact_attempts, '[]'::jsonb), coalesce(p_evidence_document_ids, '{}'::uuid[]))
  returning id into v_case_id;
  insert into public.recovery_case_events (project_id, recovery_case_id, actor_id, event_type, details)
  values (p_project_id, v_case_id, auth.uid(), 'opened', jsonb_build_object('proposed_successor_id', p_proposed_successor_id));
  perform private.write_audit_event(p_project_id, null, 'governance.recovery_case_opened', 'recovery_case', v_case_id, '{}'::jsonb);
  perform private.notify_project_members(p_project_id, 'governance.recovery_case_opened', 'A project continuity case was opened for review.', 'recovery_case', v_case_id, auth.uid());
  v_result := jsonb_build_object('recovery_case_id', v_case_id, 'status', 'pending_review', 'custody_changed', false);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.propose_project_transfer(
  p_project_id uuid,
  p_transfer_type text,
  p_from_user_id uuid,
  p_recipient_user_id uuid,
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
  v_version integer;
  v_proposal_id uuid;
  v_result jsonb;
begin
  if p_transfer_type not in ('manager_handover', 'custody_transfer') then raise exception using errcode = '22023', message = 'transfer_type_invalid'; end if;
  if p_transfer_type = 'custody_transfer' and (not private.is_project_custodian(p_project_id) or p_from_user_id <> auth.uid()) then
    raise exception using errcode = '42501', message = 'custodian_required_to_propose_custody_transfer';
  end if;
  if p_transfer_type = 'manager_handover' and not private.is_project_custodian(p_project_id) then
    raise exception using errcode = '42501', message = 'custodian_required_to_propose_manager_handover';
  end if;
  if p_recipient_user_id = p_from_user_id then raise exception using errcode = '22023', message = 'transfer_recipient_must_differ'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 3 and 1000 then raise exception using errcode = '22023', message = 'transfer_reason_required'; end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'propose_project_transfer', p_project_id,
    jsonb_build_object('transfer_type', p_transfer_type, 'from_user_id', p_from_user_id, 'recipient_user_id', p_recipient_user_id, 'reason', btrim(p_reason))
  );
  if v_replay is not null then return v_replay; end if;
  if not exists (select 1 from public.project_memberships pm where pm.project_id = p_project_id and pm.user_id = p_from_user_id and pm.status = 'active'
    and ((p_transfer_type = 'manager_handover' and pm.role = 'manager') or (p_transfer_type = 'custody_transfer' and pm.role = 'custodian'))) then
    raise exception using errcode = '23514', message = 'transfer_source_role_mismatch';
  end if;
  if not exists (select 1 from public.project_memberships pm where pm.project_id = p_project_id and pm.user_id = p_recipient_user_id and pm.status = 'active') then
    raise exception using errcode = '23514', message = 'transfer_recipient_must_be_active_member';
  end if;
  if p_transfer_type = 'manager_handover' and exists (
    select 1 from public.project_memberships pm where pm.project_id = p_project_id and pm.user_id = p_recipient_user_id
      and pm.status = 'active' and pm.role = 'custodian'
  ) then raise exception using errcode = '23514', message = 'custodian_cannot_receive_manager_handover'; end if;
  select coalesce(max(gv.version), 0) into v_version from public.project_governance_versions gv where gv.project_id = p_project_id;
  insert into public.transfer_proposals (
    project_id, transfer_type, from_user_id, recipient_user_id, governance_version, reason, created_by
  ) values (
    p_project_id, p_transfer_type, p_from_user_id, p_recipient_user_id, v_version, btrim(p_reason), auth.uid()
  ) returning id into v_proposal_id;
  perform private.write_audit_event(p_project_id, null, 'governance.transfer_proposed', 'transfer_proposal', v_proposal_id,
    jsonb_build_object('transfer_type', p_transfer_type, 'governance_version', v_version));
  perform private.enqueue_outbox_event('transfer.proposed', p_project_id, p_recipient_user_id, jsonb_build_object('proposal_id', v_proposal_id));
  v_result := jsonb_build_object('transfer_proposal_id', v_proposal_id, 'status', 'pending', 'governance_version', v_version);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.accept_project_transfer(p_project_id uuid, p_proposal_id uuid, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_proposal public.transfer_proposals%rowtype;
  v_result jsonb;
begin
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'accept_project_transfer', p_project_id, jsonb_build_object('proposal_id', p_proposal_id)
  );
  if v_replay is not null then return v_replay; end if;
  select * into v_proposal from public.transfer_proposals tp
  where tp.id = p_proposal_id and tp.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'transfer_proposal_not_found'; end if;
  if v_proposal.recipient_user_id <> auth.uid() then raise exception using errcode = '42501', message = 'transfer_recipient_only'; end if;
  if v_proposal.status <> 'pending' then raise exception using errcode = '55000', message = 'transfer_proposal_not_pending'; end if;
  update public.transfer_proposals set status = 'accepted', accepted_at = now() where id = p_proposal_id;
  perform private.write_audit_event(p_project_id, null, 'governance.transfer_accepted', 'transfer_proposal', p_proposal_id, '{}'::jsonb);
  v_result := jsonb_build_object('transfer_proposal_id', p_proposal_id, 'status', 'accepted');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.review_project_transfer(
  p_project_id uuid,
  p_proposal_id uuid,
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
  v_proposal public.transfer_proposals%rowtype;
  v_result jsonb;
begin
  if p_decision not in ('approved', 'rejected') then raise exception using errcode = '22023', message = 'transfer_decision_invalid'; end if;
  if not (private.is_project_custodian(p_project_id) or private.has_project_permission(p_project_id, 'governance.approve')) then
    raise exception using errcode = '42501', message = 'governance_approval_required';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception using errcode = '22023', message = 'transfer_review_reason_required'; end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'review_project_transfer', p_project_id,
    jsonb_build_object('proposal_id', p_proposal_id, 'decision', p_decision, 'reason', btrim(p_reason))
  );
  if v_replay is not null then return v_replay; end if;
  select * into v_proposal from public.transfer_proposals tp
  where tp.id = p_proposal_id and tp.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'transfer_proposal_not_found'; end if;
  if auth.uid() in (v_proposal.created_by, v_proposal.recipient_user_id) then
    raise exception using errcode = '42501', message = 'independent_transfer_review_required';
  end if;
  if v_proposal.status <> 'accepted' then raise exception using errcode = '55000', message = 'recipient_acceptance_required'; end if;
  insert into public.transfer_approvals (project_id, transfer_proposal_id, governance_version, approver_id, decision, reason)
  values (p_project_id, p_proposal_id, v_proposal.governance_version, auth.uid(), p_decision, btrim(p_reason))
  on conflict (transfer_proposal_id, approver_id) do update
    set governance_version = excluded.governance_version, decision = excluded.decision, reason = excluded.reason, created_at = now();
  if p_decision = 'rejected' then update public.transfer_proposals set status = 'rejected', decided_at = now() where id = p_proposal_id; end if;
  perform private.write_audit_event(p_project_id, null, 'governance.transfer_reviewed', 'transfer_proposal', p_proposal_id,
    jsonb_build_object('decision', p_decision, 'governance_version', v_proposal.governance_version));
  v_result := jsonb_build_object('transfer_proposal_id', p_proposal_id, 'decision', p_decision, 'status', case when p_decision = 'rejected' then 'rejected' else 'approved' end);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.apply_project_transfer(p_project_id uuid, p_proposal_id uuid, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_proposal public.transfer_proposals%rowtype;
  v_version integer;
  v_old_membership uuid;
  v_new_membership uuid;
  v_workspace_id uuid;
  v_result jsonb;
begin
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'apply_project_transfer', p_project_id, jsonb_build_object('proposal_id', p_proposal_id)
  );
  if v_replay is not null then return v_replay; end if;
  if not (private.is_project_custodian(p_project_id) or private.has_project_permission(p_project_id, 'governance.approve')) then
    raise exception using errcode = '42501', message = 'governance_apply_permission_required';
  end if;
  select p.workspace_id into v_workspace_id from public.projects p where p.id = p_project_id for update;
  if v_workspace_id is null then raise exception using errcode = 'P0002', message = 'project_not_found'; end if;
  select * into v_proposal from public.transfer_proposals tp where tp.id = p_proposal_id and tp.project_id = p_project_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'transfer_proposal_not_found'; end if;
  if v_proposal.status <> 'accepted' then raise exception using errcode = '55000', message = 'accepted_transfer_required'; end if;
  if v_proposal.transfer_type = 'custody_transfer' then perform private.require_policy_gate('custody_transfer'); end if;
  select coalesce(max(gv.version), 0) into v_version from public.project_governance_versions gv where gv.project_id = p_project_id;
  if v_version <> v_proposal.governance_version then raise exception using errcode = '40001', message = 'governance_version_conflict'; end if;
  if not exists (
    select 1 from public.transfer_approvals ta
    where ta.transfer_proposal_id = p_proposal_id and ta.governance_version = v_version
      and ta.decision = 'approved' and ta.approver_id <> v_proposal.created_by and ta.approver_id <> v_proposal.recipient_user_id
  ) then raise exception using errcode = '42501', message = 'independent_transfer_approval_required'; end if;

  select pm.id into v_old_membership from public.project_memberships pm
  where pm.project_id = p_project_id and pm.user_id = v_proposal.from_user_id and pm.status = 'active' for update;
  select pm.id into v_new_membership from public.project_memberships pm
  where pm.project_id = p_project_id and pm.user_id = v_proposal.recipient_user_id and pm.status = 'active' for update;
  if v_old_membership is null or v_new_membership is null then raise exception using errcode = '40001', message = 'transfer_membership_changed'; end if;
  if v_proposal.transfer_type = 'manager_handover' and exists (
    select 1 from public.project_memberships pm where pm.id = v_new_membership and pm.role = 'custodian'
  ) then raise exception using errcode = '23514', message = 'custodian_cannot_receive_manager_handover'; end if;

  if v_proposal.transfer_type = 'custody_transfer' then
    update public.project_memberships set role = 'manager' where id = v_old_membership and role = 'custodian';
    update public.project_memberships set role = 'custodian' where id = v_new_membership;
  else
    if not exists (select 1 from public.project_memberships pm where pm.id = v_old_membership and pm.role = 'manager') then
      raise exception using errcode = '40001', message = 'manager_membership_changed';
    end if;
    update public.project_memberships set role = 'manager' where id = v_new_membership;
    update public.project_memberships set status = 'revoked', revoked_at = now() where id = v_old_membership;
  end if;
  insert into public.project_membership_events (project_id, membership_id, actor_id, event_type, details)
  values
    (p_project_id, v_old_membership, auth.uid(), 'role_changed', jsonb_build_object('transfer_type', v_proposal.transfer_type, 'to_role', case when v_proposal.transfer_type = 'custody_transfer' then 'manager' else 'revoked' end)),
    (p_project_id, v_new_membership, auth.uid(), 'role_changed', jsonb_build_object('transfer_type', v_proposal.transfer_type, 'to_role', case when v_proposal.transfer_type = 'custody_transfer' then 'custodian' else 'manager' end));
  update public.project_governance_versions set status = 'superseded' where project_id = p_project_id and version = v_version;
  insert into public.project_governance_versions (project_id, version, policy_snapshot, policy_hash, status, created_by, approved_by, approved_at)
  select p_project_id, v_version + 1, gv.policy_snapshot, gv.policy_hash, 'approved', auth.uid(), auth.uid(), now()
  from public.project_governance_versions gv where gv.project_id = p_project_id and gv.version = v_version;
  update public.transfer_proposals set status = 'applied', applied_at = now(), decided_at = coalesce(decided_at, now()) where id = p_proposal_id;
  update public.projects set revision = revision + 1 where id = p_project_id;
  perform private.write_audit_event(p_project_id, v_workspace_id, 'governance.transfer_applied', 'transfer_proposal', p_proposal_id,
    jsonb_build_object('transfer_type', v_proposal.transfer_type, 'governance_version', v_version + 1));
  v_result := jsonb_build_object('transfer_proposal_id', p_proposal_id, 'status', 'applied', 'governance_version', v_version + 1);
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;

create or replace function public.request_account_deletion(p_reason text, p_operation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_replay jsonb;
  v_request_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception using errcode = '28000', message = 'authentication_required'; end if;
  v_replay := private.begin_idempotent_operation(
    p_operation_id, 'request_account_deletion', null, jsonb_build_object('reason', nullif(btrim(p_reason), ''))
  );
  if v_replay is not null then return v_replay; end if;
  insert into public.account_deletion_requests (user_id, reason)
  values (auth.uid(), nullif(btrim(p_reason), '')) returning id into v_request_id;
  perform private.write_audit_event(null, null, 'account.deletion_requested', 'account', auth.uid(), jsonb_build_object('request_id', v_request_id));
  v_result := jsonb_build_object('deletion_request_id', v_request_id, 'status', 'requested', 'execution', 'pending_policy_and_responsibility_review');
  perform private.complete_idempotent_operation(p_operation_id, v_result);
  return v_result;
end;
$function$;
