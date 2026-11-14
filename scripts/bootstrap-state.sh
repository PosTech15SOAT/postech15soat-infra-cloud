#!/usr/bin/env bash
# AWS access is opt-in. No import, state migration or backend substitution.
set -Eeuo pipefail
set +x
umask 077
trap 'printf "ERRO: falha na linha %s. Preserve os arquivos e confira dependências/permissões antes de retomar.\n" "$LINENO" >&2' ERR
export AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
bootstrap_dir="$repo_root/infra/bootstrap"
database_dir="$(dirname -- "$repo_root")/postech15soat-infra-database"
validator="$script_dir/lib/bootstrap-state.jq"
bucket=numberone-terraform-state
region=us-east-1
account=''
region_confirmed=''
allow_aws=false
permissions_reviewed=false
bootstrap_only=false
state_name=terraform.tfstate
plan_file=''
confirmation=''
mode=check
if (($#)) && [[ $1 != -* ]]; then mode=$1; shift; fi

fail() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
usage() {
  cat <<'HELP'
Uso: bootstrap-state.sh [check|bucket-status|plan|apply|verify|init-backends] [opções]
Sem argumento: check local, sem chamadas AWS ou alterações em arquivos.
  --bootstrap-only         Verifica somente o Cloud/bootstrap; não exige checkout Database.
  --aws                    Autoriza consultas AWS; necessário para os demais modos.
  --account ID             Conta Academy esperada (12 dígitos, confirmados pelo operador).
  --region us-east-1       Confirma explicitamente a região.
  --state NOME.tfstate     State dentro de infra/bootstrap (padrão: terraform.tfstate).
  --plan CAMINHO           Plano gerado por este script, obrigatório para apply.
  --confirm TOKEN          Token específico mostrado após plan; obrigatório para apply.
  --permissions-reviewed   Operador revisou permissões de escrita/locks; para init-backends.
  --database-dir CAMINHO   Raiz Database (padrão: repositório irmão).
  --help                   Mostra esta ajuda.
plan e init-backends alteram arquivos locais. apply altera AWS e o state local.
check e verify são somente leitura; verify sem --aws informa as verificações pendentes.
HELP
}
while (($#)); do
  case $1 in
    --aws) allow_aws=true; shift ;;
    --bootstrap-only) bootstrap_only=true; shift ;;
    --permissions-reviewed) permissions_reviewed=true; shift ;;
    --account|--region|--state|--plan|--confirm|--database-dir)
      (($# >= 2)) || fail "Falta valor para $1. Use --help."
      case $1 in
        --account) account=$2 ;; --region) region_confirmed=$2 ;;
        --state) state_name=$2 ;; --plan) plan_file=$2 ;;
        --confirm) confirmation=$2 ;; --database-dir) database_dir=$2 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Opção desconhecida: $1. Use --help." ;;
  esac
done
case $mode in check|bucket-status|plan|apply|verify|init-backends) ;; *) fail "Modo desconhecido: $mode. Use --help." ;; esac
[[ $mode != init-backends || $bootstrap_only == false ]] || fail '--bootstrap-only não pode inicializar os backends. Disponibilize o Database e execute a verificação completa.'
[[ $state_name =~ ^[a-zA-Z0-9_-]+\.tfstate$ ]] || fail '--state deve ser um nome simples terminado em .tfstate, dentro de infra/bootstrap.'
state_file="$bootstrap_dir/$state_name"
[[ ! -L $state_file ]] || fail 'State simbólico: selecione o arquivo original após revisão.'

