# ADR 0002 — Observabilidade, logs e traces

- Status: Aceito
- Data: 2026-09-13

## Contexto

A solução executa aplicação e infraestrutura Kubernetes em componentes separados e precisa de telemetria integrada para acompanhamento operacional.

## Decisão

Usar Datadog Agent no EKS para a integração de observabilidade. A aplicação produz logs estruturados JSON, correlaciona requisições por `X-Correlation-Id` e preserva identificadores de trace e span do Datadog quando fornecidos pelo tracer. APM, traces, métricas Kubernetes e métricas da aplicação são enviados ou coletados pelo Agent.

## Consequências

- Logs, métricas e traces podem ser correlacionados no Datadog.
- A integração da aplicação usa APM Java e DogStatsD; o cluster disponibiliza as portas do Agent para essas integrações.
- Dashboards e alertas permanecem gerenciados na plataforma Datadog, fora do state Terraform.
