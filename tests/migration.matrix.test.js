// Migration matrix: installs every historical Airdrop Manager layout into a
// real Postgres, seeds it, runs the v2 setup and checks the outcome.
//
// Needs a superuser connection URL (a throwaway server - databases named
// airdrop_t_* are created and dropped):
//   AIRDROP_TEST_DATABASE_URL=postgres://postgres:pw@127.0.0.1:55432/postgres npm test
// Optionally AIRDROP_GAME_SCHEMA_DUMP=<pg_dump --schema-only file> runs the
// same cases against a complete game schema instead of the minimal fixture.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ADMIN_URL = process.env.AIRDROP_TEST_DATABASE_URL;
const root = path.resolve(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const SETUP = read('setup_playtime_airdrops.sql');
const UNINSTALL = read('uninstall_playtime_airdrops.sql');
const LEGACY = ['v1.0.0', 'v1.2.1', 'v1.2.5', 'v1.3.3', 'v1.3.5', 'v1.3.6', 'v1.3.7', 'head-0a73fca'];
const legacySql = (name) => read(`tests/fixtures/legacy/${name}.sql`);
const TEMPLATE = 'airdrop_t_template';

const skip = ADMIN_URL ? false : 'set AIRDROP_TEST_DATABASE_URL to run the migration matrix';
const { Client } = ADMIN_URL ? require('pg') : {};

function urlFor(database, user = null) {
  const url = new URL(ADMIN_URL);
  url.pathname = `/${database}`;
  if (user) {
    url.username = user;
    url.password = user;
  }
  return url.toString();
}

async function withClient(database, user, fn) {
  const client = new Client({ connectionString: urlFor(database, user) });
  client.on('notice', () => {});
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end();
  }
}

const asAdmin = (sql, database = 'postgres') => withClient(database, null, (c) => c.query(sql));
// The console runs addon SQL as one simple-query string on a pooled
// connection, i.e. one implicit transaction. Do the same here.
const runAs = (database, user, sql) => withClient(database, user, (c) => c.query(sql));
const rows = async (database, sql) => (await withClient(database, null, (c) => c.query(sql))).rows;

let caseCounter = 0;
async function newCase() {
  const name = `airdrop_t_${process.pid}_${++caseCounter}`;
  await asAdmin(`DROP DATABASE IF EXISTS ${name}`);
  await asAdmin(`CREATE DATABASE ${name} TEMPLATE ${TEMPLATE} OWNER dune`);
  return name;
}

// Every object in the game schema, keyed so Funcom's objects can be compared
// before and after while addon-owned additions are recognised by name.
const SNAPSHOT_SQL = `
  SELECT 'proc:' || p.oid::regprocedure AS key, md5(p.prosrc) || '/' || pg_get_userbyid(p.proowner) AS val
    FROM pg_proc p WHERE p.pronamespace = 'dune'::regnamespace
  UNION ALL
  SELECT 'trigger:' || t.tgrelid::regclass || '.' || t.tgname, t.tgfoid::regprocedure || '/' || t.tgenabled::text
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
   WHERE NOT t.tgisinternal AND c.relnamespace = 'dune'::regnamespace
  UNION ALL
  SELECT 'rel:' || c.relname, c.relkind::text || '/' || pg_get_userbyid(c.relowner)
    FROM pg_class c WHERE c.relnamespace = 'dune'::regnamespace
  UNION ALL
  SELECT 'col:' || a.attrelid::regclass || '.' || a.attname, format_type(a.atttypid, a.atttypmod) || '/' || a.attnotnull
    FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
   WHERE c.relnamespace = 'dune'::regnamespace AND a.attnum > 0 AND NOT a.attisdropped
  UNION ALL
  SELECT 'con:' || con.conrelid::regclass || '.' || con.conname, pg_get_constraintdef(con.oid)
    FROM pg_constraint con WHERE con.connamespace = 'dune'::regnamespace
  UNION ALL
  SELECT 'type:' || t.typname, pg_get_userbyid(t.typowner)
    FROM pg_type t WHERE t.typnamespace = 'dune'::regnamespace`;

