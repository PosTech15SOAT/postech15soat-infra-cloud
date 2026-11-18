# Fase 4 — divisão dos microsserviços

Use este diagrama na apresentação de arquitetura e decomposição. Cada serviço controla seus dados; os três databases lógicos estão na mesma instância RDS do laboratório.

```mermaid
flowchart LR
    OS[OS Service<br/>clientes, veículos, ordens<br/>diagnóstico, execução e Saga]
    Billing[Billing Service<br/>orçamentos, aprovação<br/>cobrança e pagamentos]
    Inventory[Inventory Service<br/>materiais, preços<br/>estoque e movimentações]

    OS <-->|REST interno| Billing
    OS -->|REST interno| Inventory
    Billing -->|REST interno: preços| Inventory
    Billing -->|HTTP + JWT| Bridge[Lambda ponte HTTP]
    OS -->|HTTP + JWT| Bridge
    Bridge <-->|publicar / receber / confirmar| SQS[(SQS Billing → OS)]

    OS --> OSDB[(PostgreSQL<br/>numberone_os)]
    Billing --> BDB[(PostgreSQL<br/>numberone_billing)]
    Inventory --> IDB[(PostgreSQL<br/>numberone_inventory)]
    Bridge -->|projeção do histórico da OS| History[(DynamoDB)]
```

A OS orquestra a Saga. Billing e Inventory confirmam suas próprias operações; nenhum serviço acessa diretamente o database de outro. Consulte a [arquitetura completa](architecture-fase4.md) para a entrada HTTP, a ponte JWT e a DLQ.