require_dependencies() {
  local dependency missing=false version major minor
  for dependency in terraform aws jq sha256sum realpath flock; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
      info "Dependência ausente: $dependency. Instale-a antes da execução."
      missing=true
    fi
  done
  [[ $missing == false ]] || fail 'Dependências incompletas. Nenhuma consulta AWS realizada.'
  version=$(terraform version -json | jq -er '.terraform_version') || fail 'Não foi possível consultar a versão local do Terraform.'
  [[ $version =~ ^([0-9]+)\.([0-9]+)\.[0-9]+$ ]] || fail 'Use uma versão estável do Terraform >= 1.10.'
  major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}
  ((major > 1 || (major == 1 && minor >= 10))) || fail "Terraform $version incompatível. Use >= 1.10."
  info "Terraform $version; AWS CLI e jq disponíveis."
  local name
  for name in ${!TF_CLI_ARGS@} ${!AWS_ENDPOINT_URL@}; do
    [[ -z ${!name} ]] || fail "$name altera a execução; remova essa configuração antes de continuar."
  done
  [[ -z ${TF_DATA_DIR:-} && ${TF_WORKSPACE:-default} == default ]] || fail 'TF_DATA_DIR/TF_WORKSPACE personalizado: reconcilie o backend/workspace antes de continuar.'
  [[ -z ${TF_STATE_BUCKET:-} || $TF_STATE_BUCKET == "$bucket" ]] || fail 'TF_STATE_BUCKET diverge de numberone-terraform-state. Corrija o ambiente.'
  local configured_region=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
  if [[ -z $configured_region && $allow_aws == true ]]; then configured_region=$(aws configure get region 2>/dev/null || true); fi
  [[ -z $configured_region || $configured_region == "$region" ]] || fail 'Região AWS configurada diverge de us-east-1. Corrija o perfil/ambiente.'
  [[ -z ${AWS_DEFAULT_REGION:-} || $AWS_DEFAULT_REGION == "$region" ]] || fail 'AWS_DEFAULT_REGION diverge de us-east-1.'
  info "Destino fixo: $bucket / $region. Sem --aws, perfis AWS não são lidos."
}

