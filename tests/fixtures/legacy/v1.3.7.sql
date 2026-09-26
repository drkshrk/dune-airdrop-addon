-- PostgreSQL Playtime Airdrop Engine
-- Run this SQL on your Dune Awakening self-hosted PostgreSQL database.

-- Keep addon-owned objects outside the game schema and under the same role
-- used by Dune Docker Console. SET ROLE also normalizes ownership when this
-- script is launched manually as the postgres administrator.
CREATE SCHEMA IF NOT EXISTS dune_airdrop AUTHORIZATION dune;
SET ROLE dune;
SET LOCAL lock_timeout = '5s';

-- 1. Create playtime tracking table (supports coordinates, XP, anti-AFK validation, daily and weekly streaks)
CREATE TABLE IF NOT EXISTS dune_airdrop.active_playtime (
  character_id BIGINT PRIMARY KEY,
  active_seconds INT DEFAULT 0,
  last_xp BIGINT DEFAULT 0,
  last_x DOUBLE PRECISION DEFAULT 0.0,
  last_y DOUBLE PRECISION DEFAULT 0.0,
  last_z DOUBLE PRECISION DEFAULT 0.0,
  last_active_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  last_login_date DATE,
  consecutive_days INT DEFAULT 0,
  weekly_login_mask INT DEFAULT 0,
  current_week_id INT DEFAULT 0,
  last_weekly_claimed_at TIMESTAMP WITH TIME ZONE
);
-- Migration: Ensure types and columns exist for older installations
ALTER TABLE IF EXISTS dune_airdrop.active_playtime ALTER COLUMN character_id TYPE BIGINT USING character_id::bigint;
ALTER TABLE IF EXISTS dune_airdrop.active_playtime ADD COLUMN IF NOT EXISTS current_week_id INT DEFAULT 0;

-- 2. Create pending deliveries queue table
CREATE TABLE IF NOT EXISTS dune_airdrop.pending_deliveries (
  id SERIAL PRIMARY KEY,
  request_id UUID DEFAULT gen_random_uuid() UNIQUE,
  account_id BIGINT NOT NULL,
  template_id TEXT NOT NULL,
  stack_size INT NOT NULL,
  quality_level INT DEFAULT 0,
  is_applied BOOLEAN DEFAULT false,
  locked_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
ALTER TABLE IF EXISTS dune_airdrop.pending_deliveries ALTER COLUMN account_id TYPE BIGINT USING account_id::bigint;
ALTER TABLE IF EXISTS dune_airdrop.pending_deliveries ADD COLUMN IF NOT EXISTS locked_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE IF EXISTS dune_airdrop.pending_deliveries ADD COLUMN IF NOT EXISTS request_id UUID DEFAULT gen_random_uuid() UNIQUE;

-- 2.1 Create persistent delivery receipts table for idempotent grants
CREATE TABLE IF NOT EXISTS dune_airdrop.delivery_receipts (
  request_id UUID PRIMARY KEY,
  account_id BIGINT NOT NULL,
  template_id TEXT NOT NULL,
  quantity INT NOT NULL,
  status TEXT DEFAULT 'SUCCESS',
  granted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
ALTER TABLE IF EXISTS dune_airdrop.delivery_receipts ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'SUCCESS';

-- Notification function for the Node daemon
CREATE OR REPLACE FUNCTION dune_airdrop.trg_notify_pending_delivery_v2()
RETURNS trigger AS $$
BEGIN
  PERFORM pg_notify('new_airdrop', row_to_json(NEW)::text);
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Notification delivery must never reject a queued reward insert.
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3. Create the addon config table
CREATE TABLE IF NOT EXISTS dune_airdrop.config (
  config_key TEXT PRIMARY KEY,
  config_value JSONB
);

-- Insert default configurations if missing
INSERT INTO dune_airdrop.config (config_key, config_value)
VALUES
(
  'airdrop_multipliers',
  '{
    "playtime_enabled": true,
    "playtime_interval": 60,
    "playtime_distance": 10.0,
    "playtime_xp": 1,
    "playtime_multiplier_t0": 1,
    "playtime_multiplier_t1": 1,
    "playtime_multiplier_t2": 1,
    "playtime_multiplier_t3": 1,
    "playtime_multiplier_t4": 1,
    "playtime_multiplier_t5": 1,
    "playtime_multiplier_t6": 1,
    "daily_enabled": true,
    "daily_multiplier_step": 0.5,
    "daily_max_streak": 7,
    "weekly_enabled": true,
    "weekly_days_required": 5,
    "weekly_multiplier": 5.0
  }'::jsonb
),
(
  'daemon_heartbeat',
  '{"last_ping": "1970-01-01T00:00:00Z"}'::jsonb
),
(
  'airdrop_economy',
  '{
    "prob_gear": 0.40,
    "prob_schem": 0.80,
    "prob_raw": 1.0,
    "prob_craft": 1.0,
    "min_items": 1,
    "tier_0_min": 5, "tier_0_max": 10,
    "tier_1_min": 5, "tier_1_max": 15,
    "tier_2_min": 10, "tier_2_max": 25,
    "tier_3_min": 15, "tier_3_max": 35,
    "tier_4_min": 20, "tier_4_max": 50,
    "tier_5_min": 30, "tier_5_max": 75,
    "tier_6_min": 50, "tier_6_max": 100
  }'::jsonb
)
ON CONFLICT (config_key) DO NOTHING;

-- 4. Dynamic level and tier resolver
CREATE OR REPLACE FUNCTION dune_airdrop.fn_get_pawn_tier_v2(p_pawn_id BIGINT)
RETURNS INT AS $$
DECLARE
  v_xp BIGINT := 0;
  v_skill_points INT := 0;
  v_keystone_points INT := 0;
  v_level INT := 1;
  v_tier INT := 0;
BEGIN
  SELECT
    COALESCE((fe.components->'FLevelComponent'->1->>'TotalXPEarned')::bigint, 0),
    COALESCE((fe.components->'FLevelComponent'->1->>'TotalSkillPoints')::int, 0),
    COALESCE((fe.components->'FLevelComponent'->1->>'KeystoneBonusSkillPoints')::int, 0)
  INTO v_xp, v_skill_points, v_keystone_points
  FROM dune.actor_fgl_entities afe
  LEFT JOIN dune.fgl_entities fe ON fe.entity_id = afe.entity_id
  WHERE afe.actor_id = p_pawn_id AND afe.slot_name = 'DuneCharacter'
  LIMIT 1;

  IF v_skill_points > 0 THEN
    v_level := LEAST(200, v_skill_points - v_keystone_points + 1);
  ELSE
    v_level := LEAST(200, FLOOR(SQRT(v_xp / 100.0))::INT + 1);
  END IF;

  IF v_level IS NULL OR v_level < 1 THEN v_level := 1; END IF;

  IF v_level >= 150 THEN RETURN 6;
  ELSIF v_level >= 120 THEN RETURN 5;
  ELSIF v_level >= 80 THEN RETURN 4;
  ELSIF v_level >= 50 THEN RETURN 3;
  ELSIF v_level >= 20 THEN RETURN 2;
  ELSIF v_level >= 10 THEN RETURN 1;
  ELSE RETURN 0;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 5. Standard Item Rolling Sub-Routine
CREATE OR REPLACE FUNCTION dune_airdrop.fn_queue_reward_roll_v2(p_account_id BIGINT, p_tier INT, p_multiplier NUMERIC, p_reason TEXT)
RETURNS VOID AS $$
DECLARE
  v_gear_template TEXT;
  v_res_template_1 TEXT;
  v_res_template_2 TEXT;
  v_schem_template TEXT;
  v_gear_quality INT;
  v_res_qty_1 INT;
  v_res_qty_2 INT;
  v_num_rolls INT;
  v_econ JSONB;
  v_prob_gear NUMERIC := 0.40;
  v_prob_schem NUMERIC := 0.80;
  v_prob_raw NUMERIC := 1.0;
  v_prob_craft NUMERIC := 1.0;
  v_min_drops INT := 1;
  v_tier_min INT := 5;
  v_tier_max INT := 10;
  v_granted_count INT := 0;
  v_minimum_attempts INT := 0;
BEGIN
  v_num_rolls := GREATEST(1, ROUND(p_multiplier));

  SELECT config_value INTO v_econ FROM dune_airdrop.config WHERE config_key = 'airdrop_economy';
  IF v_econ IS NOT NULL THEN
    v_prob_gear := COALESCE((v_econ->>'prob_gear')::numeric, 0.40);
    v_prob_schem := COALESCE((v_econ->>'prob_schem')::numeric, 0.80);
    v_prob_raw := COALESCE((v_econ->>'prob_raw')::numeric, 1.0);
    v_prob_craft := COALESCE((v_econ->>'prob_craft')::numeric, 1.0);
    -- A reward roll has four distinct categories, so a larger minimum can
    -- never be satisfied and would otherwise leave the trigger looping.
    v_min_drops := LEAST(4, GREATEST(0, COALESCE((v_econ->>'min_items')::int, 1)));
    v_tier_min := COALESCE((v_econ->>('tier_' || p_tier || '_min'))::int, 5);
    v_tier_max := GREATEST(v_tier_min, COALESCE((v_econ->>('tier_' || p_tier || '_max'))::int, 10));
  END IF;

  FOR j IN 1..v_num_rolls LOOP
    v_granted_count := 0;
    v_gear_template := NULL;
    v_schem_template := NULL;
    v_res_template_1 := NULL;
    v_res_template_2 := NULL;
    v_minimum_attempts := 0;

    -- Initial Rolls
    IF RANDOM() <= v_prob_gear THEN
      SELECT template_id INTO v_gear_template FROM dune_airdrop.loot_tables WHERE tier = p_tier AND category = 'gear' ORDER BY RANDOM() * weight DESC LIMIT 1;
      IF v_gear_template IS NOT NULL THEN v_granted_count := v_granted_count + 1; v_gear_quality := 0; END IF;
    END IF;

    IF RANDOM() <= v_prob_raw THEN
      SELECT template_id INTO v_res_template_1 FROM dune_airdrop.loot_tables WHERE tier = p_tier AND category = 'raw_resources' ORDER BY RANDOM() * weight DESC LIMIT 1;
      IF v_res_template_1 IS NOT NULL THEN v_granted_count := v_granted_count + 1; END IF;
    END IF;

    IF RANDOM() <= v_prob_craft THEN
      SELECT template_id INTO v_res_template_2 FROM dune_airdrop.loot_tables WHERE tier = p_tier AND category = 'crafted_components' ORDER BY RANDOM() * weight DESC LIMIT 1;
      IF v_res_template_2 IS NOT NULL THEN v_granted_count := v_granted_count + 1; END IF;
    END IF;

    IF RANDOM() <= v_prob_schem THEN
      SELECT template_id INTO v_schem_template FROM dune_airdrop.loot_tables WHERE tier = p_tier AND category = 'schematics' ORDER BY RANDOM() * weight DESC LIMIT 1;
      IF v_schem_template IS NOT NULL THEN v_granted_count := v_granted_count + 1; END IF;
    END IF;

    -- Minimum guarantee
    WHILE v_granted_count < v_min_drops AND v_minimum_attempts < 32 LOOP
      v_minimum_attempts := v_minimum_attempts + 1;
      -- Pick a random missing category
      IF v_gear_template IS NULL AND RANDOM() < 0.25 THEN
        SELECT template_id INTO v_gear_template FROM dune_airdrop.loot_tables WHERE tier = p_tier AND category = 'gear' ORDER BY RANDOM() * weight DESC LIMIT 1;
        IF v_gear_template IS NOT NULL THEN v_granted_count := v_granted_count + 1; v_gear_quality := 0; END IF;
      ELSIF v_res_template_1 IS NULL AND RANDOM() < 0.5 THEN
        SELECT template_id INTO v_res_template_1 FROM dune_airdrop.loot_tables WHERE tier = p_tier AND category = 'raw_resources' ORDER BY RANDOM() * weight DESC LIMIT 1;
        IF v_res_template_1 IS NOT NULL THEN v_granted_count := v_granted_count + 1; END IF;
      ELSIF v_res_template_2 IS NULL AND RANDOM() < 0.75 THEN
        SELECT template_id INTO v_res_template_2 FROM dune_airdrop.loot_tables WHERE tier = p_tier AND category = 'crafted_components' ORDER BY RANDOM() * weight DESC LIMIT 1;
        IF v_res_template_2 IS NOT NULL THEN v_granted_count := v_granted_count + 1; END IF;
      ELSIF v_schem_template IS NULL THEN
        SELECT template_id INTO v_schem_template FROM dune_airdrop.loot_tables WHERE tier = p_tier AND category = 'schematics' ORDER BY RANDOM() * weight DESC LIMIT 1;
        IF v_schem_template IS NOT NULL THEN v_granted_count := v_granted_count + 1; END IF;
      END IF;

      -- Failsafe for infinite loop (e.g. no items in loot table for tier)
      IF v_gear_template IS NOT NULL AND v_res_template_1 IS NOT NULL AND v_res_template_2 IS NOT NULL AND v_schem_template IS NOT NULL THEN
        EXIT;
      END IF;
    END LOOP;

    v_res_qty_1 := GREATEST(1, (FLOOR(RANDOM() * (v_tier_max - v_tier_min + 1)) + v_tier_min)::INT);
    v_res_qty_2 := GREATEST(1, (FLOOR(RANDOM() * (v_tier_max - v_tier_min + 1)) + v_tier_min)::INT);

    -- Increase basic raw materials and ingots by 10x
    IF v_res_template_1 ILIKE '%ore%' OR v_res_template_1 ILIKE '%ingot%' OR v_res_template_1 ILIKE '%sand%' THEN
      v_res_qty_1 := v_res_qty_1 * 10;
    END IF;
    IF v_res_template_2 ILIKE '%ore%' OR v_res_template_2 ILIKE '%ingot%' OR v_res_template_2 ILIKE '%sand%' THEN
      v_res_qty_2 := v_res_qty_2 * 10;
    END IF;

    -- Queue items
    IF v_gear_template IS NOT NULL THEN
      INSERT INTO dune_airdrop.pending_deliveries (account_id, template_id, stack_size, is_applied, quality_level)
      VALUES (p_account_id, v_gear_template, 1, FALSE, v_gear_quality);
    END IF;

    IF v_res_template_1 IS NOT NULL THEN
      INSERT INTO dune_airdrop.pending_deliveries (account_id, template_id, stack_size, is_applied, quality_level)
      VALUES (p_account_id, v_res_template_1, v_res_qty_1, FALSE, 0);
    END IF;

    IF v_res_template_2 IS NOT NULL THEN
      INSERT INTO dune_airdrop.pending_deliveries (account_id, template_id, stack_size, is_applied, quality_level)
      VALUES (p_account_id, v_res_template_2, v_res_qty_2, FALSE, 0);
    END IF;

    IF v_schem_template IS NOT NULL THEN
      INSERT INTO dune_airdrop.pending_deliveries (account_id, template_id, stack_size, is_applied, quality_level)
      VALUES (p_account_id, v_schem_template, 1, FALSE, 0);
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 6. Playtime Reward Rolling logic wrapper
CREATE OR REPLACE FUNCTION dune_airdrop.fn_roll_playtime_reward_v2(p_account_id BIGINT, p_pawn_id BIGINT)
RETURNS VOID AS $$
DECLARE
  v_tier INT;
  v_config JSONB;
  v_multiplier NUMERIC := 1.0;
BEGIN
  v_tier := dune_airdrop.fn_get_pawn_tier_v2(p_pawn_id);

  SELECT config_value INTO v_config FROM dune_airdrop.config WHERE config_key = 'airdrop_multipliers';
  IF v_config IS NOT NULL THEN
    v_multiplier := COALESCE((v_config->>('playtime_multiplier_t' || v_tier::text))::numeric, 1.0);
  END IF;
  IF v_multiplier < 1.0 THEN v_multiplier := 1.0; END IF;

  PERFORM dune_airdrop.fn_queue_reward_roll_v2(p_account_id, v_tier, v_multiplier, 'playtime');
END;
$$ LANGUAGE plpgsql;

-- 7. Deliver pending rewards instantly without relogs
CREATE OR REPLACE FUNCTION dune_airdrop.fn_deliver_playtime_airdrops_v2(p_account_id BIGINT, p_pawn_id BIGINT)
RETURNS VOID AS $$
DECLARE
  v_inv_id INT;
  v_item RECORD;
BEGIN
  SELECT id INTO v_inv_id
  FROM dune.inventories
  WHERE actor_id = p_pawn_id AND inventory_type = 0
  LIMIT 1;

  IF v_inv_id IS NOT NULL THEN
    FOR v_item IN
      SELECT id, template_id, stack_size, quality_level
      FROM dune_airdrop.pending_deliveries
      WHERE account_id = p_account_id AND is_applied = FALSE
    LOOP
      INSERT INTO dune.items (inventory_id, template_id, stack_size, position_index, stats, quality_level)
      VALUES (
        v_inv_id,
        v_item.template_id,
        v_item.stack_size,
        (SELECT COALESCE(MAX(position_index) + 1, 0) FROM dune.items WHERE inventory_id = v_inv_id),
        CASE
          WHEN v_item.quality_level > 0 OR v_item.stack_size = 1 THEN
            '{"FCustomizationStats": [[], {}], "FItemStackAndDurabilityStats": [[], {"CurrentDurability": 1000, "MaxDurability": 1000, "DecayedMaxDurability": 1000}], "FWeaponItemStats": [[], {"CurrentAmmo": 0}]}'::jsonb
          ELSE
            '{"FItemStackAndDurabilityStats": [[], {"DecayedMaxDurability": 0.0}]}'::jsonb
        END,
        v_item.quality_level
      );

      UPDATE dune_airdrop.pending_deliveries
      SET is_applied = TRUE
      WHERE id = v_item.id;
    END LOOP;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 8. Daily and Weekly rewards check function executed on login/save
CREATE OR REPLACE FUNCTION dune_airdrop.fn_check_daily_weekly_rewards_v2(p_account_id BIGINT, p_pawn_id BIGINT)
RETURNS VOID AS $$
DECLARE
  v_config JSONB;
  v_today DATE := CURRENT_DATE;
  v_track RECORD;
  v_tier INT;

  v_daily_enabled BOOLEAN := TRUE;
  v_daily_step NUMERIC := 0.5;
  v_daily_max INT := 7;

  v_weekly_enabled BOOLEAN := TRUE;
  v_weekly_req INT := 5;
  v_weekly_scale NUMERIC := 5.0;

  v_streak INT := 1;
  v_multiplier NUMERIC := 1.0;
  v_weekly_days_count INT := 0;
  v_mask INT := 0;
  v_current_week_id INT;
  v_day_of_week INT;
  v_i INT;
