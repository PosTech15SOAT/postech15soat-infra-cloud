# RFC 0002 — Datadog para observabilidade

## Contexto

A solução precisa observar a aplicação e o cluster por métricas, traces e logs correlacionáveis.

## Decisão / Proposta adotada

Adotar Datadog como plataforma de observabilidade. O Datadog Agent é instalado no EKS; a solução usa APM e traces, logs estruturados, métricas Kubernetes e métricas customizadas de negócio. Dashboards e alertas compõem a operação da solução e são administrados fora deste Terraform.

## Justificativa

Datadog centraliza métricas, traces e logs em uma mesma plataforma, permitindo correlacionar o comportamento da aplicação com o estado do Kubernetes e métricas de negócio.

## Consequências

- O cluster disponibiliza coleta de logs, APM e DogStatsD por meio do Datadog Agent.
- A aplicação envia telemetria para o Agent e a operação consulta dashboards e alertas no Datadog.
- A chave de API do Datadog é tratada como dado sensível de infraestrutura.
