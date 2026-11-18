# RFC 001 · Plataforma AWS Academy para a Fase 4

**Status** · Escolha adotada na implantação da Fase 4.

**Escopo** · Infraestrutura compartilhada, serviços gerenciados e operação do laboratório.

## Contexto

A Fase 4 precisava executar três microsserviços em Kubernetes, expor APIs, aplicar controle de acesso, trocar mensagens e mostrar observabilidade. A equipe já operava AWS e Datadog na Fase 3. A conta Academy fornece créditos e identidades administradas pelo laboratório, com limites de IAM e resets do ambiente.

## Alternativas

| Opção | Efeito no projeto |
| --- | --- |
| AWS Academy com EKS e serviços gerenciados | Reaproveita a infraestrutura e a experiência da equipe. Integra API Gateway, Lambda, SQS, RDS e DynamoDB sob as restrições da conta Academy. |
| Kubernetes local para toda a entrega | Facilita desenvolvimento e testes reproduzíveis. A integração com os serviços gerenciados e o deploy do ambiente avaliado exigiriam uma etapa adicional. |
| Outra nuvem gerenciada | Atende ao requisito de Kubernetes, com migração de pipelines, rede, identidades e serviços de mensageria e persistência. |

## Proposta adotada

Use EKS para OS, Billing e Inventory, ECR para imagens, API Gateway e Lambda para a entrada e Auth, RDS PostgreSQL, SQS e DynamoDB para dados e integração. O Datadog Agent é instalado via Helm. Terraform mantém estados separados para Cloud, Database e Auth. O laboratório usa a ponte HTTP autenticada por identidade dos pods para SQS e histórico, com a role disponível na conta.

## Aceite e consequências

Os workflows devem permitir reconstruir o ambiente após reset, com VPC, nós prontos, RDS acessível pelos workloads, Lambdas ativas e Gateway em `full`. Uma jornada de homologação deve conectar logs e traces a uma ordem sintética. Os IDs, roles e URLs precisam ser redescobertos quando a conta muda. Os testes locais continuam apoiando a validação rápida antes do deploy. [RFC original da Cloud](../../../doc/architecture/rfc/0001-escolha-aws-academy.md) · [Guia de deploy](../../deploy-aws-academy-fase4.md)
