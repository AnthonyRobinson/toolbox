<#

	.SYNOPSIS
		Script to dump VSTS Release Defs to json.

	.DESCRIPTION
		Script to dump VSTS Release Defs to json.


#>

param (
	[string]$PATSjson = $null
)


function main {

	$scriptPath = Split-Path $script:MyInvocation.MyCommand.Path
	$scriptPath
	. "$($scriptPath)\gatherIncludes.ps1"

	loadConfiguration

	$strDatePrevious = [DateTime]::Today.AddDays(-90).toString("MM/dd/yyyy")

	Write-Host "Getting Release Pipelines active since", $strDatePrevious

	foreach ($tenant in $jsonConfiguration.tenants.name) {
		#	foreach ($tenant in "microsoft") {

		Write-Host "$($tenant)"

		$collection = "https://dev.azure.com/$($tenant)"

		$tenantUrl = "https://$($tenant).vsrm.visualstudio.com"

		if ($PAT = ($PATSjson | ConvertFrom-Json).$($tenant)) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
		}
		elseif ($PAT = ($ENV:PATSjson | ConvertFrom-Json).$($tenant)) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
		}
		elseif ($PAT = ($jsonConfiguration.tenants | Where-Object { $_.name -like "$($tenant)" }).PAT) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
		}

		$projects = (Invoke-RestMethod -Uri "$($collection)/_apis/projects?api-version=2.1" -Headers $headers).value

		foreach ($project in $projects.name) {
			#		foreach ($project in "Apps") {

			Write-Host "$($tenant) / $($project)"

			$projectUrl = $tenantUrl + "/" + $project

			$backupFolder = "$($scriptPath)\ReleasePipelineBackup\$($tenant)\$($project)\$($quality)"

			if (!(Test-Path "$($backupFolder)")) {
				mkdir "$($backupFolder)"
			}

			if ($releaseIds	= (Invoke-RestMethod -Uri "$projectUrl/_apis/release/definitions" -Headers $headers).value.id) {
				$releaseIds	= (Invoke-RestMethod -Uri "$projectUrl/_apis/release/definitions" -Headers $headers).value.id

				foreach ($releaseId in $releaseIds) {
					$release = Invoke-RestMethod -Uri "$projectUrl/_apis/release/definitions/$($releaseId)" -ContentType "application/json" -Headers $headers
					Write-Host "$($tenant) / $($project) / $($quality) / $($release.name)"
					$release | ConvertTo-Json -Depth 100 | Out-File "$($backupFolder)\$($release.name) $($releaseId).json" -Encoding ascii

					foreach ($environment in $release.environments) {
						foreach ($deployPhase in $environment.deployPhases) {
							for ($i = 0 ; $i -lt $deployPhase.workflowTasks.count ; $i++) {
							# foreach ($workflowTask in $deployPhase.workflowTasks) {
								if ($script = $deployPhase.workflowTasks[$i].inputs.script) {
									$tmpName2 = $deployPhase.workflowTasks[$i].name.replace(':', '-').replace('[', '-').replace(']', '-').replace('\', '-').replace('/', '-')

									if ($deployPhase.workflowTasks[$i].taskId -like "d9bafed4-0b18-4f58-968d-86655b4d2ce9") {
										$extension = "cmd"
									}
									elseif ($deployPhase.workflowTasks[$i].taskId -like "e213ff0f-5d5c-4791-802d-52ea3e7be1f1") {
										$extension = "ps1"
									}
									else {
										$extension = "txt"
									}
									$tmp = Get-Random -Minimum 1000 -Maximum 9999
									$script | Out-File "$($backupFolder)\$($release.name) $($releaseId).$($environment.id).$($deployPhase.deploymentInput.queueid).$($i).$($tmpName2).$($extension)" -Encoding ascii
								}
							}
						}
					}

					# ROOT.environments[0].deployPhases[0].workflowTasks[0].inputs.script

				}
			}
		}
	}
}

main
