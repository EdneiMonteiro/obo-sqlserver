# Apresentação HTML

Abra [apresentação.html](apresentacao.html) no navegador. CSS, JavaScript,
diagramas e documentos estão no próprio arquivo. É possível copiá-lo para
outra pasta e usá-lo sem servidor ou conexão.

## Conteúdo e controles

Os slides cobrem objetivo, arquitetura, autenticação, chamadas, implantação,
testes e operação. A aba Documentação contém os arquivos completos, incluindo
legado ACA, licença e metadados de citação.

| Controle | Ação |
|---|---|
| Anterior/Próximo, setas esquerda/direita, Page Up/Down | Navegar |
| Home/End | Primeiro/último item |
| Roteiro/Documentação | Alternar slides e documentos |
| Leitura | Exibir os slides em sequência |
| Buscar, `/` ou Ctrl+K | Pesquisar slides e documentos |
| Notas ou `N` | Mostrar notas técnicas |
| Ampliar | Abrir o diagrama com zoom |
| Imprimir | Roteiro, documentação completa ou slide atual |
| Índice | Abrir a navegação em telas pequenas |

Links externos só abrem quando selecionados. Badges remotos aparecem como
texto. O arquivo não envia telemetria, executa comandos ou grava o checklist.

## Regenerar

Edite os Markdown e `tools\presentation\slides.mjs`. O gerador extrai tabelas,
comandos e diagramas das fontes e grava `docs\apresentacao.html`.

```powershell
Set-Location .\tools\presentation
npm ci
npx playwright install chromium
npm run build
npm test
```

A geração exige Node.js 20+ e Chromium do Playwright. A leitura exige apenas um
navegador com JavaScript.

Não edite o HTML gerado manualmente. Os testes comparam os hashes das fontes
para detectar conteúdo desatualizado. O build não lê `.local`, kubeconfigs ou
arquivos de segredos.

## Verificação

Os testes abrem o HTML por `file:` e conferem conteúdo, links, navegação, busca,
zoom, layout, impressão e funcionamento sem rede.
A CI falha se as fontes mudarem sem regenerar o HTML.

A páginação da impressão depende do navegador. Preserve LICENSE e os
metadados de autoria ao distribuir o arquivo.
