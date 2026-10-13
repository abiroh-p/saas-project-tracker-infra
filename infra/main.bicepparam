using './main.bicep'

// Secrets come from the shell environment so they never land in git.
param dbAdminPassword = readEnvironmentVariable('DB_ADMIN_PASSWORD')
param djangoSecretKey = readEnvironmentVariable('DJANGO_SECRET_KEY')

param appName = 'ptracker'

// Phase switch and image tags are driven from the environment so CD can reuse this file.
param deployApps = readEnvironmentVariable('DEPLOY_APPS', 'false') == 'true'
param apiImageTag = readEnvironmentVariable('API_IMAGE_TAG', 'latest')
param webImageTag = readEnvironmentVariable('WEB_IMAGE_TAG', 'latest')
