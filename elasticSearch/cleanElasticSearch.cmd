	@echo off
	
	setlocal ENABLEDELAYEDEXPANSION ENABLEEXTENSIONS 
	
	call :doInit %*
	
	if "%intError%" == "0" (
		call :doCleanLogs
		call :doCleanMarvelIndexes
	)
	
	@echo %~nx0 !date! !time! Exiting with errorcode: %intError%
	
	exit /b %intError%

	
@REM --------------------------------------------------------------------------------------------------------------------------
	
	
:doInit
	@echo %~nx0 %0 !date! !time!
	
	set intError=0
	
	if exist %~dp0..\curator\curator.exe (
		set strCuratorDir=%~dp0..\curator
	) else (
		set intError += 1
		@echo %~nx0 %0 !date! !time! ERROR: Can't find %~dp0..\curator\curator.exe
		exit /b 1
	)
	set intDaysAgeMarvel=30
	set intDaysAgeLogs=30
	set strPowerShellFileTmp=%TMP%\%RANDOM%.ps1
	
	exit /b %intError%


:doCleanLogs
	@echo %~nx0 %0 !date! !time!
	
	for %%a in (
		"sep550devhpc001"
		"sep550devhpc002"
		"sep550devhpc003"
		"sep550devhpc004"
	) do (
		@echo %~nx0 %0 !date! !time! %%~a
		dir \\%%~a\c$\es_logs
	)
	
	setlocal DISABLEDELAYEDEXPANSION
	
		(
			@echo $EShosts = "sep550devhpc001", `
			@echo            "sep550devhpc002", `
			@echo            "sep550devhpc003", `
			@echo            "sep550devhpc004"

			@echo foreach ^($EShost in $EShosts^) {
			@echo 	$limit = ^(Get-Date^).AddDays^(-%intDaysAgeLogs%^)
			@echo 	$path  = "\\$($EShost)\c$\es_logs"
			@echo 	Get-ChildItem -Path $path -include *_es.log.* -Recurse -Force ^| Where-Object { !$_.PSIsContainer -and $_.LastwriteTime  -lt $limit } ^| Remove-Item -Force 
			@echo }
		) > %strPowerShellFileTmp%
		
		type %strPowerShellFileTmp%
		
		set strPowershellCmd=powershell -ExecutionPolicy bypass %strPowerShellFileTmp%
		
		@echo %~nx0 %0 %strPowershellCmd%
		
		%strPowershellCmd%
	
	endlocal
	
	exit /b %intError%
	
	
:doCleanMarvelIndexes
	@echo %~nx0 %0 !date! !time!
	
	set strCuratorCmd=curator --host sep550devhpc001 delete indices --older-than %intDaysAgeMarvel% --time-unit days --timestring "%%Y.%%m.%%d" --index .marvel-

	@echo %~nx0 %0 %strCuratorCmd%
	
	pushd %strCuratorDir%
		%strCuratorCmd%
	popd
	
	exit /b %intError%


