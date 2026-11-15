# Bloco 2A · Fila Billing → OS

A Cloud cria `numberone-billing-events` e `numberone-billing-events-dlq` no mesmo state do EKS. As duas filas Standard usam SSE-SQS, polling de 20 s e visibilidade de 60 s. A principal retém mensagens por 4 dias. A DLQ retém por 14 dias, aceita apenas a fila principal como origem e recebe mensagens após cinco recebimentos sem ACK. [Contrato de filas](https://github.com/PosTech15SOAT/numberone-service-order/blob/main/doc/contracts/saga/v2/queues.md)

## Identidades e implantação

1. Aplique a Cloud e confira os outputs `billing_events_queue_url`, `billing_events_queue_arn`, `billing_events_dlq_url` e `billing_events_dlq_arn`. Use `GetQueueAttributes` para conferir retenção, visibilidade, polling, criptografia e políticas de encaminhamento.
2. Identifique duas roles IAM existentes e distintas na conta do EKS, preparadas pela plataforma para Billing e OS. Confira se a trust permite `sts:AssumeRole` e `sts:TagSession` para `pods.eks.amazonaws.com` e se limita a associação ao cluster, namespace e ServiceAccount de cada workload. Confira as permissões da tabela na fila principal. A identidade de deploy precisa de `iam:GetRole` para a consulta e `iam:PassRole` para a associação. Confirme que a role dos nós permite `eks-auth:AssumeRoleForPodIdentity` e que os nós alcançam a API EKS Auth. [Trust do Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-role.html) · [Pré-requisitos do agente](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html)
3. Informe os nomes em `billing_events_workload_role_names` (variável de Actions `BILLING_EVENTS_WORKLOAD_ROLE_NAMES`, JSON com as chaves `billing` e `os`). A Cloud consulta os ARNs e gerencia o agente e as associações. A gestão de trust e permissões fica com a plataforma. Verifique o agente em todos os nós usados pelas aplicações e confira as associações com `aws eks list-pod-identity-associations`.
4. Mantenha os workers desligados e recrie os Pods após as associações. Prove o acesso com a cadeia padrão de credenciais nos Pods dos próprios Deployments. Se a imagem do serviço não oferecer um cliente de diagnóstico, use temporariamente um contêiner auxiliar AWS CLI no template de cada Deployment e confirme que ele e o contêiner da aplicação receberam as variáveis e o token projetado de Pod Identity. Remova o auxiliar após a prova. Registre a role obtida por `sts get-caller-identity` e o resultado das operações. O Billing envia uma mensagem sintética à fila principal. A OS confere atributos, recebe a mensagem, estende sua visibilidade e a exclui. Verifique a recusa de envio pela OS, recebimento pelo Billing e consulta à DLQ pelos dois serviços. Use o mesmo identificador sintético para reconhecer a mensagem em todas as operações, em uma janela com as filas livres.
5. Configure `BILLING_SQS_QUEUE_URL` com `billing_events_queue_url` e `BILLING_SQS_ENABLED=true` no deploy da OS. O workflow já fornece `BILLING_SQS_MODE=dedicated`. Aguarde o rollout, confira o readiness e verifique os logs do consumidor. A OS consulta os atributos durante o startup.
6. Revise as pendências no Billing. Com a OS pronta, configure `SQS_QUEUE_URL` com o mesmo output e `OUTBOX_ENABLED=true` no deploy do Billing. Consulte o rollout e confirme a primeira publicação com a evidência da inbox. A integração com Inventory segue por REST.

| ServiceAccount e namespace | Ações limitadas ao ARN `billing_events_queue_arn` |
| --- | --- |
| `numberone-billing` em `numberone-billing` | `sqs:SendMessage` |
| `numberone-os` em `numberone-os` | `sqs:GetQueueAttributes`, `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:ChangeMessageVisibility` |

Pod Identity usa a cadeia padrão dos SDKs e está previsto para o EKS em uso. Com `billing_events_workload_role_names=null`, o Terraform entrega as filas e os outputs com Pod Identity desabilitado. A alternativa IRSA usa roles existentes com trust `sts:AssumeRoleWithWebIdentity` restrito a cada ServiceAccount e exige um provedor IAM OIDC registrado para o issuer do EKS. A conta Academy inventariada está sem esse provedor. [Pod Identity e IRSA](https://docs.aws.amazon.com/eks/latest/userguide/service-accounts.html)

## Homologação e recuperação

1. Aprove um orçamento em uma OS sintética. Anote `correlationId`, `eventId` e ID da OS. Confira `PUBLISHED` em `integration_event_outbox` do Billing, `APPLIED` em `inbox_event` da OS e estado `READY_FOR_EXECUTION` em `service_order_saga`. Guarde a versão da Saga.
2. Reenvie o envelope da aprovação com o mesmo `eventId` na janela de teste. Aguarde `outcome=DUPLICATE` nos logs da OS. Confira que a inbox ainda tem uma linha para o evento e que a versão da Saga é a mesma.
3. Envie separadamente um envelope sintético com `eventId` e `correlationId` próprios e um `schemaVersion` inválido. Registre o `MessageId` retornado pelo SQS. Acompanhe `sqsMessageId`, `receiveCount` e `reason` nos logs da OS. O inválido chega à DLQ sem inserir linha na inbox. Correlacione a mensagem da DLQ pelo ID do SQS e registre o motivo com os identificadores sintéticos.
4. Antes de reabilitar o publicador ou iniciar um redrive, confira `PENDING`, `NEEDS_REVIEW`, idade e publicação anterior no outbox. Concilie as mensagens da DLQ com o estado da OS e corrija a causa. A plataforma registra operador, motivo e taxa do redrive antes de reenviar mensagens elegíveis, mantendo o envelope e o `eventId`. A plataforma usa `ReceiveMessage`, `GetQueueAttributes` e `DeleteMessage` na DLQ, `StartMessageMoveTask`, `ListMessageMoveTasks` e `CancelMessageMoveTask` para a operação e `SendMessage` no destino. [Operação de redrive](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-configure-dead-letter-queue-redrive.html)

No banco do Billing, a consulta abaixo sumariza as pendências de publicação.

```sql
SELECT status, count(*) AS events, min(created_at) AS oldest,
       min(next_attempt_at) AS next_attempt
FROM integration_event_outbox
WHERE status IN ('PENDING', 'NEEDS_REVIEW')
GROUP BY status;
```

Ao interromper o fluxo, desligue primeiro o publicador do Billing e acompanhe a fila principal antes de interromper a OS. Preserve filas e registros do PostgreSQL para a retomada.
