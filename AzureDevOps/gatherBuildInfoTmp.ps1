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

	if (!($strMetricsEsServer = $ENV:strMetricsEsServer)) {
		$strMetricsEsServer = "OMGRCAVM"
	}
	
	if (!($strMetricsSqlServer = $ENV:strMetricsSqlServer)) {
		$strMetricsSqlServer = "STD-5276466"
	}
	
	if (!($strMetricsDatabase = $ENV:strMetricsDatabase)) {
		$strMetricsDatabase = "Metrics"
	}
	
	if (!($strMetricsTable = $ENV:strMetricsTable)) {
		$strMetricsTable = "BuildInfo"
	}
	
	if ($ENV:strDefinitions) {
		$strDefinitions = $env:strDefinitions.replace(" ","").replace('"','').split(",")
	} else {
		$strDefinitions = "Evoke", "Camera", "Mira", "OMG.Shared.Tools", "Paint", "Story", "Video", "Canvas3d", "3MFSDK", "GLTFSDK-CI", "Microsoft.Photos", "Photos"
	}
	
	if ($ENV:strProjects) {
		$strProjects = $env:strProjects.replace(", ",",").replace('"','').split(",")
	} else {
		$strProjects = "Apps", "PaintStudio"
	}
	
	if ($ENV:processTimeLine -like "Y" -or $ENV:processTimeLine -like "true" -or $ENV:processTimeLine -like "$true") {
		$processTimeLine = $true
	} else {
		$processTimeLine = $false
	}
	
	if ($ENV:updateSQL -like "Y" -or $ENV:updateSQL -like "true" -or $ENV:updateSQL -like "$true") {
		$updateSQL = $true
	} else {
		$updateSQL = $false
	}
	
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
		$deletePreviousElasticRecord = $false
	}
	
	if (!($minutesBack = $ENV:minutesBack)) {
		if ($tmp = invoke-RestMethod -Uri http://$($strMetricsEsServer):9200/timestamp/data/buildinfo) {
			$lastRunDateTime = [datetime]([string]$tmp._source.LastRunTime)
			write-host "INFO: last run was at" $lastRunDateTime
			$minutesBack = (new-TimeSpan -start $thisRunDateTime -end $lastRunDateTime).TotalMinutes
		} else {
			$minutesBack = -200
		}
	}
	
	$strStartDate = (get-date).AddMinutes($minutesBack)
	
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
	
	get-variable | format-table Name, Value
	
	getTheBuilds
	
	exit 0
}




