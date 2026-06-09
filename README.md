# Critical alerting — Microsoft-native reference design

A reference design and deployable pilot for replacing a carrier email-to-SMS
on-call alerting pipeline with built-in Azure services. The example use case
is generic on-call production support; adapt names, severity rules, and
contacts to your organization.

The recommended stack is **Azure Monitor Action Groups** for SMS, voice,
email, and Azure mobile push; **Logic Apps**, **Azure Functions**, and
**Event Hubs** for ingestion and normalization; and **Log Analytics** plus
**Application Insights** for evaluation and audit. It avoids both the
deprecated carrier email-to-SMS gateways and any standalone SMS or voice
CPaaS product that does not have a published long-term support commitment.

> **Why this design exists.** Carrier email-to-SMS gateways (the
> "email-the-number@carrier.com" pattern that many on-call rotations used to
> rely on) have been deprecated or removed by several US carriers, so
> alerts silently disappear. A common follow-on proposal is to rebuild the
> pipeline on a standalone SMS / voice CPaaS product. We avoid anchoring on
> any such product without a published long-term support roadmap — Azure
> Communication Services SMS is a concrete example currently in its
> announced retirement window — and instead use Azure Monitor Action Groups
> for first-party notification delivery.

## What is in this repo

| Path | Purpose |
| --- | --- |
| [`index.html`](index.html) | GitHub Pages site rendered at <https://patmeh1.github.io/acs-alerting-solution/> |
| [`infra/main.bicep`](infra/main.bicep) | Single-file Bicep that deploys Log Analytics, Application Insights, Storage, Function App (Python 3.11 consumption), Event Hubs (Standard), an Action Group with SMS + voice + email + Azure mobile push + optional Teams webhook, and the Sev1 scheduled-query alert rule. |
| [`infra/main.parameters.json`](infra/main.parameters.json) | Sample parameters. Edit `oncallEmail`, `oncallPhoneCountryCode`, `oncallPhoneNumber`, and optionally `teamsWebhookUrl` before deploying. |
| [`infra/deploy.sh`](infra/deploy.sh) | Convenience wrapper around `az group create` + `az deployment group create`. |
| [`scripts/normalize_alert/`](scripts/normalize_alert/) | Python v2 Function App with an Event Hub trigger and a manual HTTP test endpoint. |
| [`scripts/send-test-event.sh`](scripts/send-test-event.sh) | Bash + `openssl` script that publishes a synthetic Sev1 event to the Event Hub via SAS. |
| [`scripts/send-test-event.py`](scripts/send-test-event.py) | Python equivalent using `DefaultAzureCredential`. |
| [`scripts/test-action-group.sh`](scripts/test-action-group.sh) | Calls `Microsoft.Insights/actionGroups/createNotifications` to ring every channel directly, without going through the alert rule. |
| [`scripts/logic-app-mailbox-monitor.json`](scripts/logic-app-mailbox-monitor.json) | Logic App workflow definition that watches a shared mailbox, builds a normalized alert, and forwards it to the Event Hub. |
| [`scripts/teams-adaptive-card.json`](scripts/teams-adaptive-card.json) | Adaptive Card payload for the Teams webhook receiver. |
| [`scripts/kql/sev1-alert-query.kql`](scripts/kql/sev1-alert-query.kql) | KQL behind the scheduled query alert rule. |
| [`scripts/kql/alert-delivery-audit.kql`](scripts/kql/alert-delivery-audit.kql) | Dashboard query joining alert events with Action Group delivery diagnostics. |
| [`docs/customer-use-case.md`](docs/customer-use-case.md) | Long-form writeup of the carrier email-to-SMS problem and the recommended solution. |
| [`docs/running-example.md`](docs/running-example.md) | End-to-end pilot walkthrough — deploy, smoke test, send synthetic events, tear down. |
| [`docs/cost-estimate.md`](docs/cost-estimate.md) | Pilot and production cost estimates pulled from the Azure Pricing Calculator with per-line workings. |

## Quick start

```bash
git clone https://github.com/patmeh1/acs-alerting-solution.git
cd acs-alerting-solution

# 1. Edit the parameters file with a real on-call email and phone number.
$EDITOR infra/main.parameters.json

# 2. Deploy the pilot infrastructure.
export RG=rg-critical-alerting-pilot
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

Step-by-step walkthrough with expected outputs and a timing diagram lives in
[`docs/running-example.md`](docs/running-example.md).

## Estimated cost

Detailed line-item breakdown in [`docs/cost-estimate.md`](docs/cost-estimate.md).
Approximate monthly figures (East US, list price, mid-2026):

| Profile | Sev1 alerts / month | Approx. monthly cost (USD) |
| --- | --- | --- |
| **Pilot** | 50 | **≈ $31** |
| **Production** | 500 | **≈ $135** |

## What we deliberately did not use

* **Standalone SMS / voice CPaaS products without a published long-term
  support roadmap.** Azure Communication Services SMS is the concrete
  example (currently in its announced retirement window) — we treat any
  such dependency as a forced-replatform risk and avoid it.
* **Twilio.** Out of scope for this design. Azure Monitor Action Groups
  cover the requirement without taking a third-party dependency. If you
  later need a third-party on-call orchestrator (PagerDuty, Opsgenie,
  xMatters), wire it in via the Action Group webhook receiver.

## License

Published as a reference design. Adapt freely within your organization.
