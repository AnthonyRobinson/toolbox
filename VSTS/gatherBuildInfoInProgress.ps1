<#

	.SYNOPSIS
		Query VSTS for build info and write to databases

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
	
	if (!(Get-Module -ListAvailable -name SqlServer)) {
		Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
		Install-module -Name SqlServer -Force -AllowClobber
	}
	

	if (!($projectUrl = $ENV:SYSTEM_TEAMFOUNDATIONSERVERURI)) {
		$projectUrl = "https://microsoft.visualstudio.com"
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
		$strMetricsTable = "BuildHistoryNew"
	}
	
	if ($ENV:strDefinitions) {
		$strDefinitions = $env:strDefinitions.replace(" ","").replace('"','').split(",")
	} else {
		$strDefinitions = "Evoke", "Camera", "Mira", "OMG.Shared.Tools", "Paint", "Story", "Video"
	}
	
	if ($ENV:strProjects) {
		$strProjects = $env:strProjects.replace(" ","").replace('"','').split(",")
	} else {
		$strProjects = "Apps", "PaintStudio"
	}
	
	if ($ENV:processTimeLine -like "Y" -or $ENV:processTimeLine -like "true" -or $ENV:processTimeLine -like "$true") {
		$processTimeLine = $true
	} else {
		$processTimeLine = $false
	}
	

	$updateSQL = $false

	
	if ($ENV:deletePreviousSQLrecord -like "Y" -or $ENV:deletePreviousSQLrecord -like "true" -or $ENV:deletePreviousSQLrecord -like "$true") {
		$deletePreviousSQLrecord = $true
	} else {
		$deletePreviousSQLrecord = $false
	}
	
	if ($ENV:updateElastic -like "Y" -or $ENV:updateElastic -like "true" -or $ENV:updateElastic -like "$true") {
		$updateElastic = $true
	} else {
		$updateElastic = $false
	}
	
	if ($ENV:deletePreviousElasticRecord -like "Y" -or $ENV:deletePreviousElasticRecord -like "true" -or $ENV:deletePreviousElasticRecord -like "$true") {
		$deletePreviousElasticRecord = $true
	} else {
		$deletePreviousElasticRecord = $true
	}
	
	$strRunningFile = $MyInvocation.ScriptName + ".running"
	
	$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($personalAccessToken)")) } 
	
	get-variable | format-table Name, Value
	
	getTheBuilds
	
	if (Test-Path "$strRunningFile") {
		Remove-Item "$strRunningFile"
	}
	
	exit 0
}




