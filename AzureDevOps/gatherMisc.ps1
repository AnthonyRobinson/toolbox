while ($true) {
	$Pos = [System.Windows.Forms.Cursor]::Position
	write-host $Pos.X, $Pos.Y
	
    $xDiff = Get-Random -minimum -10 -maximum 10
    $yDiff = Get-Random -minimum -10 -maximum 10
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point((($Pos.X + $xDiff) , ($Pos.Y + $yDiff)))
    sleep 30
}
