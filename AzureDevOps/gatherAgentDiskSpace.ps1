<#

	.SYNOPSIS
		Queries Build Agents for their current disk space

	.DESCRIPTION
		Queries VSTS Build Agents for a specific pool, then queries each agent for disk size and free space.
		Percentage free space is calculated. 
		All data is written to ElasticSearch with current query time for time-based analysis.

	.INPUTS
		All params are inferred from the environment.  If not set, some defaults are used.

	.OUTPUTS
		Output is written directly to ElasticSearch

	.NOTES
		Anthony A Robinson 7/2018
		v-antrob@microsoft.com
		https://www.linkedin.com/in/3legdog/

	.LINK
		http://std-5276466:9200/
		http://std-5276466:5601/goto/6a027ba1038ecdc1907d6d79515cee90

#>


param (
    [string]$PATSjson = $null
)


function main {

	$scriptPath = Split-Path $script:MyInvocation.MyCommand.Path
	$scriptPath
	. "$($scriptPath)\gatherIncludes.ps1"

	$progressPreference = 'silentlyContinue'
	$thisRunDateTime = (get-date).ToUniversalTime()

# --- Set some defaults

	if (!($projectUrl = $ENV:SYSTEM_TEAMFOUNDATIONSERVERURI)) {
		$projectUrl = "https://microsoft.visualstudio.com"
	}
	
# --- Override defaults with settings string

	loadConfiguration
	
	# --- override locally
	
	$strSqlTable = $jsonConfiguration.databases.sqlserver.tables.Agent
	$strElasticSearchIndex = $jsonConfiguration.databases.elasticsearch.indexes.Agent

	$personalAccessToken = $ENV:PAT
	$OAuthToken = $ENV:System_AccessToken

	if ($OAuthToken) {
		$headers = @{ Authorization = ("Bearer {0}" -f $OAuthToken) }
	} elseif ($personalAccessToken) {
		$headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($personalAccessToken)")) }
	} else {
		Write-Error "Neither personalAccessToken nor OAuthToken are set"
	}
	
	if (!($minutesBack = $ENV:minutesBack)) {
		try {
			$tmp = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/timestamp/data/$($strElasticSearchIndex)
			$lastRunDateTime = [datetime]([string]$tmp._source.LastRunTime)
			write-host "INFO: last run was at" $lastRunDateTime
			$minutesBack = (new-TimeSpan -start $thisRunDateTime -end $lastRunDateTime).TotalMinutes
		}
		catch {
			$minutesBack = -200
		}
	}
	
	$strStartDate = (get-date).AddMinutes($minutesBack).ToUniversalTime()
	
	write-host "INFO: using minutesBack of" $minutesBack "and strStartDate" $strStartDate
	
	if ($DEBUG) {
		get-variable | format-table Name, Value
	}
	
	listAgentsDiskSpace

	exit 0	
}

