# RFC 0001 — AWS e contexto AWS Academy

## Contexto

A Fase 3 executa a solução NumberOne na AWS, em um ambiente AWS Academy Learner Lab com limites de custo, capacidade e permissões.

## Decisão / Proposta adotada

Adotar AWS para a solução integrada, usando API Gateway, Lambda, VPC, Amazon EKS, Amazon ECR e Terraform. O RDS PostgreSQL é um serviço gerenciado privado, provisionado e detalhado no repositório de infraestrutura de banco.

Os nodes do EKS usam subnets públicas como decisão pragmática do ambiente acadêmico, evitando o custo e a dependência de NAT Gateway. O RDS permanece em subnets privadas.

## Justificativa

Os serviços adotados suportam a separação atual entre entrada HTTP, autenticação, rede privada, execução em Kubernetes, imagens de contêiner e banco gerenciado. Terraform mantém o provisionamento reproduzível dentro das permissões disponíveis no laboratório.

## Consequências

- A solução usa os recursos e credenciais temporárias disponibilizados pelo AWS Academy.
- A disposição dos nodes em subnets públicas e a ausência de NAT Gateway são restrições acadêmicas, não uma recomendação para produção corporativa.
- O RDS privado e os componentes de autenticação permanecem sob responsabilidade de seus respectivos repositórios.
