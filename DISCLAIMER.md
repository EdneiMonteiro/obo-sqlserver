# Aviso legal

Este repositório contém código de exemplo para uso educacional e experimental.
Não foi desenvolvido para uso direto em produção.

## Licença e garantias

O código é fornecido no estado em que se encontra, sem garantias expressas ou
implícitas, incluindo comercialização, adequação a uma finalidade específica
e não violação de direitos. Aplicam-se os termos da [licença MIT](LICENSE).

O autor não se responsabiliza por perda de dados, interrupções, falhas
operacionais ou impactos financeiros decorrentes do uso. Cabe ao usuário
revisar permissões, testar o funcionamento, avaliar o impacto nos dados e
preparar procedimentos de recuperação.

## Suporte

O projeto não é afiliado, endossado ou suportado oficialmente pela Microsoft.
Não há SLA ou compromisso de correção, atualização, suporte ou compatibilidade
futura. Dependências e APIs podem mudar e afetar o funcionamento.

## Dados sensíveis e produção

BFF e API processam plaintext nas operações autorizadas. Administradores do
runtime podem acessar esses dados. O exemplo não oferece E2EE estrito.

Antes de usar dados reais, revise segurança, privacidade/LGPD, conformidade,
disponibilidade, recuperação, monitoramento e desempenho.
Consulte o [modelo de ameaças](docs/modelo-ameacas.md) e a
[cobertura dos testes](docs/validacao.md).
