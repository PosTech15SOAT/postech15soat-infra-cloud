# Módulo ECR

Provisiona o repositório de imagens da API `numberone-auto-service-api`.

## Recursos

- repositório Amazon ECR com tags mutáveis;
- scan de vulnerabilidades no push;
- criptografia AES256;
- lifecycle policy que mantém as 20 imagens mais recentes.

## Decisões relevantes

O repositório permite exclusão forçada pelo Terraform (`force_delete = true`),
inclusive quando contém imagens. O nome do repositório é a única entrada do
módulo; a saída é `repository_url`.
