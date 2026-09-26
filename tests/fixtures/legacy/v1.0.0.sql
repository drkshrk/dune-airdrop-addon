-- PostgreSQL Playtime Airdrop Engine
-- Run this SQL on your Dune Awakening self-hosted PostgreSQL database.

-- 1. Create playtime tracking table (supports coordinates, XP, anti-AFK validation, daily and weekly streaks)
DROP TABLE IF EXISTS dune.bot_active_playtime CASCADE;
CREATE TABLE dune.bot_active_playtime (
  character_id TEXT PRIMARY KEY,
  active_seconds INT DEFAULT 0,
  last_xp BIGINT DEFAULT 0,
  last_x DOUBLE PRECISION DEFAULT 0.0,
  last_y DOUBLE PRECISION DEFAULT 0.0,
  last_z DOUBLE PRECISION DEFAULT 0.0,
  last_active_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  last_login_date DATE,
  consecutive_days INT DEFAULT 0,
  weekly_login_mask INT DEFAULT 0,
  last_weekly_claimed_at TIMESTAMP WITH TIME ZONE
);

-- 2. Create pending deliveries queue table
CREATE TABLE IF NOT EXISTS dune.bot_pending_deliveries (
  id SERIAL PRIMARY KEY,
  account_id BIGINT NOT NULL,
  template_id TEXT NOT NULL,
  stack_size INT NOT NULL,
  is_applied BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  quality_level INT DEFAULT 0
);

-- 3. Create the addon config table
CREATE TABLE IF NOT EXISTS dune.airdrop_addon_config (
  config_key TEXT PRIMARY KEY,
  config_value JSONB
);

-- Insert default configurations if missing
INSERT INTO dune.airdrop_addon_config (config_key, config_value) 
VALUES (
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
) 
ON CONFLICT (config_key) DO NOTHING;

-- 4. Dynamic level and tier resolver
CREATE OR REPLACE FUNCTION dune.fn_get_pawn_tier(p_pawn_id TEXT)
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
  WHERE afe.actor_id = p_pawn_id::bigint AND afe.slot_name = 'DuneCharacter'
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
CREATE OR REPLACE FUNCTION dune.fn_queue_reward_roll(p_account_id BIGINT, p_tier INT, p_multiplier NUMERIC, p_reason TEXT)
RETURNS VOID AS $$
DECLARE
  v_gear_template TEXT;
  v_res_template_1 TEXT;
  v_res_template_2 TEXT;
  v_schem_template TEXT;
  v_res_qty_1 INT;
  v_res_qty_2 INT;
  v_gear_quality INT := 0;
