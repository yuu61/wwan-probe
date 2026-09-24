# Infrastructure: native GNSS driver access for NMEA (GnssDevice.cs). Requires an
# administrator: the GNSS interface ACL denies a normal user (Win32 error 5).
# Shared by the elevated NMEA helper and diagnostics/Test-Gnss.ps1.

$script:GnssInterfaceClass = '{3336e5e4-018a-4669-84c5-bd05f3bd368b}'

# GNSS device interface paths (WinRT projection must be loaded).
function Get-GnssDeviceInterface {
    return @(Wait-WinRtAsync ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
                "System.Devices.InterfaceClassGuid:=`"$script:GnssInterfaceClass`"")))
}

function Open-GnssDevice([string]$Path) {
    if (-not ('WwanProbe.GnssDevice' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'GnssDevice.cs') -ErrorAction Stop
    }
    return [WwanProbe.GnssDevice]::new($Path)
}

# IOCTL_GNSS_GET_DEVICE_CAPABILITY (GNSS_DEVICE_CAPABILITY, 604 bytes in DDI version 4).
function Get-GnssCapability($Device) {
    $result = $Device.Query(0x220008, $null, 604, 3000)
    if ($result.Error -ne 0) { throw "GET_DEVICE_CAPABILITY: Win32=$($result.Error), timeout=$($result.TimedOut)" }
    if ($result.Data.Length -lt 36) { throw 'Truncated GNSS capability response.' }
    return [pscustomobject]@{
        DriverVersion       = [BitConverter]::ToUInt32($result.Data, 4)
        MultipleFixSessions = [BitConverter]::ToUInt32($result.Data, 8) -ne 0
        MultipleAppSessions = [BitConverter]::ToUInt32($result.Data, 12) -ne 0
        ContinuousTracking  = [BitConverter]::ToUInt32($result.Data, 32) -ne 0
    }
}

# GNSS_SetNMEALogging. The driver cannot report the current value, so callers
# restore the default (disabled) when they finish.
function Set-GnssNmeaLogging {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param($Device, [uint32]$Version, [bool]$Enabled)

    $result = $Device.SetNmeaLogging($Version, $Enabled)
    if ($result.Error -ne 0) { throw "SetNMEALogging: Win32=$($result.Error), timeout=$($result.TimedOut)" }
}

# One IOCTL_GNSS_LISTEN_NMEA event: up to 256 characters of the NMEA stream (a sentence
# can span events). Returns $null when nothing arrives within $TimeoutMs.
function Read-GnssNmea($Device, [uint32]$TimeoutMs) {
    $result = $Device.Query(0x22011C, $null, 8192, $TimeoutMs)
    if ($result.TimedOut) { return $null }
    if ($result.Error -ne 0) { throw "LISTEN_NMEA: Win32=$($result.Error)" }
    # GNSS_EVENT: EventType (13 = NMEA data) at 8, union at 528; GNSS_NMEA_DATA header is 8 bytes.
    if ($result.Data.Length -lt 800 -or [BitConverter]::ToUInt32($result.Data, 8) -ne 13 -or
        [BitConverter]::ToUInt32($result.Data, 12) -lt 264) { throw 'Invalid GNSS NMEA event.' }
    return [Text.Encoding]::ASCII.GetString($result.Data, 536, 256).Split([char]0)[0]
}

# Only one NMEA listener may run: each one resets the driver logging to disabled on exit,
# which would silently stop another's stream. Returns the lock to Dispose, or throws.
function Enter-GnssNmeaLock {
    $createdNew = $false
    $lock = [Threading.Mutex]::new($true, 'Global\WwanProbeGnssNmea', [ref]$createdNew)
    if (-not $createdNew) {
        $lock.Dispose()
        throw 'Another NMEA session (lte_monitor.ps1 -Nmea or Test-Gnss.ps1 -Nmea) is running.'
    }
    return $lock
}
