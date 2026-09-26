# Dune Airdrop Addon

![Dune Airdrop Concept Art](assets/dune_airdrop_art.png)

A powerful, customizable, and automated playtime tracking and rewards system for Dune Awakening self-hosted servers, designed exclusively for the RedBlink Console.

## Features
- **Real-Time Playtime Tracking:** Automatically tracks active online playtime, verifying movement and map coordinates to prevent AFK exploitation.
- **Dynamic Reward Scaling:** Scales XP or item drops based on consecutive hours played.
- **Daily & Weekly Login Rewards:** Calculates and manages sequential daily login streaks and weekly activity thresholds.

## 1. Installation

1. Copy the `dune-airdrop-addon` folder into your `runtime/addons/installed/` directory.
2. In the RedBlink UI, click **INIT SCHEMA**. Wait for it to complete.

## 2. Delivery

Rewards are queued in the addon's own `dune_airdrop` schema by a database trigger and handed to the console's reward runtime (`rewards.deliver`), which waits for the player to be online, retries, and never delivers the same reward twice. While the Airdrop Manager page is open it hands queued rewards over automatically. Upgrading from 1.3.x: stop and remove the old daemon first (`docker rm -f airdrop-daemon`), then click **INIT SCHEMA** — the migration imports your settings, player progress and any undelivered rewards (held for review, never auto-delivered).

## 3. Uninstallation

If you wish to remove the Airdrop Addon completely:
1. Remove the database tables and triggers (run from the addon folder):
```bash
docker exec -i dune-postgres psql -U postgres -d dune -1 -v ON_ERROR_STOP=1 < uninstall_playtime_airdrops.sql
```
2. Uninstall the addon via the Dune Console UI.

## Repository Layout

```text
addon.json                       Addon identity, version, entry path, and permissions.
setup_playtime_airdrops.sql      PostgreSQL schemas and triggers for tracking & rewards.
uninstall_playtime_airdrops.sql  PostgreSQL cleanup script for uninstalling.
web/                             The addon page shown inside Dune Docker Console.
```