BEGIN
  -- Roll Gear (40% chance)
  IF RANDOM() <= 0.40 THEN
    SELECT id INTO v_gear_template FROM (
      VALUES 
        (0, 'MakeshiftClothing'), (0, 'ScrapMetalKnife'),
        (1, 'ScavengerStillsuit'), (1, 'KirabHeavyArmor'),
        (2, 'KirabStillsuit'), (2, 'StandardSword'),
        (3, 'SlaverStillsuit'), (3, 'ArtisanSword'),
        (4, 'NativeStillsuit'), (4, 'HouseSword'),
        (5, 'MercenaryStillsuit'), (5, 'AdeptSword'),
        (6, 'CHOAMStillsuit'), (6, 'RegisSword')
    ) AS gear_pool(tier, id)
    WHERE tier = p_tier
    ORDER BY RANDOM()
    LIMIT 1;

    -- Keep all gear quality levels at 0 to support instant delivery without forcing relogs
    v_gear_quality := 0;
  END IF;

  -- Roll Resources
  SELECT id INTO v_res_template_1 FROM (
    VALUES
      (0, 'ScrapMetal'), (0, 'PlantFiber'), (0, 'Stone'),
      (1, 'CopperOre'), (1, 'AzuriteOre'), (1, 'FlourSand'), (1, 'Silicone'),
      (2, 'IronOre'), (2, 'MagnetiteOre'), (2, 'DolomiteRock'), (2, 'SaguaroResourceRaw'),
      (3, 'SteelBar'), (3, 'JasmiumCrystal'), (3, 'T3MarksmanComponent'),
      (4, 'AluminiumBar'), (4, 'BauxiteOre'), (4, 'Plastone'), (4, 'ErythriteCrystal'),
      (5, 'DuraluminumRod'), (5, 'CobaltBar'), (5, 'EMFGenerator'),
      (6, 'T6RefinedResourceA'), (6, 'T6RefinedResourceB'), (6, 'T6ResourceA'), (6, 'MelangeSpice')
  ) AS res_pool(tier, id)
  WHERE tier = p_tier
  ORDER BY RANDOM()
  LIMIT 1;

  SELECT id INTO v_res_template_2 FROM (
    VALUES
      (0, 'ScrapMetal'), (0, 'PlantFiber'), (0, 'Stone'),
      (1, 'CopperOre'), (1, 'AzuriteOre'), (1, 'FlourSand'), (1, 'Silicone'),
      (2, 'IronOre'), (2, 'MagnetiteOre'), (2, 'DolomiteRock'), (2, 'SaguaroResourceRaw'),
      (3, 'SteelBar'), (3, 'JasmiumCrystal'), (3, 'T3MarksmanComponent'),
      (4, 'AluminiumBar'), (4, 'BauxiteOre'), (4, 'Plastone'), (4, 'ErythriteCrystal'),
      (5, 'DuraluminumRod'), (5, 'CobaltBar'), (5, 'EMFGenerator'),
      (6, 'T6RefinedResourceA'), (6, 'T6RefinedResourceB'), (6, 'T6ResourceA'), (6, 'MelangeSpice')
  ) AS res_pool(tier, id)
  WHERE tier = p_tier AND id <> COALESCE(v_res_template_1, '')
  ORDER BY RANDOM()
  LIMIT 1;

  IF v_res_template_2 IS NULL THEN
    v_res_template_2 := v_res_template_1;
  END IF;

  v_res_qty_1 := GREATEST(1, ROUND((FLOOR(RANDOM() * 6) + 5) * p_multiplier));
  v_res_qty_2 := GREATEST(1, ROUND((FLOOR(RANDOM() * 6) + 5) * p_multiplier));

  -- Roll Schematic (80% chance)
  IF RANDOM() <= 0.80 THEN
    SELECT id INTO v_schem_template FROM (
      VALUES
        (0, 'Schematic_MakeshiftLocker'), (0, 'Schematic_MakeshiftBed'),
        (1, 'Schematic_KirabArmor'), (1, 'Schematic_SimpleStool'),
        (2, 'Schematic_StandardSword'), (2, 'Schematic_StorageChest'),
        (3, 'Schematic_ArtisanSword'), (3, 'Schematic_IronLocker'),
        (4, 'Schematic_HouseSword'), (4, 'Schematic_HeavyLocker'),
        (5, 'Schematic_AdeptSword'), (5, 'Schematic_WeaponRack'),
        (6, 'Schematic_RegisSword'), (6, 'Schematic_AdvancedVault')
    ) AS schem_pool(tier, id)
    WHERE tier = p_tier
    ORDER BY RANDOM()
    LIMIT 1;
  END IF;

  -- Queue items
  IF v_gear_template IS NOT NULL THEN
    INSERT INTO dune.bot_pending_deliveries (account_id, template_id, stack_size, is_applied, quality_level)
    VALUES (p_account_id, v_gear_template, 1, FALSE, v_gear_quality);
  END IF;

  IF v_res_template_1 IS NOT NULL THEN
    INSERT INTO dune.bot_pending_deliveries (account_id, template_id, stack_size, is_applied, quality_level)
    VALUES (p_account_id, v_res_template_1, v_res_qty_1, FALSE, 0);
  END IF;

  IF v_res_template_2 IS NOT NULL THEN
    INSERT INTO dune.bot_pending_deliveries (account_id, template_id, stack_size, is_applied, quality_level)
    VALUES (p_account_id, v_res_template_2, v_res_qty_2, FALSE, 0);
  END IF;

  IF v_schem_template IS NOT NULL THEN
    INSERT INTO dune.bot_pending_deliveries (account_id, template_id, stack_size, is_applied, quality_level)
    VALUES (p_account_id, v_schem_template, 1, FALSE, 0);
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 6. Playtime Reward Rolling logic wrapper
CREATE OR REPLACE FUNCTION dune.fn_roll_playtime_reward(p_account_id BIGINT, p_pawn_id TEXT)
RETURNS VOID AS $$
DECLARE
  v_tier INT;
  v_config JSONB;
  v_multiplier NUMERIC := 1.0;
