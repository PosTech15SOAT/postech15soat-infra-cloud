# Bloco 1B · Entrada HTTP no EKS

A stack Cloud é dona da HTTP API, do stage `$default`, do VPC Link, do NLB interno, do listener TCP, do target group e do vínculo com o Auto Scaling Group do EKS. As Lambdas e suas configurações ficam em Auth. As permissões de invocação ficam em Cloud, limitadas à rota de login e ao Authorizer desta API.

O NLB usa o desenho do plano da Fase 4. O cluster Academy não tem AWS Load Balancer Controller nem uma identidade de workload habilitada para gerenciar ELB. O Terraform vincula o target group ao ASG para acompanhar a substituição dos nós. Um DaemonSet NGINX instalado pela Cloud recebe tráfego em `18080` e deriva a lista de métodos e caminhos do mesmo mapa que publica as rotas do Gateway. Verifique os nomes DNS dos Services ao trocar o namespace ou o Service de uma aplicação. Os Services de OS, Billing e Inventory atendem em `8080` e permanecem `ClusterIP`.

O SG do NLB aceita TCP/80 exclusivamente do SG das ENIs do VPC Link. O NLB alcança a porta do DaemonSet no SG dos nós. O NGINX aceita as subnets privadas do VPC Link e compara o método e a URI à lista antes de encaminhar. O HTTPS termina no API Gateway. A integração privada usa HTTP. [Integração privada de HTTP API](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-private.html) · [Security groups do NLB](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-security-groups.html)

## Publicação

1. No state Cloud, configure `private_gateway_routes=probe` ou a variável de Actions `PRIVATE_GATEWAY_ROUTES=probe`. Revise e aplique o plano. Confirme VPC Link `AVAILABLE`, targets `healthy` e DaemonSet disponível nos nós.
2. Leia `terraform output -raw http_api_url`. Rode a pasta **Primeira rota e isolamento** da coleção com essa URL em `baseUrl`. O 404 HTML com `Cache-Control: no-store` distingue a resposta do Billing do 404 JSON do Gateway. Compare o `apigw-requestid` da resposta com `gatewayRequestId` do NGINX. A entrada do proxy deve trazer `service=billing` e `upstreamStatus=404`. A partir de um pod com o SG comum do EKS, tente acessar o listener do NLB diretamente. A conexão deve expirar.
3. Selecione `public` e revise o plano para adicionar aprovação/rejeição por formulário e webhook à consulta de decisão. Use `terraform output -raw billing_budget_approval_base_url` como a URL completa em `BUDGET_APPROVAL_BASE_URL` no deploy de Billing. Confira o valor no ConfigMap do release, pois versões do workflow usam o valor do overlay. O webhook usa o mesmo `http_api_url` com `/api/public/pagamentos/notificacoes/mercado-pago`. Valide link válido, expirado e reaplicação em massa sintética. Valide webhook com assinatura inválida e notificação real de teste quando a funcionalidade do Billing estiver habilitada.
4. Com o bloco 1A implantado, selecione `PRIVATE_GATEWAY_ROUTES=full`. O workflow lê os quatro outputs do state Auth antes do plano e fornece `auth_lambda_arns` automaticamente. Não configure `AUTH_LAMBDA_ARNS`. Habilite a confiança em cabeçalhos do Gateway no runtime da OS e do Inventory após conferir o acesso à rede interna. Selecione `full`, revise o plano e aplique. Rode a pasta **JWT e dados sintéticos**. Emita os tokens com as credenciais sintéticas do Auth. Use uma OS do cliente de teste e uma OS de outro cliente que realmente exista, além de um orçamento e um item de estoque sintéticos.
5. Para conferir a publicação ou reverter para a matriz pública, revise a mudança de `full` para `public` no mesmo state. Mantenha os parâmetros de rede do ambiente. Em `probe` e `public`, o workflow fornece `auth_lambda_arns=null` e não consulta Auth; voltar de `full` remove login, Authorizer e permissões de invocação da Cloud. Use a lista de rotas do API Gateway para conferir que todos os métodos publicados têm destino explícito e que `/internal/**` e Actuator ficam fora da publicação.

