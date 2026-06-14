#!/usr/bin/env bash
#
# setup-api-key.sh — capture, validate, and store a UniFi OS Server API key
# for ADR-008 Stage 5 (the unifi.sh switch/ap-manager plugin).
#
# Run this AFTER first-run owner setup. UniFi OS API keys can only be CREATED in
# the web UI (Settings -> Control Plane -> Integrations -> Create API Key) — there
# is no programmatic create endpoint — so this script captures the key you just
# generated, validates it against the official Network Integration API
# (GET /proxy/network/integration/v1/sites, X-API-KEY), and stores it (chmod 600)
# in the credentials file the Stage-5 plugin reads. Re-run anytime to rotate/verify.
#
# Usage:
#   setup-api-key.sh [--url <https://unifi-os.<domain>>] [--key <APIKEY>] [--cred <file>]
#     --key   omitted -> prompted (hidden input)
#     --url   omitted -> read from the cred file's url=, else prompted
#     --cred  default: /home/tappaas/.unifi-os-credentials.txt
#

set -euo pipefail

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh   # info/warn/error/die + colors

CRED="/home/tappaas/.unifi-os-credentials.txt"
URL=""
KEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)  URL="$2"; shift 2 ;;
        --key)  KEY="$2"; shift 2 ;;
        --cred) CRED="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# Resolve URL: arg → cred file → prompt.
if [[ -z "${URL}" && -f "${CRED}" ]]; then
    URL="$(awk -F= '/^url=/{sub(/^url=/,""); print; exit}' "${CRED}" || true)"
fi
if [[ -z "${URL}" ]]; then
    read -rp "UniFi OS URL (e.g. https://unifi-os.<domain>): " URL
fi
URL="${URL%/}"
[[ -n "${URL}" ]] || die "no UniFi OS URL provided"

# Capture the API key (hidden) if not supplied.
if [[ -z "${KEY}" ]]; then
    echo "Generate a key first in the UI:"
    echo "  ${BOLD}${URL}${CL} -> Settings -> Control Plane -> Integrations -> Create API Key"
    echo "(the key is shown once; copy it now)"
    read -rsp "Paste the UniFi OS API key: " KEY
    echo
fi
[[ -n "${KEY}" ]] || die "no API key provided"

# Validate against the official Network Integration API (v9.3+).
ENDPOINT="${URL}/proxy/network/integration/v1/sites"
info "Validating the key against ${ENDPOINT} ..."
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
CODE="$(curl -sk -m 20 -o "${TMP}" -w '%{http_code}' \
    -H "X-API-KEY: ${KEY}" -H "Accept: application/json" "${ENDPOINT}" 2>/dev/null || echo 000)"

case "${CODE}" in
    200)
        SITES="$(jq -r '(.data // .)[]? | (.name // .desc // .id) ' "${TMP}" 2>/dev/null | paste -sd, - || true)"
        info "  ${GN}✓${CL} API key valid (sites: ${SITES:-default})"
        ;;
    401|403)
        die "API key rejected (HTTP ${CODE}). Re-generate it in the UI and try again." ;;
    404)
        die "Integration API not found (HTTP 404) at ${ENDPOINT} — the bundled UniFi Network may be older than v9.3, or the path is wrong." ;;
    000)
        die "Could not reach ${URL} from this host. Check DNS for the friendly name and that tappaas-cicd is in an allowed zone (mgmt/home/work)." ;;
    *)
        die "Unexpected response (HTTP ${CODE}) validating the key against ${ENDPOINT}." ;;
esac

# Store (refresh the file atomically, 0600).
umask 077
cat > "${CRED}" <<EOF
# UniFi OS Server API credentials for TAPPaaS (ADR-008 Stage 5 unifi.sh).
# Written by setup-api-key.sh after validating against the Network Integration API.
url=${URL}
apikey=${KEY}
EOF
chmod 600 "${CRED}"
info "${GN}✓${CL} stored validated API key in ${BOLD}${CRED}${CL} (chmod 600)"
info "  Stage-5 unifi.sh will use: ${BOLD}X-API-KEY${CL} against ${URL}/proxy/network/integration/v1/"