BEGIN
  v_tier := dune.fn_get_pawn_tier(p_pawn_id);

  SELECT config_value INTO v_config FROM dune.airdrop_addon_config WHERE config_key = 'airdrop_multipliers';
  IF v_config IS NOT NULL THEN
    v_multiplier := COALESCE((v_config->>('playtime_multiplier_t' || v_tier::text))::numeric, 1.0);
  END IF;
  IF v_multiplier < 1.0 THEN v_multiplier := 1.0; END IF;

  PERFORM dune.fn_queue_reward_roll(p_account_id, v_tier, v_multiplier, 'playtime');
END;
$$ LANGUAGE plpgsql;

-- 7. Deliver pending rewards instantly without relogs
CREATE OR REPLACE FUNCTION dune.fn_deliver_playtime_airdrops(p_account_id BIGINT, p_pawn_id TEXT)
RETURNS VOID AS $$
DECLARE
  v_inv_id INT;
  v_item RECORD;
BEGIN
  SELECT id INTO v_inv_id 
  FROM dune.inventories 
  WHERE actor_id = p_pawn_id::bigint AND inventory_type = 0 
  LIMIT 1;

  IF v_inv_id IS NOT NULL THEN
    FOR v_item IN 
      SELECT id, template_id, stack_size, quality_level 
      FROM dune.bot_pending_deliveries 
      WHERE account_id = p_account_id AND is_applied = FALSE
    LOOP
      INSERT INTO dune.items (inventory_id, template_id, stack_size, position_index, stats, quality_level, is_new, acquisition_time)
      VALUES (
        v_inv_id, 
        v_item.template_id, 
        v_item.stack_size, 
        (SELECT COALESCE(MAX(position_index) + 1, 0) FROM dune.items WHERE inventory_id = v_inv_id), 
        '{"FItemStackAndDurabilityStats": [[], {"DecayedMaxDurability": 0.0}]}'::jsonb, 
        v_item.quality_level,
        TRUE,
        EXTRACT(epoch from now())::bigint
      );

      UPDATE dune.bot_pending_deliveries 
      SET is_applied = TRUE 
      WHERE id = v_item.id;
    END LOOP;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 8. Daily and Weekly rewards check function executed on login/save
CREATE OR REPLACE FUNCTION dune.fn_check_daily_weekly_rewards(p_account_id BIGINT, p_pawn_id TEXT)
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
  v_today_bit INT;
  v_i INT;
