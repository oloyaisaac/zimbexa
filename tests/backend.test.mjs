import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationsDir = path.join(root, 'supabase', 'migrations');
const id = () => randomUUID();

async function makeDatabase() {
  const db = new PGlite({ extensions: { pgcrypto } });
  await db.exec(`
    create role anon nologin;
    create role authenticated nologin;
    create role service_role nologin bypassrls;
    create schema auth;
    create table auth.users (
      id uuid primary key,
      email text,
      email_confirmed_at timestamptz,
      raw_user_meta_data jsonb not null default '{}'::jsonb
    );
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
    $$;
    create schema storage;
    grant usage on schema storage to authenticated, service_role;
    create table storage.buckets (
      id text primary key,
      name text not null,
      public boolean not null default false,
      file_size_limit bigint,
      allowed_mime_types text[]
    );
    create table storage.objects (
      id uuid primary key default gen_random_uuid(),
      bucket_id text not null references storage.buckets(id),
      name text not null,
      metadata jsonb not null default '{}'::jsonb,
      created_at timestamptz not null default now(),
      unique (bucket_id, name)
    );
    grant select, insert on storage.objects to authenticated;
  `);

  const migrationFiles = fs.readdirSync(migrationsDir).filter((file) => file.endsWith('.sql')).sort();
  assert.ok(migrationFiles.length >= 8, 'expected a versioned migration set');
  for (const file of migrationFiles) {
    await db.exec(fs.readFileSync(path.join(migrationsDir, file), 'utf8'));
  }
  return db;
}

async function asRole(db, role, userId, work) {
  await db.query('reset role');
  await db.query("select set_config('request.jwt.claim.sub', $1, false)", [userId ?? '']);
  await db.query(`set role ${role}`);
  try {
    return await work();
  } finally {
    await db.query('reset role');
    await db.query("select set_config('request.jwt.claim.sub', '', false)");
  }
}

async function asUser(db, userId, work) {
  return asRole(db, 'authenticated', userId, work);
}

async function asService(db, work) {
  return asRole(db, 'service_role', null, work);
}

async function rpc(db, functionName, args) {
  const entries = Object.entries(args);
  const call = entries.map(([key], index) => `${key} => $${index + 1}`).join(', ');
  const values = entries.map(([, value]) => value);
  const { rows } = await db.query(`select public.${functionName}(${call}) as result`, values);
  return rows[0]?.result;
}

async function insertUser(db, userId, email, displayName) {
  await db.query(
    'insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values ($1, $2, now(), $3::jsonb)',
    [userId, email, JSON.stringify({ display_name: displayName })],
  );
}

