export const chapters = [
  { id: "contexto", title: "Objetivo e escopo" },
  { id: "arquitetura", title: "Arquitetura" },
  { id: "identidade", title: "Autenticação e permissões" },
  { id: "jornadas", title: "Chamadas HTTP e criptografia" },
  { id: "ambiente", title: "Implantação" },
  { id: "validacao", title: "Testes e operação" },
  { id: "entrega", title: "Referências" }
];

const docs = {
  intro: "README.md",
  architecture: "docs/arquitetura.md",
  identities: "docs/identidades-e-permissoes.md",
  flow: "docs/fluxo-logico.md",
  components: "docs/componentes-azure.md",
  deploy: "docs/deploy.md",
  operations: "docs/aks-bff.md",
  tests: "docs/validacao.md",
  separation: "docs/separation-of-duties.md",
  threats: "docs/modelo-ameacas.md",
  classes: "docs/classes-e-metodos.md",
  publication: "docs/publicacao.md",
  legacy: "docs/legacy/aca.md"
};

export const documentOrder = [
  docs.intro, docs.architecture, docs.identities, docs.flow, docs.components,
  docs.deploy, docs.operations, docs.tests, docs.separation, docs.threats,
  docs.classes, docs.publication, docs.legacy,
  "DISCLAIMER.md", "SUPPORT.md", "CONTRIBUTING.md", "docs/apresentacao.md"
];

