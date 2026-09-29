param location string
param name string
param resourceId string
param groupId string
param zoneName string
param subnetId string
param vnetId string

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  location: 'global'
}
resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: 'aks'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}
resource endpoint 'Microsoft.Network/privateEndpoints@2026-05-01' = {
  name: name
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: resourceId
          groupIds: [groupId]
        }
      }
    ]
  }
}
resource dns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2026-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [{ name: 'default', properties: { privateDnsZoneId: zone.id } }]
  }
}
