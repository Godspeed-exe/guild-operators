#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2154
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#VERIFY_TIMEOUT=1800      # Seconds to wait after the switch for Amaru to follow the chain before rolling back
#VERIFY_MAX_LAG=600       # Maximum allowed distance, in slots, between Amaru's tip and the Koios tip
#MIN_FREE_GB_MAINNET=80   # Free disk space required in AMARU_HOME for mainnet (cardano-node db/ is kept for rollback)
#MIN_FREE_GB_TESTNET=15   # Free disk space required in AMARU_HOME for preprod/preview

######################################
# Do NOT modify code below           #
######################################

usage() {
  cat <<-EOF

		Usage: $(basename "$0") [-c] [-y] [-r [-p]]

		Migrate this cnode (relay or block producer) from cardano-node to Amaru, or back.
		cardano-node's db/ is kept, so a rollback is a restart, not a resync.

		-c    Check only: run the preflight checks and show what the migration would change
		-y    Do not prompt for confirmation
		-r    Roll back to cardano-node
		-p    With -r: also delete the Amaru databases in AMARU_HOME

		EOF
  exit 1
}

log() {
  echo -e "$*" | tee -a "${MIGRATE_LOG}"
}

die() {
  log "${FG_RED}ERROR${NC}: $*"
  exit 1
}

confirm() {
  [[ ${ASSUME_YES} = "Y" ]] && return 0
  getAnswer "$1"
}

# Set the NODE_IMPL user variable, only ever touching the user-variable section above "# Do NOT modify"
set_node_impl() {
  local env_file="${PARENT}"/env user_end at
  user_end=$(grep -n '^# Do NOT modify' "${env_file}" | head -1 | cut -d: -f1)
  [[ -n ${user_end} ]] || { log "  ${FG_RED}No user-variable section found in ${env_file}${NC}"; return 1; }
  cp -f "${env_file}" "${PARENT}/archive/env_bkp$(date +%s)"
  if head -n "${user_end}" "${env_file}" | grep -qE '^#?NODE_IMPL="[a-z-]*"'; then
    sed -i "1,${user_end}s|^#\?NODE_IMPL=\"[a-z-]*\"|NODE_IMPL=\"$1\"|" "${env_file}"
  else
    # env from before NODE_IMPL existed: add the variable next to CNODEBIN, or at the end of the user section
    at=$(head -n "${user_end}" "${env_file}" | grep -n '^#\?CNODEBIN=' | head -1 | cut -d: -f1)
    [[ -z ${at} ]] && at=$(( user_end - 1 ))
    sed -i "${at}i NODE_IMPL=\"$1\"                               # Node implementation run by cnode.sh: cardano-node | amaru" "${env_file}"
  fi
  if ! head -n "$(( user_end + 1 ))" "${env_file}" | grep -q "^NODE_IMPL=\"$1\""; then
    log "  ${FG_RED}Could not set NODE_IMPL=\"$1\" in ${env_file}${NC}"; return 1
  fi
  unset NODE_IMPL CNODEBIN
  . "${env_file}" offline >/dev/null || { log "  ${FG_RED}env failed to load after setting NODE_IMPL=$1${NC}"; return 1; }
  log "  NODE_IMPL=\"$1\" set in ${env_file} (previous env archived in ${PARENT}/archive)"
}

# Services next to cnode that need cardano-node's socket, database or logs, and so stop working with Amaru
incompatible_units() {
  systemctl list-unit-files "${CNODE_VNAME}-*.service" --state=enabled --no-legend 2>/dev/null | awk '{print $1}' \
    | grep -E -- '-(dbsync|ogmios|submit-?api|mithril-signer|logmonitor|tu-blockperf)\.service$' || true
}

