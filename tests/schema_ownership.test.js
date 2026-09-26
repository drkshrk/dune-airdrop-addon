// Static guards on the SQL: every object is identifiable as this addon's and
// nothing in the game schema is modified. tests/migration.matrix.test.js
// proves the same properties against a real database.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const setupSql = fs.readFileSync(path.join(root, 'setup_playtime_airdrops.sql'), 'utf8');
const uninstallSql = fs.readFileSync(path.join(root, 'uninstall_playtime_airdrops.sql'), 'utf8');

// Statements outside dollar-quoted bodies, so function and DO bodies do not
// produce false matches.
function topLevel(sql) {
  return sql.replace(/\$([A-Za-z_]*)\$[\s\S]*?\$\1\$/g, ' ').replace(/--[^\n]*/g, ' ');
}

test('every created object lives in dune_airdrop with the airdrop_ prefix, except the one game-table trigger', () => {
  const creates = [...topLevel(setupSql).matchAll(/CREATE\s+(?:OR\s+REPLACE\s+)?(TABLE|VIEW|FUNCTION|INDEX|SEQUENCE|TYPE|TRIGGER|SCHEMA)\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z0-9_."]+)/gi)];
  assert.ok(creates.length > 10);
  for (const [, kind, name] of creates) {
    if (/^SCHEMA$/i.test(kind)) {
      assert.equal(name, 'dune_airdrop');
    } else if (/^TRIGGER$/i.test(kind)) {
      assert.equal(name, 'dune_airdrop_track_playtime');
    } else if (/^INDEX$/i.test(kind)) {
      assert.match(name, /^airdrop_/);
    } else {
      assert.match(name, /^dune_airdrop\.airdrop_/, `${kind} ${name}`);
    }
  }
});

test('every table, view, function and the trigger carry the ownership marker', () => {
  const named = [...topLevel(setupSql).matchAll(/CREATE\s+(?:OR\s+REPLACE\s+)?(TABLE|VIEW|FUNCTION)\s+(?:IF\s+NOT\s+EXISTS\s+)?(dune_airdrop\.airdrop_[a-z_]+)/gi)];
  assert.ok(named.length >= 12);
  for (const [, kind, name] of named) {
    const marker = new RegExp(`COMMENT ON ${kind} ${name.replace('.', '\\.')}[\\s(][^;]*IS 'dune-airdrop-addon\\|v2\\|`, 'i');
    assert.match(setupSql, marker, `${kind} ${name} has no marker`);
  }
  assert.match(setupSql, /COMMENT ON TRIGGER dune_airdrop_track_playtime ON dune\.encrypted_player_state IS 'dune-airdrop-addon\|v2\|/);
  assert.match(setupSql, /COMMENT ON SCHEMA dune_airdrop IS 'dune-airdrop-addon\|v2\|/);
});

test('every function is SECURITY INVOKER with a pinned search_path', () => {
  const functions = setupSql.match(/CREATE OR REPLACE FUNCTION dune_airdrop\./g) || [];
  assert.ok(functions.length >= 5);
  assert.equal((setupSql.match(/SECURITY INVOKER\nSET search_path = pg_catalog, pg_temp/g) || []).length, functions.length);
});

test('setup never writes to or alters a game table', () => {
  const code = setupSql.replace(/--[^\n]*/g, ' ');
  assert.doesNotMatch(code, /\b(INSERT\s+INTO|UPDATE|DELETE\s+FROM|TRUNCATE)\s+dune\./i);
  assert.doesNotMatch(code, /ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?dune\./i);
  assert.doesNotMatch(code, /\bCASCADE\b/i);
});

test('the trigger body can never block a game save', () => {
  const body = /FUNCTION dune_airdrop\.airdrop_track_playtime\(\)[\s\S]*?\$fn\$([\s\S]*?)\$fn\$/.exec(setupSql)[1];
  assert.match(body, /EXCEPTION WHEN OTHERS THEN\s+RAISE WARNING '\[dune-airdrop-addon\]/);
  assert.match(body, /RETURN NEW;\s*END\s*$/);
});

test('the script leaves transaction control to its caller', () => {
  assert.doesNotMatch(topLevel(setupSql), /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im);
  assert.doesNotMatch(topLevel(uninstallSql), /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im);
  assert.match(setupSql, /SET LOCAL ROLE dune;/);
  assert.doesNotMatch(setupSql, /^SET ROLE/m);
});

test('uninstall only cascades inside the addon schemas and never drops shared legacy tables', () => {
  const cascades = uninstallSql.match(/DROP SCHEMA IF EXISTS [a-z_]+ CASCADE/g) || [];
  assert.deepEqual(cascades.sort(), ['DROP SCHEMA IF EXISTS dune_airdrop CASCADE', 'DROP SCHEMA IF EXISTS dune_airdrop_legacy CASCADE']);
  assert.doesNotMatch(topLevel(uninstallSql), /DROP\s+(TABLE|FUNCTION)/i);
  assert.match(uninstallSql, /Uninstall aborted without changes/);
});
