# Experiment Annotator - entry point. Run via Start-Annotator.bat (double-click).
$ErrorActionPreference = 'Stop'
$Script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $Script:AppRoot 'Clock.ps1')
. (Join-Path $Script:AppRoot 'Protocol.ps1')
. (Join-Path $Script:AppRoot 'Validation.ps1')
. (Join-Path $Script:AppRoot 'Logger.ps1')
. (Join-Path $Script:AppRoot 'Gui.ps1')

if ($env:ANNOTATOR_NOGUI -ne '1') { Start-Gui }
