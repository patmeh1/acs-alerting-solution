"""Publish a synthetic Sev1 alert to the critical-alerts Event Hub.

Usage:
    pip install azure-eventhub azure-identity
    export EVENTHUB_NAMESPACE=oncall-ehns-xxxxx
    export EVENTHUB_NAME=critical-alerts
    python scripts/send-test-event.py [--severity Sev1] [--count 1]

Uses DefaultAzureCredential, so an `az login` or managed identity is sufficient.
The publishing identity needs the "Azure Event Hubs Data Sender" role on the hub.
"""

from __future__ import annotations

import argparse
import json
import os
import time
from datetime import datetime, timezone

from azure.eventhub import EventData, EventHubProducerClient
from azure.identity import DefaultAzureCredential


def build_payload(severity: str) -> dict:
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    return {
        "source": "nightly-batch-scheduler",
        "application": "OrdersPipeline",
        "severity": severity,
        "summary": "Nightly batch job failed",
        "details": (
            f"Job 'NightlyOrdersETL' failed at {now}. "
            "Last successful run > 24h ago. Immediate review required."
        ),
        "incidentId": f"INC{int(time.time())}",
        "ownerGroup": "Production Support",
        "eventTimeUtc": now,
        "dedupeKey": f"OrdersPipeline:BatchFailure:{severity}",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--severity", default="Sev1", choices=["Sev1", "Sev2", "Sev3", "Sev4"])
    parser.add_argument("--count", type=int, default=1)
    args = parser.parse_args()

    namespace = os.environ["EVENTHUB_NAMESPACE"]
    hub = os.environ.get("EVENTHUB_NAME", "critical-alerts")
    fqdn = f"{namespace}.servicebus.windows.net"

    credential = DefaultAzureCredential()
    producer = EventHubProducerClient(
        fully_qualified_namespace=fqdn,
        eventhub_name=hub,
        credential=credential,
    )

    with producer:
        batch = producer.create_batch(partition_key="OrdersPipeline")
        for _ in range(args.count):
            payload = build_payload(args.severity)
            batch.add(EventData(json.dumps(payload)))
        producer.send_batch(batch)

    print(f"Published {args.count} {args.severity} event(s) to {fqdn}/{hub}")


if __name__ == "__main__":
    main()
