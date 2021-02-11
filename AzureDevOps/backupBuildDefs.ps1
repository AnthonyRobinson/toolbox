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

        Write-Host "$($tenant)"

        $tenantUrl = "https://dev.azure.com/$($tenant)"

        if ($PAT = ($ENV:PATSjson | ConvertFrom-Json).$($tenant)) {
            $headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
        }
        elseif ($PAT = ($jsonConfiguration.tenants | Where-Object { $_.name -like "$($tenant)" }).PAT) {
            $headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
        }

        $projects = (Invoke-RestMethod -Uri "$($tenantUrl)/_apis/projects?api-version=2.1" -Headers $headers).value

        foreach ($projectName in $projects.name) {

            $projectUrl = $tenantUrl + "/" + $projectName

            $backupFolder = "$($scriptPath)\buildPipelineBackup\$($tenant)\$($projectName)"

            if (!(Test-Path "$($backupFolder)")) {
                mkdir "$($backupFolder)"
            }

            foreach ($defName in "*") {
                $buildIds = (Invoke-RestMethod -Uri "$projectUrl/_apis/build/definitions?name=$($defName)*&builtAfter=$($strDatePrevious)&api-version=4.1" -Headers $headers).value.id

                foreach ($buildId in $buildIds) {
                    $build = Invoke-RestMethod -Uri "$projectUrl/_apis/build/definitions/$($buildId)?api-version=4.1" -ContentType "application/json" -Headers $headers
                    Write-Host $($build.name)
                    $build | ConvertTo-Json -Depth 100 | Out-File "$($backupFolder)\$($build.name) $($buildId).json" -Encoding ascii

                    $phaseCount= 0
                    foreach ($phase in $build.process.phases) {
                        $stepCount = 0
                        foreach ($step in $phase.steps) {
                            if ($script = $step.inputs.script) {
                                $tmp = Get-Random -Minimum 1000 -Maximum 9999
                                $script | Out-File "$($backupFolder)\$($build.name) $($buildId).$($phaseCount).$($stepCount).script" -Encoding ascii
                            }
                            $stepCount += 1
                        }
                        $phaseCount += 1
                    }
                }
            }

        }
    }
}

main