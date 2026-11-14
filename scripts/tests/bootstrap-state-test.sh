#!/usr/bin/env bash
# Self-contained fixtures: AWS and Terraform are always replaced with local mocks.
set -euo pipefail
umask 077
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/../.." && pwd -P)"
command -v jq >/dev/null || { echo 'Instale jq para executar os testes.' >&2; exit 1; }
test_root=$(mktemp -d /tmp/numberone-bootstrap-test.XXXXXXXX)
export MOCK_FIXTURES="$test_root/fixtures"
mkdir -p "$MOCK_FIXTURES" "$test_root/bin"
bucket=numberone-terraform-state
jq -n --arg b "$bucket" '
  [
    {type:"aws_s3_bucket", values:{bucket:$b,force_destroy:false}},
    {type:"aws_s3_bucket_ownership_controls",values:{bucket:$b,rule:[{object_ownership:"BucketOwnerEnforced"}]}},
    {type:"aws_s3_bucket_public_access_block",values:{bucket:$b,block_public_acls:true,block_public_policy:true,ignore_public_acls:true,restrict_public_buckets:true}},
    {type:"aws_s3_bucket_server_side_encryption_configuration",values:{bucket:$b,rule:[{apply_server_side_encryption_by_default:[{sse_algorithm:"AES256"}]}]}},
    {type:"aws_s3_bucket_versioning",values:{bucket:$b,versioning_configuration:[{status:"Enabled"}]}}
  ] | map(. + {address:(.type+".terraform_state"),name:"terraform_state",mode:"managed",provider_name:"registry.terraform.io/hashicorp/aws"})
' >"$MOCK_FIXTURES/resources.json"
jq -n --slurpfile r "$MOCK_FIXTURES/resources.json" '
  {version:4,serial:1,lineage:"fixture-lineage",resources:($r[0]|map({type,name,mode,instances:[{attributes:(.values + {id:"numberone-terraform-state"})}]}))}
' >"$MOCK_FIXTURES/managed.tfstate"
jq -n --slurpfile r "$MOCK_FIXTURES/resources.json" '
 {errored:false,variables:{aws_region:{value:"us-east-1"},state_bucket_name:{value:"numberone-terraform-state"}},
 configuration:{provider_config:{aws:{expressions:{region:{references:["var.aws_region"]},allowed_account_ids:{constant_value:["111111111111"]}}}}},
 planned_values:{root_module:{resources:$r[0]}},resource_changes:($r[0]|map({address,change:{actions:["create"]}}))}
