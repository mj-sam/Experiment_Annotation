# Validation.ps1 - session completeness / consistency checks.

function Get-SessionReport($session) {
    $valid = @($session.ValidEvents())
    $rows = @()
    $prevFinish = $null

    foreach ($stage in $session.Stages) {
        $starts   = @($valid | Where-Object { $_.stage -eq $stage -and $_.event -eq 'START' })
        $finishes = @($valid | Where-Object { $_.stage -eq $stage -and $_.event -eq 'FINISH' })
        $issues = @()
        $st = $null; $fi = $null; $dur = $null

        if ($starts.Count -eq 0) { $issues += 'START missing' }
        elseif ($starts.Count -gt 1) { $issues += 'duplicate START' }
        if ($finishes.Count -eq 0) { $issues += 'FINISH missing' }
        elseif ($finishes.Count -gt 1) { $issues += 'duplicate FINISH' }
        if ($starts.Count -ge 1) { $st = $starts[0] }
        if ($finishes.Count -ge 1) { $fi = $finishes[0] }

        if ($st -and $fi) {
            if ($fi.mono -lt $st.mono) {
                $issues += 'FINISH before START'
            } else {
                $dur = $fi.mono - $st.mono
                $wallDiff = ($fi.wall - $st.wall).TotalSeconds
                if ([math]::Abs($wallDiff - $dur) -gt 0.05) {
                    $issues += ('system clock changed during stage (wall {0:N3}s vs monotonic {1:N3}s)' -f $wallDiff, $dur)
                }
            }
        }
        if ($st -and $null -ne $prevFinish -and $st.mono -lt $prevFinish) {
            $issues += 'started before previous stage finished'
        }
        if ($fi) { $prevFinish = $fi.mono }

        $durHms = ''
        if ($null -ne $dur) { $durHms = Format-Hms $dur }
        $rows += [pscustomobject]@{
            Stage       = $stage
            StartEvent  = $st
            FinishEvent = $fi
            StartTime   = $(if ($st) { $st.system_time } else { '' })
            FinishTime  = $(if ($fi) { $fi.system_time } else { '' })
            DurationSec = $dur
            DurationHms = $durHms
            Issues      = $issues
            Ok          = ($issues.Count -eq 0)
        }
    }

    $total = 0.0
    if ($valid.Count -gt 0) { $total = [double]$valid[$valid.Count - 1].elapsed }
    $voided = @($session.Events | Where-Object { $_.event -eq 'CORRECTION' }).Count

    return [pscustomobject]@{
        Rows          = $rows
        TotalSeconds  = $total
        TotalHms      = (Format-Hms $total)
        AllOk         = (@($rows | Where-Object { -not $_.Ok }).Count -eq 0)
        Corrections   = $voided
    }
}