async function snapshot(database) {
  return Object.fromEntries((await rows(database, SNAPSHOT_SQL)).map((r) => [r.key, r.val]));
}

// Names only this addon (or the Discord bot it grew out of) ever created.
const ADDON_NAME = /(bot_(active_playtime|pending_deliveries|delivery_receipts)|discord_bot_config|airdrop|trg_(track_playtime|notify_pending_delivery|player_state_playtime|notify_airdrop)|fn_(get_pawn_tier|queue_reward_roll|roll_playtime_reward|deliver_playtime_airdrops|check_daily_weekly_rewards|manual_airdrop_spawn))/;

async function assertGameUntouched(database, baseline) {
  const after = await snapshot(database);
  for (const [key, val] of Object.entries(baseline)) {
    assert.equal(after[key], val, `game object changed or removed: ${key}`);
  }
  for (const key of Object.keys(after)) {
    if (key in baseline) continue;
    assert.match(key, ADDON_NAME, `unexpected new object in the game schema: ${key}`);
  }
}

// Seeds whatever airdrop tables the installed layout has: one owed reward,
// one delivered, one mid-delivery (when the layout tracks leases), an
// UNCERTAIN receipt on the owed one, a playtime row and custom settings.
async function seedLegacy(database, user = 'dune', only = null) {
  const pick = (t) => !only || only.includes(t);
  await withClient(database, user, async (c) => {
    const exists = async (t) => (await c.query('SELECT to_regclass($1) AS r', [t])).rows[0].r !== null;
    const cols = async (t) => (await c.query(
      `SELECT array_agg(column_name::text) AS c FROM information_schema.columns WHERE table_schema || '.' || table_name = $1`, [t]
    )).rows[0].c || [];
    const receipts = {
      'dune_airdrop.pending_deliveries': 'dune_airdrop.delivery_receipts',
      'dune.airdrop_pending_deliveries': 'dune.airdrop_delivery_receipts',
      'dune.bot_pending_deliveries': 'dune.bot_delivery_receipts'
    };
    for (const table of Object.keys(receipts)) {
      if (!pick(table) || !(await exists(table))) continue;
      const pc = await cols(table);
      await c.query(`INSERT INTO ${table} (account_id, template_id, stack_size, is_applied) VALUES (9001, 'OwedItem_1', 5, false)`);
      await c.query(`INSERT INTO ${table} (account_id, template_id, stack_size, is_applied) VALUES (9001, 'DeliveredItem_1', 1, true)`);
      if (pc.includes('locked_at')) {
        await c.query(`INSERT INTO ${table} (account_id, template_id, stack_size, is_applied, locked_at) VALUES (9001, 'InFlightItem_1', 2, false, now())`);
      }
      if (pc.includes('request_id')) {
        await c.query(`UPDATE ${table} SET request_id = gen_random_uuid() WHERE request_id IS NULL`);
        const rt = receipts[table];
        if (await exists(rt)) {
          const rc = await cols(rt);
          const owed = `SELECT request_id, account_id, template_id, stack_size FROM ${table} WHERE template_id = 'OwedItem_1' ORDER BY id DESC LIMIT 1`;
          if (rc.includes('account_id') && rc.includes('status')) {
            await c.query(`INSERT INTO ${rt} (request_id, account_id, template_id, quantity, status) SELECT request_id, account_id, template_id, stack_size, 'UNCERTAIN' FROM (${owed}) o`);
          } else if (rc.includes('status')) {
            await c.query(`INSERT INTO ${rt} (request_id, status) SELECT request_id, 'UNCERTAIN' FROM (${owed}) o`);
          }
        }
      }
    }
    for (const table of ['dune_airdrop.active_playtime', 'dune.airdrop_active_playtime', 'dune.bot_active_playtime']) {
      if (!pick(table) || !(await exists(table))) continue;
      await c.query(`INSERT INTO ${table} (character_id, active_seconds, last_active_at) VALUES (7001, 1234, now() - interval '1 day') ON CONFLICT DO NOTHING`);
    }
    for (const table of ['dune_airdrop.config', 'dune.airdrop_config', 'dune.discord_bot_config', 'dune.airdrop_addon_config']) {
      if (!pick(table) || !(await exists(table))) continue;
      await c.query(`INSERT INTO ${table} (config_key, config_value)
                     VALUES ('airdrop_multipliers', '{"playtime_interval":"45","use_daemon":true,"daemon_enabled":true,"weekly_enabled":"false"}')
                     ON CONFLICT (config_key) DO UPDATE SET config_value = EXCLUDED.config_value`);
      break;
    }
  });
}