function getTheBuilds {
		
	$buildInfotable = @()
	
	foreach ($project in $strProjects) {
	
		$project
		
		# -- Query the vNext Builds for this Project
	
		$projectUrlProject = $projectUrl + '/' + $project
		
		foreach ($definition in $strDefinitions) {
		
			$definition
		
			$definitionsApi = "/_apis/build/definitions?api-version=4.0&name=$($definition)*"
			
			# -- Get all the build def IDs
			
			$projectUrlProject+$definitionsApi
			
			foreach ($id in ((Invoke-RestMethod ($projectUrlProject+$definitionsApi) -Headers $headers).Value | where {$_.Type.equals("build") -and $_.quality -eq "definition"}).id) {
			
				$buildsApi = '/_apis/build/builds?api-version=4.1&definitions=' +$id+ '&statusFilter=InProgress'
				$Builds	 = (Invoke-RestMethod ($projectUrlProject+$buildsApi) -Headers $headers).Value
				
				# -- loop thru all the builds for this build def ID
				
				foreach ($build in $builds) {
				
					if ($build.status -like "inProgress") {
					
						if ($build.queueTime -and $build.startTime -and ($build.definition.name -like "$($definition)*")) {
						
							$build.buildNumber
							
							if ($DEBUG) {
								$build | convertto-json
							}
							
							$timeline = (Invoke-RestMethod ($build._links.timeline.href) -Headers $headers)
														
							$errorIssues = ""
							if ($str1 = ($timeline.records.issues | where-object {$_.type -like "error"}).message) {
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
							
							$tmpRequestedFor = $build.requestedFor.displayName -replace 'Paul Wannb.ck','Paul Wannback'
							$tmpRequestedFor = $tmpRequestedFor -replace 'Gustav Tr.ff','Gustav Traff'
							$tmpRequestedFor = $tmpRequestedFor -replace '.nis Ben Hamida','Anis Ben Hamida'
							$tmpRequestedFor = $tmpRequestedFor -replace 'Bj.rn Aili','Bjorn Aili'
							$tmpRequestedFor = $tmpRequestedFor -replace 'Tor Andr.','Tor Andrae'
						
							$tmpobject = new-object PSObject

							$tmpobject | Add-Member NoteProperty BuildKey         $build.id
							$tmpobject | Add-Member NoteProperty BuildID          $build.id
							$tmpobject | Add-Member NoteProperty TimeLineID       $null
							$tmpobject | Add-Member NoteProperty ParentID         $null
							$tmpobject | Add-Member NoteProperty BuildDef         $build.definition.name
							$tmpobject | Add-Member NoteProperty BuildNumber      $build.buildNumber
							$tmpobject | Add-Member NoteProperty RecordType       "Build"
							$tmpobject | Add-Member NoteProperty BuildJob         $null
							$tmpobject | Add-Member NoteProperty Finished         $build.status
							$tmpobject | Add-Member NoteProperty Compile_Status   "InProgress"
							$tmpobject | Add-Member NoteProperty Queue_Time       ([DateTime]::Parse($build.queueTime)).toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject | Add-Member NoteProperty Start_Time       ([DateTime]::Parse($build.startTime)).toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject | Add-Member NoteProperty Finish_Time      (get-date).toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject | Add-Member NoteProperty Queue_TimeZ      ([DateTime]::Parse($build.queueTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject | Add-Member NoteProperty Start_TimeZ      ([DateTime]::Parse($build.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject | Add-Member NoteProperty Finish_TimeZ     (get-date).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject | Add-Member NoteProperty Wait_Time        (new-TimeSpan -start $build.queueTime -end $build.startTime).TotalMinutes
							$tmpobject | Add-Member NoteProperty Elapsed_Time     0
							$tmpobject | Add-Member NoteProperty Project          $build.project.name
							$tmpobject | Add-Member NoteProperty Agent_Pool       $build.queue.name
							$tmpobject | Add-Member NoteProperty Agent            $null
							$tmpobject | Add-Member NoteProperty Reason           $build.Reason
							$tmpobject | Add-Member NoteProperty SourceGetVersion $build.sourceVersion
							$tmpobject | Add-Member NoteProperty SourceRepo       $build.repository.name
							$tmpobject | Add-Member NoteProperty SourceBranch     $build.sourceBranch
							$tmpobject | Add-Member NoteProperty RequestedFor     $tmpRequestedFor
							$tmpobject | Add-Member NoteProperty ErrorIssues      $errorIssues
							
							$buildInfotable += $tmpobject
							$lastBuildRecord = $buildInfotable.count - 1

							if ($processTimeLine) {
							
								foreach ($item in $timeline.records) {
								
									# write-host $build.definition.name, $item.name
								
									if ($DEBUG) {
										$item | convertto-json
									}
									
									$tmpResult = "InProgress"
									
									$errorIssues = ""
									if ($str1 = ($item.issues | where-object {$_.type -like "error"}).message) {
										$tmpResult = "InProgressFailed"
										$buildInfotable[$lastBuildRecord].Compile_Status = "InProgressFailed"
										$str2 = $str1.Replace('\','/')
										$str3 = ""
										foreach ($line in $str2) {
											$str3 += $line + "\n"
										}
										$str4 = $str3.Replace("`r`n","\n")
										$str5 = $str4.Replace("`n","\n")
										$str6 = $str5.Replace("`t","    ")
										$errorIssues = $str6.Replace('"',"'")
										if ($item.log.url) {
											$logData = (invoke-restmethod $item.log.url -headers $headers) -Split "`r`n"
											foreach ($failure in ($logData | select-string "^Failure")) {
												$errorIssues += "`n" + $failure
											}
											$errorIssues += "`n" + $item.log.url
											if ($tmp = ($logData | select-string "Rld schedule created") -split("'")) {
												if ($logFolder = $tmp[$tmp.count-2]) {
													foreach ($failuresXmlFile in ((get-childitem -path $logFolder -filter "failure*.xml" -recurse).fullName)) {
														[xml]$failuresXmlContent = get-content $failuresXmlFile
														if ($failuresXmlContent.Failures) {
															foreach ($failure in $failuresXmlContent.Failures) {
																foreach ($err in $failure.failure.log.testcase.error) {
																	$errorIssues += "`n" + $err.UserText
																}
															}
														}
													}
												}
											}
										}
										$errorIssues = $errorIssues.Replace("\n","`n")
										$errorIssues = $errorIssues.Replace('\','/')
										$errorIssues = $errorIssues.Replace("`r`n","\n")
										$errorIssues = $errorIssues.Replace("`n","\n")
										$errorIssues = $errorIssues.Replace("`t","    ")
										$errorIssues = $errorIssues.Replace('"',"'")
									}
							
									$tmpobject = new-object PSObject
									
									$tmpBuildKey = [string]$build.id + "_" + [string]$item.Parentid + "_" + [string]$item.id
									
									$tmpobject | Add-Member NoteProperty BuildKey         $tmpBuildKey
									$tmpobject | Add-Member NoteProperty BuildID          $build.id
									$tmpobject | Add-Member NoteProperty TimeLineID       $item.id
									$tmpobject | Add-Member NoteProperty ParentID         $item.Parentid
									$tmpobject | Add-Member NoteProperty RecordType       $item.type
									$tmpobject | Add-Member NoteProperty BuildDef         $build.definition.name
									$tmpobject | Add-Member NoteProperty BuildNumber      $build.buildNumber
									$tmpobject | Add-Member NoteProperty BuildJob         $item.name
									$tmpobject | Add-Member NoteProperty Finished         $item.state
									$tmpobject | Add-Member NoteProperty Compile_Status   $tmpResult
									$tmpobject | Add-Member NoteProperty Queue_Time       ([DateTime]::Parse($build.queueTime)).toString("MM/dd/yyyy HH:mm:ss")
									$tmpobject | Add-Member NoteProperty Queue_TimeZ      ([DateTime]::Parse($build.queueTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
									if ($item.startTime) {
										$tmpobject | Add-Member NoteProperty Start_Time   ([DateTime]::Parse($item.startTime)).toString("MM/dd/yyyy HH:mm:ss")
										$tmpobject | Add-Member NoteProperty Start_TimeZ  ([DateTime]::Parse($item.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
										$tmpobject | Add-Member NoteProperty Wait_Time    (new-TimeSpan -start $build.queueTime -end $build.startTime).TotalMinutes
									} else {
										$tmpobject | Add-Member NoteProperty Start_Time   ([DateTime]::Parse($build.startTime)).toString("MM/dd/yyyy HH:mm:ss")
										$tmpobject | Add-Member NoteProperty Start_TimeZ  ([DateTime]::Parse($build.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
										$tmpobject | Add-Member NoteProperty Wait_Time    (new-TimeSpan -start $build.queueTime -end $build.startTime).TotalMinutes
									}
									if ($item.finishTime) {
										$tmpobject | Add-Member NoteProperty Finish_Time  ([DateTime]::Parse($item.finishTime)).toString("MM/dd/yyyy HH:mm:ss")
										$tmpobject | Add-Member NoteProperty Finish_TimeZ ([DateTime]::Parse($item.finishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
										if ($item.startTime) {
											$tmpobject | Add-Member NoteProperty Elapsed_Time (new-TimeSpan -start $item.startTime -end $item.finishTime).TotalMinutes
										}
									} else {
										$tmpobject | Add-Member NoteProperty Finish_Time      (get-date).toString("MM/dd/yyyy HH:mm:ss")
										$tmpobject | Add-Member NoteProperty Finish_TimeZ     (get-date).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
										$tmpobject | Add-Member NoteProperty Elapsed_Time     0
									}
									$tmpobject | Add-Member NoteProperty Project          $build.project.name
									$tmpobject | Add-Member NoteProperty Agent            $item.workerName
									$tmpobject | Add-Member NoteProperty Agent_Pool       $build.queue.name
									$tmpobject | Add-Member NoteProperty Reason           $build.Reason
									$tmpobject | Add-Member NoteProperty SourceGetVersion $build.sourceVersion
									$tmpobject | Add-Member NoteProperty SourceRepo       $build.repository.name
									$tmpobject | Add-Member NoteProperty SourceBranch     $build.sourceBranch
									$tmpobject | Add-Member NoteProperty RequestedFor     $tmpRequestedFor
									$tmpobject | Add-Member NoteProperty ErrorIssues      $errorIssues

									$buildInfotable += $tmpobject
								}
							}
						} else {
							write-host "Not an $($definition) build..."
						}
					} else {
						write-host "Build in progress..."
					}
				}
			}
		}
	}
	
	
	foreach ($inProgressStr in "InProgress", "InProgressFailed") {
		write-host "Deleting previous", $inProgressStr, "data..."
		while ($true) {
			$esString = @"
{"query": { "match": {"Compile_Status":"$inProgressStr"}}}

"@
			$ids = (invoke-RestMethod -Uri http://$($strMetricsServer):9200/buildinfo/_search?size=1000 -Method POST -Body $esString -ContentType "application/json").hits.hits._id
			if ($ids) {
				$esString = ""
				foreach ($id in $ids) {
					
					$esString += @"
{"delete": {"_index": "buildinfo","_type": "data","_id": "$($id)"}}

"@
				}
				if ($esString) {
					invoke-RestMethod -Uri http://$($strMetricsServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
				}
			} else {
				break
			}
		}
	}


	write-host "Uploading to", $strMetricsServer
	
	$esString = ""
	$sqlString = ""
	
	foreach ($line in $buildInfotable) {

		$esString += @"
{"create": {"_index": "buildinfo","_type": "data","_id": "$($line.BuildKey)"}}
{"Build_Key": "$($line.BuildKey)","Agent": "$($line.Agent)","Agent_Pool": "$($Agent_Pool)","BuildDef": "$($line.BuildDef)","BuildID": "$($line.BuildID)","BuildJob": "$($line.BuildJob)","BuildNumber": "$($line.BuildNumber)","Compile_Status": "$($line.Compile_Status)","Elapsed_Time": $($line.Elapsed_Time),"Finish_Time": "$($line.Finish_TimeZ)","Finished": "$($line.Finished)","ParentID": "$($line.ParentID)","Project": "$($line.Project)","Queue_Time": "$($line.Queue_TimeZ)","Reason": "$($line.Reason)","RecordType": "$($line.RecordType)","RequestedFor": "$($line.RequestedFor)","SourceGetVersion": "$($line.SourceGetVersion)","SourceRepo": "$($line.SourceRepo)","SourceBranch": "$($line.SourceBranch)","Start_Time": "$($line.Start_TimeZ)","TimeLineID": "$($line.TimeLineID)","Wait_Time": $($line.Wait_Time),"Error_Issues": "$($line.ErrorIssues)"}

"@

		if (!($buildInfotable.IndexOf($line) % 500)) {
			if ($updateElastic) {
				try {
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
