<#

	.SYNOPSIS
		Query VSTS for release info and write to databases

	.DESCRIPTION
		Queries VSTS for specific build info relating to specific build defs and time frames.  Build data is conditionally written to SQL Server and ElasticSearch.  Kibana is used for dashboard visualization.

	.INPUTS
		All inputs (saerver names, query options, time window, destructive db writes, etc.) are inferreed from the calling environment.  If not set, some defaults are taken.

	.OUTPUTS
		Outputs are data written to SQL Server and ElasticSearch

	.NOTES
		Anthony A Robinson 7/2018
		v-antrob@microsoft.com
		https://www.linkedin.com/in/3legdog/

	.LINK
		http://std-5276466:5601/goto/ed68314bc0db678adf1860af9405d3ce
		http://std-5276466:9200
		
#>

function main {

	$progressPreference = 'silentlyContinue'
	$thisRunDateTime = get-date
	$DEBUG = $ENV:DEBUG
	
	if (!($collection = $ENV:SYSTEM_TEAMFOUNDATIONSERVERURI)) {
		$collection = "https://microsoft.vsrm.visualstudio.com"
	}

	if (!($personalAccessToken = $ENV:PAT)) {
		write-warning "Personal Authentication Token or OAuth System_AccessToken needs to be set in the environment"
	} elseif (!($OAuthToken = $ENV:System_AccessToken)) {
		write-warning "Personal Authentication Token or OAuth System_AccessToken needs to be set in the environment"
	} else {
		write-error "Personal Authentication Token or OAuth System_AccessToken needs to be set in the environment"
	}
	
	if (!($strMetricsServer = $ENV:strMetricsServer)) {
		$strMetricsServer = "STD-5276466"
	}
	
	if (!($strMetricsDatabase = $ENV:strMetricsDatabase)) {
		$strMetricsDatabase = "Metrics"
	}
	
	if (!($strMetricsTable = $ENV:strMetricsTable)) {
		$strMetricsTable = "ReleaseHistoryNew"
	}
	
	if ($ENV:strDefinitions) {
		$strDefinitions = $env:strDefinitions.replace(" ","").replace('"','').split(",")
	} else {
		$strDefinitions = "Evoke", "OMG"
	}
	
	if ($ENV:updateElastic -like "Y" -or $ENV:updateElastic -like "true" -or $ENV:updateElastic -like "$true") {
		$updateElastic = $true
	} else {
		$updateElastic = $false
	}
	
	if ($ENV:deletePreviousElasticRecord -like "Y" -or $ENV:deletePreviousElasticRecord -like "true" -or $ENV:deletePreviousElasticRecord -like "$true") {
		$deletePreviousElasticRecord = $true
	} else {
		$deletePreviousElasticRecord = $false
	}
	
	$deletePreviousElasticRecord = $true
	
	if (!($minutesBack = $ENV:minutesBack)) {
		if ($tmp = invoke-RestMethod -Uri http://$($strMetricsServer):9200/timestamp/data/buildinfo) {
			$lastRunDateTime = [datetime]([string]$tmp._source.LastRunTime)
			write-host "INFO: last run was at" $lastRunDateTime
			$minutesBack = (new-TimeSpan -start $thisRunDateTime -end $lastRunDateTime).TotalMinutes
		} else {
			$minutesBack = -60
		}
	}
	
	$minutesBack = -20000
	
	$strStartDate = (get-date).AddMinutes($minutesBack)
	
	write-host "INFO: using minutesBack of" $minutesBack "and strStartDate" $strStartDate
	
	$strRunningFile = $MyInvocation.ScriptName + ".running"
	
	$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($personalAccessToken)")) } 
	
	get-variable | format-table Name, Value
	
	getTheReleases
	
	if (Test-Path "$strRunningFile") {
		Remove-Item "$strRunningFile"
	}
	
	exit 0
}




