# NumberOne Auto Service - Cloud Infrastructure

Infraestrutura cloud compartilhada do Tech Challenge Fase 3 da FIAP para o
projeto NumberOne.

Este repositório é a porta de entrada da infraestrutura AWS do cluster e não
deve duplicar responsabilidades dos repositórios de aplicação, autenticação,
banco de dados ou governança.

## 📌 Visão Geral

O projeto provisiona, via Terraform:

- bucket S3 usado como backend remoto do Terraform;
- VPC em duas zonas de disponibilidade;
- subnets públicas usadas pelo EKS;
- subnets privadas reservadas para integrações internas, como o RDS do state de
  banco;
- Internet Gateway e route tables;
- cluster EKS com managed node group;
- repositório ECR da API;
- Metrics Server no EKS;
- Datadog Agent via Helm;
- regra no security group do cluster para permitir tráfego interno da VPC ao
  NodePort da API.

A infraestrutura `production` já está implantada e funcional no AWS Academy.
Existem apenas os ambientes `Local` e `Production`. A branch `develop` é usada
para integração, CI e `terraform plan`; ela não representa um ambiente cloud de
homologação.

## 🏗️ Arquitetura

Fluxo integrado da solução:

```text
Cliente / Insomnia
  -> API Gateway HTTP API
  -> Lambda Authorizer
  -> VPC Link
  -> NLB interno
  -> EKS
  -> aplicação Spring
  -> RDS PostgreSQL
```

Responsabilidades entre repositórios:

| Repositório | Responsabilidade |
| --- | --- |
| `postech15soat-infra-cloud` | VPC, networking, EKS, node group, ECR, observabilidade do Kubernetes e outputs de infraestrutura cloud |
| `postech15soat-infra-database` | RDS PostgreSQL e infraestrutura específica do banco |
| `numberone-app-auth` | Lambda Login, Lambda Authorizer, API Gateway, autenticação e consumo dos outputs de rede |
| `numberone-app-auto-service-api` | aplicação Spring, manifests/deploy da aplicação, Service/NodePort, HPA, PDB e probes quando pertencentes ao workload |
| `postech15soat-governance` | rulesets, branch protection e required checks |

TODO: adicionar o diagrama final de infraestrutura/cloud da Fase 3.

### NLB e conectividade privada

Este state não cria recurso `aws_lb`/NLB. A parte existente neste repositório é
a regra `aws_vpc_security_group_ingress_rule.api_internal_nlb`, que libera os
`api_node_ports` apenas dentro do CIDR da VPC.

Pela divisão de responsabilidades do projeto, o Service/NodePort e manifests do
workload pertencem ao repositório `numberone-app-auto-service-api`, enquanto API
Gateway, autenticação e VPC Link pertencem ao repositório `numberone-app-auth`.
O NLB interno deve ser validado junto desses repositórios, sem duplicar recursos
neste state.

## 🧰 Tecnologias

- Terraform `>= 1.10.0`;
- provider AWS `~> 6.0`;
- provider Helm `~> 2.17`;
- AWS S3 backend com lockfile nativo do S3;
- AWS VPC, EKS, managed node group e ECR;
- Amazon EKS Community Add-on `metrics-server`;
- Helm chart oficial `datadog` versão `3.242.0`;
- GitHub Actions;
- AWS Academy Learner Lab.

## 📁 Estrutura do Projeto

```text
.
├── .github/workflows/
│   ├── branch-flow.yml
│   ├── ci.yml
│   └── terraform-deploy.yml
├── infra/
│   ├── bootstrap/
│   ├── modules/
│   │   ├── ecr/
│   │   ├── eks/
│   │   ├── observability/
│   │   └── vpc/
│   ├── backend.tf
│   ├── main.tf
│   ├── outputs.tf
│   ├── providers.tf
│   ├── variables.tf
│   └── versions.tf
└── README.md
```

## ✅ Pré-requisitos

- Terraform 1.10 ou superior;
- AWS CLI;
- `kubectl`, para inspeção do cluster;
- Helm, para inspeção dos releases;
- credenciais temporárias de uma sessão ativa do AWS Academy Learner Lab;
- roles IAM já disponibilizadas pelo Learner Lab para o cluster e seus nós;
- NodePort `30081` reservado para o NLB interno de produção.

As credenciais temporárias incluem `AWS_SESSION_TOKEN`. Elas expiram quando a
sessão do laboratório termina e precisam ser renovadas nos Secrets do GitHub.

## ⚙️ Configuração

### Bootstrap do backend

O backend remoto é criado uma única vez pelo Terraform em
[`infra/bootstrap`](infra/bootstrap). O bucket S3 possui:

