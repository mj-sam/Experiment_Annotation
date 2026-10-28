# Gui.ps1 - WinForms interface. Contains no protocol rules: it asks $Script:App.Session.
# NOTE: keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).

$Script:App = @{ Session = $null; Files = $null; Locked = $false; Protocol = $null; Suppress = $false; ProtocolPaths = @{} }

$CH_CHECK = [string][char]0x2713
$CH_ARROW = [string][char]0x2192
$CH_DASH  = [string][char]0x2014
$CH_DOT   = [string][char]0x25CF

function RGB($r, $g, $b) { [System.Drawing.Color]::FromArgb($r, $g, $b) }
$Pal = @{
    Done = (RGB 46 160 67);   DoneText = (RGB 255 255 255)
    Next = (RGB 31 111 235);  Run = (RGB 214 40 40)
    Todo = (RGB 225 228 232); TodoText = (RGB 100 106 115)
    Panel = (RGB 246 247 249); Bad = (RGB 200 30 30); Ok = (RGB 30 130 50)
}
function Font($size, $bold = $false, $family = 'Segoe UI') {
    $style = [System.Drawing.FontStyle]::Regular
    if ($bold) { $style = [System.Drawing.FontStyle]::Bold }
    New-Object System.Drawing.Font($family, [single]$size, $style)
}
function Msg($text, $title, $buttons = 'OK', $icon = 'Information', $default = 'Button1') {
    [System.Windows.Forms.MessageBox]::Show($text, $title, $buttons, $icon, $default)
}
function New-Ctl($type, $props) {
    $c = New-Object $type
    foreach ($k in $props.Keys) { $c.$k = $props[$k] }
    return $c
}

# ----------------------------------------------------------------------------- actions
function Add-LogLine($ev) {
    $a = $Script:App
    switch ($ev.event) {
        'START'         { $line = '{0} {1} {2} STARTED' -f $ev.system_time, $CH_DASH, $ev.stage }
        'FINISH'        { $line = '{0} {1} {2} FINISHED' -f $ev.system_time, $CH_DASH, $ev.stage }
        'CORRECTION'    { $line = 'EVENT {0} {1} CORRECTION {1} {2}   [{3}]' -f $ev.event_number, $CH_DASH, $ev.note, $ev.system_time }
        'SESSION_START' { $line = '{0} {1} Session started' -f $ev.system_time, $CH_DASH }
        default         { $line = '{0} {1} {2} {3}' -f $ev.system_time, $CH_DASH, $ev.event, $ev.note }
    }
    $a.Log.AppendText(('#{0,-3} {1}' -f $ev.event_number, $line) + "`r`n")
}

function Save-OrWarn($ev) {
    $a = $Script:App
    try { Save-Event $a.Files $a.Session $ev }
    catch {
        Msg ("COULD NOT WRITE THE ANNOTATION FILE!`n`n$($_.Exception.Message)`n`nThe event is kept in memory (see log). Note the time manually and check the disk/folder.") 'SAVE ERROR' 'OK' 'Error' | Out-Null
    }
}

function Invoke-Action($stamp) {
    $a = $Script:App
    if ($a.Locked -or -not $a.Session) { return }
    $a.Locked = $true
    $a.ActionBtn.Enabled = $false             # block double-clicks immediately
    try {
        $ev = $a.Session.Press($stamp)        # 1. timestamp was captured by the caller before this
    } catch {
        if ($_.Exception.Message -notlike 'DUPLICATE*') { Msg $_.Exception.Message 'Not allowed' 'OK' 'Warning' | Out-Null }
        $a.Locked = $false; Update-View; return
    }
    Save-OrWarn $ev                           # 2. write to disk
    Add-LogLine $ev                           # 3. update GUI
    Update-View
    $a.UnlockTimer.Start()
}

function Get-NextSessionId([string]$sid) {
    if ($sid -match '^(.*?)(\d+)$') {
        $num = ([int64]$Matches[2] + 1).ToString().PadLeft($Matches[2].Length, '0')
        return $Matches[1] + $num
    }
    return $sid
}

