# Diagrama de componentes · NumberOne Fase 4

```mermaid
%%{init: {"flowchart": {"nodeSpacing": 20, "rankSpacing": 35, "wrappingWidth": 150}}}%%
flowchart TB
    Usuario["Cliente e operador"]
    MP["Mercado Pago TEST"]
    SMTP["Provedor SMTP"]
    DD["Datadog · logs, métricas e APM"]

    subgraph AWS["AWS Academy · us-east-1"]
        API["API Gateway · HTTP API principal"]
        Auth["Auth · Lambda Login e Authorizer"]
        Ingress["VPC Link, NLB interno e proxies NGINX"]
        Bridge["Ponte · HTTP API e Lambda"]
        Queue["SQS Standard e DLQ"]
        DDB[("DynamoDB · histórico veicular")]
        subgraph EKS["Amazon EKS"]
            OS["OS · execução e Saga"]
            Billing["Billing · orçamento e pagamento"]
            Inventory["Inventory · estoque"]
            Agent["Datadog Agent"]
        end
        SQL[("RDS PostgreSQL<br/>OS · Billing · Inventory · Auth")]
    end

    Usuario -->|HTTPS| API
    MP -->|Webhook HTTPS| API
    API -->|Login e autorização| Auth
    API -->|Roteamento · TCP 80| Ingress
    Auth -->|Identidade · HTTP 8081| Ingress
    Ingress --> OS
    Ingress --> Billing
    Ingress --> Inventory
    Billing -->|Checkout HTTPS| MP
    Billing --> SMTP
    Billing -->|Publica eventos| Bridge
    OS -->|Lê eventos e projeta histórico| Bridge
    Bridge --> Queue
    Bridge --> DDB
    OS --> SQL
    Billing --> SQL
    Inventory --> SQL
    Auth --> SQL
    OS -.-> Agent
    Billing -.-> Agent
    Inventory -.-> Agent
    Agent -.-> DD
```

- **Entrada.** O API Gateway recebe HTTPS e invoca Login ou Authorizer conforme a rota. As rotas de aplicação usam VPC Link, listener `80` e NGINX até os Services `ClusterIP` na porta `8080`. A consulta privada de identidade usa o listener `8081` do NLB e um proxy dedicado que alcança apenas a rota de identidade da OS. [Matriz de rotas e ingresso privado](../gateway-fase4.md)
- **Dados.** OS, Billing e Inventory usam `numberone_os`, `numberone_billing` e `numberone_inventory`. Auth usa `numberone_auth`, com runtime de leitura. Os segredos de conexão e a chave JWT ficam no Secrets Manager. A OS projeta o histórico veicular no DynamoDB pela ponte. [Configuração do Database](https://github.com/PosTech15SOAT/postech15soat-infra-database/blob/main/docs/phase4.md)
- **Mensageria.** A direção de negócio é Billing → OS. As setas dos dois pods para a ponte representam chamadas de infraestrutura de publicação, leitura e confirmação. A ponte autoriza a operação pela identidade do pod. A regra de negócio permanece nos microsserviços. [Configuração da ponte e das filas](../sqs-billing-fase4.md)
- **REST entre serviços.** A OS consulta e resolve consumo no Inventory e consulta quitação e solicita cancelamento no Billing. O Billing consulta composição na OS e preços no Inventory. Essas chamadas usam o DNS interno dos Services. [ADR de comunicação](adr/001-rest-sqs-saga.md)
- **Observabilidade.** Os microsserviços enviam telemetria ao Datadog Agent. O cruzamento do `correlationId` com o `eventId` permite ligar registros do Billing e da OS mesmo quando a jornada atravessa o SQS. [Módulo de observabilidade](../../infra/modules/observability/README.md)
