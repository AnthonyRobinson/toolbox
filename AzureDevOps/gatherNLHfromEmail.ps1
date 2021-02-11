class nlhRecord {
    [string]$noLongerHereKey
    [DateTime]$noLongerHereDateTime
    [string]$Requestor
    [string]$EmployeeID
    [string]$EmployeeName
    [string]$RequestingSupervisor
    [string]$EffectiveDate
    [string]$Location
    [string]$Department
    [string]$PayGroup
    [string]$PersonType
    [string]$KeepCOmputerDatafor30days
    [string]$DoesEmployeehaveBadge
    [string]$Keeprecordedcalls
    [string]$Howlongtokeepcalls
    [string]$KeepEmail
    [string]$HowLongtokeepemails
    [string]$ReRouteEmail
    [string]$ExtensionOptions
    [string]$ReReouteExtensionto
    [string]$NeedCallTag
    [string]$CubicleNumber
    [string]$ComcastDisconnect
    [string]$Notes
}


function main {

    $strElasticSearchIndex = "nolongerhere"
    $strElasticSearchServer = "LT-14763.corp.sanmar.com"

    $nlhInfoTable = [System.Collections.ArrayList]@()

    $data = ""

    $daysback = -300

    Write-Host "Querying $daysback days back..."

    Add-Type -assembly "Microsoft.Office.Interop.Outlook" | Out-Null
    $olFolders = "Microsoft.Office.Interop.Outlook.olDefaultFolders" -as [type]
    $outlook = New-Object -comobject outlook.application
    $namespace = $outlook.GetNameSpace("MAPI")
    $folder = $namespace.getDefaultFolder($olFolders::olFolderInBox)

    $messages = $folder.items | Where-Object { $_.Subject -like "No Longer Here*" -and $_.SentOn -gt (Get-Date).AddDays($daysBack) } | Sort-Object -Property SentOn

    foreach ($message in $messages) {

        $nlhObject.noLongerHereDateTime = $message.senton.toUniversalTime().toString("MM/dd/yyyy HH:mm:ss")

        $nlhObject = New-Object nlhRecord

        foreach ($line in ($message.body.split("`n"))) {

            switch -wildcard ($line) {

                <#
                '*Requestor:*' {
                    $nlhObject.Requestor = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                #>

                '*Employee ID:*' {
                    $nlhObject.EmployeeID = $line.split(":")[-1].trimstart().trimend()
                    break
                }

                <#
                '*Employee Name:*' {
                    $nlhObject.EmployeeName = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Requesting Supervisor:*' {
                    $nlhObject.RequestingSupervisor = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Effective Date:*' {
                    $nlhObject.EffectiveDate = $line.replace("Effective Date: and Time: ", "").trimstart().trimend()
                    break
                }
                '*Location:*' {
                    $nlhObject.Location = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Department:*' {
                    $nlhObject.Department = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Pay Group:*' {
                    $nlhObject.PayGroup = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Person Type:*' {
                    $nlhObject.PersonType = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Keep COmputer Data for 30 days:*' {
                    $nlhObject.KeepCOmputerDatafor30days = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Does Employee have Badge:*' {
                    $nlhObject.DoesEmployeehaveBadge = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Keep recorded calls:*' {
                    $nlhObject.Keeprecordedcalls = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*How long to keep calls:*' {
                    $nlhObject.Howlongtokeepcalls = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Keep Email:*' {
                    $nlhObject.KeepEmail = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*How Long to keep emails:*' {
                    $nlhObject.HowLongtokeepemails = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Re-Route Email:*' {
                    $nlhObject.ReRouteEmail = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Extension Options:*' {
                    $nlhObject.ExtensionOptions = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Re-Reoute Extension to:*' {
                    $nlhObject.ReReouteExtensionto = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Need Call Tag:*' {
                    $nlhObject.NeedCallTag = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Cubicle Number:*' {
                    $nlhObject.CubicleNumber = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Comcast Disconnect:*' {
                    $nlhObject.ComcastDisconnect = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                '*Notes:*' {
                    $nlhObject.Notes = $line.split(":")[-1].trimstart().trimend()
                    break
                }
                #>
            }
        }

        $nlhObject.noLongerHereKey = $nlhObject.noLongerHereDateTime.ToString("yyyyMMdd_HHmm_ss") + $nlhObject.EmployeeID

        $data += @"
{"delete": {"_index": "$strElasticSearchIndex","_type": "_doc","_id": "$($nlhObject.noLongerHereKey)"}}
{"create": {"_index": "$strElasticSearchIndex","_type": "_doc","_id": "$($nlhObject.noLongerHereKey)"}}
{"noLongerHereKey":"$($nlhObject.noLongerHereKey)","DateTime":"$($nlhObject.noLongerHereDateTime)","Requestor":"$($nlhObject.Requestor)","EmployeeID":"$($nlhObject.EmployeeID)","EmployeeName":"$($nlhObject.EmployeeName)","RequestingSupervisor":"$($nlhObject.RequestingSupervisor)","EffectiveDate":"$($nlhObject.EffectiveDate)","Location":"$($nlhObject.Location)","Department":"$($nlhObject.Department)","PayGroup":"$($nlhObject.PayGroup)","PersonType":"$($nlhObject.PersonType)","KeepCOmputerDatafor30days":"$($nlhObject.KeepCOmputerDatafor30days)","DoesEmployeehaveBadge":"$($nlhObject.DoesEmployeehaveBadge)","Keeprecordedcalls":"$($nlhObject.Keeprecordedcalls)","Howlongtokeepcalls":"$($nlhObject.Howlongtokeepcalls)","KeepEmail":"$($nlhObject.KeepEmail)","HowLongtokeepemails":"$($nlhObject.HowLongtokeepemails)","ReRouteEmail":"$($nlhObject.ReRouteEmail)","ExtensionOptions":"$($nlhObject.ExtensionOptions)","ReReouteExtensionto":"$($nlhObject.ReReouteExtensionto)","NeedCallTag":"$($nlhObject.NeedCallTag)","CubicleNumber":"$($nlhObject.CubicleNumber)","ComcastDisconnect":"$($nlhObject.ComcastDisconnect)","Notes":"$($nlhObject.Notes)"}

"@
        $null = $nlhInfoTable.Add($nlhObject)


        if ($data) {
            try {
                Invoke-RestMethod -Uri http://$($strElasticSearchServer):9200/_bulk?pretty -Method POST -Body $data -ContentType "application/json"
            }
            catch {
                $data
            }
            $data = ""
        }
    }

    $nlhInfoTable | ConvertTo-Csv -NoTypeInformation | Out-File ".\nlhInfoTable.csv"
}


main