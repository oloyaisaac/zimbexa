-- Secure all client-visible data through RLS. Writes to business records are performed by reviewed RPCs only.

alter table public.profiles enable row level security;
alter table public.workspaces enable row level security;
alter table public.workspace_memberships enable row level security;
alter table public.projects enable row level security;
alter table public.project_memberships enable row level security;
alter table public.project_permission_grants enable row level security;
alter table public.project_membership_events enable row level security;
alter table public.project_invitations enable row level security;
alter table public.project_governance_versions enable row level security;
alter table public.project_recovery_routes enable row level security;
alter table public.project_status_events enable row level security;
alter table public.transfer_proposals enable row level security;
alter table public.recovery_cases enable row level security;
alter table public.closeout_cases enable row level security;
alter table public.account_deletion_requests enable row level security;
alter table public.export_jobs enable row level security;
alter table public.support_cases enable row level security;
alter table public.transfer_approvals enable row level security;
alter table public.recovery_case_events enable row level security;
alter table public.closeout_acknowledgements enable row level security;
alter table public.export_access_log enable row level security;
alter table public.support_case_events enable row level security;
alter table public.support_access_grants enable row level security;
alter table public.app_notifications enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.audit_events enable row level security;
alter table public.outbox_events enable row level security;
alter table public.daily_reports enable row level security;
alter table public.report_revisions enable row level security;
alter table public.report_reviews enable row level security;
alter table public.milestones enable row level security;
alter table public.milestone_history enable row level security;
alter table public.materials enable row level security;
alter table public.stock_locations enable row level security;
alter table public.stock_balances enable row level security;
alter table public.material_requests enable row level security;
alter table public.material_request_lines enable row level security;
alter table public.material_request_revisions enable row level security;
alter table public.material_request_reviews enable row level security;
alter table public.stock_counts enable row level security;
alter table public.stock_movements enable row level security;
alter table public.budget_versions enable row level security;
alter table public.budget_lines enable row level security;
alter table public.budget_reviews enable row level security;
alter table public.cost_records enable row level security;
alter table public.cost_revisions enable row level security;
alter table public.cost_reviews enable row level security;
alter table public.cost_adjustments enable row level security;
alter table public.cash_advances enable row level security;
alter table public.advance_allocations enable row level security;
alter table public.cash_returns enable row level security;
alter table public.reported_payments enable row level security;
alter table public.workers enable row level security;
alter table public.labor_entries enable row level security;
alter table public.labor_entry_revisions enable row level security;
alter table public.labor_entry_reviews enable row level security;
alter table public.labor_cost_links enable row level security;
alter table public.documents enable row level security;
alter table public.document_versions enable row level security;
alter table public.evidence_links enable row level security;

-- Profile directory: users see themselves and people sharing an active project; no contact details are copied here.
create policy profiles_read_self_or_project on public.profiles
  for select to authenticated
  using (
    id = auth.uid()
    or exists (
      select 1
      from public.project_memberships mine
      join public.project_memberships theirs on theirs.project_id = mine.project_id
      where mine.user_id = auth.uid() and mine.status = 'active'
        and theirs.user_id = profiles.id and theirs.status = 'active'
        and private.has_project_permission(mine.project_id, 'project.read')
    )
  );
create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy workspaces_read_member on public.workspaces
  for select to authenticated using (private.has_workspace_access(id));
create policy workspace_memberships_read_scope on public.workspace_memberships
  for select to authenticated
  using (user_id = auth.uid() or private.has_workspace_admin(workspace_id));

create policy projects_read_member on public.projects
  for select to authenticated using (private.has_project_permission(id, 'project.read'));
create policy project_memberships_read_member on public.project_memberships
  for select to authenticated
  using (private.has_project_permission(project_id, 'project.read')
    and (status = 'active' or private.has_project_permission(project_id, 'project.manage_members')));
create policy project_permissions_read_custodian on public.project_permission_grants
  for select to authenticated using (private.is_project_custodian(project_id));
create policy project_membership_events_read_member on public.project_membership_events
  for select to authenticated using (private.has_project_permission(project_id, 'project.read'));