async function queueStates(database) {
  const result = await rows(database, `SELECT template_id, state FROM dune_airdrop.airdrop_reward_queue ORDER BY legacy_ref`);
  return result.map((r) => `${r.template_id}=${r.state}`);
}

async function leftoverLegacyCode(database) {
  return (await rows(database, `
    SELECT p.oid::regprocedure::text AS name FROM pg_proc p
     WHERE p.pronamespace IN ('dune'::regnamespace, 'dune_airdrop'::regnamespace)
       AND p.proname ~ '^(fn_|trg_)'
    UNION ALL
    SELECT t.tgrelid::regclass || '.' || t.tgname FROM pg_trigger t
     WHERE NOT t.tgisinternal AND t.tgname IN ('trg_player_state_playtime', 'trg_notify_airdrop')`)).map((r) => r.name);
}

let baseline;

test.before(async () => {
  if (skip) return;
  await asAdmin(`DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dune') THEN
      CREATE ROLE dune LOGIN PASSWORD 'dune' NOSUPERUSER;
    END IF;
  END $$`);
  await asAdmin(`DROP DATABASE IF EXISTS ${TEMPLATE}`);
  await asAdmin(`CREATE DATABASE ${TEMPLATE} OWNER dune`);
  if (process.env.AIRDROP_GAME_SCHEMA_DUMP) {
    // pg_dump output may contain psql meta-commands; they are not SQL.
    const dump = fs.readFileSync(process.env.AIRDROP_GAME_SCHEMA_DUMP, 'utf8')
      .split(/\r?\n/).filter((line) => !line.startsWith('\\')).join('\n');
    await asAdmin(dump, TEMPLATE);
  } else {
    await runAs(TEMPLATE, 'dune', read('tests/fixtures/game-schema.sql'));
  }
  baseline = await snapshot(TEMPLATE);
});

test.after(async () => {
  if (skip) return;
  const leftovers = await rows('postgres', `SELECT datname FROM pg_database WHERE datname LIKE 'airdrop_t_%'`);
  for (const { datname } of leftovers) await asAdmin(`DROP DATABASE IF EXISTS ${datname}`);
});