- versionamento habilitado;
- criptografia SSE-S3 (`AES256`);
- bloqueio de acesso público;
- `prevent_destroy = true`.

O estado do próprio bootstrap permanece local. Guarde-o com segurança ou importe
o bucket se outra pessoa precisar administrar esse recurso.

```bash
cd infra/bootstrap
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

### Configuração principal

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
terraform init \
  -backend-config="bucket=SEU_BUCKET_DE_ESTADO" \
  -backend-config="region=us-east-1"
```

O backend principal está em [`infra/backend.tf`](infra/backend.tf):

- tipo: `s3`;
- key: `cloud/terraform.tfstate`;
- criptografia: `encrypt = true`;
- locking: `use_lockfile = true`, sem tabela DynamoDB.

## ▶️ Execução Local

Use a execução local para validar e planejar mudanças de infraestrutura:

```bash
cd infra
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform plan
```

Para usar o state remoto localmente, execute `terraform init` com
`-backend-config` apontando para o bucket criado pelo bootstrap.

## 🧪 Validação/Testes da Infraestrutura

Validações reais do repositório:

```bash
terraform fmt -check -recursive
terraform validate
terraform plan
```

Comandos úteis após o deploy:

```bash
aws eks update-kubeconfig --region us-east-1 --name numberone-lab-eks
kubectl get nodes
kubectl get addon metrics-server -n kube-system
kubectl top nodes
kubectl top pods -A
helm list -n datadog
kubectl get pods -n datadog
```

Não há suíte automatizada adicional neste repositório além das validações de
Terraform e dos workflows de CI/CD.

## 🔐 Segurança

- O NLB da aplicação é interno e deve receber tráfego pelo VPC Link do API
  Gateway.
- O RDS PostgreSQL é privado e pertence ao state do repositório
  `postech15soat-infra-database`.
- O EKS está com endpoint público e privado habilitados; o acesso público é
  controlado por `endpoint_public_access_cidrs`.
- As roles IAM de cluster e nodes são reutilizadas do AWS Academy, informadas via
  variáveis `cluster_role_name` e `node_role_name`.
- Secrets sensíveis ficam no GitHub Environment `production`.
- `DATADOG_API_KEY` é enviada ao Terraform via `TF_VAR_datadog_api_key`; mesmo
  marcada como sensitive, pode existir no state remoto.
- O state remoto deve ser tratado como sensível.
- O security group do cluster permite os `api_node_ports` apenas a partir do CIDR
  da VPC.

## 🚀 CI/CD

Os workflows ficam em [`.github/workflows`](.github/workflows):

- [`ci.yml`](.github/workflows/ci.yml): roda em `push`, `pull_request` para
  `develop` e `main`, e `workflow_dispatch`. Valida estrutura, whitespace,
  `terraform fmt`, `terraform init -backend=false` e `terraform validate` para
  `infra/bootstrap` e `infra`.
- [`terraform-deploy.yml`](.github/workflows/terraform-deploy.yml): roda em
  `push` para `develop` e `main` quando há mudanças em `infra/**` ou no próprio
  workflow, além de `workflow_dispatch`.
- [`branch-flow.yml`](.github/workflows/branch-flow.yml): exige que pull
  requests para `main` venham de `develop`.

Comportamento esperado:

- `develop`: CI e `terraform plan` contra o único state remoto; não cria ambiente
  cloud separado.
- `main`: CI, `terraform plan` e `terraform apply` em `production`.
- `workflow_dispatch`: permite `plan`; `apply` somente em `main`; `destroy`
  somente em `main` com `confirm_destroy = DESTROY`.

O workflow de deploy usa o GitHub Environment `production`.

Secrets necessários:

| Secret | Origem |
| --- | --- |
| `AWS_ACCESS_KEY_ID` | AWS Academy Learner Lab |
| `AWS_SECRET_ACCESS_KEY` | AWS Academy Learner Lab |
| `AWS_SESSION_TOKEN` | AWS Academy Learner Lab |
| `DATADOG_API_KEY` | Conta Datadog |

Variables necessárias:

| Variable | Uso |
| --- | --- |
| `TF_STATE_BUCKET` | bucket S3 do backend remoto |
| `EKS_CLUSTER_ROLE_NAME` | role IAM existente usada pelo control plane do EKS |
| `EKS_NODE_ROLE_NAME` | role IAM existente usada pelo managed node group |

## ☁️ Deploy

O deploy automático ocorre no workflow
[`terraform-deploy.yml`](.github/workflows/terraform-deploy.yml).

Fluxo:

```text
AWS Academy
  -> GitHub Environment production
  -> Secrets / Variables
  -> GitHub Actions
  -> Terraform
```

