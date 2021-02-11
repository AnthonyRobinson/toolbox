class azureResourcesRecord {
    [string]$key
    [string]$subscriptionId
    [string]$subscriptionName
    [string]$resourceGroupId
    [string]$resourceGroupName
    [string]$resourceId
    [string]$resourceKind
    [string]$resourceType
    [string]$resourceXmlType
    [string]$resourceName
    [string]$resourceFriendlyName
    [string]$resourceLocation
    [string]$resourceGroupDetail
    [string]$resourceDetail
}

$resourceTypeHash = [ordered]@{
    "Resource Group"                  = "Resource Group", "alm.res-grp"
    "Integration Account"             = "Microsoft.Logic/integrationAccounts", "alm.int-acc"
    "Service Bus Namespace"           = "Microsoft.ServiceBus/namespaces", "alm.svc-bus"
    "Authorization Rule"              = "", "alm.svc-bus-auth-rule"
    "Topic"                           = "", "alm.topic"
    "Topic Subscription"              = "", "alm.topic-sub"
    "Topic Subscription Rule"         = "", "alm.topic-sub-rule"
    "Queue"                           = "", "alm.queue"
    "App Service Plan"                = "Microsoft.Web/serverfarms", "alm.app-svcpln"
    "Storage account"                 = "Microsoft.Storage/storageAccounts", "alm.sto-acc"
    "Storage account Container"       = "", "alm.sto-acc-con"
    "Storage account Table"           = "", "alm.sto-acc-tab"
    "Key Vault"                       = "Microsoft.KeyVault/vaults", "alm.kv-secret"
    "Application Insights"            = "microsoft.insights/components", "alm.app-ins"
    "App Service"                     = "Microsoft.Web/sites", "alm.fnc-app"
    "Web App"                         = "Microsoft.Web/sites", "alm.web-app"
    "Logic App"                       = "Microsoft.Logic/workflows", "alm.lgc-app"
    "Map"                             = "", "alm.xslt"
    "Schema"                          = "", "alm.xsd"
    "API Connection"                  = "Microsoft.Web/connections", "alm.unknown"
    "SQL server"                      = "Microsoft.Sql/servers", "alm.sql-svr"
    "SQL database"                    = "Microsoft.Sql/servers/databases", "alm.sql-db"
    "Integration Service Environment" = "Microsoft.Logic/integrationServiceEnvironments", "alm.unknown"
    "Virtual network"                 = "Microsoft.Network/virtualNetworks", "alm.unknown"
    "Unknown"                         = "microsoft.alertsManagement/smartDetectorAlertRules", "alm.unknown"
    "Autoscale Settings"              = "Microsoft.Insights/autoscaleSettings", "alm.autoscale"
    "Autoscale Settings Rule"         = "", "alm.autoscale"
}

function convertAzTypeToXmlTypeName($azureType) {
    foreach ($type in $resourceTypeHash.GetEnumerator()) {
        $tmpAzureType = $type.Value[0]
        $tmpXmlTypeName = $type.Value[1]
        if ($azureType -like $tmpAzureType) {
            return $tmpXmlTypeName
            break
        }
    }
    return $null
}

function convertAzTypeToFriendlyName($azureType) {
    foreach ($type in $resourceTypeHash.GetEnumerator()) {
        $tmpFriendlyName = $type.Key
        $tmpAzureType = $type.Value[0]
        if ($azureType -like $tmpAzureType) {
            if ($tmpFriendlyName = $type.Key) {
                return $tmpFriendlyName
                break
            }
            else {
                return $azureType
                break
            }
        }
    }
    return $azureType
}

function deletePreviousData {
    Write-Host "Deleting previous ES data..."

    $esStringBuilder = New-Object System.Text.StringBuilder(4096000)

    while ($true) {
        $esString = @"
{"query": { "match_all" : {}}}

"@
        $ids = (Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/$($strElasticSearchIndex)/_search?size=1000 -Method POST -Body $esString -ContentType "application/json").hits.hits._id
        if ($ids) {
            foreach ($id in $ids) {
                $esString = @"
{"delete": {"_index": "$($strElasticSearchIndex)","_type": "_doc","_id": "$($id)"}}

"@
                $null = $esStringBuilder.Append($esString)
            }
            if ($esStringBuilder.length) {
                $null = Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esStringBuilder.ToString() -ContentType "application/json"
                $esStringBuilder = $null
                $esStringBuilder = New-Object System.Text.StringBuilder(4096000)
            }
        }
        else {
            break
        }
    }
    if ($esStringBuilder.length) {
        $null = Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esStringBuilder.ToString() -ContentType "application/json"
        $esStringBuilder = $null
        $esStringBuilder = New-Object System.Text.StringBuilder(4096000)
    }
}

