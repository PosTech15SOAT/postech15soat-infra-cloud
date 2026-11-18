# ADR 002 · Entrada autenticada e origem privada da identidade

**Status** · Aceito para o MVP da Fase 4.

**Data de consolidação** · 17/11/2026.

## Contexto

O Gateway recebe tráfego externo. O Auth precisa confirmar se um cliente ainda está vinculado e ativo na OS. Os recursos do AWS Academy limitam as identidades disponíveis para componentes de rede e execução.

## Decisão

O cliente usa HTTPS no API Gateway. O Lambda Authorizer aplica a política de acesso às rotas protegidas, e a integração escreve os cabeçalhos de identidade confiáveis. O Gateway encaminha somente os métodos e caminhos cadastrados. O caminho de negócio passa pelo VPC Link, NLB interno e NGINX.

Para a verificação de identidade de cliente, as Lambdas usam `HTTP` na porta `8081` do NLB interno, com grupo de segurança dedicado e proxy de rota única. O contrato interno usa `X-Correlation-Id` e o par `customerId` e `cpf`. No MVP, esse trecho opera sem TLS e sem token de serviço. As rotas administrativas preservam o Authorizer na entrada pública.

## Alternativas e consequências

O desenho anterior usava HTTPS privado com CA e token compartilhado. O contrato adotado reduziu a configuração manual e passou a depender do isolamento de rede. A validação do limite de acesso inclui uma chamada de origem autorizada, uma de origem sem permissão e a verificação de que `/internal/**` permanece fora da matriz pública. A proteção do NLB cobre esse caminho de entrada, enquanto o acesso direto aos Services depende dos controles do cluster. [Matriz de rotas e security groups](../../gateway-fase4.md) · [Mudança da Cloud](https://github.com/PosTech15SOAT/postech15soat-infra-cloud/pull/39) · [Mudança no Auth](https://github.com/PosTech15SOAT/numberone-app-auth/pull/29)
