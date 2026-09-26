const STORAGE_KEY = 'pending_manual_grant';

function getStoredGrantState(storage) {
  try {
    const raw = storage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    
    if (!parsed || typeof parsed !== 'object') throw new Error('Not an object');
    if (typeof parsed.id !== 'string' || !parsed.id.startsWith('manual:grant:')) throw new Error('Invalid ID');
    if (parsed.status !== 'PENDING' && parsed.status !== 'UNCERTAIN') throw new Error('Invalid status');
    
    if (!parsed.payload || typeof parsed.payload !== 'object') throw new Error('Invalid payload');
    const p = parsed.payload;
    if (typeof p.playerId !== 'string' || p.playerId.trim() === '') throw new Error('Invalid playerId');
    if (typeof p.itemId !== 'string' || p.itemId.trim() === '') throw new Error('Invalid itemId');
    if (typeof p.containerId !== 'string' || p.containerId.trim() === '') throw new Error('Invalid containerId');
    
    if (!Number.isInteger(p.quantity) || p.quantity < 1 || p.quantity > 1000) throw new Error('Invalid quantity');
    if (!Number.isInteger(p.quality) || p.quality < 0 || p.quality > 5) throw new Error('Invalid quality');
    
    // Hash check
    if (parsed.hash !== computePayloadHash(p)) throw new Error('Hash mismatch');
    
    return parsed;
  } catch (e) {
    storage.removeItem(STORAGE_KEY);
    return null; // Corrupt local storage handled safely
  }
}

function setStoredGrantState(state, storage) {
  storage.setItem(STORAGE_KEY, JSON.stringify(state));
}

function clearStoredGrantState(storage) {
  storage.removeItem(STORAGE_KEY);
}

function computePayloadHash(payload) {
  return JSON.stringify([
    payload.playerId,
    payload.itemId,
    payload.quantity,
    payload.quality,
    payload.containerId
  ]);
}

function isAmbiguousBridgeError(error) {
  const message = String(error && error.message ? error.message : error || '').toLowerCase();
  return message.includes('timed out') ||
    message.includes('timeout') ||
    message.includes('network') ||
    message.includes('failed to fetch') ||
    message.includes('delivery outcome uncertain');
}

function determineActionAndState(currentState, newPayload, cryptoObj) {
  const newHash = computePayloadHash(newPayload);
  
  if (!currentState) {
    const newId = `manual:grant:${cryptoObj.randomUUID()}`;
    return {
      action: 'PROCEED',
      newState: { id: newId, payload: newPayload, hash: newHash, status: 'PENDING' }
    };
  }
  
  if (currentState.status === 'UNCERTAIN') {
    if (currentState.hash === newHash) {
      return { action: 'PROCEED', newState: currentState };
    } else {
      return { action: 'REJECT_UNCERTAIN', newState: currentState };
    }
  }
  
  if (currentState.hash === newHash) {
    return { action: 'PROCEED', newState: currentState };
  } else {
    const newId = `manual:grant:${cryptoObj.randomUUID()}`;
    return {
      action: 'PROCEED',
      newState: { id: newId, payload: newPayload, hash: newHash, status: 'PENDING' }
    };
  }
}

// rewards.deliver answers with the console's delivery record. Once a record
// is pending, processing or delivered the console owns the reward: it waits
// for the player to be online and never repeats the same requestId.
const ACCEPTED_DELIVERY_STATUSES = ['pending', 'processing', 'delivered'];

function handleBridgeReceipt(receipt, currentState, storage) {
  const status = receipt && typeof receipt.status === 'string' ? receipt.status : null;
  if ((receipt && receipt.ok === true) || ACCEPTED_DELIVERY_STATUSES.includes(status)) {
    clearStoredGrantState(storage);
    return {
      success: true,
      message: status === 'pending' ? 'Queued: delivered when the player is online' : 'Delivered'
    };
  }
  if (status === 'failed') {
    // The console tried and rejected it; retrying the same requestId returns
    // the same failure, so there is nothing uncertain to keep.
    clearStoredGrantState(storage);
    return { success: false, permanent: true, message: receipt.lastError || 'The console rejected this delivery.' };
  }
  // No record, or the console itself reports the outcome as uncertain:
  // keep the request ID so a retry can never grant twice.
  if (currentState) {
    currentState.status = 'UNCERTAIN';
    setStoredGrantState(currentState, storage);
  }
  return { success: false, message: 'Delivery outcome uncertain. Retained request ID.' };
}

function handlePermanentRejection(currentState, storage) {
  clearStoredGrantState(storage);
}

if (typeof module !== 'undefined') {
  module.exports = {
    getStoredGrantState,
    setStoredGrantState,
    clearStoredGrantState,
    computePayloadHash,
    determineActionAndState,
    handleBridgeReceipt,
    handlePermanentRejection,
    isAmbiguousBridgeError
  };
}
