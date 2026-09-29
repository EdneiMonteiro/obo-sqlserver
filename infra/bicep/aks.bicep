// Primary AKS/Istio deployment. Private data-plane bootstrap runs in src/operations.
// See docs/deploy.md for application federation and workload publication.
targetScope = 'resourceGroup'

param location string = resourceGroup().location
@maxLength(8)
param workloadName string = 'obosql'
param kubernetesVersion string = '1.35.8'
param istioRevision string = 'asm-1-30'
@description('Approved operator egress IPv4 CIDRs; never infer a wider range from observed addresses.')
@minLength(1)
param operatorCidrs array
param operatorObjectId string
param sqlAdminLogin string
param bffPrincipalId string
param cryptoUserObjectIds array = []
@description('Single node is for a disposable PoC, not HA.')
@minValue(1)
param nodeCount int = 1
param vmSize string = 'Standard_D4s_v5'

var suffix = uniqueString(resourceGroup().id)
var name = '${workloadName}-${suffix}'
var tags = { workload: 'obo-sqlserver', environment: 'poc' }

resource network 'Microsoft.Network/virtualNetworks@2026-05-01' = {
  name: 'vnet-${workloadName}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.72.0.0/16'] }
    subnets: [
      { name: 'nodes', properties: { addressPrefix: '10.72.0.0/22' } }
      { name: 'private-endpoints', properties: { addressPrefix: '10.72.4.0/24', privateEndpointNetworkPolicies: 'Disabled' } }
    ]
  }
}
resource ingressIp 'Microsoft.Network/publicIPAddresses@2026-05-01' = {
  name: 'pip-${workloadName}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: { domainNameLabel: name }
  }
}
resource controlIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-${workloadName}-aks'
  location: location
  tags: tags
}
resource kubeletIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-${workloadName}-kubelet'
  location: location
  tags: tags
}
resource operationsIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-${workloadName}-operations'
  location: location
  tags: tags
}
resource networkRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(network.id, controlIdentity.id, 'network')
  scope: network
  properties: {
    principalId: controlIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
  }
}
resource publicIpRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ingressIp.id, controlIdentity.id, 'network')
  scope: ingressIp
  properties: {
    principalId: controlIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
  }
}
resource kubeletRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kubeletIdentity.id, controlIdentity.id, 'operator')
  scope: kubeletIdentity
  properties: {
    principalId: controlIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'f1a07417-d97a-45cb-824c-7a7467783830')
  }
}
resource registry 'Microsoft.ContainerRegistry/registries@2025-11-01' = {
  name: 'cr${workloadName}${suffix}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false, anonymousPullEnabled: false }
}
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, kubeletIdentity.id, 'pull')
  scope: registry
  properties: {
    principalId: kubeletIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}
resource cluster 'Microsoft.ContainerService/managedClusters@2026-06-01' = {
  name: 'aks-${workloadName}'
  location: location
  tags: tags
  sku: { name: 'Base', tier: 'Free' }
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${controlIdentity.id}': {} } }
  properties: {
    dnsPrefix: name
    kubernetesVersion: kubernetesVersion
    disableLocalAccounts: true
    enableRBAC: true
    aadProfile: { managed: true, enableAzureRBAC: true, tenantID: tenant().tenantId }
    apiServerAccessProfile: { authorizedIPRanges: operatorCidrs }
    oidcIssuerProfile: { enabled: true }
    securityProfile: { workloadIdentity: { enabled: true } }
    identityProfile: {
      kubeletidentity: {
        resourceId: kubeletIdentity.id
        clientId: kubeletIdentity.properties.clientId
        objectId: kubeletIdentity.properties.principalId
      }
    }
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        count: nodeCount
        vmSize: vmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: '${network.id}/subnets/nodes'
        maxPods: 50
        upgradeSettings: { maxSurge: '1' }
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: 'cilium'
      networkDataplane: 'cilium'
      podCidr: '10.244.0.0/16'
      serviceCidr: '10.73.0.0/16'
      dnsServiceIP: '10.73.0.10'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
    }
    serviceMeshProfile: {
      mode: 'Istio'
      istio: {
        revisions: [istioRevision]
        components: { ingressGateways: [{ enabled: true, mode: 'External' }] }
      }
    }
  }
  dependsOn: [networkRole, publicIpRole, kubeletRole]
}
resource clusterAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cluster.id, operatorObjectId, 'cluster-admin')
  scope: cluster
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')
  }
}
resource operationsFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: operationsIdentity
  name: 'aks-operations'
  properties: {
    issuer: cluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:obo-operations:operations'
    audiences: ['api://AzureADTokenExchange']
  }
}
resource storage 'Microsoft.Storage/storageAccounts@2026-06-01' = {
  name: 'st${workloadName}${suffix}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
  }
}
resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2026-06-01' = {
  parent: storage
  name: 'default'
  properties: { deleteRetentionPolicy: { enabled: true, days: 7 } }
}
resource spa 'Microsoft.Storage/storageAccounts/blobServices/containers@2026-06-01' = {
  parent: blobs
  name: 'spa'
  properties: { publicAccess: 'None' }
}
resource blobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(spa.id, bffPrincipalId, 'reader')
  scope: spa
  properties: {
    principalId: bffPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
  }
}
resource blobPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(spa.id, operationsIdentity.id, 'publisher')
  scope: spa
  properties: {
    principalId: operationsIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}
