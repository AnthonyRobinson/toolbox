function Get-StringHash([String] $String, $HashName = "MD5") {
    $global:StringBuilder = New-Object System.Text.StringBuilder
    [System.Security.Cryptography.HashAlgorithm]::Create($HashName).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($String)) | % {
        [Void]$StringBuilder.Append($_.ToString("x2"))
    }
    $global:StringBuilder.ToString()
}

function loadConfiguration {
    if ($ENV:jsonConfiguration) {

        $global:jsonConfiguration = $ENV:jsonConfiguration | convertfrom-json

        if ($jsonConfiguration.databases.elasticsearch.server) {
            $global:strElasticSearchServer = $jsonConfiguration.databases.elasticsearch.server
        }
        if ($jsonConfiguration.databases.elasticsearch.indexes.build) {
            $global:strElasticSearchIndex = $jsonConfiguration.databases.elasticsearch.indexes.build
        }
        if ($jsonConfiguration.databases.elasticsearch.BatchSize) {
            $global:intElasticSearchBatchSize = $jsonConfiguration.databases.elasticsearch.BatchSize
        }
        if ($jsonConfiguration.databases.sqlserver.ConnectionString) {
            $global:strSqlConnectionString = $jsonConfiguration.databases.sqlserver.ConnectionString
        }
        if ($jsonConfiguration.databases.sqlserver.Server) {
            $global:strSqlServer = $jsonConfiguration.databases.sqlserver.Server
        }
        if ($jsonConfiguration.databases.sqlserver.database) {
            $global:strSqlDatabase = $jsonConfiguration.databases.sqlserver.database
        }
        if ($jsonConfiguration.databases.sqlserver.tables.build) {
            $global:strSqlTable = $jsonConfiguration.databases.sqlserver.tables.build
        }
        if ($jsonConfiguration.databases.sqlserver.BatchSize) {
            $global:intSqlBatchSize = $jsonConfiguration.databases.sqlserver.BatchSize
        }
        if ($jsonConfiguration.databases.elasticsearch.deletePreviousRecord) {
            $global:deletePreviousElasticRecord = $false
            if ($jsonConfiguration.databases.elasticsearch.deletePreviousRecord -eq "true") {
                $global:deletePreviousElasticRecord = $true
            }
        }
        if ($jsonConfiguration.databases.sqlserver.deletePreviousRecord) {
            $global:deletePreviousSQLrecord = $false
            if ($jsonConfiguration.databases.sqlserver.deletePreviousRecord -eq "true") {
                $global:deletePreviousSQLrecord = $true
            }
        }
        if ($jsonConfiguration.processTimeLine) {
            $global:processTimeLine = $false
            if ($jsonConfiguration.processTimeLine -eq "true") {
                $global:processTimeLine = $true
            }
        }
        if ($jsonConfiguration.databases.elasticsearch.updateLastRunTime) {
            $global:updateLastRunTime = $false
            if ($jsonConfiguration.databases.elasticsearch.updateLastRunTime -eq "true") {
                $global:updateLastRunTime = $true
            }
        }
        if ($jsonConfiguration.databases.elasticsearch.update) {
            $global:updateElastic = $false
            if ($jsonConfiguration.databases.elasticsearch.update -eq "true") {
                $global:updateElastic = $true
            }
        }
        if ($jsonConfiguration.databases.sqlserver.update) {
            $global:updateSQL = $false
            if ($jsonConfiguration.databases.sqlserver.update -eq "true") {
                $global:updateSQL = $true
            }
        }
    }
    else {
        write-warning "JSON Configuration environment variable not found"
    }
}

function makeUnique {
    param(
        [parameter(Mandatory = $false)] [string]$inString
    )

    if ($inString) {
        $stringHash = @{ }

        foreach ($line in ($inString.replace('\n', $([char]0x000A))).split($([char]0x000A))) {
            if ($line) {
                if (!($stringHash.ContainsKey($line))) {
                    $stringHash.Add($line, 1)
                }
            }
        }
        return(($stringHash.keys -join ('\n')) + '\n')
    }
}