# Back to the setup screen. Participant/session IDs are kept (session ID optionally incremented).
function Return-ToSetup([bool]$nextSession) {
    $a = $Script:App
    $sid = $a.SidBox.Text
    if ($a.Session) { $sid = $a.Session.SessionId; $a.PidBox.Text = $a.Session.ParticipantId }
    if ($nextSession) { $sid = Get-NextSessionId $sid }
    $a.SidBox.Text = $sid
    $a.Session = $null; $a.Files = $null; $a.Locked = $false
    $a.Log.Clear()
    Update-View
}

# One button: "Start Session" when idle, "New Session" once the previous one has finished.
function Invoke-StartOrNew {
    $a = $Script:App
    if ($a.Session) { Return-ToSetup $true } else { Invoke-StartSession }
}

function Invoke-StartSession {
    $stamp = Get-Stamp
    $a = $Script:App
    $pid_ = $a.PidBox.Text.Trim(); $sid = $a.SidBox.Text.Trim()
    if ($pid_ -notmatch '^[A-Za-z0-9_-]{1,32}$' -or $sid -notmatch '^[A-Za-z0-9_-]{1,32}$') {
        Msg "Participant ID and Session ID are required.`nUse only letters, digits, '-' and '_' (e.g. P001 and S01)." 'Check IDs' 'OK' 'Warning' | Out-Null
        return
    }
    $files = New-LogFiles (Join-Path $Script:AppRoot $Script:OutputDirName) $pid_ $sid
    $a.Files = $files
    $a.Session = New-Session $pid_ $sid $a.Protocol
    $ev = $a.Session.BeginSession($stamp)
    Save-OrWarn $ev
    $a.Log.Clear()
    Add-LogLine $ev
    Update-View
}

function Invoke-Correct {
    $a = $Script:App
    if (-not $a.Session -or $a.Session.Ended) { return }
    $valid = @($a.Session.ValidEvents())
    if ($valid.Count -eq 0) { Msg 'There is no annotation to correct.' 'Correct' | Out-Null; return }
    $t = $valid[$valid.Count - 1]
    $q = "Mark the last annotation as ACCIDENTAL?`n`nEvent {0}: {1} {2} at {3}`n`nThe original entry stays in the file; a CORRECTION entry is added." -f $t.event_number, $t.stage, $t.event, $t.system_time
    if ((Msg $q 'Correct last annotation' 'YesNo' 'Question' 'Button2') -ne 'Yes') { return }
    $stamp = Get-Stamp
    $ev = $a.Session.CorrectLast($stamp)
    Save-OrWarn $ev
    Add-LogLine $ev
    $a.Locked = $false
    Update-View
}

function Invoke-EndSession {
    $a = $Script:App
    if (-not $a.Session -or $a.Session.Ended) { return }
    if ($a.Session.Phase() -ne 'completed') {
        $q = "The experiment is NOT complete.`n`nEnd the session anyway? Missing events will be flagged in the summary."
        if ((Msg $q 'End incomplete session' 'YesNo' 'Warning' 'Button2') -ne 'Yes') { return }
    }
    $stamp = Get-Stamp
    $ev = $a.Session.EndSession($stamp, 'SESSION_END', 'session ended by operator')
    Save-OrWarn $ev
    Add-LogLine $ev
    Update-View
}

function Invoke-Reset {
    $a = $Script:App
    if ($a.Session -and -not $a.Session.Ended -and $a.Session.Phase() -ne 'completed') {
        $q = "RESET the experiment?`n`nThe current session will be closed (its files are kept) and you will return to the start screen."
        if ((Msg $q 'Reset experiment' 'YesNo' 'Warning' 'Button2') -ne 'Yes') { return }
        $stamp = Get-Stamp
        $ev = $a.Session.EndSession($stamp, 'SESSION_RESET', 'experiment reset by operator')
        Save-OrWarn $ev
    }
    Return-ToSetup ($a.Session.Phase() -eq 'completed' -or $a.Session.EndKind -eq 'SESSION_END')
}

