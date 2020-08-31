<#

	.SYNOPSIS
		Query VSTS for artifacts associated with Coverage build and summarize their results to ElasticSearch

	.DESCRIPTION
		Query VSTS for artifacts associated with Coverage build and summarize their results to ElasticSearch

	.INPUTS
		All inputs (server names, query options, time window, destructive db writes, etc.) are inferred from the calling environment.  If not set, some defaults are taken.

	.OUTPUTS
		Outputs are data written to ElasticSearch

	.NOTES
		Anthony A Robinson 10/2018
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

# --- Set some defaults

	if (!($projectUrl = $ENV:SYSTEM_TEAMFOUNDATIONSERVERURI)) {
		$projectUrl = "https://microsoft.visualstudio.com"
	}
	
# --- Override defaults with settings string

	loadConfiguration
	
# --- override defaults and configuration settings
	
	$strElasticSearchIndex = "coverage"
	
    $personalAccessToken = $ENV:PAT
    $OAuthToken = $ENV:System_AccessToken
   
    if ($OAuthToken) {
        $headers = @{Authorization = ("Bearer {0}" -f $OAuthToken)}
    } elseif ($personalAccessToken) {
        $headers = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($personalAccessToken)"))}
    } else {
        write-error "Neither personalAccessToken nor OAuthToken are set"
    }
	
	$strProject = "apps"
	$projectUrlProject = $projectUrl + "/" + $strProject

	$processPackages = $true
	$processClasses = $false
	$processSource = $false
	$deleteAllPreviousESrecords = $false

	$progressPreference = 'silentlyContinue'

	$coverageBuildDefId = "21503"
	$startDate = (get-date).AddDays(-30).ToString("MM/dd/yyyy")

	if ($DEBUG) {
		get-variable | format-table Name, Value
	}
	
	$builds = Invoke-RestMethod "$projectUrlProject/_apis/build/builds?api-version=4.0&definitions=$($coverageBuildDefId)&minFinishTime=$($startDate)" -Headers $headers
	
	if (!($builds.count)) {
		write-host "No coverage builds for buildDefID", $coverageBuildDefId, "found since", $startDate
		exit 0
	}

	
	foreach ($build in $builds.value) {

		write-host "Processing build", $build.id
		
		if ($updateElastic) {
			if ($deleteAllPreviousESrecords) {
				write-host "Deleting previous build", $build.id, "data..."
				while ($true) {
					$esString = @"
{"query": { "match": {"BuildID":"$build.id"}}}

"@
					$ids = (invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/$($strElasticSearchIndex)/_search?size=2000 -Method POST -Body $esString -ContentType "application/json").hits.hits._id

					if ($ids) {
						$esString = $null
						foreach ($id in $ids) {
							
							$esString += @"
{"delete": {"_index": "$($strElasticSearchIndex)","_type": "data","_id": "$($id)"}}

"@
						}
						if ($esString) {
							invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
							$esString = $null
						}
					} else {
						break
					}
				}
			}
		}
		

		$finishTime = ([DateTime]::Parse($build.finishTime)).ToUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
		$artifacts = $null
		$esString = $null
		
		try {
			$artifacts = Invoke-RestMethod "$projectUrlProject/_apis/build/builds/$($build.id)/artifacts" -Headers $headers
		}
		catch {
			write-warning "No artifacts for this build"
			Write-Host "##vso[task.logissue type=warning;] No artifacts for this build"
		}
		
		if ($artifacts) {
		
			foreach ($artifact in $artifacts.value) {
			
				if ($artifact.name -like "UncDrop") {
				
					$coverageXml = $artifact.resource.data + "\CodeCoverageResult\All\Summary\coveragesummary.xml"
					
					if (Test-Path $coverageXml) {
					
						write-host "Found aftifact", $coverageXml
					
						[xml]$covSummary = gc $coverageXml
						
						foreach ($report in $covSummary.report) {
						
							write-host $report.name
						
							foreach ($counter in $report.counter) {
								
								$reportHash = Get-StringHash($report.name)
								$groupHash = $null
								$packageHash = $null
								$classHash = $null
								$sourcefileHash = $null
								$counterHash = Get-StringHash($counter.type)
								$CoverageKey = [string]$build.id + "_" + `
												$reportHash + "_" + `
												$groupHash + "_" + `
												$packageHash + "_" + `
												$classHash + "_" + `
												$sourcefileHash + "_" + `
												$counterHash
								
								$linesTotal = (([int]$counter.missed) + ([int]$counter.covered))
								if ($linesTotal) {
									$pctCoverage = (([int]$counter.covered) / $linesTotal)
								} else {
									$pctCoverage = 0
								}
								
								if ($deletePreviousElasticRecord) {
									$esString += @"
{"delete": {"_index": "$($strElasticSearchIndex)","_type": "data","_id": "$($CoverageKey)"}}

"@
								}
								$esString += @"
{"create": {"_index": "$($strElasticSearchIndex)","_type": "data","_id": "$($CoverageKey)"}}
{"CoverageKey": "$($CoverageKey)","BuildID": "$($build.id)","ReportName": "$($report.name)","CounterType": "$($counter.type)","Finish_Time": "$($finishTime)","Type": "$($counter.type)","LinesMissed": $($counter.missed),"LinesCovered": $($counter.covered),"LinesTotal": $linesTotal,"pctCoverage": $pctCoverage}

"@		
							}
						
							$result = $null
							if ($updateElastic) {
								$result = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
							}
							if ($result.errors) {
								write-warning "Errors writing to ES - Bulk Mode"
								foreach ($resultItem in $result.items) {
									if ($resultItem.create.error) {
										$resultItem.create.error | convertto-json -depth 100
									}
								}
								$esString
							}
							$esString = $null
							
							foreach ($group in $report.group) {
							
								write-host $report.name, $group.name

								foreach ($counter in $group.counter) {
								
									$reportHash = Get-StringHash($report.name)
									$groupHash = Get-StringHash($group.name)
									$packageHash = $null
									$classHash = $null
									$sourcefileHash = $null
									$counterHash = Get-StringHash($counter.type)
									$CoverageKey = [string]$build.id + "_" + `
																$reportHash + "_" + `
																$groupHash + "_" + `
																$packageHash + "_" + `
																$classHash + "_" + `
																$sourcefileHash + "_" + `
																$counterHash

									$linesTotal = (([int]$counter.missed) + ([int]$counter.covered))
									if ($linesTotal) {
										$pctCoverage = (([int]$counter.covered) / $linesTotal)
									} else {
										$pctCoverage = 0
									}
									
									if ($deletePreviousElasticRecord) {
										$esString += @"
{"delete": {"_index": "$($strElasticSearchIndex)","_type": "data","_id": "$($CoverageKey)"}}

"@
									}								
									$esString += @"
{"create": {"_index": "$($strElasticSearchIndex)","_type": "data","_id": "$($CoverageKey)"}}
{"CoverageKey": "$($CoverageKey)","BuildID": "$($build.id)","ReportName": "$($report.name)","GroupName": "$($group.name)","CounterType": "$($counter.type)","Finish_Time": "$($finishTime)","Type": "$($counter.type)","LinesMissed": $($counter.missed),"LinesCovered": $($counter.covered),"LinesTotal": $linesTotal,"pctCoverage": $pctCoverage}

"@
								}
								
								$result = $null
								if ($updateElastic) {
									$result = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
								}
								if ($result.errors) {
									write-warning "Errors writing to ES - Bulk Mode"
									foreach ($resultItem in $result.items) {
										if ($resultItem.create.error) {
											$resultItem.create.error | convertto-json -depth 100
										}
									}
									$esString
								}
								$esString = $null

								
								if ($processPackages) {
									foreach ($package in $group.package) {
									
										write-host $report.name, $group.name, $package.name
											
										foreach ($counter in $package.counter) {
										
											$reportHash = Get-StringHash($report.name)
											$groupHash = Get-StringHash($group.name)
											$packageHash = Get-StringHash($package.name)
											$classHash = $null
											$sourcefileHash = $null
											$counterHash = Get-StringHash($counter.type)
											$CoverageKey = [string]$build.id + "_" + `
																	$reportHash + "_" + `
																	$groupHash + "_" + `
																	$packageHash + "_" + `
																	$classHash + "_" + `
																	$sourcefileHash + "_" + `
																	$counterHash

											$linesTotal = (([int]$counter.missed) + ([int]$counter.covered))
											if ($linesTotal) {
												$pctCoverage = (([int]$counter.covered) / $linesTotal)
											} else {
												$pctCoverage = 0
											}
										
											if ($deletePreviousElasticRecord) {
												$esString += @"
{"delete": {"_index": "$($strElasticSearchIndex)","_type": "data","_id": "$($CoverageKey)"}}

"@
											}
											$esString += @"
{"create": {"_index": "$($strElasticSearchIndex)","_type": "data","_id": "$($CoverageKey)"}}
{"CoverageKey": "$($CoverageKey)","BuildID": "$($build.id)","ReportName": "$($report.name)","GroupName": "$($group.name)","PackageName": "$($package.name)","CounterType": "$($counter.type)","Finish_Time": "$($finishTime)","Type": "$($counter.type)","LinesMissed": $($counter.missed),"LinesCovered": $($counter.covered),"LinesTotal": $linesTotal,"pctCoverage": $pctCoverage}

"@
										}
										
										$result = $null
										if ($updateElastic) {
											$result = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
										}
										if ($result.errors) {
											write-warning "Errors writing to ES - Bulk Mode"
											foreach ($resultItem in $result.items) {
												if ($resultItem.create.error) {
													$resultItem.create.error | convertto-json -depth 100
												}
											}
											$esString
										}
										$esString = $null
									}
										
									
									if ($processClasses) {
									
										write-host $report.name, $group.name, $package.name, "Classes..."
									
										foreach ($class in $package.class) {
										
											foreach ($counter in $class.counter) {
																
												$reportHash = Get-StringHash($report.name)
												$groupHash = Get-StringHash($group.name)
												$packageHash = Get-StringHash($package.name)
												$classHash = Get-StringHash($class.name)
												$sourcefileHash = $null
												$counterHash = Get-StringHash($counter.type)
												$CoverageKey = [string]$build.id + "_" + `
																$reportHash + "_" + `
																$groupHash + "_" + `
																$packageHash + "_" + `
																$classHash + "_" + `
																$sourcefileHash + "_" + `
																$counterHash

												$linesTotal = (([int]$counter.missed) + ([int]$counter.covered))
												if ($linesTotal) {
													$pctCoverage = (([int]$counter.covered) / $linesTotal)
												} else {
													$pctCoverage = 0
												}

											if ($deletePreviousElasticRecord) {
												$esString += @"
{"delete": {"_index": "$($strElasticSearchIndex)","_type": "data","_id": "$($CoverageKey)"}}

"@
											}
											$esString += @"
{"create": {"_index": "$($strElasticSearchIndex)","_type": "data","_id": "$($CoverageKey)"}}
{"CoverageKey": "$($CoverageKey)","BuildID": "$($build.id)","ReportName": "$($report.name)","GroupName": "$($group.name)","PackageName": "$($package.name)","ClassName": "$($class.name)","CounterType": "$($counter.type)","Finish_Time": "$($finishTime)","Type": "$($counter.type)","LinesMissed": $($counter.missed),"LinesCovered": $($counter.covered),"LinesTotal": $linesTotal,"pctCoverage": $pctCoverage}

"@
											}
											
											$result = $null
											if ($updateElastic) {
												$result = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
											}
											if ($result.errors) {
												write-warning "Errors writing to ES - Bulk Mode"
												foreach ($resultItem in $result.items) {
													if ($resultItem.create.error) {
														$resultItem.create.error | convertto-json -depth 100
													}
												}
												$esString
											}
											$esString = $null
										}
									}
									
									if ($processSource) {
										
										write-host $report.name, $group.name, $package.name, "Source..."
									
										foreach ($sourcefile in $package.sourcefile) {

											foreach ($counter in $sourcefile.counter) {
																
												$reportHash = Get-StringHash($report.name)
												$groupHash = Get-StringHash($group.name)
												$packageHash = Get-StringHash($package.name)
												$classHash = $null
												$sourcefileHash = Get-StringHash($sourcefile.name)
												$counterHash = Get-StringHash($counter.type)
												$CoverageKey = [string]$build.id + "_" + `
																$reportHash + "_" + `
																$groupHash + "_" + `
																$packageHash + "_" + `
																$classHash + "_" + `
																$sourcefileHash + "_" + `
																$counterHash

												$linesTotal = (([int]$counter.missed) + ([int]$counter.covered))
												if ($linesTotal) {
													$pctCoverage = (([int]$counter.covered) / $linesTotal)
												} else {
													$pctCoverage = 0
												}

											if ($deletePreviousElasticRecord) {
												$esString += @"
{"delete": {"_index": "$($strElasticSearchIndex)","_type": "data","_id": "$($CoverageKey)"}}

"@
											}
											$esString += @"
{"create": {"_index": "$($strElasticSearchIndex)","_type": "data","_id": "$($CoverageKey)"}}
{"CoverageKey": "$($CoverageKey)","BuildID": "$($build.id)","ReportName": "$($report.name)","GroupName": "$($group.name)","PackageName": "$($package.name)","SourceFileName": "$($sourcefile.name)","CounterType": "$($counter.type)","Finish_Time": "$($finishTime)","Type": "$($counter.type)","LinesMissed": $($counter.missed),"LinesCovered": $($counter.covered),"LinesTotal": $linesTotal,"pctCoverage": $pctCoverage}

"@
											}
											
											$result = $null
											if ($updateElastic) {
												$result = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
											}
											if ($result.errors) {
												write-warning "Errors writing to ES - Bulk Mode"
												foreach ($resultItem in $result.items) {
													if ($resultItem.create.error) {
														$resultItem.create.error | convertto-json -depth 100
													}
												}
												$esString
											}
											$esString = $null
										}
									}
								}
							}
						}
					} else {
						write-warning "No coveragesummary.xml file found"
						Write-Host "##vso[task.logissue type=warning;] No coveragesummary.xml file found"
					}
				} else {
					write-warning "No UncDrop found"
					Write-Host "##vso[task.logissue type=warning;] No UncDrop found"
				}
			}
		} else {
			write-warning "No artifacts found"
			Write-Host "##vso[task.logissue type=warning;] No artifacts found"
		}
	} 
}

main