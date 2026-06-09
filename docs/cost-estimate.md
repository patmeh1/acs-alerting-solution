# Cost estimate — Azure Pricing Calculator

> Estimator values below are **illustrative**, captured from the
> [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)
> using **East US, USD, pay-as-you-go list price** at the time of writing.
> Re-run the calculator for your subscription's region, currency, EA / MCA
> discounts, and reservations before signing off. Pricing for Azure Monitor
> notifications can be reviewed at
> <https://azure.microsoft.com/pricing/details/monitor/>.

## Workload assumptions

The pilot is sized for the customer's on-call rotation:

| Assumption | Pilot | Production |
| --- | --- | --- |
| Sev1 alerts per month (notified) | 50 | 500 |
| Notification fan-out per Sev1 alert | 1 primary + 1 backup contact = 2 phones, 2 emails | 1 primary + 1 backup + Teams channel |
| Lower-severity alerts (email / Teams only) | 500 | 5,000 |
| Event Hub messages ingested per month | 10,000 | 250,000 |
| Function executions per month | 10,000 | 250,000 |
| Average function duration | 200 ms | 200 ms |
| Average function memory | 128 MB | 128 MB |
| Log Analytics ingestion | ~1 GB / month | ~12 GB / month |
| Log Analytics retention | 30 days (free) | 30 days (free) |
| Region | East US | East US |

## Pilot — monthly estimate

| Component | Calculator inputs | Est. monthly cost (USD) |
| --- | --- | --- |
| Azure Monitor — Action Group SMS, US | 100 SMS (50 alerts × 2 contacts); first 100 free per geographic region | **~$0.00** |
| Azure Monitor — Action Group voice, US | 100 voice calls (50 alerts × 2 contacts); first 10 free, 90 billable @ ~$0.06 | **~$5.40** |
| Azure Monitor — Action Group email | 1,100 emails total; first 1,000 free, rest at $2 per 100,000 | **~$0.00** |
| Azure Monitor — Action Group push | 1,100 push notifications; free at this volume | **$0.00** |
| Azure Monitor — alert rules (1 scheduled query rule, 5-minute eval) | 1 rule, log search alert | **~$1.50** |
| Log Analytics workspace ingestion | 1 GB / month at $2.30 / GB | **~$2.30** |
| Log Analytics retention | 30 days included | **$0.00** |
| Application Insights ingestion (via LAW) | Counted in LAW above | **$0.00** |
| Event Hubs (Standard, 1 TU, zone-redundant) | 1 TU × 730 hours × $0.030 | **~$21.90** |
| Function App (Consumption, Linux) | 10,000 executions, 200 ms × 128 MB; well inside free grant | **$0.00** |
| Storage account (Standard_LRS) | <1 GB used, minimal transactions | **~$0.10** |
| Logic Apps (Consumption) — mailbox monitor | ~3,000 trigger polls + ~100 actions / month | **~$0.10** |
| **Estimated pilot total** | | **≈ $31 / month** |

## Production — monthly estimate

| Component | Calculator inputs | Est. monthly cost (USD) |
| --- | --- | --- |
| Action Group SMS, US | 1,000 SMS (500 alerts × 2 contacts); first 100 free, 900 billable @ ~$0.013 | **~$11.70** |
| Action Group voice, US | 1,000 voice calls; first 10 free, 990 billable @ ~$0.06 | **~$59.40** |
| Action Group email | 12,000 emails; first 1,000 free, 11,000 billable @ $2/100,000 | **~$0.22** |
| Action Group push | 12,000 push notifications; first 1,000 free, 11,000 @ $2/100,000 | **~$0.22** |
| Action Group webhook (Teams) | 500 webhook calls; first 100,000 free | **$0.00** |
| Alert rules (3 scheduled query rules) | 3 rules @ ~$1.50 each | **~$4.50** |
| Log Analytics ingestion | 12 GB / month at $2.30 / GB | **~$27.60** |
| Event Hubs (Standard, 1 TU) | 1 TU × 730 hours × $0.030 + 250M events @ $0.028/M | **~$28.90** |
| Function App (Consumption) | 250K executions, 200 ms × 128 MB | **~$0.50** |
| Storage | Minimal | **~$0.50** |
| Logic Apps (Consumption) | ~43,800 trigger polls + ~5,000 actions | **~$1.30** |
| **Estimated production total** | | **≈ $135 / month** |

> SMS and voice list prices vary by destination country. For non-US numbers
> rerun the calculator with the correct country code. The Azure Monitor
> notification pricing reference is the authoritative source; the figures
> above were drawn from list prices in mid-2026 and **should not be treated as
> a quote**.

## How the new stack compares to the alternatives we ruled out

| Aspect | Today: carrier email-to-SMS | New: Azure Monitor Action Groups | Alternative ruled out: standalone SMS/voice CPaaS without long-term roadmap (e.g. ACS SMS during its retirement window) |
| --- | --- | --- | --- |
| Monthly notification cost (pilot) | $0 (carrier-funded, but breaking) | ~$31 | ~$50–80 (per-message SMS + phone number rental + call-automation usage) |
| SMS reliability | Carrier-dependent; some carriers have already disabled email-to-SMS | Microsoft-managed delivery network, SLA-backed | Workable today, but tied to a product without published long-term support |
| Voice call support | None | First-party, no code | Possible, but anchored on a product without LTS commitment |
| Long-term viability | At-risk | Strategic | Not viable for a new build |
| Engineering effort to operate | Minimal but fragile | Low (Azure-native config) | Higher (custom SMS / phone-number lifecycle + replatform risk) |

## Cost-control levers

* **Reserve voice calls for Sev1 only.** Email + push for lower severities — both
  remain free at any realistic customer volume.
* **Dedupe before the alert rule fires** — the `DedupeKey_s` field in the
  normalized record collapses repeats so the on-call is paged once per
  incident, not once per noisy log line.
* **Cap Log Analytics ingestion** with `workspaceCapping.dailyQuotaGb`. The
  Bicep sets it to 1 GB / day by default; raise it only after you measure
  steady-state volume.
* **Stay on Event Hubs Standard with 1 TU** until you exceed ~1 MB/s sustained
  ingress. Auto-inflate is disabled so you do not silently scale up.
* **Use the Functions consumption plan** for the normalizer — the first 1M
  executions and 400,000 GB-seconds are free every month.
* **Disable the Logic App if you are not yet monitoring a mailbox.** It is a
  separate workstream and only incurs polling cost when enabled.
