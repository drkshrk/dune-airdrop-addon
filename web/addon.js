/**
 * Arrakis Manager Console Addon Controller
 */

// Security Utils
const escapeHTML = (str) => {
  if (str == null) return '';
  return String(str).replace(/[&<>'"]/g, tag => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    "'": '&#39;',
    '"': '&quot;'
  }[tag]));
};

// Tab Navigation elements
const tabSettingsBtn = document.getElementById('tabSettingsBtn');
const settingsView = document.getElementById('settingsView');
const connectionStatusBadge = document.getElementById('connectionStatusBadge');

// Multipliers settings inputs

const playtimeIntervalSlider = document.getElementById('playtimeIntervalSlider');
const playtimeIntervalInput = document.getElementById('playtimeIntervalInput');
const playtimeDistanceSlider = document.getElementById('playtimeDistanceSlider');
const playtimeDistanceInput = document.getElementById('playtimeDistanceInput');
const playtimeXpSlider = document.getElementById('playtimeXpSlider');
const playtimeXpInput = document.getElementById('playtimeXpInput');

// Online Diagnostics and Pending Queue
const diagnosticsTableBody = document.getElementById('diagnosticsTableBody');
const pendingAirdropsTableBody = document.getElementById('pendingAirdropsTableBody');
const airdropPlayerSelect = document.getElementById('airdropPlayerSelect');

let pendingAirdropsData = [];
let activeContainerId = null;

// Determine if running inside the Dune Docker Console iframe
const isSandboxMode = window.parent === window;

// Database layout this page expects (dune_airdrop.airdrop_schema_version).
const SCHEMA_VERSION = 2;
const DELIVERY_INTERVAL_MS = 30000;

// --- Initialize Bridge & UI ---

document.addEventListener('DOMContentLoaded', async () => {
  setupMultipliersSync();

  const clearQueueBtn = document.getElementById('clearQueueBtn');
  if (clearQueueBtn) {
    clearQueueBtn.addEventListener('click', async () => {
      if (isSandboxMode) {
        showToast('Mock: Queue cleared!', 'success');
        return;
      }
      const waiting = pendingAirdropsData.filter((d) => d.source === 'addon').length;
      if (waiting === 0) {
        showToast('Nothing is waiting in the addon queue. Rewards already handed to the console cannot be cleared here.', 'warning');
        return;
      }
      const confirmed = window.confirm(
        `Discard ${waiting} reward${waiting === 1 ? '' : 's'} not yet handed to the console? ` +
        'Rewards the console is already delivering are not affected.'
      );
      if (!confirmed) return;
      try {
        const { watermark } = await readWatermark(window.DuneAddon.request);
        await window.DuneAddon.request("database.execute", {
          query: discardQuery('queued', watermark)
        });
        showToast('Queued rewards discarded.', 'success');
        fetchPendingAirdrops();
      } catch (err) {
        showToast(`Failed to clear queue: ${err.message}`, 'error');
      }
    });
  }

  if (isSandboxMode) {
    connectionStatusBadge.textContent = 'Bridge Sandbox';
    connectionStatusBadge.className = connectionStatusBadge.className.replace('text-amber-500', 'text-amber-400');
    loadMockData();
  } else {
    connectionStatusBadge.textContent = 'Console Connected';
    connectionStatusBadge.className = connectionStatusBadge.className.replace('bg-amber-500/10 text-amber-500', 'bg-emerald-500/10 text-emerald-400 border-emerald-500/20');

    const schemaReady = await isAirdropSchemaReady();
    if (schemaReady) {
      await loadSettings();
      await fetchDiagnostics();
      await fetchPendingAirdrops();
      await fetchContainers();
      await loadMigrationReport();
      setupMigrationActions();

      window.__fetchDiagnosticsInterval = setInterval(fetchDiagnostics, 5000);
      window.__fetchPendingInterval = setInterval(fetchPendingAirdrops, 5000);
      runDeliveryCycle();
      window.__deliveryInterval = setInterval(runDeliveryCycle, DELIVERY_INTERVAL_MS);
    } else {
      connectionStatusBadge.textContent = 'Setup Required';
      connectionStatusBadge.className = connectionStatusBadge.className.replace(
        'bg-emerald-500/10 text-emerald-400 border-emerald-500/20',
        'bg-amber-500/10 text-amber-400 border-amber-500/20'
      );
      showToast('Database setup is required. Click INIT SCHEMA to finish installing Airdrop Manager.', 'warning');
    }

    // Wire up the manual spawn modal
    setupSpawnModal();

    // Wire up tabs
    const settingsTab = document.getElementById('tabSettingsBtn');
    const lootTab = document.getElementById('tabLootBtn');
    const settingsView = document.getElementById('settingsView');
    const lootView = document.getElementById('lootView');

    if (settingsTab && lootTab && settingsView && lootView) {
      settingsTab.addEventListener('click', () => {
        settingsView.classList.remove('hidden');
        lootView.classList.add('hidden');
        settingsTab.classList.replace('bg-slate-800', 'bg-amber-500');
        settingsTab.classList.replace('text-slate-300', 'text-slate-950');
        settingsTab.classList.add('neon-glow-orange');
        settingsTab.classList.remove('hover:bg-slate-700');

        lootTab.classList.replace('bg-amber-500', 'bg-slate-800');
        lootTab.classList.replace('text-slate-950', 'text-slate-300');
        lootTab.classList.remove('neon-glow-orange');
        lootTab.classList.add('hover:bg-slate-700');
      });

      lootTab.addEventListener('click', () => {
        lootView.classList.remove('hidden');
        settingsView.classList.add('hidden');
        lootTab.classList.replace('bg-slate-800', 'bg-amber-500');
        lootTab.classList.replace('text-slate-300', 'text-slate-950');
        lootTab.classList.add('neon-glow-orange');
        lootTab.classList.remove('hover:bg-slate-700');

        settingsTab.classList.replace('bg-amber-500', 'bg-slate-800');
        settingsTab.classList.replace('text-slate-950', 'text-slate-300');
        settingsTab.classList.remove('neon-glow-orange');
        settingsTab.classList.add('hover:bg-slate-700');
      });
    }
  }
});