-- Invitations deliberately have no authenticated SELECT policy: token hashes and invitee addresses stay server-side.
create policy project_governance_versions_read_member on public.project_governance_versions
  for select to authenticated using (private.has_project_permission(project_id, 'project.read'));
create policy project_recovery_routes_read_parties on public.project_recovery_routes
  for select to authenticated using (nominee_user_id = auth.uid() or private.is_project_custodian(project_id));
create policy project_status_events_read_member on public.project_status_events
  for select to authenticated using (private.has_project_permission(project_id, 'project.read'));
create policy transfer_proposals_read_parties on public.transfer_proposals
  for select to authenticated
  using (created_by = auth.uid() or recipient_user_id = auth.uid() or private.is_project_custodian(project_id)
    or private.has_project_permission(project_id, 'governance.approve'));
create policy transfer_approvals_read_parties on public.transfer_approvals
  for select to authenticated
  using (approver_id = auth.uid() or private.is_project_custodian(project_id)
    or private.has_project_permission(project_id, 'governance.approve'));
create policy recovery_cases_read_parties on public.recovery_cases
  for select to authenticated
  using (claimant_id = auth.uid() or private.is_project_custodian(project_id)
    or private.has_project_permission(project_id, 'governance.approve'));
create policy recovery_case_events_read_parties on public.recovery_case_events
  for select to authenticated
  using (private.is_project_custodian(project_id) or private.has_project_permission(project_id, 'governance.approve')
    or exists (select 1 from public.recovery_cases rc where rc.id = recovery_case_id and rc.claimant_id = auth.uid()));
create policy closeout_cases_read_member on public.closeout_cases
  for select to authenticated using (private.has_project_permission(project_id, 'project.read'));
create policy closeout_acknowledgements_read_member on public.closeout_acknowledgements
  for select to authenticated using (private.has_project_permission(project_id, 'project.read'));
create policy account_deletion_request_read_self on public.account_deletion_requests
  for select to authenticated using (user_id = auth.uid());
create policy export_jobs_read_requester on public.export_jobs
  for select to authenticated using (requested_by = auth.uid() and private.has_project_permission(project_id, 'project.read'));
create policy export_access_log_read_actor_or_custodian on public.export_access_log
  for select to authenticated using (accessed_by = auth.uid() or private.is_project_custodian(project_id));
create policy support_cases_read_creator on public.support_cases
  for select to authenticated using (created_by = auth.uid());
create policy support_case_events_read_creator on public.support_case_events
  for select to authenticated
  using (exists (select 1 from public.support_cases sc where sc.id = support_case_id and sc.created_by = auth.uid()));
-- Sensitive support grants are service-only; ordinary support cases do not grant account impersonation.

create policy notifications_read_recipient on public.app_notifications
  for select to authenticated using (recipient_user_id = auth.uid());
create policy notification_preferences_read_self on public.notification_preferences
  for select to authenticated using (user_id = auth.uid());
create policy audit_events_read_project_admin on public.audit_events
  for select to authenticated
  using (
    (project_id is not null and private.has_project_permission(project_id, 'audit.read'))
    or (workspace_id is not null and private.has_workspace_admin(workspace_id))
  );
-- Outbox, support grants, and invitation rows have no authenticated read policy.

create policy daily_reports_read_member on public.daily_reports
  for select to authenticated using (private.has_project_permission(project_id, 'reports.read'));
create policy report_revisions_read_member on public.report_revisions
  for select to authenticated using (private.has_project_permission(project_id, 'reports.read'));
create policy report_reviews_read_member on public.report_reviews
  for select to authenticated using (private.has_project_permission(project_id, 'reports.read'));
create policy milestones_read_member on public.milestones
  for select to authenticated using (private.has_project_permission(project_id, 'project.read'));
create policy milestone_history_read_member on public.milestone_history
  for select to authenticated using (private.has_project_permission(project_id, 'project.read'));

create policy materials_read_member on public.materials
  for select to authenticated using (private.has_project_permission(project_id, 'materials.read'));
create policy stock_locations_read_member on public.stock_locations
  for select to authenticated using (private.has_project_permission(project_id, 'materials.read'));
create policy stock_balances_read_member on public.stock_balances
  for select to authenticated using (private.has_project_permission(project_id, 'materials.read'));
