# Bootstrap do Terraform State na AWS Academy

A automação local é `scripts/bootstrap-state.sh`. Ela utiliza o Terraform existente em `infra/bootstrap`, mantém o state local do bucket e prepara os backends sem importar recursos nem migrar states automaticamente. Todos os caminhos são resolvidos a partir do script; ele pode ser executado de qualquer diretório.

Destino fixo:

| Item | Valor |
| --- | --- |
| Bucket compartilhado | `numberone-terraform-state` |
| Região | `us-east-1` |
| State Cloud, workspace default | `cloud/terraform.tfstate` |
| State Database, workspace default | `database/terraform.tfstate` |
| Locking | S3 nativo, `use_lockfile = true`, Terraform >= 1.10 |
| Segurança | Versionamento Enabled, SSE-S3 AES256, quatro bloqueios públicos, BucketOwnerEnforced |
| Exclusão | `prevent_destroy = true`, `force_destroy = false` |

## Pré-requisitos e sessão Academy

Use Bash >= 4, Terraform estável >= 1.10, AWS CLI v2, `jq` >= 1.6 e utilitários Linux usuais (`sha256sum`, `realpath`, `flock`, `mktemp`, `awk`, `grep`, `cp`). `jq` é necessário para validar estruturalmente o JSON do plano e do state sem avaliar conteúdo privado como código. O script não instala ferramentas e não exige sudo. Para instalação sem privilégios, use binários verificados publicados pelos projetos e disponibilize-os no PATH. [Download oficial do jq](https://jqlang.org/download/).

Disponibilize os dois repositórios como diretórios irmãos ou informe `--database-dir CAMINHO`. Os arquivos `.terraform.lock.hcl` existentes são obrigatórios e não são atualizados pela automação. `terraform init` pode precisar de rede para o registry/download dos providers AWS e Helm.

Renove a sessão AWS Academy pelo mecanismo seguro aprovado para o laboratório: credenciais temporárias de sessão em perfil AWS ou no ambiente do processo, sem incluí-las nos argumentos, Git, tfvars ou logs. Não use `bash -x`. Confirme na interface Academy o ID da conta pretendida. Configure a região como `us-east-1`; nenhuma credencial é exibida pelo script. `TF_CLI_ARGS*`, `TF_DATA_DIR`, workspace diferente de default e endpoints AWS personalizados não são aceitos. Endpoints configurados no perfil são desabilitados no processo da automação.

## Interface e efeitos

| Modo | Sem `--aws` | Com `--aws --account ID --region us-east-1` | Alterações |
| --- | --- | --- | --- |
| Sem argumento / `check` | Verifica arquivos, dependências, versão, configurações e conflitos locais | Acrescenta identidade, ownership, região, segurança, states/locks remotos | Somente leitura |
| `verify` | Informa explicitamente verificações remotas pendentes | Exige bucket comprovado, state gerenciado e segurança correta | Somente leitura |
| `plan` | Recusado | Planeja criação ou correção segura de bucket já gerenciado | Arquivos locais e consultas AWS; não aplica |
| `apply` | Recusado | Aplica somente plano salvo, validado e confirmado | Modifica AWS e state local |
| `init-backends` | Recusado | Exige bootstrap comprovado e `--permissions-reviewed` | Inicializa caches locais; sem migração ou escrita intencional nos states S3 |

`check`/`verify` locais não leem perfis/credenciais AWS e não criam diretórios. Uma falha nas validações interrompe a execução com causa e próxima ação; sucesso local não comprova a situação AWS. Os modos remotos confirmam a identidade com STS. O script nunca consulta ou modifica o GitHub remoto.

## Primeiro bootstrap real

Os exemplos partem da raiz do Cloud. Substitua `<ID_CONTA_ACADEMY>` pelo ID confirmado no laboratório; ele não é uma credencial. Os comandos abaixo **não foram executados contra AWS na implementação**.

```bash
./scripts/bootstrap-state.sh check
./scripts/bootstrap-state.sh check --aws --account <ID_CONTA_ACADEMY> --region us-east-1
./scripts/bootstrap-state.sh plan --aws --account <ID_CONTA_ACADEMY> --region us-east-1
```

Antes de consultar AWS, resolva quaisquer conflitos locais indicados. O state padrão é `infra/bootstrap/terraform.tfstate`. Para um state legítimo com outro nome, use `--state NOME.tfstate` em **todos** os modos. O nome deve estar dentro de `infra/bootstrap`. Outros states no diretório bloqueiam a operação: a opção não permite ignorá-los ou substituí-los por um arquivo vazio.

`plan` cria um diretório privado e exclusivo em `infra/bootstrap/.terraform/numberone-bootstrap/plan.XXXXXXXX/`, com cópia dos arquivos Terraform conhecidos, lockfile, log, plano JSON, plano binário e manifesto. Não carrega tfvars privados; bucket/região divergentes nesses arquivos precisam ser reconciliados antes de continuar. As variáveis do bootstrap são explícitas e um override privado adiciona `allowed_account_ids` ao provider para vincular a execução à conta confirmada. O projeto Terraform de origem permanece intacto.

O plano deve conter somente os cinco recursos S3 esperados, com as proteções estabelecidas, e somente ações create/update/no-op. Exclusões, substituições, importações, movimentação de endereços, outros providers ou recursos são rejeitados. O script mostra o plano para revisão e informa seu caminho e token de confirmação. A inexistência aparente do bucket não reserva nem comprova a disponibilidade global do nome; uma colisão continua possível até a criação.

Após revisar todos os recursos e autorizar a operação, use os valores **exatos** impressos pelo modo `plan`:

```bash
./scripts/bootstrap-state.sh apply \
  --aws --account <ID_CONTA_ACADEMY> --region us-east-1 \
  --plan '<CAMINHO_DO_PLANO>' \
  --confirm 'APPLY:<ID_CONTA_ACADEMY>:numberone-terraform-state:<SHA256_DO_PLANO>'
```

`apply` não gera outro plano. Ele verifica novamente conta, bucket, state, hashes do código/snapshot/plano e valida o conteúdo do plano. Exige state inalterado desde o planejamento. O token inclui o hash do plano revisado. Um lock local serializa as execuções da automação no mesmo checkout; o próprio Terraform mantém seu lock de state. O bloqueio não coordena computadores diferentes: mantenha um único operador responsável pelo bootstrap e pelo state local.

Após apply, a automação confere os cinco recursos no state, a existência/ownership/região reais do bucket e as quatro configurações de segurança. O mesmo caminho absoluto de state é passado explicitamente em plan e apply; o arquivo não é redirecionado ao diretório temporário do plano. O state local é preservado, inclusive em falhas parciais. Um plano com tentativa de apply recebe `apply.started` e não pode ser reaplicado automaticamente.

```bash
./scripts/bootstrap-state.sh verify --aws --account <ID_CONTA_ACADEMY> --region us-east-1
```

## States existentes e recuperação

| Situação | Comportamento |
| --- | --- |
| Bucket não localizado; sem state | HeadBucket 404 e listagem dos buckets próprios vazia permitem planejar uma tentativa de criação; disponibilidade global continua não comprovada |
| Bucket próprio, região correta, state esperado | Verifica; plan pode produzir no-op ou corrigir drift sem exclusão/substituição |
| Bucket próprio, sem state selecionado | Interrompe; localize o state original ou faça reconciliação/import manual revisado |
| HeadBucket 403, respostas inconsistentes ou ownership não comprovado | Interrompe; não interpreta a negativa como nome livre |
| Segurança divergente | check/verify falham; somente plan revisado pode preparar correção com state previamente conciliado |
| Bucket não localizado, mas existe state gerenciado | Interrompe; não recria automaticamente recursos removidos ou inacessíveis |
| Outro state, backup sem principal, workspace ou backend anterior divergente | Interrompe antes de plan; nenhuma substituição silenciosa |
| State remoto válido existente | Lê somente serial, lineage e quantidade de recursos; preserva o objeto e permite init sem migração se não houver conflito local |
| Histórico remoto sem objeto atual / lock ativo | Interrompe; exige reconciliação/restauração ou término da operação ativa |
| Credenciais expiradas/ausentes/insuficientes | Interrompe; renove a sessão ou revise permissões antes de retomar |

Na limpeza autorizada pelo operador para a nova conta da Fase 4, foram removidos somente `infra/bootstrap/terraform.tfstate` (serial 3, contendo exclusivamente `aws_s3_bucket.terraform_state` do bucket anterior) e `terraform.tfstate.backup` (serial 1, vazio, com a mesma lineage). A inspeção local não encontrou consumidores desses arquivos em Cloud, Database ou outros projetos do workspace. Ambos eram arquivos regulares sem links adicionais. Nenhuma conta AWS foi consultada nessa auditoria. O `terraform.tfvars` privado recebeu somente a alteração de `state_bucket_name` para `numberone-terraform-state`; as demais configurações foram preservadas. Não há migração da Fase 3 para a Fase 4. O check local passou após a limpeza.

Esta autorização foi específica para aqueles arquivos antigos; a automação continua bloqueando states conflitantes e nunca os remove automaticamente.

O script detecta arquivos `*.tfstate`, backups e diretórios padrão de workspaces, além do cache padrão de backend. Não consegue descobrir states guardados arbitrariamente em outros computadores, diretórios ou contas: o operador precisa localizá-los antes de iniciar o primeiro bootstrap.

Para reconciliação ou migração, fora da automação:

1. Identifique conta, região, origem e responsável pelo state. Inspecione somente metadados e recursos necessários, sem imprimir atributos sensíveis.
2. Registre serial, lineage e endereços dos recursos; confirme a propriedade real correspondente.
3. Crie backup seguro e verificado do state de origem, mantendo os arquivos existentes.
4. Confirme bucket, região, chave de destino e eventuais objetos/versões existentes. Compare lineage/serial e recursos; não sobrescreva um destino independente.
5. Obtenha decisão e aprovação explícitas do operador para reconciliação/import ou migração.
6. Siga o [procedimento oficial de inicialização e migração do Terraform](https://developer.hashicorp.com/terraform/cli/commands/init), com revisão das perguntas e backup prévio. Esta automação não executa `-migrate-state`, `-reconfigure`, import nem cópias forçadas.
7. Verifique novamente lineage, serial e recursos de origem/destino e valide o backend antes de liberar operações de infraestrutura.

Para qualquer outro state antigo encontrado posteriormente, confirme sua origem antes de tomar decisões. A limpeza pontual acima não autoriza eliminar states da nova conta nem estados utilizados por outros projetos.

Depois de erro: preserve state, backup, manifesto, plano e log privado; execute `check`/`verify` para diagnosticar. Se houve tentativa de apply, examine o state parcial e o bucket real e gere **novo** plano reconciliado. Não remova locks, markers, state ou caches como tentativa automática de correção. Nenhum retry do script faz import, migração, `-force-copy`, `-lock=false` ou exclusão de locks.

## Permissões e validações somente leitura

A leitura comprova somente as ações que realmente forem executadas com sucesso. O script consulta STS, `ListAllMyBuckets`, ownership via lista própria + `HeadBucket --expected-bucket-owner`, região, versionamento, criptografia, bloqueio público e ownership. Os prefixos dos backends são consultados com `ListBucket`, `ListBucketVersions` e `GetObject` quando o state existe. Os JSONs de state remoto são processados internamente, sem imprimir atributos. Um state histórico apagado não é tratado como destino vazio seguro.

Para os backends, revise a autorização **efetiva** da sessão Academy, incluindo políticas de identidade, sessão, bucket, SCPs e denies:

- `s3:ListBucket` e `s3:ListBucketVersions` no bucket, limitados aos prefixos necessários quando possível.
- `s3:GetObject` e `s3:PutObject` em `cloud/terraform.tfstate` e `database/terraform.tfstate`.
- `s3:GetObject`, `s3:PutObject` e `s3:DeleteObject` nos respectivos `terraform.tfstate.tflock`.
- Leituras das propriedades do bucket; para o bootstrap, criação, tagging e configuração de versionamento, SSE-S3, bloqueio público e ownership conforme o plano e as operações do provider.

Sem criar objetos de teste, consultas somente leitura não comprovam `PutObject`/`DeleteObject`; quando o objeto ainda não existe, nem sua leitura pode ser testada diretamente. A opção `--permissions-reviewed` registra a confirmação operacional dessa revisão e **não equivale a um teste bem-sucedido de escrita**. Não há probes de escrita, simulação IAM automática nem novos recursos IAM nesta automação. [Requisitos oficiais do backend S3](https://developer.hashicorp.com/terraform/language/backend/s3).

## Execução manual por GitHub Actions

O workflow [Terraform bootstrap](../.github/workflows/terraform-bootstrap.yml) tem somente `workflow_dispatch` e executa exclusivamente na `main`. Use sempre **Run workflow** para uma execução nova; **Re-run jobs** é bloqueado para evitar reutilização de plano/state ou colisão de artefatos da tentativa anterior. Não responde a push ou PR. Sua publicação e a execução real dependem do operador; esta sessão preparou apenas os arquivos locais.

Configure as variáveis e secrets da organização descritos na seção seguinte, com acesso ao Cloud. `account_id` é um input explícito de 12 dígitos; região e nome são conferidos contra `AWS_REGION=us-east-1` e `TF_STATE_BUCKET=numberone-terraform-state`. Não há secret novo: utiliza os três secrets temporários Academy e o `GITHUB_TOKEN` nativo com `contents: read` e `actions: read`. O runner precisa de AWS CLI v2, jq e gh; o workflow instala Terraform 1.10.5 e desabilita seu wrapper para preservar as saídas JSON.

1. Na aba Actions do Cloud, selecione **Terraform bootstrap**, branch `main`, `operation=plan` e `account_id` confirmado na Academy. Deixe `plan_run_id` e `confirm_apply` vazios.
2. Revise o plano mostrado no log e o artefato privado `numberone-phase4-bootstrap-plan` (`plan.tar`, retenção solicitada de 7 dias). Registre o ID dessa execução e o token `APPLY:conta:numberone-terraform-state:SHA256` exibido. O plano não aplica recursos.
3. Sem alterar o commit da `main`, inicie outra execução com `operation=apply`, a mesma conta, `plan_run_id` da execução revisada e o token completo em `confirm_apply`. O workflow baixa **esse plano salvo**, comprova sua origem/commit e valida os hashes. Não gera um plano novo durante apply.
4. O workflow tenta preservar o checkpoint do bootstrap mesmo quando apply ou a verificação posterior falham: artefato `numberone-phase4-bootstrap-state` (`state.tar`, retenção solicitada de 90 dias). Ele contém somente o state local do bucket, backup se houver e contexto da conta/repositório. Os states de Cloud e Database não são copiados para o artefato.
5. Para conferir o resultado em outra execução, use `operation=verify`, mesma conta e inputs de apply vazios. Para um novo plano, use novamente `operation=plan`; ambos restauram o checkpoint da execução apply mais recente, inclusive quando ela falhou.

O adaptador [bootstrap-state-ci.sh](../scripts/bootstrap-state-ci.sh) consulta apenas o histórico do workflow atual na `main`. Um plano é aceito somente se veio de uma execução plan manual bem-sucedida, no mesmo commit/repositório, e referencia o checkpoint atual. Qualquer apply posterior invalida planos anteriores. A concorrência é global para o workflow, sem cancelamento automático. Mudanças do caminho absoluto do checkout entre runners também bloqueiam apply, em vez de redirecionar silenciosamente o state.

O adaptador utiliza `--bootstrap-only`: o bootstrap não requer checkout/token de acesso ao Database nem aplica seus recursos. A CLI informa explicitamente que os arquivos Database não foram verificados nesse runner. A checagem local completa continua verificando os dois repositórios; `init-backends` recusa `--bootstrap-only`.

**Checkpoint é necessário após o primeiro apply.** O runner é descartável e o state do bootstrap continua separado dos states de infraestrutura. Faça download e guarde cópia segura de `state.tar` após cada apply; políticas da organização podem limitar a retenção solicitada. O workflow não volta a checkpoints anteriores quando o artefato mais recente estiver ausente, expirado ou inacessível. Uma execução apply cancelada antes de publicar checkpoint também exige investigação manual, mesmo que a falha tenha ocorrido antes de criar recursos: não há fallback automático para um state vazio.

Em perda de artefato ou falha no upload, preserve a execução e os arquivos recuperáveis, identifique o último state confiável e reconcilie-o manualmente antes de preparar uma retomada revisada. Não exclua a execução/artefatos para forçar um bootstrap novo nem use import automático. Sem state confiável, um bucket já existente bloqueia o fluxo. Não houve consulta remota ao histórico, upload, execução de workflow ou confirmação de existência do bucket nesta sessão.

## GitHub e inicialização dos backends

Configure na organização:

```text
TF_STATE_BUCKET=numberone-terraform-state
AWS_REGION=us-east-1
```

Disponibilize as duas variáveis e os secrets temporários `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` aos dois repositórios. Renove os três secrets juntos a cada nova sessão Academy, pelo mecanismo seguro do GitHub. Nenhum secret adicional é necessário somente para o bootstrap.

Os workflows existentes usam `vars` e `secrets`. Variáveis e secrets de repositório com o mesmo nome podem prevalecer sobre a organização; confira duplicatas e acesso por repositório. Considere também eventuais escopos de Environment caso sejam introduzidos. A automação apenas documenta esses valores; não lê configurações remotas. [Precedência de variáveis no GitHub](https://docs.github.com/en/actions/reference/workflows-and-actions/variables).

Depois de bootstrap e permissões comprovados/revisados:

```bash
./scripts/bootstrap-state.sh init-backends \
  --aws --account <ID_CONTA_ACADEMY> --region us-east-1 \
  --permissions-reviewed
```

A etapa verifica ambos os diretórios antes de inicializar qualquer um, inclusive os caches anteriores em `.terraform/terraform.tfstate`, states locais e workspace. Não aceita backend anterior de outro bucket/região/key, credenciais embutidas ou perfil/assume-role/endpoints específicos no cache. Um cache anterior conflitante exige decisão manual; não é removido/reconfigurado automaticamente. Se o segundo init falhar após o primeiro passar, preserve os caches e retome após resolver a causa; repetir um init compatível não migra o state.

O Cloud lê `TF_STATE_BUCKET` no workflow. O Database também define `TF_VAR_cloud_state_bucket` a partir da mesma variável para ler o state Cloud. Para operações manuais posteriores:

```bash
export TF_STATE_BUCKET=numberone-terraform-state
export TF_VAR_cloud_state_bucket="$TF_STATE_BUCKET"
```

Backend inicializado não significa infraestrutura aplicada nem state migrado. O Database só conseguirá planejar seus recursos após o state Cloud conter os outputs esperados.

## Preservação e exclusão

Proteja state, backups, planos e logs como dados sensíveis. Os artefatos ficam em caminhos já ignorados pelo Git, com `umask 077`; não os versione. Guarde cópias seguras do state local do bootstrap e do seu backup sob responsabilidade do operador. Os hashes do manifesto detectam alterações acidentais, mas não são uma assinatura contra um atacante com acesso de escrita ao checkout.

`prevent_destroy` vale enquanto a regra permanecer na configuração. `force_destroy = false` impede o provider de esvaziar o bucket, e S3 não exclui um bucket que contenha objetos/versões. Uma identidade privilegiada ainda pode apagar versões e depois excluir o bucket fora do Terraform. Evite conceder exclusão dos states aos operadores dos backends; exclusão de `.tflock` é necessária para o locking e deve continuar permitida. Não há políticas de expiração nem novos serviços de locking.

## Validação local da automação

```bash
bash -n scripts/bootstrap-state.sh scripts/bootstrap-state-ci.sh scripts/tests/bootstrap-state-test.sh
./scripts/tests/bootstrap-state-test.sh
terraform fmt -check -recursive
```

Os testes exigem jq e substituem **todos** os comandos AWS, Terraform e gh por mocks em fixtures privadas dentro de `/tmp`. Não acessam AWS, não aplicam Terraform real e não alteram states do workspace. Validam conta/região divergentes, credenciais ausentes, bucket próprio sem state, acesso indeterminado, states/backends antigos, tfvars divergente, drift, histórico remoto, lock ativo, plano destrutivo, proteções, confirmação, integridade do plano/state e repetição idempotente. Incluem transferência do plano entre runners, restauração do checkpoint, rejeição de plano anterior ao checkpoint atual e bloqueio quando o checkpoint mais recente está ausente, sem fallback ao antigo. A CI executa essa suíte sem AWS. As fixtures são preservadas para inspeção; não contêm credenciais reais.
