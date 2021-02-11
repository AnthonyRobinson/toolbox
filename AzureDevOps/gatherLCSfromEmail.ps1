class lcsRecord {
    [string]$lcsKey
    [DateTime]$StartTime
    [DateTime]$FinishTime
    [float]$ElapsedTime
    [string]$CompanyName
    [string]$ProjectId
    [string]$Environment
    [string]$EnvironmentName
    [string]$EnvironmentId
    [string]$Operation
    [string]$Update
    [string]$Status
    [string]$GoodDeployment
}


function main {

    $strElasticSearchIndex = "lcsdeploys"
    # $strElasticSearchServer = "LT-14763.corp.sanmar.com"
    $strElasticSearchServer = "52.158.250.123"

    $lcsInfoTable = [System.Collections.ArrayList]@()

    $data = ""

    # foreach ($daysback in -3, -5, -10, -20, -300) {
    foreach ($daysback in -600) {

        Write-Host "Querying $daysback days back..."

        $lcsDeployStartTime = @{ }
        $lcsDeployInProgress = @{ }

        $LCSenvList = "Bat", "eDEV", "eUAT", "STAGE", "Sandbox", "Master", "Test", "constest", "Prod", "training"

        Add-Type -assembly "Microsoft.Office.Interop.Outlook" | Out-Null
        $olFolders = "Microsoft.Office.Interop.Outlook.olDefaultFolders" -as [type]
        $outlook = New-Object -ComObject outlook.application
        $namespace = $outlook.GetNameSpace("MAPI")
        $folder = $namespace.getDefaultFolder($olFolders::olFolderInBox)

        $messages = $folder.items | Where-Object { `
                $_.SenderEmailAddress -like "lcsteam@microsoft.com" -and `
                $_.SentOn -gt (Get-Date).AddDays($daysBack)
        } | Sort-Object -Property SentOn

        foreach ($message in $messages) {

            $lcsObject = New-Object lcsRecord

            foreach ($line in ($message.body.split("`n"))) {
                switch -wildcard ($line) {
                    '*Company name:*' {
                        $lcsObject.CompanyName = $line.split(":")[-1].trimstart().trimend()
                        break
                    }
                    '*Organization Name:*' {
                        $lcsObject.CompanyName = $line.split(":")[-1].trimstart().trimend()
                        break
                    }
                    '*LCS project ID:*' {
                        $lcsObject.ProjectId = $line.split(":")[-1].trimstart().trimend()
                        break
                    }
                    '*Project ID:*' {
                        $lcsObject.ProjectId = $line.split(":")[-1].trimstart().trimend()
                        break
                    }
                    '*Operation:*' {
                        $lcsObject.Operation = $line.split(":")[-1].trimstart().trimend()
                        break
                    }
                    '*Environment name:*' {
                        $lcsObject.EnvironmentName = $line.split("<")[0].split(":")[-1].trimstart().trimend()
                        foreach ($env in $LCSenvList) {
                            if ($lcsObject.EnvironmentName -like "*$($env)*") {
                                $env
                                $lcsObject.Environment = $env
                            }
                        }
                        break
                    }
                    '*Environment ID:*' {
                        $lcsObject.EnvironmentId = $line.split(":")[-1].trimstart().trimend()
                        break
                    }
                    '*Update:*' {
                        $lcsObject.Update = $line.split(":")[-1].trimstart().trimend()
                        break
                    }
                    '*Package Name:*' {
                        $lcsObject.Update = $line.split(":")[-1].trimstart().trimend()
                        break
                    }
                    '*Status:*' {
                        $lcsObject.Status = $line.split(":")[-1].trimstart().trimend()
                        break
                    }
                }
            } #-- end of foreach ($line in $message)


            if (!($lcsObject.EnvironmentName)) {
                Write-Host "lcsObject.EnvironmentName is null - skipping"
                continue
            }
            if (!($lcsObject.EnvironmentId)) {
                if ($tmp = ($message.htmlbody | findstr EnvironmentId)) {
                    if ($lcsObject.EnvironmentId = $tmp.substring($tmp.indexof("EnvironmentId=")).split("=")[1].split("&")[0]) {
                        Write-Host "lcsObject.EnvironmentId inferred from message.htmlbody"
                    }
                    else {
                        Write-Host "lcsObject.EnvironmentId is null - skipping"
                        continue
                    }
                }
                else {
                    Write-Host "lcsObject.EnvironmentId is null - skipping"
                    continue
                }
            }

            if ($lcsObject.Status -like "*n progress*") {
                if ($lcsDeployStartTime.ContainsKey($lcsObject.EnvironmentName)) {
                    $lcsDeployStartTime.remove($lcsObject.EnvironmentName)
                }
                $lcsDeployStartTime.add($lcsObject.EnvironmentName, $message.senton)
                $lcsObject.StartTime = $message.senton.toUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
                $lcsObject.ElapsedTime = 0
                $lcsObject.goodDeployment = "In progress"
            }
            else {
                if ($lcsDeployStartTime.ContainsKey($lcsObject.EnvironmentName)) {
                    $lcsObject.StartTime = $lcsDeployStartTime.$($lcsObject.EnvironmentName).toUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
                    $lcsObject.FinishTime = $message.senton.toUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
                    $lcsObject.ElapsedTime = (New-TimeSpan -Start $lcsObject.startTime -End $lcsObject.finishTime).TotalMinutes
                    $lcsObject.goodDeployment = "Y"
                    $lcsDeployStartTime.remove($lcsObject.EnvironmentName)
                }
                else {
                    $lcsObject.StartTime = $message.senton.toUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
                    $lcsObject.FinishTime = $message.senton.toUniversalTime().toString("MM/dd/yyyy HH:mm:ss")
                    $lcsObject.goodDeployment = "N"
                    $lcsObject.ElapsedTime = (New-TimeSpan -Start $lcsObject.startTime -End $lcsObject.finishTime).TotalMinutes
                }
            }

            if (!($lcsObject.Update) -and !($lcsObject.Status)) {
                $lcsObject.Status = "Unknown"
            }
            if (!($lcsObject.Operation)) {
                $lcsObject.Operation = "Deployment"
            }

            $lcsObject.EnvironmentId

            $lcsObject.lcsKey = $lcsObject.EnvironmentId + $lcsObject.StartTime.ToString("yyyyMMdd_HHmm_ss")

            $data += @"
{"delete": {"_index": "$strElasticSearchIndex","_type": "_doc","_id": "$($lcsObject.lcsKey)"}}
{"create": {"_index": "$strElasticSearchIndex","_type": "_doc","_id": "$($lcsObject.lcsKey)"}}
{"lcsKey": "$($lcsObject.lcsKey)","StartTime": "$($lcsObject.StartTime)","FinishTime": "$($lcsObject.FinishTime)","ElapsedTime": "$($lcsObject.ElapsedTime)","CompanyName": "$($lcsObject.CompanyName)","ProjectId": "$($lcsObject.ProjectId)","Environment": "$($lcsObject.Environment)","EnvironmentName": "$($lcsObject.EnvironmentName)","EnvironmentId": "$($lcsObject.EnvironmentId)","Update": "$($lcsObject.Update)","Operation": "$($lcsObject.Operation)","Status": "$($lcsObject.Status)","GoodDeployment": "$($lcsObject.GoodDeployment)"}

"@
            $null = $lcsInfoTable.Add($lcsObject)
        } # end of foreach ($message in $messages)


        <#         foreach ($inProgressStr in "In progress", "Package rollback in progress", "Preparing") {
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
        } #>

        #    $lcsInfoTable | `
        #        Select-Object lcsKey, ProjectId, Environment, EnvironmentName, Update, Status, StartTime, FinishTime, ElapsedTime, goodDeployment | `
        #        Format-Table

        if ($data) {
            Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $data -ContentType "application/json"
            $data = ""
        }
    }

    $lcsInfoTable | ConvertTo-Csv -NoTypeInformation | Out-File ".\lcsInfoTable.csv"
}


main