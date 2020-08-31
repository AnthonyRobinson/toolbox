<#

	.SYNOPSIS
		Queries Build Agents for their current disk space

	.DESCRIPTION
		Queries VSTS Build Agents for a specific pool, then queries each agent for disk size and free space. Percentage free space is calculated.  All data is written to ElasticSearch with current query time for time-based analysis.

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

function main { 

	$progressPreference = 'silentlyContinue'

	if (!($projectUrl = $ENV:SYSTEM_TEAMFOUNDATIONSERVERURI)) {
		$projectUrl = "https://microsoft.visualstudio.com"
	}

	if (!($personalAccessToken = $ENV:PAT)) {
		write-warning "Personal Authentication Token or OAuth System_AccessToken needs to be set in the environment"
	} elseif (!($OAuthToken = $ENV:System_AccessToken)) {
		write-warning "Personal Authentication Token or OAuth System_AccessToken needs to be set in the environment"
	} else {
		write-error "Personal Authentication Token or OAuth System_AccessToken needs to be set in the environment"
	}
	
	if (!($strMetricsServer = $ENV:strMetricsServer)) {
		$strMetricsServer = "STD-5276466"
	}
	
	if (!($poolName = $ENV:poolName)) {
		$poolName = "Package ES Custom Demands Lab A"
	}
	
	$strRunningFile = $MyInvocation.ScriptName + ".running"
	
	$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($personalAccessToken)")) } 
	
	listAgentsDiskSpace
	
	if (Test-Path "$strRunningFile") {
		Remove-Item "$strRunningFile"
	}

	exit 0
	
}

function listAgentsDiskSpace {

	$agentNameTable = @()
	$agentSpaceTable = @{}
	
	foreach ($pool in ((Invoke-RestMethod -Uri $projectUrl/_apis/distributedtask/pools?api-version=4.0 -Headers $headers).value | Where-Object {$_.name -like $poolName})) {
		foreach ($agent in ((Invoke-RestMethod -Uri $projectUrl/_apis/distributedtask/pools/$($pool.id)/agents?api-version=4.0`&includeCapabilities=true -Headers $headers).value | where-object {$_.systemCapabilities.ClientAlias -like "EvokeBuild*"})) {
			if ($agent.enabled -like "True" -and $agent.status -like "online") {
				if (!($agentNameTable.Agent -contains $agent.systemCapabilities.'Agent.ComputerName')) {
					$tmpobject = new-object PSObject
					$tmpobject | Add-Member NoteProperty Agent $agent.systemCapabilities.'Agent.ComputerName'
					$agentNameTable += $tmpobject
				}
			}
		}
	}

	$buildAgents = ($agentNameTable.agent | sort-object | get-unique)

	foreach ($buildAgent in $buildAgents) {
		write-host "Looking at" $buildAgent
		$user = $buildAgent + "\dexxadmin"
		$passClear = $($buildAgent).substring(0,1) + $($buildAgent).substring(1).toLower()
		$pass = ConvertTo-SecureString $passClear -AsPlainText -Force
		$cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $user, $pass
		if ($diskInfo = invoke-command -computer $buildAgent -scriptblock {Get-WmiObject Win32_LogicalDisk -ComputerName localhost -Filter "DeviceID='C:'"}) {
			write-host "Found disk info for" $buildAgent
			$strDateTime = ((get-date).toUniversalTime().toString("MM/dd/yyyy HH:mm:ss"))
			$pct = (($diskInfo.FreeSpace / $diskInfo.Size) * 100)
			$id = get-random
			$data = @"
{"create": {"_index": "buildagentstats","_type": "data","_id": "$id"}}
{"ID": "$id","DateTime":"$($strDateTime)","BuildAgent":"$($buildAgent.toUpper())","DiskSize":$($diskInfo.Size),"DiskFree":$($diskInfo.FreeSpace),"DiskFreePct":$($pct)}

"@
			if ($data) {
				invoke-RestMethod -Uri http://$($strMetricsServer):9200/_bulk?pretty -Method POST -Body $data -ContentType "application/json"
			}
		} else {
			write-host "WARNING: Unable to query" $buildAgent
		}
	}
}
	
main
