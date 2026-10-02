#!/usr/bin/env python3
"""Gera docs/tutorial-obo/tutorial-obo.pptx a partir do passo a passo do
README.md deste diretório. Rode novamente após editar o README para manter a
apresentação sincronizada:

    python docs\\tutorial-obo\\gerar-apresentacao.py
"""
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN
from pathlib import Path

OUT_PATH = Path(__file__).parent / "tutorial-obo.pptx"

NAVY = RGBColor(0x0B, 0x2A, 0x4A)
ACCENT = RGBColor(0x2B, 0x6C, 0xB0)
DARK = RGBColor(0x20, 0x20, 0x20)
LIGHT_BG = RGBColor(0xF5, 0xF7, 0xFA)
MONO_BG = RGBColor(0x1E, 0x1E, 0x1E)
MONO_FG = RGBColor(0xD4, 0xD4, 0xD4)

prs = Presentation()
prs.slide_width = Inches(13.333)
prs.slide_height = Inches(7.5)
BLANK = prs.slide_layouts[6]


def add_slide():
    return prs.slides.add_slide(BLANK)


def set_background(slide, color):
    fill = slide.background.fill
    fill.solid()
    fill.fore_color.rgb = color


def add_textbox(slide, left, top, width, height):
    box = slide.shapes.add_textbox(left, top, width, height)
    tf = box.text_frame
    tf.word_wrap = True
    return tf


def add_title(slide, text, color=NAVY, size=34, top=Inches(0.5)):
    tf = add_textbox(slide, Inches(0.6), top, Inches(12.1), Inches(1.0))
    p = tf.paragraphs[0]
    run = p.add_run()
    run.text = text
    run.font.size = Pt(size)
    run.font.bold = True
    run.font.color.rgb = color
    return tf


def add_kicker(slide, text):
    tf = add_textbox(slide, Inches(0.6), Inches(0.18), Inches(12.1), Inches(0.4))
    p = tf.paragraphs[0]
    run = p.add_run()
    run.text = text.upper()
    run.font.size = Pt(14)
    run.font.bold = True
    run.font.color.rgb = ACCENT
    return tf


def add_bullets(slide, items, left=Inches(0.7), top=Inches(1.6), width=Inches(11.9),
                 height=Inches(5.2), size=20, color=DARK):
    tf = add_textbox(slide, left, top, width, height)
    tf.word_wrap = True
    for i, item in enumerate(items):
        if isinstance(item, tuple):
            text, level = item
        else:
            text, level = item, 0
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.level = level
        run = p.add_run()
        run.text = ("• " if level == 0 else "– ") + text
        run.font.size = Pt(size - level * 2)
        run.font.color.rgb = color
        p.space_after = Pt(10)
    return tf


def add_code_block(slide, lines, left=Inches(0.7), top=Inches(1.7), width=Inches(11.9),
                    height=Inches(5.0), size=16):
    box = slide.shapes.add_shape(1, left, top, width, height)  # 1 = MSO_SHAPE.RECTANGLE
    box.fill.solid()
    box.fill.fore_color.rgb = MONO_BG
    box.line.color.rgb = MONO_BG
    tf = box.text_frame
    tf.word_wrap = True
    tf.margin_left = Inches(0.25)
    tf.margin_top = Inches(0.2)
    tf.margin_right = Inches(0.25)
    for i, line in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        run = p.add_run()
        run.text = line
        run.font.name = "Consolas"
        run.font.size = Pt(size)
        run.font.color.rgb = MONO_FG
        p.space_after = Pt(4)
    return box


def add_footer(slide, text):
    tf = add_textbox(slide, Inches(0.6), Inches(7.05), Inches(10.0), Inches(0.35))
    p = tf.paragraphs[0]
    run = p.add_run()
    run.text = text
    run.font.size = Pt(11)
    run.font.color.rgb = RGBColor(0x90, 0x90, 0x90)


# ---------------------------------------------------------------------------
# Slide 1 — Capa
# ---------------------------------------------------------------------------
slide = add_slide()
set_background(slide, NAVY)
tf = add_textbox(slide, Inches(0.9), Inches(2.5), Inches(11.5), Inches(1.6))
p = tf.paragraphs[0]
run = p.add_run()
run.text = "Tutorial incremental de OBO"
run.font.size = Pt(48)
run.font.bold = True
run.font.color.rgb = RGBColor(0xFF, 0xFF, 0xFF)

