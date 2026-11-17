import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "auth-lambda-arns.py"
spec = importlib.util.spec_from_file_location("auth_arns", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def state():
    values = {}
    for key in ("login", "authorizer"):
        function = f"arn:aws:lambda:us-east-1:123456789012:function:{key}"
        values[module.OUTPUTS[key]] = {"value": function}
        values[module.OUTPUTS[f"{key}_invoke"]] = {
            "value": f"arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/{function}/invocations"
        }
    return {"outputs": values}


class AuthOutputsTest(unittest.TestCase):
    def test_existing_output_schema(self):
        self.assertEqual(set(module.extract(state())), set(module.OUTPUTS))

    def test_missing_empty_wrong_type_malformed_or_mismatched_arn(self):
        for name in module.OUTPUTS.values():
            for value in (None, "", [], "sensitive-invalid-value"):
                with self.subTest(name=name, value=value):
                    data = state()
                    data["outputs"][name]["value"] = value
                    with self.assertRaises((ValueError, TypeError)):
                        module.extract(data)
            data = state()
            del data["outputs"][name]
            with self.assertRaises(KeyError):
                module.extract(data)

    def test_rejects_duplicate_functions_and_cross_account(self):
        data = state()
        data["outputs"][module.OUTPUTS["authorizer"]] = data["outputs"][module.OUTPUTS["login"]]
        with self.assertRaises(ValueError):
            module.extract(data)
        data = state()
        name = module.OUTPUTS["authorizer"]
        data["outputs"][name]["value"] = data["outputs"][name]["value"].replace("123456789012", "999999999999")
        with self.assertRaises(ValueError):
            module.extract(data)

    def test_errors_do_not_print_state_values(self):
        for data in ("invalid-sensitive-json", json.dumps({"outputs": {"secret": "sensitive"}})):
            result = subprocess.run(["python3", str(SCRIPT)], input=data, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertNotIn("sensitive", result.stderr)


if __name__ == "__main__":
    unittest.main()
