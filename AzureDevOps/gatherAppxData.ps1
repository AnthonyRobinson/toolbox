param (
    [string]$PATSjson = $null
)


function queryES {

	$body = @"
{
	"query": {
		"bool": {
			"must": [{
					"match_phrase": {
						"BuildDef": {
							"query": "$($global:product)"
						}
					}
				}, {
					"match_phrase": {
						"BuildNumber": {
							"query": "$($global:product)_$($global:tmpBuildNum)"
						}
					}
				}, {
					"match_phrase": {
						"RecordType": {
							"query": "Job"
						}
					}
				}, {
					"bool": {
						"should": [{
								"match_phrase": {
									"BuildJob": "Build $($global:appxType),$($tmpArch)"
								}
							}, {
								"match_phrase": {
									"BuildJob": "Phase 1 $($global:appxType),$($tmpArch)"
								}
							}, {
								"match_phrase": {
									"BuildJob": "Agent job 1 $($global:appxType),$($tmpArch)"
								}
							}, {
								"match_phrase": {
									"BuildJob": "Package - $($global:appxBundleType)"
								}
							}
						],
						"minimum_should_match": 1
					}
				}
			],
			"filter": [{
					"match_all": {}
				}
			],
			"should": [],
			"must_not": []
		}
	}
}
"@
	$response = invoke-RestMethod -Uri "http://$($global:strElasticSearchServer):9200/buildinfo/_search" -Method POST -Body $body -ContentType "application/json"
	$global:agent = $response.hits.hits._source.agent
	return $global:agent
}