tf2 = add_textbox(slide, Inches(0.9), Inches(3.6), Inches(11.5), Inches(1.0))
p2 = tf2.paragraphs[0]
run2 = p2.add_run()
run2.text = "Validando o fluxo On-Behalf-Of em camadas, 100% local, sem container"
run2.font.size = Pt(22)
run2.font.color.rgb = RGBColor(0xCF, 0xE3, 0xF5)

tf3 = add_textbox(slide, Inches(0.9), Inches(6.5), Inches(11.5), Inches(0.5))
p3 = tf3.paragraphs[0]
run3 = p3.add_run()
run3.text = "docs/tutorial-obo/README.md  •  src/samples/obo-tutorial/"
run3.font.size = Pt(14)
run3.font.color.rgb = RGBColor(0x8F, 0xB4, 0xD6)

# ---------------------------------------------------------------------------
# Slide 2 — Problema / objetivo
# ---------------------------------------------------------------------------
slide = add_slide()
set_background(slide, RGBColor(0xFF, 0xFF, 0xFF))
add_kicker(slide, "Objetivo")
add_title(slide, "Por que este tutorial existe")
add_bullets(slide, [
    "O lab completo (SPA + BFF + API + AKS) prova o OBO de ponta a ponta, mas tem muitas peças em movimento.",
    "Este tutorial isola a mecânica do OBO em dois hops simples, sem AKS, sem container, sem app nova.",
    "Reaproveita a App Registration real do lab (obo-api) — o que é validado aqui é literalmente o mesmo recurso usado em produção.",
    "Público: quem precisa confirmar rapidamente, no ambiente do cliente, que o OBO está configurado corretamente antes de investir no deploy completo.",
])
add_footer(slide, "Tutorial incremental de OBO")

# ---------------------------------------------------------------------------
# Slide 3 — Visão geral das camadas
# ---------------------------------------------------------------------------
slide = add_slide()
set_background(slide, RGBColor(0xFF, 0xFF, 0xFF))
add_kicker(slide, "Visão geral")
add_title(slide, "Duas camadas, dois hops")

# simple flow diagram using shapes
def add_box(slide, text, left, top, width, height, fill=ACCENT, font_color=RGBColor(0xFF, 0xFF, 0xFF), size=16):
    shape = slide.shapes.add_shape(1, left, top, width, height)
    shape.fill.solid()
    shape.fill.fore_color.rgb = fill
    shape.line.color.rgb = fill
    tf = shape.text_frame
    tf.word_wrap = True
    p = tf.paragraphs[0]
    p.alignment = PP_ALIGN.CENTER
    run = p.add_run()
    run.text = text
    run.font.size = Pt(size)
    run.font.bold = True
    run.font.color.rgb = font_color
    return shape

def add_arrow_label(slide, text, left, top, width):
    tf = add_textbox(slide, left, top, width, Inches(0.4))
    p = tf.paragraphs[0]
    p.alignment = PP_ALIGN.CENTER
    run = p.add_run()
    run.text = text
    run.font.size = Pt(13)
    run.font.italic = True
    run.font.color.rgb = DARK

top_row = Inches(2.2)
box_h = Inches(1.1)
add_box(slide, "Usuário de\nteste", Inches(0.7), top_row, Inches(2.2), box_h, fill=NAVY)
add_arrow_label(slide, "Camada 1\nAzureCliCredential\nhop 1: user_impersonation", Inches(2.95), top_row - Inches(0.15), Inches(2.6))
add_box(slide, "obo-api\n(Step1.ConsoleLogin\nreaproveita o appId)", Inches(5.6), top_row, Inches(2.6), box_h, fill=ACCENT)
add_arrow_label(slide, "Camada 2\nOBO (Step2.MiddleTier)\nhop 2: vault.azure.net", Inches(8.25), top_row - Inches(0.15), Inches(2.6))
add_box(slide, "Key Vault\nreal do lab\n(cmk-documents)", Inches(10.9), top_row, Inches(2.0), box_h, fill=RGBColor(0x3E, 0x8E, 0x41))

