#!/usr/bin/env bash
# Publishes a synthetic Sev1 alert payload to the critical-alerts Event Hub.
# Requires: az CLI logged in + jq + curl. The Function then normalizes it,
# Application Insights ingests it, and the scheduled query alert fires within
# the next 5-minute evaluation window.
set -euo pipefail

RG="${RG:-rg-critical-alerting-pilot}"
NAMESPACE="${NAMESPACE:-}"  # auto-discovered if blank
HUB="${HUB:-critical-alerts}"
AUTH_RULE="${AUTH_RULE:-RootManageSharedAccessKey}"
SEVERITY="${SEVERITY:-Sev1}"

if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE=$(az eventhubs namespace list -g "${RG}" --query "[0].name" -o tsv)
fi
if [[ -z "${NAMESPACE}" ]]; then
  echo "Could not find an Event Hubs namespace in ${RG}" >&2
  exit 1
fi

CONN=$(az eventhubs namespace authorization-rule keys list \
  -g "${RG}" --namespace-name "${NAMESPACE}" \
  --name "${AUTH_RULE}" --query primaryConnectionString -o tsv)

# Parse SAS components.
SB_KEYNAME=$(awk -F'SharedAccessKeyName=' '{print $2}' <<<"${CONN}" | awk -F';' '{print $1}')
SB_KEY=$(awk -F'SharedAccessKey=' '{print $2}' <<<"${CONN}" | awk -F';' '{print $1}')
SB_HOST=$(awk -F'Endpoint=sb://' '{print $2}' <<<"${CONN}" | awk -F'/' '{print $1}')

EXPIRY=$(( $(date -u +%s) + 600 ))
URI="https://${SB_HOST}/${HUB}/messages"
ENCODED_URI=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote_plus(sys.argv[1]))" "https://${SB_HOST}/${HUB}")
STRING_TO_SIGN="${ENCODED_URI}\n${EXPIRY}"
SIGNATURE=$(printf "${STRING_TO_SIGN}" | openssl dgst -sha256 -hmac "${SB_KEY}" -binary | base64)
ENCODED_SIG=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote_plus(sys.argv[1]))" "${SIGNATURE}")
SAS="SharedAccessSignature sr=${ENCODED_URI}&sig=${ENCODED_SIG}&se=${EXPIRY}&skn=${SB_KEYNAME}"

NOW_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PAYLOAD=$(cat <<JSON
{
  "source": "nightly-batch-scheduler",
  "application": "OrdersPipeline",
  "severity": "${SEVERITY}",
  "summary": "Nightly batch job failed",
  "details": "Job 'NightlyOrdersETL' failed at ${NOW_UTC}. Last successful run > 24h ago. Immediate review required.",
  "incidentId": "INC$(date -u +%s)",
  "ownerGroup": "Production Support",
  "eventTimeUtc": "${NOW_UTC}",
  "dedupeKey": "OrdersPipeline:BatchFailure:${SEVERITY}"
}
JSON
)

echo "==> Publishing ${SEVERITY} test event to ${NAMESPACE}/${HUB}"
echo "${PAYLOAD}" | jq .

curl -sS -X POST "${URI}" \
  -H "Authorization: ${SAS}" \
  -H "Content-Type: application/atom+xml;type=entry;charset=utf-8" \
  -H "BrokerProperties: {\"PartitionKey\":\"OrdersPipeline\"}" \
  --data "${PAYLOAD}" \
  --fail-with-body

echo
echo "==> Event published. Watch the Function logs and Action Group delivery."
