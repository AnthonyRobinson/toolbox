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
	$DEBUG = $false

	if (!(Get-Module -ListAvailable -name SqlServer)) {
		Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
		Install-module -Name SqlServer -Force -AllowClobber
	}

	# --- Set some defaults

	if (!($projectUrl = $ENV:SYSTEM_TEAMFOUNDATIONSERVERURI)) {
		$projectUrl = "https://_CompanyNameHere_cloud.visualstudio.com/"
	}

	$homeFolder = "c:\tmp"

	# --- Override defaults with settings string

	loadConfiguration

	$strSqlTable = $jsonConfiguration.databases.sqlserver.tables.build
	$strESBuildIndex = $jsonConfiguration.databases.elasticsearch.indexes.build
	$strESTestIndex = $jsonConfiguration.databases.elasticsearch.indexes.test


	if (!($minutesBack = $ENV:minutesBack)) {
		try {
			$tmp = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/timestamp/_doc/$($strESBuildIndex)
			$lastRunDateTime = [datetime]([string]$tmp._source.LastRunTime)
			write-host "INFO: last run was at" $lastRunDateTime
			$minutesBack = (new-TimeSpan -start $thisRunDateTimeUTC -end $lastRunDateTime).TotalMinutes
		}
		catch {
			$minutesBack = -200
		}
	}

	$minutesBack = $minutesBack - 5

	$strStartDate = (get-date).AddMinutes($minutesBack)

	write-host "INFO: using minutesBack of" $minutesBack "and strStartDate" $strStartDate

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

	$strStartDate = (get-date).AddMinutes($minutesBack).ToUniversalTime()

	$buildInfotable = [System.Collections.ArrayList]@()
	$testInfotable = [System.Collections.ArrayList]@()

	$dateTimeFieldNames = @()

	try {
		$mappings = (invoke-RestMethod -Uri "http://$($strElasticSearchServer):9200/$($strESBuildIndex)/_mappings").$($strESBuildIndex).mappings.data.properties
		foreach ($field in $mappings.PSObject.Properties) {
			if ($field.value.type -eq "date") {
				$dateTimeFieldNames += $field.name
			}
		}
	}
	catch {
		write-warning "Unable to get index mappings"
		write-host "##vso[task.logissue type=warning;] Unable to get index mappings"
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

		$buildTrackerJobHash = @{}

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

					if ($DEBUG) {
						$buildDef | ConvertTo-json -depth 100 | out-file "$($homeFolder)\$($buildDef.id).buildDef.json" -encoding ascii
					}

					$buildsApi = '/_apis/build/builds?api-version=4.0&definitions=' + $id + '&minFinishTime=' + $strStartDate.ToString()
					$Builds = (Invoke-RestMethod ($projectUrlProject + $buildsApi) -Headers $headers).Value

					# -- loop thru all the builds for this build def ID

					foreach ($build in $builds) {

						if (!($build.status -like "inProgress")) {

							if ($build.queueTime -and $build.startTime -and $build.finishTime) {

								write-host "$($tenant) / $($project) / $($buildPipeline) / $($build.definition.name) / $($build.buildNumber)"

								$testLanguage = $null
								$buildTestLanguage = $null

								if ($DEBUG) {
									$build | ConvertTo-json -depth 100 | out-file "$($homeFolder)\$($buildDef.id).$($build.id).build.json" -encoding ascii
								}

								$timeline = (Invoke-RestMethod ($build._links.timeline.href) -Headers $headers)

								if ($DEBUG) {
									$timeline | ConvertTo-json -depth 100 | out-file "$($homeFolder)\$($buildDef.id).$($build.id).$($timeline.id).timeline.json" -encoding ascii
								}

								#	$tmpBuildDef = (Invoke-RestMethod ($build.definition.url) -Headers $headers)

								# --- Get the build's demands

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

								# --- Get the build's variables

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

								# --- Get the build's error issues at the build record level

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

								# --- Prepare to get the build's test results

								$testFailures = $null
								# $testFailuresStringBuilder = New-Object System.Text.StringBuilder(500mb)
								$testFailuresHashShort = @{}
								$testFailuresHashLong = @{}
								$testRunIdHash = @{}
								$testFailCount = 0
								$testPassCount = 0
								$testTotalCount = 0
								$testFailPct = 0
								$testPassPct = 0

								# --- Check to see if the build has any test results

								$testResultsSummary = Invoke-RestMethod "https://$($tenant).vstmr.visualstudio.com/$($project)/_apis/testresults/resultsummarybybuild?buildId=$($build.id)" -Headers $headers

								if ($DEBUG) {
									$testResultsSummary | ConvertTo-json -depth 100 | out-file "$($homeFolder)\$($buildDef.id).$($build.id).$($timeline.id).testResultsSummary.json" -encoding ascii
								}

								if ($testResultsSummary.aggregatedResultsAnalysis.totalTests) {
									$thisBuildHasTestResults = $true
								} else {
									if ($project -like "One") {
										$thisBuildHasTestResults = $true
									} else {
										$thisBuildHasTestResults = $false
									}
								}

#								if ($build.result -like "Failed") {
								if ($thisBuildHasTestResults) {

									if ($testResultsByBuild = Invoke-RestMethod "https://$($tenant).vstmr.visualstudio.com/$($project)/_apis/tcm/ResultsByBuild?buildId=$($build.id)" -Headers $headers) {
										if ($DEBUG) {
											$testResultsByBuild | ConvertTo-json -depth 100 | out-file "$($homeFolder)\$($buildDef.id).$($build.id).$($timeline.id).testResultsByBuild.json" -encoding ascii
										}
										if (!($testLanguage)) {
											foreach ($lang in "en", "ar", "de", "zh-hant") {
												if ($testResultsByBuild.value.testCaseTitle -match "($($lang))") {
													$testLanguage = $lang
													break
												}
											}
										}

										$Atilde = 0xc3 -as [char]
										$Ssect = 0xa7 -as [char]
										
										foreach ($value in $testResultsByBuild.value) {

											$tmpTestKey = [string]$build.id + "_" + [string]$value.id + "_" + [string]$value.runId  + "_" + [string]$value.refId
											$tmpURL = $projectUrlProject + "/_build/results?buildId=" + $build.id
											
											$tmpAutomatedTestName		= $($value.automatedTestName).Replace('\', '/').Replace('"', "'")
											$tmpAutomatedTestName		= [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($tmpAutomatedTestName))
											$tmpAutomatedTestName		= $tmpAutomatedTestName.TrimEnd(" -")
											
											$tmpAutomatedTestStorage	= $($value.automatedTestStorage).Replace('\', '/').Replace('"', "'")
											$tmpAutomatedTestStorage	= [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($tmpAutomatedTestStorage))
											
											$tmpTestCaseTitle			= $($value.testCaseTitle).Replace('\', '/').Replace('"', "'").Replace('\', '/').Replace('"', "'")
											$tmpTestCaseTitle			= [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($tmpTestCaseTitle))

											$testObject = new-object TestRecord

											$testObject.TestKey = $tmpTestKey
											$testObject.BuildID = $build.id
											$testObject.BuildDef = $build.definition.name
											$testObject.BuildDefID = $id
											$testObject.BuildDefPath = ($buildDef.Path).Replace('\', '/')
											$testObject.Quality = $quality
											$testObject.BuildNumber = $build.buildNumber
											$testObject.Outcome = $value.outcome
											$testObject.Finish_Time = ([DateTime]::Parse($build.finishTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
											$testObject.Finish_TimeZ = ([DateTime]::Parse($build.finishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
											$testObject.Tenant = $tenant
											$testObject.Project = $build.project.name
											$testObject.Agent_Pool = $build.queue.name
											$testObject.Agent = $null
											$testObject.Language = $testLanguage
											<#
											$testObject.automatedTestName = $($value.automatedTestName).Replace('\', '/').Replace('"', "'").Replace('ç','c').Replace($Atilde,'A').Replace($Ssect,'S') -replace "Fran.*ais","Fran..ais"
											$testObject.automatedTestStorage = $($value.automatedTestStorage).Replace('\', '/').Replace('"', "'").Replace('ç','c').Replace($Atilde,'A').Replace($Ssect,'S') -replace "Fran.*ais","Fran..ais"
											$testObject.testCaseTitle = $($value.testCaseTitle).Replace('\', '/').Replace('"', "'").Replace('ç','c').Replace($Atilde,'A').Replace($Ssect,'S') -replace "Fran.*ais","Fran..ais"
											#>											
											$testObject.automatedTestName = $tmpAutomatedTestName
											$testObject.automatedTestStorage = $tmpAutomatedTestStorage
											$testObject.testCaseTitle = $tmpTestCaseTitle
											
											$testObject.owner = $value.owner
											$testObject.duration = ($value.durationInMs / 1000)
											$testObject.URL = $tmpURL

											$null = $testInfotable.Add($testObject)
										}
									}

									$body = @"
{
	"contributionIds": [
		"ms.vss-test-web.test-tab-build-content",
		"ms.vss-test-web.test-tab-build-summary-data-provider",
		"ms.vss-test-web.test-tab-build-resultdetails-data-provider",
		"ms.vss-build-web.ci-results-data-provider"
	],
	"dataProviderContext": {
		"properties": {
			"sourcePage": {
				"url": "$($projectUrl)/$($project)/_build/results?buildId=$($build.id)&view=ms.vss-test-web.build-test-results-tab",
				"routeId": "ms.vss-build-web.ci-results-hub-route",
				"routeValues": {
					"project": "$($project)",
					"viewname": "build-results",
					"controller": "ContributedPage",
					"action": "Execute"
				}
			}
		}
	}
}
"@
									# https://msazure.vstmr.visualstudio.com/One/_apis/tcm/ResultsByBuild?buildId=23206552

									$body = $body | convertfrom-json | convertto-json -compress -depth 100
									if ($testRunResponse = Invoke-RestMethod "$($projectUrl)/_apis/Contribution/HierarchyQuery/project/$($project)?api-version=5.0-preview.1" -Method POST -Body $body -ContentType "application/json" -header $headers) {

										# "*** testRunResponse ***"

										if ($DEBUG) {
											$testRunResponse | ConvertTo-json -depth 100 | out-file "$($homeFolder)\$($buildDef.id).$($build.id).$($timeline.id).testRunResponse.json" -encoding ascii
										}

										write-host "$($tenant) / $($project) / $($buildPipeline) / $($build.definition.name) / $($build.buildNumber) / TestResponse"

										$testPassCount = $testRunResponse.dataProviders.'ms.vss-test-web.test-tab-build-summary-data-provider'.aggregatedResultsAnalysis.resultsByOutcome.'2'.count
										$testFailCount = $testRunResponse.dataProviders.'ms.vss-test-web.test-tab-build-summary-data-provider'.aggregatedResultsAnalysis.resultsByOutcome.'3'.count
										$testTotalCount = $testPassCount + $testFailCount

										if ($testRunResponse.dataProviders.'ms.vss-test-web.test-tab-build-summary-data-provider'.testFailures) {

											# "*** testFailures ***"

											foreach ($failuresType in "newFailures", "existingFailures") {
												foreach ($testResult in $testRunResponse.dataProviders.'ms.vss-test-web.test-tab-build-summary-data-provider'.testFailures.$($failuresType).testResults) {

													# "*** testResult $failuresType ***"

													if ($testRunId = $testResult.testRunId) {
														if ($testRunIdHash.ContainsKey($testRunId)) {
															$testRunResults = $testRunIdHash[$testRunId]
														} else {
															if (!($thisBuildHasTestResults)) {write-host "*** BAD PREDICTION ***"}
															write-host "$($tenant) / $($project) / $($buildPipeline) / $($build.definition.name) / $($build.buildNumber) / testResponse / testRunResults"
															$testRunResults = Invoke-RestMethod "$($projectUrlProject)/_apis/test/runs/$($testRunId)/results?api-version=5.0" -header $headers
															$null = $testRunIdHash.Add($testRunId, $testRunResults)
														}

														# "*** testRunId ***"

														if ($DEBUG) {
															$testRunResults | ConvertTo-json -depth 100 | out-file "$($homeFolder)\$($buildDef.id).$($build.id).$($timeline.id).$($testRunId).testRunResults.json" -encoding ascii
														}

														foreach ($failedOutcome in ($testRunResults.value | where {$_.outcome -like "Failed"})) {

															# "*** failedOutcome ***"

															$strTmp1 = "Test Failure: " + $($failedOutcome.testRun.name) + " / "+ $($failedOutcome.testCase.name)

															if (!($testFailuresHashShort.ContainsKey($strTmp1))) {
																$null = $testFailuresHashShort.Add($strTmp1, 1)
															}

															$strTmp2 = "testRunName: $($failedOutcome.testRun.name)\ntestCaseName: $($failedOutcome.testCase.name)\ncomputerName: $($failedOutcome.computerName)\nerrorMessage: $($failedOutcome.errorMessage)\n\n"

															if (!($testFailuresHashLong.ContainsKey($strTmp2))) {
																$null = $testFailuresHashLong.Add($strTmp2, 1)
															}
														}
													}
												}
											}
										}
									}
								}

								if ($testTotalCount) {
									if ($testFailCount) {
										$testFailPct = ($testFailCount / $testTotalCount) * 100
									}
									if ($testPassCount) {
										$testPassPct = ($testPassCount / $testTotalCount) * 100
									}
								}

								if ($testFailuresHashShort.count) {
									$buildErrorIssues += ($testFailuresHashShort.GetEnumerator().name | sort-object | Select -Unique) -join '\n'
								}
								if ($testFailuresHashLong.count) {
									$testFailures = ($testFailuresHashLong.GetEnumerator().name | sort-object | Select -Unique) -join '\n'
								}

								$aUmlat = 0xe4 -as [char]
								$uUmlat = 0xdc -as [char]

								if ($buildErrorIssues) {
									$buildErrorIssues = $buildErrorIssues.Replace("\n", "`n").Replace('\', '/').Replace("`r`n", "\n").Replace("`n", "\n").Replace("`t", "	").Replace('"', "'")
									$buildErrorIssues = [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($buildErrorIssues))
									if (!($buildTestLanguage)) {
										$buildTestLanguage = $testLanguage
										foreach ($lang in "en", "ar", "de", "zh-hant") {
											if ($buildErrorIssues -match "($($lang))") {
												$buildTestLanguage = $lang
												break
											}
										}
									}
								}
								
								if ($testFailures) {
									$testFailures = $testFailures.Replace("\n", "`n").Replace('\', '/').Replace("`r`n", "\n").Replace("`n", "\n").Replace("`t", "	").Replace('"', "'")
									$testFailures = [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($testFailures))
								}
								
								
								if ($buildTestLanguage) {
									foreach ($line in $testInfotable) {
										if (($line.BuildID -eq $build.id) -and (!($line.Language -eq $buildTestLanguage))) {
											$line.Language = $buildTestLanguage
										}
									}
								}
	

								$tmpURL = $projectUrlProject + "/_build/results?buildId=" + $build.id

								$buildObject = new-object BuildRecord

								$buildObject.BuildKey = $build.id
								$buildObject.BuildID = $build.id
								$buildObject.TimeLineID = $null
								$buildObject.ParentID = $null
								$buildObject.BuildDef = $build.definition.name
								$buildObject.BuildDefID = $id
								$buildObject.BuildDefPath = ($buildDef.Path).Replace('\', '/')
								$buildObject.Quality = $quality
								$buildObject.BuildNumber = $build.buildNumber
								$buildObject.RecordType = "Build"
								$buildObject.BuildJob = $null
								$buildObject.Finished = $build.status
								$buildObject.Compile_Status = $build.result
								$buildObject.Queue_Time = ([DateTime]::Parse($build.queueTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
								$buildObject.Start_Time = ([DateTime]::Parse($build.startTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
								$buildObject.Finish_Time = ([DateTime]::Parse($build.finishTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
								$buildObject.Queue_TimeZ = ([DateTime]::Parse($build.queueTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
								$buildObject.Start_TimeZ = ([DateTime]::Parse($build.startTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
								$buildObject.Finish_TimeZ = ([DateTime]::Parse($build.finishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
								$buildObject.Wait_Time = (new-TimeSpan -start $build.queueTime -end $build.startTime).TotalMinutes
								$buildObject.Elapsed_Time = (new-TimeSpan -start $build.startTime -end $build.finishTime).TotalMinutes
								$buildObject.Tenant = $tenant
								$buildObject.Project = $build.project.name
								$buildObject.Agent_Pool = $build.queue.name
								$buildObject.Agent = $null
								$buildObject.Reason = $build.Reason
								$buildObject.SourceGetVersion = $build.sourceVersion
								$buildObject.SourceRepo = $build.repository.name
								$buildObject.SourceBranch = $build.sourceBranch
								$buildObject.URL = $tmpURL
								$buildObject.RequestedFor = $tmpRequestedFor
								$buildObject.Demands = $tmpDemands
								$buildObject.Variables = $tmpVariables
								$buildObject.ErrorIssues = $buildErrorIssues
								$buildObject.TestLanguage = $buildTestLanguage
								$buildObject.TestFailures = $testFailures
								$buildObject.TestFailCount = $testFailCount
								$buildObject.TestPassCount = $testPassCount
								$buildObject.TestTotalCount = $testTotalCount
								$buildObject.TestFailPct = $testFailPct
								$buildObject.TestPassPct = $testPassPct

#								$null = $buildInfotable.Add($BuildObject)

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

										# write-host "$($project) / $($buildPipeline) / $($build.definition.name) / $($build.buildNumber)/$($item.type)"

										if ($DEBUG) {
											$item | ConvertTo-json -depth 100 | out-file "$($homeFolder)\$($buildDef.id).$($build.id).$($timeline.id).$($item.id).item.json" -encoding ascii
										}

										$errorIssues = $null
										$buildTrackerJobErrorIssues = $null

										if ($item.type -like "Task" -and $project -like "One") {

											switch ($item.name)
											{
												"Build" {
													if ($item.log.url) {
														$logData = $null
														try {
															$logData = (invoke-restmethod $item.log.url -headers $headers) -Split "`r`n"
														}
														catch {
															write-warning "WARNING: $($item.log.url) is not valid 1"
															write-host "##vso[task.logissue type=warning;] WARNING: $($item.log.url) is not valid 1"
														}
														if ($logData) {
															if ($item.result -like "failed") {
																$buildTrackerUrl = $null
																try {
																	$buildTrackerUrl = (([string]($logData | Select-String "Your build link: " -CaseSensitive)).split(" "))[4]
																	$errorIssues += "BuildTrackerJob: $($buildTrackerUrl)`n"
																}
																catch {
																	write-warning "WARNING: Unable to read buildTrackerUrl from $($item.log.url)"
																	write-host "##vso[task.logissue type=warning;] WARNING: Unable to read buildTrackerUrl from $($item.log.url)"
																}
																$logFolderUNC = $null
																try {
																	$logFolderUNC = (([string]($logData | Select-String "buildtracker_srvreleaseshare = " -CaseSensitive)).split(" "))[3]
																	$errorIssues += "BuildTrackerDrop: $($logFolderUNC)`n"
																}
																catch {
																	write-warning "WARNING: Unable to read logFolderUNC from $($item.log.url)"
																	write-host "##vso[task.logissue type=warning;] Unable to read logFolderUNC from $($item.log.url)"
																}

																$tmp = measure-command {
																	if (test-path $logFolderUNC) {
																		foreach ($logFile in ((get-childitem -path "$($logFolderUNC)" -filter "buildtracker*.log").fullName)) {
																			$tmpLogFile = get-content $logFile -encoding UTF8
																			foreach ($errorPattern in " error: ", " [ERROR] "," error : ") {
																				foreach ($hit in ($tmpLogFile | select-string -pattern $errorPattern -encoding UTF8)){
																					$errorIssues += "$($hit)`n"
																					$buildTrackerJobErrorIssues += "$($hit)`n"
																				}
																			}
																			$tmpLogFile = $null
																		}
																	}
																}
																write-host "Checking BuildTracker Logs for ERRORs took", $tmp.TotalSeconds, "seconds"
															}

															if ($buildTrackerJobErrorIssues) {
																$buildTrackerJobErrorIssues = $buildTrackerJobErrorIssues.Replace("\n", "`n").Replace('\', '/').Replace("`r`n", "\n").Replace("`n", "\n").Replace("`t", "	").Replace('"', "'")
																$buildTrackerJobErrorIssues = [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($buildTrackerJobErrorIssues))
																$buildTrackerJobErrorIssues = makeUnique $buildTrackerJobErrorIssues | sort-object
															}
															if ($errorIssues) {
																$errorIssues = $errorIssues.Replace("\n", "`n").Replace('\', '/').Replace("`r`n", "\n").Replace("`n", "\n").Replace("`t", "	").Replace('"', "'")
																$errorIssues = [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($errorIssues))
																$errorIssues = makeUnique $errorIssues | sort-object
															}

															$buildTrackerJobId = $null
															try {
																$buildTrackerJobId = (([string]($logData | Select-String " Build job scheduled with id " -CaseSensitive)).split(" "))[6]
															}
															catch {
																write-warning "WARNING: Unable to read buildTrackerJobId from $($item.log.url)"
																write-host "##vso[task.logissue type=warning;] Unable to read buildTrackerJobId from $($item.log.url)"
															}

															if ($buildTrackerJobId) {															
																$clientAssembly = [System.Reflection.Assembly]::LoadFrom("\\reddog\public\Build\BTGitOriginServerChanger\Microsoft.BuildTracker.Client.dll")
																$contractsAssembly = [System.Reflection.Assembly]::LoadFrom("\\reddog\public\Build\BTGitOriginServerChanger\Microsoft.BuildTracker.Contracts.dll")
																$connectionUri = 'net.tcp://wabt.ntdev.corp.microsoft.com:9700/BuildTrackerApi'
																$myService = [Microsoft.BuildTracker.Client.BuildTrackerService]::Connect($connectionUri)

																$legQuery = new-Object Microsoft.BuildTracker.Client.LegInstanceQuery
																$legQuery.JobInstanceIds = $buildTrackerJobId
																$legInstances = $myService.QueryLegInstances($legQuery)

																if ($DEBUG) {
																	$legInstances | ConvertTo-json -depth 100 | out-file "$($homeFolder)\$($buildDef.id).$($build.id).$($timeline.id).$($item.id).$($buildTrackerJobId).btLegInstances.json" -encoding ascii
																}

																if ($buildTrackerJobHash.ContainsKey([int]$buildTrackerJobId)) {
																	$jobInstance = $buildTrackerJobHash[[int]$buildTrackerJobId]
																} else {
																	$jobQuery = new-Object Microsoft.BuildTracker.Client.JobInstanceQuery
																	$jobQuery.ProductId = $legInstances[0].ProductId
																	$jobQuery.BranchId = $legInstances[0].BranchId
																	$jobQuery.JobTypes = "BuildJob"
																	$jobQuery.Status = "Finished"
																	# $jobQuery.TopN = "10"
																	$jobQuery.DateFromQueryType = "CompleteDateTime"
																	$jobQuery.DateFrom = (get-date).AddMinutes($minutesBack).toUniversalTime()
																	write-host "Calling BuildTracker API for ProductID $($jobQuery.ProductId) and BranchID $($jobQuery.BranchId)..."
																	$jobInstances = $myService.QueryJobInstances($jobQuery)
																	foreach ($jobInstance in $jobInstances) {
																		if (!($buildTrackerJobHash.ContainsKey([int]$jobInstance.id))) {
																			if ($jobInstance) {
																				$null = $buildTrackerJobHash.Add($jobInstance.id, $jobInstance)
																			}
																		}
																	}
																	$jobInstance = $buildTrackerJobHash[[int]$buildTrackerJobId]
																}

																if ($DEBUG) {
																	$jobInstance | ConvertTo-json -depth 100 | out-file "$($homeFolder)\$($buildDef.id).$($build.id).$($timeline.id).$($item.id).$($buildTrackerJobId).jobInstance.json" -encoding ascii
																}

																<#
																# --- DateTime fields from the BuildTracker JobInstance record

																$jobInstance.QueueDateTime
																$jobInstance.SyncDateTime
																$jobInstance.SequenceDateTime
																$jobInstance.StartDateTime
																$jobInstance.CompletedDateTime

																#>

																$timeLineObject = new-object BuildRecord

																$tmpBuildKey = [string]$build.id + "_" + [string]$item.Parentid + "_" + [string]$item.id  + "_" + [int]$buildTrackerJobId
																$tmpBuildJob = $jobInstance.name

																if ($jobInstance.StartDateTime) {
																	$buildTrackerJobStartTime = $jobInstance.StartDateTime.toUniversalTime().AddHours(-7)
																}
																else {
																	write-warning "WARNING: expected jobInstance.StartDateTime to be non-null"
																	write-host "##vso[task.logissue type=warning;] WARNING: expected jobInstance.StartDateTime to be non-null"
																	$buildTrackerJobStartTime = $item.startTime
																}

																if ($jobInstance.CompletedDateTime) {
																	$buildTrackerJobFinishTime = $jobInstance.CompletedDateTime.toUniversalTime().AddHours(-7)
																}
																else {
																	write-warning "WARNING: expected jobInstance.CompletedDateTime to be non-null"
																	write-host "##vso[task.logissue type=warning;] WARNING: expected jobInstance.CompletedDateTime to be non-null"
																	$buildTrackerJobFinishTime = $item.finishTime
																}

																if ($jobInstance.QueueDateTime) {
																	$buildTrackerJobQueueTime = $jobInstance.QueueDateTime.toUniversalTime().AddHours(-7)
																}
																else {
																	write-warning "WARNING: expected jobInstance.QueueDateTime to be non-null"
																	write-host "##vso[task.logissue type=warning;] WARNING: expected jobInstance.QueueDateTime to be non-null"
																	$buildTrackerJobQueueTime = $item.startTime
																}

																$timeLineObject.BuildKey = $tmpBuildKey
																$timeLineObject.BuildID = $build.id
																$timeLineObject.TimeLineID = $buildTrackerJobId
																$timeLineObject.ParentID = $item.id
																$timeLineObject.RecordType = "BuildTrackerJob"
																$timeLineObject.BuildDef = $build.definition.name
																$timeLineObject.BuildDefID = $id
																$timeLineObject.BuildDefPath = ($buildDef.Path).Replace('\', '/')
																$timeLineObject.Quality = $quality
																$timeLineObject.BuildNumber = $build.buildNumber
																$timeLineObject.BuildJob = $tmpBuildJob
																$timeLineObject.Finished = "completed"
																$timeLineObject.Compile_Status = $jobInstance.status
																$timeLineObject.Queue_Time = ([DateTime]::Parse($buildTrackerJobQueueTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
																$timeLineObject.Queue_TimeZ = ([DateTime]::Parse($buildTrackerJobQueueTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
																$timeLineObject.Start_Time = ([DateTime]::Parse($buildTrackerJobStartTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
																$timeLineObject.Start_TimeZ = ([DateTime]::Parse($buildTrackerJobStartTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
																$timeLineObject.Wait_Time = (new-TimeSpan -start $buildTrackerJobQueueTime -end $buildTrackerJobStartTime).TotalMinutes
																$timeLineObject.Finish_Time = ([DateTime]::Parse($buildTrackerJobFinishTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
																$timeLineObject.Finish_TimeZ = ([DateTime]::Parse($buildTrackerJobFinishTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
																$timeLineObject.Elapsed_Time = (new-TimeSpan -start $buildTrackerJobStartTime -end $buildTrackerJobFinishTime).TotalMinutes
																$timeLineObject.Tenant = $tenant
																$timeLineObject.Project = $build.project.name
																$timeLineObject.Agent = $null
																$timeLineObject.Agent_Pool = $null
																$timeLineObject.Reason = $build.Reason
																$timeLineObject.SourceGetVersion = $build.sourceVersion
																$timeLineObject.SourceRepo = $build.repository.name
																$timeLineObject.SourceBranch = $build.sourceBranch
																$timeLineObject.URL = "http://wabt/BuildTracker/Jobs/LegSummary.aspx?Id=$($buildTrackerJobId)"
																$timeLineObject.RequestedFor = $tmpRequestedFor
																$timeLineObject.Demands = $tmpDemands
																$timeLineObject.Variables = $tmpVariables
																$timeLineObject.ErrorIssues = $buildTrackerJobErrorIssues

																$null = $buildInfotable.Add($timeLineObject)

																$firstLeg = $true

																foreach ($legInstance in ($legInstances | `
																							where {$_.Status -ne "6"} | `
																							sort-object Order)) {

																	<#
																	# --- DateTime fields from the BuildTracker LegInstance record

																	$legInstance.WaitingStartedTime
																	$legInstance.ReadyStartedTime
																	$legInstance.PreparingStartedTime
																	$legInstance.ExecutingStartedTime
																	$legInstance.FinishedTime

																	#>

																	$timeLineObject = new-object BuildRecord

																	$tmpBuildKey = [string]$build.id + "_" + [string]$item.Parentid + "_" + [string]$item.id + "_" + [int]$buildTrackerJobId + "_" + [string]$leginstance.id

																	if ($legInstance.ExecutingStartedTime) {
																		$buildTrackerLegStartTime = $legInstance.ExecutingStartedTime.toUniversalTime().AddHours(-7)
																	} else {
																		write-warning "WARNING: expected legInstance.ExecutingStartedTime to be non-null"
																		write-host "##vso[task.logissue type=warning;] WARNING: expected legInstance.ExecutingStartedTime to be non-null"
																		$buildTrackerLegStartTime = $itemStartTime
																	}
																	if ($legInstance.FinishedTime) {
																		$buildTrackerLegFinishTime = $legInstance.FinishedTime.toUniversalTime().AddHours(-7)
																	} else {
																		write-warning "WARNING: expected legInstance.FinishedTime to be non-null"
																		write-host "##vso[task.logissue type=warning;] WARNING: expected legInstance.FinishedTime to be non-null"
																		$buildTrackerLegFinishTime = $itemStartTime
																	}

																	$tmpErrorIssues = $null

																	if ([int]$legInstance.exitcode -gt 0) {
																	<#
																		if (test-path $logFolderUNC) {
																			foreach ($logFile in ((get-childitem -path "$($logFolderUNC)\logs" -filter "*$($leginstance.name)*.log" -recurse).fullName)) {
																				foreach ($hit in (get-content $logFile -encoding UTF8 | select-string -pattern " error " -encoding UTF8)){
																					$tmpErrorIssues += "$($hit)`n"
																				}
																			}
																		}
																	#>
																	}

																	if ($tmpErrorIssues) {
																		$tmpErrorIssues = $tmpErrorIssues.Replace("\n", "`n").Replace('\', '/').Replace("`r`n", "\n").Replace("`n", "\n").Replace("`t", "	").Replace('"', "'")
																		$tmpErrorIssues = [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($tmpErrorIssues))
																	}

																	$timeLineObject.BuildKey = $tmpBuildKey
																	$timeLineObject.BuildID = $build.id
																	$timeLineObject.TimeLineID = $leginstance.id
																	$timeLineObject.ParentID = $item.id
																	$timeLineObject.RecordType = "BuildTrackerLeg"
																	$timeLineObject.BuildDef = $build.definition.name
																	$timeLineObject.BuildDefID = $id
																	$timeLineObject.BuildDefPath = ($buildDef.Path).Replace('\', '/')
																	$timeLineObject.Quality = $quality
																	$timeLineObject.BuildNumber = $build.buildNumber
																	$timeLineObject.BuildJob = $leginstance.name
																	$timeLineObject.Finished = "completed"
																	$timeLineObject.Compile_Status = $legInstance.status
																	$timeLineObject.Queue_Time = ([DateTime]::Parse($legInstance.WaitingStartedTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
																	$timeLineObject.Queue_TimeZ = ([DateTime]::Parse($legInstance.WaitingStartedTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
																	$timeLineObject.Start_Time = ([DateTime]::Parse($buildTrackerLegStartTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
																	$timeLineObject.Start_TimeZ = ([DateTime]::Parse($buildTrackerLegStartTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
																	if ($firstLeg) {
																		$timeLineObject.Wait_Time = (new-TimeSpan -start $buildTrackerJobStartTime -end $buildTrackerLegStartTime).TotalMinutes
																	} else {
																		$timeLineObject.Wait_Time = (new-TimeSpan -start $previousBuildTrackerLegFinishTime -end $buildTrackerLegStartTime).TotalMinutes
																	}
																	$timeLineObject.Finish_Time = ([DateTime]::Parse($buildTrackerLegFinishTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
																	$timeLineObject.Finish_TimeZ = ([DateTime]::Parse($buildTrackerLegFinishTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
																	$timeLineObject.Elapsed_Time = (new-TimeSpan -start $buildTrackerLegStartTime -end $buildTrackerLegFinishTime).TotalMinutes
																	$timeLineObject.Tenant = $tenant
																	$timeLineObject.Project = $build.project.name
																	$timeLineObject.Agent = $legInstance.machinename
																	$timeLineObject.Agent_Pool = $null
																	$timeLineObject.Reason = $build.Reason
																	$timeLineObject.SourceGetVersion = $build.sourceVersion
																	$timeLineObject.SourceRepo = $build.repository.name
																	$timeLineObject.SourceBranch = $build.sourceBranch
																	$timeLineObject.URL = $legInstance.logurl
																	$timeLineObject.RequestedFor = $tmpRequestedFor
																	$timeLineObject.Demands = $tmpDemands
																	$timeLineObject.Variables = $tmpVariables
																	$timeLineObject.ErrorIssues = $null

																	$null = $buildInfotable.Add($timeLineObject)

																	$firstLeg = $false
																	$previousBuildTrackerLegFinishTime = $buildTrackerLegFinishTime
																}
															}
														}
													}
													break
												}
												<#
												"Validate" {
													if ($item.log.url) {
														$logData = $null
														try {
															$logData = (invoke-restmethod $item.log.url -headers $headers) -Split "`r`n"
														}
														catch {
															write-warning "$($item.log.url) is not valid"
														}
														if ($logData) {
															$cloudTestId = $null
															try {
																$cloudTestId = ([string]($logData | Select-String " CloudTest " -CaseSensitive)).split("[")[1].split("]")[0]
															}
															$cloudTestTabUrl = $null
															try {
																$cloudTestTabUrl = ([string]($logData | Select-String " CloudTest " -CaseSensitive)).split("(")[1].split("])")[0]
																$tmpUrl = $cloudTestTabUrl
															}
														}
														if ($cloudTestId) {
															write-host "cloudTestId $cloudTestId"
														}
														if ($cloudTestTabUrl) {
															write-host "cloudTestTabUrl $cloudTestTabUrl"
															#(invoke-restmethod $cloudTestTabUrl -headers $headers) -Split "`r`n"
														}
													}
													break
												}
												#>
											}
										}

										if ($str1 = ($item.issues | where-object { $_.type -like "error" }).message) {
											$str2 = $str1.Replace('\', '/')
											$str3 = ""
											foreach ($line in $str2) {
												$str3 += $line + "\n"
											}
											$str4 = $str3.Replace("`r`n", "\n")
											$str5 = $str4.Replace("`n", "\n")
											$str6 = $str5.Replace("`t", "	")
											$errorIssues += $str6.Replace('"', "'")
											if ($item.log.url) {
												try {
													$logData = (invoke-restmethod $item.log.url -headers $headers) -Split "`r`n"
												}
												catch {
													write-warning "WARNING: $($item.log.url) is not valid 2"
													write-host "##vso[task.logissue type=warning;] $($item.log.url) is not valid 2"
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
										}

										if ($errorIssues) {
											$errorIssues = $errorIssues.Replace("\n", "`n").Replace('\', '/').Replace("`r`n", "\n").Replace("`n", "\n").Replace("`t", "	").Replace('"', "'")
											$buildErrorIssues += "\n" + $errorIssues
										}

										$timeLineObject = new-object BuildRecord

										$tmpBuildKey = [string]$build.id + "_" + [string]$item.Parentid + "_" + [string]$item.id
										$tmpBuildJob = $item.name.replace('\', '/').replace('"', "'")
										$tmpBuildJob = [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($tmpBuildJob))
										# $tmpBuildJob = $tmpBuildJob -replace [char]0x00a0, ' '

										if ($item.startTime) {
											$itemStartTime = $item.startTime
										}
										else {
											$itemStartTime = $build.startTime
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

										$timeLineObject.BuildKey = $tmpBuildKey
										$timeLineObject.BuildID = $build.id
										$timeLineObject.TimeLineID = $item.id
										$timeLineObject.ParentID = $item.Parentid
										$timeLineObject.RecordType = $item.type
										$timeLineObject.BuildDef = $build.definition.name
										$timeLineObject.BuildDefID = $id
										$timeLineObject.BuildDefPath = ($buildDef.Path).Replace('\', '/')
										$timeLineObject.Quality = $quality
										$timeLineObject.BuildNumber = $build.buildNumber
										$timeLineObject.BuildJob = $tmpBuildJob
										$timeLineObject.Finished = $item.state
										$timeLineObject.Compile_Status = $item.result
										$timeLineObject.Queue_Time = ([DateTime]::Parse($build.queueTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
										$timeLineObject.Queue_TimeZ = ([DateTime]::Parse($build.queueTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
										$timeLineObject.Start_Time = ([DateTime]::Parse($itemStartTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
										$timeLineObject.Start_TimeZ = ([DateTime]::Parse($itemStartTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
										$timeLineObject.Wait_Time = (new-TimeSpan -start $build.queueTime -end $itemStartTime).TotalMinutes
										$timeLineObject.Finish_Time = ([DateTime]::Parse($tmpFinishTime)).toUniversalTime().AddHours(-7).toString("MM/dd/yyyy HH:mm:ss")
										$timeLineObject.Finish_TimeZ = ([DateTime]::Parse($tmpFinishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
										$timeLineObject.Elapsed_Time = (new-TimeSpan -start $itemStartTime -end $tmpFinishTime).TotalMinutes
										$timeLineObject.Tenant = $tenant
										$timeLineObject.Project = $build.project.name
										$timeLineObject.Agent = $item.workerName
										$timeLineObject.Agent_Pool = $tmpAgentPool
										$timeLineObject.Reason = $build.Reason
										$timeLineObject.SourceGetVersion = $build.sourceVersion
										$timeLineObject.SourceRepo = $build.repository.name
										$timeLineObject.SourceBranch = $build.sourceBranch
										$timeLineObject.URL = $tmpURL
										$timeLineObject.RequestedFor = $tmpRequestedFor
										$timeLineObject.Demands = $tmpDemands
										$timeLineObject.Variables = $tmpVariables
										$timeLineObject.ErrorIssues = $errorIssues

										$null = $buildInfotable.Add($timeLineObject)
									}
								}

								$BuildObject.ErrorIssues = $buildErrorIssues
								$null = $buildInfotable.Add($BuildObject)
							}
							else {
								write-warning "WARNING: Not an $($buildPipeline) build..."
								write-host "##vso[task.logissue type=warning;] Not an $($buildPipeline) build..."
							}
						}
						else {
							write-warning "WARNING: Build in progress..."
							write-host "##vso[task.logissue type=warning;] Build in progress..."
						}
						
					}
					if ($testInfotable.count -gt 10000) {
						updateDBsForTestInfo
						$testInfotable = $null
						$testInfotable = [System.Collections.ArrayList]@()
					}

				}
				updateDBsForTestInfo
				$testInfotable = $null
				$testInfotable = [System.Collections.ArrayList]@()
						
				updateDBsForBuildInfo
				$buildInfotable = $null
				$buildInfotable = [System.Collections.ArrayList]@()
			}
		}
	}
	
	# createSmallSqlTables

	if ($updateElastic -and $updateLastRunTime) {
		write-host "Updating LastRunTime time stamps..."
		$esString += @"
{"delete": {"_index": "timestamp","_type": "_doc","_id": "$($strESBuildIndex)"}}
{"create": {"_index": "timestamp","_type": "_doc","_id": "$($strESBuildIndex)"}}
{"ID": "$($strESBuildIndex)","LastRunTime": "$($thisRunDateTimeUTC)"}

"@
		try {
			invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
		}
		catch {
			write-host "ERROR: updating LastRunTime"
			$esString
			$_.Exception
		}
	}
}


function updateDBsForBuildInfo {

	write-host "Uploading BuildInfo to DBs..."

	$esString = $null
	$sqlStringTmp = $null

	$esStringBuilder = New-Object System.Text.StringBuilder(18000 * $($intElasticSearchBatchSize))

	$sqlStringInsertBuilder = New-Object System.Text.StringBuilder(7000 * $($intSqlBatchSize))
	$sqlStringDeleteBuilder = New-Object System.Text.StringBuilder(150 * $($intSqlBatchSize))


	foreach ($line in $buildInfotable) {

		if ($deletePreviousSQLrecord) {
			$sqlStringTmp = @"
DELETE from $($strSqlTable)
WHERE Build_Key='$($line.BuildKey)';
GO

"@
			$null = $sqlStringDeleteBuilder.Append($sqlStringTmp)
		}

		$tmpVariables		= $line.Variables -replace "'", '"' -replace '\$\(', '\('
		$tmpDemands			= $line.Demands -replace "'", '"' -replace '\$\(', '\('
		$tmpErrorIssues		= $line.ErrorIssues -replace "'", '"' -replace '\$\(', '\('
		$tmpTestFailures	= $line.TestFailures -replace "'", '"' -replace '\$\(', '\('
		$tmpBuildJob		= $line.BuildJob -replace '\$\(', '\(' -replace "'", '"'

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
	Error_Issues,
	BuildDefPath,
	Test_Failures,
	Test_Fail_Count,
	Test_Pass_Count,
	Test_Total_Count,
	Test_Fail_Pct,
	Test_Pass_Pct
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
	N'$($tmpErrorIssues)',
	'$($line.BuildDefPath)',
	'$($tmpTestFailures)',
	'$($line.TestFailCount)',
	'$($line.TestPassCount)',
	'$($line.TestTotalCount)',
	'$($line.TestFailPct)',
	'$($line.TestPassPct)'
)
GO

"@
		$null = $sqlStringInsertBuilder.Append($sqlStringTmp)

		if ($deletePreviousElasticRecord) {
			$tmpString = @"
{
	"delete": {
		"_index": "$($strESBuildIndex)",
		"_type": "_doc",
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
		"_index": "$($strESBuildIndex)",
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
	"Demands": "$($line.demands)",
	"Variables": "$($line.Variables)",
	"SourceGetVersion": "$($line.SourceGetVersion)",
	"SourceRepo": "$($line.SourceRepo)",
	"SourceBranch": "$($line.SourceBranch)",
	"URL": "$($line.URL)",
	"Start_Time": "$($line.Start_TimeZ)",
	"TimeLineID": "$($line.TimeLineID)",
	"Wait_Time": $($line.Wait_Time),
	"Error_Issues": "$($line.ErrorIssues)",
	"Test_Language": "$($line.TestLanguage)",
	"Test_Failures": "$($line.TestFailures)",
	"Test_Fail_Count": "$($line.TestFailCount)",
	"Test_Pass_Count": "$($line.TestPassCount)",
	"Test_Total_Count": "$($line.TestTotalCount)",
	"Test_Fail_Pct": "$($line.TestFailPct)",
	"Test_Pass_Pct": "$($line.TestPassPct)"
}
"@
		$esString = $tmpString | convertfrom-json | convertto-json -compress
		$esString += "`n"
		$esString += "`n"
		$null = $esStringBuilder.Append($esString)

		if (!($buildInfotable.IndexOf($line) % $intSqlBatchSize)) {
			if ($updateSQL) {
				if ($sqlStringDeleteBuilder.length) {
					$sqlStringTmp = $sqlStringDeleteBuilder.ToString()
					try {
						Invoke-SqlCmd $sqlStringTmp -ConnectionString "$($strSqlConnectionString)"  -QueryTimeout 300
					}
					catch {
						write-warning "WARNING: Deleting from SQL in updateDBsForBuildInfo"
						$_.Exception
					}
				}
				if ($sqlStringInsertBuilder.length) {
					$sqlStringTmp = $sqlStringInsertBuilder.ToString()

					$tmp = measure-command {
						try {
							Invoke-SqlCmd $sqlStringTmp -ConnectionString "$($strSqlConnectionString)"  -QueryTimeout 300
						}
						catch {
							write-warning "ERROR: writing to SQL in updateDBsForBuildInfo"
							$_.Exception
						}
					}
					write-host "SQL Write", $intSqlBatchSize, $tmp.TotalSeconds
				}
			}
			$sqlStringTmp = $null
			$null = $sqlStringInsertBuilder.clear()
			$null = $sqlStringDeleteBuilder.clear()
			$sqlStringInsertBuilder = New-Object System.Text.StringBuilder(7000 * $($SqlBatchSize))
			$sqlStringDeleteBuilder = New-Object System.Text.StringBuilder(150 * $($SqlBatchSize))
		}

		if (!($buildInfotable.IndexOf($line) % $intElasticSearchBatchSize)) {
			if ($updateElastic) {
				$esString = $esStringBuilder.ToString()
				$tmp = measure-command {
					try {
						$result = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
						$result
					}
					catch {
						write-warning "Errors writing to ES - Bulk Mode in updateDBsForBuildInfo"
						$_.Exception
					}
				}
				write-host "ES Write", $intElasticSearchBatchSize, $tmp.TotalSeconds
				if ($result.errors) {
					write-warning "Errors writing to ES - Bulk Mode in updateDBsForBuildInfo"
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
								$result2 = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
								$result2
							}
							catch {
								write-warning "Errors writing to ES - Single Mode in updateDBsForBuildInfo"
								$_.Exception
							}
							if ($result2.errors) {
								write-warning "Errors writing to ES - Single Mode in updateDBsForBuildInfo"
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
			$esStringBuilder = New-Object System.Text.StringBuilder(18000 * $($intElasticSearchBatchSize))
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
				write-warning "Errors writing to ES - Bulk Mode in updateDBsForBuildInfo"
				$_.Exception
			}
			if ($result.errors) {
				write-warning "Errors writing to ES - Bulk Mode in updateDBsForBuildInfo"
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
							$result2 = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
							$result2
						}
						catch {
							write-warning "Errors writing to ES - Single Mode in updateDBsForBuildInfo"
							$_.Exception
						}
						if ($result2.errors) {
							write-warning "Errors writing to ES - Single Mode in updateDBsForBuildInfo"
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
	}

	if ($updateSQL) {
		if ($sqlStringDeleteBuilder.length) {
			$sqlStringTmp = $sqlStringDeleteBuilder.ToString()
			try {
				Invoke-SqlCmd $sqlStringTmp -ConnectionString "$($strSqlConnectionString)"  -QueryTimeout 300
			}
			catch {
				write-warning "WARNING: Deleting from SQL in updateDBsForBuildInfo"
				$_.Exception
			}
		}
		if ($sqlStringInsertBuilder.length) {
			$sqlStringTmp = $sqlStringInsertBuilder.ToString()
			try {
				Invoke-SqlCmd $sqlStringTmp -ConnectionString "$($strSqlConnectionString)"  -QueryTimeout 300
			}
			catch {
				write-warning "ERROR: writing to SQL in updateDBsForBuildInfo"
				$_.Exception
			}
		}
		$sqlStringTmp = $null
		$null = $sqlStringInsertBuilder.clear()
		$null = $sqlStringDeleteBuilder.clear()
	}
}


function updateDBsForTestInfo {

	write-host "Uploading TestInfo to DBs..."

	$esString = $null
	$sqlStringTmp = $null

	$esStringBuilder = New-Object System.Text.StringBuilder(18000 * $($intElasticSearchBatchSize))

	$sqlStringInsertBuilder = New-Object System.Text.StringBuilder(7000 * $($intSqlBatchSize))
	$sqlStringDeleteBuilder = New-Object System.Text.StringBuilder(150 * $($intSqlBatchSize))


	foreach ($line in $testInfotable) {
	
		if ($deletePreviousSQLrecord) {
			$sqlStringTmp = @"
DELETE from $($strESTestIndex)
WHERE Test_Key='$($line.TestKey)';
GO

"@
			$null = $sqlStringDeleteBuilder.Append($sqlStringTmp)
		}
		
		$tmpAutomatedTestName = $($line.automatedTestName).Replace("'",'"')
		$tmpAutomatedTestStorage = $($line.automatedTestStorage).Replace("'",'"')
		$tmpTestCaseTitle = $($line.testCaseTitle).Replace("'",'"')
		
		$sqlStringTmp = @"
INSERT INTO $($strESTestIndex) (
	Test_Key,
	BuildID,
	BuildDef,
	BuildDefID,
	BuildDefPath,
	Quality,
	BuildNumber,
	Outcome,
	Finish_Time,
	Tenant,
	Project,
	Agent_Pool,
	Agent,
	Language,
	automatedTestName,
	automatedTestStorage,
	owner,
	testCaseTitle,
	duration,
	URL
)
VALUES (
	'$($line.TestKey)',
	'$($line.BuildID)',
	'$($line.BuildDef)',
	'$($line.BuildDefID)',
	'$($line.BuildDefPath)',
	'$($line.Quality)',
	'$($line.BuildNumber)',
	'$($line.Outcome)',
	'$($line.Finish_Time)',
	'$($line.Tenant)',
	'$($line.Project)',
	'$($line.Agent_Pool)',
	'$($line.Agent)',
	'$($line.Language)',
	'$($tmpAutomatedTestName)',
	'$($tmpAutomatedTestStorage)',
	'$($line.owner)',
	'$($tmpTestCaseTitle)',
	'$($line.duration)',
	'$($line.URL)'
)
GO

"@
		$null = $sqlStringInsertBuilder.Append($sqlStringTmp)

		if ($deletePreviousElasticRecord) {
			$tmpString = @"
{
	"delete": {
		"_index": "$($strESTestIndex)",
		"_type": "_doc",
		"_id": "$($line.TestKey)"
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
		"_index": "$($strESTestIndex)",
		"_type": "_doc",
		"_id": "$($line.TestKey)"
	}
}
"@
		$esString = $tmpString | convertfrom-json | convertto-json -compress
		$esString += "`n"
		$null = $esStringBuilder.Append($esString)

		$tmpString = @"
{
	"Test_Key": "$($line.TestKey)",
	"BuildID": "$($line.BuildID)",
	"BuildDef": "$($line.BuildDef)",
	"BuildDefID": "$($line.BuildDefID)",
	"BuildDefPath": "$($line.BuildDefPath)",
	"Quality": "$($line.Quality)",
	"BuildNumber": "$($line.BuildNumber)",
	"Outcome": "$($line.Outcome)",
	"Finish_Time": "$($line.Finish_TimeZ)",
	"Tenant": "$($line.Tenant)",
	"Project": "$($line.Project)",
	"Agent_Pool": "$($line.Agent_Pool)",
	"Agent": "$($line.Agent)",
	"Language": "$($line.Language)",
	"automatedTestName": "$($line.automatedTestName)",
	"automatedTestStorage": "$($line.automatedTestStorage)",
	"owner": "$($line.owner)",
	"testCaseTitle": "$($line.testCaseTitle)",
	"duration": "$($line.duration)",
	"URL": "$($line.URL)"
}
"@
		$esString = $tmpString | convertfrom-json | convertto-json -compress
		$esString += "`n"
		$esString += "`n"
		$null = $esStringBuilder.Append($esString)
		
		if (!($testInfotable.IndexOf($line) % $intSqlBatchSize)) {
			if ($updateSQL) {
				if ($sqlStringDeleteBuilder.length) {
					$sqlStringTmp = $sqlStringDeleteBuilder.ToString()
					try {
						Invoke-SqlCmd $sqlStringTmp -ConnectionString "$($strSqlConnectionString)"  -QueryTimeout 300
					}
					catch {
						write-warning "WARNING: Deleting from SQL in updateDBsForTestInfo"
						$_.Exception
					}
				}
				if ($sqlStringInsertBuilder.length) {
					$sqlStringTmp = $sqlStringInsertBuilder.ToString()
					$tmp = measure-command {
						try {
							Invoke-SqlCmd $sqlStringTmp -ConnectionString "$($strSqlConnectionString)"  -QueryTimeout 300
						}
						catch {
							write-warning "ERROR: writing to SQL in updateDBsForTestInfo"
							$sqlStringTmp
							$_.Exception
						}
					}
					write-host "SQL Write", $intSqlBatchSize, $tmp.TotalSeconds
				}
			}
			$sqlStringTmp = $null
			$null = $sqlStringInsertBuilder.clear()
			$null = $sqlStringDeleteBuilder.clear()
			$sqlStringInsertBuilder = New-Object System.Text.StringBuilder(7000 * $($SqlBatchSize))
			$sqlStringDeleteBuilder = New-Object System.Text.StringBuilder(150 * $($SqlBatchSize))
		}
		

		if (!($testInfotable.IndexOf($line) % $intElasticSearchBatchSize)) {
			if ($updateElastic) {
				$esString = $esStringBuilder.ToString()
				$tmp = measure-command {
					try {
						$result = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
						$result
					}
					catch {
						write-warning "Errors writing to ES - Bulk Mode in updateDBsForTestInfo"
						$_.Exception
					}
				}
				write-host "ES Write", $intElasticSearchBatchSize, $tmp.TotalSeconds
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
						if ($esStringItem.split(":")[0] -like "*Test_Key*") {
							$tmpBody += $esStringItem + "`n`n"

							try {
								$result2 = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
								$result2
							}
							catch {
								write-warning "Errors writing to ES - Single Mode in updateDBsForTestInfo"
								$_.Exception
							}
							if ($result2.errors) {
								write-warning "Errors writing to ES - Single Mode in updateDBsForTestInfo"
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
			$esStringBuilder = New-Object System.Text.StringBuilder(18000 * $($intElasticSearchBatchSize))
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
				write-warning "Errors writing to ES - Bulk Mode in updateDBsForTestInfo"
				$_.Exception
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
					if ($esStringItem.split(":")[0] -like "*Test_Key*") {
						$tmpBody += $esStringItem + "`n`n"

						try {
							$result2 = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $tmpBody -ContentType "application/json"
							$result2
						}
						catch {
							write-warning "Errors writing to ES - Single Mode in updateDBsForTestInfo"
							$_.Exception
						}
						if ($result2.errors) {
							write-warning "Errors writing to ES - Single Mode in updateDBsForTestInfo"
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
	}
	
	if ($updateSQL) {
		if ($sqlStringDeleteBuilder.length) {
			$sqlStringTmp = $sqlStringDeleteBuilder.ToString()
			try {
				Invoke-SqlCmd $sqlStringTmp -ConnectionString "$($strSqlConnectionString)"  -QueryTimeout 300
			}
			catch {
				write-warning "WARNING: Deleting from SQL in updateDBsForTestInfo"
				$_.Exception
			}
		}
		if ($sqlStringInsertBuilder.length) {
			$sqlStringTmp = $sqlStringInsertBuilder.ToString()
			try {
				Invoke-SqlCmd $sqlStringTmp -ConnectionString "$($strSqlConnectionString)"  -QueryTimeout 300
			}
			catch {
				write-warning "ERROR: writing to SQL in updateDBsForTestInfo"
				$_.Exception
			}
		}
		$sqlStringTmp = $null
		$null = $sqlStringInsertBuilder.clear()
		$null = $sqlStringDeleteBuilder.clear()
	}
}


function createSmallSqlTables {

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
			Invoke-SqlCmd $sqlString -ConnectionString "$($strSqlConnectionString)" -QueryTimeout 1800
		}
		catch {
			write-host "ERROR: updating SQL"
			$_.Exception
			$sqlString
		}
	}
}


main
