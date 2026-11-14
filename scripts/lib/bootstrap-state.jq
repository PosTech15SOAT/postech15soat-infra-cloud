# Strict allowlist: no business resources, data sources, deletes or replacements.
def addresses: [
  "aws_s3_bucket.terraform_state",
  "aws_s3_bucket_ownership_controls.terraform_state",
  "aws_s3_bucket_public_access_block.terraform_state",
  "aws_s3_bucket_server_side_encryption_configuration.terraform_state",
  "aws_s3_bucket_versioning.terraform_state"
];
def safe_values($r):
  if $r.type == "aws_s3_bucket" then
    $r.values.bucket == $bucket and $r.values.force_destroy == false
  elif $r.type == "aws_s3_bucket_ownership_controls" then
    $r.values.rule[0].object_ownership == "BucketOwnerEnforced"
  elif $r.type == "aws_s3_bucket_public_access_block" then
    all(["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"][];
      . as $key | $r.values[$key] == true)
  elif $r.type == "aws_s3_bucket_server_side_encryption_configuration" then
    $r.values.rule[0].apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
  elif $r.type == "aws_s3_bucket_versioning" then
    $r.values.versioning_configuration[0].status == "Enabled"
  else false end;
if $kind == "state" then
  .version == 4 and (.serial | type == "number" and . >= 0) and (.lineage | type == "string" and length > 0) and
  (.resources | type == "array" and length > 0) and
  (.outputs // {} | all(to_entries[]; .key == "state_bucket_name" and .value.value == $bucket)) and
  all(.resources[];
    (.type + "." + .name) as $address |
    .mode == "managed" and (.module // "") == "" and (addresses | index($address)) != null) and
  all(.resources[].instances[]; (.deposed // "") == "" and
    (.attributes.bucket // .attributes.id) == $bucket and .attributes.id == $bucket) and
  ([.resources[] | select(.type == "aws_s3_bucket") | .instances[]] | length == 1)
elif $kind == "complete-state" then
  ([.resources[] | .type + "." + .name] | sort) == (addresses | sort) and
  all(.resources[]; . as $r | .instances | length == 1 and
    all(.[]; safe_values({type: $r.type, values: .attributes})))
elif $kind == "plan" then
  .errored != true and (.deferred_changes // [] | length == 0) and
  (.output_changes // {} | all(keys[]; . == "state_bucket_name")) and .variables.aws_region.value == $region and
  .variables.state_bucket_name.value == $bucket and
  .configuration.provider_config.aws.expressions.region.references == ["var.aws_region"] and
  .configuration.provider_config.aws.expressions.allowed_account_ids.constant_value == [$account] and
  (.configuration.provider_config | keys) == ["aws"] and
  all(.configuration.provider_config.aws.expressions | keys[];
    . == "region" or . == "allowed_account_ids" or . == "default_tags") and
  ([.planned_values.root_module.resources[].address] | sort) == (addresses | sort) and
  (.planned_values.root_module.child_modules // [] | length == 0) and
  all(.planned_values.root_module.resources[];
    .mode == "managed" and .provider_name == "registry.terraform.io/hashicorp/aws" and safe_values(.)) and
  all(.resource_changes[];
    .address as $address | (addresses | index($address)) != null and
    (.change.importing // null) == null and (.previous_address // null) == null and
    (.change.actions == ["create"] or .change.actions == ["update"] or .change.actions == ["no-op"]))
else false end
