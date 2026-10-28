# Logger.ps1 - durable file logging (CSV appended per event, JSON rewritten atomically per event).

$Script:CsvColumns = @(
    'event_number', 'participant_id', 'session_id', 'stage', 'event',
    'system_date', 'system_time', 'system_timestamp', 'utc_offset', 'timezone',
    'utc_timestamp', 'elapsed_seconds', 'elapsed_hms', 'corrects_event', 'note'
)
$Script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-CleanField($ev, $col) {
    $v = $ev[$col]
    if ($col -eq 'corrects_event' -and [int]$v -eq 0) { return '' }
    if ($null -eq $v) { return '' }
    return [string]$v
}

function ConvertTo-CsvLine([string[]]$fields) {
    $q = foreach ($f in $fields) {
        if ($f -match '[",\r\n]') { '"' + $f.Replace('"', '""') + '"' } else { $f }
    }
    return ($q -join ',')
}

function Write-Durable([string]$path, [string]$text, [bool]$append) {
    $mode = [System.IO.FileMode]::Create
    if ($append) { $mode = [System.IO.FileMode]::Append }
    $fs = New-Object System.IO.FileStream($path, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $bytes = $Script:Utf8NoBom.GetBytes($text)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)   # flush to disk, not just to the OS cache
    } finally { $fs.Dispose() }
}

function New-LogFiles([string]$dir, [string]$participant, [string]$sessionId) {
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $base = '{0}_{1}_annotations' -f $participant, $sessionId
    $n = 1
    $stem = $base
    # Never overwrite an earlier recording: add _run2, _run3 ... if the name is taken.
    while ((Test-Path -LiteralPath (Join-Path $dir "$stem.csv")) -or (Test-Path -LiteralPath (Join-Path $dir "$stem.json"))) {
        $n++
        $stem = '{0}_run{1}' -f $base, $n
    }
    return [pscustomobject]@{
        Dir  = $dir
        Csv  = (Join-Path $dir "$stem.csv")
        Json = (Join-Path $dir "$stem.json")
    }
}

function Get-StatusText($session) {
    switch ($session.Phase()) {
        'completed' { return 'completed' }
        'ended'     { if ($session.EndKind -eq 'SESSION_RESET') { return 'reset' } else { return 'ended_incomplete' } }
        default     { return 'in_progress' }
    }
}

function Save-Json($files, $session) {
    $report = Get-SessionReport $session
    $void = @{}
    foreach ($e in $session.Events) { if ($e.event -eq 'CORRECTION') { $void[[int]$e.corrects_event] = $true } }

    $events = @()
    foreach ($e in $session.Events) {
        $o = [ordered]@{}
        foreach ($c in $Script:CsvColumns) {
            if ($c -eq 'corrects_event') {
                $o[$c] = $(if ([int]$e[$c] -eq 0) { $null } else { [int]$e[$c] })
            } elseif ($c -eq 'event_number') {
                $o[$c] = [int]$e[$c]
            } elseif ($c -eq 'elapsed_seconds') {
                $o[$c] = [double]::Parse($e[$c], $Script:Inv)
            } else { $o[$c] = $e[$c] }
        }
        $o['voided'] = $void.ContainsKey([int]$e.event_number)
        $events += $o
    }

    $summary = @()
    foreach ($r in $report.Rows) {
        $summary += [ordered]@{
            stage            = $r.Stage
            start_timestamp  = $(if ($r.StartEvent) { $r.StartEvent.system_timestamp } else { $null })
            finish_timestamp = $(if ($r.FinishEvent) { $r.FinishEvent.system_timestamp } else { $null })
            duration_seconds = $(if ($null -ne $r.DurationSec) { [math]::Round($r.DurationSec, 3) } else { $null })
            ok               = $r.Ok
            issues           = @($r.Issues)
        }
    }

    $first = $session.Events[0]
    $doc = [ordered]@{
        schema_version         = 1
        participant_id         = $session.ParticipantId
        session_id             = $session.SessionId
        protocol_name          = $session.ProtocolName
        protocol_source        = $session.ProtocolSource
        protocol               = @($session.Stages)
        status                 = (Get-StatusText $session)
        session_start          = [ordered]@{
            system_timestamp = $first.system_timestamp
            utc_timestamp    = $first.utc_timestamp
            utc_offset       = $first.utc_offset
            timezone         = $first.timezone
        }
        total_duration_seconds = [math]::Round($report.TotalSeconds, 3)
        all_stages_verified    = $report.AllOk
        stage_summary          = $summary
        events                 = $events
        last_written           = (Format-Stamp (Get-Stamp)).system_timestamp
    }
    $json = ConvertTo-Json -InputObject $doc -Depth 6

    # Atomic replace: write a temp file to disk, then swap it in.
    $tmp = $files.Json + '.tmp'
    Write-Durable $tmp $json $false
    if (Test-Path -LiteralPath $files.Json) {
        [System.IO.File]::Replace($tmp, $files.Json, [NullString]::Value)
    } else {
        [System.IO.File]::Move($tmp, $files.Json)
    }
}

function Save-Event($files, $session, $ev) {
    $text = ''
    if (-not (Test-Path -LiteralPath $files.Csv)) {
        $text += (ConvertTo-CsvLine $Script:CsvColumns) + "`r`n"
    }
    $row = foreach ($c in $Script:CsvColumns) { Get-CleanField $ev $c }
    $text += (ConvertTo-CsvLine @($row)) + "`r`n"
    Write-Durable $files.Csv $text $true   # 1. the CSV row is on disk first
    Save-Json $files $session              # 2. then the full JSON snapshot
}