preflight() {
  local free_gb need_gb ntp
  log "\n${FG_LBLUE}== Preflight${NC}"
  log "  Network         : ${NETWORK_NAME} ($(amaru_network))"
  amaru_is_block_producer && ROLE="bp" || ROLE="relay"
  log "  Role            : ${ROLE} $([[ ${ROLE} = bp ]] && echo "(pool keys found in ${POOL_DIR})")"
  if [[ ${ROLE} = "bp" ]] && ! amaru_forging_supported; then
    die "Amaru does not support block production on mainnet yet. Keep this block producer on cardano-node; relays can migrate."
  fi
  [[ $(uname -m) = "x86_64" || $(uname -m) = "aarch64" ]] || die "Amaru releases are only published for x86_64 and aarch64, found $(uname -m)."

  AMARUBIN=$(command -v amaru || echo "${HOME}/.local/bin/amaru")
  [[ -x ${AMARUBIN} ]] || die "amaru binary not found, please run: guild-deploy.sh -s a"
  [[ ${STRICT_VERSION_CHECK} = N ]] || versionCheck "${AMARU_MIN_VERSION}" "$("${AMARUBIN}" --version | head -1 | cut -d' ' -f2)" \
    || die "amaru >= ${AMARU_MIN_VERSION} is required, please run: guild-deploy.sh -s a"
  command -v otelcol &>/dev/null || [[ -x "${HOME}/.local/bin/otelcol" ]] || die "otelcol binary not found, please run: guild-deploy.sh -s a"
  log "  Amaru           : $("${AMARUBIN}" --version | head -1)"

  mkdir -p "${AMARU_HOME}" || die "Could not create ${AMARU_HOME}"
  free_gb=$(( $(df -Pk "${AMARU_HOME}" | awk 'NR==2 {print $4}') / 1048576 ))
  [[ $(amaru_network) = "mainnet" ]] && need_gb=${MIN_FREE_GB_MAINNET} || need_gb=${MIN_FREE_GB_TESTNET}
  if [[ ! -d "$(amaru_db_ledger)" && ${free_gb} -lt ${need_gb} ]]; then
    die "Only ${free_gb} GB free in ${AMARU_HOME}, at least ${need_gb} GB is needed (cardano-node db/ is kept for rollback)."
  fi
  log "  Free disk       : ${free_gb} GB in ${AMARU_HOME}"

  ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  [[ ${ntp} = "yes" ]] && log "  Clock           : NTP synchronised" || log "  ${FG_YELLOW}Clock           : NTP synchronisation not confirmed; forging and peer selection need an accurate clock${NC}"

  [[ -n ${KOIOS_API} ]] || die "Koios is required with Amaru (no node.socket for local queries), please set ENABLE_KOIOS=Y in env."
  KOIOS_TIP=$(curl -sf -m 10 "${KOIOS_API_HEADERS[@]}" "${KOIOS_API}/tip" | jq -r '.[0].abs_slot // empty')
  [[ -n ${KOIOS_TIP} ]] || die "Could not reach Koios at ${KOIOS_API}."
  log "  Koios tip slot  : ${KOIOS_TIP}"
}

impact_report() {
  log "\n${FG_LBLUE}== What changes${NC}"
  amaru_translate_topology "${TOPOLOGY}" "${ROLE}" || die "Could not translate ${TOPOLOGY}"
  log "  cnode.service will run 'amaru node run' instead of cardano-node, on the same port ${CNODE_PORT}"
  log "  Peers from ${TOPOLOGY}: ${AMARU_TOPO_PEERS//,/ }"
  log "  Peer mix        : ${AMARU_TOPO_MIX} (max upstream ${AMARU_TOPO_MAX_UPSTREAM}${AMARU_TOPO_MAX_DOWNSTREAM:+, max downstream ${AMARU_TOPO_MAX_DOWNSTREAM}})"
  for w in "${AMARU_TOPO_WARNINGS[@]}"; do log "  ${FG_YELLOW}Note${NC}: ${w}"; done
  log "  Metrics move to OTLP; ${CNODE_VNAME}-otelcol.service serves them on ${PROM_HOST}:${PROM_PORT} as before"
  log "  There is no node.socket: cardano-cli queries, CNTools online mode and other socket users switch to Koios or stop working"
  INCOMPATIBLE=$(incompatible_units)
  if [[ -n ${INCOMPATIBLE} ]]; then
    log "  ${FG_YELLOW}These services need cardano-node and will be stopped and disabled (re-enabled on rollback):${NC}"
    for u in ${INCOMPATIBLE}; do log "    - ${u}"; done
  fi
  [[ ${ROLE} = "bp" ]] && log "  Block production continues with ${POOL_DIR}/{${POOL_HOTKEY_SK_FILENAME},${POOL_VRF_SK_FILENAME},${POOL_OPCERT_FILENAME}}"
  log "  Kept for rollback: ${DB_DIR}"
}

