// critical alerting - pilot infrastructure.
// Deploys: Log Analytics, App Insights, Storage, Function App (consumption, Python 3.11),
// Event Hubs namespace + hub, Action Group (email + SMS + voice + Teams webhook),
// and a scheduled query alert rule that fires on Sev1 normalized events.
//
// Scope: resourceGroup
// Run:   az deployment group create -g <rg> -f infra/main.bicep -p @infra/main.parameters.json

targetScope = 'resourceGroup'

@description('Short prefix used to build resource names. Lowercase, 3-10 chars.')
@minLength(3)
@maxLength(10)
param namePrefix string = 'oncall'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('On-call primary email recipient for the Action Group.')
param oncallEmail string

@description('On-call primary phone country code (digits only, e.g. 1 for US).')
param oncallPhoneCountryCode string = '1'

@description('On-call primary phone number (digits only, no spaces or dashes).')
param oncallPhoneNumber string

@description('Optional Teams Incoming Webhook URL. Leave blank to skip the Teams action.')
@secure()
param teamsWebhookUrl string = ''

@description('Log Analytics daily ingestion cap in GB. Controls cost. Default 1 GB / day.')
param logAnalyticsDailyCapGb int = 1

@description('Tags applied to every resource.')
param tags object = {
  workload: 'critical-alerting'
  owner: 'Production-Support'
  costCenter: 'production-support'
}

var suffix = uniqueString(resourceGroup().id, namePrefix)
var lawName = '${namePrefix}-law-${suffix}'
var appiName = '${namePrefix}-appi-${suffix}'
var storageName = toLower('${namePrefix}st${substring(suffix, 0, 8)}')
var planName = '${namePrefix}-plan-${suffix}'
var funcName = '${namePrefix}-func-${suffix}'
var ehNsName = '${namePrefix}-ehns-${suffix}'
var ehName = 'critical-alerts'
var actionGroupName = '${namePrefix}-ag-sev1'
var alertRuleName = '${namePrefix}-ar-sev1-critical'

// ----- Log Analytics workspace (alert signal store + audit trail) -----
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    workspaceCapping: {
      dailyQuotaGb: logAnalyticsDailyCapGb
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// ----- Application Insights (function telemetry) -----
resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: appiName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ----- Storage account (function backing store) -----
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

// ----- Event Hubs namespace + hub (intake for app/scheduler events) -----
resource ehNs 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: ehNsName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    isAutoInflateEnabled: false
    zoneRedundant: true
  }
}

resource eh 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: ehNs
  name: ehName
  properties: {
    partitionCount: 2
    messageRetentionInDays: 1
  }
}

resource ehSendListenRule 'Microsoft.EventHub/namespaces/eventhubs/authorizationRules@2024-01-01' = {
  parent: eh
  name: 'function-sendlisten'
  properties: {
    rights: [
      'Send'
      'Listen'
    ]
  }
}

// ----- Consumption hosting plan -----
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true
  }
}

// ----- Function App (Python 3.11) -----
resource func 'Microsoft.Web/sites@2023-12-01' = {
  name: funcName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appi.properties.ConnectionString
        }
        {
          name: 'EVENTHUB_NAME'
          value: ehName
        }
        {
          name: 'EVENTHUB_CONNECTION'
          value: ehSendListenRule.listKeys().primaryConnectionString
        }
        {
          name: 'LAW_WORKSPACE_ID'
          value: law.properties.customerId
        }
      ]
    }
  }
}

// ----- Action Group (SMS + voice + email + optional Teams webhook) -----
resource actionGroup 'Microsoft.Insights/actionGroups@2024-10-01-preview' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'ONCALL'
    enabled: true
    emailReceivers: [
      {
        name: 'oncall-email'
        emailAddress: oncallEmail
        useCommonAlertSchema: true
      }
    ]
    smsReceivers: [
      {
        name: 'oncall-sms'
        countryCode: oncallPhoneCountryCode
        phoneNumber: oncallPhoneNumber
      }
    ]
    voiceReceivers: [
      {
        name: 'oncall-voice'
        countryCode: oncallPhoneCountryCode
        phoneNumber: oncallPhoneNumber
      }
    ]
    azureAppPushReceivers: [
      {
        name: 'oncall-push'
        emailAddress: oncallEmail
      }
    ]
    webhookReceivers: empty(teamsWebhookUrl) ? [] : [
      {
        name: 'teams-channel'
        serviceUri: teamsWebhookUrl
        useCommonAlertSchema: true
      }
    ]
  }
}

// ----- Scheduled query alert rule on AlertEvents_CL -----
resource alertRule 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: alertRuleName
  location: location
  tags: tags
  properties: {
    displayName: 'the customer Sev1 critical alert'
    description: 'Fires when a normalized Sev1 alert event is ingested into AlertEvents_CL. Routes to the on-call Action Group for SMS + voice + email + push.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [
      law.id
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    criteria: {
      allOf: [
        {
          query: 'AlertEvents_CL | where TimeGenerated > ago(5m) | where Severity_s == "Sev1" | summarize Count=count() by DedupeKey_s, Application_s, Summary_s'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
      customProperties: {
        runbook: 'https://example.com/runbooks/on-call'
      }
    }
  }
}

// ----- Outputs -----
output resourceGroupName string = resourceGroup().name
output logAnalyticsWorkspaceId string = law.properties.customerId
output logAnalyticsResourceId string = law.id
output applicationInsightsConnectionString string = appi.properties.ConnectionString
output functionAppName string = func.name
output functionAppDefaultHostName string = func.properties.defaultHostName
output eventHubNamespace string = ehNs.name
output eventHubName string = eh.name
output eventHubConnectionStringSecretName string = ehSendListenRule.name
output actionGroupResourceId string = actionGroup.id
output alertRuleResourceId string = alertRule.id
