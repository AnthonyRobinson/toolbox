<#

	.SYNOPSIS
		Gather an abreviated build history using Agent Pool and Build Agent job request history

	.DESCRIPTION
		Gather an abreviated build history using Agent Pool and Build Agent job request history.  Agent Pool is controlled by $poolName
		
	.INPUTS
		Agent Pool is controlled by $poolName
		Build Start times before $startTime are ignored		

	.OUTPUTS
		Output is to a CSV file, suitable for analysis using Excel

	.NOTES
		Anthony A Robinson 7/2018
		v-antrob@microsoft.com
		https://www.linkedin.com/in/3legdog/

#>

	$personalAccessToken = "3xmsfg2nacbuo37jfkvy3o3ppvety5wglyrmwvmmd6sgtotnd7zq"
	$OAuthToken = $ENV:System_AccessToken

	if ($OAuthToken) {
		$headers = @{ Authorization = ("Bearer {0}" -f $OAuthToken) }
	} elseif ($personalAccessToken) {
		$headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($personalAccessToken)")) }
	} else {
		Write-Error "Neither personalAccessToken nor OAuthToken are set"
	}
	
	$collection		 	= "https://msazure.visualstudio.com"
	$projectName		= "apps"
	$projectUrl			= $collection + "/" + $projectName

	$startTime			= [DateTime] "8/1/2018"

	$agentTable = [System.Collections.ArrayList]@()


	foreach ($pool in ((Invoke-RestMethod -Uri $collection/_apis/distributedtask/pools -Headers $headers).value)) {
		$pool.name

		foreach ($agent in ((Invoke-RestMethod -Uri $collection/_apis/distributedtask/pools/$($pool.id)/agents?includeCapabilities=true -Headers $headers).value)) {
			$agent.name
			
			$requests = (Invoke-RestMethod -Uri $collection/_apis/distributedtask/pools/$($pool.id)/jobrequests?agentId=$($agent.Id)`&completedRequestCount=1000 -Headers $headers).value
			
			foreach ($request in $requests) {
			
				if ($request.finishTime -and $request.receiveTime) {
					
					$finishTime = ([DateTime]::Parse($request.finishTime)).toString("MM/dd/yyyy HH:mm:ss")
					
					if ($finishTime -gt $startTime) {
						$tmpobject = new-object PSObject

						$tmpobject | Add-Member NoteProperty PoolID $pool.ID
						$tmpobject | Add-Member NoteProperty PoolName $pool.name
						$tmpobject | Add-Member NoteProperty AgentID $agent.ID
						$tmpobject | Add-Member NoteProperty Agent $agent.systemCapabilities.'Agent.ComputerName'
						$tmpobject | Add-Member NoteProperty AgentName $agent.systemCapabilities.'Agent.Name'
						$tmpobject | Add-Member NoteProperty Enabled $agent.Enabled
						$tmpobject | Add-Member NoteProperty ProcCount $agent.systemCapabilities.'NUMBER_OF_PROCESSORS'
						$tmpobject | Add-Member NoteProperty Definition     $request.definition.name
						$tmpobject | Add-Member NoteProperty Link           $request.definition._links.web.href
						$tmpobject | Add-Member NoteProperty queueTime      ([DateTime]::Parse($request.queueTime)).toString("MM/dd/yyyy HH:mm:ss")
						$tmpobject | Add-Member NoteProperty assignTime     ([DateTime]::Parse($request.assignTime)).toString("MM/dd/yyyy HH:mm:ss")
						$tmpobject | Add-Member NoteProperty receiveTime    ([DateTime]::Parse($request.receiveTime)).toString("MM/dd/yyyy HH:mm:ss")
						$tmpobject | Add-Member NoteProperty finishTime     ([DateTime]::Parse($request.finishTime)).toString("MM/dd/yyyy HH:mm:ss")
						$tmpobject | Add-Member NoteProperty ElapsedTime    (new-TimeSpan -start $request.assignTime -end $request.finishTime).TotalMinutes
						
						$null = $agentTable.Add($tmpobject)
					}
				} 
			}
		}
	}

	$random = random
	$agentTable | ConvertTo-Csv -NoTypeInformation | Out-File ".\$($random).csv"