O proxy preserva método, query e corpo. O mapping `overwrite:path` encaminha o caminho da rota sem o prefixo do stage. O contexto do Authorizer sobrescreve os cinco cabeçalhos de identidade do contrato. Nas rotas públicas, o Billing recebe apenas os cabeçalhos de aplicação permitidos, inclusive `X-Correlation-Id`, `Idempotency-Key`, `X-Request-Id` e `X-Signature`. As duas validações públicas são feitas pelo Billing. Logs de acesso do Gateway e do proxy guardam identificadores, rota/método e códigos de resposta. A query, o corpo e as credenciais ficam fora do formato de log.

Execute `terraform test` em `infra` para verificar a matriz, as integrações e a configuração de identidade com providers simulados. Os testes HTTPS e a verificação de isolamento são executados na conta Academy. [Coleção Postman](postman/numberone-gateway.postman_collection.json)

## Origem HTTP privada para a identidade da OS

`OS_IDENTITY_INGRESS_ENABLED=true`, com `probe` ou `public`, adiciona um listener TCP/8081 ao NLB interno existente. O payload é HTTP sem TLS. A porta 18443 do target group e do DaemonSet é preservada para evitar substituir o target group; o número da porta não implica TLS. Não há certificado, CA nem Secret TLS.

O listener aceita somente o SG `os_identity_ingress.client_security_group_id`, que o Auth já consome via remote state e deve associar às Lambdas. A saída desse SG alcança apenas o SG do NLB em 8081, e o NLB alcança apenas o SG dos nós em 18443. As regras do Gateway em 80/18080 permanecem. O proxy dedicado encaminha somente `POST /internal/auth/customer-identity`, retorna 405 para outros métodos e 404 para outros caminhos. Encaminha Content-Type e X-Correlation-Id, sem Authorization. O endpoint não consta da matriz pública.

O output `os_identity_ingress.base_url` é a origem `http://<dns-interno-do-nlb>:8081`. O Terraform do Auth lê esse campo do state Cloud e define `OS_IDENTITY_BASE_URL` no runtime. `endpoint_url` inclui `/internal/auth/customer-identity` e serve à inspeção. Obtenha os campos com `terraform output -json os_identity_ingress`.