add_bullets(slide, [
    "Step1.ConsoleLogin prova o 1º hop: usuário → API (token delegado user_impersonation).",
    "Step2.MiddleTier + Step2.ConsoleClient provam o 2º hop: API → Key Vault (OBO via ITokenAcquisition).",
    "Cada camada roda isolada com dotnet run — sem subir o lab inteiro.",
], top=Inches(4.0), height=Inches(2.8))
add_footer(slide, "Tutorial incremental de OBO")

# ---------------------------------------------------------------------------
# Slide 4 — Pré-requisitos
# ---------------------------------------------------------------------------
slide = add_slide()
set_background(slide, RGBColor(0xFF, 0xFF, 0xFF))
add_kicker(slide, "Antes de começar")
add_title(slide, "Pré-requisitos")
add_bullets(slide, [
    "Lab implantado (scripts\\deploy-aks.ps1 já executado) com .local\\aks\\deployment.local.json presente.",
    "Login prévio no Azure CLI no tenant do lab (perfil isolado se você usa múltiplos tenants):",
    ('$env:AZURE_CONFIG_DIR = "$HOME\\.azure-tenant-<tenantId>"', 1),
    ('az login --tenant "<tenantId>" --allow-no-subscriptions', 1),
    "Os consoles reaproveitam essa sessão via AzureCliCredential (nenhum device code).",
    ".NET SDK 8.0 instalado.",
    "Um usuário de teste com conta no tenant (pode ser o próprio operador, se não houver conta de teste dedicada).",
])
add_footer(slide, "Tutorial incremental de OBO")

# ---------------------------------------------------------------------------
# Slide 5 — Camada 0: Preparação
# ---------------------------------------------------------------------------
slide = add_slide()
set_background(slide, RGBColor(0xFF, 0xFF, 0xFF))
add_kicker(slide, "Camada 0 — uma vez só")
add_title(slide, "Preparação (ajustes temporários e reversíveis)")
add_bullets(slide, [
    "1. Conceder ao usuário de teste a role Key Vault Crypto User no vault do lab.",
    "2. Pré-autorizar o Azure CLI (appId first-party) em obo-api (evita AADSTS65001 em tenants com consentimento restrito).",
    "3. Criar um client secret temporário em obo-api (necessário para o middle tier fazer OBO local).",
    "4. Abrir temporariamente o firewall do Key Vault para o seu IP — o vault do lab usa publicNetworkAccess=Disabled (só private endpoint).",
], size=19)
add_bullets(slide, [
    "Passos 1, 3 e 4 são temporários e reversíveis (ver Limpeza); o passo 2 é permanente e documentado com o comando az exato em docs/tutorial-obo/README.md.",
], top=Inches(5.9), height=Inches(1.0), size=16, color=RGBColor(0x60, 0x60, 0x60))
add_footer(slide, "Tutorial incremental de OBO")

# ---------------------------------------------------------------------------
# Slide 6 — Camada 1: comando
# ---------------------------------------------------------------------------
slide = add_slide()
set_background(slide, RGBColor(0xFF, 0xFF, 0xFF))
add_kicker(slide, "Camada 1")
add_title(slide, "Step1.ConsoleLogin — login + 1º hop")
add_code_block(slide, [
    "cd src\\samples\\obo-tutorial\\Step1.ConsoleLogin",
    "dotnet run -- <tenantId> <api-appId>",
], top=Inches(1.7), height=Inches(1.1))
add_bullets(slide, [
    "Reaproveita a sessão já autenticada do az login via AzureCliCredential — nenhuma interação aqui.",
    "Solicita um token para api://<api-appId>/.default (formato exigido pelo AzureCliCredential).",
    "Decodifica e imprime as claims do token: aud, scp, tid, oid, upn.",
    "Não chama nenhum recurso protegido ainda — só prova que o 1º hop funciona.",
], top=Inches(3.1), height=Inches(2.2))
add_footer(slide, "Tutorial incremental de OBO")

