!!! warning "Experimental"
    [Amaru](https://github.com/pragma-org/amaru) is a Rust implementation of a Cardano node, still in an exploratory phase with weekly releases. Run it on a relay next to at least one cardano-node relay, so your block producer always keeps a Haskell path to the network.

The guild scripts can run Amaru instead of cardano-node under the same `cnode` systemd service. The choice is a single user variable in `env`:

```bash
NODE_IMPL="amaru"     # cardano-node (default) | amaru
```

Everything else stays where it was: `CNODE_PORT`, `topology.json`, the pool keys in `priv/pool/<POOL_NAME>`, `sudo systemctl restart cnode`, `journalctl -u cnode` and gLiveView.

## What changes with Amaru

| | cardano-node | Amaru |
|---|---|---|
| Binary | `cardano-node` | `amaru` (`guild-deploy.sh -s a`) |
| Databases | `${CNODE_HOME}/db` | `${AMARU_HOME}` (default `${CNODE_HOME}/amaru`), created with `amaru node bootstrap` and `amaru mithril sync` |
| Peers | `topology.json` | Translated from `topology.json` at every start (see below) |
| Metrics | Prometheus on `PROM_PORT` | OTLP, served on the same `PROM_HOST:PROM_PORT` by `cnode-otelcol.service` |
| node.socket | yes | **no**: local queries go through Koios (`ENABLE_KOIOS=Y` is required) |
| Block production | mainnet and testnets | **testnets only**: Amaru refuses to forge on mainnet |

Because there is no node.socket, these stop working against an Amaru node: `cardano-cli query ...`, CNTools in online mode without Koios, Ogmios, DB-Sync, the submit API (`cnode-submit-api`), the Mithril signer and Log Monitor/blockPerf. Run them against a cardano-node elsewhere if you need them.

### Topology translation

`topology.json` stays the source of truth:

- **Relay**: every `localRoots`, `publicRoots` and `bootstrapPeers` access point becomes an Amaru static peer. The sum of the `localRoots` `hotValency` values is kept connected at all times. Shared, snapshot, inbound and ledger peers (when `useLedgerAfterSlot` is not `-1`) fill the remaining slots.
- **Block producer** (pool keys present): only the `localRoots` (your relays) are used, as static peers. There is no peer discovery, and inbound connections are limited to the same number. Keep the firewall rule that only lets your relays reach `CNODE_PORT`.

`trustable`, `advertise` and `warmValency` have no Amaru equivalent; the migration reports them.

## Fresh install with Amaru

```bash
./guild-deploy.sh -n preview -i amaru -s pdlmf
cd "${CNODE_HOME}"/scripts
./cnode.sh -d                 # deploys cnode.service and cnode-otelcol.service
sudo systemctl start cnode    # first start bootstraps the Amaru databases
```

`-i amaru` sets `NODE_IMPL="amaru"` in `env` and downloads Amaru and the OpenTelemetry collector (`-s a`). Without `-i`, guild-deploy never changes `NODE_IMPL`, so refreshing scripts keeps your choice.

## Migrating an existing node: migrate-amaru.sh

```bash
Usage: migrate-amaru.sh [-c] [-y] [-r [-p]]

Migrate this cnode (relay or block producer) from cardano-node to Amaru, or back.
cardano-node's db/ is kept, so a rollback is a restart, not a resync.

-c    Check only: run the preflight checks and show what the migration would change
-y    Do not prompt for confirmation
-r    Roll back to cardano-node
-p    With -r: also delete the Amaru databases in AMARU_HOME
```

1. Install the binaries: `./guild-deploy.sh -s a` (keeps cardano-node installed for rollback).
2. Review the plan: `./migrate-amaru.sh -c`.
3. Migrate: `./migrate-amaru.sh`.

The script:

1. Checks the network, role (relay or block producer), binaries, free disk space, clock synchronisation and Koios. A mainnet block producer is refused.
2. Shows the translated peers and lists the enabled `cnode-*` services that need cardano-node.
3. Builds the Amaru databases while cardano-node keeps running. This takes extra RAM and disk for its duration.
4. Disables the incompatible services, sets `NODE_IMPL="amaru"`, redeploys the systemd units and restarts `cnode`. This is the only downtime.
5. Waits until Amaru's tip advances and is within `VERIFY_MAX_LAG` slots of the Koios tip. If that does not happen within `VERIFY_TIMEOUT`, it rolls back automatically.

`./migrate-amaru.sh -r` switches back to cardano-node and re-enables the services the migration disabled. Each run logs to `${LOG_DIR}/migrate-amaru_<timestamp>.log`, and the previous `env` is kept in `scripts/archive`.
