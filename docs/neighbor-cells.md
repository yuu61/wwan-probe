# 近隣セル (Neighbors) の取得方法

調査日: 2026-09-24
対象: Fibocom L860-GL (FW `18601.5001.00.01.17.30_KD`) / Windows 11 Pro 26200 / KDDI (au) 回線

## 結論

- L860-GL は WinRT (`GetCellsInfoAsync()`) では近隣セルを返さない (1.)。
- AT ポート (COM) は ModemControl ドライバに占有されていて開けない (2.)。
- **MBIM の Intel AT Tunnel サービス経由で `AT+XMCI` を送ると近隣セルを取得できる** (5.)。
  COM ポートもドライバの無効化も不要。TUI の Neighbors セクションはこの経路で実装している。
- L860-GL 以外のモデム (他ベンダーの AT 経路・コマンド、WinRT の近隣セル) については [modem-support.md](modem-support.md) を参照。

## 1. WinRT API は近隣セルを返さない

`MobileBroadbandNetwork.GetCellsInfoAsync()` の結果を直接確認した (2 秒間隔 × 10 回)。

| プロパティ | 件数 |
| --- | --- |
| `ServingCellsLte` | 1 |
| `NeighboringCellsLte` | 0 |
| `NeighboringCellsUmts` | 0 |
| `NeighboringCellsGsm` | 0 |
| `NeighboringCellsNR` | 0 |
| `NeighboringCellsTdscdma` | 0 |
| `NeighboringCellsCdma` | 0 |

毎回同じ結果で、アプリ側のフィルタではなく API の返り値の時点で空。
ドライバ (Generic Mobile Broadband Adapter) が `MBIM_CID_BASE_STATIONS_INFO` に
近隣セルを載せていないと考えられる (理由は未確認)。一方、同時刻の `AT+XMCI` は近隣セルを返すので、
モデムが近隣セルを測定していないわけではない。

## 2. AT ポートは ModemControl ドライバが占有している

L860-GL の USB 複合デバイス (`USB\VID_8087&PID_0ADA`) の構成:

| IF | デバイス | ドライバ | バス報告名 | PDO |
| --- | --- | --- | --- | --- |
| MI_00 | USB シリアル デバイス (COM6) | `usbser` | `MBIM-AT` | `\Device\000000a5` |
| MI_02 | USB シリアル デバイス (COM9) | `usbser` | `CDC ACM Modem Control1` | `\Device\000000a6` |
| MI_04 | ModemControl Device | `WUDFRd` (UMDF, `oem262.inf`) | - | `\Device\000000a7` |

- COM6 / COM9 とも、管理者権限でも `Access to the path 'COMx' is denied.` で開けない。
- 全プロセスのハンドルを走査した結果、両ポートを開いているのは `WUDFHost.exe` 1 つだけで、
  その中で動いている UMDF ドライバは `C:\Windows\System32\drivers\umdf\modemcontrol.dll` (= ModemControl Device)。
- `FirmwareSwitchService` / `ModemAuthenticatorService` は COM ポートを直接開いていない。

### ModemControl Device について

事実:

- INF: 提供元 `Intel`、`INTEL CONFIDENTIAL Copyright 2016,2017`、DriverVer `07/27/2024,0.5.100.884`
- DLL: コード署名は `Fibocom Wireless Inc.`。PDB パスは Fibocom のビルド環境 (`...\UDE_883_2024HLKRelease\...\ModemControl.pdb`)
- DLL 内の文字列に `RIL_Open`、`MBIM_CreateEvent` / `MBIM_SetEvent` / `MBIM_WaitForSingleObject` などがある
- 調査時点で ModemControl Device (`\Device\000000a7`) を開いているユーザーモードプロセスはなかった
- 役割を説明した公開資料は見つからなかった

推測 (未検証):

- AT ポートを握り、`FirmwareSwitchService` (キャリア別ファームウェア切替) や
  `ModemAuthenticatorService` (FCC ロック解除) のモデム制御を仲介している
- L860-GL のベースバンドは Intel XMM 7560 のため VID が Intel (`8087`)。Intel のリファレンスドライバを
  Fibocom が保守していると見られる

ModemControl Device を無効化すれば COM6 は解放されるはずだが、FCC ロック解除・ファームウェア切替への
影響が懸念されるため試していない。5. の経路があるので不要。

## 3. MBIM_CID_BASE_STATIONS_INFO の仕様

[Microsoft Learn: MB base stations information query support](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/mb-base-stations-information-query-support)

