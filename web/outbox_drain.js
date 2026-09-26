// Hands queued rewards from dune_airdrop.airdrop_reward_outbox to the
// console's reward runtime (rewards.deliver) while the Airdrop Manager page is
// open. The console owns each reward once handed over: it waits for the
// player to come online, retries, and never delivers a requestId twice.
//
// Progress is a watermark (the highest outbox id handed over) kept in addon
// storage, so draining never writes to the database - database writes through
// the bridge take a full backup first.

const OUTBOX_WATERMARK_KEY = 'airdrop.outbox.watermark';
// The console allows 20 reward submissions a minute per session; one cycle
// stays under that with room for manual grants.
const OUTBOX_BATCH_LIMIT = 15;
// Rows younger than this are left for the next cycle so a trigger transaction
// that commits late can never be skipped by the watermark (and new arrivals
// get past the game's loading screen before delivery).
const OUTBOX_MIN_AGE_SECONDS = 60;

// Rejections that can never succeed for this row, so retrying would block
// the queue forever. Anything else (rate limits, permissions, timeouts,
// console storage limits) stops the cycle without advancing.
const PERMANENT_REJECTIONS = [
  /Delivery requestId must be/i,
  /Delivery must target one valid player ID/i,
  /Reward itemId is invalid/i,
  /must be an integer from \d+ through \d+/i,
  /Reward type must be/i,
  /requestId was already used with different delivery details/i
];

function isPermanentRejection(error) {
  const message = String((error && error.message) || error || '');
  return PERMANENT_REJECTIONS.some((pattern) => pattern.test(message));
}

function isStorageConflict(error) {
  return /Addon storage value changed/i.test(String((error && error.message) || error || ''));
}

function parseWatermark(entry) {
  const lastId = entry && entry.value && entry.value.lastId;
  const text = String(lastId === undefined || lastId === null ? '0' : lastId);
  return /^[0-9]{1,18}$/.test(text) ? text : '0';
}

function outboxQuery(watermark, limit = OUTBOX_BATCH_LIMIT) {
  const after = /^[0-9]{1,18}$/.test(String(watermark)) ? String(watermark) : '0';
  const size = Number.isInteger(limit) && limit > 0 && limit <= 100 ? limit : OUTBOX_BATCH_LIMIT;
  return `SELECT id::text AS id, request_id, player_id, reward_type, item_id, amount, quality
            FROM dune_airdrop.airdrop_reward_outbox
           WHERE id > ${after}
             AND created_at <= now() - interval '${OUTBOX_MIN_AGE_SECONDS} seconds'
           ORDER BY id
           LIMIT ${size}`;
}

function toDeliverPayload(row) {
  return {
    requestId: String(row.request_id),
    playerId: String(row.player_id),
    type: String(row.reward_type || 'item'),
    itemId: String(row.item_id),
    amount: Number(row.amount),
    quality: Number(row.quality || 0)
  };
}

function laterId(a, b) {
  return BigInt(a) >= BigInt(b) ? String(a) : String(b);
}

async function readWatermark(request) {
  const entry = await request('addon.storage.get', { key: OUTBOX_WATERMARK_KEY });
  return {
    watermark: parseWatermark(entry),
    version: entry && entry.found ? entry.version : null
  };
}

// Stores lastId unless someone else (another open page, or the console's
// scheduled job) already moved past it. Returns the stored watermark.
async function advanceWatermark(request, state, lastId, now = () => new Date()) {
  let current = state;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (BigInt(current.watermark) >= BigInt(lastId)) return current.watermark;
    try {
      await request('addon.storage.put', {
        key: OUTBOX_WATERMARK_KEY,
        value: { lastId: String(lastId), updatedAt: now().toISOString() },
        expectedVersion: current.version
      });
      return String(lastId);
    } catch (error) {
      if (!isStorageConflict(error)) throw error;
      current = await readWatermark(request);
    }
  }
  throw new Error('Could not save the outbox position after repeated conflicts.');
}

// One drain cycle. `request` is window.DuneAddon.request (or a test double).
async function drainOutboxOnce(request, { limit = OUTBOX_BATCH_LIMIT, now } = {}) {
  const state = await readWatermark(request);
  const result = await request('database.query', { query: outboxQuery(state.watermark, limit) });
  const rows = (result && result.rows) || [];

  const summary = { handedOver: 0, skipped: [], stoppedBy: null, watermark: state.watermark, examined: rows.length };
  let lastDone = state.watermark;

  for (const row of rows) {
    try {
      await request('rewards.deliver', toDeliverPayload(row));
      summary.handedOver += 1;
      lastDone = laterId(lastDone, row.id);
    } catch (error) {
      if (isPermanentRejection(error)) {
        summary.skipped.push({ id: String(row.id), requestId: String(row.request_id), error: String(error.message || error) });
        lastDone = laterId(lastDone, row.id);
        continue;
      }
      summary.stoppedBy = String((error && error.message) || error);
      break;
    }
  }

  if (lastDone !== state.watermark) {
    summary.watermark = await advanceWatermark(request, state, lastDone, now);
  }
  return summary;
}

// Queue maintenance statements, shared by the page and the tests. These are
// plain UPDATEs because the console runs a SELECT of a function read-only.
const RELEASABLE_STATES = ['held', 'review'];

// Released rows get a fresh id so they land after the watermark; keeping
// their old (lower) id would leave them queued but never handed over.
function releaseQuery(fromState) {
  if (!RELEASABLE_STATES.includes(fromState)) throw new Error('Only held or uncertain rewards can be released.');
  return `UPDATE dune_airdrop.airdrop_reward_queue
             SET id = nextval(pg_get_serial_sequence('dune_airdrop.airdrop_reward_queue', 'id')),
                 state = 'queued',
                 state_changed_at = now(),
                 note = concat_ws('; ', note, 'released from the upgrade report')
           WHERE state = '${fromState}'`;
}

// Queued rows keep state 'queued' after the console takes them; only the
// watermark separates the two, so discarding queued rows requires it.
function discardQuery(fromState, afterId = null) {
  if (![...RELEASABLE_STATES, 'queued'].includes(fromState)) throw new Error('Unknown reward state.');
  if (fromState === 'queued' && !/^[0-9]{1,18}$/.test(String(afterId))) {
    throw new Error('Discarding queued rewards needs the current outbox position.');
  }
  const after = afterId === null ? '' : ` AND id > ${/^[0-9]{1,18}$/.test(String(afterId)) ? String(afterId) : '0'}`;
  return `UPDATE dune_airdrop.airdrop_reward_queue
             SET state = 'discarded',
                 state_changed_at = now(),
                 note = concat_ws('; ', note, 'discarded from the Airdrop page')
           WHERE state = '${fromState}'${after}`;
}

if (typeof module !== 'undefined') {
  module.exports = {
    releaseQuery,
    discardQuery,
    OUTBOX_WATERMARK_KEY,
    OUTBOX_BATCH_LIMIT,
    OUTBOX_MIN_AGE_SECONDS,
    isPermanentRejection,
    parseWatermark,
    outboxQuery,
    toDeliverPayload,
    readWatermark,
    advanceWatermark,
    drainOutboxOnce
  };
}
