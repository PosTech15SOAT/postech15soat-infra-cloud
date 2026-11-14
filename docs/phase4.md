# Fase 4 — conta Academy nova

Este procedimento substitui as instruções operacionais da Fase 3. Não há dependência de recursos da conta anterior. Use apenas o fluxo revisado na conta nova.

## Configuração GitHub

Na organização, conceda acesso apenas aos repositórios necessários: variables `AWS_REGION=us-east-1`, `TF_STATE_BUCKET=numberone-terraform-state`, `AWS_ACCOUNT_ID` (12 dígitos da nova conta), `EKS_CLUSTER_NAME=numberone-eks` e `DB_IDENTIFIER=numberone-postgres`. Variables de repositório com o mesmo nome têm precedência sobre as de organização: remova duplicatas ou alinhe-as. Os três secrets de organização `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` e `AWS_SESSION_TOKEN` devem ser liberados aos pipelines AWS e atualizados juntos a cada sessão Academy. Não registre seus valores em arquivos.

- Cloud: repository variables `EKS_CLUSTER_ROLE_NAME`, `EKS_NODE_ROLE_NAME`; repository secret `DATADOG_API_KEY`. Confirme nomes e permissões das roles na nova conta, inclusive políticas EKS control plane, node, rede e acesso ECR. Não presumir que roles antigas existem nem que Academy permite criá-las.
- Database: variável `TF_STATE_BUCKET` e credenciais da organização. `terraform.tfvars.example` configura os demais parâmetros.
- Billing: repository variables `DB_SECRET_ARN`, `OS_SERVICE_BASE_URL`, `INVENTORY_SERVICE_BASE_URL`, `BUDGET_APPROVAL_BASE_URL`; repository secret `BUDGET_NOTIFICATION_ENCRYPTION_KEY` (base64 de 32 bytes). `OUTBOX_ENABLED` por padrão é false; se habilitado, exige `SQS_QUEUE_URL`. A URL pública de aprovação HTTPS é obrigatória pelo validador, mesmo com notificações desligadas; sua publicação depende da integração externa. URLs internas: `http://numberone-os-service.numberone-os.svc.cluster.local:8080` e `http://numberone-inventory-service.numberone-inventory.svc.cluster.local:8080`.
- OS: repository variables `DB_SECRET_ARN`, `DB_APP_USERNAME=numberone_os`, `OS_BRANCH_ID` (UUID real), `BILLING_BASE_URL`, `INVENTORY_BASE_URL`. `BILLING_SQS_ENABLED` e `HISTORY_DYNAMODB_ENABLED` são false por padrão; habilitá-los exige respectivamente `BILLING_SQS_QUEUE_URL` e `HISTORY_DYNAMODB_TABLE`. URLs internas: `http://numberone-billing-service.numberone-billing.svc.cluster.local:8080` e URL Inventory acima.
- Inventory: repository variables `DB_SECRET_ARN`, `DB_APP_USERNAME=numberone_inventory`.

Os nomes ECR e namespaces são fixados nos workflows: `numberone-os`, `numberone-billing`, `numberone-inventory`. Cada deploy permanece manual na main, validando CI no mesmo commit. A retirada do Environment também retira seus reviewers e restrições; controle quem pode executar workflows e proteger main e alterações de workflow via regras do repositório. A confirmação textual reduz acidentes, mas não equivale a aprovação independente.

## Provisionamento futuro, após revisão humana

1. Verifique cotas, versão EKS, permissões da sessão, regiões/AZs, chaves Datadog e roles na nova conta. O endpoint público do EKS está aberto por padrão: restrinja `endpoint_public_access_cidrs` quando viável. O node group usa dois `t3.medium`: requests dos serviços somam 450m CPU e 1 GiB, além de componentes EKS e Datadog; valide capacidade efetiva, custos, limites e arquitetura na Academy. Não é garantia de capacidade em falhas.
2. Siga o [procedimento de bootstrap do state](../README.md#bootstrap-do-backend), incluindo revisão e autorização antes do apply. Configure `TF_STATE_BUCKET` na organização e verifique eventuais sobrescritas nos repositórios.
3. No Cloud, execute o workflow Terraform primeiro com `plan`; depois de revisar, dispare manualmente `apply` na main e digite `APPLY`. Push em main/develop apenas planeja. `destroy` requer main e `DESTROY`. Cada execução gera novo plano: essa execução aplica imediatamente o próprio plano, sem pausa para revisão e sem aplicar um artefato previamente aprovado. Para aprovação independente de plano, implemente uma etapa protegida por governança antes de executar.
4. No Database, execute o workflow de plan e revise; dispare manualmente apply em main com `APPLY`. O apply gera e aplica seu próprio plano sem pausa para revisão; para aprovação independente, implemente uma etapa protegida por governança antes de executar. SQL e versões dos secrets são preparados conforme `docs/phase4.md` no Database.
5. Configure ARNs completos dos secrets por repositório e acesso de deploy a ECR, EKS, RDS Describe, Secrets Manager GetSecretValue e KMS quando aplicável. A identidade precisa de autorização Kubernetes; valide o acesso EKS na conta nova. Deploy manual de cada serviço, conferir Flyway, rollout e health.

O Terraform prepara VPC, subnets, EKS, node group, três ECRs, RDS privado e containers de secrets. Nenhum Gateway, Lambda Authorizer, VPC Link ou NLB é provisionado. Services são ClusterIP; conectividade externa e URL de aprovação dependem de validação separada com Marcelo. SQS `numberone-billing-events`, DLQ `numberone-billing-events-dlq` e DynamoDB são posteriores; mantenha workers desabilitados. Os perfis Spring e diretórios de overlay chamados homologation não são GitHub Environments.

A chave Datadog é sensível, mas o provider Helm pode armazená-la no state Terraform. Restrinja rigorosamente acesso ao bucket e às versões do state.
