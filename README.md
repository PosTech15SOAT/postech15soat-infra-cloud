> Fase 4: consulte a [arquitetura distribuída](docs/architecture-fase4.md), o [procedimento de implantação](docs/phase4.md) e o [roteiro de validação da fila](docs/sqs-billing-fase4.md). As seções históricas abaixo ainda descrevem componentes da Fase 3.

# NumberOne Auto Service - Cloud Infrastructure

Infraestrutura cloud compartilhada do Tech Challenge Fases 3 e 4 da FIAP para o
projeto NumberOne.

Na Fase 4, a Cloud gerencia a entrada HTTP, EKS, três repositórios ECR e a fila
Billing → OS com DLQ. A comunicação REST entre os serviços usa DNS interno e
Services ClusterIP na porta 8080. A ponte HTTP com JWT é a alternativa escolhida
para SQS e histórico DynamoDB na conta Academy; sua ativação nos workloads deve
ser confirmada pelas variáveis de deploy e por teste integrado.

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
- três repositórios ECR, um por microsserviço;
- Metrics Server no EKS;
- Datadog Agent via Helm;
- API Gateway HTTP API, VPC Link, NLB interno e proxy para as rotas externas;
- fila SQS Billing → OS, DLQ e ponte HTTP para o Academy Lab.

A infraestrutura da Fase 4 foi aplicada no AWS Academy; o fluxo de negócio
completo ainda requer validação integrada.
Existem apenas os ambientes `Local` e `Production`. A branch `develop` é usada
para integração, CI e `terraform plan`; ela não representa um ambiente cloud de
homologação.

## 🏗️ Arquitetura

O [diagrama e as interfaces da Fase 4](docs/architecture-fase4.md) incluem os
três serviços, bancos, chamadas REST, fila, DLQ e ponte HTTP.

Responsabilidades entre repositórios:

| Repositório | Responsabilidade |
| --- | --- |
| `postech15soat-infra-cloud` | VPC, EKS, ECR, Gateway, VPC Link, NLB, observabilidade, SQS/DLQ, ponte HTTP e outputs de infraestrutura |
| `postech15soat-infra-database` | RDS, databases/roles dos serviços, secrets e tabela DynamoDB de histórico |
| `numberone-app-auth` | Lambda Login, Lambda Authorizer e assinatura JWT |
| `numberone-service-order` | Clientes, veículos, OS, orquestração da Saga e projeção do histórico |
| `numberone-billing-service` | Orçamentos, pagamentos e publicação de eventos |
| `numberone-inventory-service` | Catálogo, preços, estoque e compensação de consumo |
| `postech15soat-governance` | rulesets, branch protection e required checks |

O [diagrama da Fase 3](doc/diagrams/cloud/numberone-geral.drawio.png) permanece
como referência histórica.

### NLB e conectividade privada

O state Cloud gerencia o NLB interno, VPC Link, HTTP API e proxies dedicados no
EKS. As Lambdas Login e Authorizer pertencem ao Auth. O ingresso privado de
identidade usa HTTP e SGs restritos; não publica `/internal/**` no Gateway.
A sequência Cloud → Auth → Cloud e os modos `probe`, `public` e `full` estão no
[roteiro da Fase 4](docs/gateway-fase4.md).
Os manifests dos três workloads pertencem a seus respectivos repositórios.

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

O bucket compartilhado `numberone-terraform-state` é criado localmente em
[`infra/bootstrap`](infra/bootstrap), na região `us-east-1`. Confirme a identidade
da conta Academy e a região antes de executar:

```bash
cd infra/bootstrap
terraform init
terraform plan -var="state_bucket_name=numberone-terraform-state"
terraform apply -var="state_bucket_name=numberone-terraform-state"
```

Revise o plano antes do apply. O state do bootstrap é local: preserve-o com
segurança e não o versione. Configure `TF_STATE_BUCKET=numberone-terraform-state`
na organização GitHub antes de inicializar os backends Cloud e Database.

### Configuração principal

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
terraform init \
  -backend-config="bucket=numberone-terraform-state" \
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
Como o Agent é compartilhado, exclusões de endpoints específicas da API são
feitas no Java tracer da aplicação, sem filtro global de resources neste chart.

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

- [Fonte Draw.io dos diagramas cloud](doc/diagrams/cloud/numberone.drawio)
- [RFC 0001 — AWS e contexto AWS Academy](doc/architecture/rfc/0001-escolha-aws-academy.md)
- [RFC 0002 — Datadog para observabilidade](doc/architecture/rfc/0002-escolha-datadog.md)
- [ADR 0001 — EKS e escalabilidade Kubernetes](doc/architecture/adr/0001-eks-e-escalabilidade-kubernetes.md)
- [ADR 0002 — Observabilidade, logs e traces](doc/architecture/adr/0002-observabilidade-logs-e-traces.md)

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
