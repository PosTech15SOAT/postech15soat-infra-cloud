# NumberOne · Guia rápido de deploy AWS Academy

Procedimento enviado pelo Júlio, adaptado para o repositório da Cloud. A implantação de referência após reset ocorreu em 17/11/2026 em `us-east-1`, com o EKS `numberone-eks` e o RDS `numberone-postgres`. Consulte os identificadores e as roles na conta atual a cada reset.

## 1. Conta, credenciais e backend

Inicie o lab. Atualize `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` e `AWS_SESSION_TOKEN` com os valores da mesma sessão, no perfil local e no GitHub Actions. Confira que os workflows dos seis repositórios conseguem ler as credenciais.

```bash
aws sts get-caller-identity
```

Se o bucket ainda precisa ser preparado, execute o bootstrap a partir da raiz da Cloud. O backend da execução de referência usou `numberone-terraform-state`.

```bash
cd infra/bootstrap
cp -n terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
aws s3api head-bucket --bucket numberone-terraform-state
```

Revise o plano e confira se os repositórios apontam para a mesma conta e para seus states esperados. [Configuração do backend e da organização](phase4.md)

## 2. Ordem da execução de referência

| Ordem | Repositório | Operação |
| --- | --- | --- |
| 1 | Cloud | Bootstrap S3, quando necessário |
| 2 | Cloud | `Terraform deploy` em `public`, com o ingresso privado da identidade |
| 3 | Database | `Terraform Apply` para RDS, DynamoDB e Secrets Manager |
| 4 | Database | `Initialize PostgreSQL` para OS, Billing, Inventory e Auth |
| 5 | Inventory | `Deploy Inventory` |
| 6 | Billing | `Deploy Billing` |
| 7 | OS | `Deploy OS` |
| 8 | Auth | `Deploy PROD` |
| 9 | Cloud | `Terraform deploy` em `full` |
| 10 | Todos | Validação da infraestrutura e dos fluxos funcionais |

O SQS, sua DLQ e a ponte pertencem à Cloud. Inventory → Billing → OS foi a ordem usada no ensaio. Em uma retomada com mensagens, confira a disponibilidade do consumidor da OS antes de estimular a publicação no Billing.

## 3. Cloud inicial e descoberta de recursos

Configure `PRIVATE_GATEWAY_ROUTES=public`, `OS_IDENTITY_INGRESS_ENABLED=true` e `BILLING_EVENTS_BRIDGE_ROLE_NAME` com a role disponível no lab. A execução de referência usou `LabRole`. Use os nomes exatos das roles do cluster e dos nós em `EKS_CLUSTER_ROLE_NAME` e `EKS_NODE_ROLE_NAME`.

```bash
aws iam list-roles --query "Roles[?contains(RoleName, 'LabEks')].[RoleName]" --output table
```

No workflow manual `Terraform deploy`, selecione `main`, use `action=plan` para revisar e `action=apply` com `confirm_apply=APPLY` para aplicar. Confira o EKS e registre os endpoints da conta atual.

```bash
aws eks describe-cluster --name numberone-eks --region us-east-1 \
  --query 'cluster.status' --output text
aws eks update-kubeconfig --name numberone-eks --region us-east-1
kubectl get nodes -o wide
aws apigatewayv2 get-apis --region us-east-1 \
  --query 'Items[].{Name:Name,Id:ApiId,Endpoint:ApiEndpoint}' --output table
aws sqs list-queues --region us-east-1 --queue-name-prefix numberone \
  --query 'QueueUrls' --output json
```

Espere `ACTIVE` e os dois nós `Ready`. `numberone-http-api` é a API principal, usada no link de orçamento e no webhook. `numberone-billing-sqs-bridge` é a entrada da ponte. [Matriz e outputs da Cloud](gateway-fase4.md)

## 4. Database e PostgreSQL

Execute `Terraform Apply` no Database. Confirme RDS `available`, PostgreSQL 17 e porta `5432`. Em seguida, dispare `Initialize PostgreSQL` em `main`. Para o Auth, confira `DB_AUTH_USERNAME=numberone_auth_runtime` e `DB_AUTH_PASSWORD`. O job aplica o bootstrap do Auth e valida a role de leitura. OS, Billing e Inventory aplicam suas migrations Flyway no próprio deploy.

```bash
aws rds describe-db-instances --db-instance-identifier numberone-postgres --region us-east-1 \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Port:Endpoint.Port}' --output table
kubectl get jobs,pods -n default
```

