const test = require('node:test');
const assert = require('node:assert/strict');
const drain = require('../web/outbox_drain.js');

// A fake bridge: in-memory addon storage with compare-and-swap, a fixed
// outbox, and a scriptable rewards.deliver.
function fakeBridge({ rows = [], watermark = null, deliver = () => ({ status: 'pending' }) } = {}) {
  const calls = [];
  const storage = new Map();
  if (watermark !== null) storage.set(drain.OUTBOX_WATERMARK_KEY, { value: { lastId: watermark }, version: 1 });
  const bridge = async (action, payload) => {
    calls.push({ action, payload });
    if (action === 'addon.storage.get') {
      const entry = storage.get(payload.key);
      return entry ? { found: true, key: payload.key, version: entry.version, value: entry.value } : { found: false, key: payload.key, version: 0, value: null };
    }
    if (action === 'addon.storage.put') {
      const entry = storage.get(payload.key);
      const ok = payload.expectedVersion === null ? !entry : entry && entry.version === payload.expectedVersion;
      if (!ok) throw new Error('Addon storage value changed. Read it again before saving.');
      storage.set(payload.key, { value: payload.value, version: entry ? entry.version + 1 : 1 });
      return { version: storage.get(payload.key).version };
    }
    if (action === 'database.query') {
      const after = BigInt(/id > (\d+)/.exec(payload.query)[1]);
      const limit = Number(/LIMIT (\d+)/.exec(payload.query)[1]);
      return { rows: rows.filter((r) => BigInt(r.id) > after).slice(0, limit) };
    }
    if (action === 'rewards.deliver') return deliver(payload);
    throw new Error(`unexpected action ${action}`);
  };
  return { bridge, calls, storage };
}

const row = (id, extra = {}) => ({
  id: String(id),
  request_id: `airdrop:00000000-0000-4000-8000-${String(id).padStart(12, '0')}`,
  player_id: '9001',
  reward_type: 'item',
  item_id: `Item_${id}`,
  amount: 5,
  quality: 0,
  ...extra
});

test('hands rows over in id order and advances the watermark to the last one', async () => {
  const { bridge, calls, storage } = fakeBridge({ rows: [row(1), row(2), row(3)] });
  const summary = await drain.drainOutboxOnce(bridge);
  assert.equal(summary.handedOver, 3);
  assert.equal(summary.watermark, '3');
  assert.deepEqual(calls.filter((c) => c.action === 'rewards.deliver').map((c) => c.payload.itemId), ['Item_1', 'Item_2', 'Item_3']);
  assert.equal(storage.get(drain.OUTBOX_WATERMARK_KEY).value.lastId, '3');
});

test('sends the exact rewards.deliver payload shape', async () => {
  const { bridge, calls } = fakeBridge({ rows: [row(7, { amount: '12', quality: '2' })] });
  await drain.drainOutboxOnce(bridge);
  const sent = calls.find((c) => c.action === 'rewards.deliver').payload;
  assert.deepEqual(sent, {
    requestId: 'airdrop:00000000-0000-4000-8000-000000000007',
    playerId: '9001',
    type: 'item',
    itemId: 'Item_7',
    amount: 12,
    quality: 2
  });
});

test('resumes after the stored watermark', async () => {
  const { bridge, calls } = fakeBridge({ rows: [row(4), row(5), row(6)], watermark: '5' });
  const summary = await drain.drainOutboxOnce(bridge);
  assert.equal(summary.handedOver, 1);
  assert.equal(calls.find((c) => c.action === 'rewards.deliver').payload.itemId, 'Item_6');
});

test('a transient failure stops the cycle without advancing past the failed row', async () => {
  const { bridge, storage } = fakeBridge({
    rows: [row(1), row(2), row(3)],
    deliver: (p) => { if (p.itemId === 'Item_2') throw new Error('Bridge rate limit exceeded. Try again in 12s.'); return {}; }
  });
  const summary = await drain.drainOutboxOnce(bridge);
  assert.equal(summary.handedOver, 1);
  assert.match(summary.stoppedBy, /rate limit/);
  assert.equal(storage.get(drain.OUTBOX_WATERMARK_KEY).value.lastId, '1');
});

