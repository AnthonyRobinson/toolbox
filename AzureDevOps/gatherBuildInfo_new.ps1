<#

	.SYNOPSIS
		Query VSTS for build info and write to databases

	.DESCRIPTION
		Queries VSTS for specific build info relating to specific build defs and time frames.
		Build data is conditionally written to SQL Server and ElasticSearch.
		Kibana is used for dashboard visualization.

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

class BuildRecord {
	[string]$BuildKey
	[string]$BuildID
	[string]$TimeLineID
	[string]$ParentID
	[string]$RecordType
	[string]$BuildDef
	[string]$BuildDefID
	[string]$Quality
	[string]$BuildNumber
	[string]$BuildJob
	[string]$Finished
	[string]$Compile_Status	 
	[DateTime]$Queue_Time
	[DateTime]$Queue_TimeZ
	[DateTime]$Start_Time
	[DateTime]$Start_TimeZ
	[float]$Wait_Time
	[DateTime]$Finish_Time
	[DateTime]$Finish_TimeZ
	[float]$Elapsed_Time
	[string]$Project
	[string]$Agent
	[string]$Agent_Pool
	[string]$Reason
	[string]$SourceGetVersion
	[string]$SourceRepo
	[string]$SourceBranch
	[string]$URL
	[string]$RequestedFor
	[string]$Demands
	[string]$Variables
	[string]$ErrorIssues
}

function main {

	$progressPreference = 'silentlyContinue'
	$thisRunDateTimeUTC = (get-date).ToUniversalTime()
	$thisRunDateTime = (get-date)
	$DEBUG = $ENV:DEBUG
	
	if (!(Get-Module -ListAvailable -name SqlServer)) {
		Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
		Install-module -Name SqlServer -Force -AllowClobber
	}
	
# --- Set some defaults

	if (!($projectUrl = $ENV:SYSTEM_TEAMFOUNDATIONSERVERURI)) {
		$projectUrl = "https://microsoft.visualstudio.com"
	}
	
	$deletePreviousElasticRecord = $true
	$deletePreviousSQLrecord = $true
	$updateElastic = $true
	$updateLastRunTime = $true
	$updateSQL = $true
	$processTimeLine = $true
	$homeFolder = "\\STD-5276466\scratch$"
	$strProjects = "Apps", "PaintStudio", "Universal Store"
	$strDefinitions = "Evoke", "Camera", "Mira", "OMG", "Paint", "Story", "Video", "Canvas3d", "3MFSDK", "GLTFSDK-CI", "Microsoft.Photos", "Photos", "WebUX", "BigPark", "GLTF", "FBX", "View3D"
	$strSqlDatabase = "Metrics"
	$strElasticSearchServer = "OMGRCAVM"
	$strSqlServer = "STD-5276466"
	$strSqlTable = "BuildInfo"
	$strElasticSearchIndex = "buildinfo"

# --- Override defaults with settings string

	if ($ENV:jsonConfiguration) {
	
		write-host "JSON Configuration found"
		
		$jsonConfiguration = $ENV:jsonConfiguration | convertfrom-json
		
		$jsonConfiguration | convertto-json -depth 100
		
		if ($jsonConfiguration.ElasticsearchServer) {
			$strElasticSearchServer = $jsonConfiguration.ElasticsearchServer
		}
		if ($jsonConfiguration.ElasticsearchIndex) {
			$strElasticSearchIndex = $jsonConfiguration.ElasticsearchIndex
		}
		if ($jsonConfiguration.SqlServer) {
			$strSqlServer = $jsonConfiguration.SqlServer
		}
		if ($jsonConfiguration.SqlDatabase) {
			$strSqlDatabase = $jsonConfiguration.SqlDatabase
		}
		if ($jsonConfiguration.SqlTable) {
			$strSqlTable = $jsonConfiguration.SqlTable
		}
		if ($jsonConfiguration.deletePreviousElasticRecord) {
			$deletePreviousElasticRecord = $jsonConfiguration.deletePreviousElasticRecord
		}
		if ($jsonConfiguration.deletePreviousSQLrecord) {
			$deletePreviousSQLrecord = $jsonConfiguration.deletePreviousSQLrecord
		}
		if ($jsonConfiguration.processTimeLine) {
			$processTimeLine = $jsonConfiguration.processTimeLine
		}
		if ($jsonConfiguration.updateElastic) {
			$updateElastic = $jsonConfiguration.updateElastic
		}
		if ($jsonConfiguration.updateLastRunTime) {
			$updateLastRunTime = $jsonConfiguration.updateLastRunTime
		}
		if ($jsonConfiguration.updateSQL) {
			$updateSQL = $jsonConfiguration.updateSQL
		}
		if ($jsonConfiguration.agentPoolNames) {
			$agentPoolNames = $jsonConfiguration.agentPoolNames
		}
	}
	
	$updateElastic = $true
	$updateLastRunTime = $true
	$updateSQL = $true
	
	$personalAccessToken = $ENV:PAT
	$OAuthToken = $ENV:System_AccessToken
	
	if ($OAuthToken) {
		$headers = @{Authorization = ("Bearer {0}" -f $OAuthToken) }
	}
	elseif ($personalAccessToken) {
		$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($personalAccessToken)")) }
	}
	else {
		write-error "Neither personalAccessToken nor OAuthToken are set"
	}
	
	$strStartDate = [datetime]"4/16/2019"
	$strEndDate = [datetime]"5/16/2019"
	
	get-variable | format-table Name, Value
		
	getTheBuilds
	
	exit 0
}




