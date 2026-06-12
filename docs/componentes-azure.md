# Componentes Azure

| Componente | SKU/Configuracao PoC | Observacao |
|------------|----------------------|------------|
| Azure Container Apps | Consumption, min replicas 0 | Baixo custo e scale-to-zero |
| Azure SQL Database | Basic | Suficiente para PoC funcional |
| Azure Key Vault | Standard, RBAC, soft delete, purge protection | Armazena CMK |
| Log Analytics | Retencao 7 dias | Controle de custo |
| Microsoft Entra ID | App Registration + OBO | Identidade delegada |

## Producao

Para producao, revisar:

- Private Endpoint para SQL e Key Vault
- Private DNS
- VNet integration no ACA
- Retencao e exportacao de logs
- Defender for Cloud
- Politicas Azure Policy
- Segregacao administrativa real
- Revisao LGPD/privacidade

