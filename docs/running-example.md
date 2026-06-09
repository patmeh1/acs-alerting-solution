# Running example — end-to-end pilot

A 30-minute walkthrough that deploys the Bicep template, sends a synthetic
Sev1 event, and confirms SMS + voice + email + push notifications fire.

## Prerequisites

* Azure subscription with Owner or Contributor on a resource group you
  control. The Bicep is scoped to a resource group.
* Azure CLI 2.60 or later, logged in (`az login`) and pointed at the right
  subscription (`az account set --subscription <name-or-id>`).
* A real on-call email address and a phone number you can answer.
* (Optional) A Microsoft Teams Incoming Webhook URL for a "Production
  Support" channel.

## 1. Clone and configure

```bash
git clone https://github.com/patmeh1/acs-alerting-solution.git
cd acs-alerting-solution

# Edit the parameters file with your email and phone before deploying.
$EDITOR infra/main.parameters.json
```

Set at minimum:

* `oncallEmail`
* `oncallPhoneCountryCode` and `oncallPhoneNumber`
* (optional) `teamsWebhookUrl`

## 2. Deploy the infrastructure

```bash
export RG=rg-critical-alerting-pilot
export LOCATION=eastus

# Wraps az group create + az deployment group create.
./infra/deploy.sh
```

Expected wall-clock time: **~6 minutes** for a cold deployment in East US.

The deployment outputs the Function App name, the Event Hubs namespace, the
Action Group resource id, and the Log Analytics workspace id. Capture them:

```bash
DEPLOY_NAME=$(az deployment group list -g "$RG" --query "[0].name" -o tsv)
az deployment group show -g "$RG" -n "$DEPLOY_NAME" \
  --query properties.outputs -o jsonc
```

## 3. Publish the Function code

```bash
cd scripts/normalize_alert

# Install Functions Core Tools v4 first if you do not already have it.
# https://learn.microsoft.com/azure/azure-functions/functions-run-local

FUNC_NAME=$(az deployment group show -g "$RG" -n "$DEPLOY_NAME" \
  --query properties.outputs.functionAppName.value -o tsv)

func azure functionapp publish "$FUNC_NAME" --python
cd -
```

## 4. Smoke-test the Action Group directly

Confirms every channel (SMS, voice, email, push) reaches the on-call.

```bash
./scripts/test-action-group.sh Email Sms Voice AzureAppPush
```

Expect within ~60 seconds:

* An email titled "Azure Monitor test notification".
* An SMS reading "Azure Monitor test notification".
* A phone call from a Microsoft-managed caller ID announcing a test alert.
* A push notification in the Azure mobile app.

Reject any channel that does not arrive — the cause is almost always a
mistyped country code, a wrong phone number, or a recipient who has not yet
opted into Azure mobile push.

## 5. Send a synthetic Sev1 event

```bash
# Bash + curl + openssl version
./scripts/send-test-event.sh

# Python version (uses DefaultAzureCredential)
export EVENTHUB_NAMESPACE=$(az deployment group show -g "$RG" -n "$DEPLOY_NAME" \
  --query properties.outputs.eventHubNamespace.value -o tsv)
python scripts/send-test-event.py --severity Sev1 --count 1
```

Watch what happens:

1. **t+0s** — Event Hub receives the JSON payload.
2. **t+~2s** — The Function trigger fires, the normalizer logs a
   `CRITICAL_ALERT` line, and the normalized record streams into Application
   Insights / Log Analytics.
3. **t+0–5m** — The scheduled query alert rule evaluates the window and fires
   because at least one `Severity_s == "Sev1"` record was ingested.
4. **t+~5–10m** — The Action Group fans out: SMS + voice + email + push, with
   an optional Teams card if a webhook was configured.

You can shorten step 3 by lowering `evaluationFrequency` to `PT1M`, but doing
so costs more per rule and is unnecessary for production volumes.

## 6. Verify in Azure Monitor

```bash
# Tail the function logs.
az functionapp log tail -g "$RG" -n "$FUNC_NAME"

# Confirm the alert rule fired.
az monitor scheduled-query show -g "$RG" -n oncall-ar-sev1-critical \
  --query "lastUpdatedTime"

# Confirm the action group ran.
az monitor activity-log list \
  --resource-id "$(az monitor action-group show -g "$RG" -n oncall-ag-sev1 --query id -o tsv)" \
  --offset 1h --query "[?operationName.value=='Microsoft.Insights/actionGroups/Notifications/action'].{time:eventTimestamp, status:status.value}" \
  -o table
```

## 7. Send a duplicate event to confirm deduplication

```bash
./scripts/send-test-event.sh
./scripts/send-test-event.sh
./scripts/send-test-event.sh
```

The alert rule should fire **once** per evaluation window even though three
events were published, because the KQL summarizes by `DedupeKey_s`.

## 8. Tear down when you are done

```bash
az group delete -g "$RG" --yes --no-wait
```

## Expected timing diagram

```
Event Hub  ─►  Function normalizer  ─►  App Insights  ─►  LAW (AlertEvents_CL)
   ▲                  │ ~2 s                 │
   │                  ▼                       ▼
synth event      log "CRITICAL_ALERT"    Scheduled-query alert
   │                                         │  evaluates every 5 m
   │                                         ▼
   │                                   Action Group
   │              ┌──────┬──────┬──────┬──────┐
   │              ▼      ▼      ▼      ▼      ▼
   │             SMS   Voice   Email  Push   Teams (webhook)
   │
end-to-end SLO  ≤  10 minutes from event to on-call ring
```

## Common pitfalls

* **SMS / voice silence.** Check `oncallPhoneCountryCode` (`1` for US/Canada,
  no leading `+`). Confirm the receiving carrier is not silently blocking
  short-code SMS from Microsoft's notification pool.
* **Alert never fires.** Confirm `AlertEvents_CL` exists. If you are using
  Application Insights `customEvents` instead, update the KQL in the alert
  rule and `scripts/kql/sev1-alert-query.kql`.
* **Storm of voice calls.** You probably skipped the dedupe `summarize`.
  Re-apply the KQL from `scripts/kql/sev1-alert-query.kql`.
* **Bicep validation fails on the Action Group SMS / Voice receivers.**
  Newer API versions tighten phone number validation. Make sure
  `oncallPhoneNumber` contains only digits and matches the country format.
