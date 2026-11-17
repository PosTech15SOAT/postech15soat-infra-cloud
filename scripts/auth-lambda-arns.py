"""Extract and validate the four Cloud inputs from the existing Auth state."""

import json
import re
import sys

OUTPUTS = {
    "login": "auth_login_lambda_arn",
    "login_invoke": "auth_login_lambda_invoke_arn",
    "authorizer": "authorizer_lambda_arn",
    "authorizer_invoke": "authorizer_lambda_invoke_arn",
}
FUNCTION_ARN = re.compile(
    r"arn:(aws(?:-us-gov|-cn)?):lambda:([a-z0-9-]+):(\d{12}):function:([a-zA-Z0-9_-]+)"
)


def extract(state):
    outputs = state["outputs"]
    arns = {key: outputs[name]["value"] for key, name in OUTPUTS.items()}
    if len(arns) != 4 or not all(isinstance(value, str) and value for value in arns.values()):
        raise ValueError("Four nonempty ARN strings are required")
    functions = [FUNCTION_ARN.fullmatch(arns[key]) for key in ("login", "authorizer")]
    if not all(functions) or functions[0].groups()[:3] != functions[1].groups()[:3]:
        raise ValueError("Invalid or inconsistent function ARNs")
    if arns["login"] == arns["authorizer"]:
        raise ValueError("Two distinct Lambda functions are required")
    for key, function in zip(("login", "authorizer"), functions):
        partition, region, *_ = function.groups()
        expected = (
            f"arn:{partition}:apigateway:{region}:lambda:path/2015-03-31/"
            f"functions/{arns[key]}/invocations"
        )
        if arns[f"{key}_invoke"] != expected:
            raise ValueError("Invocation ARN does not match its function")
    return arns


if __name__ == "__main__":
    try:
        result = extract(json.load(sys.stdin))
    except (KeyError, TypeError, ValueError):
        sys.exit("Auth state must provide four valid, consistent Lambda ARN outputs; values omitted.")
    print(json.dumps(result, separators=(",", ":")))