Use os logs do workflow para validar os quatro bancos se o Job temporário `pg-init-*` já tiver sido removido. [Database](https://github.com/PosTech15SOAT/postech15soat-infra-database/blob/main/docs/phase4.md) · [Inicialização PostgreSQL](https://github.com/PosTech15SOAT/postech15soat-infra-database/blob/main/docs/postgresql-initialization.md)

## 5. Deploy dos microsserviços

| Serviço | Configuração |
| --- | --- |
| Inventory | `Deploy Inventory` com o cluster e a credencial do banco atuais. |
| Billing | `BUDGET_APPROVAL_BASE_URL` com `/api/public/orcamentos-ordem-servico/decisao` na URL do Gateway principal. `OUTBOX_ENABLED=true`, `SQS_BRIDGE_URL` da ponte e `SQS_QUEUE_URL` da fila atual. `OS_SERVICE_BASE_URL` e `INVENTORY_SERVICE_BASE_URL` apontam para os Services internos. |
| OS | `BILLING_SQS_ENABLED=true`, `BILLING_SQS_BRIDGE_URL`, `BILLING_SQS_QUEUE_URL`, `HISTORY_DYNAMODB_ENABLED=true`, `HISTORY_BRIDGE_URL`, `DB_APP_USERNAME=numberone_os` e `OS_BRANCH_ID` da filial da homologação. As duas URLs de ponte apontam para o mesmo endpoint. |

As URLs internas de OS e Inventory no Billing são `http://numberone-os-service.numberone-os.svc.cluster.local:8080` e `http://numberone-inventory-service.numberone-inventory.svc.cluster.local:8080`.

- **E-mail.** Configure `BUDGET_NOTIFICATIONS_ENABLED=true`, `SMTP_FROM`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME` e `SMTP_PASSWORD`. Use o remetente autorizado pelo provedor. O ensaio usou `smtp-relay.brevo.com:587`. Preserve a `BUDGET_NOTIFICATION_ENCRYPTION_KEY` do ambiente quando houver notificações pendentes.
- **Pagamento.** Configure `MERCADO_PAGO_ENABLED=true`, `MERCADO_PAGO_WEBHOOK_ENABLED=true`, `MERCADO_PAGO_ENVIRONMENT=TEST` e `MERCADO_PAGO_WEBHOOK_ENVIRONMENT=TEST`. Use o ID do vendedor da conta de teste em `MERCADO_PAGO_EXPECTED_TEST_SELLER_ID`, forneça os secrets de teste do Billing e configure o callback `/api/public/pagamentos/notificacoes/mercado-pago` na API principal. [Workflow do Billing](https://github.com/PosTech15SOAT/numberone-billing-service/blob/main/.github/workflows/deploy.yml)

```bash
kubectl get deployments,pods -n numberone-inventory
kubectl get deployments,pods -n numberone-billing
kubectl get deployments,pods -n numberone-os
```

## 6. Auth e Cloud em full

Execute `Deploy PROD` no Auth com `TF_STATE_BUCKET` e as credenciais da sessão. O Terraform lê o ARN do segredo PostgreSQL no state Database. A origem HTTP privada da OS e o grupo de segurança vêm do state Cloud. Confirme `Active` e `LastUpdateStatus=Successful` nas funções `numberone-auth-prod-auth-login` e `numberone-auth-prod-authorizer`.

```bash
aws lambda get-function-configuration --function-name numberone-auth-prod-auth-login \
  --region us-east-1 --query '{State:State,Update:LastUpdateStatus}' --output json
aws lambda get-function-configuration --function-name numberone-auth-prod-authorizer \
  --region us-east-1 --query '{State:State,Update:LastUpdateStatus}' --output json
```

Na Cloud, mantenha `OS_IDENTITY_INGRESS_ENABLED=true`, troque `PRIVATE_GATEWAY_ROUTES` para `full` e reaplique. A esteira obtém os quatro ARNs do state Auth. Confira `POST /auth/login`, orçamento público, CSS e webhook com `NONE`, e rotas administrativas com `CUSTOM`. A execução de referência registrou 31 rotas.

```bash
aws apigatewayv2 get-routes --api-id '<HTTP_API_ID>' --region us-east-1 \
  --query 'Items[].{Route:RouteKey,Authorization:AuthorizationType}' --output table
```

## 7. Aceite e diagnóstico

Com `X-Correlation-Id` válido, um `400` ao enviar `{}` para `/auth/login` comprova que a requisição chegou à validação. Para o aceite funcional, use identidades sintéticas válidas. Confirme login, `401` sem token, `403` com cliente em rota administrativa e `201` na abertura da OS pelo operador. Depois, teste e-mail e aprovação pelo link, SQS, execução, histórico, Mercado Pago em teste, entrega e compensação. Use `eventId` e `correlationId` para localizar a jornada no Datadog.

| Sintoma | Verificação |
| --- | --- |
| Role EKS ausente | Consulte os nomes da conta atual. Um reset pode alterar o sufixo das roles. |
| EC2 em execução e EKS sem nós | Confira eventos e logs do worker. Na referência, `ec2:DescribeInstances` foi negado por uma SCP da Academy. Um reset resolveu aquela execução específica. |
| `DBParameterGroupAlreadyExists` | Confira conta, workspace e state `database/terraform.tfstate`. No incidente registrado, `terraform import 'module.rds.aws_db_parameter_group.this' numberone-postgres17` reconciliou o grupo existente depois de confirmar sua ausência do state correto. |
| `Initialize PostgreSQL` parado | Confira workers, Jobs e `kubectl get events -n default --sort-by=.lastTimestamp`. |
| Gateway responde `404` | Confira API e método atuais, matriz de rotas e o apply em `full` para rotas protegidas. |
| `ExpiredToken` | Renove os três valores da sessão e confirme a conta novamente. |

O relato registra melhorias futuras de locking e versionamento do state, concorrência dos workflows e descoberta de configurações após reset. [Documentação integrada da entrega](entrega-fase-4/README.md)
