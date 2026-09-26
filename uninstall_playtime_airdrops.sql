-- ============================================================================
-- Airdrop Manager (dune-airdrop-addon) - uninstall
-- ============================================================================
-- Removes everything this addon owns: its trigger on dune.encrypted_player_state
-- and the dune_airdrop / dune_airdrop_legacy schemas. Nothing in the game's
-- schema is dropped except triggers whose function lives in dune_airdrop, and
-- the script aborts without changes if any other object depends on the
-- addon's schemas.
--
-- Run as a single transaction:
--   docker exec -i dune-postgres psql -U postgres -d dune -1 -v ON_ERROR_STOP=1 < uninstall_playtime_airdrops.sql
--
-- Tables named dune.bot_active_playtime, dune.bot_pending_deliveries and
-- dune.discord_bot_config pre-date this addon and may belong to another tool,
-- so they are never removed here; the final report lists any that remain.
-- ============================================================================

SET LOCAL lock_timeout = '5s';
SET LOCAL client_min_messages = warning;

-- 1. Triggers on any table that execute a function in this addon's schema.
DO $drop_triggers$
DECLARE
  v_trg RECORD;
BEGIN
  FOR v_trg IN
    SELECT t.tgname, n.nspname AS sch, c.relname AS tbl
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_proc p ON p.oid = t.tgfoid
     WHERE NOT t.tgisinternal
       AND p.pronamespace = to_regnamespace('dune_airdrop')
  LOOP
    EXECUTE format('DROP TRIGGER %I ON %I.%I', v_trg.tgname, v_trg.sch, v_trg.tbl);
  END LOOP;
END
$drop_triggers$;

-- 2. Refuse to cascade into anything outside the addon's schemas.
DO $dependency_guard$
DECLARE
  v_ours OID[];
  v_outside TEXT;
BEGIN
  v_ours := ARRAY(SELECT oid FROM pg_namespace WHERE nspname IN ('dune_airdrop', 'dune_airdrop_legacy'));
  IF cardinality(v_ours) = 0 THEN
    RETURN;
  END IF;

  -- Resolve every dependent to the schema it really lives in. Views depend
  -- through a rewrite rule, triggers and constraints through their table, and
  -- defaults through their column's table; pg_identify_object reports no
  -- schema for some of these, so they are mapped explicitly.
  SELECT string_agg(DISTINCT pg_describe_object(d.classid, d.objid, d.objsubid), '; ')
    INTO v_outside
    FROM pg_depend d
    LEFT JOIN pg_rewrite rw ON d.classid = 'pg_rewrite'::regclass AND rw.oid = d.objid
    LEFT JOIN pg_trigger tg ON d.classid = 'pg_trigger'::regclass AND tg.oid = d.objid
    LEFT JOIN pg_constraint co ON d.classid = 'pg_constraint'::regclass AND co.oid = d.objid
    LEFT JOIN pg_attrdef ad ON d.classid = 'pg_attrdef'::regclass AND ad.oid = d.objid
    LEFT JOIN pg_class owner_rel ON owner_rel.oid = COALESCE(rw.ev_class, tg.tgrelid, co.conrelid, ad.adrelid)
    CROSS JOIN LATERAL pg_identify_object(d.classid, d.objid, d.objsubid) dep
   WHERE d.deptype = 'n'
     AND d.refobjid IN (
       SELECT oid FROM pg_class WHERE relnamespace = ANY (v_ours)
       UNION ALL SELECT oid FROM pg_proc WHERE pronamespace = ANY (v_ours)
       UNION ALL SELECT oid FROM pg_type WHERE typnamespace = ANY (v_ours))
     AND COALESCE(owner_rel.relnamespace, to_regnamespace(dep.schema)) IS NOT NULL
     AND NOT (COALESCE(owner_rel.relnamespace, to_regnamespace(dep.schema)) = ANY (v_ours));

  IF v_outside IS NOT NULL THEN
    RAISE EXCEPTION '[dune-airdrop-addon] Uninstall aborted without changes: objects outside the addon depend on it: %', v_outside;
  END IF;
END
$dependency_guard$;

-- 3. The addon's own schemas.
DROP SCHEMA IF EXISTS dune_airdrop_legacy CASCADE;
DROP SCHEMA IF EXISTS dune_airdrop CASCADE;

-- 4. Report anything from pre-1.4 releases still left in the game schema.
--    Setup (not uninstall) migrates and removes those; they are listed here so
--    nothing is silently left behind.
SELECT '[dune-airdrop-addon] uninstalled' AS status,
       (SELECT string_agg(p.oid::regprocedure::text, ', ')
          FROM pg_proc p
         WHERE p.pronamespace = 'dune'::regnamespace
           AND p.proname ~ '^(fn_(get_pawn_tier|queue_reward_roll|roll_playtime_reward|deliver_playtime_airdrops|check_daily_weekly_rewards|manual_airdrop_spawn)|trg_(track_playtime|notify_pending_delivery))') AS legacy_functions_remaining,
       (SELECT string_agg(c.relname, ', ')
          FROM pg_class c
         WHERE c.relnamespace = 'dune'::regnamespace
           AND c.relkind = 'r'
           AND c.relname IN ('bot_active_playtime', 'bot_pending_deliveries', 'bot_delivery_receipts', 'discord_bot_config',
                             'airdrop_active_playtime', 'airdrop_pending_deliveries', 'airdrop_delivery_receipts',
                             'airdrop_config', 'airdrop_loot_tables', 'airdrop_addon_config')) AS legacy_tables_remaining;