// --- Multipliers Sync Bindings ---
function setupMultipliersSync() {
  const syncRangeAndNumber = (slider, input, min, max, step) => {
    if (!slider || !input) return;
    slider.addEventListener('input', () => {
      input.value = slider.value;
    });
    input.addEventListener('input', () => {
      let val = parseFloat(input.value) || min;
      val = Math.max(min, Math.min(max, val));
      slider.value = val;
    });
  };

  syncRangeAndNumber(playtimeIntervalSlider, playtimeIntervalInput, 1, 120, 1);
  syncRangeAndNumber(playtimeDistanceSlider, playtimeDistanceInput, 0, 100, 1);
  syncRangeAndNumber(playtimeXpSlider, playtimeXpInput, 0, 1000, 5);

  // Sync Daily and Weekly sliders
  syncRangeAndNumber(document.getElementById('dailyStepSlider'), document.getElementById('dailyStepInput'), 0.1, 10, 0.1);
  syncRangeAndNumber(document.getElementById('dailyMaxStreakSlider'), document.getElementById('dailyMaxStreakInput'), 1, 30, 1);
  syncRangeAndNumber(document.getElementById('weeklyDaysRequiredSlider'), document.getElementById('weeklyDaysRequiredInput'), 1, 7, 1);
  syncRangeAndNumber(document.getElementById('weeklyMultiplierSlider'), document.getElementById('weeklyMultiplierInput'), 1, 100, 0.5);


  // Sync Economy Sliders
  syncRangeAndNumber(document.getElementById('probGearSlider'), document.getElementById('probGearInput'), 0, 100, 1);
  syncRangeAndNumber(document.getElementById('probSchemSlider'), document.getElementById('probSchemInput'), 0, 100, 1);
  syncRangeAndNumber(document.getElementById('probCraftSlider'), document.getElementById('probCraftInput'), 0, 100, 1);
  syncRangeAndNumber(document.getElementById('probRawSlider'), document.getElementById('probRawInput'), 0, 100, 1);
  syncRangeAndNumber(document.getElementById('minItemsSlider'), document.getElementById('minItemsInput'), 0, 4, 1);

  // Sync Tier Multipliers
  for (let t = 0; t <= 6; t++) {
    const slider = document.getElementById(`playtimeMultiplierT${t}Slider`);
    const input = document.getElementById(`playtimeMultiplierT${t}Input`);
    syncRangeAndNumber(slider, input, 1, 100, 1);
  }
}

