import json
import os
import re
import uuid
import boto3

_events = boto3.client("events")
EMAIL_RE = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")


def response(status, message):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json", "cache-control": "no-store"},
        "body": json.dumps({"message": message}),
    }


def lambda_handler(event, context):
    try:
        raw_body = event.get("body") or "{}"
        if len(raw_body.encode("utf-8")) > 10000:
            return response(413, "Inquiry is too large.")
        body = json.loads(raw_body)
        # Honeypot field: silently accept bots without publishing an event.
        if body.get("website"):
            return response(202, "Your inquiry has been received.")
        name = str(body.get("name", "")).strip()
        email = str(body.get("email", "")).strip()
        message = str(body.get("message", "")).strip()
        if not name or len(name) > 100:
            return response(400, "Enter a valid name (maximum 100 characters).")
        if not EMAIL_RE.match(email) or len(email) > 254:
            return response(400, "Enter a valid email address.")
        if not message or len(message) > 5000:
            return response(400, "Enter a message (maximum 5000 characters).")
        detail = {
            "inquiryId": str(uuid.uuid4()),
            "name": name,
            "email": email,
            "message": message,
        }
        result = _events.put_events(
            Entries=[{
                "EventBusName": os.environ["EVENT_BUS_NAME"],
                "Source": "lyken.website",
                "DetailType": "ContactInquiryReceived",
                "Detail": json.dumps(detail),
            }]
        )
        if result.get("FailedEntryCount", 0):
            return response(503, "We could not accept your inquiry right now. Please try again later.")
        return response(202, "Your inquiry has been received. Email notification is processed separately.")
    except (json.JSONDecodeError, TypeError):
        return response(400, "Invalid request body.")
    except Exception:
        # Do not log submitted PII or exception payloads.
        print(json.dumps({"level": "ERROR", "message": "Unable to publish contact inquiry"}))
        return response(500, "We could not process your inquiry right now.")
