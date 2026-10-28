# Protocol.ps1 - experiment protocol + state management (no GUI, no file I/O).

# ---------------------------------------------------------------------------
# PROTOCOL LOADING. A protocol is a named, ordered list of unique stage names.
# Accepted sources: .json file ({"name": "...", "stages": [...]} or a bare array;
# stages may be strings or {"name": "..."} objects), .txt file (one stage per line,
# # = comment) or an inline JSON string. See the protocols/ folder for examples.
# ---------------------------------------------------------------------------
$Script:OutputDirName    = 'annotations'   # created next to the application
$Script:ProtocolDirName  = 'protocols'     # protocol files offered in the GUI
$Script:MinClickInterval = 0.5             # seconds; faster repeat presses are ignored
$Script:BuiltInProtocol  = @{
    Name   = 'Built-in default'
    Source = '(built-in)'
    Stages = [string[]]@('Question', 'Baseline', 'Experiment 1', 'Q1', 'Recording Q2', 'Experiment 2', 'Questions 2', 'Recording 2')
}

function Read-Protocol([string]$source) {
    $text = $source.Trim()
    $name = 'Custom protocol'; $label = '(inline)'; $isTxt = $false
    if ($text.StartsWith('{') -or $text.StartsWith('[')) {
        $raw = $text
    } else {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Protocol file not found: $source" }
        $full = (Resolve-Path -LiteralPath $source).Path
        $raw = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
        $name = [System.IO.Path]::GetFileNameWithoutExtension($full)
        $label = $full
        $isTxt = ([System.IO.Path]::GetExtension($full) -eq '.txt')
    }

    $items = @()
    if ($isTxt) {
        $items = @($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and -not $_.StartsWith('#') })
    } else {
        try { $obj = ConvertFrom-Json -InputObject $raw } catch { throw "Invalid JSON in protocol: $($_.Exception.Message)" }
        if ($obj -is [string]) { $items = @($obj) }
        elseif ($obj -is [array]) { $items = @($obj) }
        elseif ($obj.PSObject.Properties['stages']) {
            $items = @($obj.stages)
            if ($obj.PSObject.Properties['name'] -and "$($obj.name)".Trim() -ne '') { $name = "$($obj.name)".Trim() }
        } else { throw 'Protocol JSON needs a "stages" list.' }
    }

    $stages = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($it in $items) {
        if ($it -is [string]) { $n = $it.Trim() }
        elseif ($it.PSObject.Properties['name']) { $n = "$($it.name)".Trim() }
        else { throw 'Each stage must be a text or an object with a "name".' }
        if ($n -eq '') { throw 'A stage name is empty.' }
        if ($n.Length -gt 60) { throw "Stage name too long (max 60): $n" }
        if ($seen.ContainsKey($n.ToLowerInvariant())) { throw "Duplicate stage name: $n" }
        $seen[$n.ToLowerInvariant()] = $true
        $stages.Add($n)
    }
    if ($stages.Count -lt 1) { throw 'The protocol has no stages.' }
    if ($stages.Count -gt 40) { throw 'The protocol has more than 40 stages.' }
    return @{ Name = $name; Source = $label; Stages = [string[]]$stages.ToArray() }
}

function Get-ProtocolFiles([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -in '.json', '.txt' } | Sort-Object Name)
}

# ---------------------------------------------------------------------------
# Session: append-only event list + state derived from it.
# State rule: let n = number of valid (non-voided) START/FINISH events.
#   stage index = n div 2;  n even -> ready to START;  n odd -> running (FINISH next).
# A CORRECTION event voids the most recent valid event; nothing is ever deleted.
# ---------------------------------------------------------------------------
class Session {
    [string]$ParticipantId
    [string]$SessionId
    [string]$ProtocolName
    [string]$ProtocolSource
    [string[]]$Stages
    [System.Collections.ArrayList]$Events
    [double]$StartMono
    [bool]$Ended
    [string]$EndKind
    [double]$LastPress