' >"$MOCK_FIXTURES/plan.json"
cat >"$test_root/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == --region && $2 == us-east-1 && $3 == --no-cli-pager ]] || exit 97
shift 3
service=$1; operation=$2; shift 2
printf '%s %s\n' "$service" "$operation" >>"$MOCK_HOME/aws.calls"
[[ ${MOCK_SCENARIO:-} != credentials ]] || exit 1
case "$service $operation" in
  'sts get-caller-identity')
    account=111111111111
    [[ ${MOCK_SCENARIO:-} != account ]] || account=222222222222
    printf '{"Account":"%s","Arn":"arn:aws:sts::%s:assumed-role/LabRole/test"}\n' "$account" "$account" ;;
  's3api list-buckets')
    if [[ -f $MOCK_HOME/bucket-exists ]]; then echo '["numberone-terraform-state"]'; else echo '[]'; fi ;;
  's3api head-bucket')
    if [[ ${MOCK_SCENARIO:-} == forbidden ]]; then echo 'An error occurred (403)' >&2; exit 1; fi
    if [[ ! -f $MOCK_HOME/bucket-exists ]]; then echo 'An error occurred (404)' >&2; exit 1; fi ;;
  's3api get-bucket-location')
    if [[ ${MOCK_SCENARIO:-} == region ]]; then echo '{"LocationConstraint":"sa-east-1"}'; else echo '{"LocationConstraint":null}'; fi ;;
  's3api get-bucket-versioning')
    if [[ ${MOCK_SCENARIO:-} == drift ]]; then echo '{"Status":"Suspended"}'; else echo '{"Status":"Enabled"}'; fi ;;
  's3api get-bucket-encryption') echo '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}}' ;;
  's3api get-public-access-block') echo '{"PublicAccessBlockConfiguration":{"BlockPublicAcls":true,"BlockPublicPolicy":true,"IgnorePublicAcls":true,"RestrictPublicBuckets":true}}' ;;
  's3api get-bucket-ownership-controls') echo '{"OwnershipControls":{"Rules":[{"ObjectOwnership":"BucketOwnerEnforced"}]}}' ;;
  's3api list-object-versions')
    case ${MOCK_SCENARIO:-} in
      history) echo '{"Versions":[{"Key":"cloud/terraform.tfstate","IsLatest":false}]}' ;;
      *) echo '{"Versions":[],"DeleteMarkers":[]}' ;;
    esac ;;
  's3api list-objects-v2')
    key=''; while (($#)); do if [[ $1 == --prefix ]]; then key=$2; break; fi; shift; done
    case ${MOCK_SCENARIO:-} in
      remote) printf '{"Contents":[{"Key":"%s"}]}\n' "$key" ;;
      lock) printf '{"Contents":[{"Key":"%s.tflock"}]}\n' "$key" ;;
      *) echo '{"Contents":[]}' ;;
    esac ;;
  's3api get-object') cat "$MOCK_FIXTURES/managed.tfstate" >"${!#}"; echo '{}' ;;
  *) echo "Operação AWS proibida no teste: $service $operation" >&2; exit 98 ;;