- Windows 独自拡張 (`MBB_UUID_BASIC_CONNECT_EXTENSIONS` = `3d01dcc5-fef5-4d05-0d3a-bef7058e9aaf`, CID 11)。Windows 10 1709 以降。
- クエリ `MBIM_BASE_STATIONS_INFO_REQ` で `MaxLTECount` 等 (近隣セルの最大件数、既定 15) を指定する。
  `GetCellsInfoAsync()` からはこの値を指定できない。
- 近隣セル一覧 (`LTEMrlOffset`) は「返す近隣セルがなければ NULL でよい」とされ、返すことは必須ではない。
- 仕様上の LTE RSRP は **-140〜-44 (1 dBm 単位)**、RSRQ は -20〜-3。
  このモデムはサービングセルの RSRP に `61` のような **3GPP 36.133 のインデックス値**を返しており、仕様と異なる。
  WinRT の値は `ConvertFrom-WinRtRsrp` / `ConvertFrom-WinRtRsrq` で変換する。仕様どおりの dBm / dB とこのモデムのインデックス値の
  両方を受け付ける (範囲が重ならないため区別できる)。
- CID 11 を device service として直接送る案は、`BASIC_CONNECT_EXTENSIONS` の
  `OpenCommandSession()` が `0x80070015` (ERROR_NOT_READY) で失敗するため不可 (OS が占有していると見られる)。

### 応答が返らないクエリ (実測 2026-09-24)

- `GetCellsInfoAsync()` は通常 10〜60 ms で返る (約 800 回で最大 59 ms)。
- まれに応答が返らない。以前のモニター実行では約 400 回中 6 回 (WWAN のイベントログの AT 応答の間隔から推定)。
  検証では AT なし 400 回で 0 回、AT あり 400 回で 1 回だった。AT のセッションが関係するかは、この回数では判断できない。
- 応答が返らなかった 1 回は、10 秒以内に返らず、約 60 秒後に Windows 側で失敗扱いになった (失敗の理由は記録していない)。
  遅れて返るのではなく、応答がないまま終わる。
- その間も、新しく送ったクエリは 10〜25 ms で返り、AT も正常だった。タイムアウト直後の取得は 7 回中 7 回成功している。
- このため `Get-ModemCellsInfo` は、2 秒たっても返らないクエリをもう 1 回送り、2 つのうち先に返った結果を使う
  (`Wait-TaskResult`)。全体の上限は従来どおり 10 秒。
  先に送ったクエリは取り消さない (L860-GL では、残したままでも後続のクエリは妨げられなかった)。
- 応答に 2 秒以上かかるモデムでも最初の応答を 10 秒まで待つが、その場合は毎回クエリが 1 つ余分に送られる。
  クエリを 1 つずつしか処理しないモデムでは次の取得が遅れる可能性がある。L860-GL 以外では確認していない。
- 実機 (L860-GL) で確認したのは、通常の取得と、再送を強制して 2 つのクエリを同時に出した場合 (20 回ずつ、すべて正常)。
  本当に応答が返らなかったときに再送で回復する動作は、発生がまれなため実機ではまだ確認できていない (テストは模擬のタスクで確認)。

## 4. MBIM device service の確認結果

`MobileBroadbandModem.GetDeviceService(<UUID>)` と `OpenCommandSession()` の結果:

| サービス | UUID | GetDeviceService | OpenCommandSession | SupportedCommands |
| --- | --- | --- | --- | --- |
| INTEL_AT_TUNNEL | `da138c64-6515-4893-92b2-a1e1ca7c81ca` | 可 | 可 | 1 |
| INTEL_MUTUAL_AUTHENTICATION | `f85d46ef-ab26-4081-9868-4d183c0a3aec` | 可 | 可 | - |
| INTEL_FIRMWARE_UPDATE | `0ed374cb-f835-4474-bc11-3b3fd76f5641` | 可 | 未確認 | - |
| INTEL_THERMAL_RF | `fdc22af2-f441-4d46-af8d-259fcdde4635` | 可 | 可 | - |
| INTEL_TOOLS | `4ada4962-b988-46c3-87a7-97f20f994abb` | 例外 (未対応) | - | - |
| BASIC_CONNECT_EXTENSIONS | `3d01dcc5-fef5-4d05-0d3a-bef7058e9aaf` | 可 | `0x80070015` | 2,3,4,5,6,7,8,9,11,12,15 |

