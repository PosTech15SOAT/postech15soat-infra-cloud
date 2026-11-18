# Fase 4 — entrada HTTP e segurança

Use este diagrama para explicar o caminho das requisições externas até os microsserviços. As rotas públicas e protegidas seguem a configuração do API Gateway.

```mermaid
flowchart LR
    User[Cliente ou atendente] -->|HTTPS| Gateway[API Gateway HTTP API]
    Gateway -->|login| Login[Lambda Login]
    Gateway -->|rota protegida:<br/>JWT e permissões| Authorizer[Lambda Authorizer]
    Gateway -->|integração privada| Link[VPC Link]
    Link --> NLB[NLB interno]
    NLB --> Proxy[Proxy no EKS]
    Proxy --> OS[OS Service<br/>ClusterIP:8080]
    Proxy --> Billing[Billing Service<br/>ClusterIP:8080]
    Proxy --> Inventory[Inventory Service<br/>ClusterIP:8080]
    OS <-->|REST por DNS interno| Billing
    OS <-->|REST por DNS interno| Inventory
    Billing -->|REST por DNS interno| Inventory
```

O Gateway recebe chamadas externas e aciona o Authorizer nas rotas protegidas. REST entre os Pods usa DNS e Services ClusterIP, sem passar pelo Gateway. A comunicação REST interna do MVP não autentica a identidade do serviço chamador. A ponte HTTP de SQS/DynamoDB tem autenticação própria com JWT temporário do ServiceAccount, explicada na [arquitetura completa](architecture-fase4.md).