esac
MOCK
cat >"$test_root/bin/terraform" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
run_dir=''
if [[ $1 == -chdir=* ]]; then run_dir=${1#-chdir=}; shift; fi
operation=$1; shift
printf '%s\n' "$operation" >>"$MOCK_HOME/terraform.calls"
case $operation in
  version) printf '{"terraform_version":"%s"}\n' "${MOCK_VERSION:-1.10.5}" ;;
  init)
    case $run_dir in
      */infra|*/postech15soat-infra-database)
        key=cloud/terraform.tfstate; [[ $run_dir != */postech15soat-infra-database ]] || key=database/terraform.tfstate
        mkdir -p "$run_dir/.terraform"
        jq -n --arg k "$key" '{backend:{type:"s3",config:{bucket:"numberone-terraform-state",key:$k,region:"us-east-1",encrypt:true,use_lockfile:true}}}' >"$run_dir/.terraform/terraform.tfstate" ;;
    esac ;;
  validate) ;;
  plan)
    [[ -f $run_dir/account_override.tf ]] || exit 92
    out=''; plan_state=''
    for arg in "$@"; do
      [[ $arg != -out=* ]] || out=${arg#-out=}
      [[ $arg != -state=* ]] || plan_state=${arg#-state=}
    done
    [[ -n $out ]] || exit 93
    printf 'binary-mock-plan\n' >"$out"
    cp "$MOCK_FIXTURES/plan.json" "$run_dir/fixture.json"
    if [[ -f $plan_state ]]; then
      jq '.resource_changes[].change.actions=["no-op"]' "$MOCK_FIXTURES/plan.json" >"$run_dir/fixture.json"
    fi
    case ${MOCK_SCENARIO:-} in
      delete) jq '.resource_changes[0].change.actions=["delete"]' "$MOCK_FIXTURES/plan.json" >"$run_dir/fixture.json" ;;
      badplan) jq '.planned_values.root_module.resources[0].values.force_destroy=true' "$MOCK_FIXTURES/plan.json" >"$run_dir/fixture.json" ;;
      wrongplanaccount) jq '.configuration.provider_config.aws.expressions.allowed_account_ids.constant_value=["222222222222"]' "$MOCK_FIXTURES/plan.json" >"$run_dir/fixture.json" ;;
    esac ;;
  show)
    if [[ $1 == -json ]]; then
      if [[ -f $run_dir/fixture.json ]]; then cat "$run_dir/fixture.json"; else cat "$MOCK_FIXTURES/plan.json"; fi
    else echo 'Plano simulado para revisão.'; fi ;;
  apply)
    [[ $# == 4 && $1 == -input=false && $2 == -lock-timeout=30s && $3 == -state=* && -f $4 ]] || exit 94
    apply_state=${3#-state=}
    cp "$MOCK_FIXTURES/managed.tfstate" "$apply_state"
    : >"$MOCK_HOME/bucket-exists"
    [[ ${MOCK_SCENARIO:-} != partial ]] || exit 1 ;;
  *) echo 'Operação Terraform inesperada' >&2; exit 99 ;;
esac
MOCK
chmod +x "$test_root/bin/aws" "$test_root/bin/terraform"
export PATH="$test_root/bin:$PATH"
unset TF_DATA_DIR TF_WORKSPACE TF_CLI_ARGS TF_CLI_ARGS_plan TF_CLI_ARGS_apply TF_STATE_BUCKET AWS_ENDPOINT_URL AWS_ENDPOINT_URL_S3
export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1
count=0
new_case() {
  count=$((count+1))
  export MOCK_HOME="$test_root/case.$count" MOCK_SCENARIO='' MOCK_VERSION=1.10.5
  mkdir -p "$MOCK_HOME/cloud/scripts/lib" "$MOCK_HOME/cloud/infra/bootstrap" "$MOCK_HOME/postech15soat-infra-database"
  cp "$repo_root/scripts/bootstrap-state.sh" "$repo_root/scripts/bootstrap-state-ci.sh" "$MOCK_HOME/cloud/scripts/"
  cp "$repo_root/scripts/lib/bootstrap-state.jq" "$MOCK_HOME/cloud/scripts/lib/"
  cp "$repo_root/infra/bootstrap/"*.tf "$repo_root/infra/bootstrap/.terraform.lock.hcl" "$MOCK_HOME/cloud/infra/bootstrap/"
  mkdir -p "$MOCK_HOME/cloud/.github/workflows" "$MOCK_HOME/postech15soat-infra-database/.github/workflows"
  cp "$repo_root/.github/workflows/terraform-deploy.yml" "$repo_root/.github/workflows/terraform-bootstrap.yml" "$MOCK_HOME/cloud/.github/workflows/"
  # The fixture checks the same local vars/secrets contract without real GitHub access.
  cp "$repo_root/.github/workflows/terraform-deploy.yml" "$MOCK_HOME/postech15soat-infra-database/.github/workflows/terraform-plan.yml"
  cp "$repo_root/.github/workflows/terraform-deploy.yml" "$MOCK_HOME/postech15soat-infra-database/.github/workflows/terraform-apply.yml"
  cp "$repo_root/infra/backend.tf" "$MOCK_HOME/cloud/infra/backend.tf"
  sed 's@cloud/terraform.tfstate@database/terraform.tfstate@' "$repo_root/infra/backend.tf" >"$MOCK_HOME/postech15soat-infra-database/backend.tf"
  script="$MOCK_HOME/cloud/scripts/bootstrap-state.sh"
  : >"$MOCK_HOME/aws.calls"; : >"$MOCK_HOME/terraform.calls"
}
run_ok() {
  if [[ $script == */bootstrap-state-ci.sh ]]; then export GITHUB_RUN_NUMBER=$GITHUB_RUN_ID; fi
  if ! "$script" "$@" >"$MOCK_HOME/result.log" 2>&1; then cat "$MOCK_HOME/result.log"; echo "FALHOU (esperado sucesso): $*" >&2; exit 1; fi
  printf 'PASS %s\n' "$*"
}
run_fail() {
  local diagnostic=$1; shift
  if [[ $script == */bootstrap-state-ci.sh ]]; then export GITHUB_RUN_NUMBER=$GITHUB_RUN_ID; fi
  if "$script" "$@" >"$MOCK_HOME/result.log" 2>&1; then echo "FALHOU (esperado erro): $*" >&2; exit 1; fi
  if ! grep -q -- "$diagnostic" "$MOCK_HOME/result.log"; then cat "$MOCK_HOME/result.log"; echo "Diagnóstico ausente: $diagnostic" >&2; exit 1; fi
  printf 'PASS bloqueio: %s\n' "$diagnostic"
}
managed() { cp "$MOCK_FIXTURES/managed.tfstate" "$MOCK_HOME/cloud/infra/bootstrap/terraform.tfstate"; : >"$MOCK_HOME/bucket-exists"; }
remote=(--aws --account 111111111111 --region us-east-1)
new_case; run_ok; [[ ! -s $MOCK_HOME/aws.calls ]]; [[ ! -e $MOCK_HOME/cloud/infra/bootstrap/.terraform ]]
run_ok verify; [[ ! -s $MOCK_HOME/aws.calls ]]
run_fail 'exige --plan' apply; [[ ! -s $MOCK_HOME/aws.calls ]]
run_fail 'requer --aws' plan; [[ ! -s $MOCK_HOME/aws.calls ]]
new_case; export MOCK_VERSION=1.9.8; run_fail incompatível check
new_case; export MOCK_SCENARIO=account; run_fail 'Conta AWS divergente' check "${remote[@]}"
new_case; export MOCK_SCENARIO=credentials; run_fail 'Credenciais ausentes' check "${remote[@]}"
new_case; run_fail 'Confirme --account' check --aws --account 111111111111
new_case; export AWS_REGION=sa-east-1; run_fail 'Região AWS configurada diverge' check; export AWS_REGION=us-east-1
new_case; : >"$MOCK_HOME/bucket-exists"; run_fail 'sem state de bootstrap' check "${remote[@]}"
new_case; export MOCK_SCENARIO=forbidden; run_fail 'HeadBucket negado' plan "${remote[@]}"
new_case; cp "$MOCK_FIXTURES/managed.tfstate" "$MOCK_HOME/cloud/infra/bootstrap/old.tfstate"; run_fail 'Outro state' plan "${remote[@]}"; [[ ! -s $MOCK_HOME/aws.calls ]]
new_case; managed; jq '.resources[0].instances[0].attributes.bucket="old-bucket"' "$MOCK_FIXTURES/managed.tfstate" >"$MOCK_HOME/cloud/infra/bootstrap/terraform.tfstate"; run_fail 'State selecionado inválido' check
new_case; echo 'state_bucket_name = "old-bucket"' >"$MOCK_HOME/cloud/infra/bootstrap/terraform.tfvars"; run_fail 'tfvars privado diverge' plan "${remote[@]}"
new_case; mkdir -p "$MOCK_HOME/cloud/infra/.terraform"; echo '{"backend":{"type":"s3","config":{"bucket":"old-bucket"}}}' >"$MOCK_HOME/cloud/infra/.terraform/terraform.tfstate"; run_fail 'Backend anterior divergente' init-backends "${remote[@]}" --permissions-reviewed
new_case; managed; export MOCK_SCENARIO=region; run_fail 'região divergente' verify "${remote[@]}"
new_case; managed; export MOCK_SCENARIO=drift; run_fail 'Segurança divergente' verify "${remote[@]}"; run_ok plan "${remote[@]}"
new_case; managed; export MOCK_SCENARIO=history; run_fail 'histórico' init-backends "${remote[@]}" --permissions-reviewed
new_case; managed; export MOCK_SCENARIO=lock; run_fail 'Lock existente' init-backends "${remote[@]}" --permissions-reviewed
new_case; managed; run_fail 'permissões efetivas' init-backends "${remote[@]}"
new_case; managed; export MOCK_SCENARIO=remote; run_ok verify "${remote[@]}"; run_ok verify "${remote[@]}"; run_ok init-backends "${remote[@]}" --permissions-reviewed; run_ok init-backends "${remote[@]}" --permissions-reviewed
[[ $(grep -c '^apply$' "$MOCK_HOME/terraform.calls" || true) == 0 ]]
for scenario in delete badplan wrongplanaccount; do new_case; export MOCK_SCENARIO=$scenario; run_fail 'Plano rejeitado' plan "${remote[@]}"; done
new_case; run_ok plan "${remote[@]}"; run_ok plan "${remote[@]}"
plan=$(find "$MOCK_HOME/cloud/infra/bootstrap/.terraform/numberone-bootstrap" -name bootstrap.tfplan | head -1)
token="APPLY:111111111111:$bucket:$(sha256sum "$plan" | cut -d ' ' -f1)"
run_fail 'exige --plan' apply "${remote[@]}" --plan "$plan"
run_fail 'Confirmação divergente' apply "${remote[@]}" --plan "$plan" --confirm INVALID
run_ok apply "${remote[@]}" --plan "$plan" --confirm "$token"
run_fail 'já aplicado/tentado' apply "${remote[@]}" --plan "$plan" --confirm "$token"
run_ok verify "${remote[@]}"
run_ok plan "${remote[@]}"
[[ $(grep -c '^apply$' "$MOCK_HOME/terraform.calls") == 1 ]]
new_case; run_ok plan "${remote[@]}"
plan=$(find "$MOCK_HOME/cloud/infra/bootstrap/.terraform/numberone-bootstrap" -name bootstrap.tfplan | head -1)
token="APPLY:111111111111:$bucket:$(sha256sum "$plan" | cut -d ' ' -f1)"
printf '\ntampered\n' >>"$plan"
run_fail 'Confirmação divergente' apply "${remote[@]}" --plan "$plan" --confirm "$token"
new_case; run_ok plan "${remote[@]}"
plan=$(find "$MOCK_HOME/cloud/infra/bootstrap/.terraform/numberone-bootstrap" -name bootstrap.tfplan | head -1)
token="APPLY:111111111111:$bucket:$(sha256sum "$plan" | cut -d ' ' -f1)"
managed
run_fail 'mudou desde plan' apply "${remote[@]}" --plan "$plan" --confirm "$token"
new_case; cp "$MOCK_FIXTURES/managed.tfstate" "$MOCK_HOME/cloud/infra/bootstrap/terraform.tfstate.backup"; run_fail 'backup sem o state principal' check
new_case; managed; mv "$MOCK_HOME/bucket-exists" "$MOCK_HOME/bucket-was-present"; run_fail 'existe state gerenciado' plan "${remote[@]}"
new_case; managed; mkdir -p "$MOCK_HOME/cloud/infra/bootstrap/.terraform"; echo '{"backend":{"type":"s3"}}' >"$MOCK_HOME/cloud/infra/bootstrap/.terraform/terraform.tfstate"; run_fail 'backend anterior remoto' check
new_case; cp "$MOCK_FIXTURES/managed.tfstate" "$MOCK_HOME/cloud/infra/terraform.tfstate"; run_fail 'State local anterior' init-backends "${remote[@]}" --permissions-reviewed
new_case; echo '# removed vars' >"$MOCK_HOME/cloud/.github/workflows/terraform-deploy.yml"; run_fail 'Workflow sem bucket/região' check
new_case; run_ok plan "${remote[@]}" --state academy.tfstate
plan=$(find "$MOCK_HOME/cloud/infra/bootstrap/.terraform/numberone-bootstrap" -name bootstrap.tfplan | head -1)
token="APPLY:111111111111:$bucket:$(sha256sum "$plan" | cut -d ' ' -f1)"
run_ok apply "${remote[@]}" --state academy.tfstate --plan "$plan" --confirm "$token"
[[ -f $MOCK_HOME/cloud/infra/bootstrap/academy.tfstate && ! -e $MOCK_HOME/cloud/infra/bootstrap/terraform.tfstate ]]
run_ok verify "${remote[@]}" --state academy.tfstate
new_case; mv "$MOCK_HOME/postech15soat-infra-database" "$MOCK_HOME/database-not-checked-out"
run_ok check --bootstrap-only
run_fail 'Backend ausente' check
run_fail 'não pode inicializar' init-backends --bootstrap-only
cat >"$test_root/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$MOCK_HOME/gh.calls"
if [[ $1 == api ]]; then
  if [[ $2 == --paginate ]]; then
    jq -s '{workflow_runs:(sort_by(.id)|reverse|map(.+{run_number:.id}))}' "$MOCK_HOME"/github/*/metadata.json
  else
    id=${2##*/}; cat "$MOCK_HOME/github/$id/metadata.json"
  fi
elif [[ $1 == run && $2 == download ]]; then
  id=$3; shift 3; destination=''; name=''
  while (($#)); do
    case $1 in --dir) destination=$2 ;; --name) name=$2 ;; esac
    shift 2
  done
  if [[ $name == numberone-phase4-bootstrap-plan ]]; then file=plan.tar; else file=state.tar; fi
  cp "$MOCK_HOME/github/$id/$file" "$destination/$file"
else exit 99; fi
MOCK
chmod +x "$test_root/bin/gh"
new_case
export GITHUB_RUN_ATTEMPT=1
export GITHUB_ACTIONS=true GITHUB_REF=refs/heads/main GITHUB_REPOSITORY=numberone/cloud
export GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_RUN_ID=101
export BOOTSTRAP_ACCOUNT=111111111111 TF_STATE_BUCKET=numberone-terraform-state
export BOOTSTRAP_PLAN_RUN_ID='' BOOTSTRAP_CONFIRMATION=''
# Placeholders only; mocks never consume real credentials.
export AWS_ACCESS_KEY_ID=fixture AWS_SECRET_ACCESS_KEY=fixture AWS_SESSION_TOKEN=fixture
mkdir -p "$MOCK_HOME/github/101"
jq -n '{id:101,event:"workflow_dispatch",head_branch:"main",path:".github/workflows/terraform-bootstrap.yml",status:"completed",conclusion:"success",head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",display_title:"Terraform bootstrap / plan"}' >"$MOCK_HOME/github/101/metadata.json"
cli_script=$script; script="$MOCK_HOME/cloud/scripts/bootstrap-state-ci.sh"
run_ok plan
transfer="$MOCK_HOME/cloud/infra/bootstrap/.terraform/ci-transfer"
cp "$transfer/upload/plan.tar" "$MOCK_HOME/github/101/plan.tar"
plan=$(find "$MOCK_HOME/cloud/infra/bootstrap/.terraform/numberone-bootstrap" -name bootstrap.tfplan | head -1)
export BOOTSTRAP_CONFIRMATION="APPLY:111111111111:$bucket:$(sha256sum "$plan" | cut -d ' ' -f1)"
export BOOTSTRAP_PLAN_RUN_ID=101
# Simulate a fresh runner at the same checkout path, with only immutable artifacts carried over.
mv "$MOCK_HOME/cloud/infra/bootstrap/.terraform" "$MOCK_HOME/runner-cache.101"
export GITHUB_RUN_ID=102
run_ok apply
run_ok checkpoint
mkdir -p "$MOCK_HOME/github/102"
cp "$transfer/upload/state.tar" "$MOCK_HOME/github/102/state.tar"
jq '.id=102 | .display_title="Terraform bootstrap / apply"' "$MOCK_HOME/github/101/metadata.json" >"$MOCK_HOME/github/102/metadata.json"
mv "$MOCK_HOME/cloud/infra/bootstrap/.terraform" "$MOCK_HOME/runner-cache.102"
mv "$MOCK_HOME/cloud/infra/bootstrap/terraform.tfstate" "$MOCK_HOME/runner-state.102"
export GITHUB_RUN_ID=103 BOOTSTRAP_PLAN_RUN_ID='' BOOTSTRAP_CONFIRMATION=''
run_ok verify
[[ $(grep -c '^apply$' "$MOCK_HOME/terraform.calls") == 1 ]]
mv "$MOCK_HOME/cloud/infra/bootstrap/.terraform" "$MOCK_HOME/runner-cache.103"
mv "$MOCK_HOME/cloud/infra/bootstrap/terraform.tfstate" "$MOCK_HOME/runner-state.103"
export GITHUB_RUN_ID=104 BOOTSTRAP_PLAN_RUN_ID=101
export BOOTSTRAP_CONFIRMATION="APPLY:111111111111:$bucket:$(sha256sum "$MOCK_HOME/runner-cache.101/numberone-bootstrap/"plan.*/bootstrap.tfplan | cut -d ' ' -f1)"
run_fail 'Checkpoint, diretório ou commit mudou' apply
[[ $(grep -c '^apply$' "$MOCK_HOME/terraform.calls") == 1 ]]
mv "$MOCK_HOME/cloud/infra/bootstrap/.terraform" "$MOCK_HOME/runner-cache.104"
mv "$MOCK_HOME/cloud/infra/bootstrap/terraform.tfstate" "$MOCK_HOME/runner-state.104"
export GITHUB_RUN_ID=105 BOOTSTRAP_PLAN_RUN_ID='' BOOTSTRAP_CONFIRMATION=''
run_ok plan
mkdir -p "$MOCK_HOME/github/105"
cp "$transfer/upload/plan.tar" "$MOCK_HOME/github/105/plan.tar"
jq '.id=105' "$MOCK_HOME/github/101/metadata.json" >"$MOCK_HOME/github/105/metadata.json"
plan=$(find "$MOCK_HOME/cloud/infra/bootstrap/.terraform/numberone-bootstrap" -name bootstrap.tfplan | head -1)
export BOOTSTRAP_CONFIRMATION="APPLY:111111111111:$bucket:$(sha256sum "$plan" | cut -d ' ' -f1)"
mv "$MOCK_HOME/cloud/infra/bootstrap/.terraform" "$MOCK_HOME/runner-cache.105"
mv "$MOCK_HOME/cloud/infra/bootstrap/terraform.tfstate" "$MOCK_HOME/runner-state.105"
export GITHUB_RUN_ID=106 BOOTSTRAP_PLAN_RUN_ID=105 MOCK_SCENARIO=partial
run_fail 'Terraform falhou' apply
run_ok checkpoint
mkdir -p "$MOCK_HOME/github/106"
cp "$transfer/upload/state.tar" "$MOCK_HOME/github/106/state.tar"
jq '.id=106 | .conclusion="failure"' "$MOCK_HOME/github/102/metadata.json" >"$MOCK_HOME/github/106/metadata.json"
mv "$MOCK_HOME/cloud/infra/bootstrap/.terraform" "$MOCK_HOME/runner-cache.106"
mv "$MOCK_HOME/cloud/infra/bootstrap/terraform.tfstate" "$MOCK_HOME/runner-state.106"
export GITHUB_RUN_ID=107 BOOTSTRAP_PLAN_RUN_ID='' BOOTSTRAP_CONFIRMATION='' MOCK_SCENARIO=''
run_ok verify
[[ $(grep -c '^apply$' "$MOCK_HOME/terraform.calls") == 2 ]]
mv "$MOCK_HOME/cloud/infra/bootstrap/.terraform" "$MOCK_HOME/runner-cache.107"
mv "$MOCK_HOME/cloud/infra/bootstrap/terraform.tfstate" "$MOCK_HOME/runner-state.107"
export GITHUB_RUN_ID=109
mkdir -p "$MOCK_HOME/github/108"
jq '.id=108 | .conclusion="failure"' "$MOCK_HOME/github/106/metadata.json" >"$MOCK_HOME/github/108/metadata.json"
run_fail 'Artefato ausente/expirado/inacessível' verify
printf 'Todos os testes passaram. Fixtures privadas para inspeção: %s\n' "$test_root"
