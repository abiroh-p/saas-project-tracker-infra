targetScope = 'resourceGroup'

@description('Azure region')
param location string = 'centralindia'

@description('Application name')
param appName string = 'ptracker'

@secure()
param dbAdminPassword string

@secure()
param djangoSecretKey string

@description('Database administrator username')
param dbAdminUser string = 'ptadmin'

@description('Application database name')
param dbName string = 'project_tracker'

@description('API image tag')
param apiImageTag string

@description('Frontend image tag')
param webImageTag string

param apiMinReplicas int = 1
param webMinReplicas int = 0
param maxReplicas int = 2

var suffix = uniqueString(resourceGroup().id)
var acrName = '${appName}${suffix}'
var pgName = '${appName}-pg-${suffix}'
var environmentName = 'cae-${appName}-wp'
var tags = {
  project: 'saas-project-tracker'
  environment: 'prod'
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' existing = {
  name: pgName
}

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: 'id-${appName}'
}

resource env 'Microsoft.App/managedEnvironments@2026-03-02-preview' existing = {
  name: environmentName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: 'appi-${appName}'
}

var apiImage = '${acr.properties.loginServer}/api:${apiImageTag}'
var webImage = '${acr.properties.loginServer}/web:${webImageTag}'

var webFqdn = 'web.${env.properties.defaultDomain}'

var identityBlock = {
  type: 'UserAssigned'
  userAssignedIdentities: {
    '${appIdentity.id}': {}
  }
}

var registries = [
  {
    server: acr.properties.loginServer
    identity: appIdentity.id
  }
]

var apiSecrets = [
  {
    name: 'django-secret-key'
    value: djangoSecretKey
  }
  {
    name: 'db-password'
    value: dbAdminPassword
  }
]

var apiEnv = [
  { name: 'DJANGO_SECRET_KEY', secretRef: 'django-secret-key' }
  { name: 'DB_PASSWORD', secretRef: 'db-password' }
  { name: 'DB_HOST', value: pg.properties.fullyQualifiedDomainName }
  { name: 'DB_NAME', value: dbName }
  { name: 'DB_USER', value: dbAdminUser }
  { name: 'DB_SSLMODE', value: 'require' }
  { name: 'DJANGO_ALLOWED_HOSTS', value: 'api,.azurecontainerapps.io' }
  { name: 'DJANGO_CSRF_TRUSTED_ORIGINS', value: 'https://${webFqdn}' }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
]

resource api 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'api'
  location: location
  tags: tags
  identity: identityBlock
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
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

resource web 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'web'
  location: location
  tags: tags
  identity: identityBlock
  dependsOn: [api]
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

resource migrate 'Microsoft.App/jobs@2024-03-01' = {
  name: 'migrate'
  location: location
  tags: tags
  identity: identityBlock
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
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: apiEnv
        }
      ]
    }
  }
}

output webUrl string = 'https://${web.properties.configuration.ingress.fqdn}'
output apiImage string = apiImage
output webImage string = webImage
output environmentName string = env.name
