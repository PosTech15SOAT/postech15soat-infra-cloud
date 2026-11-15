import base64
import json
import logging
import os

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError


QUEUE_URL = os.environ["QUEUE_URL"]
SQS = boto3.client("sqs", config=Config(connect_timeout=2, read_timeout=23,
                                       retries={"total_max_attempts": 1}))
LOGGER = logging.getLogger(__name__)
BILLING = "system:serviceaccount:numberone-billing:numberone-billing"
OS = "system:serviceaccount:numberone-os:numberone-os"
QUEUE_ATTRIBUTES = [
    "VisibilityTimeout", "ReceiveMessageWaitTimeSeconds", "MessageRetentionPeriod",
    "RedrivePolicy", "FifoQueue", "SqsManagedSseEnabled",
]
SUBJECTS = {
    "POST /eventos": BILLING,
    "GET /fila": OS,
    "POST /recebimentos": OS,
    "POST /confirmacoes": OS,
    "POST /visibilidade": OS,
}


def response(status, body=None):
    result = {"statusCode": status}
    if body is not None:
        result.update(headers={"content-type": "application/json"}, body=json.dumps(body))
    return result


def request_body(event):
    body = event.get("body")
    if not isinstance(body, str) or not body:
        raise ValueError("body required")
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body, validate=True).decode("utf-8")
    return body


def receipt_handle(event):
    body = json.loads(request_body(event))
    handle = body.get("receiptHandle") if isinstance(body, dict) else None
    if not isinstance(handle, str) or not handle:
        raise ValueError("receipt required")
    return handle


def handler(event, _context):
    route = event.get("routeKey")
    if route not in SUBJECTS:
        return response(404)
    claims = event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})
    if claims.get("sub") != SUBJECTS[route]:
        return response(403)

    try:
        if route == "POST /eventos":
            result = SQS.send_message(QueueUrl=QUEUE_URL, MessageBody=request_body(event))
            return response(201) if result.get("MessageId") else response(502)
        if route == "GET /fila":
            result = SQS.get_queue_attributes(QueueUrl=QUEUE_URL, AttributeNames=["All"])
            return response(200, {name: value for name, value in result["Attributes"].items()
                                  if name in QUEUE_ATTRIBUTES})
        if route == "POST /recebimentos":
            result = SQS.receive_message(QueueUrl=QUEUE_URL, WaitTimeSeconds=20, VisibilityTimeout=60,
                                         MaxNumberOfMessages=1,
                                         MessageSystemAttributeNames=["ApproximateReceiveCount"])
            return response(200, [
                {"messageId": message["MessageId"], "receiptHandle": message["ReceiptHandle"],
                 "body": message["Body"], "receiveCount": message["Attributes"]["ApproximateReceiveCount"]}
                for message in result.get("Messages", [])
            ])
        receipt = receipt_handle(event)
        if route == "POST /confirmacoes":
            SQS.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt)
        else:
            SQS.change_message_visibility(QueueUrl=QUEUE_URL, ReceiptHandle=receipt, VisibilityTimeout=60)
        return response(204)
    except ValueError:
        return response(400)
    except ClientError as error:
        code = error.response["Error"]["Code"]
        if code in {"InvalidMessageContents", "MessageTooLong", "ReceiptHandleIsInvalid", "InvalidParameterValue"}:
            return response(400)
        LOGGER.warning("SQS request failed route=%s code=%s", route, code)
        return response(503)
    except BotoCoreError as error:
        LOGGER.warning("SQS request failed route=%s type=%s", route, type(error).__name__)
        return response(503)
