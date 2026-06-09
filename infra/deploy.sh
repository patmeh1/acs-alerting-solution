#!/usr/bin/env bash
# One-shot deploy for the critical alerting pilot.
# Edit main.parameters.json (or pass --parameters overrides) before running.
set -euo pipefail

LOCATION="${LOCATION:-eastus}"
RG="${RG:-rg-critical-alerting-pilot}"
DEPLOYMENT_NAME="oncall-$(date -u +%Y%m%d-%H%M%S)"

echo "==> Ensuring resource group ${RG} in ${LOCATION}"
az group create --name "${RG}" --location "${LOCATION}" --output none

echo "==> Validating Bicep"
az deployment group validate \
  --resource-group "${RG}" \
  --template-file "$(dirname "$0")/main.bicep" \
  --parameters "@$(dirname "$0")/main.parameters.json" \
  --output none

echo "==> Submitting deployment ${DEPLOYMENT_NAME}"
az deployment group create \
  --name "${DEPLOYMENT_NAME}" \
  --resource-group "${RG}" \
  --template-file "$(dirname "$0")/main.bicep" \
  --parameters "@$(dirname "$0")/main.parameters.json" \
  --output table

echo "==> Outputs"
az deployment group show \
  --resource-group "${RG}" \
  --name "${DEPLOYMENT_NAME}" \
  --query properties.outputs \
  --output jsonc
