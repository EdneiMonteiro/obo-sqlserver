// Optional validation only. Never deployed by the functional installation.
targetScope = 'resourceGroup'

param location string = resourceGroup().location
@maxLength(8)
param workloadName string = 'obosql'
param clusterName string
param keyVaultName string

resource cluster 'Microsoft.ContainerService/managedClusters@2026-06-01' existing = { name: clusterName }
resource vault 'Microsoft.KeyVault/vaults@2026-05-15' existing = { name: keyVaultName }
var actors = ['sender', 'reader', 'admin-with-key', 'admin-without-key']
resource identities 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = [for actor in actors: {
  name: 'id-${workloadName}-test-${actor}'
  location: location
  tags: { workload: 'obo-sqlserver', purpose: 'optional-validation' }
}]
resource federations 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = [for (actor, i) in actors: {
  parent: identities[i]
  name: 'aks-test'
  properties: {
    issuer: cluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:obo-operations:test-${actor}'
    audiences: ['api://AzureADTokenExchange']
  }
}]
resource cryptoRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (actor, i) in actors: if (actor != 'admin-without-key') {
  name: guid(vault.id, identities[i].id, 'crypto')
  scope: vault
  properties: {
    principalId: identities[i].properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '12338af0-0e69-4776-bea7-57ae8d297424')
  }
}]
output identities array = [for (actor, i) in actors: {
  actor: actor
  clientId: identities[i].properties.clientId
  objectId: identities[i].properties.principalId
  resourceId: identities[i].id
  cryptoRoleId: actor == 'admin-without-key' ? '' : '${vault.id}/providers/Microsoft.Authorization/roleAssignments/${guid(vault.id, identities[i].id, 'crypto')}'
}]
