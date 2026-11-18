# Sequência · Autenticação e abertura de ordem de serviço

O cenário começa com um operador cadastrado no Auth e um cliente ativo e seu veículo cadastrados na OS. O operador usa HTTPS no Gateway em modo `full`. A abertura recebe `idCliente`, `idVeiculo` e `descricaoInicial`.

```mermaid
%%{init: {"sequence": {"actorMargin": 26, "width": 125, "wrap": true}}}%%
sequenceDiagram
    actor Operador
    participant GW as API Gateway
    participant Login as Lambda Login
    participant Authz as Lambda Authorizer
    participant AuthDB as PostgreSQL Auth
    participant Rede as Entrada privada EKS
    participant OS as OS Service
    participant OSDB as PostgreSQL OS

    Operador->>GW: POST /auth/login · CPF, senha e identityType OPERATOR
    GW->>Login: Encaminha login e X-Correlation-Id
    Login->>AuthDB: Consulta identidade, perfil, permissões e hash
    AuthDB-->>Login: Dados da identidade do operador
    alt Credencial válida
        Login-->>GW: 200 · accessToken, tokenType e expiresIn
        GW-->>Operador: Retorna JWT
    else Credencial inválida
        Login-->>GW: 401
        GW-->>Operador: 401
    end

    Note over Operador,GW: A abertura pressupõe o JWT emitido no login
    Operador->>GW: POST /api/admin/ordens-servico · Bearer JWT e X-Correlation-Id
    GW->>Authz: Valida acesso à rota
    Authz->>Authz: Verifica assinatura, validade e claims do JWT
    Authz->>AuthDB: Reconsulta identidade ativa e permissões
    AuthDB-->>Authz: Perfil e permissões atuais
    alt Operador autorizado · ADMIN_ACCESS
        Authz-->>GW: Autoriza e devolve contexto da identidade
        GW->>Rede: VPC Link, NLB e NGINX com X-Authenticated-* sobrescritos
        Rede->>OS: REST para o Service ClusterIP
        OS->>OSDB: Valida cliente ativo e vínculo do veículo
        alt Cadastro e vínculo válidos
            OS->>OSDB: Grava a ordem e a Saga IN_DIAGNOSIS na transação local
            OSDB-->>OS: Commit confirmado
            OS-->>Rede: 201 Created · Location e recurso da ordem
        else Validação de negócio falha
            OS-->>Rede: Erro conforme contrato da OS
        end
        Rede-->>GW: Resultado da OS
        GW-->>Operador: Resultado da abertura
    else Identidade inválida ou acesso insuficiente
        Authz-->>GW: Recusa autorização
        GW-->>Operador: 401 ou 403 conforme a falha
    end
```

- O login de **cliente** adiciona uma consulta da Lambda à rota `POST /internal/auth/customer-identity` pelo listener privado `8081`. O Authorizer também checa esse vínculo para acesso do cliente a rotas de acompanhamento. A autorização administrativa do diagrama é de um operador. [Contrato de identidade](https://github.com/PosTech15SOAT/numberone-app-auth/blob/main/docs/fase-4-identidade.md)
- O `201` confirma a transação da abertura. Os eventos comerciais do Billing participam da Saga depois que houver orçamento. [Controller de abertura](https://github.com/PosTech15SOAT/numberone-service-order/blob/main/src/main/java/br/com/fiap/numberone/serviceorder/api/controllers/ServiceOrderController.java) · [Persistência de OS e Saga](https://github.com/PosTech15SOAT/numberone-service-order/blob/main/src/main/java/br/com/fiap/numberone/serviceorder/infrastructure/persistence/gateways/JpaServiceOrderGateway.java)
- Modo `full`, sobrescrita dos cabeçalhos e rotas administrativas estão declarados na Cloud. O teste sem token recebido pelo Gateway retornou `401`. A demonstração do `201` exige um operador válido e o par cliente–veículo. [Matriz do Gateway](../gateway-fase4.md)
