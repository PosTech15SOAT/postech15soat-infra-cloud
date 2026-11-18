# ADR 001 · Saga orquestrada na OS com REST e SQS

**Status** · Aceito e implementado.

**Data de consolidação** · 17/11/2026.

## Contexto

A jornada da ordem depende de orçamento, estoque e pagamento, com transações próprias em cada serviço. O operador precisa de um resultado da baixa para iniciar um item. Aprovação e confirmação de pagamento podem chegar depois da requisição inicial.

## Decisão

A OS coordena o avanço da Saga e guarda seu estado atual e as operações no PostgreSQL. Os serviços usam REST interno para consultas e operações como consumo, quitação e compensação. O Billing usa SQS Standard para eventos de orçamento e pagamento enviados à OS. No laboratório, a ponte fornece acesso aos serviços AWS a partir das identidades dos pods.

O Billing grava a alteração comercial junto com a outbox. A OS deduplica pelo `eventId` e pelo hash do conteúdo, confirma a mensagem depois do commit da inbox e reaplica somente operações que ainda precisem de recuperação. Consumo REST usa `operationId`. Num cancelamento elegível, a OS resolve estoque antes de solicitar o cancelamento comercial e registra `COMPENSATED` após as confirmações.

## Alternativas e consequências

Uma Saga coreografada distribuiria o avanço entre assinantes. Uma integração exclusivamente por REST exigiria outra forma de propagar decisões tardias. A combinação adotada mantém os casos de uso operacionais na OS e exige idempotência para reentregas, reconciliação de respostas perdidas e acompanhamento da fila de falhas. [Contratos da Saga](https://github.com/PosTech15SOAT/numberone-service-order/tree/main/doc/contracts/saga/v2) · [ADR de mensageria do Billing](https://github.com/PosTech15SOAT/numberone-billing-service/blob/main/docs/adr/0005-message-broker-selection.md)