function getTheBuilds {
		
	$strStartDate = (get-date).AddMinutes($minutesBack).ToUniversalTime()

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
			
				$buildsApi = '/_apis/build/builds?api-version=4.0&definitions=' +$id+ '&minFinishTime=' + $strStartDate.ToString()
				$Builds	 = (Invoke-RestMethod ($projectUrlProject+$buildsApi) -Headers $headers).Value
				
				# -- loop thru all the builds for this build def ID
				
				foreach ($build in $builds) {
				
					if (!($build.status -like "Failed")) {
					
						if ($build.queueTime -and $build.startTime -and $build.finishTime -and ($build.definition.name -like "$($definition)*")) {
						
							$build.buildNumber
							
							if ($DEBUG) {
								$build | convertto-json
							}
							
							$timeline = (Invoke-RestMethod ($build._links.timeline.href) -Headers $headers)
							
							$tmpBuildDef = (Invoke-RestMethod ($build.definition.url) -Headers $headers)
							
							$tmpDemands = $null
							foreach ($demand in $tmpBuildDef.demands) {
								$tmpDemands += $demand + "\n"
							}
							
							$tmpVariables = $null
							if ($tmpBuildDef.variables) {
								foreach ($name in ($tmpBuildDef.variables | Get-Member -MemberType NoteProperty).Name) {
									$tmpValue = $null
									if ($tmpValue = $tmpBuildDef.variables.$($name).value) {
										$tmpValue = $tmpValue.replace('"',"'")
										$tmpValue = $tmpValue.replace('\','/')
									}
									$tmpVariables += $name +"="+ $tmpValue +"\n"
								}
							}
	
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
							
							if (($build.requestedFor.displayName -like "Microsoft.VisualStudio.Services.TFS") -or ($build.requestedFor.displayName -like "Project Collection Build Service*")) {
								$tmpRequestedFor = $build.requestedFor.displayName
							} else {
								$tmpRequestedFor = $build.requestedFor.id
							}
							
							$tmpURL = $projectUrlProject + "/_build/results?buildId=" + $build.id
						
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
							$tmpobject | Add-Member NoteProperty Compile_Status   $build.result            
							$tmpobject | Add-Member NoteProperty Queue_Time       ([DateTime]::Parse($build.queueTime)).toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject | Add-Member NoteProperty Start_Time       ([DateTime]::Parse($build.startTime)).toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject | Add-Member NoteProperty Finish_Time      ([DateTime]::Parse($build.finishTime)).toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject | Add-Member NoteProperty Queue_TimeZ      ([DateTime]::Parse($build.queueTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject | Add-Member NoteProperty Start_TimeZ      ([DateTime]::Parse($build.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject | Add-Member NoteProperty Finish_TimeZ     ([DateTime]::Parse($build.finishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject | Add-Member NoteProperty Wait_Time        (new-TimeSpan -start $build.queueTime -end $build.startTime).TotalMinutes
							$tmpobject | Add-Member NoteProperty Elapsed_Time     (new-TimeSpan -start $build.startTime -end $build.finishTime).TotalMinutes
							$tmpobject | Add-Member NoteProperty Project          $build.project.name
							$tmpobject | Add-Member NoteProperty Agent_Pool       $build.queue.name
							$tmpobject | Add-Member NoteProperty Agent            $null
							$tmpobject | Add-Member NoteProperty Reason           $build.Reason
							$tmpobject | Add-Member NoteProperty SourceGetVersion $build.sourceVersion
							$tmpobject | Add-Member NoteProperty SourceRepo       $build.repository.name
							$tmpobject | Add-Member NoteProperty SourceBranch     $build.sourceBranch
							$tmpobject | Add-Member NoteProperty URL              $tmpURL
							$tmpobject | Add-Member NoteProperty RequestedFor     $tmpRequestedFor
							$tmpobject | Add-Member NoteProperty Demands          $tmpDemands
							$tmpobject | Add-Member NoteProperty Variables        $tmpVariables
							$tmpobject | Add-Member NoteProperty ErrorIssues      $errorIssues
							
							$buildInfotable += $tmpobject

							if ($processTimeLine) {
							
								$queueNameHash = $null
								$queueNameHash = @{}
								
								foreach ($type in "Phase", "Job", "Task") {
									foreach ($item in ($timeline.records | where {$_.type -like $type})) {
										# write-host $item.type, $item.id, $item.parentId, $item.order  $item.name
										if ($queueNameHash.ContainsKey($item.id)) {
											write-warning -message "Duplicate $item.id in queueNameHash"
										} else {
											if ($type -like "Phase") {
												$tmpQueueName = $null
												$tmpName = $item.type + "_" + $item.order
												if ($tmpUrl = (($tmpBuildDef.process.phases | where {$_.refName -like $tmpName}).target.queue.url)) {
													try {
														$tmpQueueName = (invoke-restmethod $tmpUrl -headers $headers).name
													}
													catch {
														write-warning "invoke-restmethod $tmpUrl failed"
													}
												}
												if ($tmpQueueName) {
													$queueNameHash.add($item.id,$tmpQueueName)
												} else {
													$queueNameHash.add($item.id,$build.queue.name)
												}
											} else {
												if ($item.parentId) {
													$queueNameHash.add($item.id,$queueNameHash.$($item.parentId))
												}
											}
										}
									}
								}
								
#								$queueNameHash
#								pause
							
								foreach ($item in $timeline.records) {
								
									# write-host $item.type, $item.id, $item.parentId, $item.order 
								
									if ($DEBUG) {
										$item | convertto-json
									}
									
									$errorIssues = $null
									if ($str1 = ($item.issues | where-object {$_.type -like "error"}).message) {
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
											try {
												$logData = (invoke-restmethod $item.log.url -headers $headers) -Split "`r`n"
											}
											catch {
												write-host $item.log.url "is not valid"
											}
											if ($logData) {
												foreach ($failure in ($logData | select-string -pattern "^Failure|^fatal error")) {
													$errorIssues += "`n" + $failure
												}
												$errorIssues += "`n`n" + $item.log.url
												if ($tmp = ($logData | select-string "Rld schedule created") -split("'")) {
													if ($logFolder = $tmp[$tmp.count-2]) {
														foreach ($failuresXmlFile in ((get-childitem -path $logFolder -filter "failure*.xml" -recurse).fullName)) {
															[xml]$failuresXmlContent = get-content $failuresXmlFile
															if ($failuresXmlContent.Failures) {
																foreach ($failure in $failuresXmlContent.Failures) {
																	foreach ($err in $failure.failure.log.testcase.error) {
																		$errorIssues += "`n`n" + $err.UserText
																	}
																	foreach ($err in $failure.failure.log.framework.error) {
																		$errorIssues += "`n`n" + $err.UserText
																	}
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
									$tmpBuildJob = $item.name.replace('\','/')
									$tmpBuildJob = $tmpBuildJob -replace [char]0x00a0,' '
									
									if ($item.startTime) {
										$tmpStartTime = $item.startTime
									} else {
										$tmpStartTime = $build.startTime
									}
									if ($item.finishTime) {
										$tmpFinishTime = $item.finishTime
									} else {
										$tmpFinishTime = $build.finishTime
									}
									
									if ($item.parentId) {
										$tmpAgentPool = $queueNameHash.$($item.parentId)
									} else {
										$tmpAgentPool = $build.queue.name
									}
									
									$tmpobject | Add-Member NoteProperty BuildKey         $tmpBuildKey
									$tmpobject | Add-Member NoteProperty BuildID          $build.id
									$tmpobject | Add-Member NoteProperty TimeLineID       $item.id
									$tmpobject | Add-Member NoteProperty ParentID         $item.Parentid
									$tmpobject | Add-Member NoteProperty RecordType       $item.type
									$tmpobject | Add-Member NoteProperty BuildDef         $build.definition.name
									$tmpobject | Add-Member NoteProperty BuildNumber      $build.buildNumber
									$tmpobject | Add-Member NoteProperty BuildJob         $tmpBuildJob
									$tmpobject | Add-Member NoteProperty Finished         $item.state
									$tmpobject | Add-Member NoteProperty Compile_Status   $item.result            
									$tmpobject | Add-Member NoteProperty Queue_Time       ([DateTime]::Parse($build.queueTime)).toString("MM/dd/yyyy HH:mm:ss")
									$tmpobject | Add-Member NoteProperty Queue_TimeZ      ([DateTime]::Parse($build.queueTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
									$tmpobject | Add-Member NoteProperty Start_Time       ([DateTime]::Parse($tmpStartTime)).toString("MM/dd/yyyy HH:mm:ss")
									$tmpobject | Add-Member NoteProperty Start_TimeZ      ([DateTime]::Parse($tmpStartTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
									$tmpobject | Add-Member NoteProperty Wait_Time        (new-TimeSpan -start $build.queueTime -end $tmpStartTime).TotalMinutes
									$tmpobject | Add-Member NoteProperty Finish_Time      ([DateTime]::Parse($tmpFinishTime)).toString("MM/dd/yyyy HH:mm:ss")
									$tmpobject | Add-Member NoteProperty Finish_TimeZ     ([DateTime]::Parse($tmpFinishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
									$tmpobject | Add-Member NoteProperty Elapsed_Time     (new-TimeSpan -start $tmpStartTime -end $tmpFinishTime).TotalMinutes
									$tmpobject | Add-Member NoteProperty Project          $build.project.name
									$tmpobject | Add-Member NoteProperty Agent            $item.workerName
									$tmpobject | Add-Member NoteProperty Agent_Pool       $tmpAgentPool
									$tmpobject | Add-Member NoteProperty Reason           $build.Reason
									$tmpobject | Add-Member NoteProperty SourceGetVersion $build.sourceVersion
									$tmpobject | Add-Member NoteProperty SourceRepo       $build.repository.name
									$tmpobject | Add-Member NoteProperty SourceBranch     $build.sourceBranch
									$tmpobject | Add-Member NoteProperty URL              $tmpURL
									$tmpobject | Add-Member NoteProperty RequestedFor     $tmpRequestedFor
									$tmpobject | Add-Member NoteProperty Demands          $tmpDemands
									$tmpobject | Add-Member NoteProperty Variables        $tmpVariables
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
	
	
	write-host "Uploading to DBs..."
	
	$esString = ""
	$sqlString = ""
	
	
	foreach ($line in $buildInfotable) {
	
		if ($deletePreviousSQLrecord) {
			$sqlString += @"
DELETE from $($strMetricsTable)
WHERE BuildKey='$($line.BuildKey)';
GO

"@
		}
			
		$tmpErrorIssues = $line.ErrorIssues -replace "'",'"'
		$tmpErrorIssues = $tmpErrorIssues -replace '\$\(','\('
		
		$tmpWarnings = $line.Warnings -replace "'",'"'
		$tmpWarnings = $tmpWarnings -replace '\$\(','\('
		
		$tmpBuildJob = $line.BuildJob -replace '\$\(','\('
				
		$sqlString += @"
INSERT INTO $($strMetricsTable) (
	BuildKey,
	BuildID,
	TimeLineID,
	ParentID,
	RecordType,
	BuildDef,
	BuildNumber,
	BuildJob,
	Finished,
	Compile_Status,
	Queue_Time,
	Start_Time,
	Finish_Time,
	Elapsed_Time,
	Wait_Time,
	Project,
	Agent,
	Agent_Pool,
	Reason,
	SourceGetVersion,
	RequestedFor,
	Demands,
	Variables,
	SourceRepo,
	SourceBranch,
	URL,
	ErrorIssues
)
VALUES (
	'$($line.BuildKey)',
	'$($line.BuildID)',
	'$($line.TimeLineID)',
	'$($line.ParentID)',
	'$($line.RecordType)',
	'$($line.BuildDef)',
	'$($line.BuildNumber)',
	'$($tmpBuildJob)',
	'$($line.Finished)',
	'$($line.Compile_Status)',
	'$($line.Queue_Time)',
	'$($line.Start_Time)',
	'$($line.Finish_Time)',
	'$($line.Elapsed_Time)',
	'$($line.Wait_Time)',
	'$($line.Project)',
	'$($line.Agent)',
	'$($line.Agent_Pool)',
	'$($line.Reason)',
	'$($line.SourceGetVersion)',
	'$($line.RequestedFor)',
	'$($line.demands)',
	'$($tmpWarnings)',
	'$($line.SourceRepo)',
	'$($line.SourceBranch)',
	'$($line.URL)',
	N'$($tmpErrorIssues)'
)
GO

"@

		if ($deletePreviousElasticRecord) {
			$esString += @"
{"delete": {"_index": "buildinfo","_type": "data","_id": "$($line.BuildKey)"}}

"@
		}
		
		$esString += @"
{"create": {"_index": "buildinfo","_type": "data","_id": "$($line.BuildKey)"}}
{"Build_Key": "$($line.BuildKey)","Agent": "$($line.Agent)","Agent_Pool": "$($line.Agent_Pool)","BuildDef": "$($line.BuildDef)","BuildID": "$($line.BuildID)","BuildJob": "$($line.BuildJob)","BuildNumber": "$($line.BuildNumber)","Compile_Status": "$($line.Compile_Status)","Elapsed_Time": $($line.Elapsed_Time),"Finish_Time": "$($line.Finish_TimeZ)","Finished": "$($line.Finished)","ParentID": "$($line.ParentID)","Project": "$($line.Project)","Queue_Time": "$($line.Queue_TimeZ)","Reason": "$($line.Reason)","RecordType": "$($line.RecordType)","RequestedFor": "$($line.RequestedFor)","Demands": "$($line.demands)","Variables": "$($line.Variables)","SourceGetVersion": "$($line.SourceGetVersion)","SourceRepo": "$($line.SourceRepo)","SourceBranch": "$($line.SourceBranch)","URL": "$($line.URL)","Start_Time": "$($line.Start_TimeZ)","TimeLineID": "$($line.TimeLineID)","Wait_Time": $($line.Wait_Time),"Error_Issues": "$($line.ErrorIssues)"}

"@

		if ($updateSQL) {
			try {
				Invoke-SqlCmd $sqlString -ServerInstance "$strMetricsSqlServer" -Database "$strMetricsDatabase" -ConnectionTimeout 120 2> $null
			}
			catch {
				write-host "ERROR: writing to SQL"
				$sqlString
			}
		}
		$sqlString = ""

		if (!($buildInfotable.IndexOf($line) % 500)) {
			if ($updateElastic) {
				try {
					$result = invoke-RestMethod -Uri http://$($strMetricsEsServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
					$result
				}
				catch {
					write-warning "Errors writing to ES - Bulk Mode"
				}
				if ($result.errors) {
					write-warning "Errors writing to ES - Bulk Mode"
					foreach ($resultItem in $result.items) {
						if ($resultItem.create.error) {
							$resultItem.create.error | convertto-json -depth 100
						}
					}
					write-warning "Attempting to narrow down the error..."
					$tmpBody = $null
					foreach ($esStringItem in $esString.split("`n")) {
						if ($esStringItem.split(":")[0] -like "*delete*") {
							$tmpBody += $esStringItem + "`n"
						}
						if ($esStringItem.split(":")[0] -like "*create*") {
							$tmpBody += $esStringItem + "`n"
						}
						if ($esStringItem.split(":")[0] -like "*Build_Key*") {
							$tmpBody += $esStringItem + "`n`n"

							try {
								$result2 = invoke-RestMethod -Uri http://$($strMetricsEsServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
								$result2
							}
							catch {
								write-warning "Errors writing to ES - Single Mode"
							}
							if ($result2.errors) {
								write-warning "Errors writing to ES - Single Mode"
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
				$result = invoke-RestMethod -Uri http://$($strMetricsEsServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
				$result
			}
			catch {
				write-warning "Errors writing to ES - Bulk Mode"
			}
			if ($result.errors) {
				write-warning "Errors writing to ES - Bulk Mode"
				foreach ($resultItem in $result.items) {
					if ($resultItem.create.error) {
						$resultItem.create.error | convertto-json -depth 100
					}
				}
				write-warning "Attempting to narrow down the error..."
				$tmpBody = $null
				foreach ($esStringItem in $esString.split("`n")) {
					if ($esStringItem.split(":")[0] -like "*delete*") {
						$tmpBody += $esStringItem + "`n"
					}
					if ($esStringItem.split(":")[0] -like "*create*") {
						$tmpBody += $esStringItem + "`n"
					}
					if ($esStringItem.split(":")[0] -like "*Build_Key*") {
						$tmpBody += $esStringItem + "`n`n"

						try {
							$result2 = invoke-RestMethod -Uri http://$($strMetricsEsServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
							$result2
						}
						catch {
							write-warning "Errors writing to ES - Single Mode"
						}
						if ($result2.errors) {
							write-warning "Errors writing to ES - Single Mode"
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
	
	if ($updateSQL) {
		if ($sqlString) {
			try {
				Invoke-SqlCmd $sqlString -ServerInstance "$strMetricsSqlServer" -Database "$strMetricsDatabase" -ConnectionTimeout 120
			}
			catch {
				write-host "ERROR: writing to SQL"
				$sqlString
			}
			$sqlString = ""
		}
	}
	
	
	$sqlString = @"
drop table dbo.$($strMetricsTable)Week
go

select * 
into dbo.$($strMetricsTable)Week
from dbo.$($strMetricsTable)
where dbo.$($strMetricsTable).Queue_Time > dateadd(week,-1,getdate()) 
go
"@
		
	if ($DEBUG) {$sqlString}
	
	if ($updateSQL) {
		try {
			Invoke-SqlCmd $sqlString -ServerInstance "$strMetricsSqlServer" -Database "$strMetricsDatabase" -ConnectionTimeout 120
		}
		catch {
			write-host "ERROR: updating SQL"
			$sqlString
		}
	}
	
	$sqlString = @"
drop table dbo.$($strMetricsTable)Month
go

select * 
into dbo.$($strMetricsTable)Month
from dbo.$($strMetricsTable)
where dbo.$($strMetricsTable).Queue_Time > dateadd(week,-5,getdate()) 
go
"@
		
	if ($DEBUG) {$sqlString}
	
	if ($updateSQL) {
		try {
			Invoke-SqlCmd $sqlString -ServerInstance "$strMetricsSqlServer" -Database "$strMetricsDatabase" -ConnectionTimeout 120
		}
		catch {
			write-host "ERROR: updating SQL"
			$sqlString
		}
	}
	
	
	$sqlString = @"
drop table dbo.$($strMetricsTable)Build
go

select * 
into dbo.$($strMetricsTable)Build
from dbo.$($strMetricsTable)
where dbo.$($strMetricsTable).RecordType = 'Build'
go
"@
		
	if ($DEBUG) {$sqlString}
	
	if ($updateSQL) {
		try {
			Invoke-SqlCmd $sqlString -ServerInstance "$strMetricsSqlServer" -Database "$strMetricsDatabase" -ConnectionTimeout 120
		}
		catch {
			write-host "ERROR: updating SQL"
			$sqlString
		}
	}
	
	$esString += @"
{"delete": {"_index": "timestamp","_type": "data","_id": "buildinfo"}}
{"create": {"_index": "timestamp","_type": "data","_id": "buildinfo"}}
{"ID": "buildinfo","LastRunTime": "$($thisRunDateTime)"}

"@

	if ($updateElastic -and $updateSQL) {
		try {
			invoke-RestMethod -Uri http://$($strMetricsEsServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
		}
		catch {
			write-host "ERROR: updating LastRunTime"
			$esString
		}
	}
}

main
