import json
import os
import sys
import types
import unittest
from unittest.mock import patch

# The Lambda runtime provides boto3. Stub its client factory for local unit tests.
_fake_events = types.SimpleNamespace(put_events=lambda **kwargs: {"FailedEntryCount": 0})
sys.modules["boto3"] = types.SimpleNamespace(client=lambda service: _fake_events)
os.environ.setdefault("EVENT_BUS_NAME", "test-bus")
import handler


class SubmitInquiryTests(unittest.TestCase):
    @patch.object(handler, "_events")
    def test_valid_inquiry_publishes_event(self, events):
        events.put_events.return_value = {"FailedEntryCount": 0}
        result = handler.lambda_handler({"body": json.dumps({"name": "Test", "email": "test@example.com", "message": "Hello"})}, None)
        self.assertEqual(result["statusCode"], 202)
        events.put_events.assert_called_once()

    @patch.object(handler, "_events")
    def test_invalid_email_rejected(self, events):
        result = handler.lambda_handler({"body": json.dumps({"name": "Test", "email": "bad", "message": "Hello"})}, None)
        self.assertEqual(result["statusCode"], 400)
        events.put_events.assert_not_called()

    @patch.object(handler, "_events")
    def test_honeypot_does_not_publish(self, events):
        result = handler.lambda_handler({"body": json.dumps({"name": "Bot", "email": "bot@example.com", "message": "Spam", "website": "filled"})}, None)
        self.assertEqual(result["statusCode"], 202)
        events.put_events.assert_not_called()


if __name__ == "__main__":
    unittest.main()