# ---------------------------------------------------------------------------
# Slide 7 — Camada 1: saída esperada
# ---------------------------------------------------------------------------
slide = add_slide()
set_background(slide, RGBColor(0xFF, 0xFF, 0xFF))
add_kicker(slide, "Camada 1")
add_title(slide, "Saída esperada")
add_code_block(slide, [
    "Obtendo token via login existente do Azure CLI (az login)...",
    "",
    "Token adquirido com sucesso. Claims relevantes:",
    "  aud: <api-appId>",
    "  scp: user_impersonation",
    "  tid: <tenantId>",
    "  oid: <objectId-do-usuario>",
    "  upn: usuario@dominio.com",
], top=Inches(1.7), height=Inches(3.6))
add_bullets(slide, [
    "aud = appId da API real do lab e scp = user_impersonation comprovam o 1º hop.",
], top=Inches(5.6), height=Inches(0.8), size=16, color=RGBColor(0x60, 0x60, 0x60))
add_footer(slide, "Tutorial incremental de OBO")

# ---------------------------------------------------------------------------
# Slide 8 — Camada 2: configurar middle tier
# ---------------------------------------------------------------------------
slide = add_slide()
set_background(slide, RGBColor(0xFF, 0xFF, 0xFF))
add_kicker(slide, "Camada 2 — passo 1 de 3")
add_title(slide, "Step2.MiddleTier — configurar")
add_code_block(slide, [
    "cd src\\samples\\obo-tutorial\\Step2.MiddleTier",
    'dotnet user-secrets set "AzureAd:TenantId" "<tenantId>"',
    'dotnet user-secrets set "AzureAd:ClientId" "<api-appId>"',
    'dotnet user-secrets set "AzureAd:ClientSecret" "<secret-da-Camada-0>"',
    'dotnet user-secrets set "KeyVault:Uri" "https://<keyVaultName>.vault.azure.net"',
], top=Inches(1.8), height=Inches(2.3), size=15)
add_bullets(slide, [
    "Os segredos ficam em dotnet user-secrets — nunca em arquivo versionado.",
    "O appsettings.json commitado só tem placeholders vazios.",
], top=Inches(4.4), height=Inches(1.4))
add_footer(slide, "Tutorial incremental de OBO")

# ---------------------------------------------------------------------------
# Slide 9 — Camada 2: rodar
# ---------------------------------------------------------------------------
slide = add_slide()
set_background(slide, RGBColor(0xFF, 0xFF, 0xFF))
add_kicker(slide, "Camada 2 — passo 2 e 3 de 3")
add_title(slide, "Step2.MiddleTier + Step2.ConsoleClient — rodar")
add_code_block(slide, [
    "# Terminal 1 — deixe rodando",
    "dotnet run --urls http://localhost:5080",
    "",
    "# Terminal 2",
    "cd src\\samples\\obo-tutorial\\Step2.ConsoleClient",
    "dotnet run -- <tenantId> <api-appId>",
], top=Inches(1.8), height=Inches(2.6), size=16)
add_bullets(slide, [
    "O cliente repete o login da Camada 1 e chama GET /keyvault-demo no middle tier local.",
    "O middle tier troca o token do usuário por um token on-behalf-of escopado para o Key Vault.",
], top=Inches(4.8), height=Inches(1.6))
add_footer(slide, "Tutorial incremental de OBO")

# ---------------------------------------------------------------------------
# Slide 10 — Camada 2: saída esperada
# ---------------------------------------------------------------------------
slide = add_slide()
set_background(slide, RGBColor(0xFF, 0xFF, 0xFF))
add_kicker(slide, "Camada 2")
add_title(slide, "Saída esperada")
add_code_block(slide, [
    "Status: 200 OK",
    "Resposta (metadados da chave no Key Vault, via OBO em 2 hops):",
    "{",
    '  "key": { "kid": "https://<keyVaultName>.vault.azure.net/keys/cmk-documents/...",',
    '           "kty": "RSA", ... },',
    '  "attributes": { "enabled": true, ... }',
    "}",
], top=Inches(1.7), height=Inches(3.2), size=16)
add_bullets(slide, [
    "Prova o 2º hop: duas trocas de token encadeadas, o mesmo usuário do início ao fim.",
    "Validado ponta a ponta no tenant do lab — a resposta acima é real, não simulada.",
], top=Inches(5.2), height=Inches(1.4))
add_footer(slide, "Tutorial incremental de OBO")

