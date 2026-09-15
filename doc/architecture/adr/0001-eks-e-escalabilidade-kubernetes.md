# ADR 0001 — EKS e escalabilidade Kubernetes

- Status: Aceito
- Data: 2026-09-13

## Contexto

A Auto Service API é executada em contêineres e necessita de orquestração, disponibilidade entre réplicas e capacidade de escalar conforme uso.

## Decisão

Executar a aplicação no Amazon EKS com managed node group. O workload possui HorizontalPodAutoscaler configurado entre 2 e 5 réplicas, com metas de utilização de CPU e memória, e utiliza o Metrics Server do cluster.

No ambiente AWS Academy, o Deployment usa rollout com `maxSurge: 0` e `maxUnavailable: 1`, em razão da capacidade limitada disponível.

## Consequências

- A aplicação pode escalar horizontalmente dentro dos limites configurados no HPA e da capacidade do node group.
- O Metrics Server é parte necessária da coleta de métricas de recursos para o HPA.
- A estratégia de rollout acadêmica não representa necessariamente a configuração adequada para ambientes corporativos de maior capacidade.
