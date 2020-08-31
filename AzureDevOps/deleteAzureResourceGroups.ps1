function sleepIfNeeded {
	while ($true) {
		$sleep = $false
		$psTasks = Get-WmiObject Win32_Process -Filter "name = 'powershell.exe'" | Where-Object {$_.commandline -like "*_deleteAzureResourceGroup.ps1*"}
		if ($psTasks.count) {
			$seconds = $psTasks.count * 10
			"sleep $seconds ..."
			Start-Sleep $seconds
		}
		else {
			break
		}
	}
}


$subscription = "_CompanyNameHere_ Developer 11"
# $subscription = "_CompanyNameHere_ DevOps Validation"

$tmp = az login
$tmp = az account set --subscription $subscription

sleepIfNeeded

for ($try = 0 ; $try -lt 10 ; $try++) {
	foreach ($resourceGroupName in ((az group list --subscription $subscription | ConvertFrom-Json) | Where-Object { $_.name -like "wus2-d11*" }).name) {
		if (az group show --name $resourceGroupName --subscription $subscription) {
			Write-Host "Resource Group $resourceGroupName exists - deleting..."
			$tmp = Get-Random -minimum 10000 -maximum 99999
			$filename = $ENV:TMP + "\$($tmp)_deleteAzureResourceGroup.ps1"
			$body = @"
az.cmd account set --subscription "$($subscription)" --verbose
az.cmd group delete --name "$($resourceGroupName)" --subscription "$($subscription)" --yes --verbose
"@

			$body | Out-File $filename -encoding ascii

			Start-Process powershell.exe -ArgumentList "-file $($filename)" -WindowStyle Hidden
			sleep 5
		}
		else {
			Write-Host "No Resource Group $resourceGroupName exists - no need to delete."
		}
	}
	sleepIfNeeded
}