create policy material_requests_read_member on public.material_requests
  for select to authenticated using (private.has_project_permission(project_id, 'materials.read'));
create policy material_request_lines_read_member on public.material_request_lines
  for select to authenticated using (private.has_project_permission(project_id, 'materials.read'));
create policy material_request_revisions_read_member on public.material_request_revisions
  for select to authenticated using (private.has_project_permission(project_id, 'materials.read'));
create policy material_request_reviews_read_member on public.material_request_reviews
  for select to authenticated using (private.has_project_permission(project_id, 'materials.read'));
create policy stock_counts_read_member on public.stock_counts
  for select to authenticated using (private.has_project_permission(project_id, 'materials.read'));
create policy stock_movements_read_member on public.stock_movements
  for select to authenticated using (private.has_project_permission(project_id, 'materials.read'));

create policy budget_versions_read_finance on public.budget_versions
  for select to authenticated using (private.has_project_permission(project_id, 'finance.read'));
create policy budget_lines_read_finance on public.budget_lines
  for select to authenticated using (private.has_project_permission(project_id, 'finance.read'));
create policy budget_reviews_read_finance on public.budget_reviews
  for select to authenticated using (private.has_project_permission(project_id, 'finance.read'));
create policy cost_records_read_finance on public.cost_records
  for select to authenticated using (private.has_project_permission(project_id, 'finance.read'));
create policy cost_revisions_read_finance on public.cost_revisions
  for select to authenticated using (private.has_project_permission(project_id, 'finance.read'));
create policy cost_reviews_read_finance on public.cost_reviews
  for select to authenticated using (private.has_project_permission(project_id, 'finance.read'));
create policy cost_adjustments_read_finance on public.cost_adjustments
  for select to authenticated using (private.has_project_permission(project_id, 'finance.read'));
create policy cash_advances_read_finance on public.cash_advances
  for select to authenticated using (private.has_project_permission(project_id, 'finance.read'));
create policy advance_allocations_read_finance on public.advance_allocations
  for select to authenticated using (private.has_project_permission(project_id, 'finance.read'));
create policy cash_returns_read_finance on public.cash_returns
  for select to authenticated using (private.has_project_permission(project_id, 'finance.read'));
create policy reported_payments_read_finance on public.reported_payments
  for select to authenticated using (private.has_project_permission(project_id, 'finance.read'));

create policy workers_read_labor on public.workers
  for select to authenticated using (private.has_project_permission(project_id, 'labor.read'));
create policy labor_entries_read_labor on public.labor_entries
  for select to authenticated using (private.has_project_permission(project_id, 'labor.read'));
create policy labor_entry_revisions_read_labor on public.labor_entry_revisions
  for select to authenticated using (private.has_project_permission(project_id, 'labor.read'));
create policy labor_entry_reviews_read_labor on public.labor_entry_reviews
  for select to authenticated using (private.has_project_permission(project_id, 'labor.read'));
create policy labor_cost_links_read_finance on public.labor_cost_links
  for select to authenticated using (private.has_project_permission(project_id, 'finance.read') and private.has_project_permission(project_id, 'labor.pay.read'));

create policy documents_read_authorized on public.documents
  for select to authenticated
  using (private.has_project_permission(project_id, 'documents.read') and (status = 'available' or uploaded_by = auth.uid()));
create policy document_versions_read_authorized on public.document_versions
  for select to authenticated
  using (private.has_project_permission(project_id, 'documents.read') and exists (
    select 1 from public.documents d where d.id = document_id and d.status = 'available'
  ));
create policy evidence_links_read_authorized on public.evidence_links
  for select to authenticated
  using (private.has_project_permission(project_id, 'documents.read') and exists (
    select 1 from public.documents d where d.id = document_id and d.status = 'available'
  ));

