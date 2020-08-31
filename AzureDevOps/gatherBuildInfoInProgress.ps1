<#

	.SYNOPSIS
		Query VSTS for build info and write to databases

	.DESCRIPTION
		Queries VSTS for specific build info relating to specific build defs and time frames.
		Build data is conditionally written to ElasticSearch.
		Kibana is used for dashboard visualization.

	.INPUTS
		All inputs (saerver names, query options, time window, destructive db writes, etc.) are inferreed from the calling environment.  If not set, some defaults are taken.

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

	$scriptPath = Split-Path $script:MyInvocation.MyCommand.Path
	$scriptPath
	. "$($scriptPath)\gatherIncludes.ps1"

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
	
	$homeFolder = "\\STD-5276466\scratch$"

	# --- Override defaults with settings string

	loadConfiguration
	
	$strSqlTable = $jsonConfiguration.databases.sqlserver.tables.build
	$strElasticSearchIndex = $jsonConfiguration.databases.elasticsearch.indexes.build
	
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
	
	if ($DEBUG) {
		get-variable | format-table Name, Value
	}
	
	getTheBuilds
	
	exit 0
}


function getTheBuilds {
		
	$buildInfotable = [System.Collections.ArrayList]@()
	
	$dateTimeFieldNames = @()
		
    $mappings = (invoke-RestMethod -Uri "http://$($strElasticSearchServer):9200/$($strElasticSearchIndex)/_mappings").$($strElasticSearchIndex).mappings.data.properties
		
    foreach ($field in $mappings.PSObject.Properties) {
        if ($field.value.type -eq "date") {
            $dateTimeFieldNames += $field.name
        }
	}

	foreach ($tenant in $jsonConfiguration.tenants.name) {

		write-host "Tenant", $tenant

		$projectUrl = (Invoke-RestMethod "https://dev.azure.com/_apis/resourceAreas/$($resourceAreaId.Build)?accountName=$($tenant)&api-version=5.0-preview.1").locationUrl

		if ($PAT = ($PATSjson | convertfrom-json).$($tenant)) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)"))}
		} elseif ($PAT = ($ENV:PATSjson | convertfrom-json).$($tenant)) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)"))}
		} elseif ($PAT = ($jsonConfiguration.tenants | where { $_.name -like "$($tenant)" }).PAT) {
			$headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)"))}
		}
	
		write-host "Creating Agent/Pool Hash Table..."
		
		$agentPoolHash = @{ }
		foreach ($pool in ((Invoke-RestMethod -Uri $projectUrl/_apis/distributedtask/pools -Headers $headers).value)) {
			foreach ($agent in ((Invoke-RestMethod -Uri $projectUrl/_apis/distributedtask/pools/$($pool.id)/agents?includeCapabilities=true -Headers $headers).value)) {
				if (!($agentPoolHash.ContainsKey($agent.name))) {
					$agentPoolHash.add($agent.name, $pool.name)
				}
			}
		}

		if ($strProjects = ($jsonConfiguration.tenants | where { $_.name -like "$($tenant)" }).projects) {
			write-host "Using projects from jsonConfiguration"
		}
		
		foreach ($strProject in $strProjects) {

			$project = $strProject.name
		
			write-host "Project", "$($project)"
		
			# -- Query the vNext Builds for this Project
	
			$projectUrlProject = $projectUrl + '/' + $project

			$buildPipelines = $null
			
			if ($buildPipelines = ($strProject | where { $_.name -like "$($project)" }).buildpipelines) {
				write-host "Using buildpipelines from jsonConfiguration"
			} else {
				write-warning "No buildpipelines found in jsonConfiguration"
				write-host "##vso[task.logissue type=warning;] No buildpipelines found in jsonConfiguration"
			}

			foreach ($buildPipeline in $buildPipelines) {

				write-host "$($tenant) / $($project) / $($buildPipeline)"
				
				if ($buildPipeline -match '^[0-9]+$') {
					$buildPipelineIds = $buildPipeline
				} else {
					$buildPipelinesApi = "/_apis/build/definitions?api-version=4.0&name=$($buildPipeline)"
					write-host "$($tenant) / $($project) / $($buildPipeline) $($projectUrlProject + $buildPipelinesApi)"
					$buildPipelineIds = (((Invoke-RestMethod ($projectUrlProject + $buildPipelinesApi) -Headers $headers).Value | where { $_.Type.equals("build") }).id)
				}
				
				foreach ($id in $buildPipelineIds) {
				
					$buildDef = Invoke-RestMethod -Uri "$projectUrlProject/_apis/build/definitions/$id" -Headers $headers
					$quality = $buildDef.quality
				
					$buildsApi = '/_apis/build/builds?api-version=4.1&definitions=' + $id + '&statusFilter=InProgress'
					$Builds = (Invoke-RestMethod ($projectUrlProject + $buildsApi) -Headers $headers).Value
					$buildsApi = '/_apis/build/builds?api-version=4.1&definitions=' + $id + '&statusFilter=notStarted'
					$Builds += (Invoke-RestMethod ($projectUrlProject + $buildsApi) -Headers $headers).Value
						
					# -- loop thru all the builds for this build def ID
					
					foreach ($build in $builds) {
					
						if ($build.status -like "inProgress" -or $build.status -like "notStarted") {
						
							if ($build.queueTime -and ($build.definition.id -like "$($id)")) {
							
								write-host "$($tenant) / $($project) / $($buildPipeline) / $($build.definition.name) / $($build.buildNumber)"
								
								if ($DEBUG) {
									$build | convertto-json
								}
								
								$timeline = (Invoke-RestMethod ($build._links.timeline.href) -Headers $headers)
								
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
								
								$buildErrorIssues = $null
								if ($str1 = ($timeline.records.issues | where-object { $_.type -like "error" }).message) {
									$str2 = $str1.replace('\', '/')
									$str3 = ""
									foreach ($line in $str2) {
										$str3 += $line + "\n"
									}
									$str4 = $str3.Replace("`r`n", "\n")
									$str5 = $str4.Replace("`n", "\n")
									$str6 = $str5.Replace("`t", "	")
									$buildErrorIssues = $str6.replace('"', "'")
								}
								
								if ($buildErrorIssues) {
									$buildErrorIssues = $buildErrorIssues.Replace("\n", "`n").Replace('\', '/').Replace("`r`n", "\n").Replace("`n", "\n").Replace("`t", "	").Replace('"', "'")
								}
								
								if (($build.requestedFor.displayName -like "Microsoft.VisualStudio.Services.TFS") -or ($build.requestedFor.displayName -like "Project Collection Build Service*")) {
									$tmpRequestedFor = $build.requestedFor.displayName
								}
								else {
									$tmpRequestedFor = $build.requestedFor.id
								}
								
								$tmpURL = $projectUrlProject + "/_build/results?buildId=" + $build.id
								
								$tmpAgent = $null
								if ($build.status -like "notStarted") {
									try {
										$tmpAgent = ((Invoke-RestMethod -Uri "$projectUrl/_apis/distributedtask/pools/$($build.queue.pool.id)/jobrequests?completedRequestCount=1" -Headers $headers).value | `
												where { $_.owner.id -like $build.id }).matchedAgents.name | `
											sort-object | `
											get-unique
									}
									catch {
										write-warning "$projectUrl/_apis/distributedtask/pools/$($build.queue.pool.id)/jobrequests?completedRequestCount=1"
										write-host "##vso[task.logissue type=warning;] $projectUrl/_apis/distributedtask/pools/$($build.queue.pool.id)/jobrequests?completedRequestCount=1"
									}
								}
							
								$buildObject = new-object BuildRecord

								$buildObject.BuildKey =	$build.id
								$buildObject.BuildID =	$build.id
								$buildObject.TimeLineID =	$null
								$buildObject.ParentID =	$null
								$buildObject.BuildDef =	$build.definition.name
								$buildObject.BuildDefID =	$id
								$buildObject.BuildDefPath = ($buildDef.Path).Replace('\', '/')
								$buildObject.Quality =	$quality
								$buildObject.BuildNumber =	$build.buildNumber
								$buildObject.RecordType =	"Build"
								$buildObject.BuildJob =	$null
								$buildObject.Finished =	$build.status
								$buildObject.Compile_Status	=	$build.status
								$buildObject.Queue_Time =	([DateTime]::Parse($build.queueTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
								$buildObject.Queue_TimeZ =	([DateTime]::Parse($build.queueTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
								$buildObject.Elapsed_Time =	0
								if ($build.startTime) {
									$buildObject.Start_Time	=	([DateTime]::Parse($build.startTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
									$buildObject.Start_TimeZ	=	([DateTime]::Parse($build.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
									$buildObject.Wait_Time	=	(new-TimeSpan -start $build.queueTime -end $build.startTime).TotalMinutes
									$buildObject.Elapsed_Time =	(new-TimeSpan -start $build.startTime -end $thisRunDateTime).TotalMinutes
								}
								else {
									$buildObject.Start_Time	=	([DateTime]::Parse($build.queueTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
									$buildObject.Start_TimeZ	=	([DateTime]::Parse($build.queueTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
									$buildObject.Wait_Time	=	(new-TimeSpan -start $build.queueTime -end $thisRunDateTime).TotalMinutes
								}
								if ($build.status -like "notStarted") {
									$buildObject.Finish_Time	=	([DateTime]::Parse($build.queueTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
									$buildObject.Finish_TimeZ	=	([DateTime]::Parse($build.queueTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
								}
								else {
									$buildObject.Finish_Time	=	(get-date).toString("MM/dd/yyyy HH:mm:ss")
									$buildObject.Finish_TimeZ	=	(get-date).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
								}
								
								$buildObject.Tenant =	$Tenant
								$buildObject.Project =	$build.project.name
								$buildObject.Agent_Pool =	$build.queue.name
								$buildObject.Agent =	$tmpAgent
								$buildObject.Reason =	$build.Reason
								$buildObject.SourceGetVersion	=	$build.sourceVersion
								$buildObject.SourceRepo =	$build.repository.name
								$buildObject.SourceBranch =	$build.sourceBranch
								$buildObject.URL =	$tmpURL
								$buildObject.RequestedFor =	$tmpRequestedFor
								$buildObject.Demands =	$tmpDemands
								$buildObject.Variables =	$tmpVariables
								$buildObject.ErrorIssues =	$buildErrorIssues
								
								$null = $buildInfotable.Add($buildObject)

								$lastBuildRecord = $buildInfotable.count - 1

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
									
										# write-host $build.definition.name, $item.name
									
										if ($DEBUG) {
											$item | convertto-json
										}
										
										$tmpResult = $build.status
										
										$errorIssues = $null
										if (($str1 = ($item.issues | where-object { $_.type -like "error" }).message) -and (!($item.result -like "succeeded*"))) {
											$tmpResult = "inProgressFailed"
											$buildInfotable[$lastBuildRecord].Compile_Status = "inProgressFailed"
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
								
										$timeLineObject = new-object BuildRecord
										
										$tmpBuildKey = [string]$build.id + "_" + [string]$item.Parentid + "_" + [string]$item.id
										$tmpBuildJob = $item.name.replace('\', '/')
										$tmpBuildJob = [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($tmpBuildJob))
										# $tmpBuildJob = $tmpBuildJob -replace [char]0x00a0, ' '
										
										if ($item.workerName -and $agentPoolHash.$($item.workerName)) {
											$tmpAgentPool = $agentPoolHash.$($item.workerName)
										}
										else {
											$tmpAgentPool = $null
										}

										
										$timeLineObject.BuildKey =	$tmpBuildKey
										$timeLineObject.BuildID =	$build.id
										$timeLineObject.TimeLineID =	$item.id
										$timeLineObject.ParentID =	$item.Parentid
										$timeLineObject.RecordType =	$item.type
										$timeLineObject.BuildDef =	$build.definition.name
										$timeLineObject.BuildDefID =	$id
										$timeLineObject.BuildDefPath = ($buildDef.Path).Replace('\', '/')
										$timeLineObject.Quality =	$quality
										$timeLineObject.BuildNumber =	$build.buildNumber
										$timeLineObject.BuildJob =	$tmpBuildJob
										$timeLineObject.Finished =	$item.state
										$timeLineObject.Compile_Status =	$tmpResult
										$timeLineObject.Queue_Time =	([DateTime]::Parse($build.queueTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
										$timeLineObject.Queue_TimeZ =	([DateTime]::Parse($build.queueTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
										if ($item.startTime) {
											$timeLineObject.Start_Time =	([DateTime]::Parse($item.startTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
											$timeLineObject.Start_TimeZ =	([DateTime]::Parse($item.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
											$timeLineObject.Wait_Time =	(new-TimeSpan -start $build.queueTime -end $item.startTime).TotalMinutes
										}
										elseif ($build.startTime) {
											$timeLineObject.Start_Time =	([DateTime]::Parse($build.startTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
											$timeLineObject.Start_TimeZ =	([DateTime]::Parse($build.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
											$timeLineObject.Wait_Time =	(new-TimeSpan -start $build.queueTime -end $build.startTime).TotalMinutes
										}
										else {
											$timeLineObject.Start_Time =	([DateTime]::Parse($build.queueTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
											$timeLineObject.Start_TimeZ =	([DateTime]::Parse($build.queueTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
											$timeLineObject.Wait_Time =	(new-TimeSpan -start $build.queueTime -end $thisRunDateTime).TotalMinutes 
										}
										if ($item.finishTime) {
											$timeLineObject.Finish_Time =	([DateTime]::Parse($item.finishTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
											$timeLineObject.Finish_TimeZ =	([DateTime]::Parse($item.finishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
											if ($item.startTime) {
												$timeLineObject.Elapsed_Time	=	(new-TimeSpan -start $item.startTime -end $item.finishTime).TotalMinutes
											}
											elseif ($build.startTime) {
												$timeLineObject.Elapsed_Time	=	(new-TimeSpan -start $build.startTime -end $item.finishTime).TotalMinutes
											}
											else {
												$timeLineObject.Elapsed_Time	=	(new-TimeSpan -start $build.queueTime -end $item.finishTime).TotalMinutes
											}
										}
										else {
											$timeLineObject.Finish_Time =	(get-date).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
											$timeLineObject.Finish_TimeZ =	(get-date).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
											$timeLineObject.Elapsed_Time =	0
										}
										$timeLineObject.Tenant =	$Tenant
										$timeLineObject.Project =	$build.project.name
										$timeLineObject.Agent =	$item.workerName
										$timeLineObject.Agent_Pool =	$tmpAgentPool
										$timeLineObject.Reason =	$build.Reason
										$timeLineObject.SourceGetVersion =	$build.sourceVersion
										$timeLineObject.SourceRepo =	$build.repository.name
										$timeLineObject.SourceBranch =	$build.sourceBranch
										$timeLineObject.URL =	$tmpURL
										$timeLineObject.RequestedFor =	$tmpRequestedFor
										$timeLineObject.Demands =	$tmpDemands
										$timeLineObject.Variables =	$tmpVariables
										$timeLineObject.ErrorIssues =	$errorIssues

										$null = $buildInfotable.Add($timeLineObject)
									}
								}
							}
							else {
								write-host "Not an $($buildPipeline) build..."
							}
						}
						else {
							write-host "Build in progress..."
						}
					}
				}
			}
		}
	}

	
	""
	
	foreach ($inProgressStr in "inProgress", "inProgressFailed", "notStarted") {
		write-host "Deleting previous", $inProgressStr, "data..."
		while ($true) {
			$esString = @"
{"query": { "match": {"Compile_Status":"$inProgressStr"}}}

"@
			$ids = (invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/$($strElasticSearchIndex)/_search?size=1000 -Method POST -Body $esString -ContentType "application/json").hits.hits._id
			if ($ids) {
				$esString = ""
				foreach ($id in $ids) {
					
					$esString += @"
{"delete": {"_index": "$($strElasticSearchIndex)","_type": "_doc","_id": "$($id)"}}

"@
				}
				if ($esString) {
					invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
				}
			}
			else {
				break
			}
		}
	}


	write-host "Uploading to", $strElasticSearchServer
	
	$esString = $null
	$esStringBuilder = New-Object System.Text.StringBuilder(1024000)
	
	foreach ($line in $buildInfotable) {
	
		$tmpString = @"
{
	"create": {
		"_index": "$($strElasticSearchIndex)",
		"_type": "_doc",
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
	"BuildDefPath": "$($line.BuildDefPath)",
	"Quality": "$($line.Quality)",
	"BuildID": "$($line.BuildID)",
	"BuildJob": "$($line.BuildJob)",
	"BuildNumber": "$($line.BuildNumber)",
	"Compile_Status": "$($line.Compile_Status)",
	"Elapsed_Time": $($line.Elapsed_Time),
	"Finish_Time": "$($line.Finish_TimeZ)",
	"Finished": "$($line.Finished)",
	"ParentID": "$($line.ParentID)",
	"Tenant": "$($line.Tenant)",
	"Project": "$($line.Project)",
	"Queue_Time": "$($line.Queue_TimeZ)",
	"Reason": "$($line.Reason)",
	"RecordType": "$($line.RecordType)",
	"RequestedFor": "$($line.RequestedFor)",
	"Demands": "$($line.Demands)",
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

		if (!($buildInfotable.IndexOf($line) % $intElasticSearchBatchSize)) {
			if ($updateElastic) {
				$esString = $esStringBuilder.ToString()
				try {
					$result = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
					$result
				}
				catch {
					write-warning "Errors writing to ES - BulkA"
				}
				if ($result.errors) {
					write-warning "Errors writing to ES - BulkB"
					foreach ($resultItem in $result.items) {
						if ($resultItem.create.error) {
							$resultItem.create._id
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
								$result2 = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
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
			$esString = $null
			$null = $esStringBuilder.clear()
			$esStringBuilder = New-Object System.Text.StringBuilder(2048000)
		}
	}
	
	
	if ($updateElastic) {
		if ($esStringBuilder.length) {
			$esString = $esStringBuilder.ToString()
			try {
				$result = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
				$result
			}
			catch {
				write-warning "Errors writing to ES - BulkA"
			}
			<#
			if ($result.errors) {
				write-warning "Errors writing to ES - BulkB"
				foreach ($resultItem in $result.items) {
					if ($resultItem.create.error) {
						$resultItem.create._id
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
							$result2 = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
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
			#>
		}
		$esString = $null
		$null = $esStringBuilder.clear()
	}
}

main