BEGIN
  -- Load configurations
  SELECT config_value INTO v_config FROM dune.airdrop_addon_config WHERE config_key = 'airdrop_multipliers';
  IF v_config IS NOT NULL THEN
    v_daily_enabled := COALESCE((v_config->>'daily_enabled')::boolean, TRUE);
    v_daily_step := COALESCE((v_config->>'daily_multiplier_step')::numeric, 0.5);
    v_daily_max := COALESCE((v_config->>'daily_max_streak')::int, 7);
    v_weekly_enabled := COALESCE((v_config->>'weekly_enabled')::boolean, TRUE);
    v_weekly_req := COALESCE((v_config->>'weekly_days_required')::int, 5);
    v_weekly_scale := COALESCE((v_config->>'weekly_multiplier')::numeric, 5.0);
  END IF;

  v_tier := dune.fn_get_pawn_tier(p_pawn_id);

  -- Fetch player stats record
  SELECT * INTO v_track FROM dune.bot_active_playtime WHERE character_id = p_pawn_id;
  IF v_track.character_id IS NULL THEN
    -- Initialize if missing
    INSERT INTO dune.bot_active_playtime (character_id, last_login_date, consecutive_days, weekly_login_mask)
    VALUES (p_pawn_id, v_today, 1, 1);
    v_track.last_login_date := v_today;
    v_track.consecutive_days := 1;
    v_track.weekly_login_mask := 1;
  END IF;

  -- Process Daily Reward (Only once per calendar date)
  IF v_track.last_login_date IS NULL OR v_track.last_login_date < v_today THEN
    -- Calculate consecutive daily streak
    IF v_track.last_login_date = v_today - 1 THEN
      v_streak := LEAST(v_daily_max, v_track.consecutive_days + 1);
    ELSE
      v_streak := 1;
    END IF;

    -- Update weekly mask. We represent weekly logins using a 7-bit mask.
    -- Shift previous bits left by 1 and set the LSB to 1 for today.
    v_mask := ((v_track.weekly_login_mask << 1) | 1) & 127;

    -- Update tracking stats
    UPDATE dune.bot_active_playtime 
    SET 
      last_login_date = v_today, 
      consecutive_days = v_streak,
      weekly_login_mask = v_mask
    WHERE character_id = p_pawn_id;

    -- Roll and Deliver Daily Reward if enabled
    IF v_daily_enabled THEN
      v_multiplier := 1.0 + ((v_streak - 1) * v_daily_step);
      PERFORM dune.fn_queue_reward_roll(p_account_id, v_tier, v_multiplier, 'daily');
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

      -- Check if target is met and we haven't already claimed weekly attendance in the past 6 days
      IF v_weekly_days_count >= v_weekly_req AND 
         (v_track.last_weekly_claimed_at IS NULL OR v_track.last_weekly_claimed_at < NOW() - INTERVAL '6 days') THEN
        
        PERFORM dune.fn_queue_reward_roll(p_account_id, v_tier, v_weekly_scale, 'weekly');
        
        UPDATE dune.bot_active_playtime 
        SET last_weekly_claimed_at = NOW() 
        WHERE character_id = p_pawn_id;
      END IF;
    END IF;

  END IF;
END;
$$ LANGUAGE plpgsql;

-- 9. Trigger handler running on player updates
CREATE OR REPLACE FUNCTION dune.trg_track_playtime()
RETURNS TRIGGER AS $$
DECLARE
  v_delta_seconds INT;
  v_prev_active TIMESTAMP WITH TIME ZONE;
  v_config JSONB;
  
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

  v_online TEXT;
  v_account_id BIGINT;