-- Remove any default Supabase public-schema table grants, then allow scoped reads only.
revoke all on table
  public.profiles, public.workspaces, public.workspace_memberships, public.projects, public.project_memberships,
  public.project_permission_grants, public.project_membership_events, public.project_invitations,
  public.project_governance_versions, public.project_recovery_routes, public.project_status_events,
  public.transfer_proposals, public.recovery_cases, public.closeout_cases, public.account_deletion_requests,
  public.export_jobs, public.support_cases, public.transfer_approvals, public.recovery_case_events,
  public.closeout_acknowledgements, public.export_access_log, public.support_case_events, public.support_access_grants,
  public.app_notifications, public.notification_preferences, public.audit_events, public.outbox_events,
  public.daily_reports, public.report_revisions, public.report_reviews, public.milestones, public.milestone_history,
  public.materials, public.stock_locations, public.stock_balances, public.material_requests, public.material_request_lines,
  public.material_request_revisions, public.material_request_reviews, public.stock_counts, public.stock_movements,
  public.budget_versions, public.budget_lines, public.budget_reviews, public.cost_records, public.cost_revisions,
  public.cost_reviews, public.cost_adjustments, public.cash_advances, public.advance_allocations, public.cash_returns,
  public.reported_payments, public.workers, public.labor_entries, public.labor_entry_revisions, public.labor_entry_reviews, public.labor_cost_links,
  public.documents, public.document_versions, public.evidence_links
from public, anon, authenticated;

grant select on all tables in schema public to authenticated;
grant update (display_name, preferred_locale) on public.profiles to authenticated;
grant all on all tables in schema public to service_role;
revoke all on table private.policy_gates from service_role;
grant select on table private.policy_gates to service_role;
grant select on table private.policy_gate_events to service_role;
grant select, insert, update, delete on table private.idempotency_records to service_role;
revoke all on public.project_invitations from authenticated;
grant select on public.project_invitation_summaries to authenticated;
grant select on public.project_financial_summary, public.cash_advance_summary,
  public.project_progress_summary, public.project_stock_summary to authenticated;

alter default privileges in schema public revoke all on tables from anon, authenticated, service_role;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated, service_role;
alter default privileges in schema private revoke execute on functions from public, anon, authenticated, service_role;

create policy private_idempotency_is_service_only on private.idempotency_records
  for all to service_role using (true) with check (true);
alter table private.idempotency_records enable row level security;

-- No untrusted role gets implicit EXECUTE on SECURITY DEFINER functions.
revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated, service_role;

grant execute on function private.has_workspace_access(uuid) to authenticated;
grant execute on function private.has_workspace_admin(uuid) to authenticated;
grant execute on function private.has_project_permission(uuid, text) to authenticated;
grant execute on function private.is_project_custodian(uuid) to authenticated;
grant execute on function private.can_upload_storage_object(text, uuid) to authenticated;
grant execute on function private.can_read_storage_object(text) to authenticated;
grant execute on function private.set_policy_gate(text, text, text, text, uuid) to service_role;

