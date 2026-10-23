import assert from 'node:assert/strict';
import { access, readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';

const requiredFiles = [
  'README.md',
  'changelog.md',
  'PRD.json',
  'requirements.json',
  'requirements.md',
  'agent_state.md',
  'agent_findings.md',
  'contracts/backend-api.md',
  'docs/security-and-operations.md',
];

for (const file of requiredFiles) {
  await access(file);
}

const prd = JSON.parse(await readFile('PRD.json', 'utf8'));
const requirements = JSON.parse(await readFile('requirements.json', 'utf8'));

assert.equal(prd.document_type, 'product_requirements_document');
assert.equal(prd.product.name, 'Zimbexa');
assert.equal(prd.current_delivery.production_claim, false);
assert.match(prd.decisions_confirmed_by_product_owner.implementation_order, /backend first/i);
assert.match(prd.decisions_confirmed_by_product_owner.cloud_changes, /do not restore, create, or modify/i);

const expectedGates = [
  'project_activation',
  'custody_transfer',
  'recovery_adjudication',
  'account_deletion_execution',
  'project_closeout_completion',
  'project_data_export',
  'document_retention_purge',
  'sensitive_support_access',
];
assert.deepEqual(
  prd.release_gates.map((gate) => gate.key).sort(),
  [...expectedGates].sort(),
  'PRD must enumerate every protected policy gate',
);
assert.ok(prd.release_gates.every((gate) => gate.default === 'pending_signoff'));

assert.equal(requirements.document_type, 'traceable_requirements_register');
assert.ok(requirements.requirements.length >= 20, 'Requirements register is unexpectedly incomplete');
const requirementIds = requirements.requirements.map((item) => item.id);
assert.equal(new Set(requirementIds).size, requirementIds.length, 'Requirement IDs must be unique');
for (const item of requirements.requirements) {
  assert.ok(item.id && item.title && item.statement, 'Each requirement needs an ID, title and statement');
  assert.ok(Array.isArray(item.acceptance) && item.acceptance.length > 0, `${item.id} needs acceptance criteria`);
  assert.ok(requirements.status_legend[item.status], `${item.id} uses an undocumented status: ${item.status}`);
}

const migrations = (await readdir('supabase/migrations'))
  .filter((name) => name.endsWith('.sql'))
  .sort();
assert.equal(migrations.length, 9, 'Expected the nine ordered backend migrations');
assert.ok(migrations.every((name, index) => name.startsWith(`20261021000${index + 1}00_`)), 'Migration order/prefix changed');

const packageJson = JSON.parse(await readFile('package.json', 'utf8'));
assert.equal(packageJson.scripts.check, 'npm run check:docs && npm test');

console.log(`Documentation and delivery checks passed (${requiredFiles.length} files, ${requirementIds.length} requirements, ${migrations.length} migrations).`);