function uploadData {
    Write-Host "   Uploading data to $($strElasticSearchServer)..."

    $esStringBuilder = New-Object System.Text.StringBuilder(4096000)

    foreach ($line in $azureTable) {
        $esString = ""
        $tmpString = @"
{
    "create": {
        "_index": "$($strElasticSearchIndex)",
        "_type": "_doc",
        "_id": "$($line.key)"
    }
}
"@
        $esString += $tmpString | ConvertFrom-Json | ConvertTo-Json -Compress
        $esString += "`n"
        $tmpString = @"
{
    "key" : "$($line.key)",
    "subscriptionId" : "$($line.subscriptionId)",
    "subscriptionName" : "$($line.subscriptionName)",
    "resourceGroupId" : "$($line.resourceGroupId)",
    "resourceGroupName" : "$($line.resourceGroupName)",
    "resourceId" : "$($line.resourceId)",
    "resourceKind" : "$($line.resourceKind)",
    "resourceType" : "$($line.resourceType)",
    "resourceXmlType" : "$($line.resourceXmlType)",
    "resourceName" : "$($line.resourceName)",
    "resourceFriendlyName" : "$($line.resourceFriendlyName)",
    "resourceLocation" : "$($line.resourceLocation)",
    "captureTime" : "$($captureTime)"
}
"@
        $esString += $tmpString | ConvertFrom-Json | ConvertTo-Json -Compress
        $esString += "`n"

        $null = $esStringBuilder.Append($esString)
    }

    $tmp = Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esStringBuilder.ToString() -ContentType "application/json"
    Write-Host "      $($tmp.items.count) items written"
    $esStringBuilder = $null
    $azureTable = $null
    $azureTable = [System.Collections.ArrayList]@()
}

function getAndUploadData {
    Write-Host "Getting data from Azure..."
    foreach ($subscription in ((az.cmd account list | ConvertFrom-Json))) {
        Write-Host "   Subscription: $($subscription.name)..."
        try {
            az.cmd account set --subscription $subscription.name
        }
        catch {
            Write-Warning "issues with az.cmd account set --subscription $subscription.name"
            continue
        }

        try {
            $resourceGroups = (az.cmd group list --subscription $subscription.name | ConvertFrom-Json)
        }
        catch {
            Write-Warning "issues with az.cmd group list --subscription $subscription.name"
            $resourceGroups = ""
        }

        foreach ($resourceGroup in $resourceGroups) {
            $resourceGroupDetail = az.cmd group show --name $resourceGroup.name --subscription $subscription.name | ConvertFrom-Json
            Write-Host "      Resource Group: $($resourceGroup.name)..."
            try {
                $resources = (az.cmd resource list --resource-group $resourceGroup.name --subscription $subscription.name | ConvertFrom-Json)
            }
            catch {
                Write-Warning "issues with az.cmd resource list --resource-group $resourceGroup.name --subscription $subscription.name"
                $resources = ""
            }
            foreach ($resource in $resources) {
                # write-host "         Resource: $($resource.name)"

                $azureObject = New-Object azureResourcesRecord

                $azureObject.key = $subscription.id + "_" + $resourceGroup.id + "_" + $resource.id
                $azureObject.subscriptionId = $subscription.id
                $azureObject.subscriptionName = $subscription.name
                $azureObject.resourceGroupId = $resourceGroup.id
                $azureObject.resourceGroupName = $resourceGroup.name
                $azureObject.resourceId = $resource.id
                $azureObject.resourceKind = $resource.kind
                $azureObject.resourceType = $resource.type
                $azureObject.resourceXmlType = convertAzTypeToXmlTypeName $resource.type
                $azureObject.resourceFriendlyName = convertAzTypeToFriendlyName $resource.type
                $azureObject.resourceName = $resource.name
                $azureObject.resourceLocation = $resource.location
                #$azureObject.resourceGroupDetail = $resourceGroupDetail | convertto-json -depth 100
                #$azureObject.resourceDetail = $resource | convertto-json -depth 100

                $null = $azureTable.Add($azureObject)
            }
        }
        uploadData
    }
}


$captureTime = ((Get-Date).toUniversalTime().toString("MM/dd/yyyy HH:mm:ss"))
# $strElasticSearchServer = "LT-14763.corp.sanmar.com"
$strElasticSearchServer = "52.158.250.123"
$strElasticSearchIndex = "azureresources"
$azureTable = $null
$azureTable = [System.Collections.ArrayList]@()

deletePreviousData
getAndUploadData
