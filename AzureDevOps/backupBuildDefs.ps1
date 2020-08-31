<#

	.SYNOPSIS
		Script to dump VSTS Build Defs to json.

	.DESCRIPTION
		Script to dump VSTS Build Defs to json.


#>

function main {

    $scriptPath = Split-Path $script:MyInvocation.MyCommand.Path
    $scriptPath
    . "$($scriptPath)\gatherIncludes.ps1"

    loadConfiguration

    $strDatePrevious = [DateTime]::Today.AddDays(-180).toString("MM/dd/yyyy")
    $strDatePrevious

    foreach ($tenant in $jsonConfiguration.tenants.name) {

        write-host "$($tenant)"

        $tenantUrl = "https://$($tenant).visualstudio.com"

        if ($PAT = ($ENV:PATSjson | convertfrom-json).$($tenant)) {
            $headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
        }
        elseif ($PAT = ($jsonConfiguration.tenants | where { $_.name -like "$($tenant)" }).PAT) {
            $headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
        }

        $projects = (Invoke-RestMethod -Uri "$($tenantUrl)/_apis/projects?api-version=2.1" -Headers $headers).value

        foreach ($projectName in $projects.name) {

			$projectUrl = $tenantUrl + "/" + $projectName

            $backupFolder = "buildPipelineBackup\$($tenant)\$($projectName)"

				if (!(test-path "$($backupFolder)")) {
					mkdir "$($backupFolder)"
				}

            foreach ($defName in "*") {
                $buildIds = (Invoke-RestMethod -Uri "$projectUrl/_apis/build/definitions?name=$($defName)*&builtAfter=$($strDatePrevious)&api-version=4.1" -Headers $headers).value.id

                foreach ($buildId in $buildIds) {
                    $build = Invoke-RestMethod -Uri "$projectUrl/_apis/build/definitions/$($buildId)?api-version=4.1" -ContentType "application/json" -Headers $headers
                    write-Host $($build.name)
                    $build | convertto-json -depth 100 | out-file "$($backupFolder)\$($projectName)\$($buildId) $($build.name).json" -encoding ascii
                }
            }

        }
    }
}

main