BEGIN
  -- Load configurations
  SELECT config_value INTO v_config FROM dune_airdrop.config WHERE config_key = 'airdrop_multipliers';
  IF v_config IS NOT NULL THEN
    v_daily_enabled := COALESCE((v_config->>'daily_enabled')::boolean, TRUE);
    v_daily_step := COALESCE((v_config->>'daily_multiplier_step')::numeric, 0.5);
    v_daily_max := COALESCE((v_config->>'daily_max_streak')::int, 7);
    v_weekly_enabled := COALESCE((v_config->>'weekly_enabled')::boolean, TRUE);
    v_weekly_req := COALESCE((v_config->>'weekly_days_required')::int, 5);
    v_weekly_scale := COALESCE((v_config->>'weekly_multiplier')::numeric, 5.0);
  END IF;

  v_tier := dune_airdrop.fn_get_pawn_tier_v2(p_pawn_id);

  -- Determine the current Coriolis Week ID and Day of Week
  -- Coriolis hits Tuesday ~05:00 UTC. We will use Tuesday 00:00 as the exact start of the week.
  -- By shifting ISO day backwards by 1 (i.e. CURRENT_DATE - INTERVAL '1 day'), Tuesday becomes the start of the ISO week.
  v_current_week_id := (EXTRACT(YEAR FROM v_today - INTERVAL '1 day')::INT * 100) + EXTRACT(WEEK FROM v_today - INTERVAL '1 day')::INT;

  -- Calculate day of week index relative to Tuesday (0 = Tuesday, 1 = Wednesday, ... 6 = Monday)
  -- ISODOW returns 1 (Monday) to 7 (Sunday)
  v_day_of_week := (EXTRACT(ISODOW FROM v_today)::INT + 5) % 7;

  -- Fetch player stats record with FOR UPDATE to prevent concurrent duplicate rewards
  SELECT * INTO v_track FROM dune_airdrop.active_playtime WHERE character_id = p_pawn_id FOR UPDATE;
  IF v_track.character_id IS NULL THEN
    -- Initialize if missing
    INSERT INTO dune_airdrop.active_playtime (character_id, last_login_date, consecutive_days, weekly_login_mask, current_week_id)
    VALUES (p_pawn_id, v_today - INTERVAL '1 day', 0, 0, v_current_week_id);

    v_track.last_login_date := v_today - INTERVAL '1 day';
    v_track.consecutive_days := 0;
    v_track.weekly_login_mask := 0;
    v_track.current_week_id := v_current_week_id;
  END IF;

  -- Process Daily Reward (Only once per calendar date)
  IF v_track.last_login_date IS NULL OR v_track.last_login_date < v_today THEN
    -- Calculate consecutive daily streak
    IF v_track.last_login_date = v_today - 1 THEN
      v_streak := LEAST(v_daily_max, v_track.consecutive_days + 1);
    ELSE
      v_streak := 1;
    END IF;

    -- Update weekly mask based on Coriolis cycle
    IF COALESCE(v_track.current_week_id, 0) != v_current_week_id THEN
      -- A new Coriolis cycle has begun! Reset the mask for the new week.
      v_mask := (1 << v_day_of_week);
    ELSE
      -- Still in the same cycle. Set the bit for today.
      v_mask := v_track.weekly_login_mask | (1 << v_day_of_week);
    END IF;

    -- Update tracking stats
    UPDATE dune_airdrop.active_playtime
    SET
      last_login_date = v_today,
      consecutive_days = v_streak,
      weekly_login_mask = v_mask,
      current_week_id = v_current_week_id
    WHERE character_id = p_pawn_id;

    -- Roll and Deliver Daily Reward if enabled
    IF v_daily_enabled THEN
      v_multiplier := 1.0 + ((v_streak - 1) * v_daily_step);
      PERFORM dune_airdrop.fn_queue_reward_roll_v2(p_account_id, v_tier, v_multiplier, 'daily');
    END IF;

    -- Process Weekly Attendance Reward (If enabled and threshold met)
    IF v_weekly_enabled THEN
      -- Count set bits in 7-day mask
      v_weekly_days_count := 0;
      FOR v_i IN 0..6 LOOP
        IF ((v_mask >> v_i) & 1) = 1 THEN
          v_weekly_days_count := v_weekly_days_count + 1;
        END IF;
      END LOOP;

      -- Check if target is met and we haven't already claimed weekly attendance this week
      IF v_weekly_days_count >= v_weekly_req THEN
        IF v_track.last_weekly_claimed_at IS NULL OR
           ((EXTRACT(YEAR FROM v_track.last_weekly_claimed_at - INTERVAL '1 day')::INT * 100) + EXTRACT(WEEK FROM v_track.last_weekly_claimed_at - INTERVAL '1 day')::INT) != v_current_week_id THEN

          PERFORM dune_airdrop.fn_queue_reward_roll_v2(p_account_id, v_tier, v_weekly_scale, 'weekly');

          UPDATE dune_airdrop.active_playtime
          SET last_weekly_claimed_at = NOW()
          WHERE character_id = p_pawn_id;
        END IF;
      END IF;
    END IF;

  END IF;
END;
$$ LANGUAGE plpgsql;

-- 9. Trigger handler running on player updates
CREATE OR REPLACE FUNCTION dune_airdrop.trg_track_playtime_v2()
RETURNS TRIGGER AS $$
DECLARE
  v_delta_seconds INT;
  v_prev_active TIMESTAMP WITH TIME ZONE;
  v_config JSONB;
  v_daemon JSONB;
  v_last_ping TIMESTAMP WITH TIME ZONE;

  v_playtime_enabled BOOLEAN := TRUE;
  v_interval_min INT := 60;
  v_min_dist DOUBLE PRECISION := 10.0;
  v_min_xp INT := 1;

  v_curr_xp BIGINT := 0;
  v_x DOUBLE PRECISION := 0.0;
  v_y DOUBLE PRECISION := 0.0;
  v_z DOUBLE PRECISION := 0.0;

  v_track RECORD;
  v_dist DOUBLE PRECISION;
  v_xp_diff BIGINT;
  v_is_active BOOLEAN := FALSE;
  v_accumulated_seconds INT;
BEGIN
  -- Daemon heartbeat check removed so DB handles tracking


  -- Only track if player's online status is 'online'
  IF LOWER(NEW.online_status::text) = 'online' THEN
    -- THROTTLE: Prevent lag spikes from rapid inventory updates (e.g. dumping items in containers)
    -- Check when we last evaluated this player. If it was less than 60 seconds ago, exit early.
    SELECT last_active_at INTO v_prev_active
    FROM dune_airdrop.active_playtime
    WHERE character_id = NEW.player_pawn_id;

    IF v_prev_active IS NOT NULL THEN
      v_delta_seconds := EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - v_prev_active))::INT;
      IF v_delta_seconds < 60 THEN
        RETURN NEW;
      END IF;
    END IF;

    -- Load configurations
    SELECT config_value INTO v_config FROM dune_airdrop.config WHERE config_key = 'airdrop_multipliers';
    IF v_config IS NOT NULL THEN
      v_playtime_enabled := COALESCE((v_config->>'playtime_enabled')::boolean, TRUE);
      v_interval_min := COALESCE((v_config->>'playtime_interval')::int, 60);
      v_min_dist := COALESCE((v_config->>'playtime_distance')::double precision, 10.0);
      v_min_xp := COALESCE((v_config->>'playtime_xp')::int, 1);
    END IF;
    IF v_interval_min < 1 THEN v_interval_min := 60; END IF;

    -- Handle daily/weekly login claims instantly on online save
    PERFORM dune_airdrop.fn_check_daily_weekly_rewards_v2(NEW.account_id, NEW.player_pawn_id);

    -- Fetch current coordinates and XP
    SELECT
      COALESCE((fe.components->'FLevelComponent'->1->>'TotalXPEarned')::bigint, 0)
    INTO v_curr_xp
    FROM dune.actor_fgl_entities afe
    LEFT JOIN dune.fgl_entities fe ON fe.entity_id = afe.entity_id
    WHERE afe.actor_id = NEW.player_pawn_id AND afe.slot_name = 'DuneCharacter'
    LIMIT 1;

    -- Extract translation coordinates safely
    IF NEW.player_pawn_id IS NOT NULL THEN
      SELECT
        ((transform).location).x::double precision,
        ((transform).location).y::double precision,
        ((transform).location).z::double precision
      INTO v_x, v_y, v_z
      FROM dune.actors
      WHERE id = NEW.player_pawn_id;
    END IF;

    -- Get previous active status
    SELECT * INTO v_track
    FROM dune_airdrop.active_playtime
    WHERE character_id = NEW.player_pawn_id;

    IF v_track.character_id IS NOT NULL THEN
      -- Calculate seconds passed since last save/update
      v_delta_seconds := EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - v_track.last_active_at))::INT;

      -- Limit delta to 600 seconds (10 minutes) per save to accommodate the engine's 5-minute auto-save
      -- and to avoid offline time-jumps when a player logs back in after days
      IF v_delta_seconds > 0 AND v_delta_seconds < 600 THEN
        -- AFK check logic
        v_dist := SQRT(POWER(v_x - v_track.last_x, 2) + POWER(v_y - v_track.last_y, 2) + POWER(v_z - v_track.last_z, 2));
        v_xp_diff := v_curr_xp - v_track.last_xp;

        IF v_min_dist = 0.0 AND v_min_xp = 0 THEN
          v_is_active := TRUE;
        ELSE
          IF v_min_dist > 0.0 AND v_dist >= v_min_dist THEN v_is_active := TRUE; END IF;
          IF v_min_xp > 0 AND v_xp_diff >= v_min_xp THEN v_is_active := TRUE; END IF;
        END IF;

        IF v_is_active THEN
          v_accumulated_seconds := v_track.active_seconds + v_delta_seconds;

          -- Check if playtime threshold is achieved (and playtime airdrops are enabled)
          IF v_playtime_enabled AND v_accumulated_seconds >= (v_interval_min * 60) THEN
            -- Roll reward pack
            PERFORM dune_airdrop.fn_roll_playtime_reward_v2(NEW.account_id, NEW.player_pawn_id);
            v_accumulated_seconds := 0;
          END IF;

          UPDATE dune_airdrop.active_playtime
          SET
            active_seconds = v_accumulated_seconds,
            last_xp = v_curr_xp,
            last_x = v_x,
            last_y = v_y,
            last_z = v_z,
            last_active_at = CURRENT_TIMESTAMP
          WHERE character_id = NEW.player_pawn_id;
        ELSE
          -- Idle player, update timestamp but do not count active seconds
          UPDATE dune_airdrop.active_playtime
          SET last_active_at = CURRENT_TIMESTAMP
          WHERE character_id = NEW.player_pawn_id;
        END IF;
      ELSE
        -- Update timestamp without adding playtime if time jump is too large (e.g. initial login)
        UPDATE dune_airdrop.active_playtime
        SET last_active_at = CURRENT_TIMESTAMP
        WHERE character_id = NEW.player_pawn_id;
      END IF;
    ELSE
      -- Initialize playtime record for new character
      INSERT INTO dune_airdrop.active_playtime (character_id, active_seconds, last_xp, last_x, last_y, last_z, last_active_at)
      VALUES (NEW.player_pawn_id, 0, v_curr_xp, v_x, v_y, v_z, CURRENT_TIMESTAMP);
    END IF;
  ELSE
    -- Player went offline, invalidate active timestamp to prevent counting while offline
    UPDATE dune_airdrop.active_playtime
    SET last_active_at = NULL
    WHERE character_id = NEW.player_pawn_id;
  END IF;

  -- Force direct delivery run on save to catch any lingering drops
  IF NEW.online_status::text = 'Online' THEN
    -- Native delivery disabled so Node daemon can handle instant delivery via RCON
    -- PERFORM dune_airdrop.fn_deliver_playtime_airdrops_v2(NEW.account_id, NEW.player_pawn_id);
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- A rewards failure must never reject the game's player-state update.
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 10. Install the trigger on the underlying encrypted_player_state table updates (since player_state is a view)
DROP TRIGGER IF EXISTS trg_player_state_playtime ON dune.player_state;
DROP TRIGGER IF EXISTS trg_player_state_playtime ON dune.encrypted_player_state;
CREATE TRIGGER trg_player_state_playtime
AFTER UPDATE ON dune.encrypted_player_state
FOR EACH ROW
EXECUTE FUNCTION dune_airdrop.trg_track_playtime_v2();

-- Initial diagnostics print
SELECT 'Arrakis Playtime Airdrop database trigger configured successfully!' AS status;
-- [BEGIN AUTO-GENERATED LOOT POOLS]
-- ==========================================
-- AUTO-GENERATED BY generate_sql_loot.js
-- DO NOT EDIT THIS BLOCK MANUALLY
-- ==========================================

CREATE TABLE IF NOT EXISTS dune_airdrop.loot_tables (
  tier INT,
  category TEXT,
  template_id TEXT,
  weight INT,
  UNIQUE(tier, category, template_id)
);

