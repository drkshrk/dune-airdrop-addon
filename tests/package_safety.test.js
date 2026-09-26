const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

test('manifest and package versions stay aligned', () => {
  const manifest = JSON.parse(read('addon.json'));
  const packageJson = JSON.parse(read('package.json'));
  assert.equal(manifest.version, packageJson.version);
});

test('the companion daemon is gone and nothing asks for Docker access', () => {
  assert.equal(fs.existsSync(path.join(root, 'daemon')), false);
  const manifest = JSON.parse(read('addon.json'));
  assert.doesNotMatch(manifest.description, /requir\w*[^.]*(daemon|docker socket)/i);
  assert.match(manifest.description, /no companion daemon/i);
  assert.ok(!manifest.permissions.includes('admin:grant-items'));
  assert.ok(manifest.permissions.includes('rewards:grant'));
  assert.ok(manifest.permissions.includes('files:addon-data'));
});

test('every script and stylesheet the page loads is shipped in the package', () => {
  const html = read('web/index.html');
  const packageList = read('scripts/package.sh');
  const assets = [...html.matchAll(/<(?:script|link)[^>]+(?:src|href)="(?:\.\/)?([^"?]+)(?:\?[^"]*)?"/g)].map((m) => `web/${m[1]}`);
  assert.ok(assets.includes('web/outbox_drain.js'));
  for (const asset of assets) {
    assert.ok(packageList.includes(asset), `${asset} is loaded by index.html but not packaged`);
  }
});

test('reward rolls are bounded and cannot loop forever', () => {
  const sql = read('setup_playtime_airdrops.sql');
  assert.match(sql, /v_min_drops := LEAST\(4, GREATEST\(0,/);
  assert.match(sql, /v_attempts < 32/);
  assert.match(sql, /v_num_rolls := LEAST\(20, GREATEST\(1,/);
  assert.match(sql, /LEAST\(1000, GREATEST\(1, v_raw_qty\)\)/);
});

test('the web UI only uses the v2 tables and the console reward runtime', () => {
  for (const file of ['web/addon.js', 'web/outbox_drain.js']) {
    const js = read(file);
    assert.doesNotMatch(js, /dune\.bot_|discord_bot_config|dune\.airdrop_/, file);
    assert.doesNotMatch(js, /dune_airdrop\.(config|pending_deliveries|active_playtime|loot_tables|delivery_receipts)\b/, file);
    assert.doesNotMatch(js, /admin\.items\.grant/, file);
  }
});