grant execute on function public.create_workspace(text, text, uuid) to authenticated, service_role;
grant execute on function public.create_project(uuid, text, text, text, text, text, date, uuid) to authenticated, service_role;
grant execute on function public.update_project_details(uuid, integer, text, text, text, text, text, date, uuid) to authenticated, service_role;
grant execute on function public.activate_project(uuid, integer, uuid) to authenticated, service_role;
grant execute on function public.pause_project(uuid, integer, text, uuid) to authenticated, service_role;
grant execute on function public.invite_project_member(uuid, text, text, text[], integer, uuid) to authenticated, service_role;
grant execute on function public.revoke_project_invitation(uuid, uuid, text, uuid) to authenticated, service_role;
grant execute on function public.accept_project_invitation(text, uuid) to authenticated, service_role;
grant execute on function public.revoke_project_member(uuid, uuid, text, uuid) to authenticated, service_role;
grant execute on function public.grant_project_permission(uuid, uuid, text, text, uuid) to authenticated, service_role;
grant execute on function public.nominate_recovery_route(uuid, uuid, uuid) to authenticated, service_role;
grant execute on function public.accept_recovery_route(uuid, uuid, uuid) to authenticated, service_role;
grant execute on function public.open_recovery_case(uuid, uuid, text, jsonb, uuid[], uuid) to authenticated, service_role;
grant execute on function public.propose_project_transfer(uuid, text, uuid, uuid, text, uuid) to authenticated, service_role;
grant execute on function public.accept_project_transfer(uuid, uuid, uuid) to authenticated, service_role;
grant execute on function public.review_project_transfer(uuid, uuid, text, text, uuid) to authenticated, service_role;
grant execute on function public.apply_project_transfer(uuid, uuid, uuid) to authenticated, service_role;
grant execute on function public.request_account_deletion(text, uuid) to authenticated, service_role;
grant execute on function public.create_daily_report(uuid, date, text, jsonb, jsonb, uuid) to authenticated, service_role;
grant execute on function public.save_daily_report_draft(uuid, uuid, integer, date, text, jsonb, jsonb, uuid) to authenticated, service_role;
grant execute on function public.submit_daily_report(uuid, uuid, integer, uuid) to authenticated, service_role;
grant execute on function public.review_daily_report(uuid, uuid, integer, text, text, uuid) to authenticated, service_role;
grant execute on function public.create_milestone(uuid, text, text, date, date, numeric, uuid) to authenticated, service_role;
grant execute on function public.update_milestone(uuid, uuid, integer, text, text, text, numeric, numeric, uuid) to authenticated, service_role;
grant execute on function public.create_material(uuid, text, text, text, uuid) to authenticated, service_role;
grant execute on function public.create_material_request(uuid, text, date, jsonb, uuid) to authenticated, service_role;
grant execute on function public.save_material_request_draft(uuid, uuid, integer, text, date, jsonb, uuid) to authenticated, service_role;
grant execute on function public.submit_material_request(uuid, uuid, integer, uuid) to authenticated, service_role;
grant execute on function public.review_material_request(uuid, uuid, integer, text, text, uuid) to authenticated, service_role;
grant execute on function public.mark_material_ordered_external(uuid, uuid, integer, uuid) to authenticated, service_role;
grant execute on function public.record_stock_movement(uuid, uuid, uuid, text, numeric, uuid, text, uuid) to authenticated, service_role;
grant execute on function public.submit_stock_count(uuid, uuid, uuid, numeric, text, uuid) to authenticated, service_role;
grant execute on function public.review_stock_count(uuid, uuid, text, uuid) to authenticated, service_role;
grant execute on function public.create_budget_version(uuid, text, jsonb, uuid) to authenticated, service_role;
grant execute on function public.submit_budget_version(uuid, uuid, uuid) to authenticated, service_role;
grant execute on function public.review_budget_version(uuid, uuid, text, text, uuid) to authenticated, service_role;
grant execute on function public.create_cost_record(uuid, date, text, text, text, bigint, uuid) to authenticated, service_role;
grant execute on function public.update_cost_draft(uuid, uuid, integer, date, text, text, text, bigint, uuid) to authenticated, service_role;
grant execute on function public.submit_cost_record(uuid, uuid, integer, uuid) to authenticated, service_role;
grant execute on function public.review_cost_record(uuid, uuid, integer, text, text, uuid) to authenticated, service_role;
grant execute on function public.request_cost_adjustment(uuid, uuid, bigint, text, uuid) to authenticated, service_role;
grant execute on function public.review_cost_adjustment(uuid, uuid, text, uuid) to authenticated, service_role;
grant execute on function public.create_cash_advance(uuid, uuid, bigint, text, uuid) to authenticated, service_role;
grant execute on function public.issue_cash_advance(uuid, uuid, uuid) to authenticated, service_role;
grant execute on function public.allocate_advance_cost(uuid, uuid, uuid, bigint, uuid) to authenticated, service_role;
grant execute on function public.record_cash_return(uuid, uuid, bigint, uuid, text, uuid) to authenticated, service_role;
grant execute on function public.report_payment(uuid, uuid, bigint, date, text, text, uuid) to authenticated, service_role;
grant execute on function public.create_worker(uuid, text, text, uuid) to authenticated, service_role;
grant execute on function public.record_labor_entry(uuid, uuid, date, text, numeric, text, text, uuid) to authenticated, service_role;
grant execute on function public.update_labor_entry(uuid, uuid, integer, date, text, numeric, text, text, uuid) to authenticated, service_role;
grant execute on function public.review_labor_entry(uuid, uuid, integer, text, text, uuid) to authenticated, service_role;
grant execute on function public.link_labor_cost(uuid, uuid, uuid, bigint, uuid) to authenticated, service_role;
grant execute on function public.open_closeout_case(uuid, jsonb, text, uuid) to authenticated, service_role;
grant execute on function public.review_closeout(uuid, uuid, text, text, uuid) to authenticated, service_role;
grant execute on function public.complete_closeout(uuid, uuid, uuid) to authenticated, service_role;
grant execute on function public.request_project_export(uuid, text, jsonb, uuid) to authenticated, service_role;
grant execute on function public.open_support_case(uuid, text, text, uuid) to authenticated, service_role;
grant execute on function public.mark_notification_read(uuid) to authenticated, service_role;
grant execute on function public.set_notification_preference(text, boolean, boolean, uuid) to authenticated, service_role;
grant execute on function public.create_document_upload_intent(uuid, text, uuid, text, text, text, bigint, uuid) to authenticated, service_role;
grant execute on function public.finalize_document_upload(uuid, uuid, uuid) to authenticated, service_role;
grant execute on function public.record_document_scan_result(uuid, text, bytea) to service_role;
grant execute on function public.claim_outbox_events(text, integer) to service_role;
grant execute on function public.finish_outbox_event(uuid, text, boolean, text) to service_role;


