#!/usr/bin/env bash
# GitHub runner adapter; never imports or migrates. The local CLI owns AWS operations.
set -Eeuo pipefail
set +x
umask 077
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
bootstrap_dir="$repo_root/infra/bootstrap"
transfer_dir="$bootstrap_dir/.terraform/ci-transfer"
fail() { printf 'ERRO CI: %s\n' "$*" >&2; exit 1; }
mode=${1:-}
[[ $mode == plan || $mode == apply || $mode == verify || $mode == checkpoint ]] || fail 'Use plan, apply, verify ou checkpoint (somente runner GitHub).'
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REF:-} == refs/heads/main ]] || fail 'Execute pelo workflow manual na main; este adaptador depende do contexto GitHub.'
[[ ${GITHUB_RUN_ATTEMPT:-1} == 1 ]] || fail 'Não use Re-run para bootstrap. Prepare uma nova execução manual com plano/checkpoint revisados.'
for dependency in jq gh tar sha256sum; do command -v "$dependency" >/dev/null || fail "Dependência ausente: $dependency."; done
[[ ${BOOTSTRAP_ACCOUNT:-} =~ ^[0-9]{12}$ ]] || fail 'Conta Academy confirmada deve ter 12 dígitos.'
[[ ${TF_STATE_BUCKET:-} == numberone-terraform-state && ${AWS_REGION:-} == us-east-1 ]] || fail 'Configure TF_STATE_BUCKET=numberone-terraform-state e AWS_REGION=us-east-1 na organização.'
[[ ${GITHUB_RUN_ID:-} =~ ^[0-9]+$ && ${GITHUB_RUN_NUMBER:-} =~ ^[0-9]+$ && ${GITHUB_SHA:-} =~ ^[a-f0-9]{40}$ && ${GITHUB_REPOSITORY:-} =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || fail 'Contexto GitHub inválido.'
mkdir -p "$transfer_dir/upload"

write_context() {
  jq -n --arg account "$BOOTSTRAP_ACCOUNT" --arg repository "$GITHUB_REPOSITORY" --arg commit "$GITHUB_SHA" \
    --arg run "$GITHUB_RUN_ID" --arg checkpoint "$checkpoint_run" --arg root "$repo_root" \
    '{account:$account,repository:$repository,commit:$commit,run:$run,checkpoint:$checkpoint,root:$root,bucket:"numberone-terraform-state",region:"us-east-1"}' >"$1"
}
validate_context() {
  jq -e --arg a "$BOOTSTRAP_ACCOUNT" --arg r "$GITHUB_REPOSITORY" '
    .account==$a and .repository==$r and .bucket=="numberone-terraform-state" and .region=="us-east-1"
  ' "$1" >/dev/null || fail 'Artefato de outra conta/repositório/bucket/região. Não haverá uso de state vazio ou import.'
}

# Always runs after apply, including Terraform/provider/verification failure.
if [[ $mode == checkpoint ]]; then
  if [[ ! -f $transfer_dir/session.json ]]; then
    printf 'Execução não chegou à sessão validada; nenhum checkpoint disponível. Investigue antes de nova operação.\n'
    exit 0
  fi
  validate_context "$transfer_dir/session.json"
  checkpoint_run=$GITHUB_RUN_ID
  stage=$(mktemp -d "$transfer_dir/checkpoint.XXXXXXXX")
  write_context "$stage/context.json"
  files=(context.json)
  for name in terraform.tfstate terraform.tfstate.backup; do
    if [[ -f $bootstrap_dir/$name && ! -L $bootstrap_dir/$name ]]; then
      cp -p -- "$bootstrap_dir/$name" "$stage/$name"
      files+=("$name")
    fi
  done
  tar -C "$stage" -cf "$transfer_dir/upload/state.tar" "${files[@]}"
  exit 0
fi

for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
  [[ -n ${!name:-} ]] || fail "Secret temporário $name indisponível. Renove/libere a sessão Academy na organização."
done
[[ ! -e $transfer_dir/session.json ]] || fail 'Diretório de transferência já usado. Preserve os arquivos e utilize um runner limpo.'
[[ ! -e $bootstrap_dir/terraform.tfstate && ! -e $bootstrap_dir/terraform.tfstate.backup ]] || fail 'State já presente no runner. Não haverá sobrescrita; investigue a origem.'
if [[ $mode == apply ]]; then
  [[ ${BOOTSTRAP_PLAN_RUN_ID:-} =~ ^[0-9]+$ && ${BOOTSTRAP_PLAN_RUN_ID} != "$GITHUB_RUN_ID" ]] || fail 'apply exige plan_run_id anterior.'
  [[ ${BOOTSTRAP_CONFIRMATION:-} =~ ^APPLY:${BOOTSTRAP_ACCOUNT}:numberone-terraform-state:[a-f0-9]{64}$ ]] || fail 'apply exige token de confirmação do plano revisado.'
else
  [[ -z ${BOOTSTRAP_PLAN_RUN_ID:-} && -z ${BOOTSTRAP_CONFIRMATION:-} ]] || fail 'plan_run_id/confirm_apply são exclusivos de apply.'
fi

fetch_bundle() {
  local run=$1 artifact=$2 destination=$3 metadata archive entry listing
  metadata=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run") || fail 'Não foi possível consultar a execução GitHub. Revise actions:read e disponibilidade do serviço.'
  jq -e '.event=="workflow_dispatch" and .head_branch=="main" and .path==".github/workflows/terraform-bootstrap.yml" and .status=="completed"' <<< "$metadata" >/dev/null || fail 'Origem do artefato não é uma execução manual concluída do bootstrap na main.'
  if [[ $artifact == numberone-phase4-bootstrap-plan ]]; then
    jq -e --arg sha "$GITHUB_SHA" '.head_sha==$sha and .conclusion=="success" and .display_title=="Terraform bootstrap / plan"' <<< "$metadata" >/dev/null || fail 'Plano de outro commit ou execução plan sem sucesso. Gere/revise novo plano no commit atual.'
  fi
  mkdir -p "$destination/download"
  gh run download "$run" --repo "$GITHUB_REPOSITORY" --name "$artifact" --dir "$destination/download" || fail 'Artefato ausente/expirado/inacessível. Reconcilie o checkpoint; não reinicie com state vazio.'
  if [[ $artifact == numberone-phase4-bootstrap-plan ]]; then archive="$destination/download/plan.tar"; else archive="$destination/download/state.tar"; fi
  [[ -f $archive && ! -L $archive ]] || fail 'Bundle regular esperado não encontrado no artefato.'
  listing=$(tar -tf "$archive") || fail 'Bundle inválido.'
  while IFS= read -r entry; do
    [[ $entry != /* && $entry != *'..'* ]] || fail 'Caminho inseguro no bundle.'
    case $entry in
      context.json|terraform.tfstate|terraform.tfstate.backup|plan/|plan/plan.*/|plan/plan.*/*.tf|plan/plan.*/.terraform.lock.hcl|plan/plan.*/bootstrap.tfplan|plan/plan.*/plan.json|plan/plan.*/manifest.json|plan/plan.*/terraform.log) ;;
      *) fail "Entrada inesperada no bundle: $entry" ;;
    esac
  done <<< "$listing"
  # No symbolic/hard links or special files, even in a trusted workflow artifact.
  tar -tvf "$archive" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit bad}' || fail 'Links ou arquivos especiais no bundle.'
  tar -C "$destination" --no-same-owner --no-same-permissions --keep-old-files -xf "$archive"
  validate_context "$destination/context.json"
  jq -e --arg run "$run" '.run==$run' "$destination/context.json" >/dev/null || fail 'Run do manifesto diverge da origem GitHub.'
}

# The newest apply run is the authoritative checkpoint, including failed/cancelled runs.
# Missing/expired checkpoint must block; never fall back to an older state.
checkpoint_run=$(gh api --paginate "repos/$GITHUB_REPOSITORY/actions/workflows/terraform-bootstrap.yml/runs?event=workflow_dispatch&branch=main&per_page=100" |
  jq -sr --arg current "$GITHUB_RUN_ID" '[.[] | .workflow_runs[] | select((.id|tostring)!=$current and .display_title=="Terraform bootstrap / apply")][0].id // empty') || fail 'Histórico GitHub indisponível; origem do state não comprovada.'
if [[ -n $checkpoint_run ]]; then
  checkpoint_dir=$(mktemp -d "$transfer_dir/restore-state.XXXXXXXX")
  fetch_bundle "$checkpoint_run" numberone-phase4-bootstrap-state "$checkpoint_dir"
  for name in terraform.tfstate terraform.tfstate.backup; do
    [[ ! -f $checkpoint_dir/$name ]] || cp -p -- "$checkpoint_dir/$name" "$bootstrap_dir/$name"
  done
fi
write_context "$transfer_dir/session.json"
common=(--bootstrap-only --aws --account "$BOOTSTRAP_ACCOUNT" --region us-east-1)
if [[ $mode == apply ]]; then
  plan_dir=$(mktemp -d "$transfer_dir/restore-plan.XXXXXXXX")
  fetch_bundle "$BOOTSTRAP_PLAN_RUN_ID" numberone-phase4-bootstrap-plan "$plan_dir"
  jq -e --arg checkpoint "$checkpoint_run" --arg root "$repo_root" --arg sha "$GITHUB_SHA" \
    '.checkpoint==$checkpoint and .root==$root and .commit==$sha' "$plan_dir/context.json" >/dev/null || fail 'Checkpoint, diretório ou commit mudou desde plan. Gere/revise novo plano.'
  shopt -s nullglob
  plans=("$plan_dir"/plan/plan.*)
  ((${#plans[@]} == 1)) || fail 'O bundle deve conter exatamente um plano.'
  destination="$bootstrap_dir/.terraform/numberone-bootstrap/${plans[0]##*/}"
  [[ ! -e $destination ]] || fail 'Diretório do plano já existe; não haverá sobrescrita.'
  mkdir -p "${destination%/*}"
  cp -Rp -- "${plans[0]}" "$destination"
  # Restore only providers. The saved plan and source snapshot stay unchanged.
  terraform -chdir="$destination" init -backend=false -input=false -lockfile=readonly >"$destination/restore.log" 2>&1 || fail 'Não foi possível restaurar providers. Preserve o artefato e examine o log privado.'
  "$script_dir/bootstrap-state.sh" apply "${common[@]}" --plan "$destination/bootstrap.tfplan" --confirm "$BOOTSTRAP_CONFIRMATION"
else
  "$script_dir/bootstrap-state.sh" "$mode" "${common[@]}"
fi
if [[ $mode == plan ]]; then
  shopt -s nullglob
  plans=("$bootstrap_dir"/.terraform/numberone-bootstrap/plan.*)
  ((${#plans[@]} == 1)) || fail 'Runner deve conter somente o novo plano desta execução.'
  stage=$(mktemp -d "$transfer_dir/plan-bundle.XXXXXXXX")
  mkdir -p "$stage/plan/${plans[0]##*/}"
  cp -- "$transfer_dir/session.json" "$stage/context.json"
  for name in main.tf variables.tf providers.tf versions.tf outputs.tf account_override.tf .terraform.lock.hcl bootstrap.tfplan plan.json manifest.json terraform.log; do
    cp -- "${plans[0]}/$name" "$stage/plan/${plans[0]##*/}/$name"
  done
  tar -C "$stage" -cf "$transfer_dir/upload/plan.tar" context.json plan
fi
printf 'Pipeline %s concluído. Preserve os artefatos privados e consulte docs/bootstrap-state.md.\n' "$mode"
