# RFC 003 · Autenticação centralizada e autorização no Gateway

**Status** · Escolha adotada na implantação da Fase 4.

**Escopo** · Login de operador e cliente, acesso aos recursos e vínculo com a OS.

## Contexto

Operadores administram ordens e clientes acompanham os seus veículos e ordens. O Auth é dono de credenciais, perfis e permissões. A OS é dona do cadastro do cliente e da titularidade dos recursos. Uma alteração no vínculo ou no estado do cadastro deve ser considerada nas rotas protegidas.

## Alternativas

| Opção | Efeito no projeto |
| --- | --- |
| Login central e Lambda Authorizer no API Gateway | Concentra emissão do JWT, verificação de permissões e propagação de identidade. Os serviços conservam as regras de titularidade. |
| Cada microsserviço autentica o usuário | Dá controle ao serviço, com repetição de cadastro, validação e política de acesso. |
| Provedor de identidade gerenciado | Reduz a lógica própria de credenciais, com trabalho adicional de migração, integração e mapeamento de perfis e clientes. |

## Proposta adotada

Use `POST /auth/login` para validar credenciais e emitir JWT. Nas rotas protegidas o Authorizer verifica o JWT e reconsulta os dados atuais do usuário. Para login de cliente e rotas de acompanhamento, Auth consulta o vínculo ativo na OS pela origem HTTP privada. O Gateway sobrescreve os cabeçalhos de identidade a partir do Authorizer. As rotas públicas de aprovação e webhook ficam sob as validações do Billing.

## Aceite e consequências

Validar os dois logins, `401` sem token e `403` para cliente numa rota administrativa. Confirmar que um cliente acessa sua própria ordem e recebe recusa em recursos de outro cliente. Uma indisponibilidade de Auth ou da verificação de vínculo afeta a autorização dos fluxos que dependem dela. O ingresso privado usa o contrato registrado no ADR 002. [RFC original do Auth](https://github.com/PosTech15SOAT/numberone-app-auth/blob/main/docs/rfc/RFC-001-authentication-design.md) · [Contrato vigente](https://github.com/PosTech15SOAT/numberone-app-auth/blob/main/docs/fase-4-identidade.md) · [ADR 002](../adr/002-fronteiras-de-acesso.md)
