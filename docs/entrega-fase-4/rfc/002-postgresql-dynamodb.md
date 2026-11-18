# RFC 002 · PostgreSQL por serviço e histórico no DynamoDB

**Status** · Escolha adotada na implantação da Fase 4.

**Escopo** · Persistência operacional, isolamento e consulta ao histórico veicular.

## Contexto

OS, Billing e Inventory precisam de transações locais para guardar estados, revisões, efeitos financeiros e movimentos. Auth precisa ler suas próprias identidades. O histórico do veículo tem um padrão de consulta por veículo, ordenação e paginação, com atualização após a conclusão da manutenção.

## Alternativas

| Opção | Efeito no projeto |
| --- | --- |
| PostgreSQL por contexto e projeção DynamoDB | Mantém transações, constraints e migrations nos serviços. A projeção usa o padrão de consulta por veículo e é atualizada de forma assíncrona. |
| Um banco lógico compartilhado | Facilita joins e consultas transversais, com maior acoplamento a tabelas e migrations de outros serviços. |
| NoSQL como armazenamento de todos os domínios | Exigiria rever invariantes transacionais, modelos e casos de uso já implementados em PostgreSQL. |

## Proposta adotada

Compartilhe a instância RDS e use quatro bancos lógicos com papéis separados. OS, Billing e Inventory são donos de suas migrations. Auth recebe o schema pelo bootstrap do Database e usa um papel de runtime somente leitura. A OS grava a revisão na outbox de histórico ao concluir a manutenção. Um worker projeta a revisão no DynamoDB pela ponte. A tabela usa `vehicleId` como partição e `historyKey` como chave de ordenação.

## Aceite e consequências

Validar conexão e isolamento das roles, comprovar o commit local de conclusão e consultar a revisão como titular do veículo. Repetir a mesma projeção deve preservar uma entrada. O histórico é eventualmente consistente e pode aparecer após a resposta de conclusão. A Saga, a inbox e a outbox mantêm seu estado no PostgreSQL. [RFC PostgreSQL do Database](https://github.com/PosTech15SOAT/postech15soat-infra-database/blob/main/docs/rfcs/RFC-002-rds-postgresql.md) · [Inicialização e isolamento](https://github.com/PosTech15SOAT/postech15soat-infra-database/blob/main/docs/postgresql-initialization.md) · [Histórico e ponte](../../sqs-billing-fase4.md)
