const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');
const crypto = require('crypto');

async function waitFor(predicate, message, timeoutMs = 1500) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail(message);
}

const read = (p) => fs.readFileSync(path.resolve(__dirname, '..', p), 'utf-8');

// Every page is closed at the end, even when a test fails part-way, so no
// jsdom timer can keep the test process alive.
const openWindows = [];
test.after(() => {
  for (const window of openWindows) window.close();
});

// Loads the page the way the console does, with every addon script inlined
// and the bridge replaced by `request`.
function loadPage(request, { storage = {}, uuid = () => crypto.randomUUID() } = {}) {
  const addonSrc = read('web/addon.js').replace('const isSandboxMode = window.parent === window;', 'const isSandboxMode = false;');
  const scripts = [read('web/grant_logic.js'), read('web/outbox_drain.js'), addonSrc].map((src) => `<script>${src}</script>`).join('');
  const dom = new JSDOM(read('web/index.html').replace('</body>', `${scripts}</body>`), { runScripts: 'dangerously', url: 'http://localhost/' });
  const window = dom.window;
  openWindows.push(window);
  window.crypto = { randomUUID: uuid };
  // jsdom's localStorage cannot be replaced, only seeded. The page reads it
  // after its first bridge round-trip, so seeding here is in time.
  for (const [key, value] of Object.entries(storage)) window.localStorage.setItem(key, value);
  window.confirm = () => true;
  window.DuneAddon = { request };
  window.fetch = async () => ({ ok: true, text: async () => 'mock_sql' });
  return window;
}

function stopTimers(window) {
  for (const name of ['__fetchDiagnosticsInterval', '__fetchPendingInterval', '__deliveryInterval']) {
    if (window[name]) clearInterval(window[name]);
  }
}

// A bridge for an installed v2 schema. `onQuery` can answer extra queries.
function installedBridge(calls, { onQuery = () => null, deliver = () => ({ status: 'pending' }) } = {}) {
  return async (action, payload) => {
    calls.push({ action, payload });
    if (action === 'database.query') {
      const q = payload.query;
      const extra = onQuery(q);
      if (extra) return extra;
      if (q.includes("to_regclass('dune_airdrop.airdrop_schema_version')")) return { rows: [{ version_table: 'dune_airdrop.airdrop_schema_version' }] };
      if (q.includes('max(version)')) return { rows: [{ version: 2 }] };
      if (q.includes("ILIKE '%container%'")) return { rows: [{ id: '9999999999999', class: '/Game/Chest', owner_account_id: '12345' }] };
      if (q.includes('JOIN dune.actors a ON a.id = i.actor_id')) return { rows: [{ account_id: '12345' }] };
      return { rows: [] };
    }
    if (action === 'addon.storage.get') return { found: false, key: payload.key, version: 0, value: null };
    if (action === 'addon.storage.put') return { version: 1 };
    if (action === 'rewards.list') return [];
    if (action === 'rewards.deliver') return { requestId: payload.requestId, ...deliver(payload) };
    return { rows: [] };
  };
}

test('UI Integration - container grant goes through rewards.deliver', async () => {
  let calls = [];
  const window = loadPage(installedBridge(calls));
  const document = window.document;

  await waitFor(() => document.getElementById('container-row-9999999999999'), 'Initial container data did not finish loading');

  assert.ok(calls.some((c) => c.action === 'database.query' && c.payload.query.includes('FROM dune_airdrop.airdrop_config')));
  calls.length = 0;

  document.getElementById('container-row-9999999999999').click();
  const openSpawnModalBtn = document.getElementById('openSpawnModalBtn');
  assert.ok(!openSpawnModalBtn.classList.contains('hidden'));
  const templateInput = document.getElementById('spawnItemTemplateInput');
  assert.strictEqual(templateInput.dataset.actId, '9999999999999');

  openSpawnModalBtn.click();
  const modal = document.getElementById('spawnItemModal');
  assert.ok(!modal.classList.contains('hidden'));

  templateInput.value = 'TestSword';
  document.getElementById('spawnItemQtyInput').value = '3';
  document.getElementById('spawnItemConfirmBtn').click();

  await waitFor(() => calls.some((c) => c.action === 'rewards.deliver'), 'Grant request was not emitted');
  const grant = calls.find((c) => c.action === 'rewards.deliver').payload;
  assert.match(grant.requestId, /^manual:grant:/);
  assert.strictEqual(grant.playerId, '12345');
  assert.strictEqual(grant.type, 'item');
  assert.strictEqual(grant.itemId, 'TestSword');
  assert.strictEqual(grant.amount, 3);
  assert.strictEqual(grant.quality, 0);
  assert.ok(!calls.some((c) => c.action === 'admin.items.grant'));

  await waitFor(() => modal.classList.contains('hidden'), 'Modal did not close after the console accepted the grant');
  assert.strictEqual(window.localStorage.getItem('pending_manual_grant'), null);
  stopTimers(window);
});

test('UI Integration - a grant the console rejects is not kept as uncertain', async () => {
  const calls = [];
  const window = loadPage(installedBridge(calls, { deliver: () => ({ status: 'failed', lastError: 'Player not found.' }) }));
  const document = window.document;
  await waitFor(() => document.getElementById('container-row-9999999999999'), 'containers did not load');

  document.getElementById('container-row-9999999999999').click();
  document.getElementById('openSpawnModalBtn').click();
  document.getElementById('spawnItemTemplateInput').value = 'TestSword';
  document.getElementById('spawnItemQtyInput').value = '1';
  document.getElementById('spawnItemConfirmBtn').click();

  await waitFor(() => calls.some((c) => c.action === 'rewards.deliver'), 'grant not sent');
  await new Promise((r) => setTimeout(r, 20));
  assert.strictEqual(window.localStorage.getItem('pending_manual_grant'), null);
  assert.strictEqual(document.getElementById('spawnItemTemplateInput').disabled, false);
  stopTimers(window);
});