test('fresh install: every object is prefixed, marked, and the game schema gains only the trigger', { skip }, async () => {
  const db = await newCase();
  await runAs(db, 'dune', SETUP);

  const unmarked = await rows(db, `
    SELECT 'rel ' || relname AS o FROM pg_class WHERE relnamespace = 'dune_airdrop'::regnamespace AND obj_description(oid, 'pg_class') IS NULL
    UNION ALL SELECT 'fn ' || proname FROM pg_proc WHERE pronamespace = 'dune_airdrop'::regnamespace AND obj_description(oid, 'pg_proc') IS NULL
    UNION ALL SELECT 'con ' || conname FROM pg_constraint WHERE connamespace = 'dune_airdrop'::regnamespace AND obj_description(oid, 'pg_constraint') IS NULL
    UNION ALL SELECT 'name ' || relname FROM pg_class WHERE relnamespace = 'dune_airdrop'::regnamespace AND relname !~ '^airdrop_'
    UNION ALL SELECT 'name ' || proname FROM pg_proc WHERE pronamespace = 'dune_airdrop'::regnamespace AND proname !~ '^airdrop_'
    UNION ALL SELECT 'name ' || conname FROM pg_constraint WHERE connamespace = 'dune_airdrop'::regnamespace AND conname !~ '^airdrop_'`);
  assert.deepEqual(unmarked, []);

  const marked = await rows(db, `SELECT count(*)::int AS n FROM pg_description WHERE description LIKE 'dune-airdrop-addon|v2|%'`);
  assert.ok(marked[0].n >= 40, `expected the full marked set, got ${marked[0].n}`);

  const trigger = await rows(db, `
    SELECT t.tgname, t.tgfoid::regprocedure::text AS fn, obj_description(t.oid, 'pg_trigger') AS marker
      FROM pg_trigger t WHERE t.tgrelid = 'dune.encrypted_player_state'::regclass AND NOT t.tgisinternal`);
  assert.deepEqual(trigger.map((t) => [t.tgname, t.fn]), [['dune_airdrop_track_playtime', 'dune_airdrop.airdrop_track_playtime()']]);
  assert.match(trigger[0].marker, /^dune-airdrop-addon\|v2\|playtime-trigger/);

  const after = await snapshot(db);
  const added = Object.keys(after).filter((k) => !(k in baseline));
  assert.deepEqual(added, ['trigger:dune.encrypted_player_state.dune_airdrop_track_playtime']);
  await assertGameUntouched(db, baseline);

  const outbox = await rows(db, 'SELECT count(*)::int AS n FROM dune_airdrop.airdrop_reward_outbox');
  assert.equal(outbox[0].n, 0);
});

test('setup is idempotent', { skip }, async () => {
  const db = await newCase();
  await runAs(db, 'dune', SETUP);
  const first = await rows(db, 'SELECT count(*)::int AS n FROM dune_airdrop.airdrop_loot_table');
  await runAs(db, 'dune', SETUP);
  const second = await rows(db, 'SELECT count(*)::int AS n FROM dune_airdrop.airdrop_loot_table');
  assert.equal(second[0].n, first[0].n);
  assert.ok(first[0].n > 1000);
  const version = await rows(db, 'SELECT version, addon_version FROM dune_airdrop.airdrop_schema_version');
  assert.deepEqual(version.map((v) => [v.version, v.addon_version]), [[2, '1.4.0']]);
});

for (const legacy of LEGACY) {
  test(`migrates ${legacy}: owed rewards held, nothing auto-delivered, legacy code removed`, { skip }, async () => {
    const db = await newCase();
    await runAs(db, 'dune', legacySql(legacy));
    await seedLegacy(db);
    await runAs(db, 'dune', SETUP);

    const states = await queueStates(db);
    assert.ok(states.includes('DeliveredItem_1=legacy_done'), states.join(','));
    const owed = states.find((s) => s.startsWith('OwedItem_1='));
    // Layouts with receipts carry an UNCERTAIN receipt on the owed row.
    const hasReceipts = !['v1.0.0', 'v1.2.1', 'v1.2.5', 'v1.3.3'].includes(legacy);
    assert.equal(owed, hasReceipts ? 'OwedItem_1=review' : 'OwedItem_1=held');
    if (legacy !== 'v1.0.0' && legacy !== 'v1.2.1') {
      assert.ok(states.includes('InFlightItem_1=review'), states.join(','));
    }
    const outbox = await rows(db, 'SELECT count(*)::int AS n FROM dune_airdrop.airdrop_reward_outbox');
    assert.equal(outbox[0].n, 0, 'imported rewards must never be delivered without an operator releasing them');

    const progress = await rows(db, 'SELECT character_id::text AS id, active_seconds FROM dune_airdrop.airdrop_player_progress');
    assert.deepEqual(progress.map((p) => [p.id, p.active_seconds]), [['7001', 1234]]);

    const cfg = await rows(db, `SELECT config_value FROM dune_airdrop.airdrop_config WHERE config_key = 'airdrop_multipliers'`);
    assert.equal(cfg[0].config_value.playtime_interval, 45);
    assert.equal(cfg[0].config_value.weekly_enabled, false);
    assert.equal('use_daemon' in cfg[0].config_value, false);
    assert.equal('daemon_enabled' in cfg[0].config_value, false);

    assert.deepEqual(await leftoverLegacyCode(db), []);
    await assertGameUntouched(db, baseline);

    // Re-running imports nothing twice.
    const before = await rows(db, 'SELECT count(*)::int AS n FROM dune_airdrop.airdrop_reward_queue');
    await runAs(db, 'dune', SETUP);
    const again = await rows(db, 'SELECT count(*)::int AS n FROM dune_airdrop.airdrop_reward_queue');
    assert.equal(again[0].n, before[0].n);
  });
}