export const slides = [
  {
    id: "inicio", chapter: "contexto", kind: "cover",
    title: "Lab OBO com Azure SQL\nAKS, Istio e BFF",
    lead: "Configuração de envio e leitura de documentos com identidade delegada e Always Encrypted.",
    cards: [
      { title: "Aplicação", text: "SPA com sessão no BFF e API .NET 8 no AKS." },
      { title: "Dados", text: "Payload cifrado no SQL e chave mestra no Key Vault." },
      { title: "Implantação", text: "Bicep, scripts PowerShell e testes de integração." }
    ],
    sources: [docs.intro, "DISCLAIMER.md"],
    notes: "A API obtém tokens OBO para SQL e Key Vault. O navegador recebe um cookie de sessão do BFF."
  },
  {
    id: "roteiro", chapter: "contexto", title: "Conteúdo",
    steps: [
      ["Objetivo e escopo", "Proteção dos documentos e limitações do exemplo."],
      ["Arquitetura", "Componentes, armazenamento e rede."],
      ["Autenticação", "Aplicações Entra, federação, tokens e permissões."],
      ["Chamadas", "Login, gravação, leitura, erros e logout."],
      ["Implantação", "Pré-requisitos, parâmetros, recursos e publicação."],
      ["Testes e operação", "E2E, segregação SQL/Key Vault, certificados e recuperação."]
    ],
    sources: [docs.intro, docs.deploy],
    notes: "Os documentos completos estão na aba Documentação. Os links no rodapé de cada slide abrem a seção de referência."
  },
  {
    id: "problema", chapter: "contexto", title: "Requisitos do lab",
    cards: [
      { title: "Armazenar o payload cifrado", text: "O Azure SQL recebe a coluna protegida por Always Encrypted." },
      { title: "Restringir a leitura", text: "A API compara tenant ID e object ID do usuário com o destinatário do documento." },
      { title: "Separar banco e chave", text: "O administrador SQL sem acesso à chave no Key Vault não consegue descriptografar o payload." }
    ],
    sources: [docs.intro, docs.threats],
    notes: "Metadados, destinatário e auditoria permanecem em claro no SQL. Apenas a coluna EncryptedPayload usa Always Encrypted."
  },
  {
    id: "fronteira", chapter: "contexto", title: "Limites da criptografia",
    cards: [
      { title: "SQL", text: "Armazena ciphertext. A leitura com Always Encrypted depende do unwrap da CEK no Key Vault." },
      { title: "BFF e API", text: "Processam plaintext nas operações autorizadas. Administradores do runtime podem acessar esses dados." }
    ],
    body: "O modelo é chamado **near-E2EE** neste projeto. E2EE estrito exigiria cifrar e descriptografar no cliente final.",
    sources: [docs.threats, docs.architecture],
    notes: "TLS protege o tráfego. Private Endpoints restringem o acesso de rede. Nenhum dos dois retira o plaintext da memória da aplicação."
  },
  {
    id: "escopos", chapter: "contexto", title: "Componentes e etapas de implantação",
    cards: [
      { label: "Aplicação", title: "Execução", text: "SPA, BFF, API, AKS/Istio, Entra, SQL, Key Vault, Blob, ACR e HTTPS." },
      { label: "Implantação", title: "Bootstrap", text: "Publica arquivos estáticos e configura chaves, tabelas e usuários." },
      { label: "Teste opcional", title: "Segregação", text: "Cria quatro identidades e grants SQL/Key Vault em uma etapa separada." }
    ],
    sources: [docs.intro, docs.architecture, docs.separation],
    notes: "deploy-aks.ps1 não cria os usuários db_owner de teste. Eles são provisionados por setup-validation.ps1."
  },
  {
    id: "visao-geral", chapter: "arquitetura", title: "Arquitetura da aplicação",
    diagram: { file: docs.intro, index: 0 },
    sources: [docs.architecture],
    notes: "O navegador acessa o BFF pelo Istio. O BFF lê os arquivos da SPA no Blob e encaminha as operações de documentos à API."
  },
  {
    id: "responsabilidades", chapter: "arquitetura", title: "Função de cada componente",
    excerpt: { file: docs.architecture, heading: "Responsabilidades", kind: "table" },
    sources: [docs.architecture, docs.classes],
    notes: "Istio configura tráfego e mTLS. A autenticação OAuth fica no BFF e a troca OBO fica na API."
  },
  {
    id: "onde-dados", chapter: "arquitetura", title: "Armazenamento",
    cards: [
      { label: "Blob", title: "Arquivos da SPA", text: "HTML, JavaScript e CSS lidos pelo BFF com a identidade federada da aplicação." },
      { label: "SQL", title: "Documentos e auditoria", text: "Payload cifrado, metadados, destinatário e eventos de acesso." },
      { label: "Key Vault", title: "Column Master Key", text: "CMK usada para proteger a CEK. O banco armazena a CEK cifrada e a referência à CMK." }
    ],
    body: "Base64 codifica os bytes nas mensagens JSON. A criptografia da coluna é aplicada pelo driver SQL.",
    sources: [docs.architecture, docs.flow],
    notes: "O download usa um objeto Blob do JavaScript. Ele não é o container do Azure Storage que armazena os arquivos da SPA."
  },
  {
    id: "rede", chapter: "arquitetura", title: "Rede",
    diagram: { file: docs.architecture, index: 0 },
    sources: [docs.architecture, docs.components],
    notes: "SQL, Blob e Key Vault usam Private Endpoints e DNS privado. O ACR usa endpoint público autenticado."
  },
  {
    id: "entradas", chapter: "arquitetura", title: "Endpoints públicos e privados",
    cards: [
      { title: "Aplicação", text: "Ingress HTTPS público no Istio. A API tem serviço ClusterIP e não possui ingress próprio." },
      { title: "Serviços de dados", text: "SQL, Key Vault e Storage têm publicNetworkAccess desabilitado. O Blob exige autenticação." },
      { title: "Controle do AKS", text: "Endpoint administrativo com Entra/RBAC e restrição por IP de saída. O template não cria control plane privado." }
    ],
    sources: [docs.architecture, docs.deploy],
    notes: "OperatorCidrs contém os IPs de saída da rede administrativa, não os IPs dos usuários da aplicação."
  },
  {
    id: "inventario", chapter: "arquitetura", title: "Recursos Azure",
    cards: [
      { title: "AKS, Istio e ACR", text: "Hospedagem da API/BFF, roteamento, mTLS e distribuição das imagens." },
      { title: "SQL, Key Vault e Storage", text: "Banco Basic, vault com RBAC, Blob LRS e três Private Endpoints." },
      { title: "Entra e certificados", text: "Duas App Registrations, identidades operacionais e certificado TLS para o ingress." }
    ],
    body: "Antes do deploy, consulte as versões AKS/Istio, a VM e a quota de vCPU disponíveis na região escolhida.",
    sources: [docs.components, docs.identities],
    notes: "A tabela de componentes contém as SKUs e versões configuradas. O custo inclui node, discos, IPs, Private Endpoints, SQL e ACR."
  },
  {
    id: "atores", chapter: "identidade", title: "Identidades utilizadas",
    cards: [
      { title: "Usuários", text: "Remetentes e destinatários autenticados no Entra, com grants SQL e acesso criptográfico." },
      { title: "Aplicações", text: "BFF e API têm registros Entra e service principals separados." },
      { title: "Operação do cluster", text: "Managed identities do controle AKS, kubelet e bootstrap recebem permissões específicas." }
    ],
    sources: [docs.identities],
    notes: "As managed identities do cluster não são usadas para acessar documentos no fluxo OBO."
  },
  {
    id: "registros", chapter: "identidade", title: "App Registrations do BFF e da API",
    cards: [
      { title: "BFF", text: "Cliente Web confidencial. Recebe o callback OIDC e obtém o token delegado destinado à API." },
      { title: "API", text: "Expõe user_impersonation, valida o token recebido e solicita tokens OBO para SQL e Key Vault." }
    ],
    excerpt: { file: docs.identities, heading: "Federacoes e consentimento", kind: "table" },
    sources: [docs.identities],
    notes: "A SPA não tem App Registration própria neste modelo. O BFF executa o fluxo OAuth."
  },
  {
    id: "ids", chapter: "identidade", title: "Identificadores",
    excerpt: { file: docs.identities, heading: "4. Identificadores", kind: "table" },
    sources: [docs.identities],
    notes: "No SQL, um SID diferente do identificador apresentado no token causa erro de login 18456."
  },
  {
    id: "federacao", chapter: "identidade", title: "Federação de workload e OBO",
    cards: [
      { title: "Credencial da aplicação", text: "O token projetado do pod é validado pelo Entra usando issuer, subject da ServiceAccount e audience da federação." },
      { title: "Acesso delegado do usuário", text: "A API troca o token recebido por tokens destinados a SQL e Key Vault, mantendo a identidade do usuário." }
    ],
    sources: [docs.identities, docs.operations],
    notes: "BFF e API usam SignedAssertionFilePath como credencial. O acesso SQL/Key Vault continua sujeito às permissões do usuário."
  },
  {
    id: "login", chapter: "identidade", title: "Login com Authorization Code e PKCE",
    steps: [
      ["Redirecionamento", "GET /bff/login redireciona o navegador ao Entra."],
      ["Autenticação", "O usuário faz login e conclui MFA quando exigido."],
      ["Callback", "O authorization code chega a /signin-oidc."],
      ["Troca do código", "O BFF apresenta o code, o verificador PKCE e a credencial federada."],
      ["Sessão", "O BFF guarda os tokens no servidor e envia um cookie de sessão ao navegador."]
    ],
    sources: [docs.flow, docs.operations],
    notes: "Senha e MFA são tratados pelo Entra. O cookie do BFF referencia um ticket armazenado no servidor."
  },
  {
    id: "tokens", chapter: "identidade", title: "Tokens e sessão",
    excerpt: { file: docs.architecture, heading: "Tokens e sessao", kind: "table" },
    sources: [docs.architecture, docs.identities],
    notes: "Cada recurso valida a audiência do access token. O token antiforgery é usado somente na validação de CSRF."
  },
  {
    id: "permissoes", chapter: "identidade", title: "Permissões por identidade",
    excerpt: { file: docs.identities, heading: "1. Identidades da aplicacao", kind: "table" },
    sources: [docs.identities],
    notes: "O consentimento permite solicitar scopes delegados. Grants SQL e RBAC no Key Vault autorizam as operações sobre os dados."
  },
  {
    id: "acl", chapter: "identidade", title: "Validações de acesso",
    cards: [
      { title: "Token recebido", text: "JWT válido, scope user_impersonation e azp/appid correspondente ao BFF." },
      { title: "Destinatário", text: "ReceiverTenantId e ReceiverObjectId devem corresponder ao usuário autenticado." },
      { title: "Banco e chave", text: "O usuário precisa dos grants SQL e da permissão criptográfica usados na operação." }
    ],
    body: "O SQL não tem Row-Level Security. SELECT direto e acesso à chave permitem ler outras linhas; a API é que restringe o destinatário.",
    sources: [docs.threats, docs.identities, docs.flow],
    notes: "O usuário remetente só pode ler documentos se também tiver permissão de leitura e for o destinatário."
  },
  {
    id: "criptografia", chapter: "jornadas", title: "Criptografia da coluna",
    cards: [
      { title: "CMK", text: "Chave mestra no Key Vault, usada para cifrar e decifrar a CEK." },
      { title: "CEK", text: "Chave usada na criptografia da coluna. Sua forma cifrada fica no SQL com a referência à CMK versionada." },
      { title: "EncryptedPayload", text: "O driver cifra antes do INSERT e descriptografa o resultado da leitura na API." }
    ],
    body: "A coluna usa **AEAD_AES_256_CBC_HMAC_SHA_256**, em modo randomized. Metadados, destinatário e auditoria ficam em claro.",
    sources: [docs.architecture, docs.separation],
    notes: "O provider do Key Vault é registrado por conexão SQL. Ele usa TokenCredential delegado para obter acesso à chave."
  },
  {
    id: "escrita", chapter: "jornadas", title: "Gravação de um documento",
    steps: [
      ["SPA para BFF", "POST /api/documents com cookie, antiforgery, destinatário e payload Base64."],
      ["BFF para API", "Valida sessão, CSRF e JSON. Acrescenta correlation ID e token destinado à API."],
      ["API para Entra", "Obtém tokens OBO para SQL e Key Vault."],
      ["API para SQL", "O driver cifra o payload. Documento e document_create/allowed são gravados em transação."],
      ["Resposta", "O BFF retorna HTTP 201 com documentId."]
    ],
    body: "Limite do documento: **10 MiB**. Limite do corpo HTTP: **15 MiB**, incluindo JSON e Base64.",
    sources: [docs.flow, docs.classes],
    notes: "A identidade do remetente é extraída das claims tid e oid, não do corpo enviado pela SPA."
  },
  {
    id: "contrato-http", chapter: "jornadas", title: "POST /api/documents",
    code: { file: docs.flow, heading: "Exemplo de contrato HTTP", kind: "first-code" },
    sources: [docs.flow, docs.classes],
    notes: "Substitua os placeholders. SGVsbG8= codifica o texto Hello. O BFF acrescenta o bearer somente na chamada interna POST /documents."
  },
  {
    id: "leitura", chapter: "jornadas", title: "Leitura de um documento",
    steps: [
      ["Requisição", "GET /api/documents/{id} é encaminhado pelo BFF."],
      ["Metadados", "A API consulta o documento sem carregar o payload. Retorna 404 se não existir."],
      ["Destinatário", "Compara tenant ID e object ID. Retorna 403 se o usuário não for o destinatário."],
      ["Payload", "O driver lê e descriptografa a coluna com acesso delegado à chave."],
      ["Auditoria e resposta", "Atualiza ReadAt, grava document_read/allowed e retorna os bytes em Base64."]
    ],
    sources: [docs.flow],
    notes: "A consulta do payload só ocorre após a verificação do destinatário."
  },
  {
    id: "sequencia", chapter: "jornadas", title: "Sequência de login e gravação",
    diagram: { file: docs.flow, index: 0 },
    sources: [docs.flow],
    notes: "Os tokens destinados a SQL e Key Vault ficam na API. A resposta ao navegador contém apenas dados da operação."
  },
  {
    id: "respostas", chapter: "jornadas", title: "Respostas HTTP",
    excerpt: { file: docs.flow, heading: "Erros e logout", kind: "table" },
    body: "O BFF filtra cookies, redirects e challenges do upstream. As respostas usam **Cache-Control: no-store**.",
    sources: [docs.flow, docs.classes],
    notes: "Rejeições no BFF, como CSRF inválido, não chegam à API e não são gravadas em DocumentAccessAudit."
  },
  {
    id: "sessao", chapter: "jornadas", title: "Configuração da sessão",
    cards: [
      { title: "Cookie", text: "HttpOnly, Secure e SameSite=Lax. O antiforgery usa cookie e header separados." },
      { title: "Armazenamento", text: "Tickets, cache MSAL e chaves Data Protection ficam na memória do BFF." },
      { title: "Expiração e reinício", text: "Sessões duram 30 minutos, sem renovação deslizante. Reiniciar o BFF encerra as sessões." }
    ],
    sources: [docs.operations],
    notes: "O deployment usa uma réplica e Recreate. Mais réplicas exigem ticket store, cache de tokens e chaves compartilhados. Logout não encerra o SSO do Entra."
  },
  {
    id: "preparar", chapter: "ambiente", title: "Pré-requisitos",
    cards: [
      { title: "Azure e rede", text: "Subscription, RG, região, quota de compute, versões AKS/Istio e acesso administrativo ao cluster." },
      { title: "Permissões", text: "Criação de recursos/RBAC, aplicações Entra, consentimento e preparação do SQL." },
      { title: "Ferramentas", text: "PowerShell, Azure CLI/Bicep, kubectl e kubelogin. Node.js e Python são usados nos testes locais." }
    ],
    sources: [docs.deploy, docs.identities],
    notes: "RBAC da subscription e permissões de diretório Entra são administrados separadamente. Os requisitos de cada etapa estão na matriz de identidades."
  },
  {
    id: "parametros", chapter: "ambiente", title: "Parâmetros do deploy",
    excerpt: { file: docs.deploy, heading: "Parametros", kind: "table" },
    sources: [docs.deploy, docs.identities],
    notes: "O estado gerado fica em .local. Os exemplos versionados usam placeholders."
  },
  {
    id: "participantes", chapter: "ambiente", title: "Usuários remetentes e destinatários",
    cards: [
      { label: "SenderObjectIds", title: "Envio", text: "Object IDs dos usuários que recebem INSERT em Documents e Audit, além de acesso à metadata AE." },
      { label: "ReceiverObjectIds", title: "Leitura", text: "Object IDs dos usuários que recebem SELECT, UPDATE(ReadAt), INSERT em Audit e acesso à metadata AE." },
      { label: "E2E", title: "Envio e leitura", text: "O usuário da suite de round-trip deve estar nas duas listas." }
    ],
    body: "O bootstrap concede permissões. Retirar um ID da configuração não revoga grants SQL ou RBAC existentes.",
    sources: [docs.identities, docs.deploy],
    notes: "Na primeira implantação, listas vazias não criam usuários. Em reaplicações, parâmetros omitidos preservam as listas do estado local."
  },
  {
    id: "infra", chapter: "ambiente", title: "Provisionar recursos e federações",
    code: { file: docs.deploy, command: ".\\scripts\\deploy-aks.ps1", includes: "-InfrastructureOnly" },
    body: "Cria as aplicações Entra, configura consentimento, executa what-if, aplica o Bicep e registra federações e redirects.",
    sources: [docs.deploy, docs.identities],
    notes: "infrastructureReady só passa a true após a conclusão das federações. Esta etapa não constrói imagens."
  },
  {
    id: "publicar", chapter: "ambiente", title: "Publicar a aplicação",
    code: { file: docs.deploy, heading: "4. Publicar a aplicacao", kind: "first-code" },
    steps: [
      ["Imagens", "Constrói API, BFF e operações no ACR."],
      ["Bootstrap", "Publica arquivos estáticos, cria chaves e schema e configura os participantes."],
      ["Kubernetes", "Aplica workloads, ServiceAccounts, mTLS e políticas."],
      ["TLS", "Obtém ou reutiliza o certificado e atualiza o Secret do ingress."]
    ],
    sources: [docs.deploy, docs.operations],
    notes: "O bootstrap roda dentro da VNet. O token SQL administrativo é montado em Secret temporário, removido ao final junto com o Job."
  },
  {
    id: "preparacao-separada", chapter: "ambiente", title: "Bootstrap e validação opcional",
    diagram: { file: docs.architecture, index: 1 },
    sources: [docs.architecture],
    notes: "bootstrap configura a aplicação. setup-validation cria os usuários de teste; remove-validation os retira."
  },
  {
    id: "smoke", chapter: "validacao", title: "Smoke test",
    code: { file: docs.deploy, command: ".\\scripts\\test-aks.ps1", excludes: "-IncludeSegregation" },
    cards: [
      { title: "Página e TLS", text: "Verifica a SPA por HTTPS e a resposta da sessão anônima." },
      { title: "Acesso anônimo", text: "A rota de documentos deve retornar 401 sem sessão." },
      { title: "Storage", text: "Confere as propriedades ARM e a recusa de leitura anônima do Blob." }
    ],
    sources: [docs.tests, docs.deploy],
    notes: "O smoke test não verifica OBO. A sonda Blob espera 403 fora da VNet ou 409/PublicAccessNotPermitted com FromPrivateNetwork."
  },
  {
    id: "e2e", chapter: "validacao", title: "Teste E2E no navegador",
    code: { file: docs.tests, heading: "2. E2E no navegador publicado", kind: "first-code" },
    steps: [
      ["Login", "O usuário conclui login Entra/MFA na janela do teste."],
      ["Documento", "Envia um arquivo sintético e compara os bytes do download."],
      ["Negações", "Verifica outro destinatário, POST sem CSRF e logout."],
      ["Sessão e tokens", "Verifica cookie HttpOnly/Secure, storage vazio e ausência de Authorization no frontend."]
    ],
    sources: [docs.tests],
    notes: "Após o login, deixe a automação operar a tela. A suite usa um usuário com permissão de envio e leitura."
  },
  {
    id: "segregacao", chapter: "validacao", badge: "OPCIONAL", title: "Teste de permissões SQL e Key Vault",
    excerpt: { file: docs.separation, heading: "Resultados dos testes", kind: "table" },
    sources: [docs.separation, docs.tests],
    notes: "Estes Jobs acessam SQL e Key Vault diretamente. Os critérios são comparação dos bytes, SQL 229 e Key Vault 403/ForbiddenByRbac."
  },
  {
    id: "opt-in", chapter: "validacao", badge: "OPCIONAL", title: "Configurar os testes de segregação",
    code: { file: docs.deploy, heading: "6. Validacao de segregacao (opcional)", kind: "first-code" },
    body: "O setup cria quatro identidades e grava **validation.local.json**. Dois usuários recebem db_owner. **remove-validation.ps1** remove esses controles após conferir os IDs e escopos.",
    sources: [docs.separation, docs.deploy],
    notes: "Os registros sintéticos no banco não são apagados pelo teardown. O deploy funcional não cria essas identidades."
  },
  {
    id: "evidencia", chapter: "validacao", title: "Testes executados e testes pendentes",
    cards: [
      { label: "Azure", title: "Rodada de 23/09/2026", text: "Login, OBO, upload/download e segregação SQL/Key Vault foram executados no ambiente de teste." },
      { label: "Azure", title: "Validação concluída em 30/09/2026", text: "Rollout por configuração, timeout de 90 s e E2E autenticado passaram. O lab foi desprovisionado após os testes." },
      { label: "Pendente", title: "Carga e recuperação", text: "Não foram executados testes de carga, HA, pentest completo ou um ciclo inteiro de renovação ACME." }
    ],
    sources: [docs.tests, docs.threats],
    notes: "O rollout manteve os digests das imagens; a sonda usou a DLL publicada e um controle com a imagem anterior. Lab e aplicações Entra removidos em 30/09; Key Vault em soft delete até 07/10. Os scripts ACA têm regressões locais, sem novo deploy legado."
  },
  {
    id: "estado", chapter: "validacao", title: "Estado de implantação e tags",
    cards: [
      { title: "deployment.local.json", text: "Contém destino, participantes, aplicações, readiness e tags de imagens." },
      { title: "InfrastructureOnly", text: "Preserva as tags existentes quando destino e registry permanecem iguais." },
      { title: "SkipImageBuild", text: "Reutiliza as tags registradas. Mudanças no manifesto atualizam os pods por revisão SHA-256. Falha se ainda não houver imagens construídas." }
    ],
    sources: [docs.operations, docs.deploy],
    notes: "Os arquivos de .local são ignorados pelo Git e pelo Docker. Mudanças de participantes exigem a etapa de infraestrutura para aplicar RBAC."
  },
  {
    id: "tls", chapter: "validacao", title: "Certificados TLS",
    steps: [
      ["HTTP-01", "O desafio ACME é atendido por HTTP. As demais rotas redirecionam para HTTPS."],
      ["Armazenamento", "Conta ACME e certificados ficam no PVC. Istio lê o Secret obo-tls."],
      ["Renovação", "Certbot verifica o certificado diariamente. certificate.py sincroniza o Secret após sucesso."],
      ["Recuperação", "Com o PVC preservado, reaplicar o deploy recupera um Secret perdido usando o certificado existente."]
    ],
    sources: [docs.operations, docs.deploy],
    notes: "Uma PKI corporativa pode substituir o Certbot. O ingress precisa receber um certificado válido para o hostname e uma cadeia confiável pelo cliente."
  },
  {
    id: "diagnostico", chapter: "validacao", title: "Diagnóstico de erros",
    cards: [
      { title: "401, 403 e IDW10503", text: "Conferir audiência, scope, AllowedClientId, destinatário e esquema OpenIdConnect." },
      { title: "SQL 18456 e Key Vault 403", text: "Conferir SID, grants, RBAC e DNS privado. Verificar se o código é ForbiddenByRbac ou ForbiddenByConnection." },
      { title: "TLS e kubectl", text: "Conferir hostname, certificado, Secret/PVC, readiness e OperatorCidrs." }
    ],
    sources: [docs.deploy, "SUPPORT.md"],
    notes: "Use o correlation ID para localizar a requisição. Remova dados pessoais, tokens e URLs de autenticação antes de compartilhar logs."
  },
  {
    id: "codigo", chapter: "entrega", title: "Classes e dependências",
    diagram: { file: docs.classes, index: 0 },
    sources: [docs.classes],
    notes: "O documento de classes descreve os DTOs, métodos, configurações e modos do executável de operações."
  },
  {
    id: "producao", chapter: "entrega", title: "Limitações e requisitos de produção",
    cards: [
      { title: "Disponibilidade", text: "O exemplo tem um node e uma réplica BFF. Tickets, tokens e chaves de sessão ficam em memória." },
      { title: "Acesso e recuperação", text: "Definir revogação de grants, rotação de chaves, backup, restore e acesso administrativo." },
      { title: "Monitoramento e custos", text: "WAF e logs centralizados não são provisionados. Recursos Azure continuam cobrados sem usuários ativos." }
    ],
    body: "Administradores do runtime podem acessar plaintext e tokens. A restrição por destinatário é aplicada na API, sem RLS no SQL.",
    sources: [docs.threats, docs.components, "DISCLAIMER.md"],
    notes: "O exemplo não foi validado para carga, HA ou recuperação de desastre."
  },
  {
    id: "legado", chapter: "entrega", badge: "LEGADO", title: "Alternativa com Azure Container Apps",
    cards: [
      { title: "Componentes", text: "API no ACA, cliente CLI/PowerShell e client secret." },
      { title: "Diferenças", text: "Não usa BFF. Regras de rede, credenciais e custos diferem do AKS." },
      { title: "Documentação", text: "O guia legado contém seus próprios comandos de implantação e testes." }
    ],
    sources: [docs.legacy],
    notes: "Use um ambiente separado para o legado. Seus comandos de firewall não devem ser aplicados aos serviços privados do AKS."
  },
  {
    id: "entrega-cliente", chapter: "entrega", title: "Checklist de implantação",
    checklist: [
      "Subscription, RG e região definidos.",
      "Quota de vCPU, VM e versões AKS/Istio verificadas.",
      "Permissões Azure, Entra, SQL e Key Vault concedidas.",
      "Object IDs de remetentes e destinatários configurados.",
      "Saída administrativa autorizada e DNS privado resolvendo os serviços.",
      "Certificado válido instalado no ingress.",
      "Smoke test, E2E e testes opcionais executados conforme o escopo.",
      "Backup, revogação de acesso, renovação TLS e cleanup atribuídos às equipes responsáveis."
    ],
    sources: [docs.deploy, docs.identities, docs.publication],
    notes: "As marcações deste checklist não são gravadas no arquivo."
  },
  {
    id: "biblioteca", chapter: "entrega", title: "Documentação incluída",
    cards: [
      { title: "Implementação", text: "Arquitetura, identidades, chamadas, componentes, deploy, operação e classes." },
      { title: "Testes", text: "Procedimentos, resultados, segregação SQL/Key Vault e limitações." },
      { title: "Manutenção", text: "Legado ACA, publicação, suporte, contribuição, licença e instruções de geração deste HTML." }
    ],
    sources: [docs.intro, "docs/apresentacao.md", "SUPPORT.md", "CONTRIBUTING.md", "DISCLAIMER.md"],
    notes: "A aba Documentação contém os arquivos completos. A busca funciona localmente; links externos abrem somente quando selecionados."
  }
];
