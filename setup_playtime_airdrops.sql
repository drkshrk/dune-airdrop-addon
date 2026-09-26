-- ============================================================================
-- Airdrop Manager (dune-airdrop-addon) - database setup and migration, schema v2
-- ============================================================================
--
-- How every object created here is identified as belonging to this addon:
--   1. Namespace: everything lives in schema dune_airdrop (archived legacy
--      tables in dune_airdrop_legacy). The single object outside those schemas
--      is the trigger dune_airdrop_track_playtime on dune.encrypted_player_state.
--   2. Name prefix: every table, view, function, constraint and index starts
--      with airdrop_; the game-table trigger starts with dune_airdrop_.
--   3. Marker: every object carries COMMENT 'dune-airdrop-addon|v2|<purpose>'.
--      List them all with:
--        SELECT classid::regclass, objid, description FROM pg_description
--         WHERE description LIKE 'dune-airdrop-addon|%';
--
-- This script never alters, inserts into, updates or deletes from a game table.
-- It only reads legacy addon tables, and it removes legacy addon code objects
-- only after checking they are provably this addon's (exact signature plus a
-- body fingerprint, and never with CASCADE in the dune schema).
--
-- Run it from the Airdrop Manager page (INIT SCHEMA) or manually as a single
-- transaction:
--   docker exec -i dune-postgres psql -U postgres -d dune -1 -v ON_ERROR_STOP=1 < setup_playtime_airdrops.sql
-- Do not add BEGIN/COMMIT: the console runs this as one implicit transaction.
-- ============================================================================

SET LOCAL lock_timeout = '5s';
SET LOCAL client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS dune_airdrop AUTHORIZATION dune;

-- ---------------------------------------------------------------------------
-- 0. Preflight: refuse while the retired delivery daemon is still running.
-- ---------------------------------------------------------------------------
DO $preflight$
DECLARE
  v_source TEXT;
  v_ping TIMESTAMPTZ;
BEGIN
  FOREACH v_source IN ARRAY ARRAY['dune_airdrop.config', 'dune.airdrop_config', 'dune.discord_bot_config'] LOOP
    IF to_regclass(v_source) IS NOT NULL THEN
      BEGIN
        EXECUTE format('SELECT (config_value->>%L)::timestamptz FROM %s WHERE config_key = %L',
                       'last_ping', v_source, 'daemon_heartbeat')
          INTO v_ping;
      EXCEPTION WHEN OTHERS THEN
        v_ping := NULL;
      END;
      IF v_ping IS NOT NULL AND v_ping > now() - interval '2 minutes' THEN
        RAISE EXCEPTION '[dune-airdrop-addon] The retired airdrop delivery daemon is still running (last heartbeat % in %). Stop it first with: docker rm -f airdrop-daemon', v_ping, v_source;
      END IF;
    END IF;
  END LOOP;
END
$preflight$;

-- ---------------------------------------------------------------------------
-- 1. Schema v2 tables
-- ---------------------------------------------------------------------------
-- New objects are always created as dune. Steps 2-4 run as the session user
-- instead, because releases before 1.3.7 were installed as postgres and a
-- dune session cannot read or move what postgres owns; those cases are
-- logged as manual steps rather than aborting.
SET LOCAL ROLE dune;
CREATE TABLE IF NOT EXISTS dune_airdrop.airdrop_schema_version (
  version INT NOT NULL,
  addon_version TEXT NOT NULL,
  installed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  upgraded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT airdrop_schema_version_pkey PRIMARY KEY (version),
  CONSTRAINT airdrop_schema_version_positive CHECK (version > 0)
);

CREATE TABLE IF NOT EXISTS dune_airdrop.airdrop_migration_log (
  id BIGSERIAL,
  step TEXT NOT NULL,
  level TEXT NOT NULL,
  detail TEXT NOT NULL,
  at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT airdrop_migration_log_pkey PRIMARY KEY (id),
  CONSTRAINT airdrop_migration_log_level CHECK (level IN ('info', 'warn', 'manual'))
);

CREATE TABLE IF NOT EXISTS dune_airdrop.airdrop_config (
  config_key TEXT NOT NULL,
  config_value JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT airdrop_config_pkey PRIMARY KEY (config_key),
  CONSTRAINT airdrop_config_known_key CHECK (config_key IN ('airdrop_multipliers', 'airdrop_economy'))
);

CREATE TABLE IF NOT EXISTS dune_airdrop.airdrop_player_progress (
  character_id BIGINT NOT NULL,
  account_id BIGINT,
  active_seconds INT NOT NULL DEFAULT 0,
  last_xp BIGINT NOT NULL DEFAULT 0,
  last_x DOUBLE PRECISION NOT NULL DEFAULT 0,
  last_y DOUBLE PRECISION NOT NULL DEFAULT 0,
  last_z DOUBLE PRECISION NOT NULL DEFAULT 0,
  last_active_at TIMESTAMPTZ DEFAULT now(),
  last_login_date DATE,
  consecutive_days INT NOT NULL DEFAULT 0,
  weekly_login_mask INT NOT NULL DEFAULT 0,
  current_week_id INT NOT NULL DEFAULT 0,
  last_weekly_claimed_at TIMESTAMPTZ,
  CONSTRAINT airdrop_player_progress_pkey PRIMARY KEY (character_id)
);

CREATE TABLE IF NOT EXISTS dune_airdrop.airdrop_loot_table (
  tier INT NOT NULL,
  category TEXT NOT NULL,
  template_id TEXT NOT NULL,
  weight INT NOT NULL,
  CONSTRAINT airdrop_loot_table_key UNIQUE (tier, category, template_id),
  CONSTRAINT airdrop_loot_table_tier CHECK (tier BETWEEN 0 AND 6),
  CONSTRAINT airdrop_loot_table_category CHECK (category IN ('gear', 'raw_resources', 'crafted_components', 'schematics')),
  CONSTRAINT airdrop_loot_table_weight CHECK (weight > 0)
);

-- The stack_size and quality limits match the console's rewards.deliver
-- validation, so a row the console would reject can never be queued.
CREATE TABLE IF NOT EXISTS dune_airdrop.airdrop_reward_queue (
  id BIGSERIAL,
  request_id UUID NOT NULL DEFAULT gen_random_uuid(),
  account_id BIGINT NOT NULL,
  template_id TEXT NOT NULL,
  stack_size INT NOT NULL,
  quality_level INT NOT NULL DEFAULT 0,
  state TEXT NOT NULL DEFAULT 'queued',
  source TEXT NOT NULL,
  legacy_ref TEXT,
  note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  state_changed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT airdrop_reward_queue_pkey PRIMARY KEY (id),
  CONSTRAINT airdrop_reward_queue_request_id_key UNIQUE (request_id),
  CONSTRAINT airdrop_reward_queue_legacy_ref_key UNIQUE (legacy_ref),
  CONSTRAINT airdrop_reward_queue_stack_size CHECK (stack_size BETWEEN 1 AND 1000),
  CONSTRAINT airdrop_reward_queue_quality CHECK (quality_level BETWEEN 0 AND 5),
  CONSTRAINT airdrop_reward_queue_state CHECK (state IN ('queued', 'held', 'review', 'discarded', 'legacy_done')),
  CONSTRAINT airdrop_reward_queue_source CHECK (source IN ('playtime', 'daily', 'weekly', 'legacy')),
  CONSTRAINT airdrop_reward_queue_template_id CHECK (template_id ~ '^[A-Za-z0-9_./:-]{1,240}$')
);
CREATE INDEX IF NOT EXISTS airdrop_reward_queue_outbox_idx
  ON dune_airdrop.airdrop_reward_queue (id) WHERE state = 'queued';
