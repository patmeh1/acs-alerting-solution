"""the customer alert normalizer.

Two triggers:
1. Event Hub trigger - normalizes payloads coming from app code, scheduler hooks,
   or Logic Apps that publish to the critical-alerts hub.
2. HTTP trigger     - quick manual test endpoint that accepts the same payload
   shape and returns the normalized record (useful for the running example).

Both write a normalized record to Application Insights (Severity=Error for Sev1)
so the scheduled query alert rule on AlertEvents_CL / customEvents picks it up.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone

import azure.functions as func

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

VALID_SEVERITIES = {"Sev1", "Sev2", "Sev3", "Sev4"}


def _normalize(payload: dict) -> dict:
    severity = payload.get("severity", "Sev3")
    if severity not in VALID_SEVERITIES:
        severity = "Sev3"

    return {
        "Source": payload.get("source", "unknown"),
        "Application": payload.get("application", "unknown"),
        "Severity": severity,
        "Summary": payload.get("summary", "Alert received"),
        "Details": payload.get("details", ""),
        "IncidentId": payload.get("incidentId", ""),
        "OwnerGroup": payload.get("ownerGroup", "Unassigned"),
        "DedupeKey": payload.get("dedupeKey", ""),
        "EventTimeUtc": payload.get(
            "eventTimeUtc",
            datetime.now(timezone.utc).isoformat(timespec="seconds"),
        ),
        "ReceivedAtUtc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "AlertSchemaVersion": "1.0",
    }


def _emit(normalized: dict) -> None:
    body = json.dumps(normalized)
    if normalized["Severity"] == "Sev1":
        logging.error("CRITICAL_ALERT %s", body)
    elif normalized["Severity"] == "Sev2":
        logging.warning("HIGH_ALERT %s", body)
    else:
        logging.info("ALERT %s", body)


@app.event_hub_message_trigger(
    arg_name="event",
    event_hub_name=os.environ.get("EVENTHUB_NAME", "critical-alerts"),
    connection="EVENTHUB_CONNECTION",
)
def normalize_from_eventhub(event: func.EventHubEvent) -> None:
    try:
        payload = json.loads(event.get_body().decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        logging.exception("Failed to parse Event Hub payload: %s", exc)
        return

    normalized = _normalize(payload)
    _emit(normalized)


@app.route(route="normalize", methods=["POST"])
def normalize_http(req: func.HttpRequest) -> func.HttpResponse:
    try:
        payload = req.get_json()
    except ValueError:
        return func.HttpResponse("Body must be JSON", status_code=400)

    normalized = _normalize(payload)
    _emit(normalized)
    return func.HttpResponse(
        body=json.dumps(normalized),
        status_code=200,
        mimetype="application/json",
    )
