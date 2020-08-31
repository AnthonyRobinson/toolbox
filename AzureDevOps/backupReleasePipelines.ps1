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

	write-host "Getting Release Pipelines active since", $strDatePrevious

	foreach ($tenant in $jsonConfiguration.tenants.name) {
#	foreach ($tenant in "microsoft") {

		write-host "$($tenant)"

		$collection = "https://$($tenant).visualstudio.com"

		$tenantUrl = "https://$($tenant).vsrm.visualstudio.com"

		if ($PAT = ($PATSjson | convertfrom-json).$($tenant)) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)"))}
		} elseif ($PAT = ($ENV:PATSjson | convertfrom-json).$($tenant)) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)"))}
		} elseif ($PAT = ($jsonConfiguration.tenants | where { $_.name -like "$($tenant)" }).PAT) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)"))}
		}

		$projects = (Invoke-RestMethod -Uri "$($collection)/_apis/projects?api-version=2.1" -Headers $headers).value

		foreach ($project in $projects.name) {
#		foreach ($project in "Apps") {

			write-host "$($tenant) / $($project)"

			$projectUrl = $tenantUrl + "/" + $project

			$backupFolder = "$($scriptPath)\ReleasePipelineBackup\$($tenant)\$($project)\$($quality)"

			if (!(test-path "$($backupFolder)")) {
				mkdir "$($backupFolder)"
			}

			if ($releaseIds	= (Invoke-RestMethod -Uri "$projectUrl/_apis/release/definitions" -Headers $headers).value.id) {
				$releaseIds	= (Invoke-RestMethod -Uri "$projectUrl/_apis/release/definitions" -Headers $headers).value.id

				foreach ($releaseId in $releaseIds) {
					$release = Invoke-RestMethod -Uri "$projectUrl/_apis/release/definitions/$($releaseId)" -ContentType "application/json" -Headers $headers
					write-host "$($tenant) / $($project) / $($quality) / $($release.name)"
					$release | convertto-json -depth 100 | out-file "$($backupFolder)\$($release.name) $($releaseId).json" -encoding ascii
				}
			}
		}
	}
}

main
