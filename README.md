# AF Group critical alerting — Microsoft-native alternative to VTEXT and ACS SMS

A reference design and deployable pilot for replacing AF Group's VTEXT
email-to-SMS on-call alerting with built-in Azure services.

The recommended stack — **Azure Monitor Action Groups** for SMS, voice,
email, and Azure mobile push; **Logic Apps**, **Azure Functions**, and
**Event Hubs** for ingestion and normalization; **Log Analytics** and
**Application Insights** for evaluation and audit — avoids both the
deprecated carrier email-to-SMS gateways and the announced retirement of
Azure Communication Services SMS.

> **ACS retirement context:** Microsoft announced ACS retirement on
> **22 July 2026** with full retirement on **31 July 2028**
> ([retirement and breaking changes guide](https://review.learn.microsoft.com/en-us/azure/communication-services/acs-retirement-and-breaking-changes-guide?branch=pr-en-us-307749)).
> This solution treats ACS SMS as transitional only and centres on Azure
> Monitor Action Groups, which use Microsoft's own notification network and
> are not part of the ACS retirement scope.

## What is in this repo

| Path | Purpose |
| --- | --- |
| [`index.html`](index.html) | GitHub Pages site rendered at <https://patmeh1.github.io/acs-alerting-solution/> |
| [`infra/main.bicep`](infra/main.bicep) | Single-file Bicep that deploys Log Analytics, App Insights, Storage, Function App (Python 3.11 consumption), Event Hubs (Standard), Action Group (email + SMS + voice + push + optional Teams webhook), and the Sev1 scheduled-query alert rule. |
| [`infra/main.parameters.json`](infra/main.parameters.json) | Sample parameters. Edit `oncallEmail`, `oncallPhoneCountryCode`, `oncallPhoneNumber`, and optionally `teamsWebhookUrl` before deploying. |
| [`infra/deploy.sh`](infra/deploy.sh) | Convenience wrapper around `az group create` + `az deployment group create`. |
| [`scripts/normalize_alert/`](scripts/normalize_alert/) | Python v2 Function App with both an Event Hub trigger and a manual HTTP-trigger test endpoint. |
| [`scripts/send-test-event.sh`](scripts/send-test-event.sh) | Bash + `openssl` script that publishes a synthetic Sev1 event to the Event Hub via SAS. |
| [`scripts/send-test-event.py`](scripts/send-test-event.py) | Python equivalent that uses `DefaultAzureCredential`. |
| [`scripts/test-action-group.sh`](scripts/test-action-group.sh) | Calls `Microsoft.Insights/actionGroups/createNotifications` to ring every channel directly, without going through the alert rule. |
| [`scripts/logic-app-mailbox-monitor.json`](scripts/logic-app-mailbox-monitor.json) | Logic App workflow definition that watches a shared mailbox, builds a normalized alert, and forwards it to the Event Hub. |
| [`scripts/teams-adaptive-card.json`](scripts/teams-adaptive-card.json) | Adaptive Card payload for the Teams webhook receiver. |
| [`scripts/kql/sev1-alert-query.kql`](scripts/kql/sev1-alert-query.kql) | KQL backing the scheduled query alert rule. |
| [`scripts/kql/alert-delivery-audit.kql`](scripts/kql/alert-delivery-audit.kql) | Dashboard query joining alert events with Action Group delivery diagnostics. |
| [`docs/af-group-use-case.md`](docs/af-group-use-case.md) | Long-form writeup of the AF Group VTEXT problem and the recommended solution. |
| [`docs/running-example.md`](docs/running-example.md) | End-to-end pilot walkthrough — deploy, smoke test, send synthetic events, tear down. |
| [`docs/cost-estimate.md`](docs/cost-estimate.md) | Pilot and production cost estimates pulled from the Azure Pricing Calculator with per-line workings. |

## Quick start

```bash
git clone https://github.com/patmeh1/acs-alerting-solution.git
cd acs-alerting-solution

# 1. Edit the parameters file with a real on-call email and phone number.
$EDITOR infra/main.parameters.json

# 2. Deploy the pilot infrastructure.
export RG=rg-af-critical-alerting-pilot
export LOCATION=eastus
./infra/deploy.sh

# 3. Publish the Function code (requires Functions Core Tools v4).
cd scripts/normalize_alert
FUNC_NAME=$(az functionapp list -g "$RG" --query "[0].name" -o tsv)
func azure functionapp publish "$FUNC_NAME" --python
cd -

# 4. Ring every notification channel to confirm delivery.
./scripts/test-action-group.sh Email Sms Voice AzureAppPush

# 5. Send a synthetic Sev1 event and watch the on-call get paged.
./scripts/send-test-event.sh
```

Step-by-step walk-through with expected outputs and timing diagram lives in
[`docs/running-example.md`](docs/running-example.md).

## Estimated cost

Detailed line-item breakdown in [`docs/cost-estimate.md`](docs/cost-estimate.md).
Approximate monthly figures (East US, list price, mid-2026):

| Profile | Sev1 alerts / month | Approx. monthly cost (USD) |
| --- | --- | --- |
| **Pilot** | 50 | **≈ $31** |
| **Production** | 500 | **≈ $135** |

## Why not ACS SMS or Twilio

* **ACS SMS** is in the retirement scope; not a target architecture for a
  net-new build. See the retirement guide linked at the top of this README.
* **Twilio** was explicitly excluded from the request. Action Groups cover
  the requirement without taking a third-party dependency.

## License

This repository is intended as a reference design for AF Group's DnA
production support team. Adapt freely within your organisation.
