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
	
	listAgents
	
	if (Test-Path "$strRunningFile") {
		Remove-Item "$strRunningFile"
	}

	exit 0
	
}

function listAgents {

	$strDateTime = ((get-date).toUniversalTime().toString("MM/dd/yyyy HH:mm:ss"))
	
	$data = ""
	
	foreach ($pool in ((Invoke-RestMethod -Uri $projectUrl/_apis/distributedtask/pools?api-version=4.0 -Headers $headers).value | Where-Object {$_.name -like $poolName})) {
	
		foreach ($agent in ((Invoke-RestMethod -Uri $projectUrl/_apis/distributedtask/pools/$($pool.id)/agents?api-version=4.0`&includeCapabilities=true -Headers $headers).value | where-object {$_.systemCapabilities.ClientAlias -like "EvokeBuild*"})) {
	
			$lastOrCurrentBuild = (Invoke-RestMethod -Uri "$projectUrl/_apis/distributedtask/pools/$($pool.id)/jobrequests?api-version=4.0&agentId=$($agent.id)&completedRequestCount=1" -Headers $headers).value[0]
			
			if ($lastOrCurrentBuild.finishTime) {
				$busy="Idle"
				$buildDef = $null
			} else {
				$busy="Busy"
				$buildDef = $lastOrCurrentBuild.owner.name
			}
			
			$sysCapJson = $agent.systemCapabilities | convertto-json -Compress -depth 100
			$sysCap = ""
			if ($str1 = ($agent.systemCapabilities.PSObject.Properties | select-object -property Name, Value) | out-string) {
				$str2 = $str1.replace('\','/')
				$str3 = ""
				foreach ($line in $str2) {
					$str3 += $line + "\n"
				}
				$str4 = $str3.Replace("`r`n","\n")
				$str5 = $str4.Replace("`n","\n")
				$str6 = $str5.Replace("`t","    ")
				$sysCap = $str6.replace('"',"'")
			}
			
			$data += @"
{"delete": {"_index": "buildagents","_type": "data","_id": "$($agent.ID)"}}
{"create": {"_index": "buildagents","_type": "data","_id": "$($agent.ID)"}}
{"ID": "$($agent.ID)","Name": "$($agent.systemCapabilities.'Agent.Name')","Pool": "$($pool.name)","Enabled": "$($agent.Enabled)","ProcCount": "$($agent.systemCapabilities.'NUMBER_OF_PROCESSORS')","Status": "$($agent.Status)","Building": "$($buildDef)", "provisioningState": "$($agent.provisioningState)","Busy": "$($busy)","ClientAlias": "$($agent.systemCapabilities.ClientAlias)","Capabilities": $($sysCapJson),"Query_Time": "$($strDateTime)"}

"@
		}
	}

	if ($data) {
		invoke-RestMethod -Uri http://$($strMetricsServer):9200/_bulk?pretty -Method POST -Body $data -ContentType "application/json"
		$data = $null
	}
}
	
	
main