function writeToES {

	$tmpKey = $($global:appxFile.replace('\','\\'))
	
	$esString = $null
	
	$tmpString = @"
{
	"delete": {
		"_index": "$($global:strElasticSearchIndex)",
		"_type": "data",
		"_id": "$($tmpKey)"
	}
}
"@
	$esString += $tmpString | convertfrom-json | convertto-json -compress
	$esString += "`n"
			
	$tmpString = @"
{
	"create": {
		"_index": "$($global:strElasticSearchIndex)",
		"_type": "data",
		"_id": "$($tmpKey)"
	}
}
"@
	$esString += $tmpString | convertfrom-json | convertto-json -compress
	$esString += "`n"

	$tmpString = @"
{
	"Appx_FilePath": "$($tmpKey)",
	"Arch":"$($global:arch)",
	"Type":"$($global:appxType)",
	"Platform":"$($global:appxBundleType)",
	"Zip_Type":"$($global:ziptype)",
	"BuildDef": "$($global:product)",
	"BuildNumber": "$($global:tmpBuildNum)",
	"Creation_Time": "$($global:appxFileCreationTime)",
	"File_Size": "$($global:appxFileLength)",	
	"VCLib_Version": "$($global:tmpMinVersion)",
	"Agent": "$($global:agent)"
}
"@

	$esString += $tmpString | convertfrom-json | convertto-json -compress
	$esString += "`n"
	$esString += "`n"

	try {
		$result = invoke-RestMethod -Uri http://$($global:strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $esString -ContentType "application/json"
	}
	catch {
		write-warning "Errors writing to ES - Bulk Mode"
	}
}



function checkES {

	$tmpKey = $($global:appxFile.replace('\','\\'))

	$body = @"
{
  "query": {
    "bool": {
      "must": [
        {
          "match_all": {}
        },
        {
          "match_phrase": {
            "_id": {
              "query": "$($tmpKey)"
            }
          }
        }
      ],
      "filter": [],
      "should": [],
      "must_not": []
    }
  }
}
"@

	$response = invoke-RestMethod -Uri "http://$($global:strElasticSearchServer):9200/$($global:strElasticSearchIndex)/_search" -Method POST -Body $body -ContentType "application/json"
	return $response.hits.total
}
  

function main {

	$scriptPath = Split-Path $script:MyInvocation.MyCommand.Path
	$scriptPath
	. "$($scriptPath)\gatherIncludes.ps1"

	$progressPreference = 'silentlyContinue'
	$thisRunDateTimeUTC = (get-date).ToUniversalTime()
	$thisRunDateTime = (get-date)
	$DEBUG = $ENV:DEBUG
	
	# --- Set some defaults

	# --- Override defaults with settings string

	loadConfiguration
	
	$global:strElasticSearchServer = $strElasticSearchServer
	$global:strElasticSearchIndex = "appxinfo"
	
	$global:ProgressPreference = 'SilentlyContinue'

	$global:appxTypes = "Ship","Ship.Inbox","Debug","Release","Release.Inbox"
	$global:appxBundleTypes = "desktop", "holographic", "mobile", "xbox", "8828080", "universal"

	$global:arches = "arm","x86","x64"
	$random = random
	$global:scratchFolder = "c:\tmp$($random)"
	
	if (test-path $global:scratchFolder) {
		Remove-Item "$($global:scratchFolder)" -Force -recurse
	}
	
	mkdir $global:scratchFolder
	
	$global:products = @(
		"Evoke.App_Release2019-07_CI",
		"Evoke.App_Release2019-08_CI",
		"Evoke.App_Release2019-09_CI",
		"Evoke.App_Release2019-10_CI",
		"Evoke.App_Master_Rolling",
		"Evoke.App_Master_Daily"
	)
	
	if (!($minutesBack = $ENV:minutesBack)) {
		try {
			$tmp = invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/timestamp/data/$($global:strElasticSearchIndex)
			$lastRunDateTime = [datetime]([string]$tmp._source.LastRunTime)
			write-host "INFO: last run was at" $lastRunDateTime
			$minutesBack = (new-TimeSpan -start $thisRunDateTimeUTC -end $lastRunDateTime).TotalMinutes
			$minutesBack = $minutesBack - 360
		}
		catch {
			$minutesBack = -240
		}
	}
	
	$strStartDate = (get-date).AddMinutes($minutesBack)

	write-host "INFO: using minutesBack of" $minutesBack "and strStartDate" $strStartDate
	

	foreach ($global:product in $global:products) {
	
		foreach ($releaseDir in "Photos", "Photos.Scratch") {
	
			$skipAhead = $false

			if (test-path "\\pkges\release\$($releaseDir)\$($global:product)") {
			
				foreach ($release in (get-childitem -path "\\pkges\release\$($releaseDir)\$($global:product)" -attributes Directory | Where-Object {$_.LastWriteTime -gt (Get-Date).AddMinutes($minutesBack)} | sort-object Name -Descending | Select-Object -First 8).fullname) {
				
					if (!($skipAhead)) {

						Remove-Item "$($global:scratchFolder)\*.zip" -Force

						if (!($release -like "*Latest.tst*")) {
					
							foreach ($global:appxType in $global:appxTypes) {
							
								foreach ($global:arch in $global:arches) {
									if (test-path "$($global:scratchFolder)\$($global:arch).$($global:appxType)") {
										Remove-Item "$($global:scratchFolder)\$($global:arch).$($global:appxType)" -Recurse -Force
									}
								}
								foreach ($global:appxBundleType in $global:appxBundleTypes) {
									if (test-path "$($global:scratchFolder)\$($global:arch).$($global:appxBundleType)") {
										Remove-Item "$($global:scratchFolder)\$($global:arch).$($global:appxBundleType)" -Recurse -Force
									}
								}
												
								foreach ($global:appxBundleType in $global:appxBundleTypes) {
								
									$global:appxFile = $null
									$global:tmpMinVersion = $null
									$tmpFileInfo = $null
									
									if (test-path "$($release)\$($global:appxType)\appxbundle\$($appxBundleType)") {
										if ($tmpFileInfo = get-childitem -path "$($release)\$($global:appxType)\appxbundle\$($appxBundleType)" -filter "appstubcs.windows_*_$($global:appxType)_$($global:appxBundleType).appxbundle") {
											$global:appxFile = $($tmpFileInfo).fullname
											$global:appxFileShort = $($tmpFileInfo).name
											$global:appxFileCreationTime = $($tmpFileInfo).CreationTime.toString("MM/dd/yyyy HH:mm:ss")
											$global:appxFileLength = $($tmpFileInfo).Length
											$global:tmpBuildNum = ($global:appxFile.split("\"))[6]
											$global:ziptype = "appxbundle"
											$global:arch = $null
											$global:agent = $null
											$global:agent = queryES
											write-host $global:appxFile, $global:appxFileLength, $global:agent
											writeToES
										}
									}
								}
								
								foreach ($global:arch in $global:arches) {
								
									foreach ($global:ziptype in "appx", "msix") {
								
										$tmpArch = $global:arch
										$global:appxFile = $null
										$global:appxBundleType = $null
										$tmpFileInfo = $null
										
										if ($global:arch -like "x86") {
											$tmpArch = "Win32"
										} else {
											$tmpArch = $($global:arch)
										}
										
										if (test-path "$($release)\$($global:appxType)\$($tmpArch)\appstubcs.windows") {
											if ($tmpFileInfo = get-childitem -path "$($release)\$($global:appxType)\$($tmpArch)\appstubcs.windows" -filter "appstubcs.windows_*_$($global:arch)_$($global:appxType).$($global:ziptype)") {
												$global:appxFile = $($tmpFileInfo).fullname
												$global:appxFileShort = $($tmpFileInfo).name
												$global:appxFileCreationTime = $($tmpFileInfo).CreationTime.toString("MM/dd/yyyy HH:mm:ss")
												$global:appxFileLength = $($tmpFileInfo).Length
											}
										}

										if ($global:appxFile) {
											$hitsCount = checkES
											if ($hitsCount -eq 0) {
												if (!(test-path "$($global:scratchFolder)\$($global:appxFileShort).zip")) {
													copy $global:appxFile "$($global:scratchFolder)\$($global:appxFileShort).zip"
												}
												expand-archive "$($global:scratchFolder)\$($global:appxFileShort).zip" -DestinationPath "$($global:scratchFolder)\$($global:arch).$($global:appxType)"
												if (test-path "$($global:scratchFolder)\$($global:arch).$($global:appxType)\appxmanifest.xml") {
													[xml]$tmp = get-content "$($global:scratchFolder)\$($global:arch).$($global:appxType)\appxmanifest.xml"
													$global:dependencies = $tmp.Package.Dependencies.PackageDependency | where-object {$_.name -like "Microsoft.VCLibs.140.00"}
													foreach ($global:dep in $global:dependencies) {
														$global:tmpBuildNum = ($global:appxFile.split("\"))[6]
														$global:agent = $null
														$global:agent = queryES
														$global:tmpMinVersion = $global:dep.MinVersion
														write-host $global:appxFile, $global:tmpMinVersion, $global:agent
														writeToES
													}
												} else {
													write-warning "Cant find $($global:scratchFolder)\$($global:arch).$($global:appxType)\appxmanifest.xml"
												}
											} else {
												write-host "$($global:appxFile) already in ES. Skipping ahead..."
												# $skipAhead = $true
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
	
	if (test-path $global:scratchFolder) {
		write-host "Cleaning up..."
		Remove-Item "$($global:scratchFolder)" -Force -recurse
	}
	
	if ($updateElastic -and $updateLastRunTime) {
		write-host "Updating LastRunTime time stamps..."
		$esString += @"
{"delete": {"_index": "timestamp","_type": "data","_id": "$($global:strElasticSearchIndex)"}}
{"create": {"_index": "timestamp","_type": "data","_id": "$($global:strElasticSearchIndex)"}}
{"ID": "$($global:strElasticSearchIndex)","LastRunTime": "$($thisRunDateTimeUTC)"}

"@
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


				