# ----------------------------------------------------------------------------- protocol loading
function Build-Strip {
    $a = $Script:App
    $stages = $a.Protocol.Stages
    $a.Strip.SuspendLayout()
    $a.Strip.Controls.Clear()
    $a.StageLabels = @()
    for ($i = 0; $i -lt $stages.Count; $i++) {
        $l = New-Ctl System.Windows.Forms.Label @{ AutoSize = $true; Padding = '8,6,8,6'; Margin = '0,4,0,4'; Text = $stages[$i] }
        $a.StageLabels += $l
        $a.Strip.Controls.Add($l)
        if ($i -lt $stages.Count - 1) {
            $a.Strip.Controls.Add((New-Ctl System.Windows.Forms.Label @{ AutoSize = $true; Text = $CH_ARROW; Padding = '2,8,2,0'; ForeColor = $Pal.TodoText }))
        }
    }
    $a.Strip.ResumeLayout()
}

function Set-Protocol($protocol, [string]$comboText) {
    $a = $Script:App
    $a.Protocol = $protocol
    $a.Suppress = $true
    if ($comboText) {
        if ($a.ProtoCombo.Items.IndexOf($comboText) -lt 0) { [void]$a.ProtoCombo.Items.Add($comboText) }
        $a.ProtoCombo.SelectedItem = $comboText
    }
    $a.Suppress = $false
    $a.ProtoInfo.Text = '{0} stages' -f $protocol.Stages.Count
    Build-Strip
    Update-View
}

# Load from a file/inline JSON. On failure the current protocol stays active.
function Load-ProtocolFrom([string]$source, [string]$comboText) {
    try { $p = Read-Protocol $source }
    catch {
        Msg ("Could not load the protocol:`n`n" + $_.Exception.Message) 'Protocol error' 'OK' 'Warning' | Out-Null
        return $false
    }
    if (-not $comboText) { $comboText = $p.Name }
    $a = $Script:App
    $a.ProtocolPaths[$comboText] = $source
    Set-Protocol $p $comboText
    return $true
}

function Invoke-BrowseProtocol {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Load experiment protocol'
    $dlg.Filter = 'Protocol files (*.json;*.txt)|*.json;*.txt|All files (*.*)|*.*'
    $dlg.InitialDirectory = Join-Path $Script:AppRoot $Script:ProtocolDirName
    if ($dlg.ShowDialog() -eq 'OK') {
        [void](Load-ProtocolFrom $dlg.FileName ([System.IO.Path]::GetFileName($dlg.FileName)))
    }
}

function Open-DataFolder {
    $a = $Script:App
    if ($a.Files -and (Test-Path -LiteralPath $a.Files.Csv)) {
        Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $a.Files.Csv)
    } else {
        $d = Join-Path $Script:AppRoot $Script:OutputDirName
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d) }
        Start-Process explorer.exe -ArgumentList ('"{0}"' -f $d)
    }
}

# ----------------------------------------------------------------------------- view
function Set-Stage($label, $text, $back, $fore, $bold) {
    $label.Text = $text; $label.BackColor = $back; $label.ForeColor = $fore
    $label.Font = (Font $(if ($bold) { 15 } else { 12 }) $bold)
}

