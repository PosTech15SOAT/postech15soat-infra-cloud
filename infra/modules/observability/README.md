# Módulo Observability

Configura observabilidade no cluster EKS já provisionado.

## Recursos

- add-on comunitário `metrics-server` do Amazon EKS;
- release Helm `datadog` no namespace `datadog`, criado pelo próprio release.

## Decisões relevantes

- O módulo recebe o nome do cluster e depende do EKS no módulo raiz.
- O Datadog coleta logs de todos os containers e habilita APM por porta.
- Instrumentação automática, monitoramento de rede e de serviços, receptores
  OTLP e recursos de segurança avançados permanecem desabilitados na
  configuração atual.
- O Agent e compartilhado; filtros especificos de endpoint permanecem no tracer
  da aplicacao para nao afetar outros servicos do cluster.
- A chave da API do Datadog é variável sensível e é aplicada ao chart por
  `set_sensitive`.