# Echo the slot of Amaru's tip from the metrics endpoint (empty if not available)
amaru_tip_slot() {
  getNodeMetrics
  [[ ${slotnum} -gt 0 ]] && echo "${slotnum}"
}

verify() {
  local deadline first="" slot koios
  log "\n${FG_LBLUE}== Verifying Amaru follows the chain${NC} (timeout ${VERIFY_TIMEOUT}s)"
  deadline=$(( $(date +%s) + VERIFY_TIMEOUT ))
  while [[ $(date +%s) -lt ${deadline} ]]; do
    sleep 15
    if ! systemctl is-active -q "${CNODE_VNAME}.service"; then
      log "  ${FG_RED}${CNODE_VNAME}.service is not running${NC}"
      journalctl -u "${CNODE_VNAME}.service" -n 15 --no-pager | tee -a "${MIGRATE_LOG}"
      return 1
    fi
    slot=$(amaru_tip_slot)
    koios=$(curl -sf -m 10 "${KOIOS_API_HEADERS[@]}" "${KOIOS_API}/tip" | jq -r '.[0].abs_slot // empty')
    [[ -z ${slot} || -z ${koios} ]] && { log "  waiting for metrics on ${PROM_HOST}:${PROM_PORT}.."; continue; }
    [[ -z ${first} ]] && first=${slot}
    log "  tip slot ${slot} (koios ${koios}, behind $(( koios - slot )))"
    if [[ ${slot} -gt ${first} && $(( koios - slot )) -le ${VERIFY_MAX_LAG} ]]; then
      log "  ${FG_GREEN}Amaru is following the chain${NC}"
      if [[ ${ROLE} = "bp" ]]; then
        getNodeMetrics # amaru_tip_slot ran in a subshell, so its metric variables are gone
        log "  KES period ${kesperiod:-?}, forging with ${POOL_DIR}/${POOL_OPCERT_FILENAME}"
      fi
      return 0
    fi
  done
  log "  ${FG_RED}Amaru did not reach the tip within ${VERIFY_TIMEOUT}s${NC}"
  return 1
}

# Returns 1 on any failure; callers must then roll back so the node is never left stopped
switch_to() {
  local impl=$1
  log "  Stopping ${CNODE_VNAME}.service"
  sudo systemctl stop "${CNODE_VNAME}.service"
  set_node_impl "${impl}" || return 1
  if [[ ${impl} = "amaru" ]]; then
    . "${PARENT}"/amaru.library
  elif systemctl list-unit-files "${CNODE_VNAME}-otelcol.service" --no-legend 2>/dev/null | grep -q .; then
    sudo systemctl disable --now "${CNODE_VNAME}-otelcol.service" 2>/dev/null
  fi
  "${PARENT}"/cnode.sh -d >>"${MIGRATE_LOG}" 2>&1 || { log "  ${FG_RED}cnode.sh -d failed, see ${MIGRATE_LOG}${NC}"; return 1; }
  log "  Starting ${CNODE_VNAME}.service with ${impl}"
  sudo systemctl start "${CNODE_VNAME}.service"
}

rollback() {
  log "\n${FG_LBLUE}== Rolling back to cardano-node${NC}"
  if ! switch_to "cardano-node"; then
    # Last resort: whatever is configured, do not leave the node stopped
    sudo systemctl start "${CNODE_VNAME}.service"
    die "Rollback could not fully restore cardano-node, please check ${PARENT}/env (NODE_IMPL) and ${MIGRATE_LOG}"
  fi
  if [[ -f ${STATE_FILE} ]]; then
    for u in $(cat "${STATE_FILE}"); do
      log "  Re-enabling ${u}"
      sudo systemctl enable --now "${u}" 2>/dev/null
    done
    rm -f "${STATE_FILE}"
  fi
  if [[ ${PURGE} = "Y" ]]; then
    log "  Deleting Amaru databases in ${AMARU_HOME}"
    rm -rf "$(amaru_db_chain)" "$(amaru_db_ledger)" "${AMARU_HOME}"/mithril-snapshots "${AMARU_HOME}"/snapshots
  fi
  log "  ${FG_GREEN}cardano-node is back in charge of ${CNODE_VNAME}.service${NC}"
}

