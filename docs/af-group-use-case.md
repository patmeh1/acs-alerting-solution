# AF Group use case — detailed writeup

## Background

A few years ago the AF Group DnA business unit set up a Production Support
On-Call rotation for developers. It depended on a **VTEXT email-to-SMS**
pipeline: watcher processes monitored certain mailboxes and scheduled jobs,
and when a critical condition was detected the watcher sent an email to the
on-call engineer's carrier email-to-SMS gateway (for example
`5551234567@vtext.com`). That gateway converted the email into an SMS so the
on-call's personal and work phones lit up regardless of who was on call.

That mechanism is now failing in production:

* Several US carriers have **deprecated or removed** their email-to-SMS
  gateways, so messages silently disappear.
* The remaining carrier gateways do not deliver consistently across networks
  and provide no acknowledgement of delivery.
* There is **no audit trail** of who was paged or when, which makes
  post-incident reviews and audit responses difficult.

AF Group is now evaluating **Azure Communication Services (ACS) with Event
Hubs** to trigger SMS and phone calls as the replacement. The team has
explicitly **excluded Twilio** from consideration. They have asked for a
recommendation on the built-in Microsoft options.

## Constraints driving the answer

1. **No Twilio.** Out of scope per the AF Group request.
2. **ACS SMS is on the retirement path.** Microsoft has announced (July 22,
   2026) that Azure Communication Services SMS is in the retirement scope
   with full retirement on **July 31, 2028**. Any replacement built around
   ACS SMS would need to be re-platformed inside ~2 years. Treat ACS SMS as
   transitional only, not as the strategic target.
3. **Must wake the on-call engineer.** Voice is the only reliable wake-up
   channel for a sleeping engineer; SMS is the written summary that survives
   into morning. Both are required for Sev1.
4. **Auditability.** Every page must be logged so AF Group can prove
   compliance with on-call SLAs.

## Recommended solution

**Azure Monitor Action Groups** as the notification engine, fed by a
**normalized alert event stream** that originates from Logic Apps, Azure
Functions, and Event Hubs.

### Building blocks

| Layer | Component | Purpose |
| --- | --- | --- |
| **Alert sources** | Outlook / shared mailbox | Inbound vendor alerts, carrier maintenance emails, hand-built failure notifications. |
| | Scheduler jobs (SQL Agent, control-M, ADF, Synapse) | Batch failure signals. |
| | App events / Azure resources | Direct emissions from claims, billing, and DnA pipelines. |
| **Ingestion** | Azure Logic Apps (Consumption or Standard) | Polls the shared mailbox, normalises content, posts to Event Hubs or directly to the Function. |
| | Azure Event Hubs (Standard, 1 TU) | Buffer for high-volume / bursty signals. Decouples producers from consumers. |
| | Azure Functions (Python 3.11, Consumption plan) | Normalises every payload into a single schema and writes it to Azure Monitor. |
| **Alert signal** | Log Analytics workspace + DCR-based custom log (`AlertEvents_CL`) | Durable record of every normalized alert. |
| | Application Insights (workspace-based) | Function telemetry + KQL surface for short-term queries. |
| **Evaluation** | Azure Monitor scheduled query alert rule | Fires when at least one `Sev1` record has arrived inside a sliding window. Deduplicates via the `DedupeKey_s` column. |
| **Notification** | Azure Monitor **Action Group** with SMS + voice + email + Azure mobile push + optional Teams webhook | Built-in multi-channel delivery, no custom telephony code. |
| **Audit & ops** | LAW, Power BI, ITSM webhook | Delivery dashboard, weekly metrics, ServiceNow ticket creation. |

### Why not standalone ACS SMS / Call Automation?

* Documented retirement timeline: announcement 22-Jul-2026, full retirement
  31-Jul-2028.
* AF Group does not need programmable call flow control or IVR; a simple
  page-the-on-call interaction is enough. Action Groups already provide
  that without code.
* Teams Phone Extensibility + ACS Call Automation remains a valid path
  **only** for advanced programmable telephony aligned to supported Teams
  scenarios — keep it on the shelf for future requirements (callback IVR,
  recorded calls, in-call DTMF acknowledgement) but do not adopt it for the
  immediate VTEXT replacement.

## Normalized alert schema

Every producer — Logic App, Function, scheduler hook, or app code — emits the
same JSON shape so the alert rule and the downstream dashboards never have
to special-case sources.

