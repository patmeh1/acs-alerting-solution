#!/usr/bin/env bash
# End-to-end smoke test: ring the on-call Action Group directly without going
# through the alert rule. Use during pilot to confirm SMS + voice delivery for
# every recipient and country code before connecting real signal sources.
set -euo pipefail

RG="${RG:-rg-af-critical-alerting-pilot}"
AG_NAME="${AG_NAME:-afalert-ag-sev1}"
RECEIVERS=("${@:-Email Sms Voice AzureAppPush}")

AG_ID=$(az monitor action-group show -g "${RG}" -n "${AG_NAME}" --query id -o tsv)
if [[ -z "${AG_ID}" ]]; then
  echo "Action group ${AG_NAME} not found in ${RG}" >&2
  exit 1
fi

for r in "${RECEIVERS[@]}"; do
  echo "==> Triggering test notification for receiver type: ${r}"
  az rest \
    --method post \
    --uri "https://management.azure.com${AG_ID}/createNotifications?api-version=2024-10-01-preview" \
    --body "$(jq -nc \
      --arg note 'AF Group critical alerting pilot test - please ignore.' \
      --arg r "${r}" \
      '{alertType:"servicehealth", notificationName:"afalert-pilot-test", receivers:[{name:("test-"+($r|ascii_downcase)), receiverType:$r}], properties:{note:$note}}'
    )" \
    --output jsonc
  sleep 2
done

echo "==> Test notifications queued. Confirm receipt on each channel."
