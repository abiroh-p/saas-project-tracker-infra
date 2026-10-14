
param location string = 'centralindia'
param environmentName string = 'cae-ptracker-wp'
param logAnalyticsWorkspaceName string = 'log-ptracker'

resource log 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource env 'Microsoft.App/managedEnvironments@2026-03-02-preview' = {
  name: environmentName
  location: location
  properties: {
    environmentMode: 'WorkloadProfiles'
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: log.properties.customerId
        sharedKey: log.listKeys().primarySharedKey
      }
    }
  }
}

output environmentName string = env.name
output environmentId string = env.id
