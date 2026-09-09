# Number One Auto Service — Cloud Infrastructure

Terraform da infraestrutura compartilhada do Tech Challenge Fase 3:

- bucket S3 para estado remoto do Terraform;
- VPC distribuída em duas zonas de disponibilidade;
- sub-redes públicas para o EKS e privadas reservadas ao banco;
- cluster EKS com node group gerenciado;
- repositório ECR para as imagens da API;
- add-ons compartilhados do EKS: Kubernetes Metrics Server e Datadog Agent via Helm.

O RDS pertence ao repositório `postech15soat-infra-database`. Os manifests e o
pipeline da aplicação pertencem ao repositório `numberone-app-auto-service-api`.

## Pré-requisitos

- Terraform 1.10 ou superior;
- AWS CLI;
- credenciais temporárias de uma sessão ativa do AWS Academy Learner Lab;
- roles IAM já disponibilizadas pelo Learner Lab para o cluster e seus nós.
- NodePort `30081` reservado para o NLB interno de produção.

As credenciais temporárias incluem `AWS_SESSION_TOKEN`. Elas expiram quando a
sessão do laboratório termina e precisam ser renovadas nos Secrets do GitHub.

## 1. Criar o backend uma única vez

O nome do bucket S3 é global. Escolha um nome único e não versionado:

```bash
cd infra/bootstrap
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

O bucket tem versionamento, criptografia e bloqueio de acesso público. O estado
do próprio bootstrap permanece local; guarde-o com segurança ou importe o bucket
se outra pessoa precisar administrar esse recurso.

## 2. Validar e planejar a infraestrutura

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
terraform init \
  -backend-config="bucket=SEU_BUCKET_DE_ESTADO" \
  -backend-config="region=us-east-1"
terraform fmt -check -recursive
terraform validate
terraform plan
```

O lock do estado usa o próprio S3 (`use_lockfile`), sem tabela DynamoDB.
Os outputs `vpc_id` e `private_subnet_ids` são consumidos pelo Terraform do
repositório de autenticação para criar o VPC Link do API Gateway.

## Ambiente e GitHub Actions

Existe um único ambiente lógico de runtime: `production`. A branch `develop`
serve para integração, validação, CI e `terraform plan`; ela não representa
homologação e não cria um segundo ambiente. A branch `main` executa `plan` e
`apply` contra a infraestrutura única.

Crie apenas o GitHub Environment `production` em:

```text
Repositório -> Settings -> Environments -> production
```

Configure estes Secrets:

| Secret | Origem |
| --- | --- |
| `AWS_ACCESS_KEY_ID` | AWS Academy Learner Lab, obtido nas credenciais temporárias da sessão do Lab |
| `AWS_SECRET_ACCESS_KEY` | AWS Academy Learner Lab, obtido nas credenciais temporárias da sessão do Lab |
| `AWS_SESSION_TOKEN` | AWS Academy Learner Lab, obtido nas credenciais temporárias da sessão do Lab; expira junto com a sessão |
| `DATADOG_API_KEY` | Conta Datadog; API Key usada pelo Datadog Agent para enviar telemetria |

As credenciais AWS Academy são temporárias. Quando expirarem ou uma nova sessão
do Lab for iniciada, atualize os Secrets AWS correspondentes no Environment
`production`. Não coloque valores reais no README.

Configure estas Environment variables em:

```text
Repositório -> Settings -> Environments -> production -> Environment variables
```

| Variable | Origem |
| --- | --- |
| `TF_STATE_BUCKET` | Nome do bucket S3 usado como backend remoto do Terraform; é criado/preparado pelo bootstrap do projeto |
| `EKS_CLUSTER_ROLE_NAME` | Nome da IAM Role disponibilizada pelo AWS Academy para o EKS; verificar no AWS Academy/AWS IAM qual role deve ser utilizada |
| `EKS_NODE_ROLE_NAME` | Nome da IAM Role disponibilizada pelo AWS Academy para os nodes do EKS; verificar no AWS Academy/AWS IAM qual role deve ser utilizada |

Depois de executar o bootstrap, use em `TF_STATE_BUCKET` o nome resultante do
bucket. No cenário atual do projeto, as roles de cluster e nodes normalmente
correspondem às roles disponibilizadas pelo Learner Lab.

A versão do Kubernetes é versionada no próprio Terraform em
`var.kubernetes_version`, com default `1.36`, e não precisa ser cadastrada como
GitHub Environment Variable.

Fluxo das configurações:

```text
AWS Academy
    ↓
GitHub Environment production
    ↓
Secrets / Variables
    ↓
GitHub Actions
    ↓
Terraform
```

Exemplos do projeto:

```text
EKS_CLUSTER_ROLE_NAME
    ↓
${{ vars.EKS_CLUSTER_ROLE_NAME }}
    ↓
TF_VAR_cluster_role_name
    ↓
var.cluster_role_name

DATADOG_API_KEY
    ↓
${{ secrets.DATADOG_API_KEY }}
    ↓
TF_VAR_datadog_api_key
    ↓
var.datadog_api_key
```

`TF_STATE_BUCKET` é usado diretamente no `terraform init -backend-config`, por
isso não é uma variável Terraform comum.

O CI executa formatação e validação em pushes e pull requests. O workflow de
deploy usa o GitHub Environment `production` tanto em `develop` quanto em
`main`: em `develop`, isso significa apenas que o `plan` avalia mudanças contra
o único state remoto existente; em `main`, o workflow executa `plan` + `apply`.

Para executar manualmente:

```text
GitHub -> Actions -> Terraform deploy -> Run workflow
```

Opções:

- `plan`: visualiza as alterações.
- `apply`: aplica as alterações; somente `main`.
- `destroy`: destrói a infraestrutura gerenciada pelo Terraform; somente
  manual, somente `main`, e exige `confirm_destroy = DESTROY`.

`destroy` remove os recursos gerenciados pelo state Terraform e deve ser usado
apenas quando realmente se deseja desmontar a infraestrutura.

## Observabilidade do EKS

O módulo `infra/modules/observability` instala:

- Kubernetes Metrics Server via Amazon EKS Community Add-on
  (`aws_eks_addon`, `addon_name = "metrics-server"`), habilitando a Metrics API
  para `kubectl top nodes`, `kubectl top pods` e HPA;
- Datadog Agent via Helm chart oficial `datadog` na versão `3.242.0`, namespace
  `datadog`, com logs de containers, métricas de Kubernetes, APM na porta
  `8126` e DogStatsD UDP na porta `8125`.

A aplicação deve enviar APM para `hostIP:8126` e DogStatsD para `hostIP:8125`.
A API key é fornecida pelo secret `DATADOG_API_KEY` como
`TF_VAR_datadog_api_key`; não versionar esse valor. Mesmo marcada como
`sensitive`, a API key pode existir no state remoto do Terraform.

Comandos úteis após o apply:

```bash
kubectl get addon metrics-server -n kube-system
kubectl top nodes
kubectl top pods -A
helm list -n datadog
kubectl get pods -n datadog
```

## Decisões para o AWS Academy

- as roles IAM são reutilizadas, pois o laboratório restringe a criação de roles;
- os nodes ficam em sub-redes públicas, evitando o custo do NAT Gateway;
- o endpoint do EKS é público para permitir GitHub-hosted runners;
- o acesso ao endpoint pode ser restringido em `endpoint_public_access_cidrs`;
- recursos recebem tags para facilitar identificação e limpeza antes do fim do curso.

Esta estrutura foi migrada e saneada a partir de
[`MarceloGilos/PosTech15SOAT`](https://github.com/MarceloGilos/PosTech15SOAT).