function Show-Summary($session) {
    $a = $Script:App
    $r = Get-SessionReport $session
    $rt = $a.Summary
    $rt.Clear()
    function W($text, $color, $bold = $false) {
        $rt.SelectionStart = $rt.TextLength
        $rt.SelectionColor = $color
        $rt.SelectionFont = (Font 12 $bold 'Consolas')
        $rt.AppendText($text + "`r`n")
    }
    $black = [System.Drawing.Color]::Black
    if ($session.Phase() -eq 'completed') {
        $rt.SelectionFont = (Font 22 $true); $rt.SelectionColor = $Pal.Ok
        $rt.AppendText("Experiment Completed`r`n")
    } else {
        $rt.SelectionFont = (Font 22 $true); $rt.SelectionColor = $Pal.Bad
        $rt.AppendText("Session ended - INCOMPLETE`r`n")
    }
    W ('Participant {0}    Session {1}    Protocol: {2}' -f $session.ParticipantId, $session.SessionId, $session.ProtocolName) $black
    W ('Total session duration: {0}' -f $r.TotalHms) $black $true
    W '' $black
    W ('{0,-14} {1,-13} {2,-13} {3,-13} {4}' -f 'Stage', 'Start', 'Finish', 'Duration', 'Check') $black $true
    foreach ($row in $r.Rows) {
        $chk = 'OK'; $col = $Pal.Ok
        if (-not $row.Ok) { $chk = 'PROBLEM: ' + ($row.Issues -join '; '); $col = $Pal.Bad }
        W ('{0,-14} {1,-13} {2,-13} {3,-13} {4}' -f $row.Stage, $row.StartTime, $row.FinishTime, $row.DurationHms, $chk) $col (-not $row.Ok)
    }
    W '' $black
    if ($r.AllOk) { W 'Verification: every stage has both START and FINISH, in order.' $Pal.Ok $true }
    else { W 'Verification: PROBLEMS FOUND - see the red lines above.' $Pal.Bad $true }
    if ($r.Corrections -gt 0) { W ('{0} correction(s) recorded (see log file).' -f $r.Corrections) $black }
    W '' $black
    W ('Files: ' + $a.Files.Csv) $black
    W ('       ' + $a.Files.Json) $black
    $rt.SelectionStart = 0
}

function Update-View {
    $a = $Script:App
    $s = $a.Session
    $idle = ($null -eq $s)
    $stages = $a.Protocol.Stages
    if (-not $idle) { $stages = $s.Stages }

    $phase = 'idle'; $n = 0
    if (-not $idle) { $phase = $s.Phase(); $n = @($s.ValidEvents()).Count }
    $finished = ($phase -eq 'completed' -or $phase -eq 'ended')

    $a.PidBox.Enabled = $idle; $a.SidBox.Enabled = $idle
    $a.ProtoCombo.Enabled = $idle; $a.ProtoBrowse.Enabled = $idle
    $a.StartBtn.Enabled = ($idle -or $finished)
    if ($finished) { $a.StartBtn.Text = 'New Session' } else { $a.StartBtn.Text = 'Start Session' }
    $a.CorrectBtn.Enabled = $false; $a.EndBtn.Enabled = $false
    $a.ResetBtn.Enabled = ($phase -eq 'ready' -or $phase -eq 'running')
    $done = [int][math]::Floor($n / 2)

    # progress strip
    for ($i = 0; $i -lt $stages.Count; $i++) {
        $lbl = $a.StageLabels[$i]
        if ($phase -eq 'completed' -or $i -lt $done) {
            Set-Stage $lbl ("$CH_CHECK " + $stages[$i]) $Pal.Done $Pal.DoneText $false
        } elseif ($i -eq $done -and $phase -eq 'running') {
            Set-Stage $lbl ("$CH_DOT " + $stages[$i]) $Pal.Run ([System.Drawing.Color]::White) $true
        } elseif ($i -eq $done -and $phase -eq 'ready') {
            Set-Stage $lbl $stages[$i] $Pal.Next ([System.Drawing.Color]::White) $true
        } else {
            Set-Stage $lbl $stages[$i] $Pal.Todo $Pal.TodoText $false
        }
    }

    $showSummary = ($phase -eq 'completed' -or $phase -eq 'ended')
    $a.Main.Visible = -not $showSummary
    $a.Summary.Visible = $showSummary

    switch ($phase) {
        'idle' {
            $a.SessionStatus.Text = 'Session: not started'
            $a.StageName.Text = 'Not started'; $a.StageStatus.Text = 'Enter Participant ID and Session ID, then press Start Session'
            $a.StageStatus.ForeColor = $Pal.TodoText
            $a.ActionBtn.Text = 'Start Session first'; $a.ActionBtn.BackColor = $Pal.Todo; $a.ActionBtn.Enabled = $false
        }
        'ready' {
            $name = $stages[$done]
            $a.SessionStatus.Text = 'Session: IN PROGRESS'
            $a.StageName.Text = $name; $a.StageStatus.Text = 'Ready to start'; $a.StageStatus.ForeColor = $Pal.Next
            $a.ActionBtn.Text = "Start $name"; $a.ActionBtn.BackColor = $Pal.Done
            $a.ActionBtn.Enabled = -not $a.Locked
            $a.CorrectBtn.Enabled = ($n -gt 0); $a.EndBtn.Enabled = $true
        }
        'running' {
            $name = $stages[$done]
            $a.SessionStatus.Text = 'Session: IN PROGRESS'
            $a.StageName.Text = $name; $a.StageStatus.Text = "$CH_DOT RUNNING"; $a.StageStatus.ForeColor = $Pal.Run
            $a.ActionBtn.Text = "Finish $name"; $a.ActionBtn.BackColor = $Pal.Run
            $a.ActionBtn.Enabled = -not $a.Locked
            $a.CorrectBtn.Enabled = $true; $a.EndBtn.Enabled = $true
        }
        'completed' {
            $a.SessionStatus.Text = 'Session: COMPLETED'
            $a.CorrectBtn.Enabled = $true
            Show-Summary $s
        }
        'ended' {
            $a.SessionStatus.Text = 'Session: ENDED (incomplete)'
            Show-Summary $s
        }
    }
    $a.ActionBtn.ForeColor = [System.Drawing.Color]::White
}