function getTheReleases {
		
	$strStartDate = (get-date).AddMinutes($minutesBack).ToUniversalTime()

	$releaseInfoTable = @()
	$releaseInfoHash = @{}
	
	foreach ($project in "Apps") {
	
		$project
		
		$projectUrl = $collection + "/" + $project
		
		foreach ($definition in $strDefinitions) {
		
			$definition
		
			$releaseDefs = (Invoke-RestMethod "$projectUrl/_apis/release/definitions?api-version=4.0" -Headers $headers).value | where {$_.name -like "$($definition)*"}
			
			foreach ($releaseDef in $releaseDefs) {
			
				# $releaseDef | ConvertTo-json -depth 100 | out-file "d:\tmp\release\releaseDef.$($releaseDef.id).json" -encoding ascii
			
				$releaseDef.name

				$releases = Invoke-RestMethod "$projectUrl/_apis/release/releases?api-version=4.0&definitionId=$($releaseDef.id)&releaseCount=100" -Headers $headers
				$releases.count
				# "$projectUrl/_apis/release/releases?definitionId=$($releaseDef.id)&minCreatedTime=$($strStartDate.ToString())"
				# $releases = Invoke-RestMethod "$projectUrl/_apis/release/releases?api-version=4.0&definitionId=$($releaseDef.id)&minCreatedTime=$($strStartDate.ToString())" -Headers $headers
				# $releases.count
				
				foreach ($release in $releases) {
				
					# $release | ConvertTo-json -depth 100 | out-file "d:\tmp\release\release.$($release.id).json" -encoding ascii
				
					foreach ($releaseId in $release.releases.id) {
					
						foreach ($release2 in Invoke-RestMethod "$projectUrl/_apis/release/releases/$($releaseId)?api-version=4.0" -Headers $headers) {
						
							# $release2.name
							# $release2 | ConvertTo-json -depth 100 | out-file "d:\tmp\release\release2.$($release2.id).json" -encoding ascii
						
							foreach ($environment in $release2.environments) {
							
								foreach ($deployStep in $environment.deploySteps) {
								
									# $deployStep | ConvertTo-json -depth 100 | out-file "d:\tmp\release\deployStep_$($deployStep.id).json" -encoding ascii
								
									$tmpRequestedFor = $deployStep.requestedFor.displayName -replace 'Paul Wannb.ck','Paul Wannback'
									$tmpRequestedFor = $tmpRequestedFor -replace 'Gustav Tr.ff','Gustav Traff'
									$tmpRequestedFor = $tmpRequestedFor -replace '.nis Ben Hamida','Anis Ben Hamida'
									$tmpRequestedFor = $tmpRequestedFor -replace 'Bj.rn Aili','Bjorn Aili'
									$tmpRequestedFor = $tmpRequestedFor -replace 'Tor Andr.','Tor Andrae'
									$tmpRequestedFor = $tmpRequestedFor.replace('\','\\')
												
									foreach ($releaseDeployPhase in $deployStep.releaseDeployPhases) {
									
										foreach ($deploymentJob in $releaseDeployPhase.deploymentJobs) {
										
											if (!($deploymentJob.job.status -like "inProgress")) {
										
												foreach ($task in $deploymentJob.tasks) {
												
													$issueCount = 0
													$historyCount = 0
													$tmpReleaseStatus = "succeeded"
													
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
													$tmpobjectRelease | Add-Member NoteProperty ReleaseDef             $releaseDef.name
													$tmpobjectRelease | Add-Member NoteProperty ReleaseName            $release2.name
													$tmpobjectRelease | Add-Member NoteProperty EnvironmentName        $environment.name
													$tmpobjectRelease | Add-Member NoteProperty DeployStepName         $deployStep.name
													$tmpobjectRelease | Add-Member NoteProperty ReleaseDeployPhaseName $releaseDeployPhase.name
													$tmpobjectRelease | Add-Member NoteProperty DeploymentJobName      $deploymentJob.job.name
													$tmpobjectRelease | Add-Member NoteProperty TaskName               $task.name.replace('\','\\')
													$tmpobjectRelease | Add-Member NoteProperty RecordType             "Release"
													$tmpobjectRelease | Add-Member NoteProperty Start_Time             ([DateTime]::Parse($task.startTime)).toString("MM/dd/yyyy HH:mm:ss")
													$tmpobjectRelease | Add-Member NoteProperty Finish_Time            ([DateTime]::Parse($task.finishTime)).toString("MM/dd/yyyy HH:mm:ss")
													$tmpobjectRelease | Add-Member NoteProperty Start_TimeZ            ([DateTime]::Parse($task.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
													$tmpobjectRelease | Add-Member NoteProperty Finish_TimeZ           ([DateTime]::Parse($task.finishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
													if ($deployStep.queuedOn) {
														$tmpobjectRelease | Add-Member NoteProperty Queue_Time         ([DateTime]::Parse($deployStep.queuedOn)).toString("MM/dd/yyyy HH:mm:ss")
														$tmpobjectRelease | Add-Member NoteProperty Queue_TimeZ        ([DateTime]::Parse($deployStep.queuedOn)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
														$tmpobjectRelease | Add-Member NoteProperty Wait_Time          (new-TimeSpan -start $deployStep.queuedOn -end $task.startTime).TotalMinutes
													} else {
														$tmpobjectRelease | Add-Member NoteProperty Queue_Time         $null
														$tmpobjectRelease | Add-Member NoteProperty Queue_TimeZ        $null
														$tmpobjectRelease | Add-Member NoteProperty Wait_Time          $null
													}
													$tmpobjectRelease | Add-Member NoteProperty Elapsed_Time        (new-TimeSpan -start $task.startTime -end $task.finishTime).TotalMinutes
													$tmpobjectRelease | Add-Member NoteProperty Project             $project
													$tmpobjectRelease | Add-Member NoteProperty Agent               $deploymentJob.job.agentname
													$tmpobjectRelease | Add-Member NoteProperty Reason              $release2.Reason
													$tmpobjectRelease | Add-Member NoteProperty RequestedFor        $tmpRequestedFor
													$tmpobjectRelease | Add-Member NoteProperty VSTSlink            "https://microsoft.visualstudio.com/Apps/_releaseProgress?releaseId=$($releaseId)&_a=release-environment-logs&environmentId=$($environment.id)"
													
													
													$tmpReleaseErrorIssues = ""
													
													foreach ($issue in $task.issues) {
														$issueCount += 1									
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
															
															if ($errorissues) {
																$tmpReleaseStatus = "failed"
															}
															
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
															$tmpObjectTask | Add-Member NoteProperty RequestedFor           $tmpRequestedFor
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
	
	# $releaseInfoTable | ConvertTo-Csv -NoTypeInformation | out-file ".\release.csv" -encoding ascii

	
	write-host "Uploading to DBs..."
	
	$esString = ""
	
	
	foreach ($line in $releaseInfoTable) {
	
		if ($deletePreviousElasticRecord) {
			$esString += @"
{"delete": {"_index": "releaseinfo","_type": "data","_id": "$($line.ReleaseKey)"}}

"@
		}
		
		$esString += @"
{"create": {"_index": "releaseinfo","_type": "data","_id": "$($line.ReleaseKey)"}}
{"ReleaseKey": "$($line.ReleaseKey)","PipelineID": "$($line.PipelineID)","ReleaseID": "$($line.ReleaseID)","EnvironmentID": "$($line.EnvironmentID)","DeployStepID": "$($line.DeployStepID)","ReleaseDeployPhaseID": "$($line.ReleaseDeployPhaseID)","DeploymentJobID": "$($line.DeploymentJobID)","TaskID": "$($line.TaskID)","ReleaseDef": "$($line.ReleaseDef)","ReleaseName": "$($line.ReleaseName)","EnvironmentName": "$($line.EnvironmentName)","DeployStepName": "$($line.DeployStepName)","ReleaseDeployPhaseName": "$($line.ReleaseDeployPhaseName)","DeploymentJobName": "$($line.DeploymentJobName)","TaskName": "$($line.TaskName)","RecordType": "$($line.RecordType)","Status": "$($line.Status)","Start_Time": "$($line.Start_TimeZ)","Finish_Time": "$($line.Finish_TimeZ)","Queue_Time": "$($line.Queue_TimeZ)","Wait_Time": "$($line.Wait_Time)","Elapsed_Time": "$($line.Elapsed_Time)","Project": "$($line.Project)","Agent": "$($line.Agent)","Reason": "$($line.Reason)","RequestedFor": "$($line.RequestedFor)","VSTSlink": "$($line.VSTSlink)","ErrorIssues": "$($line.ErrorIssues)"}


"@

		if (!($releaseInfoTable.IndexOf($line) % 500)) {
			if ($updateElastic) {
				try {
#					""
#					$esString
					invoke-RestMethod -Uri http://$($strMetricsServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
				}
				catch {
					write-host "ERROR: writing to ES"
					$esString
				}
			}
			$esString = ""
		}
	}
	
	if ($updateElastic) {
		if ($esString) {
			try {
				invoke-RestMethod -Uri http://$($strMetricsServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
			}
			catch {
				write-host "ERROR: writing to ES"
				$esString
			}
			$esString = ""
		}
	}
}

main