INSERT INTO dune_airdrop.loot_tables (tier, category, template_id, weight) VALUES
(0, 'raw_resources', 'PlantFiber', 100),
(0, 'crafted_components', 'ScrapMetal', 100),
(0, 'crafted_components', 'SolarisCoin', 10),
(0, 'raw_resources', 'Stone', 100),
(0, 'gear', 'Social_Atre_Casual03_Bottom', 100),
(0, 'gear', 'Social_Atre_Casual03_Shoes', 100),
(0, 'gear', 'Social_Atre_Casual03_Top', 100),
(0, 'gear', 'Social_Hark_GiediCasual03_Boots', 100),
(0, 'gear', 'Social_Hark_GiediCasual03_Bottom', 100),
(0, 'gear', 'Social_Hark_GiediCasual03_Top', 100),
(0, 'gear', 'Social_Smug_EntrepreneurCasual03_Boots', 100),
(0, 'gear', 'Social_Smug_EntrepreneurCasual03_Bottom', 100),
(0, 'gear', 'Social_Smug_EntrepreneurCasual03_Gloves', 100),
(0, 'gear', 'Social_Smug_EntrepreneurCasual03_Top', 100),
(0, 'gear', 'Stillsuit_Neut_Leaking01_Boots', 100),
(0, 'gear', 'Stillsuit_Neut_Leaking01_Gloves', 100),
(0, 'gear', 'Stillsuit_Neut_Leaking01_Mask', 100),
(0, 'gear', 'Stillsuit_Neut_Leaking01_Top', 100),
(0, 'gear', 'Combat_Light_Unique_Story_Jackal_Helmet', 100),
(0, 'gear', 'Social_Atre_Casual03_Unique_Story_TheBloodline_Bottom', 100),
(0, 'gear', 'Social_Atre_Casual03_Unique_Story_TheBloodline_Shoes', 100),
(0, 'gear', 'Combat_Hark_MedUnique01_Boots', 100),
(0, 'gear', 'Combat_Hark_MedUnique02_Boots', 100),
(0, 'gear', 'Combat_Nati_SandtroutLeathers01_Boots', 100),
(0, 'gear', 'Combat_Nati_ScavengerRags02_Boots', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique01_Boots', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique02_Boots', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique03_Boots', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique04_Boots', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique05_Boots', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique06_Boots', 100),
(0, 'gear', 'Combat_Hark_MedUnique01_Gloves', 100),
(0, 'gear', 'Combat_Hark_MedUnique02_Gloves', 100),
(0, 'gear', 'Combat_Nati_SandtroutLeathers01_Gloves', 100),
(0, 'gear', 'Combat_Nati_ScavengerRags02_Gloves', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique01_Gloves', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique02_Gloves', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique03_Gloves', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique04_Gloves', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique05_Gloves', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique06_Gloves', 100),
(0, 'gear', 'Combat_Hark_MedUnique01_Helmet', 100),
(0, 'gear', 'Combat_Hark_MedUnique02_Helmet', 100),
(0, 'gear', 'Combat_Nati_SandtroutLeathers01_Helmet', 100),
(0, 'gear', 'Combat_Nati_ScavengerRags02_Helmet', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique01_Helmet', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique02_Helmet', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique03_Helmet', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique04_Helmet', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique05_Helmet', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique06_Helmet', 100),
(0, 'gear', 'Social_Neut_Unique_Story_ProcesVerbal_NobleMask', 100),
(0, 'gear', 'Combat_Atre_Med01_Bottom', 100),
(0, 'gear', 'Combat_Hark_MedUnique01_Bottom', 100),
(0, 'gear', 'Combat_Hark_MedUnique02_Bottom', 100),
(0, 'gear', 'Combat_Nati_SandtroutLeathers01_Bottom', 100),
(0, 'gear', 'Combat_Nati_ScavengerRags02_Bottom', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique01_Bottom', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique02_Bottom', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique03_Bottom', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique04_Bottom', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique05_Bottom', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique06_Bottom', 100),
(0, 'gear', 'Combat_Atre_Med01_Top', 100),
(0, 'gear', 'Combat_Hark_MedUnique01_Top', 100),
(0, 'gear', 'Combat_Hark_MedUnique02_Top', 100),
(0, 'gear', 'Combat_Hark_Scout05_Top', 100),
(0, 'gear', 'Combat_Nati_SandtroutLeathers01_Top', 100),
(0, 'gear', 'Combat_Nati_ScavengerRags02_Top', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique01_Top', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique02_Top', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique03_Top', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique04_Top', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique05_Top', 100),
(0, 'gear', 'Combat_Neut_SmugglerDeserterUnique06_Top', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique01_Boots', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique02_Boots', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique03_Boots', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique04_Boots', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique05_Boots', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique01_Gloves', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique02_Gloves', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique03_Gloves', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique04_Gloves', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique05_Gloves', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique01_Helmet', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique02_Helmet', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique03_Helmet', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique04_Helmet', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique05_Helmet', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique01_Bottom', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique02_Bottom', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique03_Bottom', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique04_Bottom', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique05_Bottom', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique01_Top', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique02_Top', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique03_Top', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique04_Top', 100),
(0, 'gear', 'Combat_Neut_AtreidesDeserterUnique05_Top', 100),
(0, 'gear', 'MTX_Stillsuit_Smuggler_Boots', 100),
(0, 'gear', 'MTX_Stillsuit_Smuggler_Gloves', 100),
(0, 'gear', 'MTX_Stillsuit_Smuggler_Helmet', 100),
(0, 'gear', 'MTX_Stillsuit_Smuggler_Top', 100),
(0, 'gear', 'Combat_Light_Unique_BeneGeserit_Boots', 100),
(0, 'gear', 'Combat_Light_Unique_BeneGeserit_Gloves', 100),
(0, 'gear', 'Combat_Light_Unique_BeneGeserit_Helmet', 100),
(0, 'gear', 'Combat_Light_Unique_BeneGeserit_Bottom', 100),
(0, 'gear', 'Combat_Light_Unique_BeneGeserit_Top', 100),
(0, 'gear', 'Combat_Light_Unique_Mentat_Boots', 100),
(0, 'gear', 'MTX_D_Combat_Light_Smuggler_Boots', 100),
(0, 'gear', 'Combat_Light_Unique_Mentat_Gloves', 100),
(0, 'gear', 'MTX_D_Combat_Light_Smuggler_Gloves', 100),
(0, 'gear', 'Combat_Light_Unique_Mentat_Helmet', 100),
(0, 'gear', 'MTX_D_Combat_Light_Smuggler_Helmet', 100),
(0, 'gear', 'Combat_Light_Unique_Mentat_Bottom', 100),
(0, 'gear', 'MTX_D_Combat_Light_Smuggler_Bottom', 100),
(0, 'gear', 'Combat_Light_Unique_Mentat_Top', 100),
(0, 'gear', 'MTX_D_Combat_Light_Smuggler_Top', 100),
(0, 'gear', 'Stillsuit_Unique_Planetologist_Boots', 100),
(0, 'gear', 'Stillsuit_Unique_Planetologist_Gloves', 100),
(0, 'gear', 'Stillsuit_Unique_Planetologist_Helmet', 100),
(0, 'gear', 'Stillsuit_Unique_Planetologist_Bottom', 100),
(0, 'gear', 'Stillsuit_Unique_Planetologist_Top', 100),
(0, 'gear', 'Combat_Heavy_Unique_Swordmaster_Boots', 100),
(0, 'gear', 'MTX_D_Combat_Heavy_Smuggler_Boots', 100),
(0, 'gear', 'Combat_Heavy_Unique_Swordmaster_Gloves', 100),
(0, 'gear', 'MTX_D_Combat_Heavy_Smuggler_Gloves', 100),
(0, 'gear', 'Combat_Heavy_Unique_Swordmaster_Helmet', 100),
(0, 'gear', 'MTX_D_Combat_Heavy_Smuggler_Helmet', 100),
(0, 'gear', 'Combat_Heavy_Unique_Swordmaster_Bottom', 100),
(0, 'gear', 'MTX_D_Combat_Heavy_Smuggler_Bottom', 100),
(0, 'gear', 'Combat_Heavy_Unique_Swordmaster_Top', 100),
(0, 'gear', 'MTX_D_Combat_Heavy_Smuggler_Top', 100),
(0, 'gear', 'Combat_Heavy_Unique_Trooper_Boots', 100),
(0, 'gear', 'Combat_Heavy_Unique_Trooper_Gloves', 100),
(0, 'gear', 'Combat_Heavy_Unique_Trooper_Helmet', 100),
(0, 'gear', 'Combat_Heavy_Unique_Trooper_Bottom', 100),
(0, 'gear', 'Combat_Heavy_Unique_Trooper_Top', 100),
(0, 'gear', 'Combat_Light_SpiceMask', 100),
(0, 'gear', 'Social_Neut_ImperialCasual_Top', 100),
(0, 'gear', 'Social_Neut_ImperialCasual_Boots', 100),
(0, 'gear', 'Social_Atre_Casual03_Unique_Story_TheBloodline_Top', 100),
(0, 'gear', 'Combat_Heavy_B1C4_Unique_Top1', 100),
(0, 'gear', 'Combat_Light_B1C4_Unique_Top1', 100),
(0, 'gear', 'Combat_Light_B1C4_Unique_Helmet1', 100),
(0, 'gear', 'InsulatedCryo_Combat_Heavy06_Unique_Boots', 100),
(0, 'gear', 'InsulatedCryo_Combat_Heavy06_Unique_Gloves', 100),
(0, 'gear', 'InsulatedCryo_Combat_Heavy06_Unique_Helmet', 100),
(0, 'gear', 'InsulatedCryo_Combat_Heavy06_Unique_Bottom', 100),
(0, 'gear', 'InsulatedCryo_Combat_Heavy06_Unique_Top', 100),
(0, 'gear', 'InsulatedCryo_Combat_Light06_Unique_Boots', 100),
(0, 'gear', 'InsulatedCryo_Combat_Light06_Unique_Gloves', 100),
(0, 'gear', 'InsulatedCryo_Combat_Light06_Unique_Helmet', 100),
(0, 'gear', 'InsulatedCryo_Combat_Light06_Unique_Bottom', 100),
(0, 'gear', 'InsulatedCryo_Combat_Light06_Unique_Top', 100),
(0, 'gear', 'Exoskeleton_Heavy06_Unique_Top', 100),
(0, 'gear', 'Assassin_Light06_Unique_Helmet', 100),
(0, 'gear', 'Assassin_Light06_Unique_Top', 100),
(0, 'gear', 'MTX_Combat_Heavy_Watershippers_Boots', 100),
(0, 'gear', 'MTX_Combat_Heavy_Watershippers_Gloves', 100),
(0, 'gear', 'MTX_Combat_Heavy_Watershippers_Helmet', 100),
(0, 'gear', 'MTX_Combat_Heavy_Watershippers_Bottom', 100),
(0, 'gear', 'MTX_Combat_Heavy_Watershippers_Top', 100),
(0, 'gear', 'MTX_Stillsuit_Watershippers_Boots', 100),
(0, 'gear', 'MTX_Stillsuit_Watershippers_Gloves', 100),
(0, 'gear', 'MTX_Stillsuit_Watershippers_Helmet', 100),
(0, 'gear', 'MTX_Stillsuit_Watershippers_Top', 100),
(0, 'gear', 'MTX_Combat_Assault_Watershippers_Boots', 100),
(0, 'gear', 'MTX_Combat_Assault_Watershippers_Gloves', 100),
(0, 'gear', 'MTX_Combat_Assault_Watershippers_Helmet', 100),
(0, 'gear', 'MTX_Combat_Assault_Watershippers_Bottom', 100),
(0, 'gear', 'MTX_Combat_Assault_Watershippers_Top', 100),
(0, 'gear', 'BoostAbility', 100),
(0, 'gear', 'BoostOneShotAbility', 100),
(0, 'gear', 'BuggyBoost_0', 100),
(0, 'gear', 'BuggyBoost_7', 100),
(0, 'gear', 'BuggyChassis_0', 100),
(0, 'gear', 'BuggyChassis_7', 100),
(0, 'gear', 'BuggyEngine_0', 100),
(0, 'gear', 'BuggyEngine_7', 100),
(0, 'gear', 'BuggyGenerator_0', 100),
(0, 'gear', 'BuggyGenerator_7', 100),
(0, 'gear', 'BuggyGenerator_PolarCap_6', 100),
(0, 'gear', 'BuggyHullBack_0', 100),
(0, 'gear', 'BuggyHullBack_7', 100),
(0, 'gear', 'BuggyHullBackExtra_0', 100),
(0, 'gear', 'BuggyHullBackExtra_7', 100),
(0, 'gear', 'BuggyHullFront_0', 100),
(0, 'gear', 'BuggyHullFront_7', 100),
(0, 'gear', 'BuggyInventory_0', 100),
(0, 'gear', 'BuggyInventory_7', 100),
(0, 'gear', 'BuggyLauncher_0', 100),
(0, 'gear', 'BuggyLocomotion_0', 100),
(0, 'gear', 'BuggyLocomotion_7', 100),
(0, 'gear', 'BuggyMining_0', 100),
(0, 'gear', 'BuggyMining_Polarcap_6', 100),
(0, 'gear', 'ContainerVehicle', 100),
(0, 'gear', 'MOrnithopterLasgunAbility', 100),
(0, 'gear', 'MOrnithopterRocketsAbility', 100),
(0, 'gear', 'OrnithopterDashAbility', 100),
(0, 'gear', 'OrnithopterHarnessAbility', 100),
(0, 'gear', 'OrnithopterLasgunAbility', 100),
(0, 'gear', 'OrnithopterLightChassis_0', 100),
(0, 'gear', 'OrnithopterLightEngine_0', 100),
(0, 'gear', 'OrnithopterLightGenerator_0', 100),
(0, 'gear', 'OrnithopterLightGenerator_PolarCap_6', 100),
(0, 'gear', 'OrnithopterLightHullFront_0', 100),
(0, 'gear', 'OrnithopterLightLocomotion_0', 100),
(0, 'gear', 'OrnithopterLightScanner_4', 100),
(0, 'gear', 'OrnithopterMediumGenerator_PolarCap_6', 100),
(0, 'gear', 'OrnithopterRocketsAbility', 100),
(0, 'gear', 'OrnithopterScannerDirectionalAbility', 100),
(0, 'gear', 'OrnithopterScannerOmniAbility', 100),
(0, 'gear', 'OrnithopterTransportBoostAbility', 100),
(0, 'gear', 'OrnithopterTransportGenerator_PolarCap_6', 100),
(0, 'gear', 'OrnithopterTransportLocomotion_Unique_Speed_6', 100),
(0, 'gear', 'OrnithopterVultureAbility', 100),
(0, 'gear', 'SandbikeBoost_0', 100),
(0, 'gear', 'SandbikeBoost_7', 100),
(0, 'gear', 'SandbikeChassis_0', 100),
(0, 'gear', 'SandbikeChassis_7', 100),
(0, 'gear', 'SandbikeEngine_0', 100),
(0, 'gear', 'SandbikeEngine_7', 100),
(0, 'gear', 'SandbikeGenerator_0', 100),
(0, 'gear', 'SandbikeGenerator_7', 100),
(0, 'gear', 'SandbikeGenerator_PolarCap_6', 100),
(0, 'gear', 'SandbikeHull_0', 100),
(0, 'gear', 'SandbikeHull_7', 100),
(0, 'gear', 'SandbikeInventory_0', 100),
(0, 'gear', 'SandbikeInventory_7', 100),
(0, 'gear', 'SandbikeLocomotion_0', 100),
(0, 'gear', 'SandbikeLocomotion_7', 100),
(0, 'gear', 'SandbikeScanner_7', 100),
(0, 'gear', 'SandbikeScannerDirectionalAbility', 100),
(0, 'gear', 'SandbikeSeat_0', 100),
(0, 'gear', 'SandcrawlerSpiceContainer_Unique_Capacity_6', 100),
(0, 'gear', 'SandcrawlerSpiceHeader_Unique_YieldIncrease_6', 100),
(0, 'gear', 'SeekerChassis', 100),
(0, 'gear', 'SeekerDashAbility', 100),
(0, 'gear', 'ThrusterAbility', 100),
(0, 'gear', 'TreadwheelGenerator_PolarCap_6', 100),
(0, 'gear', 'TreadwheelLocomotion_0', 100),
(0, 'gear', 'VehicleHarvestingAbility', 100),
(0, 'gear', 'VehicleBackupTool', 100),
(0, 'gear', 'UniqueSword', 100),
(0, 'gear', 'UniqueSmg3', 100),
(0, 'gear', 'UniqueSmg2', 100),
(0, 'gear', 'UniqueSmg1', 100),
(0, 'gear', 'UniqueSda6', 100),
(0, 'gear', 'UniqueSda5', 100),
(0, 'gear', 'UniqueSda4', 100),
(0, 'gear', 'UniqueSda3', 100),
(0, 'gear', 'UniqueSda2', 100),
(0, 'gear', 'UniqueSda1', 100),
(0, 'gear', 'UniqueScattergun5', 100),
(0, 'gear', 'UniqueScattergun4', 100),
(0, 'gear', 'UniqueScattergun3', 100),
(0, 'gear', 'UniqueScattergun2', 100),
(0, 'gear', 'UniqueScattergun1', 100),
(0, 'gear', 'UniqueRapier', 100),
(0, 'gear', 'UniqueFlameThrower', 100),
(0, 'gear', 'UniqueDirk', 100),
(0, 'gear', 'UniqueAr4', 100),
(0, 'gear', 'UniqueAr3', 100),
(0, 'gear', 'UniqueAr2', 100),
(0, 'gear', 'UniqueAr1', 100),
(0, 'gear', 'Thumper', 100),
(0, 'gear', 'SurveyProbeLauncher', 100),
(0, 'gear', 'SurveyProbe_1', 100),
(0, 'gear', 'Stilltent', 100),
(0, 'gear', 'StaticCompactorTier6', 100),
(0, 'gear', 'StakingUnit', 100),
(0, 'gear', 'SmugShot5', 100),
(0, 'gear', 'StakingUnitVertical', 100),
(0, 'gear', 'SmugShot4', 100),
(0, 'gear', 'SmugShot3', 100),
(0, 'gear', 'SmugDmr6', 100),
(0, 'gear', 'SmugDmr5', 100),
(0, 'gear', 'SmugDmr4', 100),
(0, 'gear', 'SmugDmr3', 100),
(0, 'gear', 'ScrapMetalKnife', 100),
(0, 'gear', 'Scattergun_Prototype3', 100),
(0, 'gear', 'Scattergun_Prototype2', 100),
(0, 'gear', 'Scattergun_Prototype1', 100),
(0, 'gear', 'Scattergun_Prototype0', 100),
(0, 'gear', 'Scattergun_Prototype', 100),
(0, 'gear', 'Scanner_Efficient_1', 100),
(0, 'gear', 'Scanner_Base_1', 100),
(0, 'gear', 'SardaukarBlade', 100),
(0, 'gear', 'RocketLauncher_2', 100),
(0, 'gear', 'RocketAmmo', 100),
(0, 'gear', 'RespawnBeacon', 100),
(0, 'gear', 'Rapier_3', 100),
(0, 'gear', 'Rapier_2', 100),
(0, 'gear', 'Rapier_0', 100),
(0, 'gear', 'Rapier', 100),
(0, 'gear', 'ScrapMetalKnife_NPENPC', 100),
(0, 'gear', 'Napalm', 100),
(0, 'gear', 'MiningTool_1h_Standard', 100),
(0, 'gear', 'Kindjal_4', 100),
(0, 'gear', 'Kindjal_3', 100),
(0, 'gear', 'Kindjal_2', 100),
(0, 'gear', 'Kindjal_1', 100),
(0, 'gear', 'Kindjal_0', 100),
(0, 'gear', 'Kindjal', 100),
(0, 'gear', 'InfantryRocketAmmo', 100),
(0, 'gear', 'HeavyAmmo', 100),
(0, 'gear', 'HarkHeavyPistol5', 100),
(0, 'gear', 'HarkHeavyPistol4', 100),
(0, 'gear', 'HarkHeavyPistol3', 100),
(0, 'gear', 'HarkHeavyPistol2', 100),
(0, 'gear', 'HarkHeavyPistol1', 100),
(0, 'gear', 'HarkAr7', 100),
(0, 'gear', 'HarkAr6', 100),
(0, 'gear', 'HarkAr5', 100),
(0, 'gear', 'HarkAr4', 100),
(0, 'gear', 'HarkAr3', 100),
(0, 'gear', 'HarkAr2', 100),
(0, 'gear', 'HarkAr1', 100),
(0, 'gear', 'HandHeldTorch', 100),
(0, 'gear', 'Flamethrower_Prototype_2', 100),
(0, 'gear', 'Flamethrower_Prototype', 100),
(0, 'gear', 'Dirk_3', 100),
(0, 'gear', 'Dirk_2', 100),
(0, 'gear', 'Dirk_1', 100),
(0, 'gear', 'Dirk_0', 100),
(0, 'gear', 'Dirk', 100),
(0, 'gear', 'BodyFluidExtractor', 100),
(0, 'gear', 'Binoculars_1', 100),
(0, 'gear', 'BasicBuildingTool', 100),
(0, 'gear', 'AtreSmg6', 100),
(0, 'gear', 'AtreSmg5', 100),
(0, 'gear', 'AtreSmg4', 100),
(0, 'gear', 'AtreSmg3', 100),
(0, 'gear', 'AtreSmg2', 100),
(0, 'gear', 'AtreSmg1', 100),
(0, 'gear', 'AtreLMG5', 100),
(0, 'gear', 'AtreLMG4', 100),
(0, 'gear', 'AtreLMG3', 100),
(0, 'gear', 'AtreLMG2', 100),
(0, 'gear', 'AtreLMG1', 100),
(0, 'gear', 'Ammo', 100),
(0, 'gear', 'StaticCompactor_CR', 100),
(0, 'gear', 'Crysknife_CR', 100),
(0, 'gear', 'UniqueSda_Story_Ari', 100),
(0, 'gear', 'UniqueDirk_Story_Feyd', 100),
(0, 'gear', 'Crysknife_Story_Zantara', 100),
(0, 'gear', 'Crysknife', 100),
(0, 'gear', 'DewReaper_Unique_Story', 100),
(0, 'gear', 'Sardaukar_Dagger_CR', 100),
(0, 'gear', 'NPE_ScrapMetalKnife', 100),
(0, 'gear', 'Unique_Sword_BleedyBlocky_4', 100),
(0, 'gear', 'Unique_Sword_BleedyBlocky_5', 100),
(0, 'gear', 'Unique_Sword_BleedyBlocky_6', 100),
(0, 'gear', 'Fireballer_2', 100),
(0, 'gear', 'HandHeldTorch_Story_TheBloodline', 100),
(0, 'gear', 'Fireballer_3', 100),
(0, 'gear', 'RocketLauncher_3', 100),
(0, 'gear', 'HandHeldTorch_Story_TheBloodline_NPC', 100),
(0, 'gear', 'Raider_Kindjal', 100),
(0, 'gear', 'RocketLauncher_1', 100),
(0, 'gear', 'Raider_Scattergun', 100),
(0, 'gear', 'Raider_LMG', 100),
(0, 'gear', 'UniqueAr6_Electric', 100),
(0, 'gear', 'DualBlades_1', 100),
(0, 'gear', 'DualBlades_2', 100),
(0, 'gear', 'Cine_Minotaur_Sword', 100),
(0, 'gear', 'Minotaur_Sword', 100),
(0, 'gear', 'Sandflies_Flamethrower_NPC', 100),
(0, 'gear', 'Fireballer_NPC', 100),
(0, 'gear', 'AtreLMGRadiationNPC', 100),
(0, 'gear', 'Minotaur_Memento', 100),
(0, 'gear', 'DualBlades_Memento', 100),
(0, 'gear', 'Scattergun_Prototype_RadiationNPC', 100),
(0, 'gear', 'UniqueAr_Burst_RadiationNPC', 100),
(0, 'gear', 'HarkHeavyPistolNPC', 100),
(0, 'gear', 'UniqueDualBlades_6', 100),
(0, 'gear', 'SmugDmrParaNPC', 100),
(0, 'gear', 'ScattergunEliteNPC', 100),
(0, 'gear', 'SmugShotEliteNPC', 100),
(0, 'gear', 'Crysknife_SleeperNPC', 100),
(0, 'gear', 'HarkArEliteNPC', 100),
(0, 'gear', 'B1C4_Unique_HarkAr2', 100),
(0, 'gear', 'B1C4_Unique_LMG2', 100),
(0, 'gear', 'B1C4_Unique_SmugDmr1', 100),
(0, 'gear', 'B1C4_NPCweapon_Cryo_Karpov', 100),
(0, 'gear', 'B1C4_NPCweapon_Cryo_Spitdart', 100),
(0, 'gear', 'B1C4_NPCweapon_Cryo_MaulaPistol', 100),
(0, 'gear', 'B1C4_NPCweapon_Cryo_HeavyPistol', 100),
(0, 'gear', 'B1C4_NPCweapon_Cryo_SMG', 100),
(0, 'gear', 'B1C4_NPCweapon_Cryo_LMG', 100),
(0, 'gear', 'B1C4_NPCweapon_Cryo_Shotgun', 100),
(0, 'gear', 'B1C4_NPCweapon_Cryo_Scattergun', 100),
(0, 'gear', 'SardaukarSword_1', 100),
(0, 'gear', 'B1C4_Unique_Dirk2', 100),
(0, 'gear', 'B1C4_Unique_DualBlades1', 100),
(0, 'gear', 'B1C4_Unique_Kindjal2', 100),
(0, 'gear', 'B1C4_Unique_Sword2', 100),
(0, 'gear', 'B1C4_TaligariPistol', 100),
(0, 'gear', 'B1C4_Unique_HeavyPistol2', 100),
(0, 'gear', 'B1C4_Unique_Rapier2', 100),
(0, 'gear', 'B1C4_Unique_SMG2', 100),
(0, 'schematics', 'Flamethrower1Schematic', 100),
(0, 'schematics', 'HealthPackSchematic', 100),
(0, 'schematics', 'ManualOfTheFriendlyDesertSchematic', 100),
(0, 'schematics', 'MiningTool_1h_StandardSchematic', 100),
(0, 'schematics', 'Schematic_UniqueBattleRifle', 100),
(0, 'schematics', 'Schematic_UniqueCutteray2', 100),
(0, 'schematics', 'Schematic_UniqueCutteray3', 100),
(0, 'schematics', 'Schematic_UniqueCutteray4', 100),
(0, 'schematics', 'Schematic_UniqueCutteray5', 100),
(0, 'schematics', 'Schematic_UniqueCutteray6', 100),
(0, 'schematics', 'Schematic_UniqueDirk', 100),
(0, 'schematics', 'Schematic_UniqueFlamethrower', 100),
(0, 'schematics', 'Schematic_UniqueForgeChest', 100),
(0, 'schematics', 'Schematic_UniqueForgeFeet', 100),
(0, 'schematics', 'Schematic_UniqueForgeHands', 100),
(0, 'schematics', 'Schematic_UniqueForgeHead', 100),
(0, 'schematics', 'Schematic_UniqueForgeLegs', 100),
(0, 'schematics', 'Schematic_UniqueMaulaPistol', 100),
(0, 'schematics', 'Schematic_UniqueOathbreakerChest', 100),
(0, 'schematics', 'Schematic_UniqueOathbreakerFeet', 100),
(0, 'schematics', 'Schematic_UniqueOathbreakerHands', 100),
(0, 'schematics', 'Schematic_UniqueOathbreakerHead', 100),
(0, 'schematics', 'Schematic_UniqueOathbreakerLegs', 100),
(0, 'schematics', 'Schematic_UniquePincushionChest', 100),
(0, 'schematics', 'Schematic_UniquePincushionFeet', 100),
(0, 'schematics', 'Schematic_UniquePincushionHands', 100),
(0, 'schematics', 'Schematic_UniquePincushionHead', 100),
(0, 'schematics', 'Schematic_UniquePincushionLegs', 100),
(0, 'schematics', 'Schematic_UniqueRapier', 100),
(0, 'schematics', 'Schematic_UniqueScattergun', 100),
(0, 'schematics', 'Schematic_UniqueSMG', 100),
(0, 'schematics', 'StilltentSchematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique02_Helmet_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique02_Top_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique02_Bottom_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique02_Gloves_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique02_Boots_Schematic', 100),
(0, 'schematics', 'UniqueSda2_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique03_Helmet_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique03_Top_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique03_Bottom_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique03_Gloves_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique03_Boots_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique02_Helmet_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique02_Top_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique02_Bottom_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique02_Gloves_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique02_Boots_Schematic', 100),
(0, 'schematics', 'UniqueSda3_Schematic', 100),
(0, 'schematics', 'UniqueScattergun2_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique04_Helmet_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique04_Top_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique04_Bottom_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique04_Gloves_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique04_Boots_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique03_Helmet_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique03_Top_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique03_Bottom_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique03_Gloves_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique03_Boots_Schematic', 100),
(0, 'schematics', 'UniqueSda4_Schematic', 100),
(0, 'schematics', 'UniqueScattergun3_Schematic', 100),
(0, 'schematics', 'UniqueAr2_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique05_Helmet_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique05_Top_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique05_Bottom_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique05_Gloves_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique05_Boots_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique04_Helmet_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique04_Top_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique04_Bottom_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique04_Gloves_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique04_Boots_Schematic', 100),
(0, 'schematics', 'UniqueSda5_Schematic', 100),
(0, 'schematics', 'UniqueScattergun4_Schematic', 100),
(0, 'schematics', 'UniqueAr3_Schematic', 100),
(0, 'schematics', 'UniqueSmg2_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique06_Helmet_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique06_Top_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique06_Bottom_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique06_Gloves_Schematic', 100),
(0, 'schematics', 'Combat_Neut_SmugglerDeserterUnique06_Boots_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique05_Helmet_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique05_Top_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique05_Bottom_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique05_Gloves_Schematic', 100),
(0, 'schematics', 'Combat_Neut_AtreidesDeserterUnique05_Boots_Schematic', 100),
(0, 'schematics', 'Combat_Hark_MedUnique02_Helmet_Schematic', 100),
(0, 'schematics', 'Combat_Hark_MedUnique02_Top_Schematic', 100),
(0, 'schematics', 'Combat_Hark_MedUnique02_Bottom_Schematic', 100),
(0, 'schematics', 'Combat_Hark_MedUnique02_Gloves_Schematic', 100),
(0, 'schematics', 'Combat_Hark_MedUnique02_Boots_Schematic', 100),
(0, 'schematics', 'UniqueSda6_Schematic', 100),
(0, 'schematics', 'UniqueScattergun5_Schematic', 100),
(0, 'schematics', 'UniqueAr4_Schematic', 100),
(0, 'schematics', 'UniqueSmg3_Schematic', 100),
(0, 'schematics', 'Combat_Heavy_Unique_Swordmaster_Schematic', 100),
(0, 'schematics', 'Combat_Light_Unique_BeneGeserit_Schematic', 100),
(0, 'schematics', 'Combat_Light_Unique_Mentat_Schematic', 100),
(0, 'schematics', 'Combat_Heavy_Unique_Trooper_Schematic', 100),
(0, 'schematics', 'Stillsuit_Unique_Planetologist_Schematic', 100),
(0, 'schematics', 'OrnithopterTransportLocomotion_Unique_Speed_6_Schematic', 100),
(0, 'schematics', 'Crysknife_Schematic', 100),
(0, 'schematics', 'FullStabilizationBelt_Unique_DmgReduction_Schematic', 100),
(0, 'schematics', 'SandcrawlerSpiceContainer_Unique_Capacity_6_Schematic', 100),
(0, 'schematics', 'Unique_Sword_BleedyBlocky_4_Schematic', 100),
(0, 'schematics', 'Unique_Sword_BleedyBlocky_5_Schematic', 100),
(0, 'schematics', 'Unique_Sword_BleedyBlocky_6_Schematic', 100),
(0, 'schematics', 'Unique_MiscEquipment_FullSuspensorBelt_Durability_Schematic', 100),
(0, 'schematics', 'UniqueAr6_Electric_Schematic', 100),
(0, 'schematics', 'Fireballer_2_Schematic', 100),
(0, 'schematics', 'Fireballer_3_Schematic', 100),
(0, 'schematics', 'Consumable_Buff_PoisonStackIncrease_Schematic', 100),
(0, 'schematics', 'DualBlades_1_Schematic', 100),
(0, 'schematics', 'DualBlades_2_Schematic', 100),
(0, 'schematics', 'Contract_LandsraadPowerpackComponent_Schematic', 100),
(0, 'schematics', 'Contract_LandsraadSurveillanceSensor_Schematic', 100),
(0, 'schematics', 'Contract_LandsraadPowerGenerator_Schematic', 100),
(0, 'schematics', 'Contract_LandsraadExperimentalWindTurbineComponent_Schematic', 100),
(0, 'schematics', 'Contract_LandsraadSealedRecorder_Schematic', 100),
(0, 'schematics', 'Contract_LandsraadIxianSurveillanceDevice_Schematic', 100),
(0, 'schematics', 'UniqueDualBlades_6_Schematic', 100),
(0, 'schematics', 'Contract_LandsraadPhaseDancersSolidoDissembler_Schematic', 100),
(0, 'schematics', 'Contract_LandsraadTerrainRecorder_Schematic', 100),
(0, 'schematics', 'Contract_LandsraadMinefieldSurveyor_Schematic', 100),
(0, 'schematics', 'B1C4_Unique_HarkAr2_Schematic', 100),
(0, 'schematics', 'B1C4_Unique_LMG2_Schematic', 100),
(0, 'schematics', 'B1C4_Unique_SmugDmr1_Schematic', 100),
(0, 'schematics', 'Exoskeleton_Heavy06_Unique_Top_Schematic', 100),
(0, 'schematics', 'Assassin_Light06_Unique_Helmet_Schematic', 100),
(0, 'schematics', 'Assassin_Light06_Unique_Top_Schematic', 100),
(0, 'schematics', 'B1C4_Unique_Dirk2_Schematic', 100),
(0, 'schematics', 'B1C4_Unique_DualBlades1_Schematic', 100),
(0, 'schematics', 'B1C4_Unique_Kindjal2_Schematic', 100),
(0, 'schematics', 'B1C4_Unique_Sword2_Schematic', 100),
(0, 'schematics', 'B1C4_Unique_Rapier2_Schematic', 100),
(0, 'schematics', 'B1C4_Unique_SMG2_Schematic', 100),
(0, 'schematics', 'B1C4_Unique_HeavyPistol2_Schematic', 100),
(0, 'schematics', 'Contract_LandsraadRareMetalsExtractor_Schematic', 100),
(1, 'raw_resources', 'AzuriteOre', 20),
(1, 'crafted_components', 'CopperBar', 100),
(1, 'crafted_components', 'DolomiteRock', 100),
(1, 'raw_resources', 'FlourSand', 100),
(1, 'crafted_components', 'FuelCanister', 100),
(1, 'raw_resources', 'PlantFiber', 75),
(1, 'crafted_components', 'ScrapMetal', 75),
(1, 'crafted_components', 'Silicone', 100),
(1, 'crafted_components', 'SolarisCoin', 10),
(1, 'raw_resources', 'Stone', 75),
(1, 'crafted_components', 'WeldingMaterial', 100),
(1, 'crafted_components', 'Basalt', 100),
(1, 'crafted_components', 'OldImperialComponent1', 30),
(1, 'crafted_components', 'OldImperialComponent2', 30),
(1, 'crafted_components', 'GreatHouseComponent1', 30),
(1, 'crafted_components', 'GreatHouseComponent2', 30),
(1, 'crafted_components', 'T1RusherComponent', 100),
(1, 'crafted_components', 'T1AssaultComponent', 100),
(1, 'crafted_components', 'T1ExplorationComponent', 100),
(1, 'crafted_components', 'T1UniqueComponent', 100),
(1, 'crafted_components', 'WindTrapFilter1', 100),
(1, 'gear', 'Stillsuit_Unique_Armored_01_Top', 100),
(1, 'gear', 'Stillsuit_Unique_Armored_01_Boots', 100),
(1, 'gear', 'Stillsuit_Unique_Armored_01_Gloves', 100),
(1, 'gear', 'Stillsuit_Unique_Armored_01_Mask', 100),
(1, 'gear', 'SandbikeChassis_1', 100),
(1, 'gear', 'SandbikeEngine_1', 100),
(1, 'gear', 'SandbikeEngine_Unique_Speed_1', 100),
(1, 'gear', 'SandbikeGenerator_1', 100),
(1, 'gear', 'SandbikeHull_1', 100),
(1, 'gear', 'SandbikeInventory_1', 100),
(1, 'gear', 'SandbikeLocomotion_1', 100),
(1, 'gear', 'SandbikeSeat_1', 100),
(1, 'gear', 'TreadwheelPassenger_1', 100),
(1, 'gear', 'UniqueAr_Burst_01', 100),
(1, 'gear', 'RepairTool', 100),
(1, 'gear', 'MiningTool_2h_Unique_01', 100),
(1, 'gear', 'MiningTool_1h_Unique_01', 100),
(1, 'gear', 'MiningTool_1h_Heavy', 100),
(1, 'gear', 'Kindjal_Unique_Blood_01', 100),
(1, 'gear', 'DewReaper_Unique_01', 100),
(1, 'gear', 'Hook_01', 100),
(1, 'gear', 'Hook_NPC_01', 100),
(1, 'gear', 'Ghola_NPC_Knife_01', 100),
(1, 'gear', 'Stilltent_Unique_01', 100),
(1, 'schematics', 'Schematic_UniqueLiterjon', 100),
(1, 'schematics', 'Schematic_UniqueSuspensor', 100),
(1, 'schematics', 'T1_UtilityClothing_LeakyStillsuit_Schematic', 100),
(1, 'schematics', 'HoltzmanShieldActiveDrain_Unique_01_Schematic', 100),
(1, 'schematics', 'SandbikeEngine_Unique_Speed_1_Schematic', 100),
(1, 'schematics', 'PowerPack_Unique_Regen_01_Schematic', 100),
(1, 'schematics', 'Stillsuit_Unique_Armored_01_Mask_Schematic', 100),
(1, 'schematics', 'Stillsuit_Unique_Armored_01_Boots_Schematic', 100),
(1, 'schematics', 'Stillsuit_Unique_Armored_01_Gloves_Schematic', 100),
(1, 'schematics', 'Stillsuit_Unique_Armored_01_Top_Schematic', 100),
(1, 'schematics', 'Kindjal_Unique_Blood_01_Schematic', 100),
(1, 'schematics', 'UniqueAr_Burst_01_Schematic', 100),
(1, 'schematics', 'Stilltent_Unique_01_Schematic', 100),
(1, 'schematics', 'TreadwheelPassenger_1_Schematic', 100),
(1, 'schematics', 'T6_Augment_Ch5_Spitdart1_Schematic', 100),
(2, 'crafted_components', 'DolomiteRock', 100),
(2, 'raw_resources', 'FlourSand', 100),
(2, 'crafted_components', 'FuelCanister', 100),
(2, 'crafted_components', 'IronBar', 100),
(2, 'crafted_components', 'FuelCanister_Medium', 100),
(2, 'raw_resources', 'MagnetiteOre', 100),
(2, 'raw_resources', 'PlantFiber', 50),
(2, 'crafted_components', 'ScrapMetal', 50),
(2, 'crafted_components', 'Silicone', 100),
(2, 'crafted_components', 'SolarisCoin', 10),
(2, 'raw_resources', 'Stone', 50),
(2, 'crafted_components', 'WeldingMaterial', 100),
(2, 'crafted_components', 'Basalt', 100),
(2, 'crafted_components', 'OldImperialComponent1', 30),
(2, 'crafted_components', 'OldImperialComponent2', 30),
(2, 'crafted_components', 'GreatHouseComponent1', 30),
(2, 'crafted_components', 'GreatHouseComponent2', 30),
(2, 'crafted_components', 'T2HeavyComponent', 100),
(2, 'crafted_components', 'T2MachineComponent', 100),
(2, 'crafted_components', 'T2UniqueComponent', 100),
(2, 'crafted_components', 'WindTurbineLubricant1', 100),
(2, 'crafted_components', 'WindTrapFilter1', 100),
(2, 'gear', 'Combat_Heavy_Unique_PowerEfficient_Gloves_02', 100),
(2, 'gear', 'Combat_Light_Unique_WormThreat_Boots_02', 100),
(2, 'gear', 'Stillsuit_Unique_Armored_02_Boots', 100),
(2, 'gear', 'Stillsuit_Unique_Armored_02_Gloves', 100),
(2, 'gear', 'Stillsuit_Unique_Armored_02_Mask', 100),
(2, 'gear', 'Stillsuit_Unique_Armored_02_Top', 100),
(2, 'gear', 'SandbikeBoost_2', 100),
(2, 'gear', 'SandbikeBoost_Unique_LessHeat_2', 100),
(2, 'gear', 'SandbikeChassis_2', 100),
(2, 'gear', 'SandbikeEngine_2', 100),
(2, 'gear', 'SandbikeEngine_Unique_Speed_2', 100),
(2, 'gear', 'SandbikeGenerator_2', 100),
(2, 'gear', 'SandbikeHull_2', 100),
(2, 'gear', 'SandbikeInventory_2', 100),
(2, 'gear', 'SandbikeLocomotion_2', 100),
(2, 'gear', 'SandbikeScanner_2', 100),
(2, 'gear', 'TreadwheelInventory_2', 100),
(2, 'gear', 'TreadwheelScanner_2', 100),
(2, 'gear', 'UniqueThumper_02', 100),
(2, 'gear', 'UniqueSword_02', 100),
(2, 'gear', 'UniqueRapier_02', 100),
(2, 'gear', 'UniqueFlameThrower_02', 100),
(2, 'gear', 'UniqueDirk_02', 100),
(2, 'gear', 'UniqueAr_Burst_02', 100),
(2, 'gear', 'SMG_Unique_LargeMag_02', 100),
(2, 'gear', 'MiningTool_2h_Unique_02', 100),
(2, 'gear', 'MiningTool_1h_Unique_02', 100),
(2, 'gear', 'MiningTool_1h_Light', 100),
(2, 'gear', 'Kindjal_Unique_Blood_02', 100),
(2, 'gear', 'Heavy_Flamethrower_T2_NPC', 100),
(2, 'gear', 'DewReaper_Unique_02', 100),
(2, 'gear', 'DewReaper_Prototype', 100),
(2, 'gear', 'BodyFluidExtractor_02', 100),
(2, 'gear', 'Ghola_NPC_Knife_02', 100),
(2, 'schematics', 'Schematic_UniqueBikeBoost', 100),
(2, 'schematics', 'Schematic_UniqueDewReaper', 100),
(2, 'schematics', 'T2_MiscEquipment_PowerPack_Schematic', 100),
(2, 'schematics', 'SandbikeEngine_Unique_Speed_2_Schematic', 100),
(2, 'schematics', 'SandbikeScanner_Unique_LongRange_02_Schematic', 100),
(2, 'schematics', 'HighCapacityLiterjon_02_Schematic', 100),
(2, 'schematics', 'GlidePartialStabilizationBelt_02_Schematic', 100),
(2, 'schematics', 'PowerPack_Unique_Regen_02_Schematic', 100),
(2, 'schematics', 'Bloodsack_Unique_Durable_02_Schematic', 100),
(2, 'schematics', 'Stillsuit_Unique_Armored_02_Mask_Schematic', 100),
(2, 'schematics', 'Stillsuit_Unique_Armored_02_Boots_Schematic', 100),
(2, 'schematics', 'Stillsuit_Unique_Armored_02_Gloves_Schematic', 100),
(2, 'schematics', 'Stillsuit_Unique_Armored_02_Top_Schematic', 100),
(2, 'schematics', 'Combat_Heavy_Unique_PowerEfficient_Gloves_02_Schematic', 100),
(2, 'schematics', 'Combat_Light_Unique_WormThreat_Boots_02_Schematic', 100),
(2, 'schematics', 'SMG_Unique_LargeMag_02_Schematic', 100),
(2, 'schematics', 'Kindjal_Unique_Blood_02_Schematic', 100),
(2, 'schematics', 'UniqueAr_Burst_02_Schematic', 100),
(2, 'schematics', 'DewReaper_Unique_02_Schematic', 100),
(2, 'schematics', 'UniqueSword_02_Schematic', 100),
(2, 'schematics', 'UniqueDirk_02_Schematic', 100),
(2, 'schematics', 'UniqueThumper_02_Schematic', 100),
(2, 'schematics', 'UniqueRapier_02_Schematic', 100),
(2, 'schematics', 'UniqueFlameThrower_02_Schematic', 100),
(2, 'schematics', 'TreadwheelInventory_2_Schematic', 100),
(2, 'schematics', 'TreadwheelScanner_2_Schematic', 100),
(3, 'crafted_components', 'DolomiteRock', 100),
(3, 'raw_resources', 'FlourSand', 100),
(3, 'crafted_components', 'FuelCanister_Medium', 100),
(3, 'raw_resources', 'PlantFiber', 25),
(3, 'crafted_components', 'ScrapMetal', 25),
(3, 'crafted_components', 'Silicone', 100),
(3, 'crafted_components', 'SolarisCoin', 10),
(3, 'raw_resources', 'Stone', 25),
(3, 'crafted_components', 'WeldingMaterial', 100),
(3, 'crafted_components', 'JasmiumCrystal', 100),
(3, 'crafted_components', 'WeldingMaterial3', 100),
(3, 'crafted_components', 'Basalt', 100),
(3, 'crafted_components', 'SteelBar', 100),
(3, 'crafted_components', 'ErythriteCrystal', 100),
(3, 'raw_resources', 'SaguaroResourceRaw', 100),
(3, 'crafted_components', 'OldImperialComponent1', 30),
(3, 'crafted_components', 'OldImperialComponent2', 30),
(3, 'crafted_components', 'GreatHouseComponent1', 30),
(3, 'crafted_components', 'GreatHouseComponent2', 30),
(3, 'crafted_components', 'T3MarksmanComponent', 100),
(3, 'crafted_components', 'T3MiningGalleryComponent1', 100),
(3, 'crafted_components', 'T3MiningGalleryComponent2', 100),
(3, 'crafted_components', 'T3VendorComponent1', 100),
(3, 'crafted_components', 'T3UniqueComponent', 100),
(3, 'crafted_components', 'WindTurbineLubricant1', 100),
(3, 'crafted_components', 'WindTrapFilter2', 100),
(3, 'gear', 'Combat_Light_Unique_BiomeHeat_Top_03', 100),
(3, 'gear', 'Combat_Light_Unique_DewReap_Gloves_03', 100),
(3, 'gear', 'Combat_Heavy_Unique_PowerEfficient_Gloves_03', 100),
(3, 'gear', 'Combat_Light_Unique_ReduceSuspensor_Top_03', 100),
(3, 'gear', 'Combat_Light_Unique_WormThreat_Boots_03', 100),
(3, 'gear', 'Stillsuit_Unique_Armored_03_Boots', 100),
(3, 'gear', 'Stillsuit_Unique_Armored_03_Gloves', 100),
(3, 'gear', 'Stillsuit_Unique_Armored_03_Mask', 100),
(3, 'gear', 'Stillsuit_Unique_Armored_03_Top', 100),
(3, 'gear', 'BuggyBoost_3', 100),
(3, 'gear', 'BuggyBoost_Unique_LessHeat_3', 100),
(3, 'gear', 'BuggyChassis_3', 100),
(3, 'gear', 'BuggyEngine_3', 100),
(3, 'gear', 'BuggyEngine_Unique_Accelerate_03', 100),
(3, 'gear', 'BuggyGenerator_3', 100),
(3, 'gear', 'BuggyHullBack_3', 100),
(3, 'gear', 'BuggyHullBackExtra_3', 100),
(3, 'gear', 'BuggyHullFront_3', 100),
(3, 'gear', 'BuggyInventory_3', 100),
(3, 'gear', 'BuggyInventory_Unique_Capacity_03', 100),
(3, 'gear', 'BuggyLocomotion_3', 100),
(3, 'gear', 'BuggyMining_3', 100),
(3, 'gear', 'BuggyMining_Unique_YieldIncrease_03', 100),
(3, 'gear', 'SandbikeBoost_3', 100),
(3, 'gear', 'SandbikeBoost_Unique_LessHeat_3', 100),
(3, 'gear', 'SandbikeChassis_3', 100),
(3, 'gear', 'SandbikeEngine_3', 100),
(3, 'gear', 'SandbikeEngine_Unique_Speed_3', 100),
(3, 'gear', 'SandbikeGenerator_3', 100),
(3, 'gear', 'SandbikeHull_3', 100),
(3, 'gear', 'SandbikeLocomotion_3', 100),
(3, 'gear', 'UniqueThumper_03', 100),
(3, 'gear', 'UniqueSword_03', 100),
(3, 'gear', 'UniqueRapier_03', 100),
(3, 'gear', 'UniqueDirk_03', 100),
(3, 'gear', 'UniqueAr_Burst_03', 100),
(3, 'gear', 'StaticCompactor_Unique_Compact_03', 100),
(3, 'gear', 'SMG_Unique_LargeMag_03', 100),
(3, 'gear', 'Scanner_Unique_Body_03', 100),
(3, 'gear', 'Rifle_Long_T3_NPC', 100),
(3, 'gear', 'RepairTool3', 100),
(3, 'gear', 'MiningTool_2h_Unique_03', 100),
(3, 'gear', 'MiningTool_2h_Standard', 100),
(3, 'gear', 'LongRifle_Unique_Poison_03', 100),
(3, 'gear', 'Kindjal_Unique_Stamina_03', 100),
(3, 'gear', 'Kindjal_Unique_Blood_03', 100),
(3, 'gear', 'HeavyPistol_Unique_Bleed_03', 100),
(3, 'gear', 'DewReaper_Unique_03', 100),
(3, 'gear', 'DewReaper_03', 100),
(3, 'gear', 'BodyFluidExtractor_Unique_Water_03', 100),
(3, 'gear', 'BodyFluidExtractor_03', 100),
(3, 'gear', 'Ghola_NPC_Knife_03', 100),
(3, 'schematics', 'Schematic_UniqueBuggyBoost', 100),
(3, 'schematics', 'T3_Tool_ScannerEfficient_Schematic', 100),
(3, 'schematics', 'SandbikeEngine_Unique_Speed_3_Schematic', 100),
(3, 'schematics', 'BuggyEngine_Unique_Accelerate_03_Schematic', 100),
(3, 'schematics', 'BuggyMining_Unique_YieldIncrease_03_Schematic', 100),
(3, 'schematics', 'BuggyInventory_Unique_Capacity_03_Schematic', 100),
(3, 'schematics', 'HighCapacityLiterjon_03_Schematic', 100),
(3, 'schematics', 'GlidePartialStabilizationBelt_03_Schematic', 100),
(3, 'schematics', 'StaticCompactor_Unique_Compact_03_Schematic', 100),
(3, 'schematics', 'BodyFluidExtractor_Unique_Water_03_Schematic', 100),
(3, 'schematics', 'PowerPack_Unique_Regen_03_Schematic', 100),
(3, 'schematics', 'Bloodsack_Unique_Durable_03_Schematic', 100),
(3, 'schematics', 'Scanner_Unique_Body_03_Schematic', 100),
(3, 'schematics', 'Stillsuit_Unique_Armored_03_Mask_Schematic', 100),
(3, 'schematics', 'Stillsuit_Unique_Armored_03_Boots_Schematic', 100),
(3, 'schematics', 'Stillsuit_Unique_Armored_03_Gloves_Schematic', 100),
(3, 'schematics', 'Stillsuit_Unique_Armored_03_Top_Schematic', 100),
(3, 'schematics', 'Combat_Heavy_Unique_PowerEfficient_Gloves_03_Schematic', 100),
(3, 'schematics', 'Combat_Light_Unique_WormThreat_Boots_03_Schematic', 100),
(3, 'schematics', 'Combat_Light_Unique_DewReap_Gloves_03_Schematic', 100),
(3, 'schematics', 'Combat_Light_Unique_ReduceSuspensor_Top_03_Schematic', 100),
(3, 'schematics', 'SMG_Unique_LargeMag_03_Schematic', 100),
(3, 'schematics', 'Kindjal_Unique_Blood_03_Schematic', 100),
(3, 'schematics', 'LongRifle_Unique_Poison_03_Schematic', 100),
(3, 'schematics', 'HeavyPistol_Unique_Bleed_03_Schematic', 100),
(3, 'schematics', 'UniqueAr_Burst_03_Schematic', 100),
(3, 'schematics', 'Kindjal_Unique_Stamina_03_Schematic', 100),
(3, 'schematics', 'Combat_Light_Unique_BiomeHeat_Top_03_Schematic', 100),
(3, 'schematics', 'DewReaper_Unique_03_Schematic', 100),
(3, 'schematics', 'UniqueSword_03_Schematic', 100),
(3, 'schematics', 'UniqueDirk_03_Schematic', 100),
(3, 'schematics', 'UniqueThumper_03_Schematic', 100),
(3, 'schematics', 'UniqueRapier_03_Schematic', 100),
(4, 'crafted_components', 'AluminiumBar', 100),
(4, 'raw_resources', 'BauxiteOre', 100),
(4, 'crafted_components', 'DolomiteRock', 100),
(4, 'raw_resources', 'FlourSand', 100),
(4, 'crafted_components', 'FuelCanister_Medium', 20),
(4, 'crafted_components', 'Silicone', 100),
(4, 'crafted_components', 'SolarisCoin', 10),
(4, 'crafted_components', 'WeldingMaterial3', 20),
(4, 'crafted_components', 'Basalt', 100),
(4, 'crafted_components', 'ErythriteCrystal', 100),
(4, 'raw_resources', 'SaguaroResourceRaw', 100),
(4, 'crafted_components', 'OldImperialComponent1', 30),
(4, 'crafted_components', 'OldImperialComponent2', 30),
(4, 'crafted_components', 'GreatHouseComponent1', 30),
(4, 'crafted_components', 'GreatHouseComponent2', 30),
(4, 'raw_resources', 'Plastone', 100),
(4, 'crafted_components', 'T4ShieldWallComponent', 100),
(4, 'raw_resources', 'T4HarkSpiceSiloComponent1', 100),
(4, 'raw_resources', 'T4HarkSpiceSiloComponent2', 100),
(4, 'raw_resources', 'T4HarkSpiceSiloComponent3', 100),
(4, 'crafted_components', 'T4PyonVillageComponent', 100),
(4, 'crafted_components', 'T4MysaTarilComponent1', 100),
(4, 'crafted_components', 'T4MysaTarilComponent2', 100),
(4, 'crafted_components', 'T4MaasKharetComponent1', 100),
(4, 'crafted_components', 'T4MaasKharetComponent2', 100),
(4, 'crafted_components', 'T3VendorComponent1', 100),
(4, 'crafted_components', 'T4UniqueComponent', 100),
(4, 'crafted_components', 'WindTurbineLubricant1', 100),
(4, 'crafted_components', 'WindTurbineLubricant2', 100),
(4, 'crafted_components', 'WindTrapFilter2', 20),
(4, 'crafted_components', 'WindTrapFilter3', 20),
(4, 'gear', 'Radiation_Suit', 100),
(4, 'gear', 'Combat_Light_Unique_BiomeHeat_Top_04', 100),
(4, 'gear', 'Combat_Light_Unique_DewReap_Gloves_04', 100),
(4, 'gear', 'Combat_Heavy_Unique_PowerEfficient_Gloves_04', 100),
(4, 'gear', 'Combat_Light_Unique_Stamina_Bottom_04', 100),
(4, 'gear', 'Stillsuit_Unique_Efficient_04_Boots', 100),
(4, 'gear', 'Stillsuit_Unique_Efficient_04_Gloves', 100),
(4, 'gear', 'Stillsuit_Unique_Efficient_04_Mask', 100),
(4, 'gear', 'Stillsuit_Unique_Efficient_04_Top', 100),
(4, 'gear', 'Stillsuit_Unique_HeatMitigation_04_Mask', 100),
(4, 'gear', 'Combat_Light_Unique_ReduceSuspensor_Top_04', 100),
(4, 'gear', 'Combat_Light_Unique_WormThreat_Boots_04', 100),
(4, 'gear', 'Stillsuit_Unique_Armored_04_Boots', 100),
(4, 'gear', 'Stillsuit_Unique_Armored_04_Gloves', 100),
(4, 'gear', 'Stillsuit_Unique_Armored_04_Mask', 100),
(4, 'gear', 'Stillsuit_Unique_Armored_04_Top', 100),
(4, 'gear', 'BuggyBoost_4', 100),
(4, 'gear', 'BuggyBoost_Unique_LessHeat_4', 100),
(4, 'gear', 'BuggyChassis_4', 100),
(4, 'gear', 'BuggyEngine_4', 100),
(4, 'gear', 'BuggyEngine_Unique_Accelerate_04', 100),
(4, 'gear', 'BuggyGenerator_4', 100),
(4, 'gear', 'BuggyHullBack_4', 100),
(4, 'gear', 'BuggyHullBackExtra_4', 100),
(4, 'gear', 'BuggyHullFront_4', 100),
(4, 'gear', 'BuggyInventory_4', 100),
(4, 'gear', 'BuggyInventory_Unique_Capacity_04', 100),
(4, 'gear', 'BuggyLocomotion_4', 100),
(4, 'gear', 'BuggyMining_4', 100),
(4, 'gear', 'BuggyMining_Unique_YieldIncrease_04', 100),
(4, 'gear', 'OrnithopterLightBoost_4', 100),
(4, 'gear', 'OrnithopterLightBoost_Unique_LessHeat_4', 100),
(4, 'gear', 'OrnithopterLightChassis_4', 100),
(4, 'gear', 'OrnithopterLightEngine_4', 100),
(4, 'gear', 'OrnithopterLightGenerator_4', 100),
(4, 'gear', 'OrnithopterLightHullBack_4', 100),
(4, 'gear', 'OrnithopterLightHullFront_4', 100),
(4, 'gear', 'OrnithopterLightInventory_4', 100),
(4, 'gear', 'OrnithopterLightLocomotion_4', 100),
(4, 'gear', 'OrnithopterLightLocomotion_Unique_Speed_4', 100),
(4, 'gear', 'SandbikeBoost_4', 100),
(4, 'gear', 'SandbikeBoost_Unique_LessHeat_4', 100),
(4, 'gear', 'SandbikeChassis_4', 100),
(4, 'gear', 'SandbikeEngine_4', 100),
(4, 'gear', 'SandbikeEngine_Unique_Speed_4', 100),
(4, 'gear', 'SandbikeGenerator_4', 100),
(4, 'gear', 'SandbikeHull_4', 100),
(4, 'gear', 'SandbikeLocomotion_4', 100),
(4, 'gear', 'TreadwheelBoost_4', 100),
(4, 'gear', 'TreadwheelBoost_Unique_LessHeat_4', 100),
(4, 'gear', 'TreadwheelChassis_4', 100),
(4, 'gear', 'TreadwheelEngine_4', 100),
(4, 'gear', 'TreadwheelEngine_Unique_Speed_4', 100),
(4, 'gear', 'TreadwheelGenerator_4', 100),
(4, 'gear', 'TreadwheelHull_4', 100),
(4, 'gear', 'TreadwheelLocomotion_4', 100),
(4, 'gear', 'UniqueThumper', 100),
(4, 'gear', 'UniqueSword_04', 100),
(4, 'gear', 'UniqueSda_Doubleshot_04', 100),
(4, 'gear', 'UniqueScattergun_Fire_04', 100),
(4, 'gear', 'UniqueDirk_04', 100),
(4, 'gear', 'UniqueAr_Burst_04', 100),
(4, 'gear', 'StaticCompactor_Unique_Compact_04', 100),
(4, 'gear', 'SMG_Unique_LargeMag_04', 100),
(4, 'gear', 'Shotgun_Unique_Explosive_04', 100),
(4, 'gear', 'MiningTool_2h_Unique_04', 100),
(4, 'gear', 'MiningTool_2h_Heavy', 100),
(4, 'gear', 'LongRifle_Unique_Poison_04', 100),
(4, 'gear', 'LMG_Unique_RapidFire_04', 100),
(4, 'gear', 'Kindjal_Unique_Stamina_04', 100),
(4, 'gear', 'Kindjal_Unique_Blood_04', 100),
(4, 'gear', 'HeavyPistol_Unique_Bleed_04', 100),
(4, 'gear', 'DewReaper_Unique_04', 100),
(4, 'gear', 'DewReaper_Scythe', 100),
(4, 'gear', 'DewReaper_1h_Unique_Compact_04', 100),
(4, 'gear', 'BodyFluidExtractor_Unique_Water_04', 100),
(4, 'gear', 'Rifle_Long_T4_Explosive_NPC', 100),
(4, 'gear', 'Hark_AR_T4_Poison', 100),
(4, 'schematics', 'Schematic_UniqueThopterBoost', 100),
(4, 'schematics', 'Schematic_UniqueThumper', 100),
(4, 'schematics', 'T4_Structure_Thumper1_Schematic', 100),
(4, 'schematics', 'SandbikeEngine_Unique_Speed_4_Schematic', 100),
(4, 'schematics', 'BuggyEngine_Unique_Accelerate_04_Schematic', 100),
(4, 'schematics', 'BuggyMining_Unique_YieldIncrease_04_Schematic', 100),
(4, 'schematics', 'OrnithopterLightEngine_Unique_Speed_04_Schematic', 100),
(4, 'schematics', 'BuggyInventory_Unique_Capacity_04_Schematic', 100),
(4, 'schematics', 'HighCapacityLiterjon_04_Schematic', 100),
(4, 'schematics', 'GlidePartialStabilizationBelt_04_Schematic', 100),
(4, 'schematics', 'StaticCompactor_Unique_Compact_04_Schematic', 100),
(4, 'schematics', 'BodyFluidExtractor_Unique_Water_04_Schematic', 100),
(4, 'schematics', 'PowerPack_Unique_Regen_04_Schematic', 100),
(4, 'schematics', 'DewReaper_1h_Unique_Compact_04_Schematic', 100),
(4, 'schematics', 'Bloodsack_Unique_Durable_04_Schematic', 100),
(4, 'schematics', 'Stillsuit_Unique_Armored_04_Mask_Schematic', 100),
(4, 'schematics', 'Stillsuit_Unique_Armored_04_Boots_Schematic', 100),
(4, 'schematics', 'Stillsuit_Unique_Armored_04_Gloves_Schematic', 100),
(4, 'schematics', 'Stillsuit_Unique_Armored_04_Top_Schematic', 100),
(4, 'schematics', 'Stillsuit_Unique_Efficient_04_Boots_Schematic', 100),
(4, 'schematics', 'Stillsuit_Unique_Efficient_04_Gloves_Schematic', 100),
(4, 'schematics', 'Stillsuit_Unique_Efficient_04_Mask_Schematic', 100),
(4, 'schematics', 'Stillsuit_Unique_Efficient_04_Top_Schematic', 100),
(4, 'schematics', 'Combat_Heavy_Unique_PowerEfficient_Gloves_04_Schematic', 100),
(4, 'schematics', 'Combat_Light_Unique_WormThreat_Boots_04_Schematic', 100),
(4, 'schematics', 'Combat_Light_Unique_Stamina_Bottom_04_Schematic', 100),
(4, 'schematics', 'Stillsuit_Unique_HeatMitigation_04_Mask_Schematic', 100),
(4, 'schematics', 'Combat_Light_Unique_DewReap_Gloves_04_Schematic', 100),
(4, 'schematics', 'Combat_Light_Unique_ReduceSuspensor_Top_04_Schematic', 100),
(4, 'schematics', 'SMG_Unique_LargeMag_04_Schematic', 100),
(4, 'schematics', 'Kindjal_Unique_Blood_04_Schematic', 100),
(4, 'schematics', 'LongRifle_Unique_Poison_04_Schematic', 100),
(4, 'schematics', 'HeavyPistol_Unique_Bleed_04_Schematic', 100),
(4, 'schematics', 'LMG_Unique_RapidFire_04_Schematic', 100),
(4, 'schematics', 'Shotgun_Unique_Explosive_04_Schematic', 100),
(4, 'schematics', 'UniqueSda_Doubleshot_04_Schematic', 100),
(4, 'schematics', 'UniqueScattergun_Fire_04_Schematic', 100),
(4, 'schematics', 'UniqueAr_Burst_04_Schematic', 100),
(4, 'schematics', 'Kindjal_Unique_Stamina_04_Schematic', 100),
(4, 'schematics', 'Combat_Light_Unique_BiomeHeat_Top_04_Schematic', 100),
(4, 'schematics', 'DewReaper_Unique_04_Schematic', 100),
(4, 'schematics', 'UniqueSword_04_Schematic', 100),
(4, 'schematics', 'MiningTool_2h_Unique_04_Schematic', 100),
(4, 'schematics', 'UniqueDirk_04_Schematic', 100),
(4, 'schematics', 'OrnithopterLightLocomotion_Unique_Speed_4_Schematic', 100),
(4, 'schematics', 'TreadwheelBoost_Unique_LessHeat_4_Schematic', 100),
(4, 'schematics', 'TreadwheelEngine_Unique_Speed_4_Schematic', 100),
(4, 'schematics', 'TreadwheelChassis_4_Schematic', 100),
(4, 'schematics', 'TreadwheelGenerator_4_Schematic', 100),
(4, 'schematics', 'TreadwheelEngine_4_Schematic', 100),
(4, 'schematics', 'TreadwheelLocomotion_4_Schematic', 100),
(4, 'schematics', 'TreadwheelHull_4_Schematic', 100),
(4, 'schematics', 'TreadwheelBoost_4_Schematic', 100),
(5, 'crafted_components', 'DolomiteRock', 100),
(5, 'raw_resources', 'FlourSand', 100),
(5, 'crafted_components', 'FuelCanister_Large', 20),
(5, 'crafted_components', 'Silicone', 100),
(5, 'crafted_components', 'SolarisCoin', 10),
(5, 'raw_resources', 'SpiceSand', 100),
(5, 'crafted_components', 'WeldingMaterial3', 20),
(5, 'crafted_components', 'Basalt', 100),
(5, 'crafted_components', 'WeldingMaterial5', 20),
(5, 'crafted_components', 'DuraluminumRod', 100),
(5, 'crafted_components', 'ErythriteCrystal', 100),
(5, 'crafted_components', 'CobaltBar', 100),
(5, 'raw_resources', 'SpiceResidue', 100),
(5, 'raw_resources', 'SaguaroResourceRaw', 100),
(5, 'crafted_components', 'FremenComponent1', 100),
(5, 'crafted_components', 'OldImperialComponent1', 30),
(5, 'crafted_components', 'OldImperialComponent2', 30),
(5, 'crafted_components', 'GreatHouseComponent1', 30),
(5, 'crafted_components', 'GreatHouseComponent2', 30),
(5, 'raw_resources', 'T5RadiatedCoreComponent', 100),
(5, 'crafted_components', 'T3VendorComponent1', 100),
(5, 'crafted_components', 'T5UniqueComponent', 100),
(5, 'crafted_components', 'WindTurbineLubricant2', 100),
(5, 'crafted_components', 'WindTrapFilter3', 20),
(5, 'crafted_components', 'WindTrapFilter4', 20),
(5, 'crafted_components', 'T5FactionBaseComponent1', 100),
(5, 'crafted_components', 'T5FactionBaseComponent2', 100),
(5, 'crafted_components', 'T5DeepDesertShieldWallComponent', 100),
(5, 'gear', 'Radiation_Suit_T5', 100),
(5, 'gear', 'Social_Choam_MaulaCastOffs01_Bottom', 100),
(5, 'gear', 'Social_Choam_MaulaCastOffs01_Gloves', 100),
(5, 'gear', 'Social_Choam_MaulaCastOffs01_Shoes', 100),
(5, 'gear', 'Social_Choam_MaulaCastOffs01_Top', 100),
(5, 'gear', 'Social_Choam_MaulaCastOffs01_Top_Fremkit', 100),
(5, 'gear', 'Stillsuit_Choam_01_Boots', 100),
(5, 'gear', 'Stillsuit_Choam_01_Gloves', 100),
(5, 'gear', 'Stillsuit_Choam_01_Mask', 100),
(5, 'gear', 'Stillsuit_Choam_01_Top', 100),
(5, 'gear', 'Stillsuit_Choam_02_Boots', 100),
(5, 'gear', 'Stillsuit_Choam_02_Gloves', 100),
(5, 'gear', 'Stillsuit_Choam_02_Mask', 100),
(5, 'gear', 'Stillsuit_Choam_02_Top', 100),
(5, 'gear', 'Stillsuit_Choam_04_Boots', 100),
(5, 'gear', 'Stillsuit_Choam_04_Gloves', 100),
(5, 'gear', 'Stillsuit_Choam_04_Mask', 100),
(5, 'gear', 'Stillsuit_Choam_04_Top', 100),
(5, 'gear', 'Stillsuit_Choam_05_Boots', 100),
(5, 'gear', 'Stillsuit_Choam_05_Gloves', 100),
(5, 'gear', 'Stillsuit_Choam_05_Mask', 100),
(5, 'gear', 'Stillsuit_Choam_05_Top', 100),
(5, 'gear', 'Stillsuit_Choam_06_Boots', 100),
(5, 'gear', 'Stillsuit_Choam_06_Gloves', 100),
(5, 'gear', 'Stillsuit_Choam_06_Mask', 100),
(5, 'gear', 'Stillsuit_Choam_06_Top', 100),
(5, 'gear', 'Combat_Choam_Heavy01_Boots', 100),
(5, 'gear', 'Combat_Choam_Heavy02_Boots', 100),
(5, 'gear', 'Combat_Choam_Heavy03_Boots', 100),
(5, 'gear', 'Combat_Choam_Heavy04_Shoes', 100),
(5, 'gear', 'Combat_Choam_Heavy06_Boots', 100),
(5, 'gear', 'Combat_Choam_Heavy01_Gloves', 100),
(5, 'gear', 'Combat_Choam_Heavy02_Gloves', 100),
(5, 'gear', 'Combat_Choam_Heavy03_Gloves', 100),
(5, 'gear', 'Combat_Choam_Heavy04_Gloves', 100),
(5, 'gear', 'Combat_Choam_Heavy06_Gloves', 100),
(5, 'gear', 'Combat_Choam_Heavy01_Helmet', 100),
(5, 'gear', 'Combat_Choam_Heavy02_Helmet', 100),
(5, 'gear', 'Combat_Choam_Heavy03_Helmet', 100),
(5, 'gear', 'Combat_Choam_Heavy04_Helmet', 100),
(5, 'gear', 'Combat_Choam_Heavy06_Helmet', 100),
(5, 'gear', 'Combat_Choam_Heavy01_Bottom', 100),
(5, 'gear', 'Combat_Choam_Heavy02_Bottom', 100),
(5, 'gear', 'Combat_Choam_Heavy03_Bottom', 100),
(5, 'gear', 'Combat_Choam_Heavy04_Bottom', 100),
(5, 'gear', 'Combat_Choam_Heavy06_Bottom', 100),
(5, 'gear', 'Combat_Choam_Heavy01_Top', 100),
(5, 'gear', 'Combat_Choam_Heavy02_Top', 100),
(5, 'gear', 'Combat_Choam_Heavy03_Top', 100),
(5, 'gear', 'Combat_Choam_Heavy04_Top', 100),
(5, 'gear', 'Combat_Choam_Heavy06_Top', 100),
(5, 'gear', 'Combat_Choam_Light02_Boots', 100),
(5, 'gear', 'Combat_Choam_Light03_Boots', 100),
(5, 'gear', 'Combat_Choam_Light05_Boots', 100),
(5, 'gear', 'Combat_Choam_Light06_Boots', 100),
(5, 'gear', 'Combat_Choam_Scout03_Boots', 100),
(5, 'gear', 'Combat_Choam_Light02_Gloves', 100),
(5, 'gear', 'Combat_Choam_Light03_Gloves', 100),
(5, 'gear', 'Combat_Choam_Light05_Gloves', 100),
(5, 'gear', 'Combat_Choam_Light06_Gloves', 100),
(5, 'gear', 'Combat_Choam_Scout03_Gloves', 100),
(5, 'gear', 'Combat_Choam_Light02_Helmet', 100),
(5, 'gear', 'Combat_Choam_Light03_Helmet', 100),
(5, 'gear', 'Combat_Choam_Light05_Helmet', 100),
(5, 'gear', 'Combat_Choam_Light06_Helmet', 100),
(5, 'gear', 'Combat_Choam_Scout03_Helmet', 100),
(5, 'gear', 'Combat_Choam_Light02_Bottom', 100),
(5, 'gear', 'Combat_Choam_Light03_Bottom', 100),
(5, 'gear', 'Combat_Choam_Light05_Bottom', 100),
(5, 'gear', 'Combat_Choam_Light06_Bottom', 100),
(5, 'gear', 'Combat_Choam_Scout03_Bottom', 100),
(5, 'gear', 'Combat_Choam_Light02_Top', 100),
(5, 'gear', 'Combat_Choam_Light03_Top', 100),
(5, 'gear', 'Combat_Choam_Light05_Top', 100),
(5, 'gear', 'Combat_Choam_Light06_Top', 100),
(5, 'gear', 'Combat_Choam_Scout03_Top', 100),
(5, 'gear', 'Combat_Light_Unique_BiomeHeat_Top_05', 100),
(5, 'gear', 'Combat_Heavy_Unique_Reinforced_Boots_05', 100),
(5, 'gear', 'Combat_Heavy_Unique_Reinforced_Gloves_05', 100),
(5, 'gear', 'Combat_Heavy_Unique_Reinforced_Helmet_05', 100),
(5, 'gear', 'Combat_Heavy_Unique_Reinforced_Bottom_05', 100),
(5, 'gear', 'Combat_Heavy_Unique_Reinforced_Top_05', 100),
(5, 'gear', 'Combat_Light_Unique_DewReap_Gloves_05', 100),
(5, 'gear', 'Combat_Heavy_Unique_PowerEfficient_Gloves_05', 100),
(5, 'gear', 'Combat_Light_Unique_Scanning_Helmet_05', 100),
(5, 'gear', 'Combat_Light_Unique_Stamina_Bottom_05', 100),
(5, 'gear', 'Stillsuit_Choam_Unique_Dashed02_Top', 100),
(5, 'gear', 'Stillsuit_Choam_Unique_Dashed03_Top', 100),
(5, 'gear', 'Stillsuit_Choam_Unique_Dashed04_Top', 100),
(5, 'gear', 'Stillsuit_Unique_Efficient_05_Boots', 100),
(5, 'gear', 'Stillsuit_Unique_Efficient_05_Gloves', 100),
(5, 'gear', 'Stillsuit_Unique_Efficient_05_Mask', 100),
(5, 'gear', 'Stillsuit_Unique_Efficient_05_Top', 100),
(5, 'gear', 'Stillsuit_Unique_HeatMitigation_05_Mask', 100),
(5, 'gear', 'Combat_Light_Unique_ReduceSuspensor_Top_05', 100),
(5, 'gear', 'Combat_Light_Unique_WormThreat_Boots_05', 100),
(5, 'gear', 'Stillsuit_Unique_Armored_05_Boots', 100),
(5, 'gear', 'Stillsuit_Unique_Armored_05_Gloves', 100),
(5, 'gear', 'Stillsuit_Unique_Armored_05_Mask', 100),
(5, 'gear', 'Stillsuit_Unique_Armored_05_Top', 100),
(5, 'gear', 'Stillsuit_Choam_Unique_Dashed05_Top', 100),
(5, 'gear', 'Stillsuit_Choam_Unique_Dashed06_Top', 100),
(5, 'gear', 'ExplorationSuit_Choam_06_Boots', 100),
(5, 'gear', 'ExplorationSuit_Choam_06_Gloves', 100),
(5, 'gear', 'ExplorationSuit_Choam_06_Mask', 100),
(5, 'gear', 'ExplorationSuit_Choam_06_Top', 100),
(5, 'gear', 'Insulated_Combat_Choam_Heavy06_Shoes', 100),
(5, 'gear', 'Insulated_Combat_Choam_Heavy06_Gloves', 100),
(5, 'gear', 'Insulated_Combat_Choam_Heavy06_Helmet', 100),
(5, 'gear', 'Insulated_Combat_Choam_Heavy06_Bottom', 100),
(5, 'gear', 'Insulated_Combat_Choam_Heavy06_Top', 100),
(5, 'gear', 'Insulated_Combat_Choam_Light06_Boots', 100),
(5, 'gear', 'Insulated_Combat_Choam_Light06_Gloves', 100),
(5, 'gear', 'Insulated_Combat_Choam_Light06_Helmet', 100),
(5, 'gear', 'Insulated_Combat_Choam_Light06_Bottom', 100),
(5, 'gear', 'Insulated_Combat_Choam_Light06_Top', 100),
(5, 'gear', 'Insulated_Combat_Choam_Heavy06_Unique_Boots', 100),
(5, 'gear', 'Insulated_Combat_Choam_Heavy06_Unique_Gloves', 100),
(5, 'gear', 'Insulated_Combat_Choam_Heavy06_Unique_Helmet', 100),
(5, 'gear', 'Insulated_Combat_Choam_Heavy06_Unique_Bottom', 100),
(5, 'gear', 'Insulated_Combat_Choam_Heavy06_Unique_Top', 100),
(5, 'gear', 'Insulated_Combat_Choam_Light06_Unique_Boots', 100),
(5, 'gear', 'Insulated_Combat_Choam_Light06_Unique_Gloves', 100),
(5, 'gear', 'Insulated_Combat_Choam_Light06_Unique_Helmet', 100),
(5, 'gear', 'Insulated_Combat_Choam_Light06_Unique_Bottom', 100),
(5, 'gear', 'Insulated_Combat_Choam_Light06_Unique_Top', 100),
(5, 'gear', 'ExplorationSuit_Choam_06_Unique_Boots', 100),
(5, 'gear', 'ExplorationSuit_Choam_06_Unique_Gloves', 100),
(5, 'gear', 'ExplorationSuit_Choam_06_Unique_Mask', 100),
(5, 'gear', 'ExplorationSuit_Choam_06_Unique_Top', 100),
(5, 'gear', 'BuggyBoost_5', 100),
(5, 'gear', 'BuggyBoost_Unique_LessHeat_5', 100),
(5, 'gear', 'BuggyChassis_5', 100),
(5, 'gear', 'BuggyEngine_5', 100),
(5, 'gear', 'BuggyEngine_Unique_Accelerate_05', 100),
(5, 'gear', 'BuggyGenerator_5', 100),
(5, 'gear', 'BuggyHullBack_5', 100),
(5, 'gear', 'BuggyHullBackExtra_5', 100),
(5, 'gear', 'BuggyHullFront_5', 100),
(5, 'gear', 'BuggyInventory_5', 100),
(5, 'gear', 'BuggyInventory_Unique_Capacity_05', 100),
(5, 'gear', 'BuggyLauncher_5', 100),
(5, 'gear', 'BuggyLocomotion_5', 100),
(5, 'gear', 'BuggyMining_5', 100),
(5, 'gear', 'BuggyMining_Unique_YieldIncrease_05', 100),
(5, 'gear', 'OrnithopterLightBoost_5', 100),
(5, 'gear', 'OrnithopterLightBoost_Unique_LessHeat_5', 100),
(5, 'gear', 'OrnithopterLightChassis_5', 100),
(5, 'gear', 'OrnithopterLightEngine_5', 100),
(5, 'gear', 'OrnithopterLightGenerator_5', 100),
(5, 'gear', 'OrnithopterLightHullBack_5', 100),
(5, 'gear', 'OrnithopterLightHullFront_5', 100),
(5, 'gear', 'OrnithopterLightLauncher_5', 100),
(5, 'gear', 'OrnithopterLightLocomotion_5', 100),
(5, 'gear', 'OrnithopterLightLocomotion_Unique_Speed_5', 100),
(5, 'gear', 'OrnithopterMediumBoost_5', 100),
(5, 'gear', 'OrnithopterMediumBoost_Unique_LessHeat_5', 100),
(5, 'gear', 'OrnithopterMediumChassis_5', 100),
(5, 'gear', 'OrnithopterMediumEngine_5', 100),
(5, 'gear', 'OrnithopterMediumGenerator_5', 100),
(5, 'gear', 'OrnithopterMediumHull_5', 100),
(5, 'gear', 'OrnithopterMediumHullBack_5', 100),
(5, 'gear', 'OrnithopterMediumHullFront_5', 100),
(5, 'gear', 'OrnithopterMediumInventory_5', 100),
(5, 'gear', 'OrnithopterMediumLauncher_5', 100),
(5, 'gear', 'OrnithopterMediumLocomotion_5', 100),
(5, 'gear', 'OrnithopterMediumLocomotion_Unique_Strafe_5', 100),
(5, 'gear', 'SandbikeBoost_5', 100),
(5, 'gear', 'SandbikeBoost_Unique_LessHeat_5', 100),
(5, 'gear', 'SandbikeChassis_5', 100),
(5, 'gear', 'SandbikeEngine_5', 100),
(5, 'gear', 'SandbikeEngine_Unique_Speed_5', 100),
(5, 'gear', 'SandbikeGenerator_5', 100),
(5, 'gear', 'SandbikeHull_5', 100),
(5, 'gear', 'SandbikeLocomotion_5', 100),
(5, 'gear', 'TreadwheelBoost_5', 100),
(5, 'gear', 'TreadwheelBoost_Unique_LessHeat_5', 100),
(5, 'gear', 'TreadwheelChassis_5', 100),
(5, 'gear', 'TreadwheelEngine_5', 100),
(5, 'gear', 'TreadwheelEngine_Unique_Speed_5', 100),
(5, 'gear', 'TreadwheelGenerator_5', 100),
(5, 'gear', 'TreadwheelHull_5', 100),
(5, 'gear', 'TreadwheelLocomotion_5', 100),
(5, 'gear', 'UniqueSword_05', 100),
(5, 'gear', 'UniqueSda_Doubleshot_05', 100),
(5, 'gear', 'UniqueScattergun_Fire_05', 100),
(5, 'gear', 'UniqueAr_Burst_05', 100),
(5, 'gear', 'StaticCompactor_Unique_Compact_05', 100),
(5, 'gear', 'SMG_Unique_LargeMag_05', 100),
(5, 'gear', 'Shotgun_Unique_Explosive_05', 100),
(5, 'gear', 'RepairTool5', 100),
(5, 'gear', 'MiningTool_2h_Light', 100),
(5, 'gear', 'LongRifle_Unique_Poison_05', 100),
(5, 'gear', 'LongRifle_Unique_LargeMag_05', 100),
(5, 'gear', 'LMG_Unique_RapidFire_05', 100),
(5, 'gear', 'Kindjal_Unique_Stamina_05', 100),
(5, 'gear', 'Kindjal_Unique_Blood_05', 100),
(5, 'gear', 'HeavyPistol_Unique_Headshot_05', 100),
(5, 'gear', 'HeavyPistol_Unique_Bleed_05', 100),
(5, 'gear', 'DewReaper_Unique_05', 100),
(5, 'gear', 'DewReaper_2h_Unique_YieldIncrease_05', 100),
(5, 'gear', 'DewReaper_1h_Unique_Compact_05', 100),
(5, 'gear', 'CHOAMSword_3', 100),
(5, 'gear', 'CHOAMSword_2', 100),
(5, 'gear', 'CHOAMSword_1', 100),
(5, 'gear', 'CHOAMSword_0', 100),
(5, 'gear', 'CHOAMSword', 100),
(5, 'gear', 'ChoamSda7', 100),
(5, 'gear', 'ChoamSda6', 100),
(5, 'gear', 'ChoamSda5', 100),
(5, 'gear', 'ChoamSda4', 100),
(5, 'gear', 'ChoamSda3', 100),
(5, 'gear', 'ChoamSda2', 100),
(5, 'gear', 'ChoamSda1', 100),
(5, 'gear', 'ChoamLg2', 100),
(5, 'gear', 'ChoamLg1', 100),
(5, 'gear', 'ChoamCom2', 100),
(5, 'gear', 'ChoamCom1', 100),
(5, 'gear', 'BodyFluidExtractor_Unique_Water_05', 100),
(5, 'gear', 'BodyFluidExtractor_Unique_Poison_05', 100),
(5, 'gear', 'ChoamFlameThrower_T4', 100),
(5, 'gear', 'CHOAMSword_2_Poison_NPC', 100),
(5, 'schematics', 'ChoamHeavyLasgunSchematic', 100),
(5, 'schematics', 'ChoamStaticCompactorSchematic', 100),
(5, 'schematics', 'Schematic_UniqueChoamSword', 100),
(5, 'schematics', 'T6_ChoamLg2_Schematic', 100),
(5, 'schematics', 'SandbikeChoamBoostHeatEfficient2_Schematic', 100),
(5, 'schematics', 'SandbikeChoamBoostHeatEfficient3_Schematic', 100),
(5, 'schematics', 'BuggyChoamBoostHeatEfficient2_Schematic', 100),
(5, 'schematics', 'SandbikeChoamBoostHeatEfficient4_Schematic', 100),
(5, 'schematics', 'BuggyChoamBoostHeatEfficient3_Schematic', 100),
(5, 'schematics', 'LightOrnithopterChoamBoostHeatEfficient2_Schematic', 100),
(5, 'schematics', 'SandbikeEngine_Unique_Speed_5_Schematic', 100),
(5, 'schematics', 'BuggyEngine_Unique_Accelerate_05_Schematic', 100),
(5, 'schematics', 'BuggyMining_Unique_YieldIncrease_05_Schematic', 100),
(5, 'schematics', 'OrnithopterLightEngine_Unique_Speed_05_Schematic', 100),
(5, 'schematics', 'OrnithopterMediumLauncher_Unique_LargeExplosion_05_Schematic', 100),
(5, 'schematics', 'OrnithopterMediumEngine_Unique_Speed_05_Schematic', 100),
(5, 'schematics', 'BuggyInventory_Unique_Capacity_05_Schematic', 100),
(5, 'schematics', 'OrnithopterLightScanner_Unique_LongRange_05_Schematic', 100),
(5, 'schematics', 'OrnithopterLightLauncher_Unique_RapidFire_05_Schematic', 100),
(5, 'schematics', 'HighCapacityLiterjon_05_Schematic', 100),
(5, 'schematics', 'GlidePartialStabilizationBelt_05_Schematic', 100),
(5, 'schematics', 'DewReaper_2h_Unique_YieldIncrease_05_Schematic', 100),
(5, 'schematics', 'StaticCompactor_Unique_Compact_05_Schematic', 100),
(5, 'schematics', 'BodyFluidExtractor_Unique_Water_05_Schematic', 100),
(5, 'schematics', 'BodyFluidExtractor_Unique_Poison_05_Schematic', 100),
(5, 'schematics', 'PowerPack_Unique_Regen_05_Schematic', 100),
(5, 'schematics', 'DewReaper_1h_Unique_Compact_05_Schematic', 100),
(5, 'schematics', 'Bloodsack_Unique_Durable_05_Schematic', 100),
(5, 'schematics', 'Combat_Heavy_Unique_Reinforced_Bottom_05_Schematic', 100),
(5, 'schematics', 'Combat_Heavy_Unique_Reinforced_Gloves_05_Schematic', 100),
(5, 'schematics', 'Combat_Heavy_Unique_Reinforced_Helmet_05_Schematic', 100),
(5, 'schematics', 'Combat_Heavy_Unique_Reinforced_Boots_05_Schematic', 100),
(5, 'schematics', 'Combat_Heavy_Unique_Reinforced_Top_05_Schematic', 100),
(5, 'schematics', 'Stillsuit_Unique_Armored_05_Mask_Schematic', 100),
(5, 'schematics', 'Stillsuit_Unique_Armored_05_Boots_Schematic', 100),
(5, 'schematics', 'Stillsuit_Unique_Armored_05_Gloves_Schematic', 100),
(5, 'schematics', 'Stillsuit_Unique_Armored_05_Top_Schematic', 100),
(5, 'schematics', 'Stillsuit_Unique_Efficient_05_Boots_Schematic', 100),
(5, 'schematics', 'Stillsuit_Unique_Efficient_05_Gloves_Schematic', 100),
(5, 'schematics', 'Stillsuit_Unique_Efficient_05_Mask_Schematic', 100),
(5, 'schematics', 'Stillsuit_Unique_Efficient_05_Top_Schematic', 100),
(5, 'schematics', 'Combat_Heavy_Unique_PowerEfficient_Gloves_05_Schematic', 100),
(5, 'schematics', 'Combat_Light_Unique_Scanning_Helmet_05_Schematic', 100),
(5, 'schematics', 'Combat_Light_Unique_WormThreat_Boots_05_Schematic', 100),
(5, 'schematics', 'Combat_Light_Unique_Stamina_Bottom_05_Schematic', 100),
(5, 'schematics', 'Stillsuit_Unique_HeatMitigation_05_Mask_Schematic', 100),
(5, 'schematics', 'Combat_Light_Unique_DewReap_Gloves_05_Schematic', 100),
(5, 'schematics', 'Combat_Light_Unique_ReduceSuspensor_Top_05_Schematic', 100),
(5, 'schematics', 'SMG_Unique_LargeMag_05_Schematic', 100),
(5, 'schematics', 'Kindjal_Unique_Blood_05_Schematic', 100),
(5, 'schematics', 'LongRifle_Unique_Poison_05_Schematic', 100),
(5, 'schematics', 'HeavyPistol_Unique_Bleed_05_Schematic', 100),
(5, 'schematics', 'LMG_Unique_RapidFire_05_Schematic', 100),
(5, 'schematics', 'Shotgun_Unique_Explosive_05_Schematic', 100),
(5, 'schematics', 'UniqueSda_Doubleshot_05_Schematic', 100),
(5, 'schematics', 'UniqueScattergun_Fire_05_Schematic', 100),
(5, 'schematics', 'HeavyPistol_Unique_Headshot_05_Schematic', 100),
(5, 'schematics', 'LongRifle_Unique_LargeMag_05_Schematic', 100),
(5, 'schematics', 'UniqueAr_Burst_05_Schematic', 100),
(5, 'schematics', 'Kindjal_Unique_Stamina_05_Schematic', 100),
(5, 'schematics', 'Combat_Light_Unique_BiomeHeat_Top_05_Schematic', 100),
(5, 'schematics', 'SandbikeChoamBoostHeatEfficient5_Schematic', 100),
(5, 'schematics', 'BuggyChoamBoostHeatEfficient4_Schematic', 100),
(5, 'schematics', 'LightOrnithopterChoamBoostHeatEfficient3_Schematic', 100),
(5, 'schematics', 'DewReaper_Unique_05_Schematic', 100),
(5, 'schematics', 'UniqueSword_05_Schematic', 100),
(5, 'schematics', 'UniqueSword_05_Damasteel_Schematic', 100),
(5, 'schematics', 'OrnithopterLightLocomotion_Unique_Speed_5_Schematic', 100),
(5, 'schematics', 'OrnithopterMediumBoost_Unique_LessHeat_5_Schematic', 100),
(5, 'schematics', 'OrnithopterMediumLocomotion_Unique_Strafe_5_Schematic', 100),
(5, 'schematics', 'Stillsuit_Choam_Unique_Dashed02_Top_Schematic', 100),
(5, 'schematics', 'Stillsuit_Choam_Unique_Dashed03_Top_Schematic', 100),
(5, 'schematics', 'Stillsuit_Choam_Unique_Dashed04_Top_Schematic', 100),
(5, 'schematics', 'Stillsuit_Choam_Unique_Dashed05_Top_Schematic', 100),
(5, 'schematics', 'Stillsuit_Choam_Unique_Dashed06_Top_Schematic', 100),
(5, 'schematics', 'TreadwheelBoost_Unique_LessHeat_5_Schematic', 100),
(5, 'schematics', 'TreadwheelEngine_Unique_Speed_5_Schematic', 100),
(6, 'crafted_components', 'DolomiteRock', 100),
(6, 'raw_resources', 'FlourSand', 100),
(6, 'crafted_components', 'FuelCanister_Large', 20),
(6, 'crafted_components', 'Silicone', 100),
(6, 'crafted_components', 'SolarisCoin', 10),
(6, 'raw_resources', 'MelangeSpice', 5),
(6, 'raw_resources', 'SpiceSand', 100),
(6, 'crafted_components', 'Basalt', 100),
(6, 'crafted_components', 'WeldingMaterial5', 20),
(6, 'crafted_components', 'ErythriteCrystal', 100),
(6, 'raw_resources', 'SpiceResidue', 100),
(6, 'raw_resources', 'SaguaroResourceRaw', 100),
(6, 'crafted_components', 'FremenComponent2', 100),
(6, 'crafted_components', 'OldImperialComponent1', 30),
(6, 'crafted_components', 'OldImperialComponent2', 30),
(6, 'crafted_components', 'GreatHouseComponent1', 30),
(6, 'crafted_components', 'GreatHouseComponent2', 30),
(6, 'crafted_components', 'T6ResourceA', 150),
(6, 'crafted_components', 'T6ResourceB', 150),
(6, 'crafted_components', 'T3VendorComponent1', 100),
(6, 'crafted_components', 'T6UniqueComponent', 150),
(6, 'crafted_components', 'T6RefinedResourceA', 150),
(6, 'crafted_components', 'T6RefinedResourceB', 150),
(6, 'crafted_components', 'WindTurbineLubricant2', 100),
(6, 'crafted_components', 'WindTrapFilter4', 20),
(6, 'raw_resources', 'SpicedFuelCell', 100),
(6, 'crafted_components', 'T6ArmorPlating', 150),
(6, 'crafted_components', 'T6BladePart', 150),
(6, 'crafted_components', 'T6GunPart', 150),
(6, 'crafted_components', 'T6HoltzmanActuator', 150),
(6, 'crafted_components', 'T6RangeFinder', 150),
(6, 'crafted_components', 'T6Machinery', 150),
(6, 'crafted_components', 'T6RayAmplifier', 150),
(6, 'raw_resources', 'T6IrradiatedCore', 150),
(6, 'crafted_components', 'T6IndustrialPump', 150),
(6, 'crafted_components', 'T6HeavyCalliberCompressor', 150),
(6, 'crafted_components', 'T6LightCalliberCompressor', 150),
(6, 'crafted_components', 'T6FilteredFabric', 150),
(6, 'crafted_components', 'T6DiamodineBladeParts', 150),
(6, 'crafted_components', 'T6CarbidePladeParts', 150),
(6, 'crafted_components', 'T6BalisticWeave', 150),
(6, 'raw_resources', 'T6Watertube', 150),
(6, 'crafted_components', 'T6PowerRegulator', 150),
(6, 'crafted_components', 'T6HydraulicPiston', 150),
(6, 'crafted_components', 'T6PlasteelComponent', 150),
(6, 'crafted_components', 'LandsraadTreasureComponent1', 100),
(6, 'crafted_components', 'LandsraadShipwreckComponent1', 100),
(6, 'crafted_components', 'LandsraadComponent', 100),
(6, 'crafted_components', 'T6LandsraadCraftedComponent', 150),
(6, 'crafted_components', 'T6SchematicFragmentQL4', 150),
(6, 'crafted_components', 'T6SchematicFragmentQL5', 150),
(6, 'gear', 'Radiation_Suit_T6', 100),
(6, 'gear', 'Combat_Light_Unique_BiomeHeat_Top_06', 100),
(6, 'gear', 'Combat_Heavy_Unique_Reinforced_Boots_06', 100),
(6, 'gear', 'Combat_Heavy_Unique_Reinforced_Gloves_06', 100),
(6, 'gear', 'Combat_Heavy_Unique_Reinforced_Helmet_06', 100),
(6, 'gear', 'Combat_Heavy_Unique_Reinforced_Bottom_06', 100),
(6, 'gear', 'Combat_Heavy_Unique_Reinforced_Top_06', 100),
(6, 'gear', 'Combat_Light_Unique_Climbing_Gloves_06', 100),
(6, 'gear', 'Combat_Light_Unique_DewReap_Gloves_06', 100),
(6, 'gear', 'Combat_Light_Unique_MovingDmgReduction_Boots_06', 100),
(6, 'gear', 'Combat_Heavy_Unique_PowerEfficient_Gloves_06', 100),
(6, 'gear', 'Combat_Heavy_Unique_PowerIncrease_Top_06', 100),
(6, 'gear', 'Combat_Light_Unique_Scanning_Helmet_06', 100),
(6, 'gear', 'Combat_Light_Unique_Stamina_Bottom_06', 100),
(6, 'gear', 'Combat_Heavy_Unique_StandStillDmgReduction_Top_06', 100),
(6, 'gear', 'Stillsuit_Unique_Efficient_06_Boots', 100),
(6, 'gear', 'Stillsuit_Unique_Efficient_06_Gloves', 100),
(6, 'gear', 'Stillsuit_Unique_Efficient_06_Mask', 100),
(6, 'gear', 'Stillsuit_Unique_Efficient_06_Top', 100),
(6, 'gear', 'Stillsuit_Unique_HeatMitigation_06_Mask', 100),
(6, 'gear', 'Combat_Light_Unique_ReduceSuspensor_Top_06', 100),
(6, 'gear', 'Combat_Light_Unique_WormThreat_Boots_06', 100),
(6, 'gear', 'Stillsuit_Unique_Armored_06_Boots', 100),
(6, 'gear', 'Stillsuit_Unique_Armored_06_Gloves', 100),
(6, 'gear', 'Stillsuit_Unique_Armored_06_Mask', 100),
(6, 'gear', 'Stillsuit_Unique_HighCapacity_06_Top', 100),
(6, 'gear', 'Stillsuit_Unique_Armored_06_Top', 100),
(6, 'gear', 'Combat_Light_Unique_StaminaDmgIncrease_Helmet_06', 100),
(6, 'gear', 'Radiation_Suit_T6_Unique_Armored', 100),
(6, 'gear', 'Stillsuit_Unique_ThermalSuit_06_Boots', 100),
(6, 'gear', 'Stillsuit_Unique_ThermalSuit_06_Gloves', 100),
(6, 'gear', 'Stillsuit_Unique_ThermalSuit_06_Mask', 100),
(6, 'gear', 'Stillsuit_Unique_ThermalSuit_06_Top', 100),
(6, 'gear', 'BuggyBoost_6', 100),
(6, 'gear', 'BuggyBoost_Unique_LessHeat_6', 100),
(6, 'gear', 'BuggyChassis_6', 100),
(6, 'gear', 'BuggyEngine_6', 100),
(6, 'gear', 'BuggyEngine_Unique_Accelerate_06', 100),
(6, 'gear', 'BuggyGenerator_6', 100),
(6, 'gear', 'BuggyHullBack_6', 100),
(6, 'gear', 'BuggyHullBackExtra_6', 100),
(6, 'gear', 'BuggyHullFront_6', 100),
(6, 'gear', 'BuggyInventory_6', 100),
(6, 'gear', 'BuggyInventory_Unique_Capacity_06', 100),
(6, 'gear', 'BuggyLauncher_6', 100),
(6, 'gear', 'BuggyLocomotion_6', 100),
(6, 'gear', 'BuggyMining_6', 100),
(6, 'gear', 'BuggyMining_Unique_YieldIncrease_06', 100),
(6, 'gear', 'OrnithopterLightBoost_6', 100),
(6, 'gear', 'OrnithopterLightBoost_Unique_LessHeat_6', 100),
(6, 'gear', 'OrnithopterLightChassis_6', 100),
(6, 'gear', 'OrnithopterLightEngine_6', 100),
(6, 'gear', 'OrnithopterLightGenerator_6', 100),
(6, 'gear', 'OrnithopterLightHullBack_6', 100),
(6, 'gear', 'OrnithopterLightHullFront_6', 100),
(6, 'gear', 'OrnithopterLightLauncher_6', 100),
(6, 'gear', 'OrnithopterLightLocomotion_6', 100),
(6, 'gear', 'OrnithopterLightLocomotion_Unique_Speed_6', 100),
(6, 'gear', 'OrnithopterMediumBoost_6', 100),
(6, 'gear', 'OrnithopterMediumBoost_Unique_LessHeat_6', 100),
(6, 'gear', 'OrnithopterMediumChassis_6', 100),
(6, 'gear', 'OrnithopterMediumEngine_6', 100),
(6, 'gear', 'OrnithopterMediumGenerator_6', 100),
(6, 'gear', 'OrnithopterMediumHull_6', 100),
(6, 'gear', 'OrnithopterMediumHullBack_6', 100),
(6, 'gear', 'OrnithopterMediumHullFront_6', 100),
(6, 'gear', 'OrnithopterMediumLauncher_6', 100),
(6, 'gear', 'OrnithopterMediumLocomotion_6', 100),
(6, 'gear', 'OrnithopterMediumLocomotion_Unique_Strafe_6', 100),
(6, 'gear', 'OrnithopterTransportBoost_6', 100),
(6, 'gear', 'OrnithopterTransportBoost_Unique_LessHeat_06', 100),
(6, 'gear', 'OrnithopterTransportChassis_6', 100),
(6, 'gear', 'OrnithopterTransportEngine_6', 100),
(6, 'gear', 'OrnithopterTransportGenerator_6', 100),
(6, 'gear', 'OrnithopterTransportHull_6', 100),
(6, 'gear', 'OrnithopterTransportHullBack_6', 100),
(6, 'gear', 'OrnithopterTransportHullFront_6', 100),
(6, 'gear', 'OrnithopterTransportLocomotion_6', 100),
(6, 'gear', 'SandbikeBoost_6', 100),
(6, 'gear', 'SandbikeBoost_Unique_LessHeat_6', 100),
(6, 'gear', 'SandbikeChassis_6', 100),
(6, 'gear', 'SandbikeEngine_6', 100),
(6, 'gear', 'SandbikeEngine_Unique_Speed_6', 100),
(6, 'gear', 'SandbikeGenerator_6', 100),
(6, 'gear', 'SandbikeHull_6', 100),
(6, 'gear', 'SandbikeLocomotion_6', 100),
(6, 'gear', 'SandcrawlerChassis_6', 100),
(6, 'gear', 'SandcrawlerEngine_6', 100),
(6, 'gear', 'SandcrawlerEngine_Unique_Speed_06', 100),
(6, 'gear', 'SandcrawlerGenerator_6', 100),
(6, 'gear', 'SandcrawlerHull_6', 100),
(6, 'gear', 'SandcrawlerLocomotion_6', 100),
(6, 'gear', 'SandcrawlerLocomotion_Unique_WormThreat_06', 100),
(6, 'gear', 'SandcrawlerSpiceContainer_6', 100),
(6, 'gear', 'SandcrawlerSpiceHeader_6', 100),
(6, 'gear', 'TreadwheelBoost_6', 100),
(6, 'gear', 'TreadwheelBoost_Unique_LessHeat_6', 100),
(6, 'gear', 'TreadwheelChassis_6', 100),
(6, 'gear', 'TreadwheelEngine_6', 100),
(6, 'gear', 'TreadwheelEngine_Unique_Speed_6', 100),
(6, 'gear', 'TreadwheelGenerator_6', 100),
(6, 'gear', 'TreadwheelHull_6', 100),
(6, 'gear', 'TreadwheelLocomotion_6', 100),
(6, 'gear', 'UniqueSda_Doubleshot_06', 100),
(6, 'gear', 'UniqueScattergun_Fire_06', 100),
(6, 'gear', 'UniqueRapier_Power_06', 100),
(6, 'gear', 'UniqueAr_Burst_06', 100),
(6, 'gear', 'StaticCompactor_Unique_Compact_06', 100),
(6, 'gear', 'SMG_Unique_LargeMag_06', 100),
(6, 'gear', 'Shotgun_Unique_Explosive_06', 100),
(6, 'gear', 'Shotgun_Unique_Blood_06', 100),
(6, 'gear', 'RocketLauncher_Unique_Homing_06', 100),
(6, 'gear', 'MiningTool_2h_Advanced', 100),
(6, 'gear', 'LongRifle_Unique_Poison_06', 100),
(6, 'gear', 'LongRifle_Unique_LargeMag_06', 100),
(6, 'gear', 'LMG_Unique_RapidFire_06', 100),
(6, 'gear', 'LMG_Unique_Power_06', 100),
(6, 'gear', 'Kindjal_Unique_Stamina_06', 100),
(6, 'gear', 'Kindjal_Unique_Blood_06', 100),
(6, 'gear', 'HeavyPistol_Unique_Headshot_06', 100),
(6, 'gear', 'HeavyPistol_Unique_Bleed_06', 100),
(6, 'gear', 'DewReaper_2h_Unique_YieldIncrease_06', 100),
(6, 'gear', 'DewReaper_2h_Tier6', 100),
(6, 'gear', 'DewReaper_1h_Unique_Compact_06', 100),
(6, 'gear', 'DewReaper_1h_Tier6', 100),
(6, 'gear', 'BodyFluidExtractor_Unique_Water_06', 100),
(6, 'gear', 'BodyFluidExtractor_Unique_Poison_06', 100),
(6, 'gear', 'BodyFluidExtractor_2h_tier6', 100),
(6, 'gear', 'Shotgun_Unique_LargeMag_06', 100),
(6, 'schematics', 'T6_UniqueFlamethrower_Prototype_2_Schematic', 100),
(6, 'schematics', 'SandbikeEngine_Unique_Speed_6_Schematic', 100),
(6, 'schematics', 'BuggyEngine_Unique_Accelerate_06_Schematic', 100),
(6, 'schematics', 'BuggyMining_Unique_YieldIncrease_06_Schematic', 100),
(6, 'schematics', 'OrnithopterLightEngine_Unique_Speed_06_Schematic', 100),
(6, 'schematics', 'OrnithopterTransportEngine_Unique_Speed_06_Schematic', 100),
(6, 'schematics', 'SandcrawlerEngine_Unique_Speed_06_Schematic', 100),
(6, 'schematics', 'OrnithopterMediumLauncher_Unique_LargeExplosion_06_Schematic', 100),
(6, 'schematics', 'OrnithopterMediumEngine_Unique_Speed_06_Schematic', 100),
(6, 'schematics', 'BuggyInventory_Unique_Capacity_06_Schematic', 100),
(6, 'schematics', 'OrnithopterLightLauncher_Unique_RapidFire_06_Schematic', 100),
(6, 'schematics', 'SandcrawlerLocomotion_Unique_WormThreat_06_Schematic', 100),
(6, 'schematics', 'OrnithopterTransportBoost_Unique_LessHeat_06_Schematic', 100),
(6, 'schematics', 'HighCapacityLiterjon_06_Schematic', 100),
(6, 'schematics', 'GlidePartialStabilizationBelt_06_Schematic', 100),
(6, 'schematics', 'DewReaper_2h_Unique_YieldIncrease_06_Schematic', 100),
(6, 'schematics', 'StaticCompactor_Unique_Compact_06_Schematic', 100),
(6, 'schematics', 'BodyFluidExtractor_Unique_Water_06_Schematic', 100),
(6, 'schematics', 'BodyFluidExtractor_Unique_Poison_06_Schematic', 100),
(6, 'schematics', 'PowerPack_Unique_Regen_06_Schematic', 100),
(6, 'schematics', 'DewReaper_1h_Unique_Compact_06_Schematic', 100),
(6, 'schematics', 'Bloodsack_Unique_Durable_06_Schematic', 100),
(6, 'schematics', 'Combat_Heavy_Unique_Reinforced_Bottom_06_Schematic', 100),
(6, 'schematics', 'Combat_Heavy_Unique_Reinforced_Gloves_06_Schematic', 100),
(6, 'schematics', 'Combat_Heavy_Unique_Reinforced_Helmet_06_Schematic', 100),
(6, 'schematics', 'Combat_Heavy_Unique_Reinforced_Boots_06_Schematic', 100),
(6, 'schematics', 'Combat_Heavy_Unique_Reinforced_Top_06_Schematic', 100),
(6, 'schematics', 'Stillsuit_Unique_Armored_06_Mask_Schematic', 100),
(6, 'schematics', 'Stillsuit_Unique_Armored_06_Boots_Schematic', 100),
(6, 'schematics', 'Stillsuit_Unique_Armored_06_Gloves_Schematic', 100),
(6, 'schematics', 'Stillsuit_Unique_Armored_06_Top_Schematic', 100),
(6, 'schematics', 'Stillsuit_Unique_Efficient_06_Boots_Schematic', 100),
(6, 'schematics', 'Stillsuit_Unique_Efficient_06_Gloves_Schematic', 100),
(6, 'schematics', 'Stillsuit_Unique_Efficient_06_Mask_Schematic', 100),
(6, 'schematics', 'Stillsuit_Unique_Efficient_06_Top_Schematic', 100),
(6, 'schematics', 'Combat_Heavy_Unique_PowerEfficient_Gloves_06_Schematic', 100),
(6, 'schematics', 'Combat_Heavy_Unique_PowerIncrease_Top_06_Schematic', 100),
(6, 'schematics', 'Combat_Light_Unique_Scanning_Helmet_06_Schematic', 100),
(6, 'schematics', 'Combat_Light_Unique_WormThreat_Boots_06_Schematic', 100),
(6, 'schematics', 'Combat_Light_Unique_Climbing_Gloves_06_Schematic', 100),
(6, 'schematics', 'Combat_Light_Unique_Stamina_Bottom_06_Schematic', 100),
(6, 'schematics', 'Stillsuit_Unique_HighCapacity_06_Top_Schematic', 100),
(6, 'schematics', 'Stillsuit_Unique_HeatMitigation_06_Mask_Schematic', 100),
(6, 'schematics', 'Combat_Light_Unique_DewReap_Gloves_06_Schematic', 100),
(6, 'schematics', 'Combat_Light_Unique_ReduceSuspensor_Top_06_Schematic', 100),
(6, 'schematics', 'SMG_Unique_LargeMag_06_Schematic', 100),
(6, 'schematics', 'Kindjal_Unique_Blood_06_Schematic', 100),
(6, 'schematics', 'LongRifle_Unique_Poison_06_Schematic', 100),
(6, 'schematics', 'HeavyPistol_Unique_Bleed_06_Schematic', 100),
(6, 'schematics', 'LMG_Unique_RapidFire_06_Schematic', 100),
(6, 'schematics', 'Shotgun_Unique_Explosive_06_Schematic', 100),
(6, 'schematics', 'RocketLauncher_Unique_Homing_06_Schematic', 100),
(6, 'schematics', 'UniqueSda_Doubleshot_06_Schematic', 100),
(6, 'schematics', 'UniqueScattergun_Fire_06_Schematic', 100),
(6, 'schematics', 'HeavyPistol_Unique_Headshot_06_Schematic', 100),
(6, 'schematics', 'LongRifle_Unique_LargeMag_06_Schematic', 100),
(6, 'schematics', 'LMG_Unique_Power_06_Schematic', 100),
(6, 'schematics', 'Shotgun_Unique_Blood_06_Schematic', 100),
(6, 'schematics', 'UniqueAr_Burst_06_Schematic', 100),
(6, 'schematics', 'Kindjal_Unique_Stamina_06_Schematic', 100),
(6, 'schematics', 'UniqueRapier_Power_06_Schematic', 100),
(6, 'schematics', 'Combat_Light_Unique_BiomeHeat_Top_06_Schematic', 100),
(6, 'schematics', 'OrnithopterLightLocomotion_Unique_Speed_6_Schematic', 100),
(6, 'schematics', 'OrnithopterMediumBoost_Unique_LessHeat_6_Schematic', 100),
(6, 'schematics', 'OrnithopterMediumLocomotion_Unique_Strafe_6_Schematic', 100),
(6, 'schematics', 'Shotgun_Unique_LargeMag_06_Schematic', 100),
(6, 'schematics', 'Combat_Light_Unique_MovingDmgReduction_Boots_06_Schematic', 100),
(6, 'schematics', 'Combat_Heavy_Unique_StandStillDmgReduction_Top_06_Schematic', 100),
(6, 'schematics', 'Combat_Light_Unique_StaminaDmgIncrease_Helmet_06_Schematic', 100),
(6, 'schematics', 'PowerPack_Unique_PoisRadMitigation_06_Schematic', 100),
(6, 'schematics', 'TreadwheelBoost_Unique_LessHeat_6_Schematic', 100),
(6, 'schematics', 'TreadwheelEngine_Unique_Speed_6_Schematic', 100),
(6, 'schematics', 'PowerPack_Unique_Capacity_06_Schematic', 100),
(6, 'schematics', 'T6_Augment_Acuracy1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor10_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor11_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor12_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor13_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor14_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor16_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor17_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor2_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor4_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor5_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor6_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor8_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor9_Schematic', 100),
(6, 'schematics', 'T6_Augment_BR1_Schematic', 100),
(6, 'schematics', 'T6_Augment_BR2_Schematic', 100),
(6, 'schematics', 'T6_Augment_BR3_Schematic', 100),
(6, 'schematics', 'T6_Augment_BR4_Schematic', 100),
(6, 'schematics', 'T6_Augment_BR8_Schematic', 100),
(6, 'schematics', 'T6_Augment_Damage1_Schematic', 100),
(6, 'schematics', 'T6_Augment_DeathDurabilityOff_Schematic', 100),
(6, 'schematics', 'T6_Augment_Fireballer1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Fireballer2_Schematic', 100),
(6, 'schematics', 'T6_Augment_Flamethrower1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Flamethrower2_Schematic', 100),
(6, 'schematics', 'T6_Augment_Flamethrower3_Schematic', 100),
(6, 'schematics', 'T6_Augment_Flamethrower4_Schematic', 100),
(6, 'schematics', 'T6_Augment_Headshotdamage1_Schematic', 100),
(6, 'schematics', 'T6_Augment_HeavyPistol1_Schematic', 100),
(6, 'schematics', 'T6_Augment_HeavyPistol2_Schematic', 100),
(6, 'schematics', 'T6_Augment_HeavyPistol3_Schematic', 100),
(6, 'schematics', 'T6_Augment_HeavyPistol4_Schematic', 100),
(6, 'schematics', 'T6_Augment_HeavyPistol5_Schematic', 100),
(6, 'schematics', 'T6_Augment_Lasgun1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Lasgun2_Schematic', 100),
(6, 'schematics', 'T6_Augment_Lasgun3_Schematic', 100),
(6, 'schematics', 'T6_Augment_Lasgun4_Schematic', 100),
(6, 'schematics', 'T6_Augment_Lmg1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Lmg4_Schematic', 100),
(6, 'schematics', 'T6_Augment_Lmg5_Schematic', 100),
(6, 'schematics', 'T6_Augment_Lmg6_Schematic', 100),
(6, 'schematics', 'T6_Augment_Magazinecapacity1_Schematic', 100),
(6, 'schematics', 'T6_Augment_MaulaPistol1_Schematic', 100),
(6, 'schematics', 'T6_Augment_MaulaPistol2_Schematic', 100),
(6, 'schematics', 'T6_Augment_MaulaPistol3_Schematic', 100),
(6, 'schematics', 'T6_Augment_MaulaPistol4_Schematic', 100),
(6, 'schematics', 'T6_Augment_MaulaPistol5_Schematic', 100),
(6, 'schematics', 'T6_Augment_Melee1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Melee2_Schematic', 100),
(6, 'schematics', 'T6_Augment_Melee3_Schematic', 100),
(6, 'schematics', 'T6_Augment_Melee4_Schematic', 100),
(6, 'schematics', 'T6_Augment_Melee5_Schematic', 100),
(6, 'schematics', 'T6_Augment_Melee6_Schematic', 100),
(6, 'schematics', 'T6_Augment_Melee7_Schematic', 100),
(6, 'schematics', 'T6_Augment_Melee8_Schematic', 100),
(6, 'schematics', 'T6_Augment_Melee9_Schematic', 100),
(6, 'schematics', 'T6_Augment_Range1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Rateoffire1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Recoil1_Schematic', 100),
(6, 'schematics', 'T6_Augment_ReloadSpeed1_Schematic', 100),
(6, 'schematics', 'T6_Augment_RocketLauncher1_Schematic', 100),
(6, 'schematics', 'T6_Augment_RocketLauncher2_Schematic', 100),
(6, 'schematics', 'T6_Augment_RocketLauncher3_Schematic', 100),
(6, 'schematics', 'T6_Augment_RocketLauncher4_Schematic', 100),
(6, 'schematics', 'T6_Augment_Scattergun2_Schematic', 100),
(6, 'schematics', 'T6_Augment_Scattergun4_Schematic', 100),
(6, 'schematics', 'T6_Augment_Scattergun5_Schematic', 100),
(6, 'schematics', 'T6_Augment_Scattergun6_Schematic', 100),
(6, 'schematics', 'T6_Augment_Scattergun7_Schematic', 100),
(6, 'schematics', 'T6_Augment_Scattergun8_Schematic', 100),
(6, 'schematics', 'T6_Augment_Shielddamage1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Shotgun1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Shotgun2_Schematic', 100),
(6, 'schematics', 'T6_Augment_Shotgun3_Schematic', 100),
(6, 'schematics', 'T6_Augment_Shotgun4_Schematic', 100),
(6, 'schematics', 'T6_Augment_Shotgun5_Schematic', 100),
(6, 'schematics', 'T6_Augment_smg1_Schematic', 100),
(6, 'schematics', 'T6_Augment_smg2_Schematic', 100),
(6, 'schematics', 'T6_Augment_smg3_Schematic', 100),
(6, 'schematics', 'T6_Augment_smg4_Schematic', 100),
(6, 'schematics', 'T6_Augment_Smg5_Schematic', 100),
(6, 'schematics', 'T6_Augment_smg7_Schematic', 100),
(6, 'schematics', 'T6_Augment_Spitdartrifle2_Schematic', 100),
(6, 'schematics', 'T6_Augment_Spitdartrifle3_Schematic', 100),
(6, 'schematics', 'T6_Augment_SpitdartRifle5_Schematic', 100),
(6, 'schematics', 'T6_Augment_SpitdartRifle6_Schematic', 100),
(6, 'schematics', 'T6_Augment_SpitdartRifle7_Schematic', 100),
(6, 'schematics', 'T6_Augment_SpitdartRifle8_Schematic', 100),
(6, 'schematics', 'T6_Augment_Armor3_Schematic', 100),
(6, 'schematics', 'Radiation_Suit_T6_Unique_Armored_Schematic', 100),
(6, 'schematics', 'T6_Augment_Damage2_Schematic', 100),
(6, 'schematics', 'T6_Augment_Ch5_BR1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Ch5_Fireballer1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Ch5_Flamethrower1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Ch5_Heavypistol1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Ch5_Lasgun1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Ch5_LMG1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Ch5_Maulapistol1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Ch5_RocketLauncher1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Ch5_Scattergun1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Ch5_Shotgun1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Ch5_SMG1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Ch5_Melee1_Schematic', 100),
(6, 'schematics', 'T6_Augment_Ch5_Melee3_Schematic', 100)
ON CONFLICT (tier, category, template_id) DO NOTHING;

-- ==========================================
-- [END AUTO-GENERATED LOOT POOLS]

-- Migrate readable v1.3.6 data without altering or taking ownership of the
-- legacy objects. This remains safe to rerun after the migration is complete.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM dune_airdrop.config
    WHERE config_key = 'legacy_v136_migrated'
  ) AND to_regclass('dune.airdrop_active_playtime') IS NOT NULL THEN
    INSERT INTO dune_airdrop.active_playtime
      (character_id, active_seconds, last_xp, last_x, last_y, last_z,
       last_active_at, last_login_date, consecutive_days, weekly_login_mask,
       current_week_id, last_weekly_claimed_at)
    SELECT character_id, active_seconds, last_xp, last_x, last_y, last_z,
           last_active_at, last_login_date, consecutive_days, weekly_login_mask,
           current_week_id, last_weekly_claimed_at
    FROM dune.airdrop_active_playtime
    ON CONFLICT (character_id) DO UPDATE SET
      active_seconds = EXCLUDED.active_seconds,
      last_xp = EXCLUDED.last_xp,
      last_x = EXCLUDED.last_x,
      last_y = EXCLUDED.last_y,
      last_z = EXCLUDED.last_z,
      last_active_at = EXCLUDED.last_active_at,
      last_login_date = EXCLUDED.last_login_date,
      consecutive_days = EXCLUDED.consecutive_days,
      weekly_login_mask = EXCLUDED.weekly_login_mask,
      current_week_id = EXCLUDED.current_week_id,
      last_weekly_claimed_at = EXCLUDED.last_weekly_claimed_at;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM dune_airdrop.config
    WHERE config_key = 'legacy_v136_migrated'
  ) AND to_regclass('dune.airdrop_pending_deliveries') IS NOT NULL THEN
    INSERT INTO dune_airdrop.pending_deliveries
      (id, request_id, account_id, template_id, stack_size, quality_level,
       is_applied, locked_at, created_at)
    SELECT id, COALESCE(request_id, gen_random_uuid()), account_id, template_id, stack_size, quality_level,
           is_applied, locked_at, created_at
    FROM dune.airdrop_pending_deliveries
    ON CONFLICT DO NOTHING;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM dune_airdrop.config
    WHERE config_key = 'legacy_v136_migrated'
  ) AND to_regclass('dune.airdrop_delivery_receipts') IS NOT NULL THEN
    INSERT INTO dune_airdrop.delivery_receipts
      (request_id, account_id, template_id, quantity, status, granted_at)
    SELECT request_id, account_id, template_id, quantity, status, granted_at
    FROM dune.airdrop_delivery_receipts
    ON CONFLICT (request_id) DO NOTHING;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM dune_airdrop.config
    WHERE config_key = 'legacy_v136_migrated'
  ) AND to_regclass('dune.airdrop_config') IS NOT NULL THEN
    INSERT INTO dune_airdrop.config (config_key, config_value)
    SELECT config_key, config_value
    FROM dune.airdrop_config
    ON CONFLICT (config_key) DO UPDATE
      SET config_value = EXCLUDED.config_value;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM dune_airdrop.config
    WHERE config_key = 'legacy_v136_migrated'
  ) AND to_regclass('dune.airdrop_loot_tables') IS NOT NULL THEN
    INSERT INTO dune_airdrop.loot_tables (tier, category, template_id, weight)
    SELECT tier, category, template_id, weight
    FROM dune.airdrop_loot_tables
    ON CONFLICT (tier, category, template_id) DO UPDATE
      SET weight = EXCLUDED.weight;
  END IF;

  INSERT INTO dune_airdrop.config (config_key, config_value)
  VALUES ('legacy_v136_migrated', jsonb_build_object('completed_at', NOW()))
  ON CONFLICT (config_key) DO NOTHING;
