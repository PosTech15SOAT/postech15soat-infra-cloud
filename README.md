# Number One Auto Service — Cloud Infrastructure

Terraform da infraestrutura compartilhada do Tech Challenge Fase 3:

- bucket S3 para estado remoto do Terraform;
- VPC distribuída em duas zonas de disponibilidade;
- sub-redes públicas para o EKS e privadas reservadas ao banco;
- cluster EKS com node group gerenciado;
- repositório ECR para as imagens da API.

O RDS pertence ao repositório `postech15soat-infra-database`. Os manifests e o
pipeline da aplicação pertencem ao repositório `numberone-app-auto-service-api`.

## Pré-requisitos

- Terraform 1.10 ou superior;
- AWS CLI;
- credenciais temporárias de uma sessão ativa do AWS Academy Learner Lab;
- roles IAM já disponibilizadas pelo Learner Lab para o cluster e seus nós.

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

## GitHub Actions

Crie os environments `homolog` e `production`. Em ambos, configure:

| Tipo | Nome | Finalidade |
| --- | --- | --- |
| Secret | `AWS_ACCESS_KEY_ID` | Access key temporária do Learner Lab |
| Secret | `AWS_SECRET_ACCESS_KEY` | Secret key temporária |
| Secret | `AWS_SESSION_TOKEN` | Token temporário obrigatório |
| Variable | `TF_STATE_BUCKET` | Bucket criado pelo bootstrap |
| Variable | `EKS_CLUSTER_ROLE_NAME` | Nome da role IAM do cluster |
| Variable | `EKS_NODE_ROLE_NAME` | Nome da role IAM dos nodes |
| Variable | `KUBERNETES_VERSION` | Versão suportada pelo EKS, por exemplo `1.33` |

O CI executa formatação e validação em pushes e pull requests. O workflow de
deploy executa `plan` em `develop` e `plan` + `apply` em `main`. Isso evita manter
dois clusters caros no Learner Lab; homologação e produção da API serão isoladas
posteriormente por namespaces/deployments no cluster compartilhado.

Também é possível iniciar manualmente o workflow com a ação `plan`. O apply
manual é permitido apenas quando o workflow roda a partir de `main`.

## Decisões para o AWS Academy

- as roles IAM são reutilizadas, pois o laboratório restringe a criação de roles;
- os nodes ficam em sub-redes públicas, evitando o custo do NAT Gateway;
- o endpoint do EKS é público para permitir GitHub-hosted runners;
- o acesso ao endpoint pode ser restringido em `endpoint_public_access_cidrs`;
- recursos recebem tags para facilitar identificação e limpeza antes do fim do curso.

Esta estrutura foi migrada e saneada a partir de
[`MarceloGilos/PosTech15SOAT`](https://github.com/MarceloGilos/PosTech15SOAT).