test('UI Integration - queued rewards are handed to the console while the page is open', async () => {
  const calls = [];
  const outboxRow = {
    id: '41',
    request_id: 'airdrop:00000000-0000-4000-8000-000000000041',
    player_id: '9001',
    reward_type: 'item',
    item_id: 'IronOre',
    amount: 50,
    quality: 0
  };
  let served = false;
  const window = loadPage(installedBridge(calls, {
    onQuery: (q) => {
      if (q.includes('FROM dune_airdrop.airdrop_reward_outbox')) {
        if (served) return { rows: [] };
        served = true;
        return { rows: [outboxRow] };
      }
      return null;
    }
  }));

  await waitFor(() => calls.some((c) => c.action === 'addon.storage.put'), 'watermark was never advanced');
  // JSON copy: objects built inside jsdom have a different Object prototype.
  const sent = JSON.parse(JSON.stringify(calls.find((c) => c.action === 'rewards.deliver').payload));
  assert.deepStrictEqual(sent, { requestId: outboxRow.request_id, playerId: '9001', type: 'item', itemId: 'IronOre', amount: 50, quality: 0 });
  const put = calls.find((c) => c.action === 'addon.storage.put').payload;
  assert.strictEqual(put.key, 'airdrop.outbox.watermark');
  assert.strictEqual(put.value.lastId, '41');
  await waitFor(() => /1 handed to the console/.test(window.document.getElementById('deliveryStatusLine').textContent), 'status line not updated');
  stopTimers(window);
});

test('UI Integration - upgrade report releases held rewards with fresh ids', async () => {
  const calls = [];
  const window = loadPage(installedBridge(calls, {
    onQuery: (q) => (q.includes("FILTER (WHERE state = 'held')") ? { rows: [{ held: 2, review: 0 }] } : null)
  }));
  const document = window.document;

  await waitFor(() => !document.getElementById('migrationReport').classList.contains('hidden'), 'upgrade report not shown');
  assert.match(document.getElementById('migrationSummary').textContent, /2 are held/);
  assert.ok(!document.getElementById('migrationHeldActions').classList.contains('hidden'));
  assert.ok(document.getElementById('migrationReviewActions').classList.contains('hidden'));

  document.getElementById('releaseHeldBtn').click();
  await waitFor(() => calls.some((c) => c.action === 'database.execute'), 'release not sent');
  const sql = calls.find((c) => c.action === 'database.execute').payload.query;
  assert.match(sql, /SET id = nextval\(pg_get_serial_sequence\('dune_airdrop\.airdrop_reward_queue', 'id'\)\)/);
  assert.match(sql, /WHERE state = 'held'/);
  stopTimers(window);
});

test('UI Integration - Clean install prompts for schema initialization', async () => {
  const queries = [];
  const window = loadPage(async (action, payload) => {
    queries.push({ action, payload });
    if (action === 'database.query' && payload.query.includes("to_regclass('dune_airdrop.airdrop_schema_version')")) {
      return { rows: [{ version_table: null }] };
    }
    return { rows: [] };
  });

  await waitFor(() => window.document.getElementById('connectionStatusBadge').textContent === 'Setup Required', 'Clean installation did not enter setup-required state');
  assert.ok(!queries.some((q) => q.action === 'database.query' && q.payload.query.includes('FROM dune_airdrop.airdrop_config')));
  assert.ok(!queries.some((q) => q.action === 'rewards.deliver'));
  assert.equal(window.__fetchDiagnosticsInterval, undefined);
  assert.equal(window.__fetchPendingInterval, undefined);
  assert.equal(window.__deliveryInterval, undefined);
});

test('UI Integration - Recovery paths (PENDING / UNCERTAIN)', async () => {
  const storage = {
    pending_manual_grant: JSON.stringify({
      id: 'manual:grant:test-uuid-123',
      status: 'PENDING',
      hash: JSON.stringify(['12345', 'TestSword', 3, 0, '9999999999999']),
      payload: { playerId: '12345', itemId: 'TestSword', quantity: 3, quality: 0, containerId: '9999999999999' }
    })
  };
  const calls = [];
  const window = loadPage(installedBridge(calls), { storage, uuid: () => 'test-uuid-123' });
  const document = window.document;

  await waitFor(() => document.getElementById('container-row-9999999999999'), 'containers did not load');
  if (window.selectContainer) await window.selectContainer('9999999999999');

  const templateInput = document.getElementById('spawnItemTemplateInput');
  const qtyInput = document.getElementById('spawnItemQtyInput');
  const discardBtn = document.getElementById('spawnItemDiscardBtn');

  assert.strictEqual(templateInput.disabled, true, 'Template input should be disabled');
  assert.strictEqual(qtyInput.disabled, true, 'Qty input should be disabled');
  assert.ok(!discardBtn.classList.contains('hidden'), 'Discard button should be visible');

  discardBtn.click();
  await new Promise((r) => setTimeout(r, 50));

  assert.strictEqual(window.localStorage.getItem('pending_manual_grant'), null, 'State should be cleared');
  assert.strictEqual(templateInput.disabled, false, 'Template input should be enabled after discard');
  assert.strictEqual(qtyInput.disabled, false, 'Qty input should be enabled after discard');
  stopTimers(window);
});