BEGIN
  -- Wrap trigger execution inside a safety block
  BEGIN
    SELECT online_status, account_id INTO v_online, v_account_id 
    FROM dune.player_state 
    WHERE player_pawn_id = NEW.id 
    LIMIT 1;

    -- Only track if player's online status is 'online' or 'true'
    IF v_online IS NOT NULL AND (LOWER(v_online) = 'online' OR LOWER(v_online) = 'true') THEN
      -- Load configurations
      SELECT config_value INTO v_config FROM dune.airdrop_addon_config WHERE config_key = 'airdrop_multipliers';
      IF v_config IS NOT NULL THEN
        -- If background daemon is enabled, bypass database playtime trigger updates to avoid timing overlaps
        IF COALESCE((v_config->>'use_daemon')::boolean, FALSE) = TRUE THEN
          -- Exit early but still run daily/weekly claim checks
          PERFORM dune.fn_check_daily_weekly_rewards(v_account_id, NEW.id);
          -- Force deliver check
          PERFORM dune.fn_deliver_playtime_airdrops(v_account_id, NEW.id);
          RETURN NEW;
        END IF;

        v_playtime_enabled := COALESCE((v_config->>'playtime_enabled')::boolean, TRUE);
        v_interval_min := COALESCE((v_config->>'playtime_interval')::int, 60);
        v_min_dist := COALESCE((v_config->>'playtime_distance')::double precision, 0.0);
        v_min_xp := COALESCE((v_config->>'playtime_xp')::int, 0);
      END IF;
      IF v_interval_min < 1 THEN v_interval_min := 60; END IF;

      -- Handle daily/weekly login claims instantly on online save
      PERFORM dune.fn_check_daily_weekly_rewards(v_account_id, NEW.id);

      -- Fetch current XP
      SELECT 
        COALESCE((fe.components->'FLevelComponent'->1->>'TotalXPEarned')::bigint, 0)
      INTO v_curr_xp
      FROM dune.actor_fgl_entities afe
      LEFT JOIN dune.fgl_entities fe ON fe.entity_id = afe.entity_id
      WHERE afe.actor_id = NEW.id::bigint AND afe.slot_name = 'DuneCharacter'
      LIMIT 1;

      -- Extract translation coordinates safely from transform array
      IF NEW.transform IS NOT NULL THEN
        v_x := (NEW.transform[1])::double precision;
        v_y := (NEW.transform[2])::double precision;
        v_z := (NEW.transform[3])::double precision;
      END IF;

      -- Get previous active status
      SELECT * INTO v_track 
      FROM dune.bot_active_playtime 
      WHERE character_id = NEW.id;
    
      IF v_track.character_id IS NOT NULL THEN
        -- Calculate seconds passed since last save/update
        v_delta_seconds := EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - v_track.last_active_at))::INT;

        -- Cap delta seconds to a maximum of 60 seconds per check to prevent abnormal offline time-jumps
        IF v_delta_seconds > 0 THEN
          v_delta_seconds := LEAST(60, v_delta_seconds);
          
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
              PERFORM dune.fn_roll_playtime_reward(v_account_id, NEW.id);
              v_accumulated_seconds := 0;
            END IF;
            
            UPDATE dune.bot_active_playtime 
            SET 
              active_seconds = v_accumulated_seconds,
              last_xp = v_curr_xp,
              last_x = v_x,
              last_y = v_y,
              last_z = v_z,
              last_active_at = CURRENT_TIMESTAMP
            WHERE character_id = NEW.id;
          ELSE
            -- Idle player, update timestamp but do not count active seconds
            UPDATE dune.bot_active_playtime 
            SET last_active_at = CURRENT_TIMESTAMP 
            WHERE character_id = NEW.id;
          END IF;
        END IF;
      ELSE
        -- Initialize playtime record for new character, backdating last_active_at by 5 seconds to jumpstart tracking delta
        INSERT INTO dune.bot_active_playtime (character_id, active_seconds, last_xp, last_x, last_y, last_z, last_active_at)
        VALUES (NEW.id, 0, v_curr_xp, v_x, v_y, v_z, CURRENT_TIMESTAMP - INTERVAL '5 seconds');
      END IF;
    ELSE
      -- Player went offline, invalidate active timestamp to prevent counting while offline
      UPDATE dune.bot_active_playtime 
      SET last_active_at = NULL 
      WHERE character_id = NEW.id;
    END IF;
    
    -- Force direct delivery run on save to catch any lingering drops
    IF v_online IS NOT NULL AND (LOWER(v_online) = 'online' OR LOWER(v_online) = 'true') THEN
      PERFORM dune.fn_deliver_playtime_airdrops(v_account_id, NEW.id);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Prevent trigger errors from crashing base actor updates (which crashes game server runtime partitions)
    RAISE WARNING 'Dune Airdrop tracking trigger error: %', SQLERRM;
  END;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 10. Install the trigger on any actors table updates instead of of transform updates only
DROP TRIGGER IF EXISTS trg_player_state_playtime ON dune.actors;
CREATE TRIGGER trg_player_state_playtime
AFTER UPDATE ON dune.actors
FOR EACH ROW
EXECUTE FUNCTION dune.trg_track_playtime();

-- Initial diagnostics print
SELECT 'Arrakis Playtime Airdrop database trigger configured successfully!' AS status;