function getTheBuilds {
		
	$buildInfotable = [System.Collections.ArrayList]@()
	
	write-host "Creating Agent/Pool Hash Table..."
	
	$agentPoolHash = @{ }
	foreach ($pool in ((Invoke-RestMethod -Uri $projectUrl/_apis/distributedtask/pools -Headers $headers).value)) {
		foreach ($agent in ((Invoke-RestMethod -Uri $projectUrl/_apis/distributedtask/pools/$($pool.id)/agents?includeCapabilities=true -Headers $headers).value)) {
			if (!($agentPoolHash.ContainsKey($agent.name))) {
				$agentPoolHash.add($agent.name, $pool.name)
			}
		}
	}
	
	if ($jsonConfiguration.projects.name) {
		write-host "Using projects from jsonConfiguration"
		$strProjects = $jsonConfiguration.projects.name
	}
	
	foreach ($project in $strProjects) {
	
		write-host "$($project)"
		
		# -- Query the vNext Builds for this Project
	
		$projectUrlProject = $projectUrl + '/' + $project
		
		if (($jsonConfiguration.projects | where {$_.name -like "$($project)"}).buildpipelines) {
			write-host "Using definitions from jsonConfiguration"
			$strDefinitions = ($jsonConfiguration.projects | ? {$_.name -like "$($project)"}).buildpipelines
		}
		
		foreach ($definition in $strDefinitions) {
		
			write-host "$($project) / $($definition)"
		
			$definitionsApi = "/_apis/build/definitions?api-version=4.0&name=$($definition)*"
			
			# -- Get all the build def IDs
			
			write-host "$($project) / $($definition) $($projectUrlProject+$definitionsApi)"
			
			foreach ($id in ((Invoke-RestMethod ($projectUrlProject + $definitionsApi) -Headers $headers).Value | where { $_.Type.equals("build") }).id) {
			
				$buildDef = Invoke-RestMethod -Uri "$projectUrlProject/_apis/build/definitions/$id" -Headers $headers
				$quality = $buildDef.quality
				
				if ($DEBUG) {
					$buildDef | ConvertTo-json -depth 100 | out-file "$($homeFolder)\buildDef.$($buildDef.id).json" -encoding ascii
				}
			
				$buildsApi = '/_apis/build/builds?api-version=4.0&definitions=' + $id + '&minFinishTime=' + $strStartDate.ToString()
				$Builds = (Invoke-RestMethod ($projectUrlProject + $buildsApi) -Headers $headers).Value
				
				# -- loop thru all the builds for this build def ID
				
				foreach ($build in $builds) {
				
					if ([datetime]$build.finishTime -le $strStartDate) {
						write-host $build.id, $build.finishTime, "is older than our search window - skipping"
						continue
					}
					if ([datetime]$build.finishTime -ge $strEndDate) {
						write-host $build.id, $build.finishTime, "is newer than our search window - skipping"
						continue
					}
				
					if (!($build.status -like "inProgress")) {
					
						if ($build.queueTime -and $build.startTime -and $build.finishTime -and ($build.definition.name -like "$($definition)*")) {
						
							write-host "$($project) / $($definition) / $($build.definition.name) / $($build.buildNumber)"
							
							if ($DEBUG) {
								$build | ConvertTo-json -depth 100 | out-file "$($homeFolder)\build.$($build.id).json" -encoding ascii
							}
							
							$timeline = (Invoke-RestMethod ($build._links.timeline.href) -Headers $headers)
							
							if ($DEBUG) {
								$timeline | ConvertTo-json -depth 100 | out-file "$($homeFolder)\timeline.$($timeline.id).json" -encoding ascii
							}
							
							#							$tmpBuildDef = (Invoke-RestMethod ($build.definition.url) -Headers $headers)
							
							$tmpDemands = $null
							if ($build.parameters) {
								foreach ($field in ($build.parameters | convertfrom-json).PSObject.Properties) {
									$tmpDemands += "$($field.name)=$($field.value)\n"
								}
							}
							else {
								foreach ($demand in $buildDef.demands) {
									$tmpDemands += $demand + "\n"
								}
							}
							if ($tmpDemands) {
								$tmpDemands = $tmpDemands.Replace("\n", "`n").Replace('\', '/').Replace("`r`n", "\n").Replace("`n", "\n").Replace("`t", "	").Replace('"', "'")
							}
							
							$tmpVariables = $null
							if ($buildDef.variables) {
								foreach ($name in ($buildDef.variables | Get-Member -MemberType NoteProperty).Name) {
									$tmpValue = $null
									if ($tmpValue = $buildDef.variables.$($name).value) {
										$tmpValue = $tmpValue.replace('"', "'")
										$tmpValue = $tmpValue.replace('\', '/')
									}
									$tmpVariables += $name + "=" + $tmpValue + "\n"
								}
							}
							if ($tmpVariables) {
								$tmpVariables = $tmpVariables.Replace("\n", "`n").Replace('\', '/').Replace("`r`n", "\n").Replace("`n", "\n").Replace("`t", "	").Replace('"', "'")
							}
	
							$errorIssues = $null
							if ($str1 = ($timeline.records.issues | where-object { $_.type -like "error" }).message) {
								$str2 = $str1.replace('\', '/')
								$str3 = ""
								foreach ($line in $str2) {
									$str3 += $line + "\n"
								}
								$str4 = $str3.Replace("`r`n", "\n")
								$str5 = $str4.Replace("`n", "\n")
								$str6 = $str5.Replace("`t", "	")
								$errorIssues = $str6.replace('"', "'")
							}
							
							if ($errorIssues) {
								$errorIssues = $errorIssues.Replace("\n", "`n").Replace('\', '/').Replace("`r`n", "\n").Replace("`n", "\n").Replace("`t", "	").Replace('"', "'")
							}
							
							if (($build.requestedFor.displayName -like "Microsoft.VisualStudio.Services.TFS") -or ($build.requestedFor.displayName -like "Project Collection Build Service*")) {
								$tmpRequestedFor = $build.requestedFor.displayName
							}
							else {
								$tmpRequestedFor = $build.requestedFor.id
							}
							
							$tmpURL = $projectUrlProject + "/_build/results?buildId=" + $build.id
							
							$tmpobject = new-object BuildRecord

							$tmpobject.BuildKey = $build.id
							$tmpobject.BuildID = $build.id
							$tmpobject.TimeLineID = $null
							$tmpobject.ParentID = $null
							$tmpobject.BuildDef = $build.definition.name
							$tmpobject.BuildDefID = $id
							$tmpobject.Quality = $quality
							$tmpobject.BuildNumber = $build.buildNumber
							$tmpobject.RecordType = "Build"
							$tmpobject.BuildJob = $null
							$tmpobject.Finished = $build.status
							$tmpobject.Compile_Status = $build.result			
							$tmpobject.Queue_Time = ([DateTime]::Parse($build.queueTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject.Start_Time = ([DateTime]::Parse($build.startTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject.Finish_Time = ([DateTime]::Parse($build.finishTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject.Queue_TimeZ = ([DateTime]::Parse($build.queueTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject.Start_TimeZ = ([DateTime]::Parse($build.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject.Finish_TimeZ = ([DateTime]::Parse($build.finishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
							$tmpobject.Wait_Time = (new-TimeSpan -start $build.queueTime -end $build.startTime).TotalMinutes
							$tmpobject.Elapsed_Time = (new-TimeSpan -start $build.startTime -end $build.finishTime).TotalMinutes
							$tmpobject.Project = $build.project.name
							$tmpobject.Agent_Pool = $build.queue.name
							$tmpobject.Agent = $null
							$tmpobject.Reason = $build.Reason
							$tmpobject.SourceGetVersion = $build.sourceVersion
							$tmpobject.SourceRepo = $build.repository.name
							$tmpobject.SourceBranch = $build.sourceBranch
							$tmpobject.URL = $tmpURL
							$tmpobject.RequestedFor = $tmpRequestedFor
							$tmpobject.Demands = $tmpDemands
							$tmpobject.Variables = $tmpVariables
							$tmpobject.ErrorIssues = $errorIssues
							
							$null = $buildInfotable.Add($tmpobject)

							if ($processTimeLine) {
											
								<#							
								$queueNameHash = $null
								$queueNameHash = @{}
								
								foreach ($type in "Phase", "Job", "Task") {
									foreach ($item in ($timeline.records | where {$_.type -like $type})) {
										# write-host $item.type, $item.id, $item.parentId, $item.order  $item.name
										if ($queueNameHash.ContainsKey($item.id)) {
											write-warning -message "Duplicate $item.id in queueNameHash"
											Write-Host "##vso[task.logissue type=warning;] Duplicate $item.id in queueNameHash"
										} else {
											if ($type -like "Phase") {
												$tmpQueueName = $null
												$tmpName = $item.type + "_" + $item.order
												if ($tmpUrl = (($buildDef.process.phases | where {$_.refName -like $tmpName}).target.queue.url)) {
													try {
														$tmpQueue = invoke-restmethod $tmpUrl -headers $headers
													}
													catch {
														write-warning "invoke-restmethod $tmpUrl failed"
														Write-Host "##vso[task.logissue type=warning;] invoke-restmethod $tmpUrl failed"
													}
													$tmpQueueName = $tmpQueue.name
													if ($DEBUG) {
														$tmpQueue | ConvertTo-json -depth 100 | out-file "$($homeFolder)\process.phases.target.queue.$(random).json" -encoding ascii
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
#>

								foreach ($item in $timeline.records) {
								
									# write-host "$($project) / $($definition) / $($build.definition.name) / $($build.buildNumber)/$($item.type)"
								
									if ($DEBUG) {
										$item | ConvertTo-json -depth 100 | out-file "$($homeFolder)\item.$($item.id).json" -encoding ascii
									}
									
									$errorIssues = $null
									if ($str1 = ($item.issues | where-object { $_.type -like "error" }).message) {
										$str2 = $str1.Replace('\', '/')
										$str3 = ""
										foreach ($line in $str2) {
											$str3 += $line + "\n"
										}
										$str4 = $str3.Replace("`r`n", "\n")
										$str5 = $str4.Replace("`n", "\n")
										$str6 = $str5.Replace("`t", "	")
										$errorIssues = $str6.Replace('"', "'")
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
												if ($tmp = ($logData | select-string "Rld schedule created") -split ("'")) {
													if ($logFolder = $tmp[$tmp.count - 2]) {
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
										$errorIssues = $errorIssues.Replace("\n", "`n").Replace('\', '/').Replace("`r`n", "\n").Replace("`n", "\n").Replace("`t", "	").Replace('"', "'")
									}
							
									$tmpobject = new-object BuildRecord
									
									$tmpBuildKey = [string]$build.id + "_" + [string]$item.Parentid + "_" + [string]$item.id
									$tmpBuildJob = $item.name.replace('\', '/')
									$tmpBuildJob = $tmpBuildJob -replace [char]0x00a0, ' '
									
									if ($item.startTime) {
										$tmpStartTime = $item.startTime
									}
									else {
										$tmpStartTime = $build.startTime
									}

									if ($item.finishTime) {
										$tmpFinishTime = $item.finishTime
									}
									else {
										$tmpFinishTime = $build.finishTime
									}
									
									if ($item.workerName -and $agentPoolHash.$($item.workerName)) {
										$tmpAgentPool = $agentPoolHash.$($item.workerName)
									}
									else {
										$tmpAgentPool = $null
									}
									
									$tmpobject.BuildKey = $tmpBuildKey
									$tmpobject.BuildID = $build.id
									$tmpobject.TimeLineID = $item.id
									$tmpobject.ParentID = $item.Parentid
									$tmpobject.RecordType = $item.type
									$tmpobject.BuildDef = $build.definition.name
									$tmpobject.BuildDefID = $id
									$tmpobject.Quality = $quality
									$tmpobject.BuildNumber = $build.buildNumber
									$tmpobject.BuildJob = $tmpBuildJob
									$tmpobject.Finished = $item.state
									$tmpobject.Compile_Status = $item.result			
									$tmpobject.Queue_Time = ([DateTime]::Parse($build.queueTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
									$tmpobject.Queue_TimeZ = ([DateTime]::Parse($build.queueTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
									$tmpobject.Start_Time = ([DateTime]::Parse($tmpStartTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
									$tmpobject.Start_TimeZ = ([DateTime]::Parse($tmpStartTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
									$tmpobject.Wait_Time = (new-TimeSpan -start $build.queueTime -end $tmpStartTime).TotalMinutes
									$tmpobject.Finish_Time = ([DateTime]::Parse($tmpFinishTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
									$tmpobject.Finish_TimeZ = ([DateTime]::Parse($tmpFinishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
									$tmpobject.Elapsed_Time = (new-TimeSpan -start $tmpStartTime -end $tmpFinishTime).TotalMinutes
									$tmpobject.Project = $build.project.name
									$tmpobject.Agent = $item.workerName
									$tmpobject.Agent_Pool = $tmpAgentPool
									$tmpobject.Reason = $build.Reason
									$tmpobject.SourceGetVersion = $build.sourceVersion
									$tmpobject.SourceRepo = $build.repository.name
									$tmpobject.SourceBranch = $build.sourceBranch
									$tmpobject.URL = $tmpURL
									$tmpobject.RequestedFor = $tmpRequestedFor
									$tmpobject.Demands = $tmpDemands
									$tmpobject.Variables = $tmpVariables
									$tmpobject.ErrorIssues = $errorIssues

									$null = $buildInfotable.Add($tmpobject)
								}
							}
						}
						else {
							write-host "Not an $($definition) build..."
						}
					}
					else {
						write-host "Build in progress..."
					}
				}
			}
		}
	}
	
	
	write-host "Uploading to DBs..."
	
	$esString = ""
	$sqlString = ""
	
	$esStringBuilder = New-Object System.Text.StringBuilder(1024000)
	$sqlStringBuilder = New-Object System.Text.StringBuilder(2048)
	
	
	foreach ($line in $buildInfotable) {
	
		if ($deletePreviousSQLrecord) {
			$sqlString = @"
DELETE from $($strSqlTable)
WHERE Build_Key='$($line.BuildKey)';
GO

"@
			$null = $sqlStringBuilder.Append($sqlString)
		}
		
		$tmpVariables = $line.Variables -replace "'", '"' -replace '\$\(', '\('
		$tmpDemands = $line.Demands -replace "'", '"' -replace '\$\(', '\('
		$tmpErrorIssues = $line.ErrorIssues -replace "'", '"' -replace '\$\(', '\('
		$tmpBuildJob = $line.BuildJob -replace '\$\(', '\('
				
		$sqlString = @"
INSERT INTO $($strSqlTable) (
	Build_Key,
	BuildID,
	TimeLineID,
	ParentID,
	RecordType,
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
		$null = $sqlStringBuilder.Append($sqlString)

		if ($deletePreviousElasticRecord) {
			$tmpString = @"
{
	"delete": {
		"_index": "$($strElasticSearchIndex)",
		"_type": "data",
		"_id": "$($line.BuildKey)"
	}
}
"@
			$esString = $tmpString | convertfrom-json | convertto-json -compress
			$esString += "`n"
			$null = $esStringBuilder.Append($esString)
		}

		$tmpString = @"
{
	"create": {
		"_index": "$($strElasticSearchIndex)",
		"_type": "data",
		"_id": "$($line.BuildKey)"
	}
}
"@
		$esString = $tmpString | convertfrom-json | convertto-json -compress
		$esString += "`n"
		$null = $esStringBuilder.Append($esString)

		$tmpString = @"
{
	"Build_Key": "$($line.BuildKey)",
	"Agent": "$($line.Agent)",
	"Agent_Pool": "$($line.Agent_Pool)",
	"BuildDef": "$($line.BuildDef)",
	"BuildDefID": "$($line.BuildDefID)",
	"Quality": "$($line.Quality)",
	"BuildID": "$($line.BuildID)",
	"BuildJob": "$($line.BuildJob)",
	"BuildNumber": "$($line.BuildNumber)",
	"Compile_Status": "$($line.Compile_Status)",
	"Elapsed_Time": $($line.Elapsed_Time),
	"Finish_Time": "$($line.Finish_TimeZ)",
	"Finished": "$($line.Finished)",
	"ParentID": "$($line.ParentID)",
	"Project": "$($line.Project)",
	"Queue_Time": "$($line.Queue_TimeZ)",
	"Reason": "$($line.Reason)",
	"RecordType": "$($line.RecordType)",
	"RequestedFor": "$($line.RequestedFor)",
	"Demands": "$($line.demands)",
	"Variables": "$($line.Variables)",
	"SourceGetVersion": "$($line.SourceGetVersion)",
	"SourceRepo": "$($line.SourceRepo)",
	"SourceBranch": "$($line.SourceBranch)",
	"URL": "$($line.URL)",
	"Start_Time": "$($line.Start_TimeZ)",
	"TimeLineID": "$($line.TimeLineID)",
	"Wait_Time": $($line.Wait_Time),
	"Error_Issues": "$($line.ErrorIssues)"
}
"@
		$esString = $tmpString | convertfrom-json | convertto-json -compress
		$esString += "`n"
		$esString += "`n"
		$null = $esStringBuilder.Append($esString)

		if ($updateSQL) {
#			$sqlStringBuilder.length
			$sqlString = $sqlStringBuilder.ToString()
			try {
#				Invoke-SqlCmd $sqlString -ServerInstance "$strSqlServer" -Database "$strSqlDatabase" -ConnectionTimeout 120 # 2> $null
			}
			catch {
				write-host "ERROR: writing to SQL 1"
				$sqlString
			}
		}
		
		$sqlString = $null
		$null = $sqlStringBuilder.clear()
        $sqlStringBuilder = New-Object System.Text.StringBuilder(2048)

		if (!($buildInfotable.IndexOf($line) % 1000)) {
			if ($updateElastic) {
				$esString = $esStringBuilder.ToString()
				try {
#					$result = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
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
#								$result2 = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
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
			$null = $esStringBuilder.clear()
			$esStringBuilder = New-Object System.Text.StringBuilder(2048000)
		}
	}
	
	
	if ($updateElastic) {
		if ($esStringBuilder.length) {
			$esString = $esStringBuilder.ToString()
			try {
#				$result = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
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
#							$result2 = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
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
		$null = $esStringBuilder.clear()
		$esStringBuilder = New-Object System.Text.StringBuilder(2048000)
	}
	
	
	if ($updateSQL) {
		if ($sqlStringBuilder.length) {
			$sqlString = $sqlStringBuilder.ToString()
			try {
#				Invoke-SqlCmd $sqlString -ServerInstance "$strSqlServer" -Database "$strSqlDatabase" -ConnectionTimeout 120
			}
			catch {
				write-host "ERROR: writing to SQL 2"
				$sqlString
			}
		}
		$null = $sqlStringBuilder.clear()
		$sqlStringBuilder = New-Object System.Text.StringBuilder(2048)
	}
	
	
	write-host "Creating SQL Week, Month, and Build-Only Tables..."
	
	$sqlString = @"
drop table dbo.$($strSqlTable)Week
go

select * 
into dbo.$($strSqlTable)Week
from dbo.$($strSqlTable)
where dbo.$($strSqlTable).Queue_Time > dateadd(week,-1,getdate()) 
go

drop table dbo.$($strSqlTable)Month
go

select * 
into dbo.$($strSqlTable)Month
from dbo.$($strSqlTable)
where dbo.$($strSqlTable).Queue_Time > dateadd(week,-5,getdate()) 
go

drop table dbo.$($strSqlTable)Build
go

select * 
into dbo.$($strSqlTable)Build
from dbo.$($strSqlTable)
where dbo.$($strSqlTable).RecordType = 'Build'
go
"@
		
	if ($DEBUG) { $sqlString }
	
	if ($updateSQL) {
		try {
#			Invoke-SqlCmd $sqlString -ServerInstance "$strSqlServer" -Database "$strSqlDatabase" -ConnectionTimeout 120
		}
		catch {
			write-host "ERROR: updating SQL"
			$sqlString
		}
	}
	
	if ($updateLastRunTime) {
		write-host "Updating LastRunTime time stamps..."
		$esString += @"
{"delete": {"_index": "timestamp","_type": "data","_id": "$($strElasticSearchIndex)"}}
{"create": {"_index": "timestamp","_type": "data","_id": "$($strElasticSearchIndex)"}}
{"ID": "$($strElasticSearchIndex)","LastRunTime": "$($thisRunDateTimeUTC)"}

"@
		try {
#			invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
		}
		catch {
			write-host "ERROR: updating LastRunTime"
			$esString
		}
	}
}

main