// --- Spawn Modal Logic ---
function setupSpawnModal() {
  const spawnItemModal = document.getElementById('spawnItemModal');
  const spawnItemCancelBtn = document.getElementById('spawnItemCancelBtn');
  const spawnItemConfirmBtn = document.getElementById('spawnItemConfirmBtn');
  const spawnItemTemplateInput = document.getElementById('spawnItemTemplateInput');
  const spawnItemQtyInput = document.getElementById('spawnItemQtyInput');
  const openSpawnModalBtn = document.getElementById('openSpawnModalBtn');
  const validItemTemplates = document.getElementById('validItemTemplates');
  const discardBtn = document.getElementById('spawnItemDiscardBtn');
  const warningText = document.getElementById('spawnItemWarningText');

  function updateUncertainStateUI(isUncertain) {
    if (isUncertain) {
      spawnItemTemplateInput.disabled = true;
      spawnItemQtyInput.disabled = true;
      if (discardBtn) discardBtn.classList.remove('hidden');
      if (warningText) warningText.classList.remove('hidden');
    } else {
      spawnItemTemplateInput.disabled = false;
      spawnItemQtyInput.disabled = false;
      if (discardBtn) discardBtn.classList.add('hidden');
      if (warningText) warningText.classList.add('hidden');
    }
  }

  function handleStateCheck() {
    const currentState = getStoredGrantState(window.localStorage);
    if (currentState) {
      // Lock inputs to the stored payload
      spawnItemTemplateInput.value = currentState.payload.itemId;
      spawnItemQtyInput.value = currentState.payload.quantity;
      spawnItemTemplateInput.dataset.actId = currentState.payload.containerId;
      if (activeContainerId !== currentState.payload.containerId) {
        window.selectContainer(currentState.payload.containerId, true);
      }
      updateUncertainStateUI(true);
    } else {
      updateUncertainStateUI(false);
    }
  }

  if (discardBtn) {
    discardBtn.addEventListener('click', () => {
      clearStoredGrantState(window.localStorage);
      updateUncertainStateUI(false);
      showToast('Uncertain delivery state discarded.', 'success');
    });
  }

  spawnItemCancelBtn.addEventListener('click', () => {
    spawnItemModal.classList.add('hidden');
    // We do NOT clear the state here if it was in flight or uncertain!
    // The pure functions handle state clearing.
  });

  // Global selectContainer implementation
  window.selectContainer = async function(id, skipStateCheck = false) {
    if (!/^[0-9]+$/.test(String(id))) {
      showToast('Invalid container ID selected.', 'error');
      return;
    }
    activeContainerId = String(id);
    spawnItemTemplateInput.dataset.actId = activeContainerId;

    // Update UI highlights
    const rows = document.querySelectorAll('.container-row');
    rows.forEach(r => r.classList.remove('bg-amber-900/30', 'border-amber-500/50'));
    const selectedRow = document.getElementById(`container-row-${id}`);
    if (selectedRow) {
      selectedRow.classList.add('bg-amber-900/30', 'border-amber-500/50');
    }

    if (openSpawnModalBtn) openSpawnModalBtn.classList.remove('hidden');

    // Clear container grid to show it is selected
    const grid = document.getElementById('containerInventoryGrid');
    if (grid) {
      grid.innerHTML = `<div class="col-span-full py-12 text-center text-slate-500 font-mono italic">
        Container ${escapeHTML(id)} selected. Ready to spawn items.
      </div>`;
    }

    if (!skipStateCheck) {
      handleStateCheck();
    }
  };

  if (openSpawnModalBtn) {
    openSpawnModalBtn.addEventListener('click', () => {
      spawnItemModal.classList.remove('hidden');
    });
  }

  spawnItemConfirmBtn.addEventListener('click', async () => {
    const templateId = spawnItemTemplateInput.value.trim();
    const qty = Number(spawnItemQtyInput.value);

    if (!/^[A-Za-z0-9_./:-]{1,240}$/.test(templateId)) {
      showToast('Enter a valid item template ID.', 'error');
      return;
    }
    if (!Number.isInteger(qty) || qty < 1 || qty > 1000) {
      showToast('Quantity must be a whole number from 1 to 1000.', 'error');
      return;
    }

    // Disable submission immediately to prevent duplicate rapid clicks
    spawnItemConfirmBtn.disabled = true;
    spawnItemConfirmBtn.textContent = 'SPAWNING...';

    if (isSandboxMode) {
      showToast(`Mock: Spawned ${qty}x ${templateId}`, 'success');
      spawnItemModal.classList.add('hidden');
      spawnItemConfirmBtn.disabled = false;
      spawnItemConfirmBtn.textContent = 'SPAWN';
      return;
    }

    try {
      const actId = String(spawnItemTemplateInput.dataset.actId || activeContainerId);
      if (!/^[0-9]+$/.test(actId)) {
        throw new Error("Invalid container ID format");
      }
      const qNum = qty;

      // The container's owner is recorded on the actor that holds the inventory.
      const res = await window.DuneAddon.request("database.query", {
        query: `SELECT a.owner_account_id::text AS account_id
                  FROM dune.inventories i
                  JOIN dune.actors a ON a.id = i.actor_id
                 WHERE i.id = ${actId}::bigint
                 LIMIT 1`
      });

      const account_id = (res.rows && res.rows.length === 1 && res.rows[0] && res.rows[0].account_id) ? String(res.rows[0].account_id) : null;

      if (!account_id || account_id.trim() === '') {
        throw new Error("Could not resolve exactly one nonempty player account.");
      }

      const newPayload = {
        playerId: account_id,
        itemId: templateId,
        quantity: qNum,
        quality: 0,
        containerId: actId
      };

      const currentState = getStoredGrantState(window.localStorage);
      const stateDecision = determineActionAndState(currentState, newPayload, window.crypto);

      if (stateDecision.action === 'REJECT_UNCERTAIN') {
        showToast('A previous delivery is in an uncertain state. You must retry it or discard it first.', 'error');
        spawnItemConfirmBtn.disabled = false;
        spawnItemConfirmBtn.textContent = 'SPAWN';
        return;
      }

      // Persist pending/uncertain state before calling bridge
      setStoredGrantState(stateDecision.newState, window.localStorage);

      const stored = stateDecision.newState.payload;
      const receipt = await window.DuneAddon.request("rewards.deliver", {
        requestId: stateDecision.newState.id,
        playerId: stored.playerId,
        type: 'item',
        itemId: stored.itemId,
        amount: stored.quantity,
        quality: stored.quality
      });

      const outcome = handleBridgeReceipt(receipt, stateDecision.newState, window.localStorage);

      if (outcome.permanent) {
        updateUncertainStateUI(false);
        showToast(`Grant rejected: ${outcome.message}`, 'error');
      } else if (outcome.success) {
        showToast(`${qNum}x ${templateId}: ${outcome.message}`, 'success');
        updateUncertainStateUI(false);
        if (window.selectContainer) {
          await window.selectContainer(actId);
        }
        spawnItemModal.classList.add('hidden');
      } else {
        throw new Error(outcome.message);
      }
    } catch (err) {
      if (isAmbiguousBridgeError(err)) {
        showToast(`Failed to spawn item: ${err.message}`, 'error');
        const currentState = getStoredGrantState(window.localStorage);
        if (currentState) {
          currentState.status = 'UNCERTAIN';
          setStoredGrantState(currentState, window.localStorage);
        }
        handleStateCheck();
      } else {
        handlePermanentRejection(null, window.localStorage);
        updateUncertainStateUI(false);
        showToast(`Spawn request rejected: ${err.message}`, 'error');
      }
    } finally {
      spawnItemConfirmBtn.disabled = false;
      spawnItemConfirmBtn.textContent = 'SPAWN';
    }
  });

  const commonItems = ['ScrapMetal', 'CopperOre', 'IronOre', 'FlourSand', 'PlantFiber', 'Basalt', 'DolomiteRock', 'Silicone', 'WaterCanister', 'SpiceMelange'];
  validItemTemplates.innerHTML = commonItems.map(item => `<option value="${item}"></option>`).join('');

  handleStateCheck();
}


