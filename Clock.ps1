# Clock.ps1 - system timestamp collection.
# Wall clock: OS clock via GetSystemTimePreciseAsFileTime (sub-millisecond on Windows 8+),
#             falling back to DateTimeOffset.Now. Used for the experimental timestamps.
# Monotonic : Stopwatch (QueryPerformanceCounter). Used ONLY for elapsed/duration maths,
#             so changes of the wall clock during a session cannot corrupt durations.
# No network time, no manually configured time.

Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class PreciseClock
{
    [DllImport("kernel32.dll")]
    private static extern void GetSystemTimePreciseAsFileTime(out long fileTime);

    public static DateTimeOffset Now()
    {
        try
        {
            long ft;
            GetSystemTimePreciseAsFileTime(out ft);
            return new DateTimeOffset(DateTime.FromFileTimeUtc(ft)).ToLocalTime();
        }
        catch (Exception)
        {
            return DateTimeOffset.Now;
        }
    }

    public static double MonoSeconds()
    {
        return (double)Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
    }
}
"@

$Script:Inv = [System.Globalization.CultureInfo]::InvariantCulture

function Get-Stamp {
    # Read both clocks back-to-back, as the very first thing a handler does.
    $mono = [PreciseClock]::MonoSeconds()
    $wall = [PreciseClock]::Now()
    return [pscustomobject]@{ Wall = $wall; Mono = $mono }
}

function Format-Stamp($stamp) {
    $w = $stamp.Wall
    return @{
        system_date      = $w.ToString('yyyy-MM-dd', $Script:Inv)
        system_time      = $w.ToString('HH:mm:ss.fff', $Script:Inv)
        system_timestamp = $w.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', $Script:Inv)
        utc_offset       = $w.ToString('zzz', $Script:Inv)
        timezone         = [TimeZoneInfo]::Local.Id
        utc_timestamp    = $w.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fff'Z'", $Script:Inv)
    }
}

function Format-Hms([double]$seconds) {
    $neg = $seconds -lt 0
    $ms = [long][math]::Round([math]::Abs($seconds) * 1000)
    $h = [math]::Floor($ms / 3600000); $ms -= $h * 3600000
    $m = [math]::Floor($ms / 60000);   $ms -= $m * 60000
    $s = [math]::Floor($ms / 1000);    $ms -= $s * 1000
    $t = '{0:00}:{1:00}:{2:00}.{3:000}' -f $h, $m, $s, $ms
    if ($neg) { return "-$t" }
    return $t
}

function Format-Seconds([double]$seconds) {
    return $seconds.ToString('0.000', $Script:Inv)
}