END;
$$;

-- Create notifications only after legacy rows have been copied so migration
-- cannot accidentally wake an older daemon during setup.
DROP TRIGGER IF EXISTS trg_notify_airdrop ON dune_airdrop.pending_deliveries;
CREATE TRIGGER trg_notify_airdrop
AFTER INSERT ON dune_airdrop.pending_deliveries
FOR EACH ROW EXECUTE FUNCTION dune_airdrop.trg_notify_pending_delivery_v2();

SELECT setval(
  pg_get_serial_sequence('dune_airdrop.pending_deliveries', 'id'),
  GREATEST(COALESCE((SELECT MAX(id) FROM dune_airdrop.pending_deliveries), 1), 1),
  EXISTS (SELECT 1 FROM dune_airdrop.pending_deliveries)
);

-- ==========================================
-- [START MANUAL SPAWN HELPER]
-- ==========================================
CREATE OR REPLACE FUNCTION dune_airdrop.fn_manual_airdrop_spawn(p_container_id BIGINT, p_template_id TEXT, p_qty INT)
RETURNS VOID AS $$
DECLARE
  v_account_id BIGINT;
BEGIN
  IF p_qty <= 0 THEN
    RAISE EXCEPTION 'Quantity must be greater than 0';
  END IF;
  IF p_template_id IS NULL OR p_template_id = '' THEN
    RAISE EXCEPTION 'Template ID cannot be empty';
  END IF;

  SELECT account_id INTO v_account_id FROM dune.inventories WHERE id = p_container_id LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Container % not found or has no owner account', p_container_id;
  END IF;

  INSERT INTO dune_airdrop.pending_deliveries (account_id, template_id, stack_size, is_applied, quality_level)
  VALUES (v_account_id, p_template_id, p_qty, false, 0);
END;
$$ LANGUAGE plpgsql;

RESET ROLE;