// --- Database Operations ---
async function isAirdropSchemaReady() {
  try {
    const rawResult = await window.DuneAddon.request("database.query", {
      query: `SELECT to_regclass('dune_airdrop.airdrop_schema_version')::text AS version_table`
    });
    const row = (rawResult.rows || [])[0] || {};
    if (!row.version_table) return false;
    const version = await window.DuneAddon.request("database.query", {
      query: 'SELECT max(version) AS version FROM dune_airdrop.airdrop_schema_version'
    });
    return Number(((version.rows || [])[0] || {}).version) >= SCHEMA_VERSION;
  } catch (err) {
    showToast(`Failed to check database setup: ${err.message}`, 'error');
    return false;
  }
}

async function loadSettings() {
  try {
    const rawRes = await window.DuneAddon.request("database.query", {
      query: "SELECT config_key, config_value FROM dune_airdrop.airdrop_config"
    });
    const configRows = rawRes.rows || [];
    const configValue = (key) => (configRows.find((r) => r.config_key === key) || {}).config_value;

    let mults = {
      playtime_enabled: true,
      playtime_interval: 60,
      playtime_distance: 10,
      playtime_xp: 1,
      daily_enabled: true,
      daily_multiplier_step: 0.5,
      daily_max_streak: 7,
      weekly_enabled: true,
      weekly_days_required: 5,
      weekly_multiplier: 5.0
    };
    if (configValue('airdrop_multipliers')) {
      mults = { ...mults, ...configValue('airdrop_multipliers') };
    }

    // Load playtime inputs
    document.getElementById('playtimeEnabledToggle').checked = mults.playtime_enabled !== undefined ? mults.playtime_enabled : true;
    playtimeIntervalInput.value = mults.playtime_interval || 60;
    playtimeIntervalSlider.value = mults.playtime_interval || 60;
    playtimeDistanceInput.value = mults.playtime_distance !== undefined ? mults.playtime_distance : 10.0;
    playtimeDistanceSlider.value = mults.playtime_distance !== undefined ? mults.playtime_distance : 10.0;
    playtimeXpInput.value = mults.playtime_xp !== undefined ? mults.playtime_xp : 1;
    playtimeXpSlider.value = mults.playtime_xp !== undefined ? mults.playtime_xp : 1;

    // Load Daily inputs
    document.getElementById('dailyEnabledToggle').checked = mults.daily_enabled !== undefined ? mults.daily_enabled : true;
    document.getElementById('dailyStepInput').value = mults.daily_multiplier_step !== undefined ? mults.daily_multiplier_step : 0.5;
    document.getElementById('dailyStepSlider').value = mults.daily_multiplier_step !== undefined ? mults.daily_multiplier_step : 0.5;
    document.getElementById('dailyMaxStreakInput').value = mults.daily_max_streak !== undefined ? mults.daily_max_streak : 7;
    document.getElementById('dailyMaxStreakSlider').value = mults.daily_max_streak !== undefined ? mults.daily_max_streak : 7;

    // Load Weekly inputs
    document.getElementById('weeklyEnabledToggle').checked = mults.weekly_enabled !== undefined ? mults.weekly_enabled : true;
    document.getElementById('weeklyDaysRequiredInput').value = mults.weekly_days_required !== undefined ? mults.weekly_days_required : 5;
    document.getElementById('weeklyDaysRequiredSlider').value = mults.weekly_days_required !== undefined ? mults.weekly_days_required : 5;
    document.getElementById('weeklyMultiplierInput').value = mults.weekly_multiplier !== undefined ? mults.weekly_multiplier : 5.0;
    document.getElementById('weeklyMultiplierSlider').value = mults.weekly_multiplier !== undefined ? mults.weekly_multiplier : 5.0;


    let econ = {
      prob_gear: 0.40, prob_schem: 0.80, prob_raw: 1.0, prob_craft: 1.0, min_items: 1,
      tier_0_min: 5, tier_0_max: 10,
      tier_1_min: 5, tier_1_max: 15,
      tier_2_min: 10, tier_2_max: 25,
      tier_3_min: 15, tier_3_max: 35,
      tier_4_min: 20, tier_4_max: 50,
      tier_5_min: 30, tier_5_max: 75,
      tier_6_min: 50, tier_6_max: 100
    };
    if (configValue('airdrop_economy')) {
      econ = { ...econ, ...configValue('airdrop_economy') };
    }

    // Load Economy inputs
    document.getElementById('probGearInput').value = Math.round(econ.prob_gear * 100);
    document.getElementById('probGearSlider').value = Math.round(econ.prob_gear * 100);
    document.getElementById('probSchemInput').value = Math.round(econ.prob_schem * 100);
    document.getElementById('probSchemSlider').value = Math.round(econ.prob_schem * 100);
    document.getElementById('probCraftInput').value = Math.round(econ.prob_craft * 100);
    document.getElementById('probCraftSlider').value = Math.round(econ.prob_craft * 100);
    document.getElementById('probRawInput').value = Math.round(econ.prob_raw * 100);
    document.getElementById('probRawSlider').value = Math.round(econ.prob_raw * 100);
    document.getElementById('minItemsInput').value = econ.min_items;
    document.getElementById('minItemsSlider').value = econ.min_items;

    for (let t = 0; t <= 6; t++) {
      const minInput = document.getElementById(`t${t}MinInput`);
      const maxInput = document.getElementById(`t${t}MaxInput`);
      if (minInput) minInput.value = econ[`tier_${t}_min`] || 1;
      if (maxInput) maxInput.value = econ[`tier_${t}_max`] || 1;
    }

    for (let t = 0; t <= 6; t++) {
      const input = document.getElementById(`playtimeMultiplierT${t}Input`);
      const slider = document.getElementById(`playtimeMultiplierT${t}Slider`);
      if (input && slider) {
        const val = mults[`playtime_multiplier_t${t}`] !== undefined ? mults[`playtime_multiplier_t${t}`] : (mults.playtime_multiplier || 1);
        input.value = val;
        slider.value = Math.min(50, val);
      }
    }

  } catch (err) {
    showToast(`Failed to load settings: ${err.message}`, 'error');
  }
}

