<#

	.SYNOPSIS
		Script to dump VSTS Build Defs to json.

	.DESCRIPTION
		Script to dump VSTS Build Defs to json.


#>

param (
	[string]$PATSjson = $null
)



function main {

	$scriptPath = Split-Path $script:MyInvocation.MyCommand.Path
	$scriptPath
	. "$($scriptPath)\gatherIncludes.ps1"

	loadConfiguration

	foreach ($tenant in $jsonConfiguration.tenants.name) {
		#	foreach ($tenant in "microsoft") {

		Write-Host "$($tenant)"

		$tenantUrl = "https://dev.azure.com/$($tenant)"

		if ($PAT = ($PATSjson | ConvertFrom-Json).$($tenant)) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
		}
		elseif ($PAT = ($ENV:PATSjson | ConvertFrom-Json).$($tenant)) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
		}
		elseif ($PAT = ($jsonConfiguration.tenants | Where-Object { $_.name -like "$($tenant)" }).PAT) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
		}

		$projects = (Invoke-RestMethod -Uri "$($tenantUrl)/_apis/projects?api-version=2.1" -Headers $headers).value

		foreach ($project in $projects.name) {
			#		foreach ($project in "Apps") {

			Write-Host "$($tenant) / $($project)"

			# -- Query the vNext Builds for this Project

			$projectUrl = $tenantUrl + '/' + $project

			$taskGroups = (Invoke-RestMethod -Uri $projectUrl/_apis/distributedtask/taskgroups?api-version=5.0-preview.1 -Headers $headers).value

			foreach ($taskGroup in $taskGroups) {
				if ($taskGroup.parentDefinitionId) {
					$quality = "draft"
				}
				else {
					$quality = "definition"
				}

				$backupFolder = "$($scriptPath)\taskGroupBackup\$($tenant)\$($project)\$($quality)"

				if (!(Test-Path "$($backupFolder)")) {
					mkdir "$($backupFolder)"
				}

				$tmpName = $taskGroup.name.replace(':', '-').replace('[', '-').replace(']', '-').replace('\', '-').replace('/', '-')

				Write-Host "$($tenant) / $($project) / $($quality) / $($taskGroup.name)"
				$taskGroup | ConvertTo-Json -Depth 100 | Out-File "$($backupFolder)\$($tmpName) $($taskGroup.version.major).$($taskGroup.version.minor).$($taskGroup.version.patch).json" -Encoding ascii

				if (Test-Path "$($backupFolder)\$($tmpName) $($taskGroup.version.major).$($taskGroup.version.minor).$($taskGroup.version.patch).*.txt") {
					Remove-Item "$($backupFolder)\$($tmpName) $($taskGroup.version.major).$($taskGroup.version.minor).$($taskGroup.version.patch).*.txt"
				}

				<# 				foreach ($task in $taskGroup.tasks) {
					if ($script = $task.inputs.script) {
						$tmp = get-random -Minimum 1000 -Maximum 9999
						$script | Out-File "$($backupFolder)\$($tmpName) $($taskGroup.version.major).$($taskGroup.version.minor).$($taskGroup.version.patch).$($tmp).ps1" -Encoding ascii
					}
				} #>

				for ($i = 0 ; $i -lt $taskGroup.tasks.count ; $i++) {
					if ($script = $taskGroup.tasks[$i].inputs.script) {

						$tmpName2 = $taskGroup.tasks[$i].displayName.replace(':', '-').replace('[', '-').replace(']', '-').replace('\', '-').replace('/', '-')

						if ($taskGroup.tasks[$i].task.id -like "d9bafed4-0b18-4f58-968d-86655b4d2ce9") {
							$extension = "cmd"
						}
						elseif ($taskGroup.tasks[$i].task.id -like "e213ff0f-5d5c-4791-802d-52ea3e7be1f1") {
							$extension = "ps1"
						}
						else {
							$extension = "txt"
						}
						$script | Out-File "$($backupFolder)\$($tmpName) $($taskGroup.version.major).$($taskGroup.version.minor).$($taskGroup.version.patch).$($i).$($tmpName2).$($extension)" -Encoding ascii
					}
				}
			}
		}
	}
}



main