```json
{
  "source": "claims-batch-scheduler",
  "application": "ClaimsPipeline",
  "severity": "Sev1",
  "summary": "Claims pipeline batch job failed",
  "details": "Job 'NightlyClaimsETL' failed at 2:15 AM. Immediate review required.",
  "incidentId": "INC000000123",
  "ownerGroup": "DnA Production Support",
  "eventTimeUtc": "2026-06-09T07:15:00Z",
  "dedupeKey": "ClaimsPipeline:BatchFailure:Sev1"
}
```

The Function normalizer adds `ReceivedAtUtc` and `AlertSchemaVersion` before
writing to Log Analytics. The alert rule deduplicates on `DedupeKey_s` so a
storm of identical failures still only rings on-call once per evaluation
window.

## Notification routing matrix

| Scenario | Primary channel | Secondary | Why |
| --- | --- | --- | --- |
| Critical failures, outages, Sev1 production incidents | Voice + SMS | Email + push + Teams | Voice wakes the engineer, SMS preserves the summary. |
| After-hours escalation (15 min unacknowledged) | Voice + SMS to backup | Email + Teams to manager | Redundancy when primary cannot answer. |
| Sev2 — degraded but no outage | SMS + push | Email | Quiet enough to skip a phone call, loud enough to be seen. |
| Sev3 / FYI | Email + Teams | — | Avoids alert fatigue and notification cost. |

## Architecture diagram (text)

```
+----------------+    +-----------+    +-------------+    +----------------+    +---------------+
| Outlook /      | -> | Logic App | -> | Event Hub   | -> | Function       | -> | Log Analytics |
| Scheduler /    |    |           |    |             |    | (normalize +   |    |  & App        |
| App events     |    +-----------+    +-------------+    |  emit to LAW)  |    |  Insights     |
+----------------+                                         +----------------+    +-------+-------+
                                                                                          |
                                                                                          v
                                                                                +-------------------+
                                                                                | Scheduled query   |
                                                                                | alert rule (5 m)  |
                                                                                +---------+---------+
                                                                                          |
                                                                                          v
                                                                                +-------------------+
                                                                                | Action Group:     |
                                                                                | SMS + Voice +     |
                                                                                | Email + Push +    |
                                                                                | Teams webhook +   |
                                                                                | ITSM webhook      |
                                                                                +-------------------+
```

## Step-by-step implementation

1. **Discovery.** Inventory current VTEXT senders, mailboxes monitored,
   scheduler jobs that emit critical conditions, and the current rotation
   roster. Use the Open Questions table on the site to drive these
   conversations.
2. **Pilot Action Group.** Deploy the Bicep with 1–2 test recipients. Run
   `scripts/test-action-group.sh` to confirm SMS, voice, email, and Azure
   mobile push delivery on every recipient.
3. **Stand up the ingestion stack.** Deploy Event Hubs, Function App, Log
   Analytics, and the scheduled query alert rule from the same Bicep file.
4. **Wire the highest-value source first.** Pick the noisiest current VTEXT
   user (often the nightly batch failure mailbox) and connect it via Logic
   App or direct Event Hub publish.
5. **Run parallel for two weeks.** Keep VTEXT alive while the Action Group
   notifications prove out. Compare audit trails daily.
6. **Cut over Sev1 + Sev2.** Decommission the carrier email-to-SMS path for
   any rotation that has hit two consecutive weeks of clean delivery.
7. **Add escalation logic.** If the on-call does not acknowledge within
   15 minutes, fire a second alert rule that pages a backup contact and the
   manager. This is a second Action Group, not a new tool.
8. **Codify in policy.** Use Azure Policy and an Action Group template
   library so every new workload onboarding inherits the same rotation
   contacts and severity routing.

## Pilot success criteria

* Every recipient receives SMS + voice + email + push during the smoke
  test.
* End-to-end latency (synthetic event to phone ringing) is ≤ 10 minutes.
* Deduplication confirmed: three identical synthetic events trigger one
  page.
* Maintenance window suppression rule confirmed: alerts inside a planned
  maintenance window do not page.
* Audit query `scripts/kql/alert-delivery-audit.kql` shows one delivery
  row per real alert.

## What we are explicitly **not** doing

* **Twilio** — out of scope.
* **ACS SMS as a new build** — retirement path.
* **Custom CPaaS implementation** — the requirement does not warrant it,
  and Action Groups already cover the use case.

## Future options

* **Teams Phone Extensibility + ACS Call Automation** if AF Group later
  needs IVR, callback acknowledgement, call recording, or a branded caller
  ID. Treat this as a follow-on workstream gated on a real business
  requirement.
* **PagerDuty / Opsgenie / xMatters** via Action Group webhook if AF Group
  decides to standardise on a third-party on-call orchestrator. The Action
  Group webhook receiver type is the integration seam.