resource vault 'Microsoft.KeyVault/vaults@2026-05-15' = {
  name: take('kv-${name}', 24)
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
  }
}
resource keySetupRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, operationsIdentity.id, 'crypto-officer')
  scope: vault
  properties: {
    principalId: operationsIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '14b46e9e-c2b7-41b4-b07b-48a6ebf60603')
  }
}
resource userCryptoRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for userId in cryptoUserObjectIds: {
  name: guid(vault.id, userId, 'crypto')
  scope: vault
  properties: {
    principalId: userId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '12338af0-0e69-4776-bea7-57ae8d297424')
  }
}]
resource sql 'Microsoft.Sql/servers@2025-01-01' = {
  name: 'sql-${name}'
  location: location
  tags: tags
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'User'
      login: sqlAdminLogin
      sid: operatorObjectId
      tenantId: tenant().tenantId
      azureADOnlyAuthentication: true
    }
  }
}
resource database 'Microsoft.Sql/servers/databases@2025-01-01' = {
  parent: sql
  name: 'documents'
  location: location
  tags: tags
  sku: { name: 'Basic', tier: 'Basic', capacity: 5 }
  properties: { maxSizeBytes: 2147483648 }
}
var endpoints = [
  { name: 'pe-blob', resourceId: storage.id, groupId: 'blob', zone: 'privatelink.blob.core.windows.net' }
  { name: 'pe-sql', resourceId: sql.id, groupId: 'sqlServer', zone: 'privatelink.database.windows.net' }
  { name: 'pe-vault', resourceId: vault.id, groupId: 'vault', zone: 'privatelink.vaultcore.azure.net' }
]
module privateEndpoints 'private-endpoint.bicep' = [for item in endpoints: {
  name: item.name
  params: {
    name: item.name
    location: location
    resourceId: item.resourceId
    groupId: item.groupId
    zoneName: item.zone
    subnetId: '${network.id}/subnets/private-endpoints'
    vnetId: network.id
  }
}]

output clusterName string = cluster.name
output oidcIssuer string = cluster.properties.oidcIssuerProfile.issuerURL
output registryName string = registry.name
output registryHost string = registry.properties.loginServer
output publicIpName string = ingressIp.name
output publicIp string = ingressIp.properties.ipAddress
output publicHost string = ingressIp.properties.dnsSettings.fqdn
output storageAccount string = storage.name
output blobContainerUrl string = '${storage.properties.primaryEndpoints.blob}spa'
output sqlFqdn string = sql.properties.fullyQualifiedDomainName
output databaseName string = database.name
output keyVaultName string = vault.name
output keyVaultKeyUrl string = '${vault.properties.vaultUri}keys/cmk-documents'
output operationsClientId string = operationsIdentity.properties.clientId
output operationsObjectId string = operationsIdentity.properties.principalId
output workloadName string = workloadName