# ---------------------------------------------------------------------------
# Slide 11 — Mapeamento para o código real
# ---------------------------------------------------------------------------
slide = add_slide()
set_background(slide, RGBColor(0xFF, 0xFF, 0xFF))
add_kicker(slide, "Do tutorial para o lab real")
add_title(slide, "Como isso mapeia para o BFF/API reais")

rows = [
    ("Tutorial", "Projeto real equivalente"),
    ("Step1.ConsoleLogin\n(login + token p/ API)", "src/bff/Services/ApiTokenProvider.cs"),
    ("Step2.MiddleTier\n(OBO API → Key Vault)", "src/api/Security/DelegatedTokenCredential.cs"),
]
table_shape = slide.shapes.add_table(len(rows), 2, Inches(0.8), Inches(1.9), Inches(11.5), Inches(2.2))
table = table_shape.table
table.columns[0].width = Inches(5.5)
table.columns[1].width = Inches(6.0)
for r, (a, b) in enumerate(rows):
    for c, text in enumerate((a, b)):
        cell = table.cell(r, c)
        cell.text = text
        for p in cell.text_frame.paragraphs:
            for run in p.runs:
                run.font.size = Pt(16)
                if r == 0:
                    run.font.bold = True
                    run.font.color.rgb = RGBColor(0xFF, 0xFF, 0xFF)
                else:
                    run.font.color.rgb = DARK
        if r == 0:
            cell.fill.solid()
            cell.fill.fore_color.rgb = NAVY
        else:
            cell.fill.solid()
            cell.fill.fore_color.rgb = LIGHT_BG

add_bullets(slide, [
    "A diferença é só a superfície: aqui é console + API minimalista; no lab real é SPA → BFF → API → AKS com Workload Identity federada (sem client secret) e TLS público.",
    "A mecânica OBO (duas trocas de token encadeadas, mesmo usuário do início ao fim) é idêntica.",
], top=Inches(4.5), height=Inches(2.0))
add_footer(slide, "Tutorial incremental de OBO")

# ---------------------------------------------------------------------------
# Slide 12 — Limpeza
# ---------------------------------------------------------------------------
slide = add_slide()
set_background(slide, RGBColor(0xFF, 0xFF, 0xFF))
add_kicker(slide, "Ao terminar")
add_title(slide, "Limpeza dos ajustes temporários")
add_bullets(slide, [
    "Remover o client secret temporário de obo-api (az ad app credential delete).",
    "Manter a pré-autorização do Azure CLI em obo-api (permanente — não concede acesso extra por si só).",
    "Fechar o firewall do Key Vault (publicNetworkAccess=Disabled, remover a network-rule).",
    "Remover a role Key Vault Crypto User do usuário de teste, se ele não precisar continuar com acesso.",
    "Limpar os dotnet user-secrets do Step2.MiddleTier (dotnet user-secrets clear).",
], size=19)
add_bullets(slide, [
    "Comandos exatos de cada passo estão na seção \"Limpeza\" de docs/tutorial-obo/README.md.",
], top=Inches(6.0), height=Inches(0.8), size=15, color=RGBColor(0x60, 0x60, 0x60))
add_footer(slide, "Tutorial incremental de OBO")

# ---------------------------------------------------------------------------
# Slide 13 — Encerramento
# ---------------------------------------------------------------------------
slide = add_slide()
set_background(slide, NAVY)
tf = add_textbox(slide, Inches(0.9), Inches(2.8), Inches(11.5), Inches(1.2))
p = tf.paragraphs[0]
run = p.add_run()
run.text = "Dúvidas / próximos passos"
run.font.size = Pt(40)
run.font.bold = True
run.font.color.rgb = RGBColor(0xFF, 0xFF, 0xFF)

tf2 = add_textbox(slide, Inches(0.9), Inches(4.0), Inches(11.5), Inches(1.8))
for i, line in enumerate([
    "docs/tutorial-obo/README.md — guia completo",
    "src/samples/obo-tutorial/ — código fonte dos 3 projetos",
    "Validado ponta a ponta no tenant do lab em 01/10/2026",
]):
    p = tf2.paragraphs[0] if i == 0 else tf2.add_paragraph()
    run = p.add_run()
    run.text = line
    run.font.size = Pt(18)
    run.font.color.rgb = RGBColor(0xCF, 0xE3, 0xF5)

prs.save(OUT_PATH)
print(f"Gerado: {OUT_PATH}")