Exemplos de mapeamento:

```text
EKS_CLUSTER_ROLE_NAME
  -> vars.EKS_CLUSTER_ROLE_NAME
  -> TF_VAR_cluster_role_name
  -> var.cluster_role_name

DATADOG_API_KEY
  -> secrets.DATADOG_API_KEY
  -> TF_VAR_datadog_api_key
  -> var.datadog_api_key
```

`TF_STATE_BUCKET` é usado diretamente no `terraform init -backend-config`; ele
não é uma variável Terraform comum.

## 📊 Observabilidade

O módulo [`infra/modules/observability`](infra/modules/observability) instala:

- Metrics Server via `aws_eks_addon`, `addon_name = "metrics-server"`;
- Datadog Agent via Helm no namespace `datadog`;
- coleta de logs de containers;
- métricas de Kubernetes;
- APM com porta `8126` habilitada;
- DogStatsD com hostPort UDP `8125`;
- `datadog.site` configurável por `var.datadog_site`.

A aplicação deve enviar APM para `hostIP:8126` e DogStatsD para `hostIP:8125`.
Dashboards e monitors do Datadog não são provisionados por este Terraform.

## 🗃️ State / Integração com outros repositórios

Outputs atuais em [`infra/outputs.tf`](infra/outputs.tf):

| Output | Uso |
| --- | --- |
| `vpc_id` | consumido por outros states, especialmente autenticação/API Gateway |
| `public_subnet_ids` | referência de rede do cluster |
| `private_subnet_ids` | consumido pelo repositório de autenticação para VPC Link/API Gateway e por integrações privadas |
| `eks_cluster_name` | referência do cluster |
| `eks_cluster_endpoint` | endpoint do cluster, sensitive |
| `eks_cluster_security_group_id` | referência do SG do cluster |
| `ecr_repository_url` | usado pelo pipeline/build da aplicação |
| `aws_region` | região do ambiente |
| `api_node_ports` | NodePorts liberados internamente na VPC |

Os outputs confirmados como consumidos pelo repositório de autenticação são
`vpc_id` e `private_subnet_ids`. Não invente outputs: qualquer novo contrato
entre states deve ser decidido explicitamente.

## 📚 Documentação

Arquivos de documentação existentes:

- [`README.md`](README.md)
- [`infra/terraform.tfvars.example`](infra/terraform.tfvars.example)
- [`infra/bootstrap/terraform.tfvars.example`](infra/bootstrap/terraform.tfvars.example)

Não foram encontrados diretórios `docs/`, `doc/`, diagramas, ADRs ou RFCs neste
repositório.

## 🧠 Decisões Arquiteturais

Decisões implementadas no Terraform atual:

- EKS como orquestrador da aplicação;
- Terraform como ferramenta de provisionamento;
- S3 remoto como backend do state principal;
- lock do state com `use_lockfile`, sem DynamoDB;
- VPC com duas AZs;
- subnets públicas para os nodes do EKS;
- subnets privadas reservadas a componentes privados de outros states;
- ausência de NAT Gateway;
- endpoint público e privado do EKS habilitados;
- Metrics Server no EKS;
- Datadog Agent no cluster;
- ECR com scan on push, criptografia AES256 e lifecycle mantendo as 20 imagens
  mais recentes.

Essas decisões estão documentadas aqui, mas não existem ADRs formais neste
repositório.

## ⚠️ Limitações e decisões do ambiente acadêmico

Estas escolhas são pragmáticas para o AWS Academy Learner Lab e não devem ser
apresentadas como arquitetura ideal de produção corporativa:

- reutilização de IAM roles existentes (`LabRole` ou equivalente), pois o
  laboratório restringe criação e permissão de roles;
- nodes do EKS em subnets públicas para evitar o custo operacional de NAT
  Gateway;
- ausência de NAT Gateway;
- endpoint público do EKS habilitado para permitir execução por
  GitHub-hosted runners;
- credenciais temporárias com `AWS_SESSION_TOKEN`;
- sizing econômico do node group: `t3.small`, mínimo `1`, desejado `2`, máximo
  `2`;
- tags padrão para identificação e limpeza: `Project`, `Environment`,
  `ManagedBy` e `Course`.

## 🤝 Contribuição

Fluxo de branches:

```text
feature/*
  -> Pull Request
develop
  -> Pull Request
main
```

Não faça push direto para `develop` ou `main`.

As proteções de branch, required checks e validações de promoção para `main` são
centralizadas no repositório `postech15soat-governance`. Este repositório mantém
apenas a validação local de origem do PR para `main` em
[`branch-flow.yml`](.github/workflows/branch-flow.yml).
