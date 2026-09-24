# Domain: EARFCN -> LTE band mapping (pure, no I/O).

function Get-EarfcnBand([int]$earfcn) {
    if ($earfcn -ge 0 -and $earfcn -le 599) { return "B1/2100" }
    if ($earfcn -ge 600 -and $earfcn -le 1199) { return "B2/1900" }
    if ($earfcn -ge 1200 -and $earfcn -le 1949) { return "B3/1800" }
    if ($earfcn -ge 1950 -and $earfcn -le 2399) { return "B4/AWS" }
    if ($earfcn -ge 2400 -and $earfcn -le 2649) { return "B5/850" }
    if ($earfcn -ge 2750 -and $earfcn -le 3449) { return "B7/2600" }
    if ($earfcn -ge 3450 -and $earfcn -le 3799) { return "B8/900" }
    if ($earfcn -ge 5010 -and $earfcn -le 5179) { return "B11/1500" }
    if ($earfcn -ge 5180 -and $earfcn -le 5279) { return "B12/700" }
    if ($earfcn -ge 5280 -and $earfcn -le 5379) { return "B13/700" }
    if ($earfcn -ge 5730 -and $earfcn -le 5849) { return "B17/700" }
    if ($earfcn -ge 5850 -and $earfcn -le 5999) { return "B18/800" }
    if ($earfcn -ge 6000 -and $earfcn -le 6149) { return "B19/800" }
    if ($earfcn -ge 6150 -and $earfcn -le 6449) { return "B20/800" }
    if ($earfcn -ge 6450 -and $earfcn -le 6599) { return "B21/1500" }
    if ($earfcn -ge 7700 -and $earfcn -le 8039) { return "B26/850" }
    if ($earfcn -ge 8040 -and $earfcn -le 8689) { return "B28/700" }
    if ($earfcn -ge 39650 -and $earfcn -le 41589) { return "B41/2500T" }
    if ($earfcn -ge 41590 -and $earfcn -le 43589) { return "B42/3500T" }
    return "B?/$earfcn"
}
