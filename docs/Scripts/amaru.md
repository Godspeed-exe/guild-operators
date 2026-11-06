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
| Block production | mainnet and testnets | mainnet from release 10.11.20261105 (earlier releases refuse it); testnets |

Because there is no node.socket, these stop working against an Amaru node: `cardano-cli query ...`, CNTools in online mode without Koios, Ogmios, DB-Sync, the submit API (`cnode-submit-api`), the Mithril signer and Log Monitor/blockPerf. Run them against a cardano-node elsewhere if you need them.

### Topology translation

`topology.json` stays the source of truth:

- **Relay**: every `localRoots`, `publicRoots` and `bootstrapPeers` access point becomes an Amaru static peer. The sum of the `localRoots` `hotValency` values is kept connected at all times. Shared, snapshot, inbound and ledger peers (when `useLedgerAfterSlot` is not `-1`) fill the remaining slots. Up to `AMARU_PEERS_MAX_DOWNSTREAM` (default 50, set in `env`) inbound peers are accepted; Amaru's own default is 10.
- **Block producer** (pool keys present): only the `localRoots` (your relays) are used, as static peers. There is no peer discovery, and inbound connections are limited to the same number plus `AMARU_BP_LOCAL_CLIENTS` (default 2, set in `env`) for local clients such as `cncli sync`. Keep the firewall rule that only lets your relays reach `CNODE_PORT`.

`trustable`, `advertise` and `warmValency` have no Amaru equivalent; the migration reports them.

## Fresh install with Amaru

```bash
./guild-deploy.sh -n preview -i amaru -s pdlmf
cd "${CNODE_HOME}"/scripts
./cnode.sh -d                 # deploys cnode.service and cnode-otelcol.service
sudo systemctl start cnode    # first start bootstraps the Amaru databases
```

`-i amaru` sets `NODE_IMPL="amaru"` in `env` and downloads Amaru and the OpenTelemetry collector (`-s a`). Without `-i`, guild-deploy never changes `NODE_IMPL`, so refreshing scripts keeps your choice.

### Choosing the Amaru version

`-v` picks which Amaru to install, with `-i amaru` or `-s a`:

| `-v` | Installs | Integrity |
| --- | --- | --- |
| *(omitted)* | the release pinned in `files/docker/node/release-versions/amaru-latest.txt` | checksum manifest |
| `latest` | the newest release on GitHub | checksum manifest |
| `10.11.20261029` | that release | checksum manifest |
| `nightly` | the latest nightly build of `main` from [nightly.amaru.global](https://nightly.amaru.global) | none published; the archive hash and the commit are logged |
| any other value | that git ref (commit, branch or tag), built from source | built locally |

```bash
./guild-deploy.sh -s a -v latest
./guild-deploy.sh -s a -v nightly
./guild-deploy.sh -s a -v main                                          # build the tip of main
AMARU_SOURCE_REPO=https://github.com/<you>/amaru ./guild-deploy.sh -s a -v my-branch
```

A source build installs what it needs: the C/C++ toolchain and `libclang-dev` for RocksDB, and `rustup`, after which the repository's `rust-toolchain.toml` selects the compiler. It builds a native release binary in `~/git/amaru` with the same features as the official releases. Expect 20 to 60 minutes and several GB of disk; with less than 8 GB of memory, add swap. The build log is `~/tmp/amaru-build.log`.

Nightly and source builds report a version such as `10.11.0`, with `0` where a release has its date. The scripts accept these without `STRICT_VERSION_CHECK="N"`.

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

1. Checks the network, role (relay or block producer), binaries, free disk space, clock synchronisation and Koios. A mainnet block producer is refused with an Amaru release before 10.11.20261105.
2. Shows the translated peers and lists the enabled `cnode-*` services that need cardano-node.
3. Builds the Amaru databases while cardano-node keeps running. This takes extra RAM and disk for its duration.
4. Disables the incompatible services, sets `NODE_IMPL="amaru"`, redeploys the systemd units and restarts `cnode`. This is the only downtime.
5. Waits until Amaru's tip advances and is within `VERIFY_MAX_LAG` slots of the Koios tip. If that does not happen within `VERIFY_TIMEOUT`, it rolls back automatically.

`./migrate-amaru.sh -r` switches back to cardano-node and re-enables the services the migration disabled. Each run logs to `${LOG_DIR}/migrate-amaru_<timestamp>.log`, and the previous `env` is kept in `scripts/archive`.
