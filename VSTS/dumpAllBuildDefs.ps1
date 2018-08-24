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
	
	$nul=LoadTFAPI
	while (1) {
		getTheBuilds
		sleep 20
		cls
	}
	exit 0
	
}




function getTheBuilds {
		
	if ($env:strTFSinstance) {
		$tfsURL = $env:strTFSinstance
	} else {
		$tfsURL = "http://tfs2012.dev.tech.local:8080/tfs/fticollection"
	}
	
	# -- set some defaults
	
	$projects =	"Ringtail"
	
	# -- connect to the TFS build service
	
	$tpc = [Microsoft.TeamFoundation.Client.TfsTeamProjectCollectionFactory]::GetTeamProjectCollection($tfsURL)
#	$tfs = [Microsoft.TeamFoundation.Client.TeamFoundationServerFactory]::GetServer($tfsURL)
	$buildService = $tpc.GetService([Microsoft.TeamFoundation.Build.Client.IBuildServer])
	
	
	# -- loop thru our projects...
	
	foreach ($project in $projects) {
	
		# -- loop thru all build defs in the project
	
		foreach ($buildDef in ($buildService.QueryBuildDefinitions("$project").Name | sort)) {
				
			# -- Query the builds for this buildDef
			#
			#	for this specified project
			#	for this specified build def
			#	finished within the last 3 days
			#	sorted in reverse so most recent is examined first
			
			tfpt builddefinition /dump /collection:"$($tfsURL)" "$($projects)\$($buildDef)"
			
		}
	}
}
		
		


function LoadTFAPI { 

	. (Join-Path -Path $PSScriptRoot -ChildPath 'loadTfsAssemlies.ps1')

}

main
