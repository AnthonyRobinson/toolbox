<#

	.SYNOPSIS
		A brief description of the function or script. This keyword can be used only once in each topic.

	.DESCRIPTION
		A detailed description of the function or script. This keyword can be used only once in each topic.

	.PARAMETER  <Parameter-Name>
		The Parameter keywords can appear in any order in the comment block, but the function or script syntax determines the order in which the parameters (and their descriptions) appear in help topic. To change the order, change the syntax.

		You can also specify a parameter description by placing a comment in the function or script syntax immediately before the parameter variable name. If you use both a syntax comment and a Parameter keyword, the description associated with the Parameter keyword is used, and the syntax comment is ignored.

	.EXAMPLE
		A sample command that uses the function or script, optionally followed by sample output and a description. Repeat this keyword for each example.

	.INPUTS
		The Microsoft .NET Framework types of objects that can be piped to the function or script. You can also include a description of the input objects.

	.OUTPUTS
		The .NET Framework type of the objects that the cmdlet returns. You can also include a description of the returned objects.

	.NOTES
		Additional information about the function or script.

	.LINK
		The name of a related topic. The value appears on the line below the ".LINK" keyword and must be preceded by a comment symbol # or included in the comment block.

#>

function main {
	
	if (!($personalAccessToken = $ENV:PAT)) {
		write-warning "Personal Authentication Token or OAuth System_AccessToken needs to be set in the environment"
	} elseif (!($OAuthToken = $ENV:System_AccessToken)) {
		write-warning "Personal Authentication Token or OAuth System_AccessToken needs to be set in the environment"
	} else {
		write-error "Personal Authentication Token or OAuth System_AccessToken needs to be set in the environment"
	}
	$headers				= @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($personalAccessToken)")) } 
	$collection				= "https://microsoft.vsrm.visualstudio.com"
	$projectName			= "apps"
	$projectUrl				= $collection + "/" + $projectName
	$backupFolder			= "releaseDefBackup"
	
	if (!(test-path $backupFolder)) {
		mkdir $backupFolder
	}
	
	$releaseIds	= (Invoke-RestMethod -Uri "$projectUrl/_apis/release/definitions" -Headers $headers).value.id
	
	foreach ($releaseId in $releaseIds) {
		$release = Invoke-RestMethod -Uri "$projectUrl/_apis/release/definitions/$($releaseId)" -ContentType "application/json" -Headers $headers
		write-Host "*****" $($release.name) "*****"
		$release | convertto-json -depth 100 | out-file "ReleaseDefBackup\$($releaseId) $($release.name).json" -encoding ascii
	}
}

main