CREATE INDEX IF NOT EXISTS airdrop_reward_queue_account_idx
  ON dune_airdrop.airdrop_reward_queue (account_id);
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 2. Import from every earlier layout (idempotent, never auto-delivers)
-- ---------------------------------------------------------------------------
-- Sources are read newest-layout-first so a row copied forward by v1.3.7 wins
-- over its v1.3.6 original (same request_id). Imported rewards are never
-- 'queued': an operator releases or discards them from the Airdrop page.
DO $import_rewards$
DECLARE
  v_src RECORD;
  v_cols TEXT[];
  v_rcols TEXT[];
  v_has_receipts BOOLEAN;
  v_request_expr TEXT;
  v_receipt_status TEXT;
  v_lease_expr TEXT;
  v_failure_expr TEXT;
  v_quality_expr TEXT;
  v_created_expr TEXT;
  v_count BIGINT;
BEGIN
  FOR v_src IN
    SELECT * FROM (VALUES
      (1, 'dune_airdrop', 'pending_deliveries', 'dune_airdrop', 'delivery_receipts'),
      (2, 'dune', 'airdrop_pending_deliveries', 'dune', 'airdrop_delivery_receipts'),
      (3, 'dune', 'bot_pending_deliveries', 'dune', 'bot_delivery_receipts')
    ) AS s(ord, sch, tbl, rsch, rtbl)
    ORDER BY ord
  LOOP
    CONTINUE WHEN to_regclass(format('%I.%I', v_src.sch, v_src.tbl)) IS NULL;

    SELECT COALESCE(array_agg(a.attname::text), ARRAY[]::TEXT[]) INTO v_cols
      FROM pg_attribute a
      WHERE a.attrelid = to_regclass(format('%I.%I', v_src.sch, v_src.tbl)) AND a.attnum > 0 AND NOT a.attisdropped;

    IF NOT (v_cols @> ARRAY['id', 'account_id', 'template_id', 'stack_size', 'is_applied']) THEN
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('import-rewards', 'warn', format('%I.%I skipped: column set does not match any airdrop layout', v_src.sch, v_src.tbl));
      CONTINUE;
    END IF;

    v_has_receipts := 'request_id' = ANY (v_cols)
                      AND to_regclass(format('%I.%I', v_src.rsch, v_src.rtbl)) IS NOT NULL;
    v_rcols := ARRAY[]::TEXT[];
    IF v_has_receipts THEN
      SELECT COALESCE(array_agg(a.attname::text), ARRAY[]::TEXT[]) INTO v_rcols
        FROM pg_attribute a
        WHERE a.attrelid = to_regclass(format('%I.%I', v_src.rsch, v_src.rtbl)) AND a.attnum > 0 AND NOT a.attisdropped;
      v_has_receipts := 'request_id' = ANY (v_rcols);
    END IF;

    v_request_expr := CASE WHEN 'request_id' = ANY (v_cols) THEN 'p.request_id' ELSE 'NULL::uuid' END;
    -- v1.3.4 receipts had no status column; a receipt row then meant success.
    v_receipt_status := CASE
      WHEN NOT v_has_receipts THEN 'NULL::text'
      WHEN 'status' = ANY (v_rcols) THEN 'upper(r.status)'
      ELSE 'CASE WHEN r.request_id IS NOT NULL THEN ''SUCCESS'' END'
    END;
    v_lease_expr := concat_ws(' OR ',
      CASE WHEN 'locked_at' = ANY (v_cols) THEN 'p.locked_at IS NOT NULL' END,
      CASE WHEN 'lease_token' = ANY (v_cols) THEN 'p.lease_token IS NOT NULL' END);
    IF v_lease_expr = '' THEN v_lease_expr := 'false'; END IF;
    v_failure_expr := CASE WHEN 'last_failure_code' = ANY (v_cols)
      THEN 'COALESCE(p.last_failure_code, '''') IN (''TIMEOUT'', ''INTERRUPTED'', ''UNKNOWN_OUTPUT'', ''VERIFICATION_FAILED'', ''COMMAND_ERROR'', ''ABANDONED_PENDING'', ''UNCERTAIN'')'
      ELSE 'false' END;
    v_quality_expr := CASE WHEN 'quality_level' = ANY (v_cols) THEN 'COALESCE(p.quality_level, 0)' ELSE '0' END;
    v_created_expr := CASE WHEN 'created_at' = ANY (v_cols) THEN 'COALESCE(p.created_at::timestamptz, now())' ELSE 'now()' END;

    BEGIN
    EXECUTE format($sql$
      INSERT INTO dune_airdrop.airdrop_reward_queue
        (request_id, account_id, template_id, stack_size, quality_level, state, source, legacy_ref, note, created_at, state_changed_at)
      SELECT COALESCE(%1$s, gen_random_uuid()),
             p.account_id::bigint,
             p.template_id,
             LEAST(1000, GREATEST(1, p.stack_size)),
             LEAST(5, GREATEST(0, %2$s)),
             CASE
               WHEN %3$s IN ('SUCCESS', 'FAILED') THEN 'legacy_done'
               WHEN %3$s IN ('PENDING', 'UNCERTAIN') THEN 'review'
               WHEN COALESCE(p.is_applied, false) THEN 'legacy_done'
               WHEN %4$s THEN 'review'
               WHEN %5$s THEN 'review'
               ELSE 'held'
             END,
             'legacy',
             %6$L || '#' || p.id,
             concat_ws('; ',
               'imported from ' || %6$L,
               CASE WHEN %3$s IS NOT NULL THEN 'receipt ' || %3$s END,
               CASE WHEN p.stack_size > 1000 THEN 'stack clamped from ' || p.stack_size END),
             %7$s,
             now()
        FROM %8$s p
        %9$s
       WHERE p.account_id IS NOT NULL
         AND p.template_id ~ '^[A-Za-z0-9_./:-]{1,240}$'
      ON CONFLICT DO NOTHING
    $sql$,
      v_request_expr,
      v_quality_expr,
      v_receipt_status,
      v_lease_expr,
      v_failure_expr,
      format('%s.%s', v_src.sch, v_src.tbl),
      v_created_expr,
      format('%I.%I', v_src.sch, v_src.tbl),
      CASE WHEN v_has_receipts
        THEN format('LEFT JOIN %I.%I r ON r.request_id = p.request_id', v_src.rsch, v_src.rtbl)
        ELSE '' END);
    GET DIAGNOSTICS v_count = ROW_COUNT;

    INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
    VALUES ('import-rewards', 'info', format('%s rows imported from %I.%I', v_count, v_src.sch, v_src.tbl));
    EXCEPTION WHEN insufficient_privilege THEN
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('import-rewards', 'manual', format('%I.%I is owned by another role; re-run setup as postgres to import it: docker exec -i dune-postgres psql -U postgres -d dune -1 -v ON_ERROR_STOP=1 < setup_playtime_airdrops.sql', v_src.sch, v_src.tbl));
    END;
  END LOOP;
END
$import_rewards$;

DO $import_progress$
DECLARE
  v_src RECORD;
  v_cols TEXT[];
  v_week_expr TEXT;
  v_mask_expr TEXT;
  v_login_expr TEXT;
  v_count BIGINT;
BEGIN
  FOR v_src IN
    SELECT * FROM (VALUES
      (1, 'dune_airdrop', 'active_playtime'),
      (2, 'dune', 'airdrop_active_playtime'),
      (3, 'dune', 'bot_active_playtime')
    ) AS s(ord, sch, tbl)
    ORDER BY ord
  LOOP
    CONTINUE WHEN to_regclass(format('%I.%I', v_src.sch, v_src.tbl)) IS NULL;

    SELECT COALESCE(array_agg(a.attname::text), ARRAY[]::TEXT[]) INTO v_cols
      FROM pg_attribute a
      WHERE a.attrelid = to_regclass(format('%I.%I', v_src.sch, v_src.tbl)) AND a.attnum > 0 AND NOT a.attisdropped;

    IF NOT (v_cols @> ARRAY['character_id', 'active_seconds', 'last_active_at']) THEN
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('import-progress', 'warn', format('%I.%I skipped: column set does not match any airdrop layout', v_src.sch, v_src.tbl));
      CONTINUE;
    END IF;

    -- Before v1.1.0 weekly_login_mask was a rolling 7-day register rather
    -- than a Coriolis-week bitmask; without current_week_id it cannot be
    -- interpreted, so those players restart their week.
    IF 'current_week_id' = ANY (v_cols) THEN
      v_week_expr := 'COALESCE(p.current_week_id, 0)';
      v_mask_expr := 'COALESCE(p.weekly_login_mask, 0) & 127';
    ELSE
      v_week_expr := '0';
      v_mask_expr := '0';
    END IF;
    v_login_expr := CASE WHEN 'last_login_date' = ANY (v_cols) THEN 'p.last_login_date' ELSE 'NULL::date' END;

    BEGIN
    EXECUTE format($sql$
      INSERT INTO dune_airdrop.airdrop_player_progress AS t
        (character_id, active_seconds, last_xp, last_x, last_y, last_z, last_active_at,
         last_login_date, consecutive_days, weekly_login_mask, current_week_id, last_weekly_claimed_at)
      SELECT DISTINCT ON (p.character_id::text::bigint)
             p.character_id::text::bigint,
             GREATEST(0, COALESCE(p.active_seconds, 0)),
             %1$s, %2$s, %3$s, %4$s,
             p.last_active_at::timestamptz,
             %5$s, %6$s, %7$s, %8$s, %9$s
        FROM %10$s p
       WHERE p.character_id::text ~ '^[0-9]{1,18}$'
       ORDER BY p.character_id::text::bigint,
                GREATEST(COALESCE(p.last_active_at::timestamptz, '-infinity'),
                         COALESCE((%5$s)::timestamptz, '-infinity')) DESC
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
        last_weekly_claimed_at = EXCLUDED.last_weekly_claimed_at
      WHERE GREATEST(COALESCE(EXCLUDED.last_active_at, '-infinity'), COALESCE(EXCLUDED.last_login_date::timestamptz, '-infinity'))
          > GREATEST(COALESCE(t.last_active_at, '-infinity'), COALESCE(t.last_login_date::timestamptz, '-infinity'))
    $sql$,
      CASE WHEN 'last_xp' = ANY (v_cols) THEN 'GREATEST(0, COALESCE(p.last_xp, 0))' ELSE '0' END,
      CASE WHEN 'last_x' = ANY (v_cols) THEN 'COALESCE(p.last_x, 0)' ELSE '0' END,
      CASE WHEN 'last_y' = ANY (v_cols) THEN 'COALESCE(p.last_y, 0)' ELSE '0' END,
      CASE WHEN 'last_z' = ANY (v_cols) THEN 'COALESCE(p.last_z, 0)' ELSE '0' END,
      v_login_expr,
      CASE WHEN 'consecutive_days' = ANY (v_cols) THEN 'GREATEST(0, COALESCE(p.consecutive_days, 0))' ELSE '0' END,
      v_mask_expr,
      v_week_expr,
      CASE WHEN 'last_weekly_claimed_at' = ANY (v_cols) THEN 'p.last_weekly_claimed_at::timestamptz' ELSE 'NULL::timestamptz' END,
      format('%I.%I', v_src.sch, v_src.tbl));
    GET DIAGNOSTICS v_count = ROW_COUNT;

    INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
    VALUES ('import-progress', 'info', format('%s player rows imported or refreshed from %I.%I', v_count, v_src.sch, v_src.tbl));
    EXCEPTION WHEN insufficient_privilege THEN
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('import-progress', 'manual', format('%I.%I is owned by another role; re-run setup as postgres to import it: docker exec -i dune-postgres psql -U postgres -d dune -1 -v ON_ERROR_STOP=1 < setup_playtime_airdrops.sql', v_src.sch, v_src.tbl));
    END;
  END LOOP;
END
$import_progress$;

-- Settings: the first layout holding a key wins (the current v2 table first),
-- then everything is normalised onto the current defaults below.
DO $import_config$
DECLARE
  v_source TEXT;
  v_count BIGINT;
BEGIN
  FOREACH v_source IN ARRAY ARRAY['dune_airdrop.config', 'dune.airdrop_config', 'dune.discord_bot_config', 'dune.airdrop_addon_config'] LOOP
    CONTINUE WHEN to_regclass(v_source) IS NULL;
    BEGIN
      EXECUTE format($sql$
        INSERT INTO dune_airdrop.airdrop_config (config_key, config_value)
        SELECT config_key, config_value
          FROM %s
         WHERE config_key IN ('airdrop_multipliers', 'airdrop_economy')
           AND jsonb_typeof(config_value) = 'object'
        ON CONFLICT (config_key) DO NOTHING
      $sql$, v_source);
      GET DIAGNOSTICS v_count = ROW_COUNT;
      IF v_count > 0 THEN
        INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
        VALUES ('import-config', 'info', format('%s settings keys imported from %s', v_count, v_source));
      END IF;
    EXCEPTION
      WHEN undefined_column OR datatype_mismatch OR undefined_function THEN
        INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
        VALUES ('import-config', 'warn', format('%s skipped: unexpected column layout', v_source));
      WHEN insufficient_privilege THEN
        INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
        VALUES ('import-config', 'manual', format('%s is owned by another role; re-run setup as postgres to import it: docker exec -i dune-postgres psql -U postgres -d dune -1 -v ON_ERROR_STOP=1 < setup_playtime_airdrops.sql', v_source));
    END;
  END LOOP;
END
$import_config$;

-- Keep only known settings, with the type of the default (numeric strings
-- saved by older UIs are accepted); retired daemon-era keys are dropped.
WITH defaults(config_key, config_value) AS (
  VALUES
  ('airdrop_multipliers', '{
     "playtime_enabled": true, "playtime_interval": 60, "playtime_distance": 10.0, "playtime_xp": 1,
     "playtime_multiplier_t0": 1, "playtime_multiplier_t1": 1, "playtime_multiplier_t2": 1,
     "playtime_multiplier_t3": 1, "playtime_multiplier_t4": 1, "playtime_multiplier_t5": 1,
     "playtime_multiplier_t6": 1,
     "daily_enabled": true, "daily_multiplier_step": 0.5, "daily_max_streak": 7,
     "weekly_enabled": true, "weekly_days_required": 5, "weekly_multiplier": 5.0
   }'::jsonb),
  ('airdrop_economy', '{
     "prob_gear": 0.40, "prob_schem": 0.80, "prob_raw": 1.0, "prob_craft": 1.0, "min_items": 1,
     "tier_0_min": 5, "tier_0_max": 10, "tier_1_min": 5, "tier_1_max": 15,
     "tier_2_min": 10, "tier_2_max": 25, "tier_3_min": 15, "tier_3_max": 35,
     "tier_4_min": 20, "tier_4_max": 50, "tier_5_min": 30, "tier_5_max": 75,
     "tier_6_min": 50, "tier_6_max": 100
   }'::jsonb)
),
merged AS (
  SELECT d.config_key,
         (SELECT jsonb_object_agg(dk.key,
                   CASE
                     WHEN s.config_value ? dk.key AND jsonb_typeof(s.config_value->dk.key) = jsonb_typeof(dk.value)
                       THEN s.config_value->dk.key
                     WHEN jsonb_typeof(dk.value) = 'number' AND jsonb_typeof(s.config_value->dk.key) = 'string'
                          AND (s.config_value->>dk.key) ~ '^-?[0-9]+(\.[0-9]+)?$'
                       THEN to_jsonb((s.config_value->>dk.key)::numeric)
                     WHEN jsonb_typeof(dk.value) = 'boolean' AND jsonb_typeof(s.config_value->dk.key) = 'string'
                          AND lower(s.config_value->>dk.key) IN ('true', 'false')
                       THEN to_jsonb(lower(s.config_value->>dk.key) = 'true')
                     ELSE dk.value
                   END)
            FROM jsonb_each(d.config_value) dk) AS config_value
    FROM defaults d
    LEFT JOIN dune_airdrop.airdrop_config s ON s.config_key = d.config_key
)
INSERT INTO dune_airdrop.airdrop_config AS c (config_key, config_value, updated_at)
SELECT config_key, config_value, now() FROM merged
ON CONFLICT (config_key) DO UPDATE
  SET config_value = EXCLUDED.config_value,
      updated_at = CASE WHEN c.config_value IS DISTINCT FROM EXCLUDED.config_value THEN now() ELSE c.updated_at END;

-- ---------------------------------------------------------------------------
-- 3. Remove legacy code objects, provably ours only
-- ---------------------------------------------------------------------------
-- A function is dropped only when (a) its exact signature is one this addon
-- shipped, (b) its body references airdrop tables, and (c) nothing but a
-- trigger removed here depends on it. A trigger is dropped only when it
-- executes one of those functions. Nothing is dropped with CASCADE.
DO $legacy_code$
DECLARE
  v_candidate RECORD;
  v_fn REGPROCEDURE;
  v_fn_oids OID[] := ARRAY[]::OID[];
  v_oid OID;
  v_name TEXT;
  v_trg RECORD;
  -- Each shipped signature with a fingerprint of this addon's own code: the
  -- tier helper only reads game tables, so it is matched on its variable
  -- names; every other function references the addon's tables or channel.
  v_tables_fp CONSTANT TEXT := '(bot_active_playtime|bot_pending_deliveries|airdrop|discord_bot_config|loot_tables|active_playtime|pending_deliveries)';
  v_tier_fp CONSTANT TEXT := '(v_keystone_points|v_xp_text)';
BEGIN
  FOR v_candidate IN
    SELECT sig, CASE WHEN sig LIKE '%pawn_tier%' THEN v_tier_fp ELSE v_tables_fp END AS fingerprint
      FROM unnest(ARRAY[
        'dune.trg_track_playtime()',
        'dune.trg_track_playtime_v2()',
        'dune.trg_notify_pending_delivery()',
        'dune.trg_notify_pending_delivery_v2()',
        'dune.fn_get_pawn_tier(text)',
        'dune.fn_get_pawn_tier(bigint)',
        'dune.fn_get_pawn_tier_v2(bigint)',
        'dune.fn_queue_reward_roll(bigint,integer,numeric,text)',
        'dune.fn_queue_reward_roll_v2(bigint,integer,numeric,text)',
        'dune.fn_roll_playtime_reward(bigint,text)',
        'dune.fn_roll_playtime_reward(bigint,bigint)',
        'dune.fn_roll_playtime_reward_v2(bigint,bigint)',
        'dune.fn_deliver_playtime_airdrops(bigint,text)',
        'dune.fn_deliver_playtime_airdrops(bigint,bigint)',
        'dune.fn_deliver_playtime_airdrops_v2(bigint,bigint)',
        'dune.fn_check_daily_weekly_rewards(bigint,text)',
        'dune.fn_check_daily_weekly_rewards(bigint,bigint)',
        'dune.fn_check_daily_weekly_rewards_v2(bigint,bigint)',
        'dune.fn_manual_airdrop_spawn(bigint,text,integer)',
        'dune_airdrop.trg_track_playtime_v2()',
        'dune_airdrop.trg_notify_pending_delivery_v2()',
        'dune_airdrop.fn_get_pawn_tier_v2(bigint)',
        'dune_airdrop.fn_queue_reward_roll_v2(bigint,integer,numeric,text)',
        'dune_airdrop.fn_roll_playtime_reward_v2(bigint,bigint)',
        'dune_airdrop.fn_deliver_playtime_airdrops_v2(bigint,bigint)',
        'dune_airdrop.fn_check_daily_weekly_rewards_v2(bigint,bigint)',
        'dune_airdrop.fn_manual_airdrop_spawn(bigint,text,integer)'
      ]) AS sig
  LOOP
    v_fn := to_regprocedure(v_candidate.sig);
    CONTINUE WHEN v_fn IS NULL;
    IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_fn AND p.prosrc ~* v_candidate.fingerprint) THEN
      v_fn_oids := v_fn_oids || v_fn::oid;
    ELSE
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('remove-legacy-code', 'warn', format('%s left untouched: its body does not match the airdrop fingerprint, so it may not be ours', v_candidate.sig));
    END IF;
  END LOOP;

  -- Triggers first: only ones that execute a proven airdrop function.
  FOR v_trg IN
    SELECT t.tgname, n.nspname AS sch, c.relname AS tbl
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE NOT t.tgisinternal
       AND t.tgfoid = ANY (v_fn_oids)
  LOOP
    BEGIN
      EXECUTE format('DROP TRIGGER %I ON %I.%I', v_trg.tgname, v_trg.sch, v_trg.tbl);
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('remove-legacy-code', 'info', format('dropped legacy trigger %s on %I.%I', v_trg.tgname, v_trg.sch, v_trg.tbl));
    EXCEPTION WHEN insufficient_privilege THEN
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('remove-legacy-code', 'manual', format('owned by another role; run as postgres: DROP TRIGGER %I ON %I.%I;', v_trg.tgname, v_trg.sch, v_trg.tbl));
    END;
  END LOOP;

  -- Then the functions, unless something unexpected still depends on them.
  FOREACH v_oid IN ARRAY v_fn_oids LOOP
    v_name := v_oid::regprocedure::text;
    IF EXISTS (SELECT 1 FROM pg_depend d
                WHERE d.refclassid = 'pg_proc'::regclass AND d.refobjid = v_oid AND d.deptype = 'n') THEN
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('remove-legacy-code', 'warn', format('%s kept: another object still depends on it', v_name));
      CONTINUE;
    END IF;
    BEGIN
      EXECUTE format('DROP FUNCTION %s', v_name);
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('remove-legacy-code', 'info', format('dropped legacy function %s', v_name));
    EXCEPTION WHEN insufficient_privilege THEN
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('remove-legacy-code', 'manual', format('owned by another role; run as postgres: DROP FUNCTION %s;', v_name));
    END;
  END LOOP;
END
$legacy_code$;

-- ---------------------------------------------------------------------------
-- 4. Archive legacy addon tables (moved, never dropped)
-- ---------------------------------------------------------------------------
-- Only tables that exist solely because of this addon are moved. The
-- dune.bot_active_playtime, dune.bot_pending_deliveries and
-- dune.discord_bot_config names pre-date the addon (an earlier Discord bot),
-- so they are left exactly as they are and only reported.
DO $archive$
DECLARE
  v_src RECORD;
  v_cols TEXT[];
  v_target TEXT;
BEGIN
  FOR v_src IN
    SELECT * FROM (VALUES
      ('dune_airdrop', 'active_playtime', ARRAY['character_id', 'active_seconds']),
      ('dune_airdrop', 'pending_deliveries', ARRAY['id', 'account_id', 'template_id', 'stack_size']),
      ('dune_airdrop', 'delivery_receipts', ARRAY['request_id']),
      ('dune_airdrop', 'config', ARRAY['config_key', 'config_value']),
      ('dune_airdrop', 'loot_tables', ARRAY['tier', 'category', 'template_id', 'weight']),
      ('dune', 'airdrop_active_playtime', ARRAY['character_id', 'active_seconds']),
      ('dune', 'airdrop_pending_deliveries', ARRAY['id', 'account_id', 'template_id', 'stack_size']),
      ('dune', 'airdrop_delivery_receipts', ARRAY['request_id']),
      ('dune', 'airdrop_config', ARRAY['config_key', 'config_value']),
      ('dune', 'airdrop_loot_tables', ARRAY['tier', 'category', 'template_id', 'weight']),
      ('dune', 'airdrop_addon_config', ARRAY['config_key', 'config_value']),
      ('dune', 'bot_delivery_receipts', ARRAY['request_id', 'status'])
    ) AS s(sch, tbl, required_cols)
  LOOP
    CONTINUE WHEN to_regclass(format('%I.%I', v_src.sch, v_src.tbl)) IS NULL;

    SELECT COALESCE(array_agg(a.attname::text), ARRAY[]::TEXT[]) INTO v_cols
      FROM pg_attribute a
      WHERE a.attrelid = to_regclass(format('%I.%I', v_src.sch, v_src.tbl)) AND a.attnum > 0 AND NOT a.attisdropped;
    IF NOT (v_cols @> v_src.required_cols) THEN
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('archive-legacy', 'warn', format('%I.%I left in place: column set does not match any airdrop layout', v_src.sch, v_src.tbl));
      CONTINUE;
    END IF;

    BEGIN
      CREATE SCHEMA IF NOT EXISTS dune_airdrop_legacy AUTHORIZATION dune;
      COMMENT ON SCHEMA dune_airdrop_legacy IS 'dune-airdrop-addon|v2|legacy-archive: tables from earlier Airdrop Manager versions, kept for reference; removed by uninstall';

      -- Name archived tables after their origin so layouts never collide.
      v_target := left(format('airdrop_legacy_%s_%s', v_src.sch, v_src.tbl), 63);
      IF to_regclass(format('dune_airdrop_legacy.%I', v_target)) IS NOT NULL THEN
        v_target := left(v_target, 48) || '_' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISS');
      END IF;
      EXECUTE format('ALTER TABLE %I.%I RENAME TO %I', v_src.sch, v_src.tbl, v_target);
      EXECUTE format('ALTER TABLE %I.%I SET SCHEMA dune_airdrop_legacy', v_src.sch, v_target);
      EXECUTE format('COMMENT ON TABLE dune_airdrop_legacy.%I IS %L', v_target,
                     format('dune-airdrop-addon|v2|legacy-archive: formerly %s.%s', v_src.sch, v_src.tbl));
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('archive-legacy', 'info', format('moved %I.%I to dune_airdrop_legacy.%I', v_src.sch, v_src.tbl, v_target));
    EXCEPTION WHEN insufficient_privilege THEN
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('archive-legacy', 'manual', format('owned by another role; re-run setup as postgres to archive %I.%I', v_src.sch, v_src.tbl));
    END;
  END LOOP;

  FOR v_src IN
    SELECT * FROM (VALUES ('bot_active_playtime'), ('bot_pending_deliveries'), ('discord_bot_config')) AS s(tbl)
  LOOP
    IF to_regclass(format('dune.%I', v_src.tbl)) IS NOT NULL THEN
      INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
      VALUES ('archive-legacy', 'info', format('dune.%I left untouched: this name pre-dates the addon and may belong to another tool; its airdrop data has been imported and is no longer read', v_src.tbl));
    END IF;
  END LOOP;
END
$archive$;

-- ---------------------------------------------------------------------------
-- 5. Loot table (regenerated from scripts/admin-items.json)
-- ---------------------------------------------------------------------------
SET LOCAL ROLE dune;
-- [BEGIN AUTO-GENERATED LOOT POOLS]
-- ==========================================
-- AUTO-GENERATED BY generate_sql_loot.js
-- DO NOT EDIT THIS BLOCK MANUALLY
-- ==========================================

TRUNCATE dune_airdrop.airdrop_loot_table;

INSERT INTO dune_airdrop.airdrop_loot_table (tier, category, template_id, weight) VALUES
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

-- ---------------------------------------------------------------------------
-- 6. Functions (all SECURITY INVOKER with a pinned search_path)
-- ---------------------------------------------------------------------------
-- Tier from the character's total XP, using the same XP-per-level curve the
-- console uses to display player level (xpToLevel in console/api), so an
-- airdrop tier always matches the level an admin sees:
--   level 10 = 4190 XP, 20 = 10190, 50 = 28190, 80 = 46190, 120 = 71190, 150 = 93099.
CREATE OR REPLACE FUNCTION dune_airdrop.airdrop_pawn_tier(p_pawn_id BIGINT)
RETURNS INT
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
  v_xp_text TEXT;
  v_xp NUMERIC := 0;
BEGIN
  SELECT fe.components->'FLevelComponent'->1->>'TotalXPEarned'
    INTO v_xp_text
    FROM dune.actor_fgl_entities afe
    LEFT JOIN dune.fgl_entities fe ON fe.entity_id = afe.entity_id
   WHERE afe.actor_id = p_pawn_id AND afe.slot_name = 'DuneCharacter'
   LIMIT 1;

  IF v_xp_text ~ '^[0-9]{1,18}(\.[0-9]+)?$' THEN
    v_xp := v_xp_text::numeric;
  END IF;

  RETURN CASE
    WHEN v_xp >= 93099 THEN 6
    WHEN v_xp >= 71190 THEN 5
    WHEN v_xp >= 46190 THEN 4
    WHEN v_xp >= 28190 THEN 3
    WHEN v_xp >= 10190 THEN 2
    WHEN v_xp >= 4190 THEN 1
    ELSE 0
  END;
END
$fn$;

-- Rolls one reward pack per whole multiplier step (capped at 20) and queues
-- each item. Returns the number of queue rows written.
CREATE OR REPLACE FUNCTION dune_airdrop.airdrop_queue_roll(p_account_id BIGINT, p_tier INT, p_multiplier NUMERIC, p_source TEXT)
RETURNS INT
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
  v_econ JSONB;
  v_prob_gear NUMERIC := 0.40;
  v_prob_schem NUMERIC := 0.80;
  v_prob_raw NUMERIC := 1.0;
  v_prob_craft NUMERIC := 1.0;
  v_min_drops INT := 1;
  v_tier_min INT := 5;
  v_tier_max INT := 10;
  v_num_rolls INT;
  v_gear TEXT;
  v_raw TEXT;
  v_craft TEXT;
  v_schem TEXT;
  v_raw_qty INT;
  v_craft_qty INT;
  v_granted INT;
  v_attempts INT;
  v_written INT := 0;
BEGIN
  IF p_account_id IS NULL OR p_tier IS NULL THEN
    RETURN 0;
  END IF;
  v_num_rolls := LEAST(20, GREATEST(1, ROUND(COALESCE(p_multiplier, 1))::INT));

  SELECT config_value INTO v_econ FROM dune_airdrop.airdrop_config WHERE config_key = 'airdrop_economy';
  IF v_econ IS NOT NULL THEN
    v_prob_gear := COALESCE((v_econ->>'prob_gear')::numeric, v_prob_gear);
    v_prob_schem := COALESCE((v_econ->>'prob_schem')::numeric, v_prob_schem);
    v_prob_raw := COALESCE((v_econ->>'prob_raw')::numeric, v_prob_raw);
    v_prob_craft := COALESCE((v_econ->>'prob_craft')::numeric, v_prob_craft);
    -- Four categories exist, so a larger minimum could never be satisfied.
    v_min_drops := LEAST(4, GREATEST(0, COALESCE((v_econ->>'min_items')::int, v_min_drops)));
    v_tier_min := GREATEST(1, COALESCE((v_econ->>('tier_' || p_tier || '_min'))::int, v_tier_min));
    v_tier_max := GREATEST(v_tier_min, COALESCE((v_econ->>('tier_' || p_tier || '_max'))::int, v_tier_max));
  END IF;

  FOR v_roll IN 1..v_num_rolls LOOP
    v_gear := NULL; v_raw := NULL; v_craft := NULL; v_schem := NULL;
    v_granted := 0; v_attempts := 0;

    IF random() <= v_prob_gear THEN
      SELECT template_id INTO v_gear FROM dune_airdrop.airdrop_loot_table
       WHERE tier = p_tier AND category = 'gear' ORDER BY random() * weight DESC LIMIT 1;
      IF v_gear IS NOT NULL THEN v_granted := v_granted + 1; END IF;
    END IF;
    IF random() <= v_prob_raw THEN
      SELECT template_id INTO v_raw FROM dune_airdrop.airdrop_loot_table
       WHERE tier = p_tier AND category = 'raw_resources' ORDER BY random() * weight DESC LIMIT 1;
      IF v_raw IS NOT NULL THEN v_granted := v_granted + 1; END IF;
    END IF;
    IF random() <= v_prob_craft THEN
      SELECT template_id INTO v_craft FROM dune_airdrop.airdrop_loot_table
       WHERE tier = p_tier AND category = 'crafted_components' ORDER BY random() * weight DESC LIMIT 1;
      IF v_craft IS NOT NULL THEN v_granted := v_granted + 1; END IF;
    END IF;
    IF random() <= v_prob_schem THEN
      SELECT template_id INTO v_schem FROM dune_airdrop.airdrop_loot_table
       WHERE tier = p_tier AND category = 'schematics' ORDER BY random() * weight DESC LIMIT 1;
      IF v_schem IS NOT NULL THEN v_granted := v_granted + 1; END IF;
    END IF;

    -- Minimum guarantee, bounded so an empty tier can never loop forever.
    WHILE v_granted < v_min_drops AND v_attempts < 32 LOOP
      v_attempts := v_attempts + 1;
      IF v_gear IS NULL AND random() < 0.25 THEN
        SELECT template_id INTO v_gear FROM dune_airdrop.airdrop_loot_table
         WHERE tier = p_tier AND category = 'gear' ORDER BY random() * weight DESC LIMIT 1;
        IF v_gear IS NOT NULL THEN v_granted := v_granted + 1; END IF;
      ELSIF v_raw IS NULL AND random() < 0.5 THEN
        SELECT template_id INTO v_raw FROM dune_airdrop.airdrop_loot_table
         WHERE tier = p_tier AND category = 'raw_resources' ORDER BY random() * weight DESC LIMIT 1;
        IF v_raw IS NOT NULL THEN v_granted := v_granted + 1; END IF;
      ELSIF v_craft IS NULL AND random() < 0.75 THEN
        SELECT template_id INTO v_craft FROM dune_airdrop.airdrop_loot_table
         WHERE tier = p_tier AND category = 'crafted_components' ORDER BY random() * weight DESC LIMIT 1;
        IF v_craft IS NOT NULL THEN v_granted := v_granted + 1; END IF;
      ELSIF v_schem IS NULL THEN
        SELECT template_id INTO v_schem FROM dune_airdrop.airdrop_loot_table
         WHERE tier = p_tier AND category = 'schematics' ORDER BY random() * weight DESC LIMIT 1;
        IF v_schem IS NOT NULL THEN v_granted := v_granted + 1; END IF;
      END IF;
      EXIT WHEN v_gear IS NOT NULL AND v_raw IS NOT NULL AND v_craft IS NOT NULL AND v_schem IS NOT NULL;
    END LOOP;

    v_raw_qty := (FLOOR(random() * (v_tier_max - v_tier_min + 1)) + v_tier_min)::INT;
    v_craft_qty := (FLOOR(random() * (v_tier_max - v_tier_min + 1)) + v_tier_min)::INT;
    -- Bulk materials come in larger stacks.
    IF v_raw ~* '(ore|ingot|sand)' THEN v_raw_qty := v_raw_qty * 10; END IF;
    IF v_craft ~* '(ore|ingot|sand)' THEN v_craft_qty := v_craft_qty * 10; END IF;

    IF v_gear IS NOT NULL THEN
      INSERT INTO dune_airdrop.airdrop_reward_queue (account_id, template_id, stack_size, quality_level, source)
      VALUES (p_account_id, v_gear, 1, 0, p_source);
      v_written := v_written + 1;
    END IF;
    IF v_raw IS NOT NULL THEN
      INSERT INTO dune_airdrop.airdrop_reward_queue (account_id, template_id, stack_size, quality_level, source)
      VALUES (p_account_id, v_raw, LEAST(1000, GREATEST(1, v_raw_qty)), 0, p_source);
      v_written := v_written + 1;
    END IF;
    IF v_craft IS NOT NULL THEN
      INSERT INTO dune_airdrop.airdrop_reward_queue (account_id, template_id, stack_size, quality_level, source)
      VALUES (p_account_id, v_craft, LEAST(1000, GREATEST(1, v_craft_qty)), 0, p_source);
      v_written := v_written + 1;
    END IF;
    IF v_schem IS NOT NULL THEN
      INSERT INTO dune_airdrop.airdrop_reward_queue (account_id, template_id, stack_size, quality_level, source)
      VALUES (p_account_id, v_schem, 1, 0, p_source);
      v_written := v_written + 1;
    END IF;
  END LOOP;

  RETURN v_written;
END
$fn$;

CREATE OR REPLACE FUNCTION dune_airdrop.airdrop_roll_playtime(p_account_id BIGINT, p_pawn_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
  v_tier INT;
  v_config JSONB;
  v_multiplier NUMERIC := 1.0;
BEGIN
  v_tier := dune_airdrop.airdrop_pawn_tier(p_pawn_id);
  SELECT config_value INTO v_config FROM dune_airdrop.airdrop_config WHERE config_key = 'airdrop_multipliers';
  IF v_config IS NOT NULL THEN
    v_multiplier := COALESCE((v_config->>('playtime_multiplier_t' || v_tier))::numeric, 1.0);
  END IF;
  PERFORM dune_airdrop.airdrop_queue_roll(p_account_id, v_tier, GREATEST(1.0, v_multiplier), 'playtime');
END
$fn$;

-- Daily streak and weekly attendance. Weeks start on Tuesday (the Coriolis
-- reset), so the day index is 0 = Tuesday ... 6 = Monday.
CREATE OR REPLACE FUNCTION dune_airdrop.airdrop_check_daily_weekly(p_account_id BIGINT, p_pawn_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
  v_config JSONB;
  v_today DATE := CURRENT_DATE;
  v_track dune_airdrop.airdrop_player_progress%ROWTYPE;
  v_tier INT;
  v_daily_enabled BOOLEAN := TRUE;
  v_daily_step NUMERIC := 0.5;
  v_daily_max INT := 7;
  v_weekly_enabled BOOLEAN := TRUE;
  v_weekly_req INT := 5;
  v_weekly_scale NUMERIC := 5.0;
  v_streak INT;
  v_mask INT;
  v_week_id INT;
  v_day INT;
  v_claimed_week INT;
BEGIN
  SELECT config_value INTO v_config FROM dune_airdrop.airdrop_config WHERE config_key = 'airdrop_multipliers';
  IF v_config IS NOT NULL THEN
    v_daily_enabled := COALESCE((v_config->>'daily_enabled')::boolean, v_daily_enabled);
    v_daily_step := COALESCE((v_config->>'daily_multiplier_step')::numeric, v_daily_step);
    v_daily_max := GREATEST(1, COALESCE((v_config->>'daily_max_streak')::int, v_daily_max));
    v_weekly_enabled := COALESCE((v_config->>'weekly_enabled')::boolean, v_weekly_enabled);
    v_weekly_req := LEAST(7, GREATEST(1, COALESCE((v_config->>'weekly_days_required')::int, v_weekly_req)));
    v_weekly_scale := COALESCE((v_config->>'weekly_multiplier')::numeric, v_weekly_scale);
  END IF;

  v_week_id := EXTRACT(YEAR FROM v_today - 1)::INT * 100 + EXTRACT(WEEK FROM v_today - 1)::INT;
  v_day := (EXTRACT(ISODOW FROM v_today)::INT + 5) % 7;

  -- Row lock prevents two concurrent saves from both claiming today.
  SELECT * INTO v_track FROM dune_airdrop.airdrop_player_progress WHERE character_id = p_pawn_id FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO dune_airdrop.airdrop_player_progress (character_id, account_id, last_login_date, consecutive_days, weekly_login_mask, current_week_id)
    VALUES (p_pawn_id, p_account_id, v_today - 1, 0, 0, v_week_id)
    ON CONFLICT (character_id) DO NOTHING;
    SELECT * INTO v_track FROM dune_airdrop.airdrop_player_progress WHERE character_id = p_pawn_id FOR UPDATE;
  END IF;

  IF v_track.last_login_date IS NOT NULL AND v_track.last_login_date >= v_today THEN
    RETURN;
  END IF;

  v_streak := CASE WHEN v_track.last_login_date = v_today - 1
                   THEN LEAST(v_daily_max, v_track.consecutive_days + 1)
                   ELSE 1 END;
  v_mask := CASE WHEN v_track.current_week_id = v_week_id
                 THEN (v_track.weekly_login_mask | (1 << v_day)) & 127
                 ELSE (1 << v_day) END;

  UPDATE dune_airdrop.airdrop_player_progress
     SET account_id = p_account_id,
         last_login_date = v_today,
         consecutive_days = v_streak,
         weekly_login_mask = v_mask,
         current_week_id = v_week_id
   WHERE character_id = p_pawn_id;

  v_tier := dune_airdrop.airdrop_pawn_tier(p_pawn_id);

  IF v_daily_enabled THEN
    PERFORM dune_airdrop.airdrop_queue_roll(p_account_id, v_tier, 1.0 + (v_streak - 1) * v_daily_step, 'daily');
  END IF;

  IF v_weekly_enabled AND length(replace((v_mask::bit(7))::text, '0', '')) >= v_weekly_req THEN
    v_claimed_week := CASE WHEN v_track.last_weekly_claimed_at IS NULL THEN NULL
      ELSE EXTRACT(YEAR FROM (v_track.last_weekly_claimed_at - interval '1 day'))::INT * 100
         + EXTRACT(WEEK FROM (v_track.last_weekly_claimed_at - interval '1 day'))::INT END;
    IF v_claimed_week IS DISTINCT FROM v_week_id THEN
      PERFORM dune_airdrop.airdrop_queue_roll(p_account_id, v_tier, v_weekly_scale, 'weekly');
      UPDATE dune_airdrop.airdrop_player_progress
         SET last_weekly_claimed_at = now()
       WHERE character_id = p_pawn_id;
    END IF;
  END IF;
END
$fn$;

-- Trigger body. Fields are read through to_jsonb(NEW) so a future game
-- schema change degrades to a logged warning instead of an error, and the
-- whole body is guarded so a reward failure can never block a game save.
CREATE OR REPLACE FUNCTION dune_airdrop.airdrop_track_playtime()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
  v_row JSONB;
  v_account_id BIGINT;
  v_pawn_id BIGINT;
  v_config JSONB;
  v_playtime_enabled BOOLEAN := TRUE;
  v_interval_min INT := 60;
  v_min_dist DOUBLE PRECISION := 10.0;
  v_min_xp INT := 1;
  v_prev_active TIMESTAMPTZ;
  v_track dune_airdrop.airdrop_player_progress%ROWTYPE;
  v_components JSONB;
  v_xp BIGINT := 0;
  v_x DOUBLE PRECISION := 0;
  v_y DOUBLE PRECISION := 0;
  v_z DOUBLE PRECISION := 0;
  v_delta INT;
  v_active BOOLEAN := FALSE;
  v_seconds INT;
BEGIN
  v_row := to_jsonb(NEW);
  IF COALESCE(v_row->>'player_pawn_id', '') !~ '^[0-9]{1,18}$'
     OR COALESCE(v_row->>'account_id', '') !~ '^[0-9]{1,18}$' THEN
    RETURN NEW;
  END IF;
  v_pawn_id := (v_row->>'player_pawn_id')::bigint;
  v_account_id := (v_row->>'account_id')::bigint;

  IF lower(COALESCE(v_row->>'online_status', '')) <> 'online'
     OR COALESCE(v_row->>'character_state', 'Active') <> 'Active' THEN
    -- Offline: stop counting until the next online save.
    UPDATE dune_airdrop.airdrop_player_progress SET last_active_at = NULL
     WHERE character_id = v_pawn_id AND last_active_at IS NOT NULL;
    RETURN NEW;
  END IF;

  -- Throttle: the game updates this row often; evaluate at most once a minute.
  SELECT last_active_at INTO v_prev_active FROM dune_airdrop.airdrop_player_progress WHERE character_id = v_pawn_id;
  IF v_prev_active IS NOT NULL AND v_prev_active > now() - interval '60 seconds' THEN
    RETURN NEW;
  END IF;

  SELECT config_value INTO v_config FROM dune_airdrop.airdrop_config WHERE config_key = 'airdrop_multipliers';
  IF v_config IS NOT NULL THEN
    v_playtime_enabled := COALESCE((v_config->>'playtime_enabled')::boolean, v_playtime_enabled);
    v_interval_min := COALESCE((v_config->>'playtime_interval')::int, v_interval_min);
    v_min_dist := COALESCE((v_config->>'playtime_distance')::double precision, v_min_dist);
    v_min_xp := COALESCE((v_config->>'playtime_xp')::int, v_min_xp);
  END IF;
  IF v_interval_min < 1 THEN v_interval_min := 60; END IF;

  PERFORM dune_airdrop.airdrop_check_daily_weekly(v_account_id, v_pawn_id);

  SELECT fe.components->'FLevelComponent'->1 INTO v_components
    FROM dune.actor_fgl_entities afe
    LEFT JOIN dune.fgl_entities fe ON fe.entity_id = afe.entity_id
   WHERE afe.actor_id = v_pawn_id AND afe.slot_name = 'DuneCharacter'
   LIMIT 1;
  IF (v_components->>'TotalXPEarned') ~ '^[0-9]{1,18}(\.[0-9]+)?$' THEN
    v_xp := floor((v_components->>'TotalXPEarned')::numeric)::bigint;
  END IF;

  SELECT COALESCE(((a.transform).location).x, 0), COALESCE(((a.transform).location).y, 0), COALESCE(((a.transform).location).z, 0)
    INTO v_x, v_y, v_z
    FROM dune.actors a
   WHERE a.id = v_pawn_id;

  SELECT * INTO v_track FROM dune_airdrop.airdrop_player_progress WHERE character_id = v_pawn_id;
  v_delta := EXTRACT(EPOCH FROM (now() - v_track.last_active_at))::INT;

  -- Count at most 10 minutes per evaluation, so logging back in after a
  -- long absence never credits the time spent offline.
  IF v_track.last_active_at IS NOT NULL AND v_delta > 0 AND v_delta < 600 THEN
    IF v_min_dist = 0 AND v_min_xp = 0 THEN
      v_active := TRUE;
    ELSE
      IF v_min_dist > 0 AND sqrt(power(v_x - v_track.last_x, 2) + power(v_y - v_track.last_y, 2) + power(v_z - v_track.last_z, 2)) >= v_min_dist THEN
        v_active := TRUE;
      END IF;
      IF v_min_xp > 0 AND v_xp - v_track.last_xp >= v_min_xp THEN
        v_active := TRUE;
      END IF;
    END IF;
  END IF;

  v_seconds := COALESCE(v_track.active_seconds, 0);
  IF v_active THEN
    v_seconds := v_seconds + v_delta;
    IF v_playtime_enabled AND v_seconds >= v_interval_min * 60 THEN
      PERFORM dune_airdrop.airdrop_roll_playtime(v_account_id, v_pawn_id);
      v_seconds := 0;
    END IF;
  END IF;

  UPDATE dune_airdrop.airdrop_player_progress
     SET account_id = v_account_id,
         active_seconds = v_seconds,
         last_xp = v_xp,
         last_x = v_x,
         last_y = v_y,
         last_z = v_z,
         last_active_at = now()
   WHERE character_id = v_pawn_id;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[dune-airdrop-addon] playtime tracking skipped for pawn %: % (%)', v_pawn_id, SQLERRM, SQLSTATE;
  RETURN NEW;
END
$fn$;

-- ---------------------------------------------------------------------------
-- 7. The outbox view the console delivers from
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW dune_airdrop.airdrop_reward_outbox AS
SELECT q.id,
       'airdrop:' || q.request_id::text AS request_id,
       q.account_id::text AS player_id,
       'item'::text AS reward_type,
       q.template_id AS item_id,
       q.stack_size AS amount,
       q.quality_level AS quality,
       q.created_at
  FROM dune_airdrop.airdrop_reward_queue q
 WHERE q.state = 'queued';

-- ---------------------------------------------------------------------------
-- 8. The one object in the game schema: the playtime trigger
-- ---------------------------------------------------------------------------
DO $trigger_guard$
DECLARE
  v_existing_fn TEXT;
BEGIN
  SELECT t.tgfoid::regprocedure::text INTO v_existing_fn
    FROM pg_trigger t
   WHERE t.tgrelid = 'dune.encrypted_player_state'::regclass
     AND t.tgname = 'dune_airdrop_track_playtime'
     AND NOT t.tgisinternal;
  IF v_existing_fn IS NOT NULL AND v_existing_fn <> 'dune_airdrop.airdrop_track_playtime()' THEN
    RAISE EXCEPTION '[dune-airdrop-addon] A trigger named dune_airdrop_track_playtime already exists on dune.encrypted_player_state but runs %, which is not this addon''s function. Aborting without changes.', v_existing_fn;
  END IF;
END
$trigger_guard$;

CREATE OR REPLACE TRIGGER dune_airdrop_track_playtime
AFTER UPDATE ON dune.encrypted_player_state
FOR EACH ROW
EXECUTE FUNCTION dune_airdrop.airdrop_track_playtime();

-- ---------------------------------------------------------------------------
-- 9. Ownership markers
-- ---------------------------------------------------------------------------
COMMENT ON SCHEMA dune_airdrop IS 'dune-airdrop-addon|v2|schema: Airdrop Manager addon (github.com/atobo/dune-airdrop-addon); removed by uninstall_playtime_airdrops.sql';
COMMENT ON TABLE dune_airdrop.airdrop_schema_version IS 'dune-airdrop-addon|v2|schema-version';
COMMENT ON TABLE dune_airdrop.airdrop_migration_log IS 'dune-airdrop-addon|v2|migration-log';
COMMENT ON TABLE dune_airdrop.airdrop_config IS 'dune-airdrop-addon|v2|settings';
COMMENT ON TABLE dune_airdrop.airdrop_player_progress IS 'dune-airdrop-addon|v2|player-progress: playtime, daily streak and weekly attendance per character (pawn id)';
COMMENT ON TABLE dune_airdrop.airdrop_loot_table IS 'dune-airdrop-addon|v2|loot-table: generated from scripts/admin-items.json';
COMMENT ON TABLE dune_airdrop.airdrop_reward_queue IS 'dune-airdrop-addon|v2|reward-queue: rewards owed; delivery state lives in the console reward runtime';
COMMENT ON VIEW dune_airdrop.airdrop_reward_outbox IS 'dune-airdrop-addon|v2|reward-outbox: the only object the console delivery job reads';
COMMENT ON FUNCTION dune_airdrop.airdrop_pawn_tier(BIGINT) IS 'dune-airdrop-addon|v2|pawn-tier';
COMMENT ON FUNCTION dune_airdrop.airdrop_queue_roll(BIGINT, INT, NUMERIC, TEXT) IS 'dune-airdrop-addon|v2|queue-roll';
COMMENT ON FUNCTION dune_airdrop.airdrop_roll_playtime(BIGINT, BIGINT) IS 'dune-airdrop-addon|v2|roll-playtime';
COMMENT ON FUNCTION dune_airdrop.airdrop_check_daily_weekly(BIGINT, BIGINT) IS 'dune-airdrop-addon|v2|daily-weekly';
COMMENT ON FUNCTION dune_airdrop.airdrop_track_playtime() IS 'dune-airdrop-addon|v2|playtime-trigger-function';
COMMENT ON TRIGGER dune_airdrop_track_playtime ON dune.encrypted_player_state IS 'dune-airdrop-addon|v2|playtime-trigger: added by the Airdrop Manager addon; reads game tables, writes only to schema dune_airdrop';

-- Every remaining object in the schema (constraints, indexes, sequences) gets
-- a generic marker so the audit query lists the complete set.
DO $markers$
DECLARE
  v_obj RECORD;
BEGIN
  FOR v_obj IN
    SELECT c.relname, c.relkind, t.relname AS table_name
      FROM pg_class c
      LEFT JOIN pg_index i ON i.indexrelid = c.oid
      LEFT JOIN pg_class t ON t.oid = i.indrelid
     WHERE c.relnamespace = 'dune_airdrop'::regnamespace
       AND c.relkind IN ('i', 'S')
       AND obj_description(c.oid, 'pg_class') IS NULL
  LOOP
    IF v_obj.relkind = 'i' THEN
      EXECUTE format('COMMENT ON INDEX dune_airdrop.%I IS %L', v_obj.relname,
                     format('dune-airdrop-addon|v2|index:%s', v_obj.table_name));
    ELSE
      EXECUTE format('COMMENT ON SEQUENCE dune_airdrop.%I IS %L', v_obj.relname, 'dune-airdrop-addon|v2|sequence');
    END IF;
  END LOOP;

  FOR v_obj IN
    SELECT con.conname AS relname, 'c'::"char" AS relkind, cl.relname AS table_name
      FROM pg_constraint con
      JOIN pg_class cl ON cl.oid = con.conrelid
     WHERE con.connamespace = 'dune_airdrop'::regnamespace
       AND obj_description(con.oid, 'pg_constraint') IS NULL
  LOOP
    EXECUTE format('COMMENT ON CONSTRAINT %I ON dune_airdrop.%I IS %L', v_obj.relname, v_obj.table_name,
                   format('dune-airdrop-addon|v2|constraint:%s', v_obj.table_name));
  END LOOP;
END
$markers$;

-- ---------------------------------------------------------------------------
-- 10. Record the schema version
-- ---------------------------------------------------------------------------
INSERT INTO dune_airdrop.airdrop_schema_version (version, addon_version)
VALUES (2, '1.4.0')
ON CONFLICT (version) DO UPDATE SET addon_version = EXCLUDED.addon_version, upgraded_at = now();

INSERT INTO dune_airdrop.airdrop_migration_log (step, level, detail)
VALUES ('setup', 'info', 'schema v2 ready (addon 1.4.0)');

SELECT '[dune-airdrop-addon] schema v2 ready' AS status,
       (SELECT count(*) FROM dune_airdrop.airdrop_reward_queue WHERE state = 'held') AS legacy_rewards_held,
       (SELECT count(*) FROM dune_airdrop.airdrop_reward_queue WHERE state = 'review') AS legacy_rewards_for_review,
       (SELECT count(*) FROM dune_airdrop.airdrop_migration_log WHERE level = 'manual') AS manual_cleanup_steps;
