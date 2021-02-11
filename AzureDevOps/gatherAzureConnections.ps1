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

    "SQL database"          = "Microsoft.Sql/servers/databases", "alm.unknown"
    "Service Bus Namespace" = "Microsoft.ServiceBus/namespaces", "alm.svc-bus"
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
    # write-host "   Uploading data to $($strElasticSearchServer)..."

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
    # write-host "      $($tmp.items.count) items written"
    $esStringBuilder = $null
    $azureTable = $null
    $azureTable = [System.Collections.ArrayList]@()
}

function getAndUploadData {
    Write-Host "Getting data from Azure..."
    #    foreach ($subscriptionName in (az.cmd account list | convertfrom-json).name) {
    foreach ($subscriptionName in "SanMar Development") {
        Write-Host "   Subscription: $($subscriptionName)..."
        if (!(Test-Path "c:\tmp\json\$($subscriptionName)")) {
            mkdir "c:\tmp\json\$($subscriptionName)"
        }
        $null = az.cmd account set --subscription $subscriptionName
        foreach ($resourceGroup in (az.cmd group list --subscription $subscriptionName | ConvertFrom-Json)) {
            Write-Host "      Resource Group: $($resourceGroup.name)..."
            foreach ($type in $resourceTypeHash.GetEnumerator()) {
                $tmpAzureType = $type.Value[0]
                Write-Host "         Type: $($tmpAzureType)..."
                foreach ($resource in (az resource list --resource-type $tmpAzureType --resource-group $resourceGroup.name | ConvertFrom-Json)) {
                    Write-Host "            Resource Name: $($resource.name)..."

                    if ($tmpAzureType -like "Microsoft.ServiceBus/namespaces") {
                        $azCLI = "servicebus", "namespace", "authorization-rule", "keys", "list",
                        "--resource-group", "$($resourceGroup.name)",
                        "--namespace-name", "$($resource.name)",
                        "--name", "RootManageSharedAccessKey"
                        (az.cmd @azCLI) | Out-File "c:\tmp\json\$($subscriptionName)\$($resource.name).json" -Encoding ascii
                    }

                    if ($tmpAzureType -like "Microsoft.Sql/servers/databases") {
                        foreach ($db in (az resource list --resource-type "Microsoft.Sql/servers/databases" | ConvertFrom-Json)) {
                            $dbServer = $db.name.split('/')[0]
                            $dbName = $db.name.split('/')[1]
                            # az sql db show --resource-group $dbs[0].resourceGroup --name $dbName --server $dbServer
                            foreach ($type in "ado.net", "sqlcmd", "jdbc", "php_pdo", "php", "odbc") {
                                az sql db show-connection-string --name $dbName --server $dbServer --client $type |
                                    Out-File "c:\tmp\json\$($subscriptionName)\$($dbServer).$($dbName).$($type).json" -Encoding ascii
                            }
                        }
                    }

                    $azureObject = New-Object azureResourcesRecord

                    $azureObject.key = $subscription.id + "_" + $resourceGroup.id + "_" + $resource.id
                    $azureObject.subscriptionId = $subscription.id
                    $azureObject.subscriptionName = $subscriptionName
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
        }
        # uploadData
    }
}


$captureTime = ((Get-Date).toUniversalTime().toString("MM/dd/yyyy HH:mm:ss"))
# $strElasticSearchServer = "LT-14763.corp.sanmar.com"
$strElasticSearchServer = "52.158.250.123"
$strElasticSearchIndex = "azureresources"
$azureTable = $null
$azureTable = [System.Collections.ArrayList]@()

# deletePreviousData
getAndUploadData