function listAgentsDiskSpace {

	$strDateTime = ((get-date).toUniversalTime().toString("MM/dd/yyyy HH:mm:ss"))

	$agentNameTable = @()
	$agentSpaceTable = @{ }

	foreach ($tenant in $jsonConfiguration.tenants.name) {

		write-host "Tenant", $tenant

		$agentsAll = $null
		$poolNameHash = @{ }
		$agentPoolHash = @{ }

		$projectUrl = (Invoke-RestMethod "https://dev.azure.com/_apis/resourceAreas/$($resourceAreaId.Build)?accountName=$($tenant)&api-version=5.0-preview.1").locationUrl

		if ($PAT = ($PATSjson | convertfrom-json).$($tenant)) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)"))}
		} elseif ($PAT = ($ENV:PATSjson | convertfrom-json).$($tenant)) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)"))}
		} elseif ($PAT = ($jsonConfiguration.tenants | where { $_.name -like "$($tenant)" }).PAT) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)"))}
		}
		
		if ($agentPools = ($jsonConfiguration.tenants | where { $_.name -like "$($tenant)" }).agentPools) {
			write-host "Using agentPools from jsonConfiguration"
		}
	
		foreach ($agentPool in $agentPools) {
		
			$agentPoolName = $agentPool.name
		
			write-host "Agent Pool Name", $agentPoolName
		
			foreach ($pool in ((Invoke-RestMethod -Uri $projectUrl/_apis/distributedtask/pools?api-version=4.0 -Headers $headers).value | Where-Object { $_.Name -like "$($agentPoolName)" })) {

				Write-Host "Querying Pool", $pool.Name
				
				$poolNameHash.add($pool.id, $pool.Name)
				
				$tmpAgents = @()

				if ($clientAliases = ($agentPool | where { $_.name -like "$($pool.name)" }).ClientAliases) {	
					foreach ($clientAlias in $clientAliases) {
						Write-Host "Querying clientAlias", $clientAlias
						$tmpAgents += ((Invoke-RestMethod -Uri $projectUrl/_apis/distributedtask/pools/$($pool.id)/agents?api-version=4.0`&includeCapabilities=true -Headers $headers).value | Where-Object { $_.systemCapabilities.ClientAlias -like "$($clientAlias)*" })
					}
				}
				else {
					$tmpAgents = ((Invoke-RestMethod -Uri $projectUrl/_apis/distributedtask/pools/$($pool.id)/agents?api-version=4.0`&includeCapabilities=true -Headers $headers).value )
				}
				
				foreach ($agentId in $tmpAgents.id) {
					$agentPoolHash.add($agentId, $pool.id)
				}
				$agentsAll += $tmpAgents
			}
		}
	
		if ($agentsOnline = ($agentsAll | Where-Object { $_.status -like "online" }).systemCapabilities.'Agent.ComputerName') {
			""
			Write-Host "Agents online:"
			$agentsOnline
		}
	
		if ($agentsToQuery = ($agentsAll | Where-Object { $_.systemCapabilities.'USERNAME' -like "*issblder*" -and $_.status -like "online" }).systemCapabilities.'Agent.ComputerName') {
			""
			Write-Host "Agents to bulk query:"
			$agentsToQuery
		}

		if ($agentsOffline = ($agentsAll | Where-Object { $_.status -like "offline" }).systemCapabilities.'Agent.ComputerName') {
			""
			Write-Host "Agents offline:"
			$agentsOffline
		}

		if ($agentsDisabled = ($agentsAll | Where-Object { $_.enabled -like "False" }).systemCapabilities.'Agent.ComputerName') {
			""
			Write-Host "Agents disabled:"
			$agentsDisabled
		}
	
	
		write-host "Performing bulk query..."
		
		try {
			$diskInfos = invoke-command -computer $agentsToQuery -scriptblock { Get-WmiObject Win32_LogicalDisk -ComputerName localhost -Filter "DeviceID='C:'" }
		}
		catch {
			Write-Warning "Problems getting diskInfos..."
			Write-Host "##vso[task.logissue type=warning;] Problems getting diskInfos..."
			$diskInfos = $null
		}
			

		$data = $null
		$esStringBuilder = New-Object System.Text.StringBuilder(1024000)
	
		foreach ($agent in $agentsAll) {
	
			$poolId = $agentPoolHash.$($agent.id)
			$poolName = $poolNameHash.$($poolId)
			
			#		if ($agent.enabled -like "True" -and $agent.status -like "online") {
			if ($agent.status -like "online") {
		
				$buildAgent = $null
			
				if ($agent.systemCapabilities.'Agent.ComputerName') {
					$buildAgent = $agent.systemCapabilities.'Agent.ComputerName'
				}
				elseif ($agent.name) {
					$buildAgent = $agent.name
				}
			
				if ($buildAgent) {

					write-host "Looking at" $buildAgent
				
					$requests = (Invoke-RestMethod $projectUrl/_apis/distributedtask/pools/$($poolId)/jobrequests?api-version=4.0`&agentId=$($agent.Id)`&completedRequestCount=1000 -Headers $headers).value | `
						where-object { $_."planType" -like "Build" } | `
						where-object { ($_.result -like "failed" -or $_.result -like "succeeded") } | `
						where-object { ($_.owner.name -notlike "OMG.*") }
							
					#			$requests | convertto-json -depth 100
				
					$failCount = ($requests | where-object { $_.result -like "failed" }).count
					$succeedCount = ($requests | where-object { $_.result -like "succeeded" }).count
					if ($failCount + $succeedCount) {
						$pctFailure = [math]::Round((($failCount / ($failCount + $succeedCount)) * 100))
					}
					else {
						$pctFailure = 0
					}
				
					write-host $buildAgent "has a" $pctFailure "% failure rate"
			
					#			$user = $buildAgent + "\dexxadmin"
					#			$passClear = $($buildAgent).substring(0,1) + $($buildAgent).substring(1).toLower()
					#			$pass = ConvertTo-SecureString $passClear -AsPlainText -Force
					#			$cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $user, $pass		
				
					$id = get-random
					$data = $null
				
					try {
						$diskInfo = ($diskInfos | where { $_.PSComputerName -eq $buildAgent } | select FreeSpace, Size)
						write-host "Found disk info for" $buildAgent
						$pct = (($diskInfo.FreeSpace / $diskInfo.Size) * 100)

						$tmpString = @"
{
	"create": {
		"_index": "$($strElasticSearchIndex)",
		"_type": "data",
		"_id": "$id"
	}
}
"@
						$data += $tmpString | convertfrom-json | convertto-json -compress
						$data += "`n"

						$tmpString = @"
{
	"ID": "$id",
	"DateTime": "$($strDateTime)",
	"Tenant": "$($tenant)",
	"BuildAgent": "$($buildAgent.toUpper())",
	"DiskSize": $($diskInfo.Size),
	"DiskFree": $($diskInfo.FreeSpace),
	"DiskFreePct": $($pct),
	"FailureRate": $($pctFailure)
}
"@
						$data += $tmpString | convertfrom-json | convertto-json -compress
						$data += "`n"
						$null = $esStringBuilder.Append($data)
					}
					catch {
						$tmpString = @"
{
	"create": {
		"_index": "$($strElasticSearchIndex)",
		"_type": "data",
		"_id": "$id"
	}
}
"@
						$data += $tmpString | convertfrom-json | convertto-json -compress
						$data += "`n"

						$tmpString = @"
{
	"ID": "$id",
	"DateTime": "$($strDateTime)",
	"Tenant": "$($tenant)",
	"BuildAgent": "$($buildAgent.toUpper())",
	"FailureRate": $($pctFailure)
}
"@
						$data += $tmpString | convertfrom-json | convertto-json -compress
						$data += "`n"
						$null = $esStringBuilder.Append($data)
					}
				}
			}
		}
	
		if ($esStringBuilder.ToString()) {
			invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $($esStringBuilder.ToString()) -ContentType "application/json"
		}

	
	
		$esString = @"
{"delete": {"_index": "timestamp","_type": "data","_id": "$($strElasticSearchIndex)"}}
{"create": {"_index": "timestamp","_type": "data","_id": "$($strElasticSearchIndex)"}}
{"ID": "$($strElasticSearchIndex)","LastRunTime": "$($thisRunDateTime)"}

"@

		try {
			invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
		}
		catch {
			write-host "ERROR: updating LastRunTime"
			$esString
		}
	}
}
	
main
