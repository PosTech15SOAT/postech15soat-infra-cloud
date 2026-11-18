# ADR 003 · Escalabilidade dos workloads e adoção de HPA

**Status** · Réplicas fixas na implantação de referência. Adoção de HPA nos três microsserviços em avaliação.

**Data de consolidação** · 17/11/2026.

## Contexto

A Cloud instala o Metrics Server no EKS. O monólito da fase anterior tem um manifesto HPA próprio. Os manifests inspecionados na `main` dos três microsserviços da Fase 4 e o relato da implantação de referência mostram o rollout com uma réplica por aplicação.

## Decisão registrada

Use o estado observado do lab como referência da entrega. A evolução para HPA pertence ao repositório do workload que será escalado. Avalie `autoscaling/v2` para serviços que precisem aumentar réplicas após um teste de carga. Defina os limites com base nos requests de CPU ou memória do pod, capacidade dos nós, pool de conexões do RDS e comportamento das operações concorrentes.

## Condições para promover HPA

- Comprovar que o Metrics Server entrega métricas para o deployment e que os recursos utilizados pela métrica têm requests definidos.
- Testar aumento e redução das réplicas e observar latência, saturação do pool do RDS e disponibilidade.
- Exercitar publicação, consumo e recuperação com mais de uma réplica. Conferir que inbox, outbox e operações da Saga preservam os efeitos idempotentes.
- Registrar `kubectl get hpa`, a variação de réplicas e a execução no Datadog antes de apresentar o HPA como implantado.

## Consequências

Réplicas fixas deixam a capacidade conhecida durante a demonstração. HPA pode ajustar a quantidade de pods depois de validado, sujeito às métricas e à capacidade dos nós. A conveniência do manifesto do monólito precisa ser reavaliada por microsserviço. [ADR de escalabilidade da Cloud](../../../doc/architecture/adr/0001-eks-e-escalabilidade-kubernetes.md) · [Metrics Server](../../../infra/modules/observability/main.tf) · [HPA da Fase 3](https://github.com/PosTech15SOAT/numberone-app-auto-service-api/blob/main/k8s/base/hpa.yaml) · [Guia da implantação de referência](../../deploy-aws-academy-fase4.md)