function Update-Clocks {
    $a = $Script:App
    $now = [PreciseClock]::Now()
    $t = $now.ToString('ddd yyyy-MM-dd', $Script:Inv) + "`r`n" + $now.ToString('HH:mm:ss.fff', $Script:Inv) + '  (UTC' + $now.ToString('zzz', $Script:Inv) + ')'
    if ($a.Clock.Text -ne $t) { $a.Clock.Text = $t }

    $txt = '00:00:00.0'
    $s = $a.Session
    if ($s -and $s.Phase() -eq 'running') {
        $valid = @($s.ValidEvents())
        $startMono = [double]$valid[$valid.Count - 1].mono
        $txt = (Format-Hms ([PreciseClock]::MonoSeconds() - $startMono)).Substring(0, 10)
    }
    if ($a.StageTimer.Text -ne $txt) { $a.StageTimer.Text = $txt }
}

# ----------------------------------------------------------------------------- build
function Start-Gui {
    $a = $Script:App
    $form = New-Ctl System.Windows.Forms.Form @{
        Text = 'Experiment Annotator'; Size = (New-Object System.Drawing.Size(1280, 880))
        MinimumSize = (New-Object System.Drawing.Size(1000, 760)); StartPosition = 'CenterScreen'
        Font = (Font 11); BackColor = [System.Drawing.Color]::White
    }
    $root = New-Ctl System.Windows.Forms.TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 1; RowCount = 5 }
    foreach ($h in 140, 120) { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', $h))) }
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
    foreach ($h in 190, 60) { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', $h))) }
    $form.Controls.Add($root)

    # --- top bar
    $top = New-Ctl System.Windows.Forms.Panel @{ Dock = 'Fill'; BackColor = $Pal.Panel }
    $top.Controls.Add((New-Ctl System.Windows.Forms.Label @{ Text = 'Participant ID'; Location = '14,10'; AutoSize = $true }))
    $a.PidBox = New-Ctl System.Windows.Forms.TextBox @{ Location = '14,36'; Width = 150; Font = (Font 14); MaxLength = 32 }
    $top.Controls.Add((New-Ctl System.Windows.Forms.Label @{ Text = 'Session / Experiment ID'; Location = '184,10'; AutoSize = $true }))
    $a.SidBox = New-Ctl System.Windows.Forms.TextBox @{ Location = '184,36'; Width = 170; Font = (Font 14); MaxLength = 32 }
    $a.StartBtn = New-Ctl System.Windows.Forms.Button @{ Text = 'Start Session'; Location = '376,26'; Size = '160,50'; Font = (Font 13 $true); BackColor = $Pal.Next; ForeColor = [System.Drawing.Color]::White; FlatStyle = 'Flat' }
    $a.SessionStatus = New-Ctl System.Windows.Forms.Label @{ Text = 'Session: not started'; Location = '556,38'; AutoSize = $true; Font = (Font 13 $true) }
    $a.Clock = New-Ctl System.Windows.Forms.Label @{ Dock = 'Right'; Width = 330; TextAlign = 'MiddleRight'; Font = (Font 17 $true 'Consolas'); Padding = '0,0,12,0' }
    $top.Controls.Add((New-Ctl System.Windows.Forms.Label @{ Text = 'Protocol'; Location = '14,92'; AutoSize = $true }))
    $a.ProtoCombo = New-Ctl System.Windows.Forms.ComboBox @{ Location = '84,88'; Width = 270; DropDownStyle = 'DropDownList' }
    $a.ProtoBrowse = New-Ctl System.Windows.Forms.Button @{ Text = 'Load file...'; Location = '366,86'; Size = '110,32' }
    $a.ProtoInfo = New-Ctl System.Windows.Forms.Label @{ Text = ''; Location = '490,92'; AutoSize = $true; ForeColor = $Pal.TodoText }
    foreach ($c in $a.PidBox, $a.SidBox, $a.StartBtn, $a.SessionStatus, $a.Clock, $a.ProtoCombo, $a.ProtoBrowse, $a.ProtoInfo) { $top.Controls.Add($c) }
    $root.Controls.Add($top, 0, 0)

    # --- progress strip (rebuilt whenever a protocol is loaded)
    $a.Strip = New-Ctl System.Windows.Forms.FlowLayoutPanel @{ Dock = 'Fill'; Padding = '10,12,10,0'; WrapContents = $true }
    $root.Controls.Add($a.Strip, 0, 1)

    # --- centre: main controls / summary share one cell
    $centre = New-Ctl System.Windows.Forms.Panel @{ Dock = 'Fill'; Padding = '16,6,16,6' }
    $a.Main = New-Ctl System.Windows.Forms.TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 1; RowCount = 4 }
    foreach ($h in 64, 40, 84) { [void]$a.Main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', $h))) }
    [void]$a.Main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
    $a.StageName = New-Ctl System.Windows.Forms.Label @{ Dock = 'Fill'; TextAlign = 'MiddleCenter'; Font = (Font 32 $true) }
    $a.StageStatus = New-Ctl System.Windows.Forms.Label @{ Dock = 'Fill'; TextAlign = 'MiddleCenter'; Font = (Font 16 $true) }
    $a.StageTimer = New-Ctl System.Windows.Forms.Label @{ Dock = 'Fill'; TextAlign = 'MiddleCenter'; Font = (Font 46 $true 'Consolas'); Text = '00:00:00.0' }
    $a.ActionBtn = New-Ctl System.Windows.Forms.Button @{ Dock = 'Fill'; Font = (Font 30 $true); FlatStyle = 'Flat'; Margin = '60,6,60,6'; Enabled = $false }
    $a.Main.Controls.Add($a.StageName, 0, 0); $a.Main.Controls.Add($a.StageStatus, 0, 1)
    $a.Main.Controls.Add($a.StageTimer, 0, 2); $a.Main.Controls.Add($a.ActionBtn, 0, 3)
    $a.Summary = New-Ctl System.Windows.Forms.RichTextBox @{ Dock = 'Fill'; ReadOnly = $true; BorderStyle = 'None'; BackColor = $Pal.Panel; Visible = $false }
    $centre.Controls.Add($a.Summary); $centre.Controls.Add($a.Main)
    $root.Controls.Add($centre, 0, 2)

    # --- event log
    $logBox = New-Ctl System.Windows.Forms.GroupBox @{ Dock = 'Fill'; Text = 'Event log'; Padding = '8,4,8,8' }
    $a.Log = New-Ctl System.Windows.Forms.TextBox @{ Dock = 'Fill'; Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Font = (Font 11 $false 'Consolas'); BackColor = [System.Drawing.Color]::White }
    $logBox.Controls.Add($a.Log)
    $root.Controls.Add($logBox, 0, 3)

    # --- bottom bar
    $bar = New-Ctl System.Windows.Forms.FlowLayoutPanel @{ Dock = 'Fill'; Padding = '12,8,0,0' }
    $a.CorrectBtn = New-Ctl System.Windows.Forms.Button @{ Text = 'Correct last annotation'; Size = '230,40' }
    $a.ResetBtn = New-Ctl System.Windows.Forms.Button @{ Text = 'Reset experiment'; Size = '170,40' }
    $a.EndBtn = New-Ctl System.Windows.Forms.Button @{ Text = 'End session'; Size = '150,40' }
    $a.FolderBtn = New-Ctl System.Windows.Forms.Button @{ Text = 'Open data folder'; Size = '170,40' }
    foreach ($b in $a.CorrectBtn, $a.ResetBtn, $a.EndBtn, $a.FolderBtn) { $bar.Controls.Add($b) }
    $root.Controls.Add($bar, 0, 4)

    # --- timers
    $a.UnlockTimer = New-Object System.Windows.Forms.Timer
    $a.UnlockTimer.Interval = 700
    $a.UnlockTimer.Add_Tick({ $Script:App.UnlockTimer.Stop(); $Script:App.Locked = $false; Update-View })
    $a.ClockTimer = New-Object System.Windows.Forms.Timer
    $a.ClockTimer.Interval = 40
    $a.ClockTimer.Add_Tick({ Update-Clocks })

    # --- events (the timestamp is the FIRST statement of each action handler)
    $a.ActionBtn.Add_Click({ $stamp = Get-Stamp; Invoke-Action $stamp })
    $a.StartBtn.Add_Click({ Invoke-StartOrNew })
    $a.ProtoBrowse.Add_Click({ Invoke-BrowseProtocol })
    $a.ProtoCombo.Add_SelectedIndexChanged({
        $a2 = $Script:App
        if ($a2.Suppress -or $null -eq $a2.ProtoCombo.SelectedItem) { return }
        $key = [string]$a2.ProtoCombo.SelectedItem
        $prev = $a2.Protocol
        if (-not (Load-ProtocolFrom $a2.ProtocolPaths[$key] $key)) {
            # failed: restore the previous selection
            $a2.Suppress = $true; $a2.ProtoCombo.SelectedItem = $prev.Name; $a2.Suppress = $false
        }
    })
    $a.CorrectBtn.Add_Click({ Invoke-Correct })
    $a.EndBtn.Add_Click({ Invoke-EndSession })
    $a.ResetBtn.Add_Click({ Invoke-Reset })
    $a.FolderBtn.Add_Click({ Open-DataFolder })
    $form.Add_FormClosing({
        param($sender, $e)
        $s = $Script:App.Session
        if ($s -and -not $s.Ended -and $s.Phase() -ne 'completed') {
            $q = "The session is still in progress.`n`nClose the application and end the session as INCOMPLETE?"
            if ((Msg $q 'Close application' 'YesNo' 'Warning' 'Button2') -ne 'Yes') { $e.Cancel = $true; return }
            $stamp = Get-Stamp
            $ev = $s.EndSession($stamp, 'SESSION_END', 'application closed before completion')
            Save-OrWarn $ev
        }
    })

    $a.Form = $form

    # --- initial protocol: command-line/inline source > protocols\default.* > first file > built-in
    $files = Get-ProtocolFiles (Join-Path $Script:AppRoot $Script:ProtocolDirName)
    foreach ($f in $files) { $a.ProtocolPaths[$f.Name] = $f.FullName; [void]$a.ProtoCombo.Items.Add($f.Name) }
    $loaded = $false
    if ($Script:ProtocolArg) {
        $label = $null
        if (Test-Path -LiteralPath $Script:ProtocolArg -PathType Leaf) { $label = [System.IO.Path]::GetFileName($Script:ProtocolArg) } else { $label = 'Inline protocol' }
        $loaded = Load-ProtocolFrom $Script:ProtocolArg $label
    }
    if (-not $loaded) {
        $def = $files | Where-Object { $_.BaseName -eq 'default' } | Select-Object -First 1
        if (-not $def) { $def = $files | Select-Object -First 1 }
        if ($def) { $loaded = Load-ProtocolFrom $def.FullName $def.Name }
    }
    if (-not $loaded) { Set-Protocol $Script:BuiltInProtocol $null }
    Update-View
    Update-Clocks
    $a.ClockTimer.Start()
    [void]$form.ShowDialog()
    $a.ClockTimer.Stop()
}
