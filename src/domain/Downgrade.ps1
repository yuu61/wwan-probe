# Domain: 2G/3G downgrade detection (pure, no I/O).
# Jamming 4G/5G to push a device onto 2G/3G (where a fake base station is easier) is a known
# attack. All inputs are plain values so the rules can be tested without a modem.
# In Japan no carrier runs 2G, and all 3G networks were shut down by 2026-03-31
# (au 2022-03, SoftBank 2024-07, docomo FOMA 2026-03), so any 2G/3G cell there is suspect.

# WinRT DataClasses flag names that mean 2G/3G (GSM/UMTS/CDMA families).
$script:LegacyDataClassNames = @(
    'Gprs', 'Edge', 'Umts', 'Hsdpa', 'Hsupa',
    'Cdma1xRtt', 'Cdma1xEvdo', 'Cdma1xEvdoRevA', 'Cdma1xEvdv', 'Cdma3xRtt', 'Cdma1xEvdoRevB', 'CdmaUmb'
)

# Legacy flag names in a DataClasses string such as "Umts, Hsdpa" (empty when none).
function Get-LegacyDataClass([string]$DataClass) {
    $names = @($DataClass -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return , @($names | Where-Object { $script:LegacyDataClassNames -contains $_ })
}

# Evaluates one sample. Returns:
#   Level   = 'Alert' (registered/serving on 2G/3G), 'Warning' (2G/3G cells visible) or 'None'
#   Reasons = human readable evidence
# $RegisteredDataClass: WinRT RegisteredDataClass string
# $LegacyServingCount:  WinRT GSM/UMTS/CDMA serving cells
# $AtCells:             common AT cells (AtProfile.ps1, e.g. from AT+XMCI) ($null when unavailable)
# $AtSource:            label of the AT cell list shown in the reasons (e.g. 'XMCI')
function Get-DowngradeFinding([string]$RegisteredDataClass, [int]$LegacyServingCount, $AtCells, [string]$AtSource = 'AT') {
    $alert = @()
    $warning = @()

    $legacyClass = Get-LegacyDataClass $RegisteredDataClass
    $hasModern = $RegisteredDataClass -match 'Lte|NewRadio'
    if ($legacyClass.Count -gt 0 -and -not $hasModern) {
        $alert += "registered on $($legacyClass -join '/')"
    }
    if ($LegacyServingCount -gt 0) {
        $alert += "$LegacyServingCount 2G/3G serving cell(s) (WinRT)"
    }
    # LTE / NR cells are not legacy (CDMA is not reported by any AT profile).
    foreach ($cell in @($AtCells | Where-Object { $_ -and $_.Rat -in 'GSM', 'UMTS' })) {
        $text = "$($cell.Rat) $($cell.Role.ToLower()) ch:$(if ($null -eq $cell.Channel) { '?' } else { $cell.Channel })"
        if ($cell.Role -eq 'Serving') { $alert += "$text ($AtSource)" } else { $warning += "$text ($AtSource)" }
    }

    $level = if ($alert.Count -gt 0) { 'Alert' } elseif ($warning.Count -gt 0) { 'Warning' } else { 'None' }
    return [pscustomobject]@{ Level = $level; Reasons = @($alert + $warning) }
}