-- Ledger snapshots and decisions are append-only; corrections are new events.
create trigger project_status_events_append_only before update or delete on public.project_status_events
  for each row execute function private.prevent_immutable_change();
create trigger project_membership_events_append_only before update or delete on public.project_membership_events
  for each row execute function private.prevent_immutable_change();
create trigger report_revisions_append_only before update or delete on public.report_revisions
  for each row execute function private.prevent_immutable_change();
create trigger report_reviews_append_only before update or delete on public.report_reviews
  for each row execute function private.prevent_immutable_change();
create trigger milestone_history_append_only before update or delete on public.milestone_history
  for each row execute function private.prevent_immutable_change();
create trigger material_request_revisions_append_only before update or delete on public.material_request_revisions
  for each row execute function private.prevent_immutable_change();
create trigger material_request_reviews_append_only before update or delete on public.material_request_reviews
  for each row execute function private.prevent_immutable_change();
create trigger stock_movements_append_only before update or delete on public.stock_movements
  for each row execute function private.prevent_immutable_change();
create trigger budget_lines_append_only before update or delete on public.budget_lines
  for each row execute function private.prevent_immutable_change();
create trigger budget_reviews_append_only before update or delete on public.budget_reviews
  for each row execute function private.prevent_immutable_change();
create trigger cost_revisions_append_only before update or delete on public.cost_revisions
  for each row execute function private.prevent_immutable_change();
create trigger cost_reviews_append_only before update or delete on public.cost_reviews
  for each row execute function private.prevent_immutable_change();
create trigger transfer_approvals_append_only before update or delete on public.transfer_approvals
  for each row execute function private.prevent_immutable_change();
create trigger recovery_case_events_append_only before update or delete on public.recovery_case_events
  for each row execute function private.prevent_immutable_change();
create trigger closeout_acknowledgements_append_only before update or delete on public.closeout_acknowledgements
  for each row execute function private.prevent_immutable_change();
create trigger export_access_log_append_only before update or delete on public.export_access_log
  for each row execute function private.prevent_immutable_change();
create trigger support_case_events_append_only before update or delete on public.support_case_events
  for each row execute function private.prevent_immutable_change();
create trigger document_versions_append_only before update or delete on public.document_versions
  for each row execute function private.prevent_immutable_change();
create trigger advance_allocations_append_only before update or delete on public.advance_allocations
  for each row execute function private.prevent_immutable_change();
create trigger cash_returns_append_only before update or delete on public.cash_returns
  for each row execute function private.prevent_immutable_change();
create trigger labor_entry_revisions_append_only before update or delete on public.labor_entry_revisions
  for each row execute function private.prevent_immutable_change();
create trigger labor_entry_reviews_append_only before update or delete on public.labor_entry_reviews
  for each row execute function private.prevent_immutable_change();
create trigger audit_events_append_only before update or delete on public.audit_events
  for each row execute function private.prevent_immutable_change();
create trigger policy_gate_events_append_only before update or delete on private.policy_gate_events
  for each row execute function private.prevent_immutable_change();
