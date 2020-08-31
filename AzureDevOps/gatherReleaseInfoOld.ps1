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
    [string]$PATSJSON = $null
)


function main {

	$scriptPath = Split-Path $script:MyInvocation.MyCommand.Path
	$scriptPath
	. "$($scriptPath)\gatherIncludes.ps1"

	$progressPreference = 'silentlyContinue'
	$thisRunDateTime = (get-date).ToUniversalTime()
	
	$collection = "https://microsoft.vsrm.visualstudio.com"
	
# --- Set some defaults

	if (!($projectUrl = $ENV:SYSTEM_TEAMFOUNDATIONSERVERURI)) {
		$projectUrl = "https://microsoft.visualstudio.com"
	}
	
# --- Override defaults with settings string

	loadConfiguration
	
	# --- override locally
	
	$strElasticSearchIndex = "releaseinfo"
	
	if (!($minutesBack = $ENV:minutesBack)) {
		try {
			$tmp = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/timestamp/data/$($strElasticSearchIndex)
			$lastRunDateTime = [datetime]([string]$tmp._source.LastRunTime)
			write-host "INFO: last run was at" $lastRunDateTime
			$minutesBack = (new-TimeSpan -start $thisRunDateTime -end $lastRunDateTime).TotalMinutes
		}
		catch {
			$minutesBack = -200
		}
	}
	
	$minutesBack = $minutesBack - 1440
	
	$strStartDate = (get-date).AddMinutes($minutesBack).ToUniversalTime()
	
	write-host "INFO: using minutesBack of" $minutesBack "and strStartDate" $strStartDate
	
	$personalAccessToken = $ENV:PAT
	$OAuthToken = $ENV:System_AccessToken
	
	if ($OAuthToken) {
		$headers = @{Authorization = ("Bearer {0}" -f $OAuthToken)}
	} elseif ($personalAccessToken) {
		$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($personalAccessToken)"))}
	} else {
		write-error "Neither personalAccessToken nor OAuthToken are set"
	}
	
	if ($DEBUG) {
		get-variable | format-table Name, Value
	}
	
	getTheReleases
	
	exit 0
}

function Get-CurrentLineNumber { 
    $MyInvocation.ScriptLineNumber 
}


