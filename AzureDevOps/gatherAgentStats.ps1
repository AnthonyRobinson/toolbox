<#

	.SYNOPSIS
		Queries VSTS for Build Agent-related info

	.DESCRIPTION
		Queries VSTS for Build Agent-related info from a specific poll name, saving current build activity to ElasticSearch. Previous ElasticSearch records per Build Agent are deleted and no history is retained.  This build agent info is current "now" snapshot only.

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
	
	$strElasticSearchIndex = "buildagents"
	$strSqlTable = $jsonConfiguration.databases.sqlserver.tables.AgentStatic
	$strElasticSearchIndex = $jsonConfiguration.databases.elasticsearch.indexes.AgentStatic
	
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
	
	listAgents

	exit 0

}

function listAgents {

	$strDateTime = ((Get-Date).toUniversalTime().ToString("MM/dd/yyyy HH:mm:ss"))

	$agentInfotable = @()
	$agentInfoBody = $null

	foreach ($tenant in $jsonConfiguration.tenants.name) {

		write-host "Tenant", $tenant
		
		$agentsAll = @()
		$poolNameHash = @{}
		$agentPoolHash = @{}

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
		
		
		""
		Write-Host "Performing bulk queries..."
		
		try {
			Write-Host "Machine PATH..."
			$pathMachines = Invoke-Command -computerName $agentsToQuery -ScriptBlock {([System.Environment]::GetEnvironmentVariable("PATH",'Machine') -split ';' | where {$_ -and (Test-Path $_)}| select-object -unique)}
		}
		catch {
			Write-Warning "Problems getting pathMachines..."
			Write-Host "##vso[task.logissue type=warning;] Problems getting pathMachines..."
			$pathMachines = $null
		}
		
		try {
			Write-Host "User PATH..."
			$pathUsers = Invoke-Command -computerName $agentsToQuery -ScriptBlock {([System.Environment]::GetEnvironmentVariable("PATH",'User') -split ';' | where {$_ -and (Test-Path $_)}| select-object -unique)}
		}
		catch {
			Write-Warning "Problems getting pathUsers..."
			Write-Host "##vso[task.logissue type=warning;] Problems getting pathUsers..."
			$pathUsers = $null
		}

		try {
			Write-Host "Environments..."
			$environments = Invoke-Command -computerName $agentsToQuery -ScriptBlock { Get-ChildItem env: | Select-Object name,value }
		}
		catch {
			Write-Warning "Problems getting environments..."
			Write-Host "##vso[task.logissue type=warning;] Problems getting environments..."
			$environments = $null
		}

		try {
			Write-Host "Disk sizes..."
			$diskSizes = Invoke-Command -computerName $agentsToQuery -ScriptBlock { Get-WmiObject Win32_LogicalDisk -ComputerName localhost -Filter "DeviceID='C:'" }
		}
		catch {
			Write-Warning "Problems getting diskSizes..."
			Write-Host "##vso[task.logissue type=warning;] Problems getting diskSizes..."
			$diskSizes = $null
		}

		try {
			Write-Host "Memory sizes..."
			$memorySizes = Invoke-Command -computerName $agentsToQuery -ScriptBlock { Get-WmiObject Win32_PhysicalMemory -ComputerName localhost }
		}
		catch {
			Write-Warning "Problems getting memorySizes..."
			Write-Host "##vso[task.logissue type=warning;] Problems getting memorySizes..."
			$memorySizes = $null
		}

		try {
			Write-Host "Systeminfo..."
			$systeminfoJsons = Invoke-Command -computerName $agentsToQuery -ScriptBlock {
				(& systeminfo /fo csv) | ConvertFrom-Csv | ConvertTo-Json -Compress -Depth 100
			}
		}
		catch {
			Write-Warning "Problems getting systeminfoJsons..."
			Write-Host "##vso[task.logissue type=warning;] Problems getting systeminfoJsons..."
			$systeminfoJsons = $null
		}
		
	#		try {
	#			Write-Host "PSInfo..."
	#			$PSInfoJsons = Invoke-Command -computerName $agentsToQuery -ScriptBlock {
	#				(& c:\sysInternalsSuite\PSInfo -accepteula -s -nobanner) | ConvertTo-Json -Compress -Depth 100
	#			}
	#		}
	#		catch {
	#			$PSInfoJsons = $null
	#		}
		
		try {
			Write-Host "Processor info..."
			$procInfos = Invoke-Command -computerName $agentsToQuery -ScriptBlock { Get-WmiObject win32_Processor -ComputerName localhost }
		}
		catch {
			Write-Warning "Problems getting procInfos..."
			Write-Host "##vso[task.logissue type=warning;] Problems getting procInfos..."
			$procInfos = $null
		}
		

		
		foreach ($agent in $agentsAll) {

			if ($agent.id) {

				$agentName = $agent.systemCapabilities.'Agent.ComputerName'

				Write-Host "Processing Agent", $agentName
			
				$poolId = $agentPoolHash.($($agent.id))
				$poolName = $poolNameHash.($($poolId))
			
				$lastOrCurrentBuild = ((Invoke-RestMethod -Uri "$projectUrl/_apis/distributedtask/pools/$($poolId)/jobrequests?api-version=4.0&agentId=$($agent.id)&completedRequestCount=1" -Headers $headers).value[0])

				if ($lastOrCurrentBuild.finishTime) {
					$busy = "Idle"
					$buildDef = $null
				}
				else {
					$busy = "Busy"
					$buildDef = $lastOrCurrentBuild.owner.Name
					write-host $agentName "is" $busy "with", $buildDef
				}
			
				$sysCapJson = $agent.systemCapabilities | ConvertTo-Json -Compress -Depth 100
				$sysCap = ""
				if ($str1 = ($agent.systemCapabilities.PSObject.Properties | Select-Object -Property Name, Value) | Out-String) {
					$str2 = $str1.Replace('\', '/')
					$str3 = ""
					foreach ($line in $str2) {
						$str3 += $line + "\n"
					}
					$str4 = $str3.Replace("`r`n", "\n")
					$str5 = $str4.Replace("`n", "\n")
					$str6 = $str5.Replace("`t", "    ")
					$sysCap = $str6.Replace('"', "'")
				}
			
				try {
					if ($pathMachine = $pathMachines | Where-Object { $_.PSComputerName -eq $agentName }) {
						$pathMachine | Out-File -Encoding ASCII "$($ENV:outputLocation)\$($agentName)_PATH_Machine"
					}
				}
				catch {
					Write-Warning "Problems getting pathMachine..."
					Write-Host "##vso[task.logissue type=warning;] Problems getting pathMachine..."
					$pathMachine = $null
				}
			
				try {
					if ($pathUser = $pathUsers | Where-Object { $_.PSComputerName -eq $agentName }) {
						$pathUser | Out-File -Encoding ASCII "$($ENV:outputLocation)\$($agentName)_PATH_User"
					}
				}
				catch {
					Write-Warning "Problems getting pathUser..."
					Write-Host "##vso[task.logissue type=warning;] Problems getting pathUser..."
					$pathUser = $null
				}

				try {
					#			$environment = Invoke-Command -computerName $agentName -scriptblock {Get-Childitem env: | select name, value}
					$environment = $environments | Where-Object { $_.PSComputerName -eq $agentName } | Select-Object name, value
					$environmentHash = @{ }
					foreach ($item in $environment) {
						$environmentHash.Add($item.Name, $item.value)
					}
					$environmentJson = $environmentHash | ConvertTo-Json -Compress -Depth 100
				}
				catch {
					Write-Warning "Problems getting environment..."
					Write-Host "##vso[task.logissue type=warning;] Problems getting environment..."
					$environment = $null
					$environmentJson = "{}"
				}

				try {
					#			$diskSize = (Invoke-Command -computerName $agentName -scriptblock {Get-WmiObject Win32_LogicalDisk -ComputerName localhost -Filter "DeviceID='C:'"}).size
					$diskSize = ($diskSizes | Where-Object { $_.PSComputerName -eq $agentName } | Select-Object size).size
				}
				catch {
					Write-Warning "Problems getting diskSize..."
					Write-Host "##vso[task.logissue type=warning;] Problems getting diskSize..."
					$diskSize = $null
				}

				try {
					#			$memorySize = ((Invoke-Command -computerName $agentName -scriptblock {Get-WmiObject Win32_PhysicalMemory -ComputerName localhost}).Capacity | measure-object -sum).sum
					$memorySize = (($memorySizes | Where-Object { $_.PSComputerName -eq $agentName } | Select-Object Capacity).Capacity | Measure-Object -Sum).sum
				}
				catch {
					Write-Warning "Problems getting memorySize..."
					Write-Host "##vso[task.logissue type=warning;] Problems getting memorySize..."
					$memorySize = $null
				}

				try {
					#			$systeminfoCSV = Invoke-Command -computerName $agentName -scriptblock {(& systeminfo /fo csv)}
					#			$systeminfoJson = $systeminfoCSV | convertfrom-csv | convertto-json -compress -depth 100
					$systeminfoJson = $systeminfoJsons | Where-Object { $_.PSComputerName -eq $agentName }
				}
				catch {
					Write-Warning "Problems getting systeminfoJson..."
					Write-Host "##vso[task.logissue type=warning;] Problems getting systeminfoJson..."
					$systeminfoCSV = $null
					$systeminfoJson = "{}"
				}
			
				if (!($systeminfoJson)) {
					$systeminfoJson = "{}"
				}
			
				try {
					$PSInfoJson = $PSInfoJsons | Where-Object { $_.PSComputerName -eq $agentName }
				}
				catch {
					Write-Warning "Problems getting PSInfoJson..."
					Write-Host "##vso[task.logissue type=warning;] Problems getting PSInfoJson..."
					$PSInfoJson = "{}"
				}

				try {
					#			$procInfo = (Invoke-Command -computerName $agentName -scriptblock {Get-WmiObject win32_Processor -ComputerName localhost})
					$procInfo = $procInfos | Where-Object { $_.PSComputerName -eq $agentName }
					$procCurrentClockSpeed = $procInfo.CurrentClockSpeed
					$procDescription = $procInfo.Description
					$procName = $procInfo.Name
					$procNumberOfCores = $procInfo.NumberOfCores
					$procNumberOfLogicalProcessors = $procInfo.NumberOfLogicalProcessors
				}
				catch {
					Write-Warning "Problems getting procInfo..."
					Write-Host "##vso[task.logissue type=warning;] Problems getting procInfo..."
					$procInfo = $null
					$procCurrentClockSpeed = $null
					$procDescription = $null
					$procName = $null
					$procNumberOfCores = $null
					$procNumberOfLogicalProcessors = $null
				}

				$id = get-random
				$agentInfoBody += @"
{"create": {"_index": "$($strElasticSearchIndex)","_type": "data","_id": "$($agent.ID)"}}
{"ID": "$($agent.ID)","Name": "$($agentName)","Tenant": "$($tenant)","Agent_ID": "$($agent.ID)","Pool_ID": "$($poolId)","Pool": "$($poolName)","Enabled": "$($agent.Enabled)","Status": "$($agent.Status)","DiskSize": "$diskSize","MemorySize": "$memorySize","ProcCount": "$($agent.systemCapabilities.'NUMBER_OF_PROCESSORS')","procCurrentClockSpeed": "$procCurrentClockSpeed","procDescription": "$procDescription","procName": "$procName","procNumberOfCores": "$procNumberOfCores","procNumberOfLogicalProcessors": "$procNumberOfLogicalProcessors","Building": "$($buildDef)","provisioningState": "$($agent.provisioningState)","Busy": "$($busy)","ClientAlias": "$($agent.systemCapabilities.ClientAlias)","Capabilities": $($sysCapJson),"Environment": $($environmentJson),"SystemInfo": $($systeminfoJson),"Query_Time": "$($strDateTime)"}

"@

				$tmpSysCap = $null
				$tmpEnvironment = $null
				$tmpSystemInfo = $null
				$tmpPSInfo = $null

				foreach ($name in ($agent.systemCapabilities | Get-Member -MemberType NoteProperty | Select -ExpandProperty Name)) {
					$tmpSysCap += $name + "=" + $agent.systemCapabilities.$($name) + "`n"
				}
			
				foreach ($name in ($environmentHash.keys)) {
					$tmpEnvironment += $name + "=" + $environmentHash.$($name) + "`n"
				}

				if ($systemInfo = $systeminfoJson | convertfrom-json) {
					foreach ($name in $systemInfo | Get-Member -MemberType NoteProperty | Select -ExpandProperty Name) {
						$tmpSystemInfo += $name + "=" + $systemInfo.$($name) + "`n"
					}
				}
			
				#		$PSInfo = $PSInfoJson | convertfrom-json
				#		foreach ($item in $PSInfo) {
				#			$tmpPSInfo += $item + "`n"
				#		}
				#		$tmpPSInfo = $tmpPSInfo.Replace(',','')
		
				$tmpobject = new-object PSObject
			
				$tmpobject | Add-Member NoteProperty ID                             $($agent.ID)
				$tmpobject | Add-Member NoteProperty Name                           $($agentName)
				$tmpobject | Add-Member NoteProperty Tenant                         $($tenant)
				$tmpobject | Add-Member NoteProperty Pool_ID                        $($poolId)
				$tmpobject | Add-Member NoteProperty Pool                           $($poolName)
				$tmpobject | Add-Member NoteProperty Enabled                        $($agent.Enabled)
				$tmpobject | Add-Member NoteProperty Status                         $($agent.Status)
				$tmpobject | Add-Member NoteProperty DiskSize                       $($diskSize)
				$tmpobject | Add-Member NoteProperty MemorySize                     $($memorySize)
				$tmpobject | Add-Member NoteProperty procDescription                $($procDescription)
				$tmpobject | Add-Member NoteProperty procName                       $($procName)
				$tmpobject | Add-Member NoteProperty procNumberOfCores              $($procNumberOfCores)
				$tmpobject | Add-Member NoteProperty procNumberOfLogicalProcessors  $($procNumberOfLogicalProcessors)
				$tmpobject | Add-Member NoteProperty ProcCount                      $($agent.systemCapabilities.'NUMBER_OF_PROCESSORS')
				$tmpobject | Add-Member NoteProperty procCurrentClockSpeed          $($procCurrentClockSpeed)
				$tmpobject | Add-Member NoteProperty ClientAlias                    $($agent.systemCapabilities.ClientAlias)
				$tmpobject | Add-Member NoteProperty Query_Time                     $($strDateTime)
				$tmpobject | Add-Member NoteProperty Capabilities                   $($tmpSysCap)
				$tmpobject | Add-Member NoteProperty Environment                    $($tmpEnvironment)
				$tmpobject | Add-Member NoteProperty SystemInfo                     $($tmpSystemInfo)
				#		$tmpobject | Add-Member NoteProperty PSInfo                         $($tmpPSInfo)

				$agentInfotable += $tmpobject
			}
		}
	}

	Write-Host "Deleting previous data..."

	while ($true) {
		$esString = @"
{"query": { "match_all" : {}}}

"@
		$ids = (Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/$($strElasticSearchIndex)/_search?size=1000 -Method POST -Body $esString -ContentType "application/json").hits.hits._id
		if ($ids) {
			$esString = ""
			foreach ($id in $ids) {
				$esString += @"
{"delete": {"_index": "$($strElasticSearchIndex)","_type": "data","_id": "$($id)"}}

"@
			}
			if ($esString) {
				Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
			}
		} else {
			break
		}
	}


	Write-Host "Writing current data..."
	
	if ($agentInfoBody) {
		try {
			$result = Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $agentInfoBody -ContentType "application/json"
			$result
		}
		catch {
			write-warning "Errors writing to ES - Bulk Mode"
			Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Bulk Mode"
		}
		if ($result.errors) {
			write-warning "Errors writing to ES - Bulk Mode"
			foreach ($resultItem in $result.items) {
				if ($resultItem.create.error) {
					$resultItem.create.error | convertto-json -depth 100
				}
			}
			write-warning "Attempting to narrow down the error..."
			$tmpBody = $null
			foreach ($esStringItem in $agentInfoBody.split("`n")) {
				if ($esStringItem.split(":")[0] -like "*delete*") {
					$tmpBody += $esStringItem + "`n"
				}
				if ($esStringItem.split(":")[0] -like "*create*") {
					$tmpBody += $esStringItem + "`n"
				}
				if ($esStringItem.split(":")[0] -like "*ID*") {
					$tmpBody += $esStringItem + "`n`n"

					try {
						$result2 = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
						$result2
					}
					catch {
						write-warning "Errors writing to ES - Single Mode"
					}
					if ($result2.errors) {
						write-warning "Errors writing to ES - Single Mode"
						foreach ($result2Item in $result2.items) {
							if ($result2Item.create.error) {
								$result2Item.create.error | convertto-json -depth 100
							}
						}
						$tmpBody
					}
					$tmpBody = $null
				}
			}
		}

		$agentInfoBody = $null
	}

	Write-Host "Generating Build Agent Inventory CSV..."
	
	$agentInfotable | Export-CSV ".\BuildAgentInventory.csv" -NoTypeInformation
	
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


main