test('stacked upgrade v1.3.5 -> v1.3.6 -> v1.3.7 -> HEAD keeps every owed row exactly once', { skip }, async () => {
  const db = await newCase();
  await runAs(db, 'dune', legacySql('v1.3.5'));
  await seedLegacy(db, 'dune', ['dune.bot_pending_deliveries', 'dune.bot_active_playtime', 'dune.discord_bot_config']);
  await runAs(db, 'dune', legacySql('v1.3.6'));
  await seedLegacy(db, 'dune', ['dune.airdrop_pending_deliveries']);
  await runAs(db, 'dune', legacySql('v1.3.7'));
  await seedLegacy(db, 'dune', ['dune_airdrop.pending_deliveries']);
  await runAs(db, 'dune', legacySql('head-0a73fca'));
  await seedLegacy(db, 'dune', ['dune.bot_pending_deliveries']);

  await runAs(db, 'dune', SETUP);

  // bot_* seeded twice (6), v1.3.6 table (3, also copied forward by v1.3.7
  // with the same request ids), v1.3.7 table's own rows (3).
  const total = await rows(db, `SELECT count(*)::int AS n, count(DISTINCT request_id)::int AS d FROM dune_airdrop.airdrop_reward_queue`);
  assert.equal(total[0].n, 12);
  assert.equal(total[0].d, 12);
  assert.deepEqual(await leftoverLegacyCode(db), []);
  await assertGameUntouched(db, baseline);
});

test('postgres-owned legacy objects: a dune run logs manual steps, a postgres re-run completes them', { skip }, async () => {
  const db = await newCase();
  await asAdmin(legacySql('v1.3.5'), db);
  await seedLegacy(db, null);

  await runAs(db, 'dune', SETUP);
  const manual = await rows(db, `SELECT detail FROM dune_airdrop.airdrop_migration_log WHERE level = 'manual'`);
  assert.ok(manual.length > 0, 'expected manual steps for postgres-owned objects');
  assert.ok(manual.some((m) => /re-run setup as postgres|run as postgres/.test(m.detail)));

  await asAdmin(SETUP, db);
  assert.deepEqual(await leftoverLegacyCode(db), []);
  const states = await queueStates(db);
  assert.ok(states.includes('OwedItem_1=review'), states.join(','));
  const owners = await rows(db, `
    SELECT DISTINCT pg_get_userbyid(relowner) AS o FROM pg_class WHERE relnamespace = 'dune_airdrop'::regnamespace
    UNION SELECT DISTINCT pg_get_userbyid(proowner) FROM pg_proc WHERE pronamespace = 'dune_airdrop'::regnamespace`);
  assert.deepEqual(owners.map((o) => o.o), ['dune'], 'every v2 object must be owned by dune even when run as postgres');
  await assertGameUntouched(db, baseline);
});

