	@echo off

	@REM http://air.ghost.io/kibana-4-export-and-import-visualizations-and-dashboards/
	
	set ESDump=C:\Users\v-antrob\AppData\Roaming\npm\node_modules\elasticdump\bin\elasticdump
	set strBackupDir=z:\
	

	for %%a in (
buildagents
buildagentstats
buildinfo
buildsrunning
critical
timestamp
.kibana
	) do (
		@echo %%a
		for %%b in ( mapping data analyzer) do (
			node.exe %ESDump% --input .\%%a_%%b.json --output=http://localhost:9200/%%a --type=%%b --limit=2000
		)
	)

	exit /b 0