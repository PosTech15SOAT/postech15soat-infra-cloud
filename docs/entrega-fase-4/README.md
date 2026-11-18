# NumberOne · Documentação integrada da Fase 4

Visão do sistema implantado na AWS Academy, decisões que atravessam os repositórios e procedimento para reconstruir o ambiente. Referência de arquitetura e deploy de 17/11/2026. As decisões específicas e os contratos continuam documentados junto ao código de cada serviço.

| Documento | Conteúdo |
| --- | --- |
| [Prévia Markdown da entrega](entrega-fase-4.md) | Arquitetura, Saga, evidências e itens para fechar antes do PDF |
| [Arquitetura distribuída](../architecture-fase4.md) | Limites dos serviços, DNS interno e checklist de evidências |
| [Diagrama de componentes](diagrama-componentes.md) | Nuvem, APIs, microsserviços, persistência, mensageria e observabilidade |
| [Sequência de autenticação e abertura de OS](sequencia-autenticacao-abertura-os.md) | Login, autorização, entrada privada e persistência da ordem |
| [RFC 001 · AWS Academy](rfc/001-aws-academy.md) | Alternativas para a plataforma e critérios de aceite |
| [RFC 002 · PostgreSQL e DynamoDB](rfc/002-postgresql-dynamodb.md) | Isolamento de dados e histórico veicular |
| [RFC 003 · Estratégia de autenticação](rfc/003-autenticacao.md) | Identidades, JWT, autorização e integração privada |
| [ADR 001 · REST, SQS e Saga](adr/001-rest-sqs-saga.md) | Contratos entre serviços, consistência e compensação |
| [ADR 002 · Fronteiras de acesso](adr/002-fronteiras-de-acesso.md) | Gateway público e transporte interno do MVP |
| [ADR 003 · Escalabilidade de workloads](adr/003-escalabilidade-hpa.md) | Réplicas fixas no lab e critérios para avaliar HPA |
| [Guia rápido de deploy AWS Academy](../deploy-aws-academy-fase4.md) | Procedimento de implantação enviado pelo Júlio, adaptado para o repositório |

Os diagramas do Marcelo para a apresentação mostram a [divisão dos microsserviços](../diagram-fase4-dominios.md) e a [entrada HTTP e segurança](../diagram-fase4-entrada-seguranca.md).

**Repositório recomendado para publicação.** `postech15soat-infra-cloud` reúne o Gateway, a rede, o EKS e a observabilidade, além dos outputs que conectam Database e Auth. Este diretório é o ponto de referência para os documentos integrados. Para a entrega acadêmica, use o diagrama de componentes no PDF e referencie este índice para consulta aos detalhes. Os detalhes de OS, Billing, Inventory, Auth e Database ficam nos repositórios proprietários.

**Referência da implantação.** Os runs registram a Cloud em `full`, os quatro bancos lógicos validados e o deploy do Auth. Os testes de rota sem credenciais verificam exposição e autorização básica. A entrega pode anexar separadamente a evidência da jornada autenticada com dados sintéticos. [Cloud](https://github.com/PosTech15SOAT/postech15soat-infra-cloud/actions/runs/44140584016) · [PostgreSQL](https://github.com/PosTech15SOAT/postech15soat-infra-database/actions/runs/44164971101) · [Auth](https://github.com/PosTech15SOAT/numberone-app-auth/actions/runs/44173375280)
