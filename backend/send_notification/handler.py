import json
import os
import boto3

_ses = boto3.client("sesv2")


def lambda_handler(event, context):
    failures = []
    for record in event.get("Records", []):
        message_id = record["messageId"]
        try:
            # EventBridge-to-SQS target places the EventBridge envelope in the body.
            envelope = json.loads(record["body"])
            detail = envelope.get("detail", {})
            name = str(detail.get("name", "Unknown"))[:100]
            email = str(detail.get("email", ""))[:254]
            message = str(detail.get("message", ""))[:5000]
            inquiry_id = str(detail.get("inquiryId", "unknown"))[:80]
            if not email or not message:
                raise ValueError("Required inquiry fields missing")
            subject = f"New website inquiry from {name}"
            text_body = (
                f"New inquiry received through the Lyken website.\n\n"
                f"Inquiry ID: {inquiry_id}\nName: {name}\nEmail: {email}\n\n"
                f"Message:\n{message}\n"
            )
            _ses.send_email(
                FromEmailAddress=os.environ["SES_FROM_EMAIL"],
                Destination={"ToAddresses": [os.environ["NOTIFICATION_TO_EMAIL"]]},
                ReplyToAddresses=[email],
                Content={"Simple": {
                    "Subject": {"Data": subject, "Charset": "UTF-8"},
                    "Body": {"Text": {"Data": text_body, "Charset": "UTF-8"}},
                }},
            )
            print(json.dumps({"level": "INFO", "message": "Inquiry notification accepted by SES", "inquiryId": inquiry_id}))
        except Exception as exc:
            # Avoid logging message bodies or email addresses.
            print(json.dumps({"level": "ERROR", "message": "Inquiry notification failed", "errorType": type(exc).__name__}))
            failures.append({"itemIdentifier": message_id})
    return {"batchItemFailures": failures}
