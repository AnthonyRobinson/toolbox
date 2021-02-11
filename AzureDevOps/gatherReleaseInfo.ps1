<#

	.SYNOPSIS
		Query VSTS for release info and write to databases

	.DESCRIPTION
		Queries VSTS for release info relating to specific release defs and time frames.
		Release data is conditionally written to ElasticSearch.
		ibana is used for dashboard visualization.

	.INPUTS
		All inputs (server names, query options, time window, destructive db writes, etc.) are inferred from the calling environment.  If not set, some defaults are taken.

	.OUTPUTS
		Outputs are data written to ElasticSearch

	.NOTES
		Anthony A Robinson 7/2018
		v-antrob@microsoft.com
		https://www.linkedin.com/in/3legdog/

	.LINK
		http://std-5276466:5601/goto/ed68314bc0db678adf1860af9405d3ce
		http://std-5276466:9200

#>


param (
	[string]$PATSjson = $null
)


function main {

	$DEBUG = $false

	$scriptPath = Split-Path $script:MyInvocation.MyCommand.Path
	$scriptPath
	. "$($scriptPath)\gatherIncludes.ps1"

	$homeFolder = "c:\tmp"

	$progressPreference = 'silentlyContinue'
	$thisRunDateTime = (Get-Date).ToUniversalTime()

	# --- Override defaults with settings string

	loadConfiguration

	# --- override locally

	$strSqlTable = $jsonConfiguration.databases.sqlserver.tables.Release
	$strElasticSearchIndex = $jsonConfiguration.databases.elasticsearch.indexes.Release
	$updateSQL = $false

	if (!($minutesBack = $ENV:minutesBack)) {
		try {
			$tmp = Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/timestamp/_doc/$($strElasticSearchIndex)
			$lastRunDateTime = [datetime]([string]$tmp._source.LastRunTime)
			Write-Host "INFO: last run was at" $lastRunDateTime
			$minutesBack = (New-TimeSpan -Start $thisRunDateTime -End $lastRunDateTime).TotalMinutes
		}
		catch {
			$minutesBack = -200
		}
	}

	$minutesBack = $minutesBack - 44000

	$strStartDate = (Get-Date).AddMinutes($minutesBack).ToUniversalTime()

	Write-Host "INFO: using minutesBack of" $minutesBack "and strStartDate" $strStartDate

	$personalAccessToken = $ENV:PAT
	$OAuthToken = $ENV:System_AccessToken

	if ($OAuthToken) {
		$headers = @{Authorization = ("Bearer {0}" -f $OAuthToken) }
	}
	elseif ($personalAccessToken) {
		$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($personalAccessToken)")) }
	}
	else {
		Write-Error "Neither personalAccessToken nor OAuthToken are set"
	}

	if ($DEBUG) {
		Get-Variable | Format-Table Name, Value
	}

	getTheReleases

	exit 0
}


function Get-CurrentLineNumber {
	$MyInvocation.ScriptLineNumber
}