test('possibly shared legacy tables and foreign config keys are left untouched', { skip }, async () => {
  const db = await newCase();
  await runAs(db, 'dune', legacySql('v1.3.5'));
  await seedLegacy(db);
  await runAs(db, 'dune', `INSERT INTO dune.discord_bot_config (config_key, config_value) VALUES ('gameplay_settings', '{"xp_multiplier": 2}')`);
  const before = await rows(db, `SELECT config_key, config_value::text AS v FROM dune.discord_bot_config ORDER BY 1`);
  const botRows = await rows(db, `SELECT count(*)::int AS n FROM dune.bot_pending_deliveries`);

  await runAs(db, 'dune', SETUP);

  assert.deepEqual(await rows(db, `SELECT config_key, config_value::text AS v FROM dune.discord_bot_config ORDER BY 1`), before);
  assert.deepEqual(await rows(db, `SELECT count(*)::int AS n FROM dune.bot_pending_deliveries`), botRows);
});

test('refuses to run while the retired daemon is still heartbeating, and changes nothing', { skip }, async () => {
  const db = await newCase();
  await runAs(db, 'dune', legacySql('v1.3.7'));
  await runAs(db, 'dune', `UPDATE dune_airdrop.config SET config_value = jsonb_build_object('last_ping', now()) WHERE config_key = 'daemon_heartbeat'`);
  await assert.rejects(runAs(db, 'dune', SETUP), /daemon is still running/);
  const v2 = await rows(db, `SELECT to_regclass('dune_airdrop.airdrop_reward_queue') AS r`);
  assert.equal(v2[0].r, null);
});

test('decoys: same-named objects that are not ours survive', { skip }, async () => {
  const db = await newCase();
  await runAs(db, 'dune', `
    CREATE FUNCTION dune.fn_get_pawn_tier(bigint) RETURNS int LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END $$;
    CREATE FUNCTION dune.decoy_trigger_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
    CREATE TRIGGER trg_player_state_playtime AFTER UPDATE ON dune.encrypted_player_state
      FOR EACH ROW EXECUTE FUNCTION dune.decoy_trigger_fn();`);
  const decoyBaseline = await snapshot(db);

  await runAs(db, 'dune', SETUP);

  const after = await snapshot(db);
  assert.equal(after['proc:dune.fn_get_pawn_tier(bigint)'], decoyBaseline['proc:dune.fn_get_pawn_tier(bigint)']);
  assert.equal(after['trigger:dune.encrypted_player_state.trg_player_state_playtime'],
    decoyBaseline['trigger:dune.encrypted_player_state.trg_player_state_playtime']);
  const warned = await rows(db, `SELECT detail FROM dune_airdrop.airdrop_migration_log WHERE level = 'warn'`);
  assert.ok(warned.some((w) => w.detail.includes('fn_get_pawn_tier(bigint)')));
});