test('permission and unknown errors are treated as transient, never skipped', async () => {
  for (const message of ['Addon permission rewards:grant is not approved.', 'Bridge request timed out.', 'Addon delivery history cannot exceed 100000 records.']) {
    const { bridge, storage } = fakeBridge({ rows: [row(1)], deliver: () => { throw new Error(message); } });
    const summary = await drain.drainOutboxOnce(bridge);
    assert.equal(summary.skipped.length, 0, message);
    assert.equal(storage.has(drain.OUTBOX_WATERMARK_KEY), false, message);
  }
});

test('a permanently invalid row is skipped and recorded so it cannot block the queue', async () => {
  const { bridge } = fakeBridge({
    rows: [row(1), row(2), row(3)],
    deliver: (p) => { if (p.itemId === 'Item_2') throw new Error('Reward itemId is invalid.'); return {}; }
  });
  const summary = await drain.drainOutboxOnce(bridge);
  assert.equal(summary.handedOver, 2);
  assert.deepEqual(summary.skipped.map((s) => s.id), ['2']);
  assert.equal(summary.watermark, '3');
});

test('honours the batch limit', async () => {
  const rows = Array.from({ length: 40 }, (_, i) => row(i + 1));
  const { bridge } = fakeBridge({ rows });
  const summary = await drain.drainOutboxOnce(bridge);
  assert.equal(summary.handedOver, drain.OUTBOX_BATCH_LIMIT);
  assert.equal(summary.watermark, String(drain.OUTBOX_BATCH_LIMIT));
});

test('the query only selects rows at least a minute old, in id order', () => {
  const sql = drain.outboxQuery('42');
  assert.match(sql, /FROM dune_airdrop\.airdrop_reward_outbox/);
  assert.match(sql, /id > 42/);
  assert.match(sql, /created_at <= now\(\) - interval '60 seconds'/);
  assert.match(sql, /ORDER BY id/);
});

test('the query never interpolates a non-numeric watermark', () => {
  assert.match(drain.outboxQuery("1; DROP TABLE x"), /id > 0\b/);
  assert.equal(drain.parseWatermark({ value: { lastId: '5 OR 1=1' } }), '0');
});

test('a concurrent drain that already moved further is respected, not rewound', async () => {
  const { bridge, storage } = fakeBridge({ rows: [row(1), row(2)] });
  // Another page stores watermark 10 between our read and our write.
  const racing = async (action, payload) => {
    if (action === 'addon.storage.put' && !storage.has(drain.OUTBOX_WATERMARK_KEY)) {
      storage.set(drain.OUTBOX_WATERMARK_KEY, { value: { lastId: '10' }, version: 1 });
    }
    return bridge(action, payload);
  };
  const summary = await drain.drainOutboxOnce(racing);
  assert.equal(summary.watermark, '10');
  assert.equal(storage.get(drain.OUTBOX_WATERMARK_KEY).value.lastId, '10');
});

test('a conflicting write is retried against the fresh version', async () => {
  const { bridge, storage } = fakeBridge({ rows: [row(1), row(2), row(3)], watermark: '0' });
  let bumped = false;
  const racing = async (action, payload) => {
    if (action === 'addon.storage.put' && !bumped) {
      bumped = true;
      storage.set(drain.OUTBOX_WATERMARK_KEY, { value: { lastId: '1' }, version: 2 });
    }
    return bridge(action, payload);
  };
  const summary = await drain.drainOutboxOnce(racing);
  assert.equal(summary.watermark, '3');
  assert.equal(storage.get(drain.OUTBOX_WATERMARK_KEY).version, 3);
});

test('an empty outbox makes no writes', async () => {
  const { bridge, calls } = fakeBridge({ rows: [] });
  const summary = await drain.drainOutboxOnce(bridge);
  assert.equal(summary.handedOver, 0);
  assert.equal(calls.some((c) => c.action === 'addon.storage.put'), false);
});
