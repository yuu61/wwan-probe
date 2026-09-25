# Infrastructure: native GNSS driver access for the NMEA helper (GnssDevice.cs). Requires an
# administrator: the GNSS interface ACL denies a normal user (Win32 error 5).

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

# Only one NMEA listener may run: each one resets the driver logging to disabled on exit,
# which would silently stop another's stream. Returns the lock to Dispose, or throws.
# Other tools that switch NMEA logging should take the same named mutex.
function Enter-GnssNmeaLock {
    $createdNew = $false
    $lock = [Threading.Mutex]::new($true, 'Global\WwanProbeGnssNmea', [ref]$createdNew)
    if (-not $createdNew) {
        $lock.Dispose()
        throw 'Another process is already listening to the GNSS NMEA stream.'
    }
    return $lock
}
