# Plataforma AWS · Arquitetura da Fase 4

Cloud define a infraestrutura compartilhada. Os repositórios dos microsserviços mantêm as imagens, os manifests de workloads e seus deploys. Database consome a rede por outputs do state. Auth mantém o código das Lambdas e a integração da Fase 3.

| Fronteira | Código em `develop` (`860ea15`) | Dependência ou evidência necessária |
| --- | --- | --- |
| Rede | Módulo VPC, subnets públicas e privadas e rotas. O node group recebe as subnets públicas no código atual. | Confirmar CIDRs, política do endpoint EKS e caminho da rede interna na conta da entrega. |
| Computação | EKS, node group e roles IAM externas resolvidas por nome. | Validar permissões Academy, versão e capacidade. |
| Imagens | ECR separados `numberone-os`, `numberone-billing` e `numberone-inventory`. | Confirmar existência, acesso e digest de cada implantação. |
| Observabilidade | Helm instala Datadog com logs e APM configurados. | Evidenciar sinais das aplicações e correlação/traces de um fluxo real. |
| Entrada HTTP | Workloads dos serviços usam ClusterIP. | Decidir integração privada para os três workloads, regras de rota, controle de acesso e proprietário dos recursos. |
| SQS e DynamoDB | Os serviços possuem adaptadores e configuração. | Provisionar fila, DLQ e tabela do histórico, autorizar as identidades de runtime e validar o fluxo na conta. |

## Operação

O bootstrap configura o backend S3. A raiz efetiva é `infra/`, onde `main.tf` compõe os módulos e `outputs.tf` exporta rede, EKS e ECR. O workflow da revisão analisada planeja em push e restringe apply/destroy manual à `main` com confirmação textual. O workflow que aplica calcula seu próprio plano. Registre o plano, a revisão e o resultado da execução real no handoff.

`docs/phase4.md` descreve o preparo da nova conta Academy. Alguns nomes, portas e regras de execução desse procedimento ainda divergem dos pipelines dos apps publicados. Por exemplo, ele cita Inventory em 8080 e variáveis de repositório, enquanto o PR do Inventory usa Service em 8082 e environment `homologation`. Confirme a configuração final com os três donos antes de ativar deploys.

[Procedimento Fase 4](phase4.md) · [Módulos Terraform](../infra/main.tf) · [Bootstrap do state](bootstrap-state.md) · [Pipeline](../.github/workflows/terraform-deploy.yml) · [CI verificado](https://github.com/PosTech15SOAT/postech15soat-infra-cloud/actions/runs/43636764866) · [Plan que falhou na revisão consultada](https://github.com/PosTech15SOAT/postech15soat-infra-cloud/actions/runs/43636735881)