    Session([string]$p, [string]$s, [object]$protocol) {
        $this.ParticipantId = $p
        $this.SessionId = $s
        $this.Stages = [string[]]$protocol.Stages
        $this.ProtocolName = [string]$protocol.Name
        $this.ProtocolSource = [string]$protocol.Source
        $this.Events = New-Object System.Collections.ArrayList
        $this.LastPress = -1000.0
        $this.Ended = $false
    }

    [hashtable] AddEvent([string]$kind, [string]$stage, [object]$stamp, [string]$note, [int]$corrects) {
        $f = Format-Stamp $stamp
        $elapsed = $stamp.Mono - $this.StartMono
        $ev = @{
            event_number     = $this.Events.Count + 1
            participant_id   = $this.ParticipantId
            session_id       = $this.SessionId
            stage            = $stage
            event            = $kind
            system_date      = $f.system_date
            system_time      = $f.system_time
            system_timestamp = $f.system_timestamp
            utc_offset       = $f.utc_offset
            timezone         = $f.timezone
            utc_timestamp    = $f.utc_timestamp
            elapsed_seconds  = (Format-Seconds $elapsed)
            elapsed_hms      = (Format-Hms $elapsed)
            corrects_event   = $corrects
            note             = $note
            wall             = $stamp.Wall   # internal (not written to files)
            mono             = $stamp.Mono   # internal
            elapsed          = $elapsed      # internal
        }
        [void]$this.Events.Add($ev)
        return $ev
    }

    [hashtable] BeginSession([object]$stamp) {
        $this.StartMono = $stamp.Mono
        return $this.AddEvent('SESSION_START', '', $stamp, '', 0)
    }

    [object[]] ValidEvents() {
        $void = @{}
        foreach ($e in $this.Events) {
            if ($e.event -eq 'CORRECTION') { $void[[int]$e.corrects_event] = $true }
        }
        $out = New-Object System.Collections.ArrayList
        foreach ($e in $this.Events) {
            if (($e.event -eq 'START' -or $e.event -eq 'FINISH') -and -not $void.ContainsKey([int]$e.event_number)) {
                [void]$out.Add($e)
            }
        }
        return $out.ToArray()
    }

    [string] Phase() {
        if ($this.Ended) { return 'ended' }
        $n = @($this.ValidEvents()).Count
        if ($n -ge 2 * $this.Stages.Count) { return 'completed' }
        if ($n % 2 -eq 1) { return 'running' }
        return 'ready'
    }

    [int] StageIndex() {
        $n = @($this.ValidEvents()).Count
        return [int][math]::Min([math]::Floor($n / 2), $this.Stages.Count - 1)
    }

    [hashtable] Press([object]$stamp) {
        $phase = $this.Phase()
        if ($phase -eq 'ended' -or $phase -eq 'completed') { throw 'The session is already finished.' }
        if (($stamp.Mono - $this.LastPress) -lt $Script:MinClickInterval) { throw 'DUPLICATE: repeat click ignored.' }
        $n = @($this.ValidEvents()).Count
        $idx = [int][math]::Floor($n / 2)
        $kind = 'START'
        if ($n % 2 -eq 1) { $kind = 'FINISH' }
        $ev = $this.AddEvent($kind, $this.Stages[$idx], $stamp, '', 0)
        $this.LastPress = $stamp.Mono
        return $ev
    }

    [hashtable] CorrectLast([object]$stamp) {
        if ($this.Ended) { throw 'The session is already ended.' }
        $valid = @($this.ValidEvents())
        if ($valid.Count -eq 0) { throw 'There is no annotation to correct.' }
        $t = $valid[$valid.Count - 1]
        $note = 'Event {0} ({1} {2}) marked as accidental' -f $t.event_number, $t.stage, $t.event
        $ev = $this.AddEvent('CORRECTION', $t.stage, $stamp, $note, [int]$t.event_number)
        $this.LastPress = -1000.0
        return $ev
    }

    [hashtable] EndSession([object]$stamp, [string]$kind, [string]$note) {
        $ev = $this.AddEvent($kind, '', $stamp, $note, 0)
        $this.Ended = $true
        $this.EndKind = $kind
        return $ev
    }
}

function New-Session([string]$participant, [string]$sessionId, $protocol) {
    return [Session]::new($participant, $sessionId, $protocol)
}
