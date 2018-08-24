	@echo off
	
	@REM http://air.ghost.io/kibana-4-export-and-import-visualizations-and-dashboards/

	set ESDump=C:\Users\v-antrob\AppData\Roaming\npm\node_modules\elasticdump\bin\elasticdump
	set strBackupDir=elasticsearchBackup
	
	mkdir %strBackupDir%
	
	
	for /f "tokens=3" %%a in ('powershell "invoke-RestMethod -Uri http://std-5276466:9200/_cat/indices?v"') do (
		@echo %%a
		if not "%%a" == "index" (
			for %%b in (data mapping analyzer) do (
				if exist %strBackupDir%\%%a_%%b.json del %strBackupDir%\%%a_%%b.json
				node %ESDump% --input=http://localhost:9200/%%a --output=.\%strBackupDir%\%%a_%%b.json --type=%%b --limit=2000
			)
		)
	)

	exit /b 0
