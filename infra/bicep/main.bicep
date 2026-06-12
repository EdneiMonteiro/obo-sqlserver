targetScope = 'resourceGroup'

@description('Azure region for the PoC resources.')
param location string = resourceGroup().location

@description('Short environment name used in resource names.')
param environmentName string = 'poc'

@description('Base name used to derive Azure resource names.')
param workloadName string = 'obo-sql'

@description('Container image for the API. Replace after building/publishing the API image.')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Microsoft Entra object id for the Azure SQL administrator.')
param sqlEntraAdminObjectId string

@description('Microsoft Entra display name/login for the Azure SQL administrator.')
param sqlEntraAdminLogin string

@description('Object ids that should receive Key Vault Crypto User on the PoC vault.')
param keyVaultCryptoUserObjectIds array = []

@description('Allow Azure services to reach SQL public endpoint. Use false unless ACA cannot reach SQL during the PoC.')
param allowAzureServicesToSql bool = false

var suffix = toLower(uniqueString(subscription().id, resourceGroup().id, workloadName, environmentName))
var regionCodes = {
  brazilsouth: 'brs'
  brazilsoutheast: 'brse'
  eastus: 'eus'
  eastus2: 'eus2'
  westus: 'wus'
  westus2: 'wus2'
  westus3: 'wus3'
  centralus: 'cus'
  northeurope: 'neu'
  westeurope: 'weu'
}
var regionCode = contains(regionCodes, toLower(location)) ? regionCodes[toLower(location)] : substring(replace(toLower(location), ' ', ''), 0, 3)
var logName = 'log-${workloadName}-${environmentName}-${regionCode}'
var identityName = 'id-${workloadName}-api-${environmentName}-${regionCode}'
var caeName = 'cae-${workloadName}-${environmentName}-${regionCode}'
var appName = 'ca-${workloadName}-api-${environmentName}-${regionCode}'
var sqlServerName = 'sql-${workloadName}-${environmentName}-${suffix}'
var sqlDatabaseName = 'sqldb-${workloadName}-${environmentName}'
var keyVaultName = take('kv-${replace(workloadName, '-', '')}-${environmentName}-${suffix}', 24)
var keyName = 'cmk-documents'
var sqlScopeHost = substring(environment().suffixes.sqlServerHostname, 1)

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource apiIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
  }
}

resource documentKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: keyVault
  name: keyName
  properties: {
    kty: 'RSA'
    keySize: 3072
    keyOps: [
      'wrapKey'
      'unwrapKey'
      'encrypt'
      'decrypt'
      'sign'
      'verify'
    ]
  }
}

resource cryptoUserAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for objectId in keyVaultCryptoUserObjectIds: {
  name: guid(keyVault.id, objectId, 'key-vault-crypto-user')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '12338af0-0e69-4776-bea7-57ae8d297424')
    principalId: objectId
    principalType: 'User'
  }
}]

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'User'
      login: sqlEntraAdminLogin
      sid: sqlEntraAdminObjectId
      tenantId: tenant().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 2147483648
  }
}

resource allowAzureServicesFirewall 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (allowAzureServicesToSql) {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: caeName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${apiIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
      }
    }
    template: {
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
      containers: [
        {
          name: 'api'
          image: containerImage
          env: [
            {
              name: 'Sql__ConnectionString'
              value: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Database=${sqlDatabase.name};Encrypt=True;TrustServerCertificate=False;Column Encryption Setting=Enabled;'
            }
            {
              name: 'Sql__DatabaseScope'
              value: 'https://${sqlScopeHost}/user_impersonation'
            }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
    }
  }
}

output containerAppName string = containerApp.name
output containerAppUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
output keyVaultName string = keyVault.name
output keyVaultKeyId string = documentKey.properties.keyUriWithVersion
output sqlServerName string = sqlServer.name
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDatabase.name
output userAssignedIdentityClientId string = apiIdentity.properties.clientId
