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


if (!($personalAccessToken = $ENV:PAT)) {
	write-warning "Personal Authentication Token or OAuth System_AccessToken needs to be set in the environment"
} elseif (!($OAuthToken = $ENV:System_AccessToken)) {
	write-warning "Personal Authentication Token or OAuth System_AccessToken needs to be set in the environment"
} else {
	write-error "Personal Authentication Token or OAuth System_AccessToken needs to be set in the environment"
}
$headers				= @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($personalAccessToken)")) } 
$collection				= "https://microsoft.visualstudio.com"
$projectName			= "apps"
$projectUrl				= $collection + "/" + $projectName
$poolName				= "Package ES Custom Demands Lab A"
$startTime				= [DateTime] "8/1/2018"

$agentTable = @()


foreach ($pool in ((Invoke-RestMethod -Uri $collection/_apis/distributedtask/pools -Headers $headers).value | Where-Object {$_.name -like $poolName})) {

	foreach ($agent in ((Invoke-RestMethod -Uri $collection/_apis/distributedtask/pools/$($pool.id)/agents?includeCapabilities=true -Headers $headers).value | where-object {$_.systemCapabilities.ClientAlias -like "EvokeBuild*"})) {
		
		$agent.name
		
#		if ($agent.name -like "PKGESEVOKEBLD40") {

			$requests = (Invoke-RestMethod -Uri $collection/_apis/distributedtask/pools/$($pool.id)/jobrequests?agentId=$($agent.Id)`&completedRequestCount=1000 -Headers $headers).value
			
			foreach ($request in $requests) {
			
				if ($request.finishTime -and $request.receiveTime) {
					
					$finishTime = ([DateTime]::Parse($request.finishTime)).toString("MM/dd/yyyy HH:mm:ss")
					
					if ($finishTime -gt $startTime) {
						$tmpobject = new-object PSObject

						$tmpobject | Add-Member NoteProperty AgentName      $agent.systemCapabilities.'Agent.Name'
						$tmpobject | Add-Member NoteProperty Definition     $request.definition.name
						$tmpobject | Add-Member NoteProperty Link           $request.definition._links.web.href
						$tmpobject | Add-Member NoteProperty queueTime      ([DateTime]::Parse($request.queueTime)).toString("MM/dd/yyyy HH:mm:ss")
						$tmpobject | Add-Member NoteProperty assignTime     ([DateTime]::Parse($request.assignTime)).toString("MM/dd/yyyy HH:mm:ss")
						$tmpobject | Add-Member NoteProperty receiveTime    ([DateTime]::Parse($request.receiveTime)).toString("MM/dd/yyyy HH:mm:ss")
						$tmpobject | Add-Member NoteProperty finishTime     ([DateTime]::Parse($request.finishTime)).toString("MM/dd/yyyy HH:mm:ss")
						$tmpobject | Add-Member NoteProperty ElapsedTime    (new-TimeSpan -start $request.assignTime -end $request.finishTime).TotalMinutes
						
						$agentTable += $tmpobject
					}
				} 
			}
#		}
	}
}

$agentTable | ConvertTo-Csv -NoTypeInformation | Out-File ".\test.csv"
