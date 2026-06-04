#!/usr/bin/env bash
#
# TAPPaaS coturn TURN Service - Install
#
# Verifies the coturn STUN/TURN server is reachable on port 3478
# before dependent modules (nextcloud-hpb) install.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
readonly CONFIG_DIR="/home/tappaas/config"
readonly COTURN_JSON="${CONFIG_DIR}/coturn.json"

VMNAME=$(jq -r '.vmname' "${COTURN_JSON}")
ZONE=$(jq -r '.zone0' "${COTURN_JSON}")

info "coturn:turn install-service — verifying coturn STUN/TURN is reachable for module: ${MODULE}"

if nc -z -w5 "${VMNAME}.${ZONE}.internal" 3478 2>/dev/null; then
    info "${GN}✓${CL} coturn STUN/TURN is reachable at ${VMNAME}.${ZONE}.internal:3478"
else
    die "coturn is not responding on port 3478 — ensure the coturn module is fully installed"
fi