Os dois proxies leem o servidor DNS de `/etc/resolv.conf` do Pod. Os upstreams usam `zone` e `resolve` do NGINX 1.28, com cache de 5 segundos. Assim podem iniciar com os três Services ainda ausentes, responder 502 enquanto o destino não existe e passar a encaminhar quando o DNS estiver disponível. Probes TCP continuam verificando o proxy, não a disponibilidade das aplicações. Método, caminho, query, corpo, headers permitidos e timeouts permanecem. [Resolução dinâmica do NGINX](https://nginx.org/en/docs/http/ngx_http_upstream_module.html#resolve)

## Descoberta automática de Auth

O schema foi conferido no [Auth, revisão dfb688b](https://github.com/PosTech15SOAT/numberone-app-auth/tree/dfb688b990fee659953a84b4f30be53502a20e3d/infra). Antes de planejar em `full`, o workflow lê `s3://<AUTH_STATE_BUCKET>/auth/prod/terraform.tfstate`; `AUTH_STATE_BUCKET` é opcional e usa `TF_STATE_BUCKET` por padrão. A identidade do workflow precisa de `s3:GetObject` nesse objeto (e decrypt se houver KMS próprio). Bucket, região e chave do backend Cloud permanecem inalterados.

| Entrada Cloud | Output Auth |
| --- | --- |
| `login` | `auth_login_lambda_arn` |
| `login_invoke` | `auth_login_lambda_invoke_arn` |
| `authorizer` | `authorizer_lambda_arn` |
| `authorizer_invoke` | `authorizer_lambda_invoke_arn` |

O script `scripts/auth-lambda-arns.py` recebe o state por stdin, exige quatro strings não vazias, dois ARNs de função distintos na mesma partição/região/conta e duas URIs de invocação correspondentes. Falta de state, acesso negado ou saída inválida interrompe o job antes do plano. O state não é gravado em disco nem impresso; somente os quatro campos são passados pelo ambiente, com máscara de log. Outputs adicionais do Auth são ignorados. `probe`, `public` e `disabled` não consultam o state Auth.

## Conta nova: ordem de deploy

1. Prepare credenciais Academy, roles existentes e bucket do backend com o bootstrap existente. Configure as variáveis do workflow Cloud. Nenhuma mudança no orçamento, states ou ownership é necessária.
2. **Cloud inicial:** use `PRIVATE_GATEWAY_ROUTES=public` e `OS_IDENTITY_INGRESS_ENABLED=true`, sem Lambdas Auth. Revise o plano e aplique pelo fluxo existente. Isso prepara rede, EKS, NLB interno, proxies e URL privada; os Services das aplicações podem não existir. `probe` também permite preparar identidade, mas publica apenas a consulta de decisão.
3. Prepare a stack Database existente, bancos e credenciais de runtime; implante OS, Billing e Inventory nos Services previstos. Configure Billing com `billing_budget_approval_base_url`. O token do formulário e o HMAC do webhook continuam sendo validados no Billing.
4. **Auth:** implante a revisão que lê a origem HTTP e o SG cliente do state Cloud e o ARN do segredo PostgreSQL do state Database. Configure o banco pelo workflow `Initialize PostgreSQL`. O deploy do Auth publica os quatro outputs usados pela promoção da Cloud.
5. **Cloud final:** mantenha identidade habilitada, altere `PRIVATE_GATEWAY_ROUTES=full`, revise o plano e aplique. O workflow descobre os ARNs; publica login, Authorizer e as 25 rotas protegidas, preservando as cinco rotas Billing sem Authorizer.

O proxy principal aguarda o módulo EKS (incluindo os nós); o de identidade aguarda o principal, que cria o namespace compartilhado. Os recursos de identidade não dependem mais de Secret TLS, CA, Auth ou Services e podem participar do primeiro apply Cloud quando o Gateway está habilitado. Continua existindo a dependência do provider Helm de um EKS acessível e autorizado, inclusive para observabilidade já presente na base. Os testes locais não comprovam bootstrap real em conta vazia. Se esse provider exigir o cluster previamente criado, conclua a base Cloud antes de habilitar ingressos, ainda antes de Auth; não use `-target` nem recrie recursos para forçar um apply único.

## Validação por revisão

As revisões promovidas do Auth e da OS em 17/11 implementam o caminho privado HTTP sem Bearer. Ao implantar revisões anteriores, confira a compatibilidade das três stacks com o mesmo contrato. A execução de referência, da Cloud inicial até `full`, está registrada no [guia AWS Academy](deploy-aws-academy-fase4.md). [Promoção Auth](https://github.com/PosTech15SOAT/numberone-app-auth/pull/30) · [Promoção OS](https://github.com/PosTech15SOAT/numberone-service-order/pull/18)

Validação local: `terraform fmt -check -recursive`, `terraform validate`, `terraform test` em `infra` com providers simulados, `python3 -m unittest discover -s scripts/tests -v`. Os testes Python verificam outputs inválidos sem vazamento e usam Docker para iniciar os proxies com Services ausentes, registrar os três destinos depois e conferir encaminhamento e filtros. A execução em CI inclui esses testes. Não é feito apply/destroy real. Isolamento efetivo dos SGs, targets saudáveis e disponibilidade ponta a ponta precisam ser conferidos na conta após deploy autorizado.
