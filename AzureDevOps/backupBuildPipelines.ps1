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

	$strDatePrevious = [DateTime]::Today.AddDays(-90).toString("MM/dd/yyyy")


	write-host "Getting Build Pipelines active since", $strDatePrevious

	foreach ($tenant in $jsonConfiguration.tenants.name) {

		write-host "$($tenant)"

		$tenantUrl = "https://$($tenant).visualstudio.com"
		$PAT = "53sp5xvm6u42um2enqolfb7jbva4mpb2dtdjm6a7ypfy3brq7dwq"
		$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)"))}

		$projects = (Invoke-RestMethod -Uri "$($tenantUrl)/_apis/projects?api-version=2.1" -Headers $headers).value

		foreach ($project in $projects.name) {

			write-host "$($tenant) / $($project)"

			# -- Query the vNext Builds for this Project

			$projectUrl = $tenantUrl + '/' + $project

			foreach ($quality in "definition", "draft") {

				write-host "$($tenant) / $($project) / $($quality)"

				$backupFolder = "$($scriptPath)\buildPipelineBackup\$($tenant)\$($project)\$($quality)"

				if (!(test-path "$($backupFolder)")) {
					mkdir "$($backupFolder)"
				}

				foreach ($defName in "A*","B*","C*","D*","E*","F*","G*","H*","I*","J*","K*","L*","M*","N*","O*","P*","Q*","R*","S*","T*","U*","V*","W*","X*","Y*","Z*","0","1","2","3","4","5","6","7","8","9") {
#				foreach ($defName in "BuddyBuild*", "MergeValidation*", "OfficialBuild*") {

					if ($strDatePrevious) {
						$buildDefs = ((Invoke-RestMethod -Uri "$($projectUrl)/_apis/build/definitions?name=$($defName)&builtAfter=$($strDatePrevious)&api-version=5.0" -Headers $headers).value | `
							Where-Object { $_.quality -eq $quality })
					}
					else {
						$buildDefs = ((Invoke-RestMethod -Uri "$($projectUrl)/_apis/build/definitions?name=$($defName)&api-version=5.0 " -Headers $headers).value | `
							Where-Object { $_.quality -eq $quality })
					}

					foreach ($buildDef in $buildDefs) {
#						$tmp = $builddef.path -split "\\"
#						if ($tmp[1] -ieq "cdp" -and $tmp[2] -ieq "media") {
#							$builddef.path
#							write-host $tmp[4], $tmp[5]
							$buildDefId = $buildDef.id
							$buildDef = Invoke-RestMethod -Uri "$($projectUrl)/_apis/build/definitions/$($buildDefId)?includeAllProperties=true&api-version=5.0" -ContentType "application/json" -Headers $headers
							write-host "$($tenant) / $($project) / $($quality) / $($buildDef.name)"
							$buildDef | convertto-json -depth 100 | out-file "$($backupFolder)\$($buildDef.name) $($buildDefId).json" -encoding ascii
#						}
					}
				}
			}
		}
	}
}



main