function getTheReleases {

	$releaseInfoTable = [System.Collections.ArrayList]@()
	$releaseInfoHash = @{ }

	foreach ($field in $mappings.PSObject.Properties) {
		if ($field.value.type -eq "date") {
			$dateTimeFieldNames += $field.name
		}
	}

	$keyField = $null
	foreach ($field in $mappings.PSObject.Properties) {
		if ($field.name -like "*Key*") {
			$keyField = $($field.name)
		}
	}


	foreach ($tenant in $jsonConfiguration.tenants.name) {

		Write-Host "Tenant", $tenant

		$projectUrl = (Invoke-RestMethod "https://dev.azure.com/_apis/resourceAreas/$($resourceAreaId.Release)?accountName=$($tenant)&api-version=5.0-preview.1").locationUrl


		if ($PAT = ($PATSjson | ConvertFrom-Json).$($tenant)) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
		}
		elseif ($PAT = ($ENV:PATSjson | ConvertFrom-Json).$($tenant)) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
		}
		elseif ($PAT = ($jsonConfiguration.tenants | Where-Object { $_.name -like "$($tenant)" }).PAT) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
		}

		if ($strProjects = ($jsonConfiguration.tenants | Where-Object { $_.name -like "$($tenant)" }).projects) {
			Write-Host "Using projects from jsonConfiguration"
		}

		foreach ($strProject in $strProjects) {

			$project = $strProject.name

			Write-Host "Project", "$($project)"

			$projectUrlProject = $projectUrl + "/" + $project

			if ($strDefinitions = ($strProject | Where-Object { $_.name -like "$($project)" }).releasepipelines) {
				Write-Host "Using definitions from jsonConfiguration"
			}

			foreach ($definition in $strDefinitions) {

				$line = Get-CurrentLineNumber
				Write-Host $MyInvocation.ScriptName, $line, $definition

				$line = Get-CurrentLineNumber
				Write-Host $MyInvocation.ScriptName, $line, "$projectUrlProject/_apis/release/definitions"

				$pipelineNames = (Invoke-RestMethod "$projectUrlProject/_apis/release/definitions" -Headers $headers).value | Where-Object { $_.name -like "$($definition)*" }
				#			$pipelineNames = (Invoke-RestMethod "$projectUrlProject/_apis/release/definitions" -Headers $headers).value | where {$_.name -like "$($definition)"}

				foreach ($pipelineName in $pipelineNames) {

					if ($DEBUG) {
						$pipelineName | ConvertTo-Json -Depth 100 | Out-File "$($homeFolder)\pipelineName.$($pipelineName.id).json" -Encoding ascii
					}

					$line = Get-CurrentLineNumber
					Write-Host $MyInvocation.ScriptName, $line, $pipelineName.name

					$line = Get-CurrentLineNumber
					Write-Host $MyInvocation.ScriptName, $line, "$projectUrlProject/_apis/release/releases?api-version=4.1-preview.6&definitionId=$($pipelineName.id)&minCreatedTime=$($strStartDate.ToString())"
					$releases = Invoke-RestMethod "$projectUrlProject/_apis/release/releases?api-version=4.1-preview.6&definitionId=$($pipelineName.id)&minCreatedTime=$($strStartDate.ToString())" -Headers $headers

					if ($DEBUG) {
						$releases | ConvertTo-Json -Depth 100 | Out-File "$($homeFolder)\pipelineName.$($pipelineName.id).releases.json" -Encoding ascii
					}

					foreach ($releaseId in $releases.value.id) {

						$line = Get-CurrentLineNumber
						Write-Host $MyInvocation.ScriptName, $line, $pipelineName.id, "$projectUrlProject/_apis/release/releases/$($releaseId)?api-version=4.1-preview.6"

						foreach ($release in Invoke-RestMethod "$projectUrlProject/_apis/release/releases/$($releaseId)?api-version=4.1-preview.6" -Headers $headers) {

							if ($DEBUG) {
								$line = Get-CurrentLineNumber
								Write-Host $MyInvocation.ScriptName, $line, "release.name", $release.name, "release.status", $release.status
								$release | ConvertTo-Json -Depth 100 | Out-File "$($homeFolder)\pipelineName.$($pipelineName.id).release.$($release.id).json" -Encoding ascii
							}

							if (($release.modifiedBy.displayName -like "Microsoft.VisualStudio.Services.TFS") -or ($release.modifiedBy.displayName -like "Project Collection Build Service*")) {
								$tmpModifiedBy = $release.modifiedBy.displayName
							}
							else {
								$tmpModifiedBy = $release.modifiedBy.id
							}

							if (($release.createdBy.displayName -like "Microsoft.VisualStudio.Services.TFS") -or ($release.createdBy.displayName -like "Project Collection Build Service*")) {
								$tmpCreatedBy = $release.createdBy.displayName
							}
							else {
								$tmpCreatedBy = $release.createdBy.id
							}

							if (!($artifactVersion = ($release.artifacts | Where-Object { $_.alias -like "Logic Apps*" }).definitionReference.version.name)) {
								$artifactVersion = $null
							}

							$tmpVariables = $null
							if ($release.variables) {
								foreach ($name in ($release.variables | Get-Member -MemberType NoteProperty).Name) {
									$tmpValue = $null
									if ($tmpValue = $release.variables.$($name).value) {
										$tmpValue = $tmpValue.replace('"', "'")
										$tmpValue = $tmpValue.replace('\', '/')
									}
									$tmpVariables += $name + "=" + $tmpValue + "\n"
								}
							}

							if ($release.variableGroups.variables) {
								foreach ($name in ($release.variableGroups.variables | Get-Member -MemberType NoteProperty).Name) {
									$tmpValue = $null
									if ($tmpValue = $release.variableGroups.variables.$($name).value) {
										$tmpValue = $tmpValue.replace('"', "'")
										$tmpValue = $tmpValue.replace('\', '/')
									}
									$tmpVariables += $name + "=" + $tmpValue + "\n"
								}
							}

							$global:CreatedOn_Time = ([DateTime]::now).toUniversalTime().AddHours(-8).toString("MM/dd/yyyy HH:mm:ss")
							$global:CreatedOn_TimeZ = ([DateTime]::now).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
							$global:ModifiedOn_Time = $null
							$global:ModifiedOn_TimeZ = $null
							$global:Start_Time = $null
							$global:Start_TimeZ = $null
							$global:Finish_Time = $null
							$global:Finish_TimeZ = $null
							$global:Queued_Time = $null
							$global:Queued_TimeZ = $null

							$tmpReleaseKey = [string]$pipelineName.id + "_" + `
								[string]$releaseId

							if ($release.createdOn) {
								$global:CreatedOn_Time = ([DateTime]::Parse($release.createdOn)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
								$global:CreatedOn_TimeZ = ([DateTime]::Parse($release.createdOn)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
							}
							if ($release.modifiedOn) {
								$global:ModifiedOn_Time = ([DateTime]::Parse($release.modifiedOn)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
								$global:ModifiedOn_TimeZ = ([DateTime]::Parse($release.modifiedOn)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
							}

							$releaseObject = New-Object ReleaseRecord

							$releaseObject.ReleaseKey = $tmpReleaseKey
							$releaseObject.PipelineID = $pipelineName.id
							$releaseObject.ReleaseID = $releaseId
							$releaseObject.PipelineName = $pipelineName.name
							$releaseObject.ReleaseName = $release.name
							$releaseObject.RecordType = "Release"
							$releaseObject.Status = $release.status
							$releaseObject.Tenant = $tenant
							$releaseObject.Project = $project
							$releaseObject.Reason = $release.Reason
							$releaseObject.Description = $release.Description
							$releaseObject.ModifiedBy = $tmpModifiedBy
							$releaseObject.CreatedBy = $tmpCreatedBy
							$releaseObject.VSTSlink = "$($projectUrl)/$($project)/_releaseProgress?releaseId=$($releaseId)"
							$releaseObject.Variables = $tmpVariables
							$releaseObject.ArtifactVersion = $artifactVersion

							$releaseErrorIssues = $null


							foreach ($environment in $release.environments) {

								if ($DEBUG) {
									$line = Get-CurrentLineNumber
									Write-Host $MyInvocation.ScriptName, $line, "environment.id", $environment.id, "environment.status", $environment.status
									$environment | ConvertTo-Json -Depth 100 | Out-File "$($homeFolder)\pipelineName.$($pipelineName.id).release.$($release.id)_environment.$($environment.id).json" -Encoding ascii
								}

								$tmpReleaseKey = [string]$pipelineName.id + "_" + `
									[string]$releaseId + "_" + `
									[string]$environment.id


								$tmpVariables = $null
								if ($environment.variables) {
									foreach ($name in ($environment.variables | Get-Member -MemberType NoteProperty).Name) {
										$tmpValue = $null
										if ($tmpValue = $environment.variables.$($name).value) {
											$tmpValue = $tmpValue.replace('"', "'")
											$tmpValue = $tmpValue.replace('\', '/')
										}
										$tmpVariables += $name + "=" + $tmpValue + "\n"
									}
								}

								if ($environment.createdOn) {
									$global:CreatedOn_Time = ([DateTime]::Parse($environment.createdOn)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
									$global:CreatedOn_TimeZ = ([DateTime]::Parse($environment.createdOn)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
								}
								if ($environment.modifiedOn) {
									$global:ModifiedOn_Time = ([DateTime]::Parse($environment.modifiedOn)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
									$global:ModifiedOn_TimeZ = ([DateTime]::Parse($environment.modifiedOn)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
								}

								if ($environment.queuedOn) {
									$global:Queued_Time = ([DateTime]::Parse($environment.queuedOn)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
									$global:Queued_TimeZ = ([DateTime]::Parse($environment.queuedOn)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
								}

								$environmentObject = New-Object ReleaseRecord

								$environmentObject.ReleaseKey = $tmpReleaseKey
								$environmentObject.PipelineID = $pipelineName.id
								$environmentObject.ReleaseID = $releaseId
								$environmentObject.EnvironmentID = $environment.id
								$environmentObject.PipelineName = $pipelineName.name
								$environmentObject.ReleaseName = $release.name
								$environmentObject.EnvironmentName = $environment.name
								$environmentObject.RecordType = "Environment"
								$environmentObject.Status = $environment.status
								$environmentObject.Tenant = $tenant
								$environmentObject.Project = $project
								$environmentObject.Reason = $release.Reason
								$environmentObject.Description = $release.Description
								$environmentObject.ModifiedBy = $tmpModifiedBy
								$environmentObject.CreatedBy = $tmpCreatedBy
								$environmentObject.VSTSlink = "$($projectUrl)/$($project)/_releaseProgress?releaseId=$($releaseId)"
								$environmentObject.Variables = $tmpVariables
								$environmentObject.ArtifactVersion = $artifactVersion

								$environmentErrorIssues = $null


								foreach ($deployStep in $environment.deploySteps) {

									if ($DEBUG) {
										$line = Get-CurrentLineNumber
										Write-Host $MyInvocation.ScriptName, $line, "deployStep.id", $deployStep.id, "deployStep.status", $deployStep.status
										$deployStep | ConvertTo-Json -Depth 100 | Out-File "$($homeFolder)\pipelineName.$($pipelineName.id).release.$($release.id)_environment.$($environment.id).deployStep.$($deployStep.id).json" -Encoding ascii
									}

									if (($deployStep.requestedFor.displayName -like "Microsoft.VisualStudio.Services.TFS") -or ($deployStep.requestedFor.displayName -like "Project Collection Build Service*")) {
										$tmpRequestedFor = $deployStep.requestedFor.displayName
									}
									else {
										$tmpRequestedFor = $deployStep.requestedFor.id
									}

									if (($deployStep.requestedBy.displayName -like "Microsoft.VisualStudio.Services.TFS") -or ($deployStep.requestedBy.displayName -like "Project Collection Build Service*")) {
										$tmpRequestedBy = $deployStep.requestedBy.displayName
									}
									else {
										$tmpRequestedBy = $deployStep.requestedBy.id
									}

									$tmpReleaseKey = [string]$pipelineName.id + "_" + `
										[string]$releaseId + "_" + `
										[string]$environment.id + "_" + `
										[string]$deployStep.id

									if ($deployStep.queuedOn) {
										$global:Queued_Time = ([DateTime]::Parse($deployStep.queuedOn)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
										$global:Queued_TimeZ = ([DateTime]::Parse($deployStep.queuedOn)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
									}

									$deployStepObject = New-Object ReleaseRecord

									$deployStepObject.ReleaseKey = $tmpReleaseKey
									$deployStepObject.PipelineID = $pipelineName.id
									$deployStepObject.ReleaseID = $releaseId
									$deployStepObject.EnvironmentID = $environment.id
									$deployStepObject.DeployStepID = $deployStep.id
									$deployStepObject.PipelineName = $pipelineName.name
									$deployStepObject.ReleaseName = $release.name
									$deployStepObject.EnvironmentName = $environment.name
									$deployStepObject.RecordType = "DeployStep"
									$deployStepObject.Status = $deployStep.status
									$deployStepObject.Attempt = $deployStep.attempt
									$deployStepObject.Tenant = $tenant
									$deployStepObject.Project = $project
									$deployStepObject.Reason = $deployStep.Reason
									$deployStepObject.Description = $release.Description
									$deployStepObject.ModifiedBy = $tmpModifiedBy
									$deployStepObject.CreatedBy = $tmpCreatedBy
									$deployStepObject.RequestedFor = $tmpRequestedFor
									$deployStepObject.RequestedBy = $tmpRequestedBy
									$deployStepObject.VSTSlink = "$($projectUrl)/$($project)/_releaseProgress?releaseId=$($releaseId)"
									$deployStepObject.Variables = $tmpVariables
									$deployStepObject.ArtifactVersion = $artifactVersion

									$deployStepErrorIssues = $null


									foreach ($releaseDeployPhase in $deployStep.releaseDeployPhases) {

										if ($DEBUG) {
											$line = Get-CurrentLineNumber
											Write-Host $MyInvocation.ScriptName, $line, "releaseDeployPhase.id", $releaseDeployPhase.id, "releaseDeployPhase.status", $releaseDeployPhase.status
											$releaseDeployPhase | ConvertTo-Json -Depth 100 | Out-File "$($homeFolder)\pipelineName.$($pipelineName.id).release.$($release.id)_environment.$($environment.id).deployStep.$($deployStep.id).releaseDeployPhase.$($releaseDeployPhase.id).json" -Encoding ascii
										}

										$tmpReleaseKey = [string]$pipelineName.id + "_" + `
											[string]$releaseId + "_" + `
											[string]$environment.id + "_" + `
											[string]$deployStep.id + "_" + `
											[string]$releaseDeployPhase.id

										if ($releaseDeployPhase.startedOn) {
											$global:StartedOn_Time = ([DateTime]::Parse($releaseDeployPhase.startedOn)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
											$global:StartedOn_TimeZ = ([DateTime]::Parse($releaseDeployPhase.startedOn)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
										}

										if ($releaseDeployPhase.queuedOn) {
											$global:Queued_Time = ([DateTime]::Parse($releaseDeployPhase.queuedOn)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
											$global:Queued_TimeZ = ([DateTime]::Parse($releaseDeployPhase.queuedOn)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
											if ($releaseObject.Queued_Time) {
												if ($global:Queued_Time -lt $releaseObject.Queued_Time) {
													$releaseObject.Queued_Time = $global:Queued_Time
													$releaseObject.Queued_TimeZ = $global:Queued_TimeZ
												}
											}
											else {
												$releaseObject.Queued_Time = $global:Queued_Time
												$releaseObject.Queued_TimeZ = $global:Queued_TimeZ
											}
										}

										$releaseDeployPhaseObject = New-Object ReleaseRecord

										$releaseDeployPhaseObject.ReleaseKey = $tmpReleaseKey
										$releaseDeployPhaseObject.PipelineID = $pipelineName.id
										$releaseDeployPhaseObject.ReleaseID = $releaseId
										$releaseDeployPhaseObject.EnvironmentID = $environment.id
										$releaseDeployPhaseObject.DeployStepID = $deployStep.id
										$releaseDeployPhaseObject.ReleaseDeployPhaseID = $releaseDeployPhase.id
										$releaseDeployPhaseObject.PipelineName = $pipelineName.name
										$releaseDeployPhaseObject.ReleaseName = $release.name
										$releaseDeployPhaseObject.EnvironmentName = $environment.name
										$releaseDeployPhaseObject.ReleaseDeployPhaseName = $releaseDeployPhase.name
										$releaseDeployPhaseObject.RecordType = "ReleaseDeployPhase"
										$releaseDeployPhaseObject.Status = $releaseDeployPhase.status
										$releaseDeployPhaseObject.Attempt = $deployStep.attempt
										$releaseDeployPhaseObject.Tenant = $tenant
										$releaseDeployPhaseObject.Project = $project
										$releaseDeployPhaseObject.Reason = $deployStep.Reason
										$releaseDeployPhaseObject.Description = $release.Description
										$releaseDeployPhaseObject.ModifiedBy = $tmpModifiedBy
										$releaseDeployPhaseObject.CreatedBy = $tmpCreatedBy
										$releaseDeployPhaseObject.RequestedFor = $tmpRequestedFor
										$releaseDeployPhaseObject.RequestedBy = $tmpRequestedBy
										$releaseDeployPhaseObject.VSTSlink = "$($projectUrl)/$($project)/_releaseProgress?releaseId=$($releaseId)"
										$releaseDeployPhaseObject.Variables = $tmpVariables
										$releaseDeployPhaseObject.ArtifactVersion = $artifactVersion

										$releaseDeployPhaseErrorIssues = $null


										foreach ($deploymentJob in $releaseDeployPhase.deploymentJobs) {

											if ($DEBUG) {
												$line = Get-CurrentLineNumber
												Write-Host $MyInvocation.ScriptName, $line, "deploymentJob.id", $deploymentJob.id, "deploymentJob.status", $deploymentJob.status
												$deploymentJob | ConvertTo-Json -Depth 100 | Out-File "$($homeFolder)\pipelineName.$($pipelineName.id).release.$($release.id)_environment.$($environment.id).deployStep.$($deployStep.id).releaseDeployPhase.$($releaseDeployPhase.id).deploymentJob.$($deploymentJob.job.ID).json" -Encoding ascii
											}

											$deploymentJobErrorIssues = $null

											foreach ($issue in $deploymentJob.job.issues) {
												if ($issue | Where-Object { $_.issueType -like "Error" }) {
													$errorIssues = $null
													if ($str1 = $issue.message) {
														$str2 = $str1.replace('\', '/')
														$str3 = $null
														foreach ($line in $str2) {
															$str3 += $line + "\n"
														}
														$str4 = $str3.Replace("`r`n", "\n")
														$str5 = $str4.Replace("`n", "\n")
														$str6 = $str5.Replace("`t", "	")
														$errorIssues = $str6.replace('"', "'")
													}
													$deploymentJobErrorIssues += $errorIssues
												}
											}

											$tmpReleaseKey = [string]$pipelineName.id + "_" + `
												[string]$releaseId + "_" + `
												[string]$environment.id + "_" + `
												[string]$deployStep.id + "_" + `
												[string]$releaseDeployPhase.id + "_" + `
												[string]$deploymentJob.job.id

											if ($deploymentJob.job.finishTime) {
												$global:Finish_Time = ([DateTime]::Parse($deploymentJob.job.finishTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
												$global:Finish_TimeZ = ([DateTime]::Parse($deploymentJob.job.finishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
												if ($releaseObject.Finish_Time) {
													if ($global:Finish_Time -gt $releaseObject.Finish_Time) {
														$releaseObject.Finish_Time = $global:Finish_Time
														$releaseObject.Finish_TimeZ = $global:Finish_TimeZ
													}
												}
												else {
													$releaseObject.Finish_Time = $global:Finish_Time
													$releaseObject.Finish_TimeZ = $global:Finish_TimeZ
												}
											}
											if ($deploymentJob.job.startTime) {
												$global:Start_Time = ([DateTime]::Parse($deploymentJob.job.startTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
												$global:Start_TimeZ = ([DateTime]::Parse($deploymentJob.job.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
												if ($releaseObject.Start_Time) {
													if ($global:Start_Time -lt $releaseObject.Start_Time) {
														$releaseObject.Start_Time = $global:Start_Time
														$releaseObject.Start_TimeZ = $global:Start_TimeZ
													}
												}
												else {
													$releaseObject.Start_Time = $global:Start_Time
													$releaseObject.Start_TimeZ = $global:Start_TimeZ
												}
											}

											$deploymentJobObject = New-Object ReleaseRecord

											$deploymentJobObject.ReleaseKey = $tmpReleaseKey
											$deploymentJobObject.PipelineID = $pipelineName.id
											$deploymentJobObject.ReleaseID = $releaseId
											$deploymentJobObject.EnvironmentID = $environment.id
											$deploymentJobObject.DeployStepID = $deployStep.id
											$deploymentJobObject.ReleaseDeployPhaseID = $releaseDeployPhase.id
											$deploymentJobObject.DeploymentJobID = $deploymentJob.job.id
											$deploymentJobObject.PipelineName = $pipelineName.name
											$deploymentJobObject.ReleaseName = $release.name
											$deploymentJobObject.EnvironmentName = $environment.name
											$deploymentJobObject.ReleaseDeployPhaseName = $releaseDeployPhase.name
											$deploymentJobObject.DeploymentJobName = $deploymentJob.job.name
											$deploymentJobObject.RecordType = "DeploymentJob"
											$deploymentJobObject.Status = $deploymentJob.job.status
											$deploymentJobObject.Attempt = $deployStep.attempt
											if ($deploymentJob.job.startTime -and $deploymentJob.job.finishTime) {
												$deploymentJobObject.Elapsed_Time = (New-TimeSpan -Start $deploymentJob.job.startTime -End $deploymentJob.job.finishTime).TotalMinutes
											}
											if ($deployStep.queuedOn -and $deploymentJob.job.startTime) {
												$deploymentJobObject.Wait_Time = (New-TimeSpan -Start $deployStep.queuedOn -End $deploymentJob.job.startTime).TotalMinutes
											}
											$deploymentJobObject.Tenant = $tenant
											$deploymentJobObject.Project = $project
											$deploymentJobObject.Reason = $release.Reason
											$deploymentJobObject.Agent = $deploymentJob.job.agentName
											$deploymentJobObject.Description = $release.Description
											$deploymentJobObject.ModifiedBy = $tmpModifiedBy
											$deploymentJobObject.CreatedBy = $tmpCreatedBy
											$deploymentJobObject.RequestedFor = $tmpRequestedFor
											$deploymentJobObject.RequestedBy = $tmpRequestedBy
											$deploymentJobObject.ErrorIssues = $deploymentJobErrorIssues
											$deploymentJobObject.VSTSlink = $deploymentJob.job.logurl
											$deploymentJobObject.Variables = $tmpVariables
											$deploymentJobObject.ArtifactVersion = $artifactVersion


											foreach ($task in $deploymentJob.tasks) {

												if ($DEBUG) {
													$line = Get-CurrentLineNumber
													Write-Host $MyInvocation.ScriptName, $line, "task.id", $task.id, "task.status", $task.status
													$task | ConvertTo-Json -Depth 100 | Out-File "$($homeFolder)\pipelineName.$($pipelineName.id).release.$($release.id)_environment.$($environment.id).deployStep.$($deployStep.id).releaseDeployPhase.$($releaseDeployPhase.id).deploymentJob.$($deploymentJob.job.ID).task.$($task.id).json" -Encoding ascii
												}

												$historyCount = 0

												$tmpReleaseKey = [string]$pipelineName.id + "_" + `
													[string]$releaseId + "_" + `
													[string]$environment.id + "_" + `
													[string]$deployStep.id + "_" + `
													[string]$releaseDeployPhase.id + "_" + `
													[string]$deploymentJob.job.id + "_" + `
													[string]$task.id + "_" + `
													[string]$historyCount

												while ($true) {
													if ($releaseInfoHash.ContainsKey($tmpReleaseKey)) {
														Write-Warning -Message "Duplicate ReleaseKey A - $tmpReleaseKey"
														Write-Host "##vso[task.logissue type=warning;] Duplicate ReleaseKey A - $tmpReleaseKey"
														$historyCount += 1
														$tmpReleaseKey = [string]$pipelineName.id + "_" + `
															[string]$releaseId + "_" + `
															[string]$environment.id + "_" + `
															[string]$deployStep.id + "_" + `
															[string]$releaseDeployPhase.id + "_" + `
															[string]$deploymentJob.job.id + "_" + `
															[string]$task.id + "_" + `
															[string]$historyCount
													}
													else {
														$releaseInfoHash.add($tmpReleaseKey, 1)
														break
													}
												}

												if ($task.startTime) {
													$global:Start_Time = ([DateTime]::Parse($task.startTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
													$global:Start_TimeZ = ([DateTime]::Parse($task.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
													if ($releaseObject.Start_Time) {
														if ($global:Start_Time -lt $releaseObject.Start_Time) {
															$releaseObject.Start_Time = $global:Start_Time
															$releaseObject.Start_TimeZ = $global:Start_TimeZ
														}
													}
													else {
														$releaseObject.Start_Time = $global:Start_Time
														$releaseObject.Start_TimeZ = $global:Start_TimeZ
													}
												}
												if ($task.finishTime) {
													$global:Finish_Time = ([DateTime]::Parse($task.finishTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
													$global:Finish_TimeZ = ([DateTime]::Parse($task.finishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
													if ($releaseObject.Finish_Time) {
														if ($global:Finish_Time -gt $releaseObject.Finish_Time) {
															$releaseObject.Finish_Time = $global:Finish_Time
															$releaseObject.Finish_TimeZ = $global:Finish_TimeZ
														}
													}
													else {
														$releaseObject.Finish_Time = $global:Finish_Time
														$releaseObject.Finish_TimeZ = $global:Finish_TimeZ
													}
												}

												$taskObject = New-Object ReleaseRecord

												$taskObject.ReleaseKey = $tmpReleaseKey
												$taskObject.PipelineID = $pipelineName.id
												$taskObject.ReleaseID = $releaseId
												$taskObject.EnvironmentID = $environment.id
												$taskObject.DeployStepID = $deployStep.id
												$taskObject.ReleaseDeployPhaseID = $releaseDeployPhase.id
												$taskObject.DeploymentJobID = $deploymentJob.job.id
												$taskObject.TaskID = $task.id
												$taskObject.PipelineName = $pipelineName.name
												$taskObject.ReleaseName = $release.name
												$taskObject.EnvironmentName = $environment.name
												$taskObject.ReleaseDeployPhaseName = $releaseDeployPhase.name
												$taskObject.DeploymentJobName = $deploymentJob.job.name
												$taskObject.TaskName = $task.name.replace('\', '\\')
												$taskObject.RecordType = "Task"
												$taskObject.Status = $task.status
												$taskObject.Attempt = $deployStep.attempt
												if ($task.startTime -and $deployStep.queuedOn) {
													$taskObject.Wait_Time = (New-TimeSpan -Start $deployStep.queuedOn -End $task.startTime).TotalMinutes
												}
												if ($task.finishTime -and $task.startTime) {
													$taskObject.Elapsed_Time = (New-TimeSpan -Start $task.startTime -End $task.finishTime).TotalMinutes
												}
												$taskObject.Tenant = $tenant
												$taskObject.Project = $project
												$taskObject.Reason = $release.Reason
												$taskObject.Agent = $task.agentName
												$taskObject.Description = $release.Description
												$taskObject.ModifiedBy = $tmpModifiedBy
												$taskObject.CreatedBy = $tmpCreatedBy
												$taskObject.RequestedFor = $tmpRequestedFor
												$taskObject.RequestedBy = $tmpRequestedBy
												$taskObject.VSTSlink = $task.logurl
												$taskObject.Variables = $tmpVariables
												$taskObject.ArtifactVersion = $artifactVersion

												$taskErrorIssues = $null
												$issueCount = 0

												foreach ($issue in $task.issues) {

													$issueCount += 1

													if ($DEBUG) {
														$line = Get-CurrentLineNumber
														Write-Host $MyInvocation.ScriptName, $line, "issue", $issueCount
													}

													if ($issue | Where-Object { $_.issueType -like "Error" }) {
														$issueErrorIssues = $null
														if ($str1 = $issue.message) {
															$str2 = $str1.replace('\', '/')
															$str3 = $null
															foreach ($line in $str2) {
																$str3 += $line + "\n"
															}
															$str4 = $str3.Replace("`r`n", "\n")
															$str5 = $str4.Replace("`n", "\n")
															$str6 = $str5.Replace("`t", "	")
															$issueErrorIssues = $str6.replace('"', "'")
														}

														$taskErrorIssues += $issueErrorIssues

														$historyCount = 0

														$tmpReleaseKey = [string]$pipelineName.id + "_" + `
															[string]$releaseId + "_" + `
															[string]$environment.id + "_" + `
															[string]$deployStep.id + "_" + `
															[string]$releaseDeployPhase.id + "_" + `
															[string]$deploymentJob.job.id + "_" + `
															[string]$task.id + "_" + `
															[string]$issueCount + "_" + `
															[string]$historyCount

														while ($true) {
															if ($releaseInfoHash.ContainsKey($tmpReleaseKey)) {
																Write-Warning -Message "Duplicate ReleaseKey B - $tmpReleaseKey"
																Write-Host "##vso[task.logissue type=warning;] Duplicate ReleaseKey B - $tmpReleaseKey"
																$historyCount += 1
																$tmpReleaseKey = [string]$pipelineName.id + "_" + `
																	[string]$releaseId + "_" + `
																	[string]$environment.id + "_" + `
																	[string]$deployStep.id + "_" + `
																	[string]$releaseDeployPhase.id + "_" + `
																	[string]$deploymentJob.job.id + "_" + `
																	[string]$task.id + "_" + `
																	[string]$issueCount + "_" + `
																	[string]$historyCount
															}
															else {
																$releaseInfoHash.add($tmpReleaseKey, 1)
																break
															}
														}

														$issueObject = New-Object ReleaseRecord

														$issueObject.ReleaseKey = $tmpReleaseKey
														$issueObject.PipelineID = $pipelineName.id
														$issueObject.ReleaseID = $releaseId
														$issueObject.EnvironmentID = $environment.id
														$issueObject.DeployStepID = $deployStep.id
														$issueObject.ReleaseDeployPhaseID = $releaseDeployPhase.id
														$issueObject.DeploymentJobID = $deploymentJob.job.id
														$issueObject.TaskID = $task.id
														$issueObject.PipelineName = $pipelineName.name
														$issueObject.ReleaseName = $release.name
														$issueObject.EnvironmentName = $environment.name
														$issueObject.ReleaseDeployPhaseName = $releaseDeployPhase.name
														$issueObject.DeploymentJobName = $deploymentJob.job.name
														$issueObject.TaskName = $task.name.replace('\', '\\')
														$issueObject.RecordType = "TaskErrorIssues"
														$issueObject.Status = $task.status
														$issueObject.Attempt = $deployStep.attempt
														$issueObject.IssueCount = $issueCount
														if ($task.startTime -and $deployStep.queuedOn) {
															$issueObject.Wait_Time = (New-TimeSpan -Start $deployStep.queuedOn -End $task.startTime).TotalMinutes
														}
														if ($task.finishTime -and $task.startTime) {
															$issueObject.Elapsed_Time = (New-TimeSpan -Start $task.startTime -End $task.finishTime).TotalMinutes
														}
														$issueObject.Tenant = $tenant
														$issueObject.Project = $project
														$issueObject.Reason = $release.Reason
														$issueObject.Agent = $task.agentName
														$issueObject.Description = $release.Description
														$issueObject.ModifiedBy = $tmpModifiedBy
														$issueObject.CreatedBy = $tmpCreatedBy
														$issueObject.RequestedFor = $tmpRequestedFor
														$issueObject.RequestedBy = $tmpRequestedBy
														$issueObject.VSTSlink = $task.logurl
														$issueObject.Variables = $tmpVariables
														$issueObject.ArtifactVersion = $artifactVersion
														$issueObject.ErrorIssues = makeUnique($issueErrorIssues)

														$null = $releaseInfoTable.Add($issueObject)

														$taskErrorIssues += makeUnique($issueErrorIssues)
													}
												}
												$taskObject.ErrorIssues = makeUnique($taskErrorIssues)
												$null = $releaseInfoTable.Add($taskObject)

												$deploymentJobErrorIssues += $taskErrorIssues
											}
											$deploymentJobObject.ErrorIssues = makeUnique($deploymentJobErrorIssues)
											$null = $releaseInfoTable.Add($deploymentJobObject)

											$releaseDeployPhaseErrorIssues += $deploymentJobErrorIssues
										}
										$releaseDeployPhaseObject.ErrorIssues = makeUnique($releaseDeployPhaseErrorIssues)
										$null = $releaseInfoTable.Add($releaseDeployPhaseObject)

										$deployStepErrorIssues += $releaseDeployPhaseErrorIssues
									}
									$deployStepObject.ErrorIssues = makeUnique($deployStepErrorIssues)
									$null = $releaseInfoTable.Add($deployStepObject)

									$environmentErrorIssues += $deployStepErrorIssues
								}
								$environmentObject.ErrorIssues = makeUnique($environmentErrorIssues)
								$null = $releaseInfoTable.Add($environmentObject)

								$releaseErrorIssues += $environmentErrorIssues
							}

							if ($releaseObject.Start_Time -and $releaseObject.Finish_Time) {
								$releaseObject.Elapsed_Time = (New-TimeSpan -Start $releaseObject.Start_Time -End $releaseObject.Finish_Time).TotalMinutes
							}

							$releaseObject.ErrorIssues = makeUnique($releaseErrorIssues)
							$null = $releaseInfoTable.Add($releaseObject)
						}
					}
				}
			}
		}
	}


	#--- Patch some names in the table

	for ($i = 0 ; $i -lt $releaseInfoTable.count ; $i++) {
		if ($releaseInfoTable[$i].PipelineID -like "276" -or $releaseInfoTable[$i].PipelineID -like "303" -or $releaseInfoTable[$i].PipelineID -like "306" -or $releaseInfoTable[$i].PipelineID -like "302") {
			if ($releaseInfoTable[$i].ReleaseDeployPhaseName -like "Run Tasks") {
				if ($releaseInfoTable[$i].EnvironmentName -like "Test: Unit Tests") {
					$releaseInfoTable[$i].ReleaseDeployPhaseName = "Run Unit Test Tasks"
				}
				if ($releaseInfoTable[$i].EnvironmentName -like "Test: UI Tests") {
					$releaseInfoTable[$i].ReleaseDeployPhaseName = "Run UI Test Tasks"
				}
			}
		}
	}


	if ($DEBUG) {
		$releaseInfoTable | ConvertTo-Csv -NoTypeInformation | Out-File "$($homeFolder)\release_$(Get-Random).csv" -Encoding ascii
	}


	Write-Host "Uploading to DBs..."

	foreach ($inProgressStr in "inProgress", "pending") {
		Write-Host "Deleting previous", $inProgressStr, "data..."
		while ($true) {
			$esString = @"
{"query": { "match": {"Status":"$inProgressStr"}}}

"@
			$ids = (Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/$($strElasticSearchIndex)/_search?size=1000 -Method POST -Body $esString -ContentType "application/json").hits.hits._id
			if ($ids) {
				$esString = $null
				foreach ($id in $ids) {

					$esString += @"
{"delete": {"_index": "$($strElasticSearchIndex)","_type": "_doc","_id": "$($id)"}}

"@
				}
				if ($esString) {
					Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
				}
			}
			else {
				break
			}
		}
		if ($updateSQL) {
			$sqlStringTmp = @"
DELETE FROM [dbo].[$($strElasticSearchIndex)]
WHERE [Status] = '$($inProgressStr)'
GO
"@
			try {
				Invoke-Sqlcmd $sqlStringTmp -ConnectionString "$($strSqlConnectionString)" -QueryTimeout 300
			}
			catch {
				Write-Host "WARNING: Deleting from SQL $($inProgressStr)"
			}
		}
	}


	$esString = $null
	$esStringBuilder = New-Object System.Text.StringBuilder(1024000)

	$sqlStringInsertBuilder = New-Object System.Text.StringBuilder(7000 * $($intSqlBatchSize))
	$sqlStringDeleteBuilder = New-Object System.Text.StringBuilder(150 * $($intSqlBatchSize))

	foreach ($line in $releaseInfoTable) {

		if ($deletePreviousElasticRecord) {
			$tmpString = @"
{
	"delete": {
		"_index": "$($strElasticSearchIndex)",
		"_type": "_doc",
		"_id": "$($line.ReleaseKey)"
	}
}
"@
			$esString = $tmpString | ConvertFrom-Json | ConvertTo-Json -Compress
			$esString += "`n"
			$null = $esStringBuilder.Append($esString)
		}

		$tmpString = @"
{
	"create": {
		"_index": "$($strElasticSearchIndex)",
		"_type": "_doc",
		"_id": "$($line.ReleaseKey)"
	}
}
"@
		$esString = $tmpString | ConvertFrom-Json | ConvertTo-Json -Compress
		$esString += "`n"
		$null = $esStringBuilder.Append($esString)

		$tmpString = @"
{
	"Agent": "$($line.Agent)",
	"Attempt": "$($line.Attempt)",
	"ArtifactVersion": "$($line.ArtifactVersion)",
	"CreatedBy": "$($line.CreatedBy)",
	"DeploymentJobID": "$($line.DeploymentJobID)",
	"DeploymentJobName": "$($line.DeploymentJobName)",
	"DeployStepID": "$($line.DeployStepID)",
	"Description": "$($line.Description)",
	"EnvironmentID": "$($line.EnvironmentID)",
	"EnvironmentName": "$($line.EnvironmentName)",
	"ErrorIssues": "$($line.ErrorIssues)",
	"IssueCount": "$($line.IssueCount)",
	"ModifiedBy": "$($line.ModifiedBy)",
	"PipelineID": "$($line.PipelineID)",
	"Tenant": "$($line.Tenant)",
	"Project": "$($line.Project)",
	"Reason": "$($line.Reason)",
	"RecordType": "$($line.RecordType)",
	"PipelineName": "$($line.PipelineName)",
	"ReleaseDeployPhaseID": "$($line.ReleaseDeployPhaseID)",
	"ReleaseDeployPhaseName": "$($line.ReleaseDeployPhaseName)",
	"ReleaseID": "$($line.ReleaseID)",
	"ReleaseKey": "$($line.ReleaseKey)",
	"ReleaseName": "$($line.ReleaseName)",
	"RequestedBy": "$($line.RequestedBy)",
	"RequestedFor": "$($line.RequestedFor)",
	"Status": "$($line.Status)",
	"TaskID": "$($line.TaskID)",
	"TaskName": "$($line.TaskName)",
	"Variables": "$($line.Variables)",
	"VSTSlink": "$($line.VSTSlink)",
	"Wait_Time": "$($line.Wait_Time)",
	"Elapsed_Time": "$($line.Elapsed_Time)"
"@

		if ($line.CreatedOn_TimeZ) {
			$tmpString += @"
,"CreatedOn_Time":"$($line.CreatedOn_TimeZ)"
"@
		}

		if ($line.Finish_TimeZ) {
			$tmpString += @"
,"Finish_Time":"$($line.Finish_TimeZ)"
"@
		}
		if ($line.ModifiedOn_TimeZ) {
			$tmpString += @"
,"ModifiedOn_Time":"$($line.ModifiedOn_TimeZ)"
"@
		}
		if ($line.Queued_TimeZ) {
			$tmpString += @"
,"Queued_Time":"$($line.Queued_TimeZ)"
"@
		}
		if ($line.Start_TimeZ) {
			$tmpString += @"
,"Start_Time":"$($line.Start_TimeZ)"
"@
		}

		$tmpString += @"
}

"@

		$esString = $tmpString | ConvertFrom-Json | ConvertTo-Json -Compress
		$esString += "`n"
		$null = $esStringBuilder.Append($esString)

		if ($deletePreviousSQLrecord) {
			$sqlStringTmp = @"
DELETE from $($strSqlTable)
WHERE Build_Key='$($line.BuildKey)';
GO

"@
			$null = $sqlStringDeleteBuilder.Append($sqlStringTmp)
		}

		$tmpVariables = $line.Variables -replace "'", '"' -replace '\$\(', '\('
		$tmpDemands = $line.Demands -replace "'", '"' -replace '\$\(', '\('
		$tmpErrorIssues = $line.ErrorIssues -replace "'", '"' -replace '\$\(', '\('
		$tmpBuildJob = $line.BuildJob -replace '\$\(', '\(' -replace "'", '"'

		$sqlStringTmp = @"
INSERT INTO $($strSqlTable) (
	Build_Key,
	BuildID,
	TimeLineID,
	ParentID,
	RecordType,
	Tenant,
	Project,
	BuildDefID,
	BuildDef,
	Quality,
	BuildNumber,
	BuildJob,
	Finished,
	Compile_Status,
	Queue_Time,
	Start_Time,
	Finish_Time,
	Wait_Time,
	Elapsed_Time,
	Agent,
	Agent_Pool,
	Reason,
	RequestedFor,
	URL,
	SourceRepo,
	SourceBranch,
	SourceGetVersion,
	Variables,
	Demands,
	Error_Issues
)
VALUES (
	'$($line.BuildKey)',
	'$($line.BuildID)',
	'$($line.TimeLineID)',
	'$($line.ParentID)',
	'$($line.RecordType)',
	'$($line.Tenant)',
	'$($line.Project)',
	'$($line.BuildDefID)',
	'$($line.BuildDef)',
	'$($line.Quality)',
	'$($line.BuildNumber)',
	'$($tmpBuildJob)',
	'$($line.Finished)',
	'$($line.Compile_Status)',
	'$($line.Queue_Time)',
	'$($line.Start_Time)',
	'$($line.Finish_Time)',
	'$($line.Wait_Time)',
	'$($line.Elapsed_Time)',
	'$($line.Agent)',
	'$($line.Agent_Pool)',
	'$($line.Reason)',
	'$($line.RequestedFor)',
	'$($line.URL)',
	'$($line.SourceRepo)',
	'$($line.SourceBranch)',
	'$($line.SourceGetVersion)',
	'($($tmpVariables)',
	'($($tmpDemands)',
	N'$($tmpErrorIssues)'
)
GO

"@
		$null = $sqlStringInsertBuilder.Append($sqlStringTmp)

		if (!($releaseInfoTable.IndexOf($line) % 1000)) {
			if ($updateElastic) {
				$esString = $esStringBuilder.ToString()
				try {
					$result = Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
					$result
				}
				catch {
					Write-Warning "Errors writing to ES - Bulk Mode 1"
					Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Bulk Mode"
				}
				if ($result.errors) {
					Write-Warning "Errors writing to ES - Bulk Mode 2"
					Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Bulk Mode"
					foreach ($resultItem in $result.items) {
						if ($resultItem.create.error) {
							$resultItem.create.error | ConvertTo-Json -Depth 100
						}
					}
					Write-Warning "Attempting to narrow down the error..."
					Write-Host "##vso[task.logissue type=warning;] Attempting to narrow down the error..."
					$tmpBody = $null
					foreach ($esStringItem in $esString.split("`n")) {
						if ($esStringItem.split(":")[0] -like "*delete*") {
							$tmpBody += $esStringItem + "`n"
						}
						if ($esStringItem.split(":")[0] -like "*create*") {
							$tmpBody += $esStringItem + "`n"
						}
						if ($esStringItem.split(":")[0] -like "*ReleaseKey*") {
							$tmpBody += $esStringItem + "`n`n"

							try {
								$result2 = Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
								$result2
							}
							catch {
								Write-Warning "Errors writing to ES - Single Mode"
								Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Single Mode"
							}
							if ($result2.errors) {
								Write-Warning "Errors writing to ES - Single Mode"
								Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Single Mode"
								foreach ($result2Item in $result2.items) {
									if ($result2Item.create.error) {
										$result2Item.create.error | ConvertTo-Json -Depth 100
									}
								}
								$tmpBody
							}
							$tmpBody = $null
						}
					}
				}
			}
			$esString = $null
			$null = $esStringBuilder.clear()
			$esStringBuilder = New-Object System.Text.StringBuilder(2048000)
			if ($updateSQL) {
				if ($sqlStringDeleteBuilder.length) {
					$sqlStringTmp = $sqlStringDeleteBuilder.ToString()
					try {
						Invoke-Sqlcmd $sqlStringTmp -ConnectionString "$($strSqlConnectionString)"  -QueryTimeout 300
					}
					catch {
						Write-Host "WARNING: Deleting from SQL 1"
					}
				}
				if ($sqlStringInsertBuilder.length) {
					$sqlStringTmp = $sqlStringInsertBuilder.ToString()
					try {
						Invoke-Sqlcmd $sqlStringTmp -ConnectionString "$($strSqlConnectionString)"  -QueryTimeout 300
					}
					catch {
						Write-Host "ERROR: writing to SQL 1"
					}
				}
				$sqlStringTmp = $null
				$null = $sqlStringInsertBuilder.clear()
				$null = $sqlStringDeleteBuilder.clear()
			}
		}
	}

	if ($updateElastic) {
		if ($esStringBuilder.length) {
			$esString = $esStringBuilder.ToString()

			try {
				Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
				$result
			}
			catch {
				Write-Warning "Errors writing to ES - Bulk Mode"
				Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Bulk Mode"
			}
			if ($result.errors) {
				Write-Warning "Errors writing to ES - Bulk Mode"
				Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Bulk Mode"
				foreach ($resultItem in $result.items) {
					if ($resultItem.create.error) {
						$resultItem.create.error | ConvertTo-Json -Depth 100
					}
				}
				Write-Warning "Attempting to narrow down the error..."
				Write-Host "##vso[task.logissue type=warning;] Attempting to narrow down the error..."
				$tmpBody = $null
				foreach ($esStringItem in $esString.split("`n")) {
					if ($esStringItem.split(":")[0] -like "*delete*") {
						$tmpBody += $esStringItem + "`n"
					}
					if ($esStringItem.split(":")[0] -like "*create*") {
						$tmpBody += $esStringItem + "`n"
					}
					if ($esStringItem.split(":")[0] -like "*ReleaseKey*") {
						$tmpBody += $esStringItem + "`n`n"

						try {
							$result2 = Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
							$result2
						}
						catch {
							Write-Warning "Errors writing to ES - Single Mode"
							Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Single Mode"
						}
						if ($result2.errors) {
							Write-Warning "Errors writing to ES - Single Mode"
							Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Single Mode"
							foreach ($result2Item in $result2.items) {
								if ($result2Item.create.error) {
									$result2Item.create.error | ConvertTo-Json -Depth 100
								}
							}
							$tmpBody
						}
						$tmpBody = $null
					}
				}
			}
			$esString = $null
			$null = $esStringBuilder.clear()
		}
	}


	if ($updateElastic -and $updateLastRunTime) {
		Write-Host "Updating LastRunTime time stamps..."
		$esString = @"
{"delete": {"_index": "timestamp","_type": "_doc","_id": "$($strElasticSearchIndex)"}}
{"create": {"_index": "timestamp","_type": "_doc","_id": "$($strElasticSearchIndex)"}}
{"ID": "$($strElasticSearchIndex)","LastRunTime": "$($thisRunDateTime)"}

"@
		try {
			Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
		}
		catch {
			Write-Host "ERROR: updating LastRunTime"
			$esString
		}
	}
}

main

