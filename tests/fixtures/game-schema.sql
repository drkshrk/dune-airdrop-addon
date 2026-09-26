-- Minimal subset of the Dune Awakening game schema used by the migration
-- tests: only the objects the addon reads or attaches to, with the column
-- types and constraints of the real game database (dune2, 2026-09-26), plus
-- one real game trigger so the "game objects untouched" check has something
-- to guard. Set AIRDROP_GAME_SCHEMA_DUMP to a full `pg_dump --schema-only`
-- file to run the same tests against the complete schema instead.

CREATE SCHEMA dune;

CREATE TYPE dune.vector AS (x double precision, y double precision, z double precision);
CREATE TYPE dune.quaternion AS (x double precision, y double precision, z double precision, w double precision);
CREATE TYPE dune.transform AS (location dune.vector, rotation dune.quaternion);
CREATE TYPE dune.actorstate AS ENUM ('Default', 'Travel', 'VehicleBackup', 'AbortedAuthorityTransfer', 'VehicleRecovery', 'BaseBackup', 'SimulatedLandsraadActor');
CREATE TYPE dune.characterstate AS ENUM ('Active', 'Deleted');
CREATE TYPE dune.playerlifestate AS ENUM ('Alive', 'Dead', 'DeadByCoriolis', 'DeadBySandworm');
CREATE TYPE dune.playerconnectionstatus AS ENUM ('Offline', 'LoggingOut', 'Online');

CREATE FUNCTION dune.decrypt_user_data(in_encrypted_data bytea) RETURNS text
  LANGUAGE sql IMMUTABLE AS $$select convert_from(in_encrypted_data, 'utf8');$$;
CREATE FUNCTION dune.encrypt_user_data(in_data text) RETURNS bytea
  LANGUAGE sql IMMUTABLE AS $$select convert_to(in_data, 'utf8')$$;

CREATE TABLE dune.encrypted_accounts (
  id bigserial PRIMARY KEY,
  "user" text NOT NULL UNIQUE,
  encrypted_funcom_id bytea,
  takeoverable boolean DEFAULT false,
  platform_name text,
  encrypted_platform_id bytea
);

CREATE TABLE dune.actors (
  id bigint NOT NULL PRIMARY KEY,
  class text,
  map text,
  transform dune.transform,
  partition_id bigint,
  dimension_index integer DEFAULT 0 NOT NULL,
  gas_attributes jsonb DEFAULT '{}'::jsonb NOT NULL,
  properties jsonb DEFAULT '{}'::jsonb NOT NULL,
  owner_account_id bigint,
  serial bigint DEFAULT 0 NOT NULL,
  state dune.actorstate DEFAULT 'Default'::dune.actorstate NOT NULL,
  CONSTRAINT actors_id_check CHECK (id > 0)
);

CREATE TABLE dune.encrypted_player_state (
  account_id bigint NOT NULL REFERENCES dune.encrypted_accounts(id) ON UPDATE CASCADE ON DELETE CASCADE,
  encrypted_character_name bytea NOT NULL,
  last_avatar_activity timestamp with time zone,
  server_id text,
  player_controller_id bigint REFERENCES dune.actors(id) ON DELETE SET NULL,
  player_pawn_id bigint REFERENCES dune.actors(id) ON DELETE SET NULL,
  player_state_id bigint REFERENCES dune.actors(id) ON DELETE SET NULL,
  life_state dune.playerlifestate DEFAULT 'Alive'::dune.playerlifestate NOT NULL,
  online_status dune.playerconnectionstatus DEFAULT 'Offline'::dune.playerconnectionstatus NOT NULL,
  last_login_time timestamp with time zone,
  id bigint NOT NULL PRIMARY KEY,
  character_state dune.characterstate DEFAULT 'Active'::dune.characterstate NOT NULL,
  last_character_state_change timestamp without time zone DEFAULT now() NOT NULL
);
CREATE INDEX encrypted_player_state_character_name_gin_stub
  ON dune.encrypted_player_state (dune.decrypt_user_data(encrypted_character_name));

CREATE VIEW dune.player_state AS
SELECT account_id,
       dune.decrypt_user_data(encrypted_character_name) AS character_name,
       last_avatar_activity, server_id, player_controller_id, player_pawn_id, player_state_id,
       life_state, online_status, last_login_time, id, character_state, last_character_state_change
  FROM dune.encrypted_player_state
 WHERE character_state = 'Active'::dune.characterstate;

CREATE TABLE dune.fgl_entities (
  entity_id bigint NOT NULL PRIMARY KEY,
  components jsonb,
  CONSTRAINT fgl_entities_entity_id_check CHECK (entity_id <> 0)
);

CREATE TABLE dune.actor_fgl_entities (
  actor_id bigint,
  entity_id bigint,
  slot_name text NOT NULL
);

CREATE TABLE dune.inventories (
  id bigint NOT NULL PRIMARY KEY,
  actor_id bigint,
  exchange_id bigint,
  item_id bigint,
  vehicle_module_id bigint,
  inventory_type integer,
  max_item_count integer,
  max_item_volume real,
  CONSTRAINT inventories_id_check CHECK (id > 0),
  CONSTRAINT valid_fkey CHECK (actor_id IS NOT NULL OR exchange_id IS NOT NULL OR item_id IS NOT NULL OR vehicle_module_id IS NOT NULL)
);

CREATE TABLE dune.items (
  id bigserial PRIMARY KEY,
  inventory_id bigint,
  stack_size bigint NOT NULL,
  position_index bigint NOT NULL,
  template_id text NOT NULL,
  is_new boolean DEFAULT true,
  acquisition_time bigint DEFAULT 0 NOT NULL,
  stats jsonb NOT NULL,
  quality_level bigint DEFAULT 0 NOT NULL,
  volume_override real,
  CONSTRAINT items_position_index_check CHECK (position_index >= 0),
  CONSTRAINT items_stack_size_check CHECK (stack_size > 0)
);

-- A real game trigger, reproduced so the tests can prove it survives.
CREATE FUNCTION dune.cleanup_orphaned_entities() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM dune.fgl_entities WHERE fgl_entities.entity_id = OLD.entity_id;
  RETURN NULL;
END
$$;
CREATE TRIGGER actor_fgl_entities_cleanup_orphaned_entities
  AFTER DELETE ON dune.actor_fgl_entities
  FOR EACH ROW EXECUTE FUNCTION dune.cleanup_orphaned_entities();