- `DeviceInformation.DeviceServices` は null を返すが、GUID 指定の `GetDeviceService()` では取得できる。
- `OpenDataSession()` はどのサービスも `0x80070045` で失敗する (未使用)。
- Intel サービスの UUID は [libmbim `mbim-uuid.c`](https://github.com/linux-mobile-broadband/libmbim/blob/main/src/libmbim-glib/mbim-uuid.c) より。

## 5. Intel AT Tunnel 経由の AT+XMCI (採用)

### プロトコル

- libmbim 1.34 で追加された `MBIM_SERVICE_INTEL_AT_TUNNEL`
  ([libmbim NEWS](https://github.com/linux-mobile-broadband/libmbim/blob/main/NEWS),
  [Ubuntu bug #2121842](https://bugs.launchpad.net/ubuntu/+source/libmbim/+bug/2121842))。
- CID 1 (`AT_COMMAND`) に **SET** で `"<AT コマンド>\r\n"` の ASCII バイト列を送ると、
  応答 (`...\r\nOK\r\n` など) が ASCII バイト列で返る
  ([mbimcli-intel-at-tunnel.c](https://github.com/linux-mobile-broadband/libmbim/blob/main/src/mbimcli/mbimcli-intel-at-tunnel.c))。
- 実機で `ATI` → `".Built@Aug-27-2024:18:22:53"` / `OK`、所要時間は 1 回 1 秒未満。

### AT+XMCI の応答

[L860-GL AT Command User Manual p.167](https://www.manualslib.com/manual/1655076/Fibocom-L860-Gl.html?page=167)

```text
AT+XMCI=?  ->  +XMCI: (0,1)
AT+XMCI=1  ->  (AT+XMCI=0 も同じ形式)
+XMCI: 4,440,50,"0x8AA8","0x0558E901","0x019F","0x0000170C","0x00005D5C","0xFFFFFFFF",61,20,19,"0x00000002","0x00000000"
+XMCI: 5,000,000,"0xFFFE","0xFFFFFFFF","0x0184","0x00009F8A","0xFFFFFFFF","0xFFFFFFFF",31,15,255,"0x7FFFFFFF","0x00000000"
...
OK
```

フィールド: `TYPE, MCC, MNC, TAC, CI, PCI, DLEARFCN, ULEARFCN, PATHLOSS, RSRP, RSRQ, RSSNR, TA, CQI`

- TYPE 4 = LTE サービングセル、5 = LTE 近隣セル。`0xFFFFFFFF` は値なし。
- 近隣セルは PCI / EARFCN / RSRP / RSRQ のみ有効 (TAC=`0xFFFE`, CI=`0xFFFFFFFF`, RSSNR=255)。
- 同時刻の WinRT サービングセル情報と照合し、各値が一致することを確認した
  (CI `0x0558E901`=89712897, PCI `0x019F`=415, EARFCN `0x170C`=5900, RSRP/RSRQ インデックスが同値)。
  → **RSRP / RSRQ は WinRT と同じ 3GPP 36.133 インデックス**で、`Convert-RsrpIndex` / `Convert-RsrqIndex` で変換できる。
- RSSNR の単位は未確認 (6. 参照)。

### XMCI=0 と XMCI=1

- `<meas>`=0: 取得済みの測定情報をすべて返す。`<meas>`=1: サービングセルを新たに測定してから返す (マニュアル p.168)。
- 実測では `AT+XMCI=0` は約 0.06 秒で返る。`AT+XMCI=1` は通常 0.5 秒程度だが、
  弱電界 (B41, RSRP -115 dBm 付近) で **10 秒以上応答しない**ことが再現した (他のコマンドは同時刻でも 0.06 秒)。
- 近隣セル一覧が目的なので、実装では `AT+XMCI=0` を使う。

### 実装

| ファイル | 内容 |
| --- | --- |
| `src/infrastructure/Modem.ps1` | `Find-ModemAtChannel`: 起動時に AT の経路 (Intel AT Tunnel など) を探す。`Invoke-ModemAtCommand`: 1 つのセッションで複数コマンドを順に送り、`@{ コマンド = 応答文字列 }` を返す |
| `src/domain/CellMeasurement.ps1` | `ConvertFrom-XmciResponse`: `+XMCI:` 行をセルのオブジェクトに変換 |
| `src/domain/ModemStatus.ps1` | `+MTSM` / `+XCESQ` / `+XLEC` / `+XACT` の応答パーサー |
| `src/domain/AtProfile.ps1` | ベンダー別のコマンドセット (Intel は `AT+XMCI=?` の応答で判定) と、応答から近隣セル・温度・RSSNR・CA へのまとめ |
| `src/application/Snapshot.ps1` | `Initialize-ModemAt`: 起動時に経路とコマンドセットを判定。`Get-AtStatus`: 毎回の更新で近隣セル・温度・RSSNR・CA を取得。`Get-ModemSummary`: 有効 LTE バンドを起動時に 1 回取得 |
| `src/presentation/Frame.ps1` | `LTE bands` 行、`Temp / RSSNR / CA` 行、Neighbors セクションの表示。RSSNR (`SNR`) と温度 (`Temp`) は History にもグラフ表示 |

- PowerShell は CsWinRT の `IBuffer` を引数・戻り値として正しく扱えない
  (`WinRT.IInspectable` から `IBuffer` への変換で失敗する) ため、
  `SendSetCommandAsync` / `ResponseData` / `ToArray` はリフレクション経由で呼んでいる。
- 1 コマンドのタイムアウトは 3 秒。タイムアウトしたらそのセッションの残りのコマンドは送らず `$null` にする。
  プロセスが AT Tunnel を使い始めた直後に応答が 1 回返らないことがあったため、起動時の判定だけはタイムアウト時に 1 回再送する。
  毎回の更新では `AT+MTSM=1`, `AT+XCESQ?`, `AT+XLEC?`, `AT+XMCI=0` の順に送る (XMCI を最後にして、詰まっても他の値は残す)。
- 取得できなかった値は `n/a`、近隣セルは `(unavailable: <理由>)` と表示し、サービングセルの表示は継続する。
  AT で近隣セルが取れなかったときは WinRT の `NeighboringCellsLte` を使う (L860-GL では常に 0 件なので `unavailable` のまま)。
- CSV (`-CsvPath`) には温度・RSSNR・CA (セル数・帯域幅・SCell) も出力する (列は `src/application/SnapshotLog.ps1` 参照)。近隣セルは出力していない。
- History のグラフは RSRP / RSRQ / SNR / RX / TX / Temp。TUI では `1`〜`6` で個別に、`g` で全部をまとめて表示・非表示を切り替える。
  初期状態は RSRP / RSRQ / SNR のみ表示 (画面の高さを節約するため)。取得できなかった値はグラフ上で空白になる。
  RX / TX は対数スケール。上限・下限は表示中の正の値を挟む 10 の累乗で自動調整 (最低 1 桁幅、下限は 100 B/s 以上。計測の分解能は 0.1 KB/s = 102.4 B/s)。0 と下限未満は最下段に描く。
  RX / TX の値 (Network 行、グラフの軸・統計) は B/s に換算し SI 接頭辞 (k / M / G、1000 倍ごと) で表示する。CSV の `RX_KBps` / `TX_KBps` は従来どおり KB/s (1 KB = 1024 B)。

## 6. AT Tunnel で取れるその他の値 (マニュアル V3.2.3 で確認)

出典: FIBOCOM L860 AT Commands User Manual V3.2.3 (254 ページ)。実測は 2026-09-24、読み取り系コマンドのみ。

| コマンド | 実測応答 | マニュアルの定義 | 解釈 | 表示 |
| --- | --- | --- | --- | --- |
| `AT+MTSM=1` (4.2.4, p.51) | `+MTSM: 52` | `<Report>`=1: 現在温度を 1 回報告。`<Temp>` -40〜125、単位は摂氏 | モデム温度 52℃ (確定)。`<Report>`=6 で BBIC、7 で RF の温度 (未試行) | `Temp` |
| `AT+XLEC?` (9.1.16, p.172-173) | `+XLEC: 0,2,3,5,BAND_LTE_18,0,0,0,0` | `<n>,<no_of_cells>,[<bandwidth>[,...]]`。`no_of_cells`: 0=LTE 以外、1=PCell のみ、2〜5=SCell あり。`bandwidth`: 0=1.4 / 1=3 / 2=5 / 3=10 / 4=15 / 5=20 MHz, 255=無効 | CA で 2 セル、10 MHz + 20 MHz (確定)。`BAND_LTE_18,0,0,0,0` はマニュアルに記載なし (PCell のバンドと推測) | `CA` |
| `AT+XCESQ?` (9.1.19, p.177-179) | `+XCESQ: 0,99,99,255,255,19,58,11,255,255,255,255` | `<n>,<rxlev>,<ber>,<rscp>,<ecno>,<rsrq>,<rsrp>,<rssnr>,...`。範囲は rsrq 0-34, rsrp 0-97, **rssnr -100〜100** (255=不明) | rsrq/rsrp は 3GPP インデックス。**rssnr の単位はマニュアルに記載なし**。0.5 dB 刻みと推定 (11 → 5.5 dB) | `RSSNR` (dB, 推定) |
| `AT+XACT?` | `+XACT: 4,2,1,1,2,4,5,8,101,...,171` | **マニュアルに記載なし** | ModemManager の実装で確認: 許可 RAT 4 = 3G+4G、優先 2 = 4G、バンドは <100 = UMTS、101〜299 = 100 + LTE バンド (詳細は [downgrade-detection.md](downgrade-detection.md)) | `RAT` / `LTE bands` |
| `AT+XMCI` (9.1.13, p.167-169) | 5. 参照 | フィールド名のみで、RSRP / RSRQ / RSSNR / PATHLOSS_LTE / CQI の単位の定義はない。例では RSSNR=-24 | RSSNR の単位は未確定 | Neighbors |
| `AT+XCCINFO?` (9.1.14, p.169-170) | `+XCCINFO: 0,440,51,"0558E901",3,118,"FFFF",1,"FF","8AA8",0,...` | `<mode>,<mcc>,<mnc>,<ci>,<rat>,<band_info>,<lac>,<area_type>,<rac>,<tac>,...`。個別の値の定義はなし。例: `rat`=3, `band_info`=103 | `band_info` は 100 + LTE バンド番号と推測 (118=B18、実機の EARFCN 5900=B18 と一致) | なし |
| `AT+CSQ` | `+CSQ: 15,4` / `+CSQ: 16,5` / `+CSQ: 0,2` | 3GPP TS 27.007 (-113 + 2×rssi dBm) | **RSSI ではなく RSRP の読み替え**。同時刻の RSRP (XCESQ) が -83 / -81 / -115 dBm のとき、CSQ 換算は -83 / -81 / -113 dBm (下限張り付き) で一致 | なし (新しい情報がないため) |

- rssnr (SINR) は XCESQ で -100〜100 の範囲とされるが、単位 (dB / 0.5 dB など) は記載がない。
  **0.5 dB 刻みと推定し、生値 ÷ 2 を dB として表示している** (未確定)。根拠:
  - ModemManager の XMM プラグイン (`src/plugins/xmm/mm-modem-helpers-xmm.c` の `rssnr_level_to_rssnr()`) が
    -100〜100 の値を `/ 2.0` して dB として扱っている (単位のコメントはなく、一次資料ではない)。
  - 範囲 -100〜100 は 1 dB 刻みだと ±100 dB で SINR として広すぎる。0.5 dB 刻みなら ±50 dB。
  - マニュアル XMCI の例 RSSNR=-24 は、1 dB 刻みだと LTE が接続を保てる下限 (-6〜-10 dB 程度) を大きく下回る。
  - 0.1 dB 刻みは RSRQ と矛盾する: 実測 (rssnr 11 / RSRQ -10.5〜-10 dB, rssnr 19 / RSRQ -10〜-9.5 dB) で
    SINR 1.1 / 1.9 dB とすると、2 ポート時の RSRQ 上限 `1 / (4 + 12/SINR)` が約 -11 dB になり実測を説明できない。
    1 dB 刻みと 0.5 dB 刻みはどちらも負荷 40〜70% 程度で説明でき、実測からは区別できない。
  - 確定させるには、弱電界 (RSRP -110 dBm 以下) で接続を保ったまま生値が -20 前後になるかを確認する
    (1 dB 刻みでは通信できない値になる)。
- RSSI は CSQ からは得られない (上表)。`netsh mbn show interfaces` の `RSSI / RSCP` (MBIM の信号状態) は
  同時刻に `6 (-101 dBm)` で、CSQ (`0`) とも異なる。
- `AT+GTCCINFO?`, `AT+GTCAINFO?`, `AT+XTEMP=?`, `AT+GTSENRDTEMP=?`, `AT+XTAMR=?`,
  `AT+XCMODE?`, `AT+XBANDSEL?` はこのモデムでは `ERROR`。

## 再確認手順

```powershell
. .\src\infrastructure\WinRt.ps1
. .\src\infrastructure\Modem.ps1
Import-WinRtProjection (Join-Path (Get-Location) 'lib')
$m = Get-DefaultModem
@((Get-ModemCellsInfo $m.CurrentNetwork).NeighboringCellsLte).Count  # WinRT (現状 0)
$ch = Find-ModemAtChannel $m $null  # Intel AT Tunnel
Invoke-ModemAtCommand $m $ch @('AT+XMCI=0', 'AT+MTSM=1', 'AT+XCESQ?', 'AT+XLEC?', 'AT+XACT?')
```
