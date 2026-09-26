const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const logic = require('../web/grant_logic.js');

class MockStorage {
  constructor() {
    this.store = {};
  }
  getItem(key) { return this.store[key] || null; }
  setItem(key, value) { this.store[key] = String(value); }
  removeItem(key) { delete this.store[key]; }
}

test('getStoredGrantState handles corrupt localStorage', () => {
  const storage = new MockStorage();
  storage.setItem('pending_manual_grant', '{bad-json');
  const state = logic.getStoredGrantState(storage);
  assert.strictEqual(state, null);
});

test('getStoredGrantState handles malformed valid JSON', () => {
  const storage = new MockStorage();
  storage.setItem('pending_manual_grant', JSON.stringify({ status: 'UNCERTAIN' })); // Missing payload, id, hash
  const state = logic.getStoredGrantState(storage);
  assert.strictEqual(state, null);
  assert.strictEqual(storage.getItem('pending_manual_grant'), null); // Assert it was cleared
});

test('determineActionAndState: New payload generates new state', () => {
  const payload = { playerId: '123', itemId: 'Sword', quantity: 1, quality: 0 };
  const result = logic.determineActionAndState(null, payload, crypto);
  assert.strictEqual(result.action, 'PROCEED');
  assert.ok(result.newState.id.startsWith('manual:grant:'));
  assert.strictEqual(result.newState.status, 'PENDING');
  assert.deepStrictEqual(result.newState.payload, payload);
});

test('determineActionAndState: Retains same ID when payload matches (pending state)', () => {
  const payload = { playerId: '123', itemId: 'Sword', quantity: 1, quality: 0 };
  const initial = logic.determineActionAndState(null, payload, crypto);
  
  const retry = logic.determineActionAndState(initial.newState, payload, crypto);
  assert.strictEqual(retry.action, 'PROCEED');
  assert.strictEqual(retry.newState.id, initial.newState.id); // Idempotency
});

test('determineActionAndState: Generates new ID when payload changes (pending state)', () => {
  const payload1 = { playerId: '123', itemId: 'Sword', quantity: 1, quality: 0 };
  const payload2 = { playerId: '123', itemId: 'Sword', quantity: 2, quality: 0 };
  const initial = logic.determineActionAndState(null, payload1, crypto);
  
  const retry = logic.determineActionAndState(initial.newState, payload2, crypto);
  assert.strictEqual(retry.action, 'PROCEED');
  assert.notStrictEqual(retry.newState.id, initial.newState.id); // New ID!
});

test('determineActionAndState: Rejects changes if state is UNCERTAIN', () => {
  const payload1 = { playerId: '123', itemId: 'Sword', quantity: 1, quality: 0 };
  const payload2 = { playerId: '123', itemId: 'Sword', quantity: 2, quality: 0 };
  const initial = logic.determineActionAndState(null, payload1, crypto);
  
  initial.newState.status = 'UNCERTAIN';
  
  const retry = logic.determineActionAndState(initial.newState, payload2, crypto);
  assert.strictEqual(retry.action, 'REJECT_UNCERTAIN');
});

test('determineActionAndState: Allows retry with exact same payload if UNCERTAIN', () => {
  const payload = { playerId: '123', itemId: 'Sword', quantity: 1, quality: 0 };
  const initial = logic.determineActionAndState(null, payload, crypto);
  
  initial.newState.status = 'UNCERTAIN';
  
  const retry = logic.determineActionAndState(initial.newState, payload, crypto);
  assert.strictEqual(retry.action, 'PROCEED');
  assert.strictEqual(retry.newState.id, initial.newState.id);
});

test('handleBridgeReceipt: Clears state on ok === true', () => {
  const storage = new MockStorage();
  const payload = { playerId: '123', itemId: 'Sword', quantity: 1, quality: 0 };
  const initial = logic.determineActionAndState(null, payload, crypto);
  logic.setStoredGrantState(initial.newState, storage);
  
  const outcome = logic.handleBridgeReceipt({ ok: true }, initial.newState, storage);
  assert.strictEqual(outcome.success, true);
  assert.strictEqual(logic.getStoredGrantState(storage), null);
});

test('handleBridgeReceipt: a rewards.deliver record the console accepted is success', () => {
  for (const status of ['pending', 'processing', 'delivered']) {
    const storage = new MockStorage();
    const initial = logic.determineActionAndState(null, { playerId: '123', itemId: 'Sword', quantity: 1, quality: 0 }, crypto);
    logic.setStoredGrantState(initial.newState, storage);
    const outcome = logic.handleBridgeReceipt({ requestId: initial.newState.id, status }, initial.newState, storage);
    assert.strictEqual(outcome.success, true, status);
    assert.strictEqual(logic.getStoredGrantState(storage), null, status);
  }
});

test('handleBridgeReceipt: a failed delivery is a permanent rejection, not uncertain', () => {
  const storage = new MockStorage();
  const initial = logic.determineActionAndState(null, { playerId: '123', itemId: 'Sword', quantity: 1, quality: 0 }, crypto);
  logic.setStoredGrantState(initial.newState, storage);
  const outcome = logic.handleBridgeReceipt({ status: 'failed', lastError: 'Player not found.' }, initial.newState, storage);
  assert.strictEqual(outcome.success, false);
  assert.strictEqual(outcome.permanent, true);
  assert.strictEqual(outcome.message, 'Player not found.');
  assert.strictEqual(logic.getStoredGrantState(storage), null);
});

test('handleBridgeReceipt: an uncertain delivery keeps the request ID', () => {
  const storage = new MockStorage();
  const initial = logic.determineActionAndState(null, { playerId: '123', itemId: 'Sword', quantity: 1, quality: 0, containerId: '99' }, crypto);
  logic.setStoredGrantState(initial.newState, storage);
  const outcome = logic.handleBridgeReceipt({ status: 'uncertain' }, initial.newState, storage);
  assert.strictEqual(outcome.success, false);
  assert.strictEqual(logic.getStoredGrantState(storage).status, 'UNCERTAIN');
});

test('handleBridgeReceipt: Transitions to UNCERTAIN on lost/failed response', () => {
  const storage = new MockStorage();
  // A stored grant is only valid with the container it targets.
  const payload = { playerId: '123', itemId: 'Sword', quantity: 1, quality: 0, containerId: '99' };
  const initial = logic.determineActionAndState(null, payload, crypto);
  logic.setStoredGrantState(initial.newState, storage);
  
  const outcome = logic.handleBridgeReceipt(null, initial.newState, storage);
  assert.strictEqual(outcome.success, false);
  
  const stored = logic.getStoredGrantState(storage);
  assert.strictEqual(stored.status, 'UNCERTAIN');
});