$resourceAreaId = @{ `
        "account"                     = "0d55247a-1c47-4462-9b1f-5e2125590ee6"; `
        "build"                       = "5d6898bb-45ec-463f-95f9-54d49c71752e"; `
        "collection"                  = "79bea8f8-c898-4965-8c51-8bbc3966faa8"; `
        "core"                        = "79134c72-4a58-4b42-976c-04e7115f32bf"; `
        "dashboard"                   = "31c84e0a-3ece-48fd-a29d-100849af99ba"; `
        "delegatedAuth"               = "a0848fa1-3593-4aec-949c-694c73f4c4ce"; `
        "discussion"                  = "6823169a-2419-4015-b2fd-6fd6f026ca00"; `
        "distributedtask"             = "a85b8835-c1a1-4aac-ae97-1c3d0ba72dbd"; `
        "drop"                        = "7bf94c77-0ce1-44e5-a0f3-263e4ebbf327"; `
        "extensionManagement"         = "6c2b0933-3600-42ae-bf8b-93d4f7e83594"; `
        "favorite"                    = "67349c8b-6425-42f2-97b6-0843cb037473"; `
        "git"                         = "4e080c62-fa21-4fbc-8fef-2a10a2b38049"; `
        "graph"                       = "4e40f190-2e3f-4d9f-8331-c7788e833080"; `
        "memberEntitlementManagement" = "68ddce18-2501-45f1-a17b-7931a9922690"; `
        "nuget"                       = "b3be7473-68ea-4a81-bfc7-9530baaa19ad"; `
        "npm"                         = "4c83cfc1-f33a-477e-a789-29d38ffca52e"; `
        "package"                     = "45fb9450-a28d-476d-9b0f-fb4aedddff73"; `
        "packaging"                   = "7ab4e64e-c4d8-4f50-ae73-5ef2e21642a5"; `
        "pipelines"                   = "2e0bf237-8973-4ec9-a581-9c3d679d1776"; `
        "policy"                      = "fb13a388-40dd-4a04-b530-013a739c72ef"; `
        "profile"                     = "8ccfef3d-2b87-4e99-8ccb-66e343d2daa8"; `
        "release"                     = "efc2f575-36ef-48e9-b672-0c6fb4a48ac5"; `
        "reporting"                   = "57731fdf-7d72-4678-83de-f8b31266e429"; `
        "search"                      = "ea48a0a1-269c-42d8-b8ad-ddc8fcdcf578"; `
        "test"                        = "3b95fb80-fdda-4218-b60e-1052d070ae6b"; `
        "testresults"                 = "c83eaf52-edf3-4034-ae11-17d38f25404c"; `
        "tfvc"                        = "8aa40520-446d-40e6-89f6-9c9f9ce44c48"; `
        "user"                        = "970aa69f-e316-4d78-b7b0-b7137e47a22c"; `
        "wit"                         = "5264459e-e5e0-4bd8-b118-0985e68a4ec5"; `
        "work"                        = "1d4f49f9-02b9-4e26-b826-2cdb6195f2a9"; `
        "worktracking"                = "85f8c7b6-92fe-4ba6-8b6d-fbb67c809341";
}

class ReleaseRecord {
    [string]$ReleaseKey
    [string]$PipelineID
    [string]$ReleaseID
    [string]$EnvironmentID
    [string]$DeployStepID
    [string]$ReleaseDeployPhaseID
    [string]$DeploymentJobID
    [string]$TaskID
    [string]$PipelineName
    [string]$ReleaseName
    [string]$EnvironmentName
    [string]$ReleaseDeployPhaseName
    [string]$DeploymentJobName
    [string]$TaskName
    [string]$Tenant
    [string]$Project
    [string]$IssueCount
    [string]$Attempt
    [string]$RecordType
    [string]$Status
    [string]$CreatedOn_Time = $global:CreatedOn_Time
    [string]$CreatedOn_TimeZ = $global:CreatedOn_TimeZ
    [string]$ModifiedOn_Time = $global:ModifiedOn_Time
    [string]$ModifiedOn_TimeZ = $global:ModifiedOn_TimeZ
    [string]$Start_Time = $global:Start_Time
    [string]$Start_TimeZ = $global:Start_TimeZ
    [string]$Finish_Time = $global:Finish_Time
    [string]$Finish_TimeZ = $global:Finish_TimeZ
    [string]$Queued_Time = $global:Queued_Time
    [string]$Queued_TimeZ = $global:Queued_TimeZ
    [float]$Elapsed_Time
    [float]$Wait_Time
    [string]$Agent
    [string]$Reason
    [string]$Description
    [string]$VSTSlink
    [string]$RequestedFor
    [string]$RequestedBy
    [string]$ModifiedBy
    [string]$CreatedBy
    [string]$Variables
    [string]$ArtifactVersion
    [string]$ErrorIssues
}

class BuildRecord {
    [string]$BuildKey
    [string]$BuildID
    [string]$TimeLineID
    [string]$ParentID
    [string]$RecordType
    [string]$BuildDef
    [string]$BuildDefID
    [string]$BuildDefPath
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
    [string]$Tenant
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
    [string]$TestLanguage
    [string]$TestFailures
    [string]$TestFailCount
    [string]$TestPassCount
    [string]$TestTotalCount
    [string]$TestFailPct
    [string]$TestPassPct
}

class TestRecord {
    [string]$TestKey
    [string]$BuildID
    [string]$BuildDef
    [string]$BuildDefID
    [string]$BuildDefPath
    [string]$Quality
    [string]$BuildNumber
    [string]$URL
    [string]$Outcome
    [DateTime]$Finish_Time
    [DateTime]$Finish_TimeZ
    [string]$Tenant
    [string]$Project
    [string]$Agent_Pool
    [string]$Agent
    [string]$Language
    [string]$automatedTestName
    [string]$automatedTestStorage
    [string]$owner
    [string]$testCaseTitle
    [float]$duration

}