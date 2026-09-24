# Domain: EARFCN -> LTE band mapping (pure, no I/O).
# 3GPP TS 36.101 Table 5.7.3-1 (E-UTRA DL channel numbers), cross-checked against the
# srsRAN band table (lib/src/phy/common/phy_common.c). Each entry is the first DL EARFCN of the
# band; a band ends where the next entry starts, so unassigned gaps are attributed to the band
# below them (harmless for display). Name = common frequency label, "T" = TDD.
$script:LteBandTable = @(
    @(0, 1, '2100'), @(600, 2, '1900'), @(1200, 3, '1800'), @(1950, 4, 'AWS'), @(2400, 5, '850')
    @(2650, 6, '800'), @(2750, 7, '2600'), @(3450, 8, '900'), @(3800, 9, '1800'), @(4150, 10, 'AWS')
    @(4750, 11, '1500'), @(5010, 12, '700'), @(5180, 13, '700'), @(5280, 14, '700'), @(5380, $null, $null)
    @(5730, 17, '700'), @(5850, 18, '800'), @(6000, 19, '800'), @(6150, 20, '800'), @(6450, 21, '1500')
    @(6600, 22, '3500'), @(7500, 23, '2000'), @(7700, 24, '1600'), @(8040, 25, '1900'), @(8690, 26, '850')
    @(9040, 27, '800'), @(9210, 28, '700'), @(9660, 29, '700'), @(9770, 30, '2300'), @(9870, 31, '450')
    @(9920, 32, '1500'), @(10360, $null, $null)
    @(36000, 33, '1900T'), @(36200, 34, '2000T'), @(36350, 35, '1900T'), @(36950, 36, '1900T')
    @(37550, 37, '1900T'), @(37750, 38, '2600T'), @(38250, 39, '1900T'), @(38650, 40, '2300T')
    @(39650, 41, '2500T'), @(41590, 42, '3500T'), @(43590, 43, '3700T'), @(45590, 44, '700T')
    @(46590, 45, '1500T'), @(46790, 46, '5200T'), @(54540, 47, '5900T'), @(55240, 48, '3500T')
    @(56740, 49, '3500T'), @(58240, 50, '1500T'), @(59090, 51, '1500T'), @(59140, 52, '3300T')
    , @(60140, $null, $null)
    @(65536, 65, '2100'), @(66436, 66, 'AWS'), @(67336, 67, '700'), @(67536, 68, '700')
    @(67836, 69, '2600'), @(68336, 70, 'AWS'), @(68586, 71, '600'), @(68936, $null, $null)
)

function Get-EarfcnBand([long]$earfcn) {
    $entry = $null
    foreach ($e in $script:LteBandTable) {
        if ($earfcn -lt $e[0]) { break }
        $entry = $e
    }
    if ($null -eq $entry -or $null -eq $entry[1]) { return "B?/$earfcn" }
    return "B$($entry[1])/$($entry[2])"
}