check_backend_config() {
  local directory=$1 key=$2 cache="$1/.terraform/terraform.tfstate" file
  [[ ! -L $directory/.terraform && ! -L $directory/.terraform/terraform.tfstate ]] || fail "Cache de backend simbólico em $directory. Revise o diretório original antes de continuar."
  [[ -f $directory/backend.tf ]] || fail "Backend ausente em $directory. Confira --database-dir."
  grep -Eq 'backend "s3"' "$directory/backend.tf" &&
    grep -Eq "key[[:space:]]*=[[:space:]]*\"$key\"" "$directory/backend.tf" &&
    grep -Eq 'use_lockfile[[:space:]]*=[[:space:]]*true' "$directory/backend.tf" &&
    grep -Eq 'encrypt[[:space:]]*=[[:space:]]*true' "$directory/backend.tf" || fail "Backend divergente: $directory. Revise bucket, key, criptografia e locking."
  if grep -Eq '^[[:space:]]*(bucket|region)[[:space:]]*=' "$directory/backend.tf"; then
    ! grep -Eq '^[[:space:]]*bucket[[:space:]]*=' "$directory/backend.tf" ||
      grep -Eq "bucket[[:space:]]*=[[:space:]]*\"$bucket\"" "$directory/backend.tf" || fail "Bucket fixado incorretamente em $directory/backend.tf."
    ! grep -Eq '^[[:space:]]*region[[:space:]]*=' "$directory/backend.tf" ||
      grep -Eq 'region[[:space:]]*=[[:space:]]*"us-east-1"' "$directory/backend.tf" || fail "Região divergente em $directory/backend.tf."
  fi
  [[ ! -e $directory/.terraform/environment ]] ||
    [[ $(<"$directory/.terraform/environment") == default ]] || fail "Workspace anterior em $directory. Revise antes de inicializar."
  if [[ -f $cache ]]; then
    info "Configuração anterior de backend detectada: $cache"
    jq -e --arg b "$bucket" --arg k "$key" --arg r "$region" '
      .backend.type == "s3" and .backend.config.bucket == $b and .backend.config.key == $k and
      .backend.config.region == $r and .backend.config.encrypt == true and .backend.config.use_lockfile == true and
      (.backend.config.access_key // "") == "" and (.backend.config.secret_key // "") == "" and
      (.backend.config.token // "") == "" and (.backend.config.profile // "") == "" and
      (.backend.config.role_arn // "") == "" and (.backend.config.assume_role // {} | length == 0) and
      (.backend.config.assume_role_with_web_identity // {} | length == 0) and
      (.backend.config.endpoints // {} | all(.[]; . == null or . == "")) and
      (.backend.config.endpoint // "") == ""
    ' "$cache" >/dev/null 2>&1 || fail "Backend anterior divergente em $directory. Reconciliação manual; nenhuma migração/reconfiguração automática."
  fi
  for file in "$directory"/*.tfstate "$directory"/*.tfstate.backup "$directory"/terraform.tfstate.d; do
    [[ ! -e $file ]] || fail "State local anterior detectado: $file. Inspecione lineage/serial/recursos e preserve backup antes de decidir qualquer migração."
  done
}

check_private_variables() {
  local file
  for file in "$bootstrap_dir"/*.tfvars "$bootstrap_dir"/*.tfvars.json; do
    [[ -f $file ]] || continue
    info "Arquivo privado detectado (valores omitidos): $file"
    case $file in
      *.json)
        jq -e --arg b "$bucket" --arg r "$region" '
          (.state_bucket_name // $b) == $b and (.aws_region // $r) == $r
        ' "$file" >/dev/null 2>&1 || fail 'Variáveis privadas divergentes ou inválidas. Reconcilie bucket/região sem sobrescrever o arquivo.' ;;
      *)
        # Inspect only bucket/region assignments. Never evaluate/source private files.
        awk -v bucket="$bucket" -v region="$region" '
          /^[[:space:]]*(state_bucket_name|aws_region)[[:space:]]*=/ {
            key=$0; sub(/^[[:space:]]*/, "", key); sub(/[[:space:]]*=.*/, "", key)
            value=$0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]*(#|\/\/).*$/, "", value); sub(/[[:space:]]*$/, "", value)
            expected=(key=="aws_region" ? region : bucket)
            if (value != "\"" expected "\"") bad=1
          } END {exit bad}
        ' "$file" || fail 'Bucket/região em tfvars privado diverge ou exige interpretação manual. Reconcilie antes de plan.' ;;
    esac
  done
}

state_fingerprint() {
  if [[ -f $state_file ]]; then sha256sum "$state_file" | cut -d ' ' -f1; else printf 'absent\n'; fi
}
report_local_files() {
  local file
  for file in "$bootstrap_dir"/*.tfstate* "$bootstrap_dir"/*.tfvars* \
    "$bootstrap_dir/.terraform/terraform.tfstate" "$repo_root/infra/.terraform/terraform.tfstate" \
    "$database_dir/.terraform/terraform.tfstate"; do
    [[ $file != *.example ]] || continue
    [[ ! -e $file ]] || info "Inventário local (conteúdo privado omitido): $file"
  done
}
check_bootstrap_state() {
  local file cache="$bootstrap_dir/.terraform/terraform.tfstate"
  [[ ! -L $bootstrap_dir/.terraform ]] || fail 'Cache do bootstrap é simbólico. Reconcilie seu destino antes de continuar.'
  [[ ! -f $cache ]] || jq -e '.backend == null or .backend.type == "local"' "$cache" >/dev/null 2>&1 ||
    fail 'Bootstrap possui backend anterior remoto ou inválido. Reconcilie manualmente; nada será substituído.'
  [[ ! -e $bootstrap_dir/.terraform/environment ]] ||
    [[ $(<"$bootstrap_dir/.terraform/environment") == default ]] || fail 'Bootstrap com workspace anterior. Reconcilie antes de continuar.'
  for file in "$bootstrap_dir"/*.tfstate "$bootstrap_dir"/*.tfstate.backup "$bootstrap_dir"/terraform.tfstate.d; do
    [[ -e $file ]] || continue
    info "State/backup detectado: $file"
    if [[ $file != "$state_file" && $file != "$state_file.backup" ]]; then
      fail 'Outro state de bootstrap foi encontrado. Identifique conta, lineage e recursos; não selecione um state vazio para substituí-lo.'
    fi
  done
  if [[ -f $state_file ]]; then
    jq -e --arg kind state --arg bucket "$bucket" --arg account "$account" --arg region "$region" -f "$validator" "$state_file" >/dev/null 2>&1 ||
      fail 'State selecionado inválido, vazio, de outro bucket ou com recursos inesperados. Reconcilie; não haverá import automático.'
    jq -r '"State selecionado: serial=\(.serial), lineage=\(.lineage), recursos=\(.resources|length). Valores omitidos."' "$state_file"
  else
    [[ ! -e $state_file.backup ]] || fail 'Existe backup sem o state principal. Restaure/verifique manualmente antes de continuar.'
    info 'Nenhum state de bootstrap selecionado existe; criação só poderá ser planejada após consultas AWS.'
  fi
}

check_workflows() {
  local file credential
  local -a workflows=("$repo_root/.github/workflows/terraform-deploy.yml")
  if [[ -f $repo_root/.github/workflows/terraform-bootstrap.yml ]]; then
    workflows+=("$repo_root/.github/workflows/terraform-bootstrap.yml")
  fi
  if [[ $bootstrap_only == false ]]; then
    workflows+=("$database_dir/.github/workflows/terraform-plan.yml" "$database_dir/.github/workflows/terraform-apply.yml")
  fi
  for file in "${workflows[@]}"; do
    [[ -f $file ]] || fail "Workflow ausente: $file. Revise o checkout selecionado."
    grep -Fq 'vars.TF_STATE_BUCKET' "$file" && grep -Fq 'vars.AWS_REGION' "$file" || fail "Workflow sem bucket/região esperados: $file."
    for credential in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
      grep -Fq "secrets.$credential" "$file" || fail "Workflow sem secret de sessão esperado: $file."
    done
  done
}
local_checks() {
  report_local_files
  require_dependencies
  check_backend_config "$repo_root/infra" cloud/terraform.tfstate
  if [[ $bootstrap_only == false ]]; then
    check_backend_config "$database_dir" database/terraform.tfstate
    info 'Backends locais Cloud/Database verificados: chaves distintas, encrypt e locking S3.'
  else
    info 'Escopo bootstrap: backend e workflows Database NÃO verificados neste checkout.'
  fi
  check_workflows
  info 'GitHub esperado: TF_STATE_BUCKET=numberone-terraform-state e AWS_REGION=us-east-1 na organização, com acesso dos dois repositórios.'
  info 'vars/secrets podem ser sobrescritos pelo repositório; valores remotos e permissões de escrita não são comprovados localmente.'
  grep -Eq '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true' "$bootstrap_dir/main.tf" &&
    grep -Eq '^[[:space:]]*force_destroy[[:space:]]*=[[:space:]]*false' "$bootstrap_dir/main.tf" || fail 'Proteções Terraform do bucket ausentes. Restaure antes de continuar.'
  check_bootstrap_state
  check_private_variables
}

# All AWS calls are routed through this opt-in function. Never log credentials/raw errors.
aws_read() { AWS_PAGER='' aws --region "$region" --no-cli-pager "$@"; }
confirm_identity() {
  [[ $allow_aws == true ]] || fail 'Consulta AWS não autorizada. Use --aws somente quando desejar consultar a conta.'
  [[ $account =~ ^[0-9]{12}$ && $region_confirmed == "$region" ]] || fail 'Confirme --account com 12 dígitos e --region us-east-1.'
  local identity
  identity=$(aws_read sts get-caller-identity --output json 2>/dev/null) ||
    fail 'Credenciais ausentes, expiradas ou sem acesso STS. Renove a sessão Academy pelo mecanismo seguro e tente check --aws.'
  jq -e --arg a "$account" '.Account == $a and (.Arn | type == "string")' <<< "$identity" >/dev/null || fail 'Conta AWS divergente. Pare e selecione a sessão Academy correta.'
  export AWS_REGION="$region" AWS_DEFAULT_REGION="$region"
  info "Conta AWS confirmada: $account; região confirmada: $region."
}

bucket_exists=false
inspect_bucket() {
  local owned error
  owned=$(aws_read s3api list-buckets --query "Buckets[?Name=='$bucket'].Name" --output json 2>/dev/null) ||
    fail 'Não foi possível listar buckets próprios (s3:ListAllMyBuckets). Ownership não comprovado; revise a sessão/permissões.'
  if error=$(aws_read s3api head-bucket --bucket "$bucket" --expected-bucket-owner "$account" 2>&1); then
    jq -e --arg b "$bucket" 'type == "array" and index($b) != null' <<< "$owned" >/dev/null || fail 'Bucket acessível, mas não consta entre os buckets próprios. Ownership ambíguo.'
    bucket_exists=true
    local location
    location=$(aws_read s3api get-bucket-location --bucket "$bucket" --expected-bucket-owner "$account" --output json 2>/dev/null) || fail 'Sem acesso à região do bucket. Revise s3:GetBucketLocation.'
    jq -e '.LocationConstraint == null or .LocationConstraint == "us-east-1"' <<< "$location" >/dev/null || fail 'Bucket em região divergente. Não haverá substituição.'
    info 'Bucket existente; conta proprietária e região comprovadas.'
  else
    [[ $error =~ \((404|NoSuchBucket|NotFound)\) ]] || fail 'HeadBucket negado/indeterminado (credenciais, permissões ou outra conta). Não conclua que o nome está disponível.'
    jq -e 'type == "array" and length == 0' <<< "$owned" >/dev/null || fail 'Listagem e HeadBucket inconsistentes. Pare e investigue.'
    [[ ! -f $state_file ]] || fail 'Bucket não localizado, mas existe state gerenciado. Investigue remoção, conta e acesso; não recrie automaticamente.'
    info 'Bucket não localizado na consulta; disponibilidade global NÃO comprovada. O apply ainda pode falhar por colisão do nome.'
  fi
}

check_managed_bucket() {
  if [[ $bucket_exists == true && ! -f $state_file ]]; then
    fail 'Bucket próprio existente sem state de bootstrap selecionado. Localize o state original ou faça reconciliação/import manual revisado.'
  fi
}
verify_security() {
  local operation result filter
  for operation in get-bucket-versioning get-bucket-encryption get-public-access-block get-bucket-ownership-controls; do
    result=$(aws_read s3api "$operation" --bucket "$bucket" --expected-bucket-owner "$account" --output json 2>/dev/null) || fail "Não foi possível verificar $operation. Revise configurações/permissões; use plan para corrigir somente com state reconciliado."
    case $operation in
      get-bucket-versioning) filter='.Status == "Enabled"' ;;
      get-bucket-encryption) filter='[.ServerSideEncryptionConfiguration.Rules[].ApplyServerSideEncryptionByDefault.SSEAlgorithm] == ["AES256"]' ;;
      get-public-access-block) filter='.PublicAccessBlockConfiguration | .BlockPublicAcls and .BlockPublicPolicy and .IgnorePublicAcls and .RestrictPublicBuckets' ;;
      get-bucket-ownership-controls) filter='[.OwnershipControls.Rules[].ObjectOwnership] == ["BucketOwnerEnforced"]' ;;
    esac
    jq -e "$filter" <<< "$result" >/dev/null 2>&1 || fail "Segurança divergente: $operation. Revise um plan corretivo; não será alterado por verify."
  done
  info 'S3 confirmado: versionamento Enabled, AES256, bloqueio público completo e BucketOwnerEnforced.'
}

# A successful list proves ListBucket for these prefixes, not PutObject/DeleteObject.
inspect_remote_states() {
  local key result versions
  for key in cloud/terraform.tfstate database/terraform.tfstate; do
    versions=$(aws_read s3api list-object-versions --bucket "$bucket" --expected-bucket-owner "$account" --prefix "$key" --output json 2>/dev/null) || fail "Não foi possível listar versões de $key. Revise s3:ListBucketVersions antes de inicializar."
    jq -e --arg k "$key.tflock" 'all(.Versions[]?; .Key != $k or .IsLatest != true)' <<< "$versions" >/dev/null || fail "Versão ativa de lock em $key.tflock. Aguarde/reconcilie; não remova locks."
    result=$(aws_read s3api list-objects-v2 --bucket "$bucket" --expected-bucket-owner "$account" --prefix "$key" --output json 2>/dev/null) || fail "Sem leitura/listagem do prefixo $key. Revise s3:ListBucket."
    jq -e --arg k "$key.tflock" 'all(.Contents[]?; .Key != $k)' <<< "$result" >/dev/null || fail "Lock existente em $key.tflock. Identifique a operação ativa; não remova automaticamente."
    if jq -e --arg k "$key" 'any(.Contents[]?; .Key == $k)' <<< "$result" >/dev/null; then
      # Stream to stdout internally: no downloaded state file and no attributes printed.
      local summary
      summary=$(aws_read s3api get-object --bucket "$bucket" --key "$key" --expected-bucket-owner "$account" /dev/fd/3 3>&1 >/dev/null 2>/dev/null |
        jq -er 'select(.version == 4 and (.lineage|type == "string") and (.serial|type == "number") and (.resources|type == "array")) |
          "serial=\(.serial), lineage=\(.lineage), recursos=\(.resources|length)"' 2>/dev/null) || fail "State remoto $key ilegível/inválido. Revise s3:GetObject e reconcilie."
      info "State remoto existente e preservado: $key ($summary)."
    else
      jq -e --arg k "$key" 'all((.Versions[]?, .DeleteMarkers[]?); .Key != $k)' <<< "$versions" >/dev/null || fail "Há histórico de $key sem objeto atual. Restaure/reconcilie versões antes de inicializar; não crie state vazio."
      info "Sem objeto atual ou histórico em $key. Nenhum state criado."
    fi
  done
  info 'Leitura verificada. PutObject no state e Get/Put/DeleteObject em .tflock NÃO foram testados por escrita.'
}

acquire_lock() {
  mkdir -p "$bootstrap_dir/.terraform/numberone-bootstrap"
  exec 9>"$bootstrap_dir/.terraform/numberone-bootstrap/operator.lock"
  flock -n 9 || fail 'Outra execução local está ativa. Aguarde; não exclua locks.'
}
source_hash() {
  (cd -- "$1"; sha256sum ./*.tf .terraform.lock.hcl) | sha256sum | cut -d ' ' -f1
}
run_terraform() {
  terraform -chdir="$run_dir" "$@" >>"$run_dir/terraform.log" 2>&1 || fail "Terraform falhou. Examine o log privado em $run_dir/terraform.log. Preserve state/plano; não repita apply sem reconciliação."
}
validate_plan() {
  terraform -chdir="$run_dir" show -json "$plan_file" >"$run_dir/plan.json" 2>>"$run_dir/terraform.log" || fail 'Plano ilegível/incompatível. Gere outro plan após revisão.'
  jq -e --arg kind plan --arg bucket "$bucket" --arg region "$region" --arg account "$account" -f "$validator" "$run_dir/plan.json" >/dev/null 2>&1 ||
    fail 'Plano rejeitado: recursos, ações, provider, bucket, região ou segurança inesperados. Não aplique; revise a configuração.'
}

create_plan() {
  acquire_lock
  check_bootstrap_state
  check_private_variables
  inspect_bucket
  check_managed_bucket
  # A managed bucket may have drift. The validated plan can repair settings, never delete/replace.
  run_dir=$(mktemp -d "$bootstrap_dir/.terraform/numberone-bootstrap/plan.XXXXXXXX")
  local file before hash source_before
  for file in "$bootstrap_dir"/*.tf "$bootstrap_dir"/*.tf.json; do
    [[ -f $file ]] || continue
    case ${file##*/} in main.tf|variables.tf|providers.tf|versions.tf|outputs.tf) ;; *) fail 'Arquivo Terraform adicional no bootstrap. Revise a allowlist do script antes de planejar.' ;; esac
  done
  source_before=$(source_hash "$bootstrap_dir")
  for file in main.tf variables.tf providers.tf versions.tf outputs.tf .terraform.lock.hcl; do cp -- "$bootstrap_dir/$file" "$run_dir/$file"; done
  [[ $(source_hash "$run_dir") == "$source_before" ]] || fail 'Código mudou durante a cópia. Gere outro plano após revisar.'
  printf 'provider "aws" {\n  allowed_account_ids = ["%s"]\n}\n' "$account" >"$run_dir/account_override.tf"
  plan_file="$run_dir/bootstrap.tfplan"
  before=$(state_fingerprint)
  run_terraform init -backend=false -input=false -lockfile=readonly
  run_terraform validate
  run_terraform plan -input=false -lock-timeout=30s -state="$state_file" \
    -var="aws_region=$region" -var="state_bucket_name=$bucket" -var=project_name=numberone -out="$plan_file"
  [[ $(state_fingerprint) == "$before" ]] || fail 'State mudou durante plan. Preserve os arquivos e reconcilie antes de aplicar.'
  validate_plan
  [[ $(source_hash "$bootstrap_dir") == "$source_before" ]] || fail 'Código mudou durante plan. Gere outro plano após revisar.'
  hash=$(sha256sum "$plan_file" | cut -d ' ' -f1)
  jq -n --arg account "$account" --arg bucket "$bucket" --arg region "$region" --arg state "$state_file" \
    --arg state_hash "$before" --arg source_hash "$source_before" --arg snapshot_hash "$(source_hash "$run_dir")" --arg plan_hash "$hash" \
    '{account:$account,bucket:$bucket,region:$region,state:$state,state_hash:$state_hash,source_hash:$source_hash,snapshot_hash:$snapshot_hash,plan_hash:$plan_hash}' >"$run_dir/manifest.json"
  terraform -chdir="$run_dir" show -no-color "$plan_file" || fail 'Não foi possível mostrar o plano para revisão.'
  info "Plano salvo e validado: $plan_file"
  info "Após revisar, use apply com --plan '$plan_file' e --confirm 'APPLY:$account:$bucket:$hash', além das mesmas opções --aws/--account/--region/--state."
}

apply_plan() {
  [[ -f $plan_file && -n $confirmation ]] || fail 'apply exige --plan existente e --confirm específico do plano. Execute plan e revise primeiro.'
  plan_file=$(realpath -- "$plan_file")
  case $plan_file in "$bootstrap_dir/.terraform/numberone-bootstrap/plan."*/bootstrap.tfplan) ;; *) fail 'Use um plano gerado por este script neste checkout.' ;; esac
  run_dir=$(dirname -- "$plan_file")
  [[ -f $run_dir/manifest.json && ! -e $run_dir/apply.started ]] || fail 'Manifesto ausente ou plano já aplicado/tentado. Verifique o state e gere outro plano; nunca repita cegamente.'
  local hash
  hash=$(sha256sum "$plan_file" | cut -d ' ' -f1)
  [[ $confirmation == "APPLY:$account:$bucket:$hash" ]] || fail 'Confirmação divergente. Use exatamente o token associado ao plano revisado.'
  jq -e --arg a "$account" --arg b "$bucket" --arg r "$region" --arg s "$state_file" --arg p "$hash" \
    --arg h "$(state_fingerprint)" --arg c "$(source_hash "$bootstrap_dir")" --arg snap "$(source_hash "$run_dir")" '
      .account==$a and .bucket==$b and .region==$r and .state==$s and .plan_hash==$p and .state_hash==$h and .source_hash==$c and .snapshot_hash==$snap
    ' "$run_dir/manifest.json" >/dev/null || fail 'Conta, state, código ou plano mudou desde plan. Gere e revise outro plano.'
  acquire_lock
  [[ ! -e $run_dir/apply.started ]] || fail 'Plano já aplicado/tentado por outra execução. Verifique e gere novo plano.'
  [[ $(state_fingerprint) == "$(jq -er '.state_hash' "$run_dir/manifest.json")" ]] || fail 'State mudou ao adquirir lock. Gere outro plano.'
  inspect_bucket
  check_managed_bucket
  validate_plan
  # The marker intentionally survives partial failure. Terraform also locks the local state.
  date -u +%FT%TZ >"$run_dir/apply.started"
  if [[ -f $state_file ]]; then cp -p -- "$state_file" "$run_dir/pre-apply.tfstate"; fi
  run_terraform apply -input=false -lock-timeout=30s -state="$state_file" "$plan_file"
  check_bootstrap_state
  jq -e --arg kind complete-state --arg bucket "$bucket" --arg account "$account" --arg region "$region" -f "$validator" "$state_file" >/dev/null || fail 'Apply terminou, mas o state não contém as cinco configurações esperadas. Preserve-o e investigue.'
  if [[ -f $run_dir/pre-apply.tfstate ]]; then
    jq -e --slurpfile prior "$run_dir/pre-apply.tfstate" '.lineage == $prior[0].lineage and .serial >= $prior[0].serial' "$state_file" >/dev/null || fail 'Lineage ou serial inesperado após apply. Preserve os states e reconcilie.'
  fi
  inspect_bucket
  [[ $bucket_exists == true ]] || fail 'Bucket não comprovado após apply. Preserve o state e investigue.'
  verify_security
  inspect_remote_states
  info "Apply concluído e verificado. Preserve $state_file e o backup em armazenamento seguro."
}