test('aborts without changes if a foreign trigger already uses the v2 trigger name', { skip }, async () => {
  const db = await newCase();
  await runAs(db, 'dune', `
    CREATE FUNCTION dune.decoy_trigger_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
    CREATE TRIGGER dune_airdrop_track_playtime AFTER UPDATE ON dune.encrypted_player_state
      FOR EACH ROW EXECUTE FUNCTION dune.decoy_trigger_fn();`);
  await assert.rejects(runAs(db, 'dune', SETUP), /not this addon's function/);
  const schema = await rows(db, `SELECT to_regnamespace('dune_airdrop') AS s`);
  assert.equal(schema[0].s, null);
});

test('uninstall after migrating leaves every game object exactly as it was', { skip }, async () => {
  const db = await newCase();
  await runAs(db, 'dune', legacySql('v1.3.7'));
  await seedLegacy(db);
  await runAs(db, 'dune', SETUP);
  await runAs(db, 'dune', UNINSTALL);

  const schemas = await rows(db, `SELECT nspname FROM pg_namespace WHERE nspname LIKE 'dune_airdrop%'`);
  assert.deepEqual(schemas, []);
  await assertGameUntouched(db, baseline);
  const after = await snapshot(db);
  assert.deepEqual(Object.keys(after).filter((k) => !(k in baseline)), [], 'uninstall must leave nothing of a v1.3.7+ install behind');
});

test('uninstall refuses to cascade into objects outside the addon', { skip }, async () => {
  const db = await newCase();
  await runAs(db, 'dune', SETUP);
  await runAs(db, 'dune', `CREATE VIEW dune.someone_elses_view AS SELECT id FROM dune_airdrop.airdrop_reward_queue`);
  await assert.rejects(runAs(db, 'dune', UNINSTALL), /Uninstall aborted without changes/);
  const still = await rows(db, `SELECT to_regclass('dune.someone_elses_view') AS v, to_regnamespace('dune_airdrop') AS s`);
  assert.notEqual(still[0].v, null);
  assert.notEqual(still[0].s, null);
});

test('releasing held rewards puts them past the watermark; discarding queued ones spares handed-over rows', { skip }, async () => {
  const { releaseQuery, discardQuery, outboxQuery } = require('../web/outbox_drain.js');
  const db = await newCase();
  await runAs(db, 'dune', legacySql('v1.3.5'));
  await seedLegacy(db);
  await runAs(db, 'dune', SETUP);

  // New rewards arrive and the page hands them over, moving the watermark
  // beyond every imported row.
  await runAs(db, 'dune', `
    INSERT INTO dune_airdrop.airdrop_reward_queue (account_id, template_id, stack_size, source, created_at)
    SELECT 9001, 'NewItem_' || g, 1, 'playtime', now() - interval '5 minutes' FROM generate_series(1, 3) g`);
  const watermark = (await rows(db, `SELECT max(id)::text AS id FROM dune_airdrop.airdrop_reward_queue`))[0].id;
  const held = await rows(db, `SELECT id::text AS id FROM dune_airdrop.airdrop_reward_queue WHERE state IN ('held', 'review')`);
  assert.ok(held.length > 0 && held.every((h) => BigInt(h.id) < BigInt(watermark)));

  await runAs(db, 'dune', releaseQuery('review'));
  const released = await rows(db, `SELECT id::text AS id FROM dune_airdrop.airdrop_reward_queue WHERE note LIKE '%released%'`);
  assert.ok(released.length > 0);
  assert.ok(released.every((r) => BigInt(r.id) > BigInt(watermark)), 'released rows must sort after the watermark');
  // Make them old enough for the drain's one-minute rule, then drain.
  await runAs(db, 'dune', `UPDATE dune_airdrop.airdrop_reward_queue SET created_at = now() - interval '5 minutes'`);
  const outbox = await rows(db, outboxQuery(watermark));
  assert.equal(outbox.length, released.length);

  // A newer unsent reward, then "clear queue" at the current watermark.
  await runAs(db, 'dune', `INSERT INTO dune_airdrop.airdrop_reward_queue (account_id, template_id, stack_size, source) VALUES (9001, 'Unsent_1', 1, 'daily')`);
  const handedOver = await rows(db, `SELECT count(*)::int AS n FROM dune_airdrop.airdrop_reward_queue WHERE state = 'queued' AND id <= ${watermark}`);
  await runAs(db, 'dune', discardQuery('queued', watermark));
  const after = await rows(db, `SELECT count(*)::int AS n FROM dune_airdrop.airdrop_reward_queue WHERE state = 'queued' AND id <= ${watermark}`);
  assert.equal(after[0].n, handedOver[0].n, 'rows the console already owns must not be touched');
  const unsent = await rows(db, `SELECT state FROM dune_airdrop.airdrop_reward_queue WHERE template_id = 'Unsent_1'`);
  assert.equal(unsent[0].state, 'discarded');
  assert.throws(() => discardQuery('queued'), /outbox position/);
});

test('trigger: login, active play, AFK, throttle, logout, and a broken config never blocks a save', { skip }, async () => {
  const db = await newCase();
  await runAs(db, 'dune', SETUP);
  const q = (sql) => runAs(db, 'dune', sql);
  await q(`
    INSERT INTO dune.encrypted_accounts (id, "user") VALUES (9001, 'fls-9001');
    INSERT INTO dune.actors (id, class, transform) VALUES (7001, 'BP_Pawn', ROW(ROW(0,0,0)::dune.vector, NULL)::dune.transform);
    INSERT INTO dune.fgl_entities (entity_id, components) VALUES (8001, '{"FLevelComponent":[[],{"TotalXPEarned":30000}]}');
    INSERT INTO dune.actor_fgl_entities (actor_id, entity_id, slot_name) VALUES (7001, 8001, 'DuneCharacter');
    INSERT INTO dune.encrypted_player_state (id, account_id, encrypted_character_name, player_pawn_id, online_status)
    VALUES (6001, 9001, dune.encrypt_user_data('Tester'), 7001, 'Offline');`);
  const count = async (source) => (await rows(db, `SELECT count(*)::int AS n FROM dune_airdrop.airdrop_reward_queue WHERE source = '${source}'`))[0].n;
  const progress = async () => (await rows(db, 'SELECT * FROM dune_airdrop.airdrop_player_progress WHERE character_id = 7001'))[0];

  await q(`UPDATE dune.encrypted_player_state SET online_status = 'Online' WHERE id = 6001`);
  assert.ok(await count('daily') > 0, 'first online save rolls the daily reward');
  assert.equal((await progress()).consecutive_days, 1);
  // 30000 XP is level 51 on the console's curve, tier 3 (levels 50-79).
  assert.equal((await rows(db, 'SELECT dune_airdrop.airdrop_pawn_tier(7001) AS t'))[0].t, 3);

  for (let i = 1; i <= 14; i += 1) {
    await q(`UPDATE dune_airdrop.airdrop_player_progress SET last_active_at = now() - interval '5 minutes' WHERE character_id = 7001;
             UPDATE dune.actors SET transform = ROW(ROW(${i * 100}, 0, 0)::dune.vector, NULL)::dune.transform WHERE id = 7001;
             UPDATE dune.encrypted_player_state SET last_avatar_activity = now() WHERE id = 6001;`);
  }
  assert.ok(await count('playtime') > 0, '70 active minutes rolls one playtime reward');
  assert.equal((await progress()).active_seconds, 600);

  await q(`UPDATE dune_airdrop.airdrop_player_progress SET last_active_at = now() - interval '5 minutes', active_seconds = 100 WHERE character_id = 7001;
           UPDATE dune.encrypted_player_state SET last_avatar_activity = now() WHERE id = 6001;`);
  assert.equal((await progress()).active_seconds, 100, 'standing still earns nothing');

  await q(`UPDATE dune.encrypted_player_state SET last_avatar_activity = now() WHERE id = 6001`);
  assert.equal((await progress()).active_seconds, 100, 'a second save inside a minute is ignored');

  await q(`UPDATE dune.encrypted_player_state SET online_status = 'Offline' WHERE id = 6001`);
  assert.equal((await progress()).last_active_at, null);

  const outbox = await rows(db, 'SELECT * FROM dune_airdrop.airdrop_reward_outbox');
  assert.ok(outbox.length > 0);
  for (const row of outbox) {
    assert.match(row.request_id, /^airdrop:[0-9a-f-]{36}$/);
    assert.equal(row.player_id, '9001');
    assert.equal(row.reward_type, 'item');
    assert.ok(row.amount >= 1 && row.amount <= 1000);
  }

  await q(`UPDATE dune_airdrop.airdrop_config SET config_value = '{"playtime_interval":"oops"}' WHERE config_key = 'airdrop_multipliers';
           UPDATE dune_airdrop.airdrop_player_progress SET last_active_at = now() - interval '5 minutes' WHERE character_id = 7001;`);
  await q(`UPDATE dune.encrypted_player_state SET online_status = 'Online' WHERE id = 6001`);
  const saved = await rows(db, 'SELECT online_status::text AS s FROM dune.encrypted_player_state WHERE id = 6001');
  assert.equal(saved[0].s, 'Online');
});
