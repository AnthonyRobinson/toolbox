function invoke-almAzCLI ([PSCustomObject] $azclidata) {
    $azcliargs = $($azclidata.azcli)
    $azCmdLog = "az.cmd $azcliargs"
    $almAzCLIModuleOut = [PSCustomObject]@{
        stdout = $null
        stderr = $null
    }
    $allOutput = az.cmd @azCLIArgs 2>&1
    $stderr = $allOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
    $stdout = $allOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    if ($stderr) {
        $almAzCLIModuleOut.stderr = $stderr
    }
    if ($stdout) {
        try {
            $stdoutTmp = ($stdout | ConvertFrom-Json | ConvertTo-Json -Compress)
        }
        catch {
            $stdoutTmp = $stdout
        }
        $almAzCLIModuleOut.stdout = $stdout
    }
    return $almAzCLIModuleOut
}

function get-ResourceInfo {
    Param(
        [parameter(mandatory = $true)]
        [Object] $ALMAzureData
    )
    if (!($global:resourceInfoHash)) {
        $global:resourceInfoHash = @{ }
    }
    $azCLIargs = "resource", "list"
    $azCLiData = invoke-almAzCLI ([PSCustomObject]@{azcli = $azCLIargs })
    $stdOut = "$($azCLiData.stdout)"
    $stdErr = "$($azCLiData.stderr)"
    $resources = ($stdOut | ConvertFrom-Json) | Where-Object { $_.resourcegroup -like "*$($ALMAzureData.locationShort)*" -and $_.resourcegroup -like "*$($ALMAzureData.environment)*" }
    foreach ($resource in $resources) {
        if (!($global:resourceInfoHash.ContainsKey($resource.name))) {
            $null = $global:resourceInfoHash.add($resource.name, $resource)
        }
    }
    return $global:resourceInfoHash
}

function show-ConnectionStrings {
    Param(
        [parameter(mandatory = $true)]
        [Object] $ALMAzureData
    )
    $null = get-ResourceInfo $ALMAzureData
    Write-Host ""
    Write-Host "* Connection Strings for this deployment"
    show-ServiceBusConnectionStrings
    show-SqlServerConnectionStrings
}

function show-ServiceBusConnectionStrings {
    foreach ($serviceBus in ($global:resourceInfoHash.GetEnumerator() | Where-Object { $_.value.type -like "*Microsoft.ServiceBus/namespaces*" })) {
        Write-Host ""
        Write-Host "** Service Bus: $($serviceBus.value.name)"
        $azCLIargs = "servicebus", "namespace", "authorization-rule", "keys", "list",
        "--resource-group", "$($serviceBus.value.resourceGroup)",
        "--namespace-name", "$($serviceBus.value.name)",
        "--name", "RootManageSharedAccessKey",
        "--output", "json"
        $azCLiData = invoke-almAzCLI ([PSCustomObject]@{azcli = $azCLIargs })
        $stdOut = "$($azCLiData.stdout)"
        $stdErr = "$($azCLiData.stderr)"
        $stdOut | ConvertFrom-Json | ConvertTo-Json -Depth 5
    }
}

function show-SqlServerConnectionStrings {
    foreach ($database in ($global:resourceInfoHash.GetEnumerator() | Where-Object { $_.value.type -like "*Microsoft.Sql/servers/databases*" })) {
        $dbServer = $database.name.split('/')[0]
        $dbName = $database.name.split('/')[1]
        foreach ($type in "ado.net", "sqlcmd", "jdbc", "php_pdo", "php", "odbc") {
            Write-Host ""
            Write-Host "** SQL Server Database: $($dbServer) $($dbName) - Type $($type)"
            $azCLIargs = "sql", "db", "show-connection-string",
            "--name", "$dbName",
            "--server", "$dbServer",
            "--client", "$type",
            "--output", "json"
            $azCLiData = invoke-almAzCLI ([PSCustomObject]@{azcli = $azCLIargs })
            $stdOut = "$($azCLiData.stdout)"
            $stdErr = "$($azCLiData.stderr)"
            $stdOut | ConvertFrom-Json | ConvertTo-Json -Depth 5
        }
    }
}

#===============================================================================================================

$appId = "$($ENV:appId)"
$key = "$($ENV:key)"
$tenantId = "$($ENV:tenantId)"
$environment = "$($ENV:environment)"
$subscription = "$($ENV:subscription)"

$appId
$key
$tenantId
$environment
$subscription

$ALMAzureDataJson = @"
{
    "SubscriptionName":  "$($subscription)",
    "Environment":  "$($environment)",
    "Location":  "westus2",
    "LocationShort":  "wus2",
    "LocationLong":  "westus2",
    "SkuName":  "Standard_LRS",
    "PricingTier":  "Standard",
    "Kind":  "StorageV2",
    "Debug":  null
}
"@

$ALMAzureData = ($ALMAzureDataJson | ConvertFrom-Json)

Write-Host "Logging into Azure..."

$azCLIargs = "login",
"--service-principal",
"--username", "$appId",
"--password", "$key",
"--tenant", "$tenantId"
$azCLiData = invoke-almAzCLI ([PSCustomObject]@{azcli = $azCLIargs })

$azCLIargs = "account", "set",
"--subscription", "$subscription"
$azCLiData = invoke-almAzCLI ([PSCustomObject]@{azcli = $azCLIargs })

show-ConnectionStrings $ALMAzureData