test('Supabase backend migrations and critical workflows enforce project scope and ledger invariants', async (t) => {
  const db = await makeDatabase();
  t.after(async () => db.close());

  const users = {
    owner: '10000000-0000-4000-8000-000000000001',
    supervisor: '10000000-0000-4000-8000-000000000002',
    accountant: '10000000-0000-4000-8000-000000000003',
    outsider: '10000000-0000-4000-8000-000000000004',
    notification_viewer: '10000000-0000-4000-8000-000000000005',
    manager: '10000000-0000-4000-8000-000000000006',
  };
  await insertUser(db, users.owner, 'sarah@example.test', 'Sarah Owner');
  await insertUser(db, users.supervisor, 'moses@example.test', 'Moses Site');
  await insertUser(db, users.accountant, 'david@example.test', 'David Finance');
  await insertUser(db, users.outsider, 'outsider@example.test', 'Outside User');
  await insertUser(db, users.notification_viewer, 'notification-viewer@example.test', 'Notification Viewer');
  await insertUser(db, users.manager, 'manager@example.test', 'Project Manager');

  const workspaceOperation = id();
  const workspace = await asUser(db, users.owner, () => rpc(db, 'create_workspace', {
    p_name: 'Sarah Personal Workspace', p_kind: 'personal', p_operation_id: workspaceOperation,
  }));
  const workspaceReplay = await asUser(db, users.owner, () => rpc(db, 'create_workspace', {
    p_name: 'Sarah Personal Workspace', p_kind: 'personal', p_operation_id: workspaceOperation,
  }));
  assert.equal(workspaceReplay.workspace_id, workspace.workspace_id, 'retry returns the original workspace');
  await assert.rejects(
    asUser(db, users.owner, () => rpc(db, 'create_workspace', {
      p_name: 'Different Workspace', p_kind: 'personal', p_operation_id: workspaceOperation,
    })),
    /operation_id_reused_with_different_request/,
  );

  const projectResult = await asUser(db, users.owner, () => rpc(db, 'create_project', {
    p_workspace_id: workspace.workspace_id,
    p_name: 'Wakiso Home',
    p_project_type: 'residential',
    p_region: 'Central Region',
    p_district: 'Wakiso',
    p_town: 'Wakiso',
    p_planned_start_date: '2026-11-01',
    p_operation_id: id(),
  }));
  const projectId = projectResult.project_id;
  assert.equal(projectResult.status, 'draft');

  const secondProject = await asUser(db, users.owner, () => rpc(db, 'create_project', {
    p_workspace_id: workspace.workspace_id,
    p_name: 'Second Project',
    p_project_type: 'commercial',
    p_region: null,
    p_district: null,
    p_town: null,
    p_planned_start_date: null,
    p_operation_id: id(),
  }));
  assert.notEqual(secondProject.project_id, projectId);

  const invitationOperation = id();
  const invitationArgs = {
    p_project_id: projectId,
    p_email: 'moses@example.test',
    p_role: 'supervisor',
    p_permission_keys: [],
    p_expires_in_hours: 48,
    p_operation_id: invitationOperation,
  };
  const invitation = await asUser(db, users.owner, () => rpc(db, 'invite_project_member', invitationArgs));
  assert.equal(invitation.delivery, 'manual_or_future_email_provider');
  assert.equal(invitation.invite_token.length, 64);
  const invitationRetry = await asUser(db, users.owner, () => rpc(db, 'invite_project_member', invitationArgs));
  assert.equal(invitationRetry.invitation_id, invitation.invitation_id);
  assert.equal(invitationRetry.invite_token_available, false);
  assert.equal('invite_token' in invitationRetry, false, 'bearer tokens are not stored for idempotent retries');
  const expiringInvite = await asUser(db, users.owner, () => rpc(db, 'invite_project_member', {
    p_project_id: projectId, p_email: 'outsider@example.test', p_role: 'viewer',
    p_permission_keys: [], p_expires_in_hours: 1, p_operation_id: id(),
  }));
  await assert.rejects(
    asUser(db, users.owner, () => rpc(db, 'invite_project_member', {
      p_project_id: projectId, p_email: 'outsider@example.test', p_role: 'viewer',
      p_permission_keys: [], p_expires_in_hours: 1, p_operation_id: id(),
    })),
    /invitation_already_pending/,
    'a live invitation for the same recipient is not duplicated',
  );
  await db.query(
    'update public.project_invitations set created_at = now() - interval \'2 hours\', expires_at = now() - interval \'1 minute\' where id = $1',
    [expiringInvite.invitation_id],
  );
  const replacementInvite = await asUser(db, users.owner, () => rpc(db, 'invite_project_member', {
    p_project_id: projectId, p_email: 'outsider@example.test', p_role: 'viewer',
    p_permission_keys: [], p_expires_in_hours: 1, p_operation_id: id(),
  }));
  assert.notEqual(replacementInvite.invitation_id, expiringInvite.invitation_id, 'expired invitations can be replaced');
  const invitationStatuses = await db.query(
    'select id, status from public.project_invitations where id = any($1::uuid[]) order by created_at',
    [[expiringInvite.invitation_id, replacementInvite.invitation_id]],
  );
  assert.equal(invitationStatuses.rows[0].status, 'expired');
  assert.equal(invitationStatuses.rows[1].status, 'pending');
  await assert.rejects(
    asUser(db, users.outsider, () => rpc(db, 'accept_project_invitation', {
      p_token: invitation.invite_token, p_operation_id: id(),
    })),
    /invitation_recipient_mismatch/,
  );
  const joined = await asUser(db, users.supervisor, () => rpc(db, 'accept_project_invitation', {
    p_token: invitation.invite_token, p_operation_id: id(),
  }));
  assert.equal(joined.project_id, projectId);
  assert.equal(joined.role, 'supervisor');

  const outsiderProjects = await asUser(db, users.outsider, () => db.query('select id from public.projects'));
  assert.equal(outsiderProjects.rows.length, 0, 'outsiders cannot enumerate projects');
  const supervisorProjects = await asUser(db, users.supervisor, () => db.query('select id from public.projects'));
  assert.deepEqual(supervisorProjects.rows.map((row) => row.id), [projectId], 'membership is scoped to one project');
  const directProjectWrite = asUser(db, users.supervisor, () => db.query(
    "insert into public.projects (workspace_id, name, project_type) values ($1, 'forged', 'residential')",
    [workspace.workspace_id],
  ));
  await assert.rejects(directProjectWrite, /permission denied|row-level security/);
  await assert.rejects(
    asRole(db, 'anon', null, () => rpc(db, 'create_workspace', {
      p_name: 'Anonymous Workspace', p_kind: 'personal', p_operation_id: id(),
    })),
    /permission denied/,
    'anonymous users cannot execute authenticated business RPCs',
  );
  await assert.rejects(
    asUser(db, users.owner, () => db.query('select * from public.project_invitations')),
    /permission denied/,
    'authenticated users cannot read invitation token hashes directly',
  );
  const invitationSummary = await asUser(db, users.owner, () => db.query(
    'select * from public.project_invitation_summaries where id = $1', [invitation.invitation_id],
  ));
  assert.equal(invitationSummary.rows.length, 1);
  assert.equal('token_hash' in invitationSummary.rows[0], false, 'invitation summaries do not disclose token hashes');
  await assert.rejects(
    asUser(db, users.owner, () => db.query(
      "select private.write_audit_event($1, null, 'forged.audit', 'project', $1, '{}'::jsonb)", [projectId],
    )),
    /permission denied/,
    'authenticated clients cannot invoke internal audit-writing helpers',
  );

  await assert.rejects(
    asUser(db, users.owner, () => rpc(db, 'activate_project', {
      p_project_id: projectId, p_expected_revision: 1, p_operation_id: id(),
    })),
    /release_gate_blocked/,
  );
  const route = await asUser(db, users.owner, () => rpc(db, 'nominate_recovery_route', {
    p_project_id: projectId, p_nominee_user_id: users.supervisor, p_operation_id: id(),
  }));
  const acceptedRoute = await asUser(db, users.supervisor, () => rpc(db, 'accept_recovery_route', {
    p_project_id: projectId, p_route_id: route.recovery_route_id, p_operation_id: id(),
  }));
  assert.equal(acceptedRoute.status, 'verified');
  await assert.rejects(
    asUser(db, users.owner, () => db.query(
      "select private.set_policy_gate('project_activation', 'enabled', 'test-only', 'TEST-ONLY-REVIEW', $1)",
      [users.owner],
    )),
    /permission denied/,
    'authenticated users cannot open platform policy gates',
  );
  await asService(db, () => db.query(
    "select private.set_policy_gate('project_activation', 'enabled', 'test-only', 'TEST-ONLY-REVIEW', $1)",
    [users.owner],
  ));
  await asService(db, () => db.query(
    "select private.set_policy_gate('project_activation', 'enabled', 'test-only', 'TEST-ONLY-REVIEW', $1)",
    [users.supervisor],
  ));
  const gateAudit = await db.query(
    "select count(*)::integer as count from private.policy_gate_events where gate_key = 'project_activation' and new_status = 'enabled'",
  );
  assert.equal(gateAudit.rows[0].count, 2, 'policy-gate openings and approver changes are audited');
  await assert.rejects(
    db.query("update private.policy_gate_events set evidence_reference = 'tampered' where gate_key = 'project_activation'"),
    /record_is_append_only/,
    'policy-gate audit history is immutable',
  );
  const activated = await asUser(db, users.owner, () => rpc(db, 'activate_project', {
    p_project_id: projectId, p_expected_revision: 1, p_operation_id: id(),
  }));
  assert.equal(activated.status, 'active');
  assert.equal(activated.revision, 2);

  const material = await asUser(db, users.supervisor, () => rpc(db, 'create_material', {
    p_project_id: projectId, p_name: 'Cement', p_specification: '50 kg bag', p_base_unit: 'BAG_50KG', p_operation_id: id(),
  }));
  const locationRows = await asUser(db, users.supervisor, () => db.query(
    'select id from public.stock_locations where project_id = $1 and name = $2', [projectId, 'Main site'],
  ));
  const locationId = locationRows.rows[0].id;
  await assert.rejects(
    asUser(db, users.supervisor, () => rpc(db, 'create_material_request', {
      p_project_id: projectId, p_purpose: 'Invalid empty request', p_required_date: null,
      p_lines: null, p_operation_id: id(),
    })),
    /material_request_lines_invalid/,
    'material requests require at least one explicit line',
  );
  const request = await asUser(db, users.supervisor, () => rpc(db, 'create_material_request', {
    p_project_id: projectId,
    p_purpose: 'Columns and lintels',
    p_required_date: '2026-11-10',
    p_lines: [{ material_id: material.material_id, quantity: 50, unit: 'BAG_50KG', estimated_unit_cost_ugx: 32000 }],
    p_operation_id: id(),
  }));
  await asUser(db, users.supervisor, () => rpc(db, 'submit_material_request', {
    p_project_id: projectId, p_request_id: request.request_id, p_expected_revision: 1, p_operation_id: id(),
  }));
  const changesRequested = await asUser(db, users.owner, () => rpc(db, 'review_material_request', {
    p_project_id: projectId, p_request_id: request.request_id, p_expected_revision: 1,
    p_decision: 'changes_requested', p_comment: 'Clarify the request purpose.', p_operation_id: id(),
  }));
  assert.equal(changesRequested.status, 'changes_requested');
  const savedRequest = await asUser(db, users.supervisor, () => rpc(db, 'save_material_request_draft', {
    p_project_id: projectId, p_request_id: request.request_id, p_expected_revision: 1,
    p_purpose: 'Columns and lintels - revised', p_required_date: '2026-11-10',
    p_lines: [{ material_id: material.material_id, quantity: 50, unit: 'BAG_50KG', estimated_unit_cost_ugx: 32000 }],
    p_operation_id: id(),
  }));
  assert.equal(savedRequest.revision, 2);
  const requestHistory = await asUser(db, users.supervisor, () => db.query(
    'select revision, snapshot from public.material_request_revisions where request_id = $1 order by revision', [request.request_id],
  ));
  assert.deepEqual(requestHistory.rows.map((row) => row.revision), [1, 2]);
  assert.equal(requestHistory.rows[0].snapshot.purpose, 'Columns and lintels');
  assert.equal(requestHistory.rows[1].snapshot.purpose, 'Columns and lintels - revised');
  const lineRows = await asUser(db, users.supervisor, () => db.query(
    'select id from public.material_request_lines where request_id = $1', [request.request_id],
  ));
  const lineId = lineRows.rows[0].id;
  await asUser(db, users.supervisor, () => rpc(db, 'submit_material_request', {
    p_project_id: projectId, p_request_id: request.request_id, p_expected_revision: 2, p_operation_id: id(),
  }));
  const approval = await asUser(db, users.owner, () => rpc(db, 'review_material_request', {
    p_project_id: projectId, p_request_id: request.request_id, p_expected_revision: 2,
    p_decision: 'approved', p_comment: 'Approved for the next delivery.', p_operation_id: id(),
  }));
  assert.equal(approval.status, 'approved');
  await asUser(db, users.owner, () => rpc(db, 'mark_material_ordered_external', {
    p_project_id: projectId, p_request_id: request.request_id, p_expected_revision: 2, p_operation_id: id(),
  }));

  const receiptOperation = id();
  const receiptArgs = {
    p_project_id: projectId, p_location_id: locationId, p_material_id: material.material_id,
    p_movement_type: 'receipt', p_quantity_delta: 50, p_request_line_id: lineId,
    p_reason: 'Received on site; user-reported.', p_operation_id: receiptOperation,
  };
  const receipt = await asUser(db, users.supervisor, () => rpc(db, 'record_stock_movement', receiptArgs));
  const receiptReplay = await asUser(db, users.supervisor, () => rpc(db, 'record_stock_movement', receiptArgs));
  assert.equal(receiptReplay.movement_id, receipt.movement_id, 'retry cannot create a second receipt');
  const afterReceipt = await asUser(db, users.supervisor, () => db.query(
    'select available_quantity from public.stock_balances where project_id = $1 and location_id = $2 and material_id = $3',
    [projectId, locationId, material.material_id],
  ));
  assert.equal(Number(afterReceipt.rows[0].available_quantity), 50);

  const issue = await asUser(db, users.supervisor, () => rpc(db, 'record_stock_movement', {
    p_project_id: projectId, p_location_id: locationId, p_material_id: material.material_id,
    p_movement_type: 'issue', p_quantity_delta: -30, p_request_line_id: null,
    p_reason: 'Issued to the foundation team.', p_operation_id: id(),
  }));
  assert.equal(Number(issue.balance), 20);
  await assert.rejects(
    asUser(db, users.supervisor, () => rpc(db, 'record_stock_movement', {
      p_project_id: projectId, p_location_id: locationId, p_material_id: material.material_id,
      p_movement_type: 'issue', p_quantity_delta: -25, p_request_line_id: null,
      p_reason: 'Concurrent issue must not overdraw stock.', p_operation_id: id(),
    })),
    /insufficient_stock/,
  );
  const movementCount = await db.query('select count(*)::integer as count from public.stock_movements where project_id = $1', [projectId]);
  assert.equal(movementCount.rows[0].count, 2, 'failed overdraw leaves the ledger unchanged');

  const cost = await asUser(db, users.supervisor, () => rpc(db, 'create_cost_record', {
    p_project_id: projectId, p_cost_date: '2026-10-21', p_category: 'materials',
    p_description: 'Cement delivered to site', p_counterparty: 'Local hardware shop', p_amount_ugx: 320000, p_operation_id: id(),
  }));
  await asUser(db, users.supervisor, () => rpc(db, 'submit_cost_record', {
    p_project_id: projectId, p_cost_record_id: cost.cost_record_id, p_expected_revision: 1, p_operation_id: id(),
  }));
  await assert.rejects(
    asUser(db, users.supervisor, () => rpc(db, 'review_cost_record', {
      p_project_id: projectId, p_cost_record_id: cost.cost_record_id, p_expected_revision: 1,
      p_decision: 'approved', p_comment: null, p_operation_id: id(),
    })),
    /cost_approval_denied/,
  );
  const supervisorFinance = await asUser(db, users.supervisor, () => db.query(
    'select * from public.project_financial_summary where project_id = $1', [projectId],
  ));
  assert.equal(supervisorFinance.rows.length, 0, 'supervisors do not see finance summaries by default');
  await asUser(db, users.owner, () => rpc(db, 'review_cost_record', {
    p_project_id: projectId, p_cost_record_id: cost.cost_record_id, p_expected_revision: 1,
    p_decision: 'approved', p_comment: 'Receipt reviewed.', p_operation_id: id(),
  }));

  const accountantInvite = await asUser(db, users.owner, () => rpc(db, 'invite_project_member', {
    p_project_id: projectId, p_email: 'david@example.test', p_role: 'accountant',
    p_permission_keys: [], p_expires_in_hours: 48, p_operation_id: id(),
  }));
  await asUser(db, users.accountant, () => rpc(db, 'accept_project_invitation', {
    p_token: accountantInvite.invite_token, p_operation_id: id(),
  }));
  await asUser(db, users.owner, () => rpc(db, 'grant_project_permission', {
    p_project_id: projectId, p_user_id: users.accountant, p_permission_key: 'finance.approve',
    p_reason: 'Designated independent approver for the pilot test.', p_operation_id: id(),
  }));
  await asUser(db, users.owner, () => rpc(db, 'grant_project_permission', {
    p_project_id: projectId, p_user_id: users.accountant, p_permission_key: 'closeout.approve',
    p_reason: 'Designated independent closeout reviewer for the test.', p_operation_id: id(),
  }));

  const notificationPreference = await asUser(db, users.owner, () => rpc(db, 'set_notification_preference', {
    p_event_type: 'member.joined', p_in_app_enabled: false, p_email_enabled: false, p_operation_id: id(),
  }));
  assert.equal(notificationPreference.in_app_enabled, false);
  const ownerMemberNotificationsBefore = await db.query(
    "select count(*)::integer as count from public.app_notifications where recipient_user_id = $1 and event_type = 'member.joined'",
    [users.owner],
  );
  const preferenceInvite = await asUser(db, users.owner, () => rpc(db, 'invite_project_member', {
    p_project_id: projectId, p_email: 'notification-viewer@example.test', p_role: 'viewer',
    p_permission_keys: [], p_expires_in_hours: 48, p_operation_id: id(),
  }));
  await asUser(db, users.notification_viewer, () => rpc(db, 'accept_project_invitation', {
    p_token: preferenceInvite.invite_token, p_operation_id: id(),
  }));
  const ownerMemberNotificationsAfter = await db.query(
    "select count(*)::integer as count from public.app_notifications where recipient_user_id = $1 and event_type = 'member.joined'",
    [users.owner],
  );
  assert.equal(ownerMemberNotificationsAfter.rows[0].count, ownerMemberNotificationsBefore.rows[0].count,
    'disabled in-app notification preferences are honored for future events');
  const savedPreference = await asUser(db, users.owner, () => db.query(
    "select in_app_enabled, email_enabled from public.notification_preferences where user_id = $1 and event_type = 'member.joined'",
    [users.owner],
  ));
  assert.deepEqual(savedPreference.rows[0], { in_app_enabled: false, email_enabled: false });

  const managerInvite = await asUser(db, users.owner, () => rpc(db, 'invite_project_member', {
    p_project_id: projectId, p_email: 'manager@example.test', p_role: 'manager',
    p_permission_keys: [], p_expires_in_hours: 48, p_operation_id: id(),
  }));
  await asUser(db, users.manager, () => rpc(db, 'accept_project_invitation', {
    p_token: managerInvite.invite_token, p_operation_id: id(),
  }));
  await asUser(db, users.owner, () => rpc(db, 'grant_project_permission', {
    p_project_id: projectId, p_user_id: users.notification_viewer, p_permission_key: 'governance.approve',
    p_reason: 'Independent manager-handover reviewer for the test.', p_operation_id: id(),
  }));
  const handover = await asUser(db, users.owner, () => rpc(db, 'propose_project_transfer', {
    p_project_id: projectId, p_transfer_type: 'manager_handover', p_from_user_id: users.manager,
    p_recipient_user_id: users.accountant, p_reason: 'Routine manager transition.', p_operation_id: id(),
  }));
  await asUser(db, users.accountant, () => rpc(db, 'accept_project_transfer', {
    p_project_id: projectId, p_proposal_id: handover.transfer_proposal_id, p_operation_id: id(),
  }));
  await asUser(db, users.notification_viewer, () => rpc(db, 'review_project_transfer', {
    p_project_id: projectId, p_proposal_id: handover.transfer_proposal_id,
    p_decision: 'approved', p_reason: 'Independent handover approval.', p_operation_id: id(),
  }));
  const appliedHandover = await asUser(db, users.owner, () => rpc(db, 'apply_project_transfer', {
    p_project_id: projectId, p_proposal_id: handover.transfer_proposal_id, p_operation_id: id(),
  }));
  assert.equal(appliedHandover.status, 'applied', 'a manager handover does not require the closed custody-transfer gate');
  const transferRoles = await db.query(
    'select user_id, role, status from public.project_memberships where project_id = $1 and user_id = any($2::uuid[]) order by user_id',
    [projectId, [users.owner, users.manager, users.accountant]],
  );
  assert.equal(transferRoles.rows.find((row) => row.user_id === users.owner).role, 'custodian');
  assert.equal(transferRoles.rows.find((row) => row.user_id === users.manager).status, 'revoked');
  assert.equal(transferRoles.rows.find((row) => row.user_id === users.accountant).role, 'manager');
  const custodyGate = await db.query("select status from private.policy_gates where gate_key = 'custody_transfer'");
  assert.equal(custodyGate.rows[0].status, 'pending_signoff');

  await assert.rejects(
    asUser(db, users.supervisor, () => rpc(db, 'create_budget_version', {
      p_project_id: projectId, p_reason: 'Invalid empty budget', p_lines: null, p_operation_id: id(),
    })),
    /budget_lines_invalid/,
    'budget versions require at least one explicit line',
  );
  const budget = await asUser(db, users.supervisor, () => rpc(db, 'create_budget_version', {
    p_project_id: projectId, p_reason: 'Initial project budget',
    p_lines: [
      { category: 'materials', description: 'Cement', amount_ugx: 1000000 },
      { category: 'labor', description: 'Masonry wages', amount_ugx: 250000 },
    ],
    p_operation_id: id(),
  }));
  assert.equal(budget.version, 1);
  await asUser(db, users.supervisor, () => rpc(db, 'submit_budget_version', {
    p_project_id: projectId, p_budget_version_id: budget.budget_version_id, p_operation_id: id(),
  }));
  const budgetApproval = await asUser(db, users.owner, () => rpc(db, 'review_budget_version', {
    p_project_id: projectId, p_budget_version_id: budget.budget_version_id,
    p_decision: 'approved', p_comment: 'Initial budget reviewed.', p_operation_id: id(),
  }));
  assert.equal(budgetApproval.status, 'approved');
  const approvedBudget = await asUser(db, users.accountant, () => db.query(
    'select approved_budget_ugx from public.project_financial_summary where project_id = $1', [projectId],
  ));
  assert.equal(Number(approvedBudget.rows[0].approved_budget_ugx), 1250000);

  const accountantCost = await asUser(db, users.accountant, () => rpc(db, 'create_cost_record', {
    p_project_id: projectId, p_cost_date: '2026-10-21', p_category: 'transport',
    p_description: 'Material transport', p_counterparty: null, p_amount_ugx: 50000, p_operation_id: id(),
  }));
  await asUser(db, users.accountant, () => rpc(db, 'submit_cost_record', {
    p_project_id: projectId, p_cost_record_id: accountantCost.cost_record_id, p_expected_revision: 1, p_operation_id: id(),
  }));
  await assert.rejects(
    asUser(db, users.accountant, () => rpc(db, 'review_cost_record', {
      p_project_id: projectId, p_cost_record_id: accountantCost.cost_record_id, p_expected_revision: 1,
      p_decision: 'approved', p_comment: null, p_operation_id: id(),
    })),
    /self_approval_not_allowed/,
  );
  await asUser(db, users.owner, () => rpc(db, 'review_cost_record', {
    p_project_id: projectId, p_cost_record_id: accountantCost.cost_record_id, p_expected_revision: 1,
    p_decision: 'approved', p_comment: null, p_operation_id: id(),
  }));

  const worker = await asUser(db, users.supervisor, () => rpc(db, 'create_worker', {
    p_project_id: projectId, p_display_name: 'Site Mason A', p_trade: 'Masonry', p_operation_id: id(),
  }));
  const laborEntry = await asUser(db, users.supervisor, () => rpc(db, 'record_labor_entry', {
    p_project_id: projectId, p_worker_id: worker.worker_id, p_work_date: '2026-10-21',
    p_work_type: 'Block laying', p_quantity: 1, p_unit: 'day', p_note: 'Initial attendance entry.', p_operation_id: id(),
  }));
  const requestedChanges = await asUser(db, users.owner, () => rpc(db, 'review_labor_entry', {
    p_project_id: projectId, p_labor_entry_id: laborEntry.labor_entry_id, p_expected_revision: 1,
    p_decision: 'changes_requested', p_comment: 'Confirm the recorded day quantity.', p_operation_id: id(),
  }));
  assert.equal(requestedChanges.status, 'changes_requested');
  const correctedLabor = await asUser(db, users.supervisor, () => rpc(db, 'update_labor_entry', {
    p_project_id: projectId, p_labor_entry_id: laborEntry.labor_entry_id, p_expected_revision: 1,
    p_work_date: '2026-10-21', p_work_type: 'Block laying', p_quantity: 1.5,
    p_unit: 'day', p_note: 'Corrected attendance after supervisor review.', p_operation_id: id(),
  }));
  assert.equal(correctedLabor.revision, 2);
  assert.equal(correctedLabor.status, 'submitted');
  const laborHistory = await asUser(db, users.supervisor, () => db.query(
    'select revision, snapshot from public.labor_entry_revisions where labor_entry_id = $1 order by revision',
    [laborEntry.labor_entry_id],
  ));
  assert.deepEqual(laborHistory.rows.map((row) => row.revision), [1, 2]);
  assert.equal(Number(laborHistory.rows[0].snapshot.quantity), 1);
  assert.equal(Number(laborHistory.rows[1].snapshot.quantity), 1.5);
  await asUser(db, users.owner, () => rpc(db, 'review_labor_entry', {
    p_project_id: projectId, p_labor_entry_id: laborEntry.labor_entry_id, p_expected_revision: 2,
    p_decision: 'accepted', p_comment: 'Corrected attendance accepted.', p_operation_id: id(),
  }));

  const wageCost = await asUser(db, users.supervisor, () => rpc(db, 'create_cost_record', {
    p_project_id: projectId, p_cost_date: '2026-10-21', p_category: 'labor',
    p_description: 'Masonry wages', p_counterparty: 'Site Mason A', p_amount_ugx: 100000, p_operation_id: id(),
  }));
  await assert.rejects(
    asUser(db, users.supervisor, () => rpc(db, 'link_labor_cost', {
      p_project_id: projectId, p_labor_entry_id: laborEntry.labor_entry_id,
      p_cost_record_id: wageCost.cost_record_id, p_amount_ugx: 100000, p_operation_id: id(),
    })),
    /approved_labor_cost_required/,
  );
  await asUser(db, users.supervisor, () => rpc(db, 'submit_cost_record', {
    p_project_id: projectId, p_cost_record_id: wageCost.cost_record_id, p_expected_revision: 1, p_operation_id: id(),
  }));
  await asUser(db, users.owner, () => rpc(db, 'review_cost_record', {
    p_project_id: projectId, p_cost_record_id: wageCost.cost_record_id, p_expected_revision: 1,
    p_decision: 'approved', p_comment: 'Wage cost reviewed.', p_operation_id: id(),
  }));
  await asUser(db, users.supervisor, () => rpc(db, 'link_labor_cost', {
    p_project_id: projectId, p_labor_entry_id: laborEntry.labor_entry_id,
    p_cost_record_id: wageCost.cost_record_id, p_amount_ugx: 100000, p_operation_id: id(),
  }));
  const hiddenWageLinks = await asUser(db, users.supervisor, () => db.query(
    'select id from public.labor_cost_links where labor_entry_id = $1', [laborEntry.labor_entry_id],
  ));
  assert.equal(hiddenWageLinks.rows.length, 0, 'supervisors cannot see private wage-cost links');
  const visibleWageLinks = await asUser(db, users.accountant, () => db.query(
    'select amount_ugx from public.labor_cost_links where labor_entry_id = $1', [laborEntry.labor_entry_id],
  ));
  assert.equal(Number(visibleWageLinks.rows[0].amount_ugx), 100000, 'authorized finance/pay users can see wage links');

  const advance = await asUser(db, users.owner, () => rpc(db, 'create_cash_advance', {
    p_project_id: projectId, p_custodian_user_id: users.supervisor, p_amount_ugx: 500000,
    p_purpose: 'Small site purchases', p_operation_id: id(),
  }));
  await asUser(db, users.accountant, () => rpc(db, 'issue_cash_advance', {
    p_project_id: projectId, p_advance_id: advance.cash_advance_id, p_operation_id: id(),
  }));
  await asUser(db, users.accountant, () => rpc(db, 'allocate_advance_cost', {
    p_project_id: projectId, p_advance_id: advance.cash_advance_id, p_cost_record_id: cost.cost_record_id,
    p_amount_ugx: 320000, p_operation_id: id(),
  }));
  await asUser(db, users.accountant, () => rpc(db, 'record_cash_return', {
    p_project_id: projectId, p_advance_id: advance.cash_advance_id, p_amount_ugx: 80000,
    p_received_by: users.owner, p_reason: 'Unused cash returned to the custodian.', p_operation_id: id(),
  }));
  const advanceSummary = await asUser(db, users.accountant, () => db.query(
    'select amount_ugx, allocated_to_approved_costs_ugx, cash_returned_ugx, unaccounted_ugx from public.cash_advance_summary where cash_advance_id = $1',
    [advance.cash_advance_id],
  ));
  assert.deepEqual(Object.fromEntries(Object.entries(advanceSummary.rows[0]).map(([key, value]) => [key, Number(value)])), {
    amount_ugx: 500000, allocated_to_approved_costs_ugx: 320000, cash_returned_ugx: 80000, unaccounted_ugx: 100000,
  });

  const payment = await asUser(db, users.supervisor, () => rpc(db, 'report_payment', {
    p_project_id: projectId, p_cost_record_id: cost.cost_record_id, p_amount_ugx: 200000,
    p_payment_date: '2026-10-21', p_method: 'mobile_money', p_external_reference: 'UG-TEST-123', p_operation_id: id(),
  }));
  assert.equal(payment.verification_status, 'user_reported');
  const financeSummary = await asUser(db, users.accountant, () => db.query(
    'select approved_costs_ugx, reported_payments_ugx, independently_reconciled_payments_ugx, payment_status_note from public.project_financial_summary where project_id = $1',
    [projectId],
  ));
  assert.deepEqual(financeSummary.rows[0], {
    approved_costs_ugx: 470000, reported_payments_ugx: 200000, independently_reconciled_payments_ugx: 0,
    payment_status_note: 'reported payments are not provider-confirmed by default',
  });
  const paymentUndercuttingAdjustment = await asUser(db, users.supervisor, () => rpc(db, 'request_cost_adjustment', {
    p_project_id: projectId, p_cost_record_id: cost.cost_record_id, p_delta_ugx: -150000,
    p_reason: 'Test a downward correction against reported payments.', p_operation_id: id(),
  }));
  await assert.rejects(
    asUser(db, users.owner, () => rpc(db, 'review_cost_adjustment', {
      p_project_id: projectId, p_cost_adjustment_id: paymentUndercuttingAdjustment.cost_adjustment_id,
      p_decision: 'approved', p_operation_id: id(),
    })),
    /cost_adjustment_below_reported_payments/,
  );
  const advanceUndercuttingAdjustment = await asUser(db, users.supervisor, () => rpc(db, 'request_cost_adjustment', {
    p_project_id: projectId, p_cost_record_id: cost.cost_record_id, p_delta_ugx: -100000,
    p_reason: 'Test a downward correction against advance allocations.', p_operation_id: id(),
  }));
  await assert.rejects(
    asUser(db, users.owner, () => rpc(db, 'review_cost_adjustment', {
      p_project_id: projectId, p_cost_adjustment_id: advanceUndercuttingAdjustment.cost_adjustment_id,
      p_decision: 'approved', p_operation_id: id(),
    })),
    /cost_adjustment_below_advance_allocations/,
  );

  const report = await asUser(db, users.supervisor, () => rpc(db, 'create_daily_report', {
    p_project_id: projectId, p_report_date: '2026-10-21', p_work_done: 'Foundation trenches prepared.',
    p_labor_summary: [{ trade: 'masonry', people: 4 }], p_blockers: [], p_operation_id: id(),
  }));
  await asUser(db, users.supervisor, () => rpc(db, 'submit_daily_report', {
    p_project_id: projectId, p_report_id: report.report_id, p_expected_revision: 1, p_operation_id: id(),
  }));
  await assert.rejects(
    asUser(db, users.owner, () => rpc(db, 'review_daily_report', {
      p_project_id: projectId, p_report_id: report.report_id, p_expected_revision: 0,
      p_decision: 'accepted', p_comment: null, p_operation_id: id(),
    })),
    /revision_conflict/,
  );
  await assert.rejects(
    asUser(db, users.owner, () => rpc(db, 'review_daily_report', {
      p_project_id: projectId, p_report_id: report.report_id, p_expected_revision: null,
      p_decision: 'accepted', p_comment: null, p_operation_id: id(),
    })),
    /revision_conflict/,
    'a null revision cannot bypass optimistic concurrency',
  );
  const reviewedReport = await asUser(db, users.owner, () => rpc(db, 'review_daily_report', {
    p_project_id: projectId, p_report_id: report.report_id, p_expected_revision: 1,
    p_decision: 'accepted', p_comment: 'Reviewed.', p_operation_id: id(),
  }));
  assert.equal(reviewedReport.status, 'accepted');
  const revisions = await asUser(db, users.supervisor, () => db.query(
    'select revision from public.report_revisions where report_id = $1 order by revision', [report.report_id],
  ));
  assert.deepEqual(revisions.rows.map((row) => row.revision), [1]);

  const milestone = await asUser(db, users.owner, () => rpc(db, 'create_milestone', {
    p_project_id: projectId, p_name: 'Foundation', p_description: 'Footings and foundation walls',
    p_target_start_date: '2026-11-01', p_target_end_date: '2026-11-20', p_weight: 2, p_operation_id: id(),
  }));
  await asUser(db, users.owner, () => rpc(db, 'update_milestone', {
    p_project_id: projectId, p_milestone_id: milestone.milestone_id, p_expected_revision: 1,
    p_name: 'Foundation', p_description: 'Footings and foundation walls', p_status: 'in_progress',
    p_completion_fraction: 0.5, p_weight: 2, p_operation_id: id(),
  }));
  const progress = await asUser(db, users.owner, () => db.query(
    'select weighted_progress_percent, progress_basis from public.project_progress_summary where project_id = $1', [projectId],
  ));
  assert.equal(Number(progress.rows[0].weighted_progress_percent), 50);

  const document = await asUser(db, users.supervisor, () => rpc(db, 'create_document_upload_intent', {
    p_project_id: projectId, p_record_type: 'daily_report', p_record_id: report.report_id,
    p_purpose: 'Site progress photo', p_original_filename: 'foundation.jpg', p_mime_type: 'image/jpeg',
    p_size_bytes: 1024, p_operation_id: id(),
  }));
  await asUser(db, users.supervisor, async () => {
    await db.query('insert into storage.objects (bucket_id, name, metadata) values ($1, $2, $3::jsonb)', [
      document.bucket, document.object_key, JSON.stringify({ size: '1024', mimetype: 'image/jpeg' }),
    ]);
    await rpc(db, 'finalize_document_upload', {
      p_project_id: projectId, p_document_id: document.document_id, p_operation_id: id(),
    });
    const hiddenUntilScan = await db.query('select id from storage.objects where name = $1', [document.object_key]);
    assert.equal(hiddenUntilScan.rows.length, 0, 'unscanned documents cannot be downloaded');
  });
  await assert.rejects(
    asUser(db, users.supervisor, () => rpc(db, 'record_document_scan_result', {
      p_document_id: document.document_id, p_scan_result: 'clean', p_sha256: null,
    })),
    /permission denied/,
    'authenticated clients cannot forge document scan results',
  );
  const documentSha256 = createHash('sha256').update('clean-test-object').digest();
  await assert.rejects(
    asService(db, () => rpc(db, 'record_document_scan_result', {
      p_document_id: document.document_id, p_scan_result: 'clean', p_sha256: null,
    })),
    /document_hash_required/,
    'trusted scan results must include a SHA-256 digest',
  );
  await asService(db, () => rpc(db, 'record_document_scan_result', {
    p_document_id: document.document_id, p_scan_result: 'clean', p_sha256: documentSha256,
  }));
  const scanReplay = await asService(db, () => rpc(db, 'record_document_scan_result', {
    p_document_id: document.document_id, p_scan_result: 'clean', p_sha256: documentSha256,
  }));
  assert.equal(scanReplay.replayed, true, 'a provider retry with the same scan result is safe');
  const visibleAfterScan = await asUser(db, users.supervisor, () => db.query(
    'select id from storage.objects where name = $1', [document.object_key],
  ));
  assert.equal(visibleAfterScan.rows.length, 1);
  const outsiderFiles = await asUser(db, users.outsider, () => db.query('select id from storage.objects'));
  assert.equal(outsiderFiles.rows.length, 0, 'private files are not enumerable across projects');

  const closeout = await asUser(db, users.owner, () => rpc(db, 'open_closeout_case', {
    p_project_id: projectId,
    p_checklist: { milestones_reviewed: true, stock_reconciled: true, costs_reviewed: true },
    p_reason: 'Construction work has reached the proposed completion stage.', p_operation_id: id(),
  }));
  await assert.rejects(
    asUser(db, users.accountant, () => rpc(db, 'complete_closeout', {
      p_project_id: projectId, p_closeout_case_id: closeout.closeout_case_id, p_operation_id: id(),
    })),
    /release_gate_blocked/,
  );
  const gatedProject = await asUser(db, users.owner, () => db.query('select status from public.projects where id = $1', [projectId]));
  assert.equal(gatedProject.rows[0].status, 'closeout_requested', 'a closeout request is not project completion');
  await assert.rejects(
    asUser(db, users.accountant, () => rpc(db, 'request_project_export', {
      p_project_id: projectId, p_export_scope: 'summary', p_filters: {}, p_operation_id: id(),
    })),
    /release_gate_blocked/,
  );

  const deletionRequest = await asUser(db, users.outsider, () => rpc(db, 'request_account_deletion', {
    p_reason: 'I no longer need this account.', p_operation_id: id(),
  }));
  assert.equal(deletionRequest.status, 'requested');
  const accountStillExists = await db.query('select id from auth.users where id = $1', [users.outsider]);
  assert.equal(accountStillExists.rows.length, 1, 'a request does not perform an unreviewed destructive deletion');

  const ownerNotifications = await asUser(db, users.owner, () => db.query(
    'select count(*)::integer as count from public.app_notifications where recipient_user_id = $1', [users.owner],
  ));
  assert.ok(ownerNotifications.rows[0].count > 0, 'membership changes create an in-app notification');
  await assert.rejects(
    asUser(db, users.owner, () => db.query('select * from public.claim_outbox_events($1, $2)', ['forged-client', 10])),
    /permission denied/,
    'outbox leases are service-role-only',
  );
  const claimed = await asService(db, async () => {
    const result = await db.query('select * from public.claim_outbox_events($1, $2)', ['test-worker', 10]);
    return result.rows;
  });
  assert.ok(claimed.length > 0, 'service worker can claim durable outbox events');
  const claimedEvent = claimed[0];
  await asService(db, () => rpc(db, 'finish_outbox_event', {
    p_event_id: claimedEvent.id, p_worker_id: 'test-worker', p_succeeded: true, p_error_code: null,
  }));
  const delivered = await db.query('select status from public.outbox_events where id = $1', [claimedEvent.id]);
  assert.equal(delivered.rows[0].status, 'delivered');
});