migrate() {
  preflight
  impact_report
  [[ ${CHECK_ONLY} = "Y" ]] && { log "\nCheck only (-c): nothing was changed."; exit 0; }
  confirm "\nMigrate this ${ROLE} to Amaru?" || { log "Aborted, nothing was changed."; exit 0; }

  log "\n${FG_LBLUE}== Preparing Amaru databases${NC} (cardano-node keeps running meanwhile)"
  CNODEBIN=${AMARUBIN} amaru_prepare_db 2>&1 | tee -a "${MIGRATE_LOG}" | grep --line-buffered -E 'INFO: |ERROR|progress.complete|epoch_transition.apply close' | sed -u -E 's/.*(epoch=[0-9]+).*/  ledger at \1/' | uniq
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Preparing the Amaru databases failed, see ${MIGRATE_LOG}. Nothing else was changed."

  log "\n${FG_LBLUE}== Switching ${CNODE_VNAME}.service to Amaru${NC}"
  : > "${STATE_FILE}"
  for u in ${INCOMPATIBLE}; do
    log "  Disabling ${u}"
    sudo systemctl disable --now "${u}" && echo "${u}" >> "${STATE_FILE}"
  done
  if switch_to "amaru" && verify; then
    log "\n${FG_GREEN}Migration complete.${NC} Roll back any time with: $(basename "$0") -r"
    log "Log: ${MIGRATE_LOG}"
  else
    rollback
    die "Migration verification failed and was rolled back, see ${MIGRATE_LOG}"
  fi
}

###################
# Execution       #
###################

while getopts :cyrp opt; do
  case ${opt} in
    c ) CHECK_ONLY="Y" ;;
    y ) ASSUME_YES="Y" ;;
    r ) ROLLBACK="Y" ;;
    p ) PURGE="Y" ;;
    \? ) usage ;;
  esac
done
[[ ${PURGE} = "Y" && ${ROLLBACK} != "Y" ]] && usage

[[ ${0} != '-bash' ]] && PARENT="$(dirname $0)" || PARENT="$(pwd)"
[[ ! -f "${PARENT}"/env ]] && echo -e "\nCommon env file missing in \"${PARENT}\", please ensure latest guild-deploy.sh was run and this script is being run from ${CNODE_HOME}/scripts folder!\n" && exit 1
. "${PARENT}"/env offline
case $? in
  1) echo -e "ERROR: Failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" && exit 1;;
  2) clear ;;
esac
[[ ! -f "${PARENT}"/amaru.library ]] && echo -e "\namaru.library missing in \"${PARENT}\", please ensure latest guild-deploy.sh was run!\n" && exit 1
. "${PARENT}"/amaru.library

[[ -z ${VERIFY_TIMEOUT} ]] && VERIFY_TIMEOUT=1800
[[ -z ${VERIFY_MAX_LAG} ]] && VERIFY_MAX_LAG=600
[[ -z ${MIN_FREE_GB_MAINNET} ]] && MIN_FREE_GB_MAINNET=80
[[ -z ${MIN_FREE_GB_TESTNET} ]] && MIN_FREE_GB_TESTNET=15
STATE_FILE="${AMARU_HOME}/migrate-disabled-units"
mkdir -p "${LOG_DIR}" "${PARENT}"/archive
MIGRATE_LOG="${LOG_DIR}/migrate-amaru_$(date +%Y%m%d%H%M%S).log"

if [[ ${ROLLBACK} = "Y" ]]; then
  [[ ${NODE_IMPL} = "amaru" ]] || log "NODE_IMPL is already ${NODE_IMPL}; making sure cardano-node runs."
  confirm "Roll back ${CNODE_VNAME}.service to cardano-node?" || exit 0
  rollback
else
  [[ ${NODE_IMPL} = "amaru" ]] && die "This cnode already runs Amaru (NODE_IMPL=amaru in env). Use -r to roll back."
  migrate
fi
