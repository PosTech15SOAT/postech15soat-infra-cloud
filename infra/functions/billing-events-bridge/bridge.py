import base64
import json
import logging
import os

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError
from boto3.dynamodb.conditions import Attr, Key


QUEUE_URL = os.environ["QUEUE_URL"]
SQS = boto3.client("sqs", config=Config(connect_timeout=2, read_timeout=23,
                                       retries={"total_max_attempts": 1}))
DYNAMODB = boto3.resource("dynamodb", config=Config(connect_timeout=2, read_timeout=4,
                                                     retries={"total_max_attempts": 1}))
HISTORY_TABLE_NAME = os.environ.get("HISTORY_TABLE_NAME", "")
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
    "POST /historico": OS,
    "GET /historico": OS,
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


def history_table():
    if not HISTORY_TABLE_NAME:
        raise RuntimeError("history table is not configured")
    return DYNAMODB.Table(HISTORY_TABLE_NAME)


def put_history(event):
    body = json.loads(request_body(event))
    required = {"vehicleId", "historyKey", "branchId", "serviceOrderId", "historyVersion", "snapshot"}
    if not isinstance(body, dict) or not required.issubset(body):
        raise ValueError("invalid history item")
    if any(not isinstance(body[key], str) or not body[key] for key in
           ("vehicleId", "historyKey", "branchId", "serviceOrderId", "snapshot")):
        raise ValueError("invalid history item")
    if type(body["historyVersion"]) is not int or body["historyVersion"] < 1:
        raise ValueError("invalid history version")

    snapshot = json.loads(body["snapshot"])
    if not isinstance(snapshot, dict):
        raise ValueError("invalid history snapshot")
    try:
        expected_key = f"{snapshot['completedAt']}#{snapshot['serviceOrderId']}#{snapshot['historyVersion']}"
    except KeyError as error:
        raise ValueError("invalid history snapshot") from error
    if (snapshot.get("vehicleId") != body["vehicleId"] or snapshot.get("branchId") != body["branchId"]
            or snapshot.get("serviceOrderId") != body["serviceOrderId"]
            or snapshot.get("historyVersion") != body["historyVersion"]
            or expected_key != body["historyKey"]):
        raise ValueError("history snapshot does not match its key")

    item = {key: body[key] for key in required}
    key = {"vehicleId": body["vehicleId"], "historyKey": body["historyKey"]}
    try:
        history_table().put_item(Item=item, ConditionExpression="attribute_not_exists(vehicleId)")
        return response(201, {"result": "WRITTEN"})
    except ClientError as error:
        if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        existing = history_table().get_item(Key=key, ConsistentRead=True).get("Item")
        if existing == item:
            return response(200, {"result": "REPLAYED"})
        return response(409, {"result": "COLLISION"})


def query_history(event):
    params = event.get("queryStringParameters") or {}
    vehicle = params.get("vehicleId")
    branch = params.get("branchId")
    after = params.get("after")
    try:
        limit = int(params.get("limit", "20"))
    except (TypeError, ValueError) as error:
        raise ValueError("invalid history limit") from error
    if not vehicle or not branch or limit < 1 or limit > 50:
        raise ValueError("invalid history query")

    request = {
        "KeyConditionExpression": Key("vehicleId").eq(vehicle),
        "FilterExpression": Attr("branchId").eq(branch),
        "ScanIndexForward": False,
        "Limit": 50,
        "ConsistentRead": True,
    }
    if after:
        request["ExclusiveStartKey"] = {"vehicleId": vehicle, "historyKey": after}

    visible = []
    while len(visible) <= limit:
        page = history_table().query(**request)
        for item in page.get("Items", []):
            snapshot = json.loads(item["snapshot"])
            if (snapshot.get("vehicleId") != vehicle or snapshot.get("branchId") != branch
                    or f"{snapshot.get('completedAt')}#{snapshot.get('serviceOrderId')}#"
                    f"{snapshot.get('historyVersion')}" != item.get("historyKey")):
                raise ValueError("invalid stored history document")
            visible.append((item["historyKey"], snapshot))
            if len(visible) > limit:
                break
        last_key = page.get("LastEvaluatedKey")
        if len(visible) > limit or not last_key:
            break
        request["ExclusiveStartKey"] = last_key

    entries = [snapshot for _, snapshot in visible[:limit]]
    next_key = visible[limit - 1][0] if len(visible) > limit else None
    return response(200, {"entries": entries, "lastKey": next_key})


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
        if route == "POST /historico":
            return put_history(event)
        if route == "GET /historico":
            return query_history(event)
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
