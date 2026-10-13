// SaaS Project Tracker - Azure infrastructure (resource-group scope).
//
// Two-phase deploy (see README):
//   phase 1  deployApps=false  platform only: logs, App Insights, registry, Postgres, Container Apps environment
//   phase 2  deployApps=true   web + api apps and the migration job, once images exist in the registry

targetScope = 'resourceGroup'

@description('Azure region. Use one your student subscription allows (Postgres Flexible Server capacity varies by region).')
param location string = resourceGroup().location

@description('Short lowercase prefix for resource names.')
@minLength(3)
@maxLength(12)
param appName string = 'ptracker'

@description('Tags applied to every resource.')
param tags object = {
  project: 'saas-project-tracker'
  environment: 'prod'
}

@description('PostgreSQL administrator login (not a reserved name such as admin/root).')
param dbAdminUser string = 'ptadmin'

@secure()
@description('PostgreSQL administrator password.')
param dbAdminPassword string

@secure()
@description('Django SECRET_KEY: long, random, unique to this environment.')
param djangoSecretKey string

@description('Application database name.')
param dbName string = 'project_tracker'

@description('false = platform only; true = also deploy the apps and migration job.')
param deployApps bool = false

@description('Image tag of the API image (repository "api") in the registry.')
param apiImageTag string = 'latest'

@description('Image tag of the web image (repository "web") in the registry.')
param webImageTag string = 'latest'

@description('The API must stay warm: it holds the database connections and cold starts hurt.')
param apiMinReplicas int = 1

@description('nginx starts in seconds, so scale-to-zero (0) is fine for a low-traffic student project.')
param webMinReplicas int = 0

param maxReplicas int = 2

@description('Daily ingestion cap for Log Analytics, to protect student credit.')
param logDailyCapGb int = 1

var suffix = uniqueString(resourceGroup().id)
var acrName = '${appName}${suffix}'
var pgName = '${appName}-pg-${suffix}'
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// ---------------------------------------------------------------------------------------------
// Monitoring
// ---------------------------------------------------------------------------------------------
resource log 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${appName}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: logDailyCapGb }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${appName}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: log.id
    IngestionMode: 'LogAnalytics'
  }
}

// ---------------------------------------------------------------------------------------------
// Registry + the identity the apps use to pull from it (no admin user, no passwords)
// ---------------------------------------------------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${appName}'
  location: location
  tags: tags
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  name: guid(acr.id, appIdentity.id, acrPullRoleId)
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
  }
}

// ---------------------------------------------------------------------------------------------
// PostgreSQL Flexible Server (Burstable B1ms). TLS is enforced by the server; Django connects with
// DB_SSLMODE=require. Public access is limited to Azure-internal traffic via the 0.0.0.0 rule.
// ---------------------------------------------------------------------------------------------
resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: pgName
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '16'
    administratorLogin: dbAdminUser
    administratorLoginPassword: dbAdminPassword
    storage: {
      storageSizeGB: 32
      autoGrow: 'Disabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: { mode: 'Disabled' }
    network: { publicNetworkAccess: 'Enabled' }
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
  }
}

resource pgDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: pg
  name: dbName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

resource pgAllowAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: pg
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ---------------------------------------------------------------------------------------------
// Container Apps environment
// ---------------------------------------------------------------------------------------------
resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${appName}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: log.properties.customerId
        sharedKey: log.listKeys().primarySharedKey
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------
// Apps (phase 2)
// ---------------------------------------------------------------------------------------------
var apiImage = '${acr.properties.loginServer}/api:${apiImageTag}'
var webImage = '${acr.properties.loginServer}/web:${webImageTag}'
var webFqdn = 'web.${env.properties.defaultDomain}'

var apiSecrets = [
  { name: 'django-secret-key', value: djangoSecretKey }
  { name: 'db-password', value: dbAdminPassword }
]

var apiEnv = [
  { name: 'DJANGO_SECRET_KEY', secretRef: 'django-secret-key' }
  { name: 'DB_PASSWORD', secretRef: 'db-password' }
  { name: 'DB_HOST', value: pg.properties.fullyQualifiedDomainName }
  { name: 'DB_NAME', value: dbName }
  { name: 'DB_USER', value: dbAdminUser }
  { name: 'DB_SSLMODE', value: 'require' }
  // The web container proxies with Host=api; the wildcard covers the internal FQDN.
  { name: 'DJANGO_ALLOWED_HOSTS', value: 'api,.azurecontainerapps.io' }
  { name: 'DJANGO_CSRF_TRUSTED_ORIGINS', value: 'https://${webFqdn}' }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
]

var identityBlock = {
  type: 'UserAssigned'
  userAssignedIdentities: { '${appIdentity.id}': {} }
}

var registries = [
  {
    server: acr.properties.loginServer
    identity: appIdentity.id
  }
]

resource api 'Microsoft.App/containerApps@2024-03-01' = if (deployApps) {
  name: 'api'
  location: location
  tags: tags
  identity: identityBlock
  dependsOn: [acrPull]
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      // Internal only: reachable by the web app, never from the internet.
      // allowInsecure lets web reach it over plain HTTP inside the environment (verify in README).
      ingress: {
        external: false
        targetPort: 8000
        transport: 'auto'
        allowInsecure: true
      }
      registries: registries
      secrets: apiSecrets
    }
    template: {
      containers: [
        {
          name: 'api'
          image: apiImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: apiEnv
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/api/healthz', port: 8000 }
              initialDelaySeconds: 10
              periodSeconds: 15
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: { path: '/api/readyz', port: 8000 }
              initialDelaySeconds: 5
              periodSeconds: 10
              failureThreshold: 3
            }
          ]
        }
      ]
      scale: {
        minReplicas: apiMinReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-concurrency'
            http: { metadata: { concurrentRequests: '50' } }
          }
        ]
      }
    }
  }
}

resource web 'Microsoft.App/containerApps@2024-03-01' = if (deployApps) {
  name: 'web'
  location: location
  tags: tags
  identity: identityBlock
  dependsOn: [acrPull, api]
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'web'
          image: webImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'API_UPSTREAM', value: 'http://api' }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/healthz', port: 8080 }
              initialDelaySeconds: 5
              periodSeconds: 15
            }
            {
              type: 'Readiness'
              httpGet: { path: '/healthz', port: 8080 }
              initialDelaySeconds: 3
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: webMinReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-concurrency'
            http: { metadata: { concurrentRequests: '100' } }
          }
        ]
      }
    }
  }
}

// One-off job: run before rolling out a new API revision.
//   az containerapp job start -n migrate -g <rg>
resource migrate 'Microsoft.App/jobs@2024-03-01' = if (deployApps) {
  name: 'migrate'
  location: location
  tags: tags
  identity: identityBlock
  dependsOn: [acrPull]
  properties: {
    environmentId: env.id
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 600
      replicaRetryLimit: 0
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
      registries: registries
      secrets: apiSecrets
    }
    template: {
      containers: [
        {
          name: 'migrate'
          image: apiImage
          command: ['sh', '-c']
          args: ['python manage.py migrate --noinput && python manage.py createcachetable']
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: apiEnv
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------------------------
output webUrl string = 'https://${webFqdn}'
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output postgresHost string = pg.properties.fullyQualifiedDomainName
output environmentName string = env.name
output logAnalyticsWorkspaceName string = log.name
output appInsightsName string = appInsights.name
