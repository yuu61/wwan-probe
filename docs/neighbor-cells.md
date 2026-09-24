# 近隣セル (Neighbors) の取得方法

調査日: 2026-09-24
対象: Fibocom L860-GL (FW `18601.5001.00.01.17.30_KD`) / Windows 11 Pro 26200 / KDDI (au) 回線

## 結論

- L860-GL は WinRT (`GetCellsInfoAsync()`) では近隣セルを返さない (1.)。
- AT ポート (COM) は ModemControl ドライバに占有されていて開けない (2.)。
- **MBIM の Intel AT Tunnel サービス経由で `AT+XMCI=1` を送ると近隣セルを取得できる** (5.)。
  COM ポートもドライバの無効化も不要。TUI の Neighbors セクションはこの経路で実装している。

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
  `Convert-RsrpIndex` / `Convert-RsrqIndex` はこのモデム実機の挙動に合わせたもの。
- CID 11 を device service として直接送る案は、`BASIC_CONNECT_EXTENSIONS` の
  `OpenCommandSession()` が `0x80070015` (ERROR_NOT_READY) で失敗するため不可 (OS が占有していると見られる)。

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
AT+XMCI=1  ->
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
- RSSNR の単位は未確認 (表示には使っていない)。

### 実装

| ファイル | 内容 |
| --- | --- |
| `src/infrastructure/Modem.ps1` | `Invoke-ModemAtCommand`: AT Tunnel で AT コマンドを送り応答文字列を返す |
| `src/domain/CellMeasurement.ps1` | `ConvertFrom-XmciResponse`: `+XMCI:` 行を LTE セルのオブジェクトに変換 |
| `src/application/Snapshot.ps1` | `Get-LteNeighbor`: `AT+XMCI=1` の近隣セルを snapshot の `Neighbors` にする |
| `src/presentation/Frame.ps1` | Neighbors セクションの表示 |

- PowerShell は CsWinRT の `IBuffer` を引数・戻り値として正しく扱えない
  (`WinRT.IInspectable` から `IBuffer` への変換で失敗する) ため、
  `SendSetCommandAsync` / `ResponseData` / `ToArray` はリフレクション経由で呼んでいる。
- AT 取得に失敗してもサービングセルの表示は継続し、Neighbors に `(unavailable: <理由>)` を表示する。
- 近隣セルは CSV には出力していない。

## 再確認手順

```powershell
. .\src\infrastructure\WinRt.ps1
. .\src\infrastructure\Modem.ps1
Import-WinRtProjection (Join-Path (Get-Location) 'lib')
$m = Get-DefaultModem
@((Get-ModemCellsInfo $m.CurrentNetwork).NeighboringCellsLte).Count  # WinRT (現状 0)
Invoke-ModemAtCommand $m 'AT+XMCI=1'                                 # AT Tunnel
```