function getTheReleases {
		
	$releaseInfoTable = @()
	$releaseInfoHash = @{}
	
	if ($jsonConfiguration.projects.name) {
		write-host "Using projects from jsonConfiguration"
		$strProjects = $jsonConfiguration.projects.name
	}
	
	foreach ($project in $strProjects) {
	
		$project
		
		$projectUrl = $collection + "/" + $project
		
		if (($jsonConfiguration.projects | where {$_.name -like "$($project)"}).releasepipelines) {
			write-host "Using definitions from jsonConfiguration"
			$strDefinitions = ($jsonConfiguration.projects | ? {$_.name -like "$($project)"}).releasepipelines
		}
		
		foreach ($definition in $strDefinitions) {
		
			$line = Get-CurrentLineNumber
			write-host $MyInvocation.ScriptName, $line, $definition
			
			$line = Get-CurrentLineNumber
			write-host $MyInvocation.ScriptName, $line, "$projectUrl/_apis/release/definitions"
			
			$releaseDefs = (Invoke-RestMethod "$projectUrl/_apis/release/definitions" -Headers $headers).value | where {$_.name -like "$($definition)*"}
			
			foreach ($releaseDef in $releaseDefs) {
			
				if ($DEBUG) {
					$releaseDef | ConvertTo-json -depth 100 | out-file "$($homeFolder)\releaseDef.$($releaseDef.id).json" -encoding ascii
				}
			
				$line = Get-CurrentLineNumber
				write-host $MyInvocation.ScriptName, $line, $releaseDef.name

				# $releases = Invoke-RestMethod "$projectUrl/_apis/release/releases?api-version=4.1-preview.6&definitionId=$($releaseDef.id)&releaseCount=100" -Headers $headers
				
				$line = Get-CurrentLineNumber
				write-host $MyInvocation.ScriptName, $line, "$projectUrl/_apis/release/releases?api-version=4.1-preview.6&definitionId=$($releaseDef.id)&minCreatedTime=$($strStartDate.ToString())"
				$releases = Invoke-RestMethod "$projectUrl/_apis/release/releases?api-version=4.1-preview.6&definitionId=$($releaseDef.id)&minCreatedTime=$($strStartDate.ToString())" -Headers $headers

				# "$projectUrl/_apis/release/releases?definitionId=$($releaseDef.id)&minCreatedTime=$($strStartDate.ToString())"
				
				foreach ($release in $releases.value) {
				
					if ($DEBUG) {
						$line = Get-CurrentLineNumber
						write-host $MyInvocation.ScriptName, $line, "release.name", $release.name, "release.status", $release.status
						$release | ConvertTo-json -depth 100 | out-file "$($homeFolder)\release.$($release.id).json" -encoding ascii
					}
				
					foreach ($releaseId in $release.id) {
					
						$line = Get-CurrentLineNumber
						write-host $MyInvocation.ScriptName, $line, "$projectUrl/_apis/release/releases/$($releaseId)?api-version=4.1-preview.6"
						
						foreach ($release2 in Invoke-RestMethod "$projectUrl/_apis/release/releases/$($releaseId)?api-version=4.1-preview.6" -Headers $headers) {
						
							if ($DEBUG) {
								$line = Get-CurrentLineNumber
								write-host $MyInvocation.ScriptName, $line, "release2.name", $release2.name, "release2.status", $release2.status
								$release2 | ConvertTo-json -depth 100 | out-file "$($homeFolder)\release2.$($release2.id).json" -encoding ascii
							}
							
							foreach ($environment in $release2.environments) {
							
								if (!($environment.status -like "inProgress")) {
								
									if ($DEBUG) {
										$line = Get-CurrentLineNumber
										write-host $MyInvocation.ScriptName, $line, "environment.id", $environment.id, "environment.status", $environment.status
										$environment | ConvertTo-json -depth 100 | out-file "$($homeFolder)\release2.$($release2.id)_environment.$($environment.id).json" -encoding ascii
									}
														
									foreach ($deployStep in $environment.deploySteps) {
									
										if (!($deployStep.status -like "inProgress")) {
									
											if ($DEBUG) {
												$line = Get-CurrentLineNumber
												write-host $MyInvocation.ScriptName, $line, "deployStep.id", $deployStep.id, "deployStep.status", $deployStep.status
												$deployStep | ConvertTo-json -depth 100 | out-file "$($homeFolder)\deployStep_$($deployStep.id).json" -encoding ascii
											}
										
											if (($deployStep.requestedFor.displayName -like "Microsoft.VisualStudio.Services.TFS") -or ($deployStep.requestedFor.displayName -like "Project Collection Build Service*")) {
												$tmpRequestedFor = $deployStep.requestedFor.displayName
											} else {
												$tmpRequestedFor = $deployStep.requestedFor.id
											}
											
											if (($deployStep.requestedBy.displayName -like "Microsoft.VisualStudio.Services.TFS") -or ($deployStep.requestedBy.displayName -like "Project Collection Build Service*")) {
												$tmpRequestedBy = $deployStep.requestedBy.displayName
											} else {
												$tmpRequestedBy = $deployStep.requestedBy.id
											}
											
											$tmpAttempt = $deployStep.attempt
														
											foreach ($releaseDeployPhase in $deployStep.releaseDeployPhases) {
											
												if ($DEBUG) {
													$line = Get-CurrentLineNumber
													write-host $MyInvocation.ScriptName, $line, "releaseDeployPhase.id", $releaseDeployPhase.id, "releaseDeployPhase.status", $releaseDeployPhase.status
												}
											
												foreach ($deploymentJob in $releaseDeployPhase.deploymentJobs) {
												
													if ($DEBUG) {
														$line = Get-CurrentLineNumber
														write-host $MyInvocation.ScriptName, $line, "deploymentJob.id", $deploymentJob.id, "deploymentJob.status", $deploymentJob.status
													}
												
													if (!($deploymentJob.job.status -like "inProgress")) {
													
														$tmpReleaseErrorIssues = ""
														$tmpReleaseStatus = $deploymentJob.job.status
														
														foreach ($issue in $deploymentJob.job.issues) {
															if ($issue | where {$_.issueType -like "Error"}) {
																$errorIssues = ""
																if ($str1 = $issue.message) {
																	$str2 = $str1.replace('\','/')
																	$str3 = ""
																	foreach ($line in $str2) {
																		$str3 += $line + "\n"
																	}
																	$str4 = $str3.Replace("`r`n","\n")
																	$str5 = $str4.Replace("`n","\n")
																	$str6 = $str5.Replace("`t","    ")
																	$errorIssues = $str6.replace('"',"'")
																}
																$tmpReleaseErrorIssues +=$errorIssues
															}
														}
												
														foreach ($task in $deploymentJob.tasks) {
														
															if ($DEBUG) {
																$line = Get-CurrentLineNumber
																write-host $MyInvocation.ScriptName, $line, "task.id", $task.id, "task.status", $task.status
															}
														
															$issueCount = 0
															$historyCount = 0
															$tmpReleaseStatus = "succeeded"
															$tmpReleaseStatus = $task.status
															
															$tmpReleaseKey = [string]$releaseDef.id + "_" + `
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
																	write-warning -message "Duplicate ReleaseKey - $tmpReleaseKey"
																	Write-Host "##vso[task.logissue type=warning;] Duplicate ReleaseKey - $tmpReleaseKey"
																	$historyCount += 1
																	$tmpReleaseKey = [string]$releaseDef.id + "_" + `
																					[string]$releaseId + "_" + `
																					[string]$environment.id + "_" + `
																					[string]$deployStep.id + "_" + `
																					[string]$releaseDeployPhase.id + "_" + `
																					[string]$deploymentJob.job.id + "_" + `
																					[string]$task.id + "_" + `
																					[string]$issueCount + "_" + `
																					[string]$historyCount
																} else {
																	$releaseInfoHash.add($tmpReleaseKey,1)
																	break
																}
															}
																	
															$tmpobjectRelease = new-object PSObject

															$tmpobjectRelease | Add-Member NoteProperty ReleaseKey             $tmpReleaseKey
															$tmpobjectRelease | Add-Member NoteProperty PipelineID             $releaseDef.id
															$tmpobjectRelease | Add-Member NoteProperty ReleaseID              $releaseId
															$tmpobjectRelease | Add-Member NoteProperty EnvironmentID          $environment.id
															$tmpobjectRelease | Add-Member NoteProperty DeployStepID           $deployStep.id
															$tmpobjectRelease | Add-Member NoteProperty ReleaseDeployPhaseID   $releaseDeployPhase.id
															$tmpobjectRelease | Add-Member NoteProperty DeploymentJobID        $deploymentJob.job.id
															$tmpobjectRelease | Add-Member NoteProperty TaskID                 $task.id
															$tmpobjectRelease | Add-Member NoteProperty IssueCount             $issueCount
															$tmpobjectRelease | Add-Member NoteProperty Attempt                $tmpAttempt
															$tmpobjectRelease | Add-Member NoteProperty ReleaseDef             $releaseDef.name
															$tmpobjectRelease | Add-Member NoteProperty ReleaseName            $release2.name
															$tmpobjectRelease | Add-Member NoteProperty EnvironmentName        $environment.name
															$tmpobjectRelease | Add-Member NoteProperty DeployStepName         $deployStep.name
															$tmpobjectRelease | Add-Member NoteProperty ReleaseDeployPhaseName $releaseDeployPhase.name
															$tmpobjectRelease | Add-Member NoteProperty DeploymentJobName      $deploymentJob.job.name
															$tmpobjectRelease | Add-Member NoteProperty TaskName               $task.name.replace('\','\\')
															$tmpobjectRelease | Add-Member NoteProperty RecordType             "Release"
															$tmpobjectRelease | Add-Member NoteProperty Start_Time             ([DateTime]::Parse($task.startTime)).toString("MM/dd/yyyy HH:mm:ss")
															if ($task.finishTime) {
																$tmpobjectRelease | Add-Member NoteProperty Finish_Time        ([DateTime]::Parse($task.finishTime)).toString("MM/dd/yyyy HH:mm:ss")
																$tmpobjectRelease | Add-Member NoteProperty Finish_TimeZ       ([DateTime]::Parse($task.finishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
																$tmpobjectRelease | Add-Member NoteProperty Elapsed_Time       (new-TimeSpan -start $task.startTime -end $task.finishTime).TotalMinutes
															} else {
																$tmpobjectRelease | Add-Member NoteProperty Elapsed_Time       0
															}
															$tmpobjectRelease | Add-Member NoteProperty Start_TimeZ            ([DateTime]::Parse($task.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
															if ($deployStep.queuedOn) {
																$tmpobjectRelease | Add-Member NoteProperty Queue_Time         ([DateTime]::Parse($deployStep.queuedOn)).toString("MM/dd/yyyy HH:mm:ss")
																$tmpobjectRelease | Add-Member NoteProperty Queue_TimeZ        ([DateTime]::Parse($deployStep.queuedOn)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
																$tmpobjectRelease | Add-Member NoteProperty Wait_Time          (new-TimeSpan -start $deployStep.queuedOn -end $task.startTime).TotalMinutes
															} else {
																$tmpobjectRelease | Add-Member NoteProperty Queue_Time         $null
																$tmpobjectRelease | Add-Member NoteProperty Queue_TimeZ        $null
																$tmpobjectRelease | Add-Member NoteProperty Wait_Time          $null
															}
															
															$tmpobjectRelease | Add-Member NoteProperty Project             $project
															$tmpobjectRelease | Add-Member NoteProperty Agent               $deploymentJob.job.agentname
															$tmpobjectRelease | Add-Member NoteProperty Reason              $release2.Reason
															$tmpobjectRelease | Add-Member NoteProperty Description         $release2.Description
															$tmpobjectRelease | Add-Member NoteProperty RequestedFor        $tmpRequestedFor
															$tmpobjectRelease | Add-Member NoteProperty RequestedBy         $tmpRequestedBy
															$tmpobjectRelease | Add-Member NoteProperty VSTSlink            "https://microsoft.visualstudio.com/Apps/_releaseProgress?releaseId=$($releaseId)&_a=release-environment-logs&environmentId=$($environment.id)"
															
															
															
															
															foreach ($issue in $task.issues) {
															
																$issueCount += 1

																if ($DEBUG) {
																	$line = Get-CurrentLineNumber
																	write-host $MyInvocation.ScriptName, $line, "issue", $issueCount
																}
																
																if ($issue | where {$_.issueType -like "Error"}) {
																	$errorIssues = ""
																	if ($str1 = $issue.message) {
																		$str2 = $str1.replace('\','/')
																		$str3 = ""
																		foreach ($line in $str2) {
																			$str3 += $line + "\n"
																		}
																		$str4 = $str3.Replace("`r`n","\n")
																		$str5 = $str4.Replace("`n","\n")
																		$str6 = $str5.Replace("`t","    ")
																		$errorIssues = $str6.replace('"',"'")
																	}
<#
																	if ($errorissues) {
																		$tmpReleaseStatus = "failed"
																		$tmpReleaseStatus = $task.status
																	}
#>
																	
																	$historyCount = 0
																	
																	$tmpReleaseKey = [string]$releaseDef.id + "_" + `
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
																			write-warning -message "Duplicate ReleaseKey - $tmpReleaseKey"
																			Write-Host "##vso[task.logissue type=warning;] Duplicate ReleaseKey - $tmpReleaseKey"
																			$historyCount += 1
																			$tmpReleaseKey = [string]$releaseDef.id + "_" + `
																							[string]$releaseId + "_" + `
																							[string]$environment.id + "_" + `
																							[string]$deployStep.id + "_" + `
																							[string]$releaseDeployPhase.id + "_" + `
																							[string]$deploymentJob.job.id + "_" + `
																							[string]$task.id + "_" + `
																							[string]$issueCount + "_" + `
																							[string]$historyCount
																		} else {
																			$releaseInfoHash.add($tmpReleaseKey,1)
																			break
																		}
																	}
																	
																	$tmpObjectTask = new-object PSObject

																	$tmpObjectTask | Add-Member NoteProperty ReleaseKey             $tmpReleaseKey
																	$tmpObjectTask | Add-Member NoteProperty PipelineID             $releaseDef.id
																	$tmpObjectTask | Add-Member NoteProperty ReleaseID              $releaseId
																	$tmpObjectTask | Add-Member NoteProperty EnvironmentID          $environment.id
																	$tmpObjectTask | Add-Member NoteProperty DeployStepID           $deployStep.id
																	$tmpObjectTask | Add-Member NoteProperty ReleaseDeployPhaseID   $releaseDeployPhase.id
																	$tmpObjectTask | Add-Member NoteProperty DeploymentJobID        $deploymentJob.job.id
																	$tmpObjectTask | Add-Member NoteProperty TaskID                 $task.id
																	$tmpObjectTask | Add-Member NoteProperty IssueCount             $issueCount
																	$tmpObjectTask | Add-Member NoteProperty Attempt                $tmpAttempt
																	$tmpObjectTask | Add-Member NoteProperty ReleaseDef             $releaseDef.name
																	$tmpObjectTask | Add-Member NoteProperty ReleaseName            $release2.name
																	$tmpObjectTask | Add-Member NoteProperty EnvironmentName        $environment.name
																	$tmpObjectTask | Add-Member NoteProperty DeployStepName         $deployStep.name
																	$tmpObjectTask | Add-Member NoteProperty ReleaseDeployPhaseName $releaseDeployPhase.name
																	$tmpObjectTask | Add-Member NoteProperty DeploymentJobName      $deploymentJob.job.name
																	$tmpObjectTask | Add-Member NoteProperty TaskName               $task.name.replace('\','\\')
																	$tmpObjectTask | Add-Member NoteProperty RecordType             "Task"
																	$tmpObjectTask | Add-Member NoteProperty Status                 $task.status            
																	$tmpObjectTask | Add-Member NoteProperty Start_Time             ([DateTime]::Parse($task.startTime)).toString("MM/dd/yyyy HH:mm:ss")
																	$tmpObjectTask | Add-Member NoteProperty Finish_Time            ([DateTime]::Parse($task.finishTime)).toString("MM/dd/yyyy HH:mm:ss")
																	$tmpObjectTask | Add-Member NoteProperty Start_TimeZ            ([DateTime]::Parse($task.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
																	$tmpObjectTask | Add-Member NoteProperty Finish_TimeZ           ([DateTime]::Parse($task.finishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
																	if ($deployStep.queuedOn) {
																		$tmpObjectTask | Add-Member NoteProperty Queue_Time         ([DateTime]::Parse($deployStep.queuedOn)).toString("MM/dd/yyyy HH:mm:ss")
																		$tmpObjectTask | Add-Member NoteProperty Queue_TimeZ        ([DateTime]::Parse($deployStep.queuedOn)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
																		$tmpObjectTask | Add-Member NoteProperty Wait_Time          (new-TimeSpan -start $deployStep.queuedOn -end $task.startTime).TotalMinutes
																	} else {
																		$tmpObjectTask | Add-Member NoteProperty Queue_Time         $null
																		$tmpObjectTask | Add-Member NoteProperty Queue_TimeZ        $null
																		$tmpObjectTask | Add-Member NoteProperty Wait_Time          $null
																	}
																	$tmpObjectTask | Add-Member NoteProperty Elapsed_Time           (new-TimeSpan -start $task.startTime -end $task.finishTime).TotalMinutes
																	$tmpObjectTask | Add-Member NoteProperty Project                $project
																	$tmpObjectTask | Add-Member NoteProperty Agent                  $task.agentname
																	$tmpObjectTask | Add-Member NoteProperty Reason                 $release2.Reason
																	$tmpObjectTask | Add-Member NoteProperty Description            $release2.Description
																	$tmpObjectTask | Add-Member NoteProperty RequestedFor           $tmpRequestedFor
																	$tmpObjectTask | Add-Member NoteProperty RequestedBy            $tmpRequestedBy
																	$tmpObjectTask | Add-Member NoteProperty VSTSlink               $task.logUrl
																	$tmpObjectTask | Add-Member NoteProperty ErrorIssues            $errorIssues
																	
																	$releaseInfoTable += $tmpObjectTask
																	
																	$tmpReleaseErrorIssues += $errorIssues
																}
															}
															
															$tmpobjectRelease | Add-Member NoteProperty Status      $tmpReleaseStatus
															$tmpobjectRelease | Add-Member NoteProperty ErrorIssues $tmpReleaseErrorIssues
															$releaseInfoTable += $tmpobjectRelease	
														}
													}
												}
											}
										}
									}
								}
							}
						}
					}
				}
			}
		}
	}
	
	if ($DEBUG) {
		$releaseInfoTable | ConvertTo-Csv -NoTypeInformation | out-file "$($homeFolder)\release.csv" -encoding ascii
	}

	
	write-host "Uploading to DBs..."
	
	$esString = ""
	
	
	foreach ($line in $releaseInfoTable) {
	
		if ($deletePreviousElasticRecord) {
			$esString += @"
{"delete": {"_index": "$($strElasticSearchIndex)","_type": "_doc","_id": "$($line.ReleaseKey)"}}

"@
		}
		
		$esString += @"
{"create": {"_index": "$($strElasticSearchIndex)","_type": "_doc","_id": "$($line.ReleaseKey)"}}
{"ReleaseKey":"$($line.ReleaseKey)","PipelineID":"$($line.PipelineID)","ReleaseID":"$($line.ReleaseID)","EnvironmentID":"$($line.EnvironmentID)","DeployStepID":"$($line.DeployStepID)","ReleaseDeployPhaseID":"$($line.ReleaseDeployPhaseID)","DeploymentJobID":"$($line.DeploymentJobID)","TaskID":"$($line.TaskID)","IssueCount":"$($line.IssueCount)","Attempt":"$($line.Attempt)","ReleaseDef":"$($line.ReleaseDef)","ReleaseName":"$($line.ReleaseName)","EnvironmentName":"$($line.EnvironmentName)","DeployStepName":"$($line.DeployStepName)","ReleaseDeployPhaseName":"$($line.ReleaseDeployPhaseName)","DeploymentJobName":"$($line.DeploymentJobName)","TaskName":"$($line.TaskName)","RecordType":"$($line.RecordType)","Status":"$($line.Status)","Start_Time":"$($line.Start_TimeZ)","Finish_Time":"$($line.Finish_TimeZ)","Queue_Time":"$($line.Queue_TimeZ)","Wait_Time":"$($line.Wait_Time)","Elapsed_Time":"$($line.Elapsed_Time)","Project":"$($line.Project)","Agent":"$($line.Agent)","Reason":"$($line.Reason)","Description":"$($line.Description)","RequestedFor":"$($line.RequestedFor)","RequestedBy":"$($line.RequestedBy)","VSTSlink":"$($line.VSTSlink)","ErrorIssues":"$($line.ErrorIssues)"}

"@

		if (!($releaseInfoTable.IndexOf($line) % 500)) {
			if ($updateElastic) {
				try {
					$result = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
					$result
				}
				catch {
					write-warning "Errors writing to ES - Bulk Mode"
					Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Bulk Mode"
				}
				if ($result.errors) {
					write-warning "Errors writing to ES - Bulk Mode"
					Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Bulk Mode"
					foreach ($resultItem in $result.items) {
						if ($resultItem.create.error) {
							$resultItem.create.error | convertto-json -depth 100
						}
					}
					write-warning "Attempting to narrow down the error..."
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
								$result2 = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
								$result2
							}
							catch {
								write-warning "Errors writing to ES - Single Mode"
								Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Single Mode"
							}
							if ($result2.errors) {
								write-warning "Errors writing to ES - Single Mode"
								Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Single Mode"
								foreach ($result2Item in $result2.items) {
									if ($result2Item.create.error) {
										$result2Item.create.error | convertto-json -depth 100
									}
								}
								$tmpBody
							}
							$tmpBody = $null
						}
					}
				}
			}
			$esString = ""
		}
	}
	
	if ($updateElastic) {
		if ($esString) {
			try {
				$result = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
				$result
			}
			catch {
				write-warning "Errors writing to ES - Bulk Mode"
				Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Bulk Mode"
			}
			if ($result.errors) {
				write-warning "Errors writing to ES - Bulk Mode"
				Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Bulk Mode"
				foreach ($resultItem in $result.items) {
					if ($resultItem.create.error) {
						$resultItem.create.error | convertto-json -depth 100
					}
				}
				write-warning "Attempting to narrow down the error..."
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
							$result2 = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
							$result2
						}
						catch {
							write-warning "Errors writing to ES - Single Mode"
							Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Single Mode"
						}
						if ($result2.errors) {
							write-warning "Errors writing to ES - Single Mode"
							Write-Host "##vso[task.logissue type=warning;] Errors writing to ES - Single Mode"
							foreach ($result2Item in $result2.items) {
								if ($result2Item.create.error) {
									$result2Item.create.error | convertto-json -depth 100
								}
							}
							$tmpBody
						}
						$tmpBody = $null
					}
				}
			}
			$esString = ""
		}
	}
	
	$esString = @"
{"delete": {"_index": "timestamp","_type": "_doc","_id": "$($strElasticSearchIndex)"}}
{"create": {"_index": "timestamp","_type": "_doc","_id": "$($strElasticSearchIndex)"}}
{"ID": "$($strElasticSearchIndex)","LastRunTime": "$($thisRunDateTime)"}

"@

	if ($updateElastic) {
		try {
			invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
		}
		catch {
			write-host "ERROR: updating LastRunTime"
			$esString
		}
	}
}

main