async function handleSaveAllSettings() {
  if (isSandboxMode) {
    showToast('Mock: Settings saved successfully!', 'success');
    return;
  }

  try {
    const getFloat = (val, def) => { const n = parseFloat(val); return isNaN(n) ? def : n; };
    const getInt = (val, def) => { const n = parseInt(val); return isNaN(n) ? def : n; };

    const payload = {
      playtime_enabled: document.getElementById('playtimeEnabledToggle').checked,
      playtime_interval: getInt(playtimeIntervalInput.value, 60),
      playtime_distance: getFloat(playtimeDistanceInput.value, 10.0),
      playtime_xp: getInt(playtimeXpInput.value, 1),
      daily_enabled: document.getElementById('dailyEnabledToggle').checked,
      daily_multiplier_step: getFloat(document.getElementById('dailyStepInput').value, 0.5),
      daily_max_streak: getInt(document.getElementById('dailyMaxStreakInput').value, 7),
      weekly_enabled: document.getElementById('weeklyEnabledToggle').checked,
      weekly_days_required: getInt(document.getElementById('weeklyDaysRequiredInput').value, 5),
      weekly_multiplier: getFloat(document.getElementById('weeklyMultiplierInput').value, 5.0)
    };

    for (let t = 0; t <= 6; t++) {
      const input = document.getElementById(`playtimeMultiplierT${t}Input`);
      payload[`playtime_multiplier_t${t}`] = input ? getInt(input.value, 1) : 1;
    }


    const econPayload = {
      prob_gear: getFloat(document.getElementById('probGearInput').value, 40) / 100,
      prob_schem: getFloat(document.getElementById('probSchemInput').value, 80) / 100,
      prob_craft: getFloat(document.getElementById('probCraftInput').value, 100) / 100,
      prob_raw: getFloat(document.getElementById('probRawInput').value, 100) / 100,
      min_items: Math.max(0, Math.min(4, getInt(document.getElementById('minItemsInput').value, 1))),
    };
    for (let t = 0; t <= 6; t++) {
      econPayload[`tier_${t}_min`] = getInt(document.getElementById(`t${t}MinInput`).value, 1);
      econPayload[`tier_${t}_max`] = getInt(document.getElementById(`t${t}MaxInput`).value, 1);
    }

    // One statement, so the console takes one pre-write backup per save.
    const escapedEconJson = JSON.stringify(econPayload).replace(/'/g, "''");
    const escapedJson = JSON.stringify(payload).replace(/'/g, "''");
    await window.DuneAddon.request("database.execute", {
      query: `INSERT INTO dune_airdrop.airdrop_config (config_key, config_value, updated_at)
              VALUES ('airdrop_multipliers', '${escapedJson}'::jsonb, now()),
                     ('airdrop_economy', '${escapedEconJson}'::jsonb, now())
              ON CONFLICT (config_key)
              DO UPDATE SET config_value = EXCLUDED.config_value, updated_at = now()`
    });

    showToast('All multipliers and settings saved successfully!', 'success');
  } catch (err) {
    showToast(`Failed to save settings: ${err.message}`, 'error');
  }
}

async function handleInitializeSchema() {
  if (isSandboxMode) {
    showToast('Mock: Database schema initialized successfully!', 'success');
    return;
  }

  const confirmed = window.confirm(
    'Stop the battlegroup before initializing or upgrading Airdrop Manager. ' +
    'This briefly replaces its player-state trigger. Continue now?'
  );
  if (!confirmed) return;

  try {
    showToast('Loading SQL schema from addon package...', 'success');
    const response = await fetch('../setup_playtime_airdrops.sql');
    if (!response.ok) throw new Error('Failed to fetch SQL file.');

    const sqlQuery = await response.text();

    showToast('Executing schema creation... This may take a moment.', 'success');
    const setupResult = await window.DuneAddon.request("database.execute", {
      query: sqlQuery
    });
    const summary = ((setupResult && setupResult.rows) || [])[0] || {};
    const held = Number(summary.legacy_rewards_held || 0) + Number(summary.legacy_rewards_for_review || 0);
    showToast(held > 0
      ? `Database ready. ${held} reward(s) from the previous version are held for your review. Reloading...`
      : 'Database ready. Reloading...', 'success');
    window.setTimeout(() => window.location.reload(), 500);
  } catch (err) {
    const message = String(err?.message || err);
    if (/lock timeout|statement timeout|canceling statement/i.test(message)) {
      showToast('Schema init could not lock the active player-state table. Stop the battlegroup, then click INIT SCHEMA again.', 'error');
    } else if (/daemon is still running/i.test(message)) {
      showToast('The old airdrop daemon is still running. Remove it with: docker rm -f airdrop-daemon, then click INIT SCHEMA again.', 'error');
    } else {
      showToast(`Schema init failed: ${message}`, 'error');
    }
  }
}

async function fetchDiagnostics() {
  if (isSandboxMode) return;

  try {
    const rawPlayers = await window.DuneAddon.request("database.query", {
      query: `SELECT
                ps.character_name AS name,
                ps.player_pawn_id AS character_id,
                COALESCE(act.map, 'Unknown') AS map,
                COALESCE(bp.active_seconds, 0) AS active_seconds,
                COALESCE(bp.consecutive_days, 0) AS consecutive_days,
                COALESCE(bp.weekly_login_mask, 0) AS weekly_login_mask
              FROM dune.player_state ps
              LEFT JOIN dune.actors act ON ps.player_pawn_id = act.id
              LEFT JOIN dune_airdrop.airdrop_player_progress bp ON ps.player_pawn_id = bp.character_id
              WHERE ps.player_pawn_id IS NOT NULL AND LOWER(ps.online_status::text) = 'online'`
    });
    const players = rawPlayers.rows || rawPlayers || [];

    if (!players || players.length === 0) {
      diagnosticsTableBody.innerHTML = `
        <tr>
          <td colspan="7" class="py-4 text-center italic text-slate-500">No online players detected.</td>
        </tr>
      `;
      return;
    }

    diagnosticsTableBody.innerHTML = players.map(p => {
      const characterId = String(p.character_id || '');
      const hasValidCharacterId = /^[0-9]+$/.test(characterId);
      const activeMin = Math.floor(p.active_seconds / 60);
      const limitMin = parseInt(playtimeIntervalInput.value) || 60;
      const nextMin = Math.max(0, limitMin - activeMin);

      const weeklyLogins = (p.weekly_login_mask || 0).toString(2).split('1').length - 1;
      const weeklyReq = parseInt(document.getElementById('weeklyDaysRequiredInput').value) || 5;

      return `
        <tr class="border-b border-slate-900/40 hover:bg-slate-900/20 font-mono">
          <td class="py-2 text-slate-300">${escapeHTML(p.name)}</td>
          <td class="py-2 text-slate-400">${activeMin}m / ${limitMin}m</td>
          <td class="py-2 text-slate-400">${nextMin}m left</td>
          <td class="py-2 text-slate-400">${p.consecutive_days || 0} Days</td>
          <td class="py-2 text-slate-400">${weeklyLogins} / ${weeklyReq}</td>
          <td class="py-2 text-right text-slate-500">${escapeHTML(p.map)}</td>
          <td class="py-2 text-right">
            ${hasValidCharacterId ? `<button onclick="testResetDaily('${characterId}')" class="text-[10px] bg-red-900/40 hover:bg-red-800 text-red-200 px-2 py-1 rounded">Reset Daily</button>
            <button onclick="testSetWeekly('${characterId}')" class="text-[10px] bg-blue-900/40 hover:bg-blue-800 text-blue-200 px-2 py-1 rounded ml-1">Set 5/5</button>` : '-'}
          </td>
        </tr>
      `;
    }).join('');
  } catch (err) {
    console.error('Diagnostics failed:', err);
  }
}

async function fetchPendingAirdrops() {
  if (isSandboxMode) return;

  try {
    const { watermark } = await readWatermark(window.DuneAddon.request);
    const rawList = await window.DuneAddon.request("database.query", {
      query: `SELECT q.id::text AS id, 'airdrop:' || q.request_id::text AS request_id,
                     COALESCE(ps.character_name, 'Unknown') AS character_name,
                     q.template_id, q.stack_size, q.state
                FROM dune_airdrop.airdrop_reward_queue q
                LEFT JOIN dune.player_state ps ON ps.account_id = q.account_id
               WHERE q.state IN ('queued', 'held', 'review')
               ORDER BY q.created_at DESC
               LIMIT 200`
    });
    const queueRows = rawList.rows || [];
    const names = new Map(queueRows.map((r) => [r.request_id, r.character_name]));

    // Rewards past the watermark belong to the console now; show its view.
    const consoleRows = [];
    for (const status of ['pending', 'uncertain', 'failed']) {
      const listed = await window.DuneAddon.request("rewards.list", { status, limit: 100 });
      for (const d of (Array.isArray(listed) ? listed : (listed && listed.rows) || [])) {
        const delivery = d.delivery || {};
        consoleRows.push({
          source: 'console',
          character_name: names.get(d.requestId) || `Player ${delivery.playerId || '?'}`,
          template_id: delivery.itemId || delivery.type || '?',
          stack_size: delivery.amount || 1,
          status: status === 'pending' ? 'waiting for player' : status,
          detail: d.lastError || ''
        });
      }
    }

    const addonRows = queueRows
      .filter((r) => r.state !== 'queued' || BigInt(r.id) > BigInt(watermark))
      .map((r) => ({
        source: r.state === 'queued' ? 'addon' : 'legacy',
        character_name: r.character_name,
        template_id: r.template_id,
        stack_size: r.stack_size,
        status: r.state === 'queued' ? 'queued' : (r.state === 'held' ? 'held (upgrade)' : 'uncertain (upgrade)'),
        detail: ''
      }));

    pendingAirdropsData = [...addonRows, ...consoleRows];
    renderPendingAirdrops();

    // Populate filter dropdown
    const selected = airdropPlayerSelect.value;
    const characterNames = [...new Set(pendingAirdropsData.map(d => d.character_name))].sort();
    airdropPlayerSelect.innerHTML = '<option value="all">All Characters</option>' +
      characterNames.map(n => `<option value="${escapeHTML(n)}">${escapeHTML(n)}</option>`).join('');
    if (characterNames.includes(selected) || selected === 'all') {
      airdropPlayerSelect.value = selected;
    }
  } catch (err) {
    console.error('Failed to load pending queue:', err);
    pendingAirdropsTableBody.innerHTML = `
      <tr>
        <td colspan="4" class="py-4 text-center italic text-rose-500">Error: ${escapeHTML(err.message || String(err))}</td>
      </tr>
    `;
  }
}

function renderPendingAirdrops() {
  const filter = airdropPlayerSelect.value;
  const filtered = filter === 'all'
    ? pendingAirdropsData
    : pendingAirdropsData.filter(d => d.character_name === filter);

  if (filtered.length === 0) {
    pendingAirdropsTableBody.innerHTML = `
      <tr>
        <td colspan="4" class="py-2 text-center italic text-slate-500">No pending airdrops.</td>
      </tr>
    `;
    return;
  }

  pendingAirdropsTableBody.innerHTML = filtered.map(d => `
    <tr class="border-b border-slate-900/40 hover:bg-slate-900/20 font-mono text-xs">
      <td class="py-1.5 text-slate-300">${escapeHTML(d.character_name)}</td>
      <td class="py-1.5 text-amber-500 font-bold">${escapeHTML(d.template_id)}</td>
      <td class="py-1.5 text-right text-slate-300 font-bold">${escapeHTML(d.stack_size)}</td>
      <td class="py-1.5 text-right text-slate-400" title="${escapeHTML(d.detail)}">${escapeHTML(d.status)}</td>
    </tr>
  `).join('');
}

// --- Delivery: hand queued rewards to the console while this page is open ---
async function runDeliveryCycle() {
  if (isSandboxMode || window.__deliveryRunning) return;
  window.__deliveryRunning = true;
  const line = document.getElementById('deliveryStatusLine');
  try {
    const summary = await drainOutboxOnce(window.DuneAddon.request);
    const time = new Date().toLocaleTimeString();
    let text = `Delivery: active while this page is open. Last check ${time}`;
    if (summary.handedOver > 0) text += `, ${summary.handedOver} handed to the console`;
    if (summary.skipped.length > 0) text += `, ${summary.skipped.length} rejected as invalid`;
    if (summary.stoppedBy) text += `. Paused: ${summary.stoppedBy}`;
    if (line) line.textContent = `${text}.`;
    if (summary.handedOver > 0 || summary.skipped.length > 0) fetchPendingAirdrops();
  } catch (err) {
    if (line) line.textContent = `Delivery paused: ${err.message || err}`;
  } finally {
    window.__deliveryRunning = false;
  }
}

// --- Upgrade report: rewards imported from earlier versions ---
async function loadMigrationReport() {
  const panel = document.getElementById('migrationReport');
  if (!panel || isSandboxMode) return;
  try {
    const counts = await window.DuneAddon.request("database.query", {
      query: `SELECT count(*) FILTER (WHERE state = 'held')::int AS held,
                     count(*) FILTER (WHERE state = 'review')::int AS review
                FROM dune_airdrop.airdrop_reward_queue`
    });
    const manual = await window.DuneAddon.request("database.query", {
      query: `SELECT detail FROM dune_airdrop.airdrop_migration_log WHERE level = 'manual' ORDER BY id DESC LIMIT 50`
    });
    const c = (counts.rows || [])[0] || { held: 0, review: 0 };
    const steps = (manual.rows || []).map((r) => r.detail);
    if (!c.held && !c.review && steps.length === 0) {
      panel.classList.add('hidden');
      return;
    }
    panel.classList.remove('hidden');
    document.getElementById('migrationSummary').textContent =
      `The upgrade imported rewards the previous version never confirmed. ${c.held} are held (never attempted). ` +
      `${c.review} are uncertain (the old daemon may already have delivered them, so delivering again could duplicate). ` +
      'Nothing imported is delivered until you choose.';
    document.getElementById('migrationHeldActions').classList.toggle('hidden', !c.held);
    document.getElementById('migrationReviewActions').classList.toggle('hidden', !c.review);
    document.getElementById('migrationManualList').innerHTML = steps.length === 0 ? '' :
      '<div class="py-1.5 text-amber-400">Needs a database administrator:</div>' +
      steps.map((step) => `<div class="py-1.5 border-b border-slate-900/40 select-all">${escapeHTML(step)}</div>`).join('');
  } catch (err) {
    console.error('Failed to load upgrade report:', err);
  }
}

function setupMigrationActions() {
  const act = (id, fromState, toState, prompt) => {
    const button = document.getElementById(id);
    if (!button) return;
    button.addEventListener('click', async () => {
      if (!window.confirm(prompt)) return;
      try {
        await window.DuneAddon.request("database.execute", {
          query: toState === 'queued' ? releaseQuery(fromState) : discardQuery(fromState)
        });
        showToast(toState === 'queued' ? 'Released for delivery.' : 'Discarded.', 'success');
        await loadMigrationReport();
        await fetchPendingAirdrops();
      } catch (err) {
        showToast(`Failed: ${err.message}`, 'error');
      }
    });
  };
  act('releaseHeldBtn', 'held', 'queued', 'Deliver every held reward from the previous version?');
  act('discardHeldBtn', 'held', 'discarded', 'Discard every held reward from the previous version? They will not be delivered.');
  act('releaseReviewBtn', 'review', 'queued', 'These may already have been delivered by the old daemon. Deliver them anyway and risk duplicates?');
  act('discardReviewBtn', 'review', 'discarded', 'Discard every uncertain reward from the previous version?');
}

async function fetchContainers() {
  if (isSandboxMode) return;
  const tableBody = document.getElementById('lootContainersTableBody');
  if (!tableBody) return;

  try {
    const rawList = await window.DuneAddon.request("database.query", {
      query: `
        SELECT
          i.id::text as id,
          a.class,
          a.owner_account_id
        FROM dune.inventories i
        JOIN dune.actors a ON i.actor_id = a.id
        WHERE a.class ILIKE '%container%' OR a.class ILIKE '%chest%'
        LIMIT 100
      `
    });

    const containers = rawList.rows || rawList || [];

    if (containers.length === 0) {
      tableBody.innerHTML = `<tr><td colspan="4" class="py-4 text-center italic text-slate-500">No containers found.</td></tr>`;
      return;
    }

    tableBody.innerHTML = containers.map(c => {
      const cls = c.class ? c.class.split('/').pop().replace('_C', '') : 'Unknown';
      const isSelected = activeContainerId === c.id;
      const highlight = isSelected ? 'bg-amber-900/30 border-amber-500/50' : '';
      return `
        <tr id="container-row-${escapeHTML(c.id)}" class="container-row border-b border-slate-900/40 hover:bg-slate-900/20 font-mono text-xs cursor-pointer ${highlight}" onclick="window.selectContainer('${escapeHTML(c.id)}')">
          <td class="py-2 text-slate-400 font-bold">${escapeHTML(c.id)}</td>
          <td class="py-2 text-amber-500">${escapeHTML(cls)}</td>
          <td class="py-2 text-slate-300">${escapeHTML(c.owner_account_id || 'Unknown')}</td>
          <td class="py-2 text-center text-slate-500">-</td>
        </tr>
      `;
    }).join('');
  } catch (err) {
    console.error('Failed to load containers:', err);
    tableBody.innerHTML = `<tr><td colspan="4" class="py-4 text-center italic text-rose-500">Error: ${escapeHTML(err.message)}</td></tr>`;
  }
}


// --- UI Toasts ---
function showToast(message, type = 'success') {
  const container = document.getElementById('toastContainer');
  if (!container) return;

  const toast = document.createElement('div');
  toast.className = `pointer-events-auto flex items-center gap-2 px-4 py-3 rounded-lg border font-mono text-xs shadow-lg transition-all duration-300 transform translate-y-2 opacity-0`;

  if (type === 'success') {
    toast.className += ' bg-slate-900 border-emerald-500/30 text-emerald-400';
  } else if (type === 'error') {
    toast.className += ' bg-slate-900 border-rose-500/30 text-rose-400';
  } else {
    toast.className += ' bg-slate-900 border-amber-500/30 text-amber-400';
  }

  const icon = type === 'success' ? '✅' : (type === 'error' ? '❌' : '⚠️');
  toast.innerHTML = `<span>${icon}</span> <span class="flex-1">${escapeHTML(message)}</span>`;

  container.appendChild(toast);

  setTimeout(() => {
    toast.classList.remove('translate-y-2', 'opacity-0');
  }, 10);

  setTimeout(() => {
    toast.classList.add('translate-y-2', 'opacity-0');
    setTimeout(() => {
      toast.remove();
    }, 300);
  }, 4000);
}

// --- Mock Sandbox Loader ---
function loadMockData() {
  diagnosticsTableBody.innerHTML = `
    <tr class="border-b border-slate-900/40 font-mono text-xs">
      <td class="py-2 text-slate-300">PlayerOne</td>
      <td class="py-2 text-slate-400">42m / 60m</td>
      <td class="py-2 text-slate-400">18m left</td>
      <td class="py-2 text-right text-green-500 font-bold">COMPLETED</td>
    </tr>
    <tr class="border-b border-slate-900/40 font-mono text-xs">
      <td class="py-2 text-slate-300">Nalita</td>
      <td class="py-2 text-slate-400">59m / 60m</td>
      <td class="py-2 text-slate-400">1m left</td>
      <td class="py-2 text-right text-slate-600">PENDING</td>
    </tr>
  `;

  pendingAirdropsTableBody.innerHTML = `
    <tr class="border-b border-slate-900/40 font-mono text-xs">
      <td class="py-1.5 text-slate-300">PlayerOne</td>
      <td class="py-1.5 text-amber-500 font-bold">StandardSword</td>
      <td class="py-1.5 text-right text-slate-300 font-bold">1</td>
    </tr>
  `;
}

// Globals exports
window.handleSaveAllSettings = handleSaveAllSettings;
window.handleInitializeSchema = handleInitializeSchema;
window.showToast = showToast;

window.testResetDaily = async function(characterId) {
  try {
    const safeCharacterId = String(characterId);
    if (!/^[0-9]+$/.test(safeCharacterId)) throw new Error('Invalid character ID');
    await window.DuneAddon.request("database.execute", {
      query: `UPDATE dune_airdrop.airdrop_player_progress
              SET last_login_date = NULL, consecutive_days = 0
              WHERE character_id = ${safeCharacterId}::bigint`
    });
    showToast('Daily streak reset for player!', 'success');
    fetchDiagnostics();
  } catch (err) {
    showToast(`Failed to reset daily: ${err.message}`, 'error');
  }
};

window.testSetWeekly = async function(characterId) {
  try {
    const safeCharacterId = String(characterId);
    if (!/^[0-9]+$/.test(safeCharacterId)) throw new Error('Invalid character ID');
    // 31 in binary is 11111 (5 days)
    await window.DuneAddon.request("database.execute", {
      query: `UPDATE dune_airdrop.airdrop_player_progress
              SET weekly_login_mask = 31, last_weekly_claimed_at = NULL
              WHERE character_id = ${safeCharacterId}::bigint`
    });
    showToast('Weekly mask set to 5 days!', 'success');
    fetchDiagnostics();
  } catch (err) {
    showToast(`Failed to set weekly: ${err.message}`, 'error');
  }
};