init_backends() {
  [[ $permissions_reviewed == true ]] || fail 'Revise permissões efetivas de state e .tflock e confirme com --permissions-reviewed. Consultas somente leitura não comprovam escrita/exclusão.'
  acquire_lock
  inspect_bucket
  [[ $bucket_exists == true ]] || fail 'Bucket ainda não comprovado. Conclua o bootstrap antes de inicializar backends.'
  check_managed_bucket
  verify_security
  inspect_remote_states
  local directory
  # Validate both repositories before touching either local backend cache.
  check_backend_config "$repo_root/infra" cloud/terraform.tfstate
  check_backend_config "$database_dir" database/terraform.tfstate
  for directory in "$repo_root/infra" "$database_dir"; do
    terraform -chdir="$directory" init -input=false -lockfile=readonly \
      -backend-config="bucket=$bucket" -backend-config="region=$region" || fail "Init falhou em $directory. Nenhuma migração será tentada. Revise o backend/cache e retome."
  done
  info "Backends inicializados sem migração. Para operações Database: export TF_VAR_cloud_state_bucket=$bucket"
}

# CI uses the same identity, owner and region checks as bootstrap. A generic
# HeadBucket 404 is not enough to skip a plan: require NoSuchBucket explicitly.
if [[ $mode == bucket-status ]]; then
  require_dependencies
  confirm_identity
  inspect_bucket
  if [[ $bucket_exists == true ]]; then
    info 'bucket_status=present'
  else
    if result=$(aws_read s3api get-bucket-location --bucket "$bucket" --expected-bucket-owner "$account" --output json 2>&1); then
      fail 'HeadBucket indicou ausência, mas GetBucketLocation respondeu com sucesso. Investigue a inconsistência.'
    fi
    [[ $result == *"An error occurred (NoSuchBucket) when calling the GetBucketLocation operation:"* ]] || fail 'Ausência do bucket não comprovada; GetBucketLocation retornou erro inconclusivo ou acesso negado.'
    info 'bucket_status=missing'
  fi
  exit 0
fi

# Missing plan/approval is rejected before any AWS request.
if [[ $mode == apply ]]; then
  [[ -f $plan_file && -n $confirmation ]] || fail 'apply exige --plan existente e --confirm. Execute plan e revise primeiro.'
fi
local_checks
if [[ $allow_aws == false ]]; then
  case $mode in
    check|verify) info 'NÃO VERIFICADO: identidade, existência/ownership/região/segurança do bucket, states remotos e permissões AWS. Nenhuma chamada AWS realizada.'; exit 0 ;;
    *) fail 'Este modo requer --aws --account ID --region us-east-1. Nenhuma chamada AWS realizada.' ;;
  esac
fi
confirm_identity
case $mode in
  check|verify)
    inspect_bucket
    if [[ $bucket_exists == true ]]; then
      check_managed_bucket
      verify_security
      inspect_remote_states
    elif [[ $mode == verify ]]; then
      fail 'Bucket não comprovado. Não declare bootstrap concluído; execute plan após reconciliação.'
    fi ;;
  plan) create_plan ;;
  apply) apply_plan ;;
  init-backends) init_backends ;;
esac
