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

		$tenantUrl = "https://$($tenant).visualstudio.com"

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

				if (test-path "$($backupFolder)\$($tmpName) $($taskGroup.version.major).$($taskGroup.version.minor).$($taskGroup.version.patch).*.txt") {
					remove-item "$($backupFolder)\$($tmpName) $($taskGroup.version.major).$($taskGroup.version.minor).$($taskGroup.version.patch).*.txt"
				}

				foreach ($task in $taskGroup.tasks) {
					if ($script = $task.inputs.script) {
						$tmp = get-random -Minimum 1000 -Maximum 9999
						$script | Out-File "$($backupFolder)\$($tmpName) $($taskGroup.version.major).$($taskGroup.version.minor).$($taskGroup.version.patch).$($tmp).txt" -Encoding ascii
					}
				}
			}
		}
	}
}



main
