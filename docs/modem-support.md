# 対応モデム (L860-GL 以外)

調査日: 2026-09-24

**実機で動作を確認したのは Fibocom L860-GL (Intel XMM 7560) だけ**です。
それ以外のモデムは、公開されている仕様書・マニュアル・オープンソース実装をもとに「仕様上は動く」状態にしたもので、
実機では確認していません。動かなかった場合は、画面の `AT:` 行と `(unavailable: ...)` の理由を添えて報告してください。

## 全体の構成

取得する情報は 2 系統あります。

| 系統 | 取れる値 | 対象 |
| --- | --- | --- |
| WinRT (`MobileBroadbandModem` / `GetCellsInfoAsync()`) | 事業者、DataClass、LTE サービングセル (RSRP / RSRQ / EARFCN / PCI / Cell ID / TAC / TA)、LTE 近隣セル (モデムが報告する場合)、通信量 | Windows が認識する全 MBIM モデム |
| AT コマンド (ベンダー固有) | 温度、SINR、CA、近隣セル、2G/3G セル、RAT / バンド設定 | 下表の AT 経路とコマンドセットに対応するモデム |

AT が使えなくても、WinRT の範囲 (サービングセル・履歴グラフ・ハンドオーバー履歴・CSV) は動きます。
その場合は `AT: unavailable (...)` と表示し、温度・SINR・CA は `n/a` になります。

## WinRT の RSRP / RSRQ の単位

MBIM の仕様 ([MB base stations information query support](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/mb-base-stations-information-query-support)) では、
`MBIM_LTE_SERVING_CELL_INFO` / `MBIM_LTE_MRL_INFO` の RSRP は **-140〜-44 dBm**、RSRQ は **-20〜-3 dB** です。
一方 L860-GL は **3GPP TS 36.133 のインデックス値** (RSRP 0〜97、RSRQ 0〜34) を返します
(詳細は [neighbor-cells.md](neighbor-cells.md) の 3.)。

以前はインデックス値しか受け付けず、仕様どおり dBm を返すモデムではサービングセルが表示されませんでした。
現在は `ConvertFrom-WinRtRsrp` / `ConvertFrom-WinRtRsrq` (`src/domain/Signal.ps1`) で両方を受け付けます。
範囲が重ならないので区別できます。範囲外の値や `0xFFFFFFFF` は「値なし」として扱います。

近隣セルは、AT で取れなかった場合に WinRT の `NeighboringCellsLte` を使います
(L860-GL は常に 0 件ですが、報告するモデムもあり得ます)。

## AT コマンドの経路

起動時に、次の順で `AT` を送り、`OK` が返った最初の経路を使います (`Find-ModemAtChannel`, `src/infrastructure/Modem.ps1`)。

| 経路 | MBIM サービス UUID | CID | MBIM コマンド種別 | 要求 / 応答の形式 | 想定モデム |
| --- | --- | --- | --- | --- | --- |
| Intel AT Tunnel | `da138c64-6515-4893-92b2-a1e1ca7c81ca` | 1 | SET | `"<AT>\r\n"` / 応答テキスト | Intel XMM (Fibocom L860-GL で**実機確認済み**) |
| Fibocom AT | `ffffffff-abca-4b11-a4e2-f2fc87f94488` | 1 | SET | `"<AT>\r\n"` / 応答テキスト | Fibocom (libmbim に Fibocom 社員が追加) |
| Compal AT | `a2a32a97-cab1-4f57-9ae1-451c74dda957` | 1 | QUERY | `"<AT>\r\n"` / 応答テキスト | Compal 製モジュール |
| Quectel QDU | `6427015f-579d-48f5-8c54-f43ed1e76f83` | 8 | SET | UINT32 種別 (0 = AT) + `"<AT>"` / UINT32 状態 (0 = OK) + 応答テキスト | Quectel (Qualcomm 系) |
| シリアル (COM) ポート | - | - | - | `"<AT>\r"` / `OK` / `ERROR` 行まで | `-AtPort COMx` を指定したとき |

- 出典はすべて libmbim:
  [data/mbim-service-*.json](https://github.com/linux-mobile-broadband/libmbim/tree/main/data) (メッセージ形式)、
  [mbim-uuid.c](https://github.com/linux-mobile-broadband/libmbim/blob/main/src/libmbim-glib/mbim-uuid.c) (UUID)、
  [mbim-cid.h](https://github.com/linux-mobile-broadband/libmbim/blob/main/src/libmbim-glib/mbim-cid.h) (CID)、
  mbimcli の `mbimcli-{fibocom,compal,quectel}.c` (要求の組み立て方)。
  Fibocom / Compal / Quectel の AT コマンドは libmbim 1.32、Intel AT Tunnel は 1.34 で追加された。
- Quectel QDU はファームウェア更新用のサービスです。本ツールは CID 8 (COMMAND) 以外は送りません。
  応答テキストに最終結果 (`OK` / `ERROR`) が含まれるかは資料に記載がないため、含まれない場合は状態値から補っています。
- Windows がこれらのサービスをアプリに開放するかどうかは、モデムのファームウェアとドライバ次第です
  (L860-GL では `GetDeviceService()` と `OpenCommandSession()` が使えることを確認済み)。
- COM ポートは、ベンダードライバが AT ポートを公開している場合に使えます
  (例: FM350-GL の `MD AT` ポート ([fibocom-connect-fm350](https://github.com/prusa-dev/fibocom-connect-fm350) が使用)、Quectel の `Quectel USB AT Port`)。
  L860-GL の COM ポートは ModemControl ドライバが占有しているため開けません ([neighbor-cells.md](neighbor-cells.md) の 2.)。
- 実機 (L860-GL) で、プロセスが AT Tunnel を使い始めた直後に応答が 1 回返らない (タイムアウトする) ことがありました。
  起動時の判定 (`AT` とプローブ) はタイムアウトしたら 1 回だけ再送します。
- 経路とコマンドセットの判定は**起動時に 1 回だけ**です。起動時にモデムが応答しなかった場合は、再起動するまで AT の値は取れません
  (Intel AT Tunnel の場合を除く。下記)。
- AT の経路がないモデムでは、各 MBIM サービスを 1.5 秒のタイムアウト (と 1 回の再送) で順に試すため、起動に数秒かかることがあります。
  画面には `AT: unavailable (no AT channel (4 MBIM services tried))` と表示し、各サービスの失敗理由は `Summary.At.Tried` に残します。

## AT コマンドセット (プロファイル)

経路が見つかったら、次の順でプローブを送り、`OK` が返った最初のプロファイルを使います (`src/domain/AtProfile.ps1`)。
同じ Fibocom の経路でも、Intel 系 (L850 / L860) と MediaTek 系 (FM350) ではコマンドが異なるため、モデル名ではなく応答で判定します。

| プロファイル | プローブ | 毎回の取得 | 起動時 (RAT / バンド) | 近隣セル・2G/3G の出典 | 状態 |
| --- | --- | --- | --- | --- | --- |
| Intel XMM | `AT+XMCI=?` | `AT+MTSM=1`, `AT+XCESQ?`, `AT+XLEC?`, `AT+XMCI=0` | `AT+XACT?` | `XMCI` | **L860-GL で実機確認済み** |
| Quectel | `AT+QENG=?` | `AT+QTEMP`, `AT+QCAINFO`, `AT+QSINR`, `AT+QENG="servingcell"`, `AT+QENG="neighbourcell"` | `AT+QNWPREFCFG="mode_pref"` / `"gw_band"` / `"lte_band"` / `"nr5g_band"` | `QENG` | 仕様のみ |
| Fibocom GT | `AT+GTCAINFO=?` | `AT+GTSENRDTEMP=1`, `AT+GTCAINFO?`, `AT+GTCCINFO?` | `AT+GTACT?` | `GTCCINFO` | 仕様のみ |

- プローブはテストコマンド (`=?`) で、登録状態に左右されない。L860-GL は `AT+XMCI=?` に `+XMCI: (0,1)` を返す。
- Intel AT Tunnel は Intel XMM 系にしかないため、この経路でプローブが失敗した (応答が落ちた) 場合も Intel のコマンドセットを使う
  (プロファイル導入前と同じく、毎回の取得で個々のコマンドの失敗を許容する)。
- どのプロファイルにも一致しない場合は `AT: unavailable (unsupported AT command set on ...)` と表示し、WinRT の値だけを使います。

### Quectel

出典: [Quectel RG50xQ&RM5xxQ Series AT Commands Manual V1.2](https://quectel.com/content/uploads/2024/05/Quectel_RG50xQRM5xxQ_Series_AT_Commands_Manual_V1.2.pdf)
(5.12 `QSINR`、5.20 `QENG`、5.21 `QCAINFO`、5.25 `QNWPREFCFG`、12.5 `QTEMP`)。パーサーは `src/domain/QuectelStatus.ps1`。

| 値 | 取得元 | 解釈 |
| --- | --- | --- |
| 近隣セル | `QENG="neighbourcell"` | LTE モードの `"neighbourcell intra"/"inter"` は `<earfcn>,<PCID>,<RSRQ>,<RSRP>` の順、WCDMA モードの `"neighbourcell","LTE"` は `<RSRP>,<RSRQ>` の順 (逆なので注意)。RSRP / RSRQ は dBm / dB。`-` は無効 |
| 2G/3G | `QENG` の `"WCDMA"` / `"GSM"` のサービングセル・近隣セル | `Get-DowngradeFinding` に渡す |
| SINR | `QCAINFO` の PCC `<RSSNR>` (dB、-10〜30)。なければ `QSINR` の PRX (dB、LTE のとき) | `QENG` の `<SINR>` は使わない: RM5xx のマニュアルの換算式は `Y = 1/5 × X × 10 - 20` だが、EC2x 系は 1/5 dB 単位 (`Y = X/5 - 20`) とされていて食い違い、機種を特定できないため (EC2x 系の定義は検索結果の要約で確認しただけで、マニュアル本文は未確認) |
| CA | `QCAINFO` (帯域幅はリソースブロック数 6/15/25/50/75/100 = 1.4〜20 MHz) | PCC と、`<scell_state>` が 0 (deconfigured) 以外の SCC を数える。`QCAINFO` が何も返さないときは `QENG` の LTE サービングセルから「1 セル」とする (`<DL_bandwidth>` は XLEC と同じ 0〜5 のインデックス) |
| 温度 | `QTEMP` | 全センサーのうち最も高い値 (℃)。RM5xx は 1 行 1 センサー (`"<sensor>","<temp>"`)。EM12 / EG25 系は `<pmic>,<xo>,<pa>` の 1 行とされる (Quectel フォーラムの例 `+QTEMP: 30,28,27` による。マニュアル本文は未確認)。範囲外 (-40〜125 以外) は無視 |
| RAT / バンド | `QNWPREFCFG` | `mode_pref` の `AUTO` は「WCDMA & LTE & 5G NR」なので `3G+4G+5G (AUTO)` と表示し、ダウングレード可能と警告する。優先 RAT は取得しない |

- `QENG="servingcell"` は EN-DC のとき `"servingcell",<state>` 行と `"LTE",...` 行に分かれ、フィールド位置が 2 つずれる。
  RAT 名のトークンを基準に位置を数えて両方に対応している。`<cellID>` と `<TAC>` は 16 進。
- `QNWPREFCFG` は RM5xx / RG50x など新しい系列のコマンド。EM05 / EM12 などの旧系列 (`AT+QCFG="nwscanmode"` 等) には対応していない (RAT 行は `n/a`)。

### Fibocom GT (FM350-GL など MediaTek 系)

出典: [FM350 AT Commands User Manual V2.10](https://www.minipc.de/support_db/support_files/Fibocom_FM350_AT%20Commands%20User%20Manual_V2.10.pdf)
(11.1.14 `GTACT`、11.1.15 `GTCCINFO`、11.1.16 `GTCAINFO`、18.3 `GTSENRDTEMP`)。パーサーは `src/domain/FibocomStatus.ps1`。

| 値 | 取得元 | 解釈 |
| --- | --- | --- |
| 近隣セル・2G/3G | `GTCCINFO?` | `+GTCCINFO:` の後に接頭辞なしの行が並ぶ。`<IsServiceCell>` 1 = サービング、2 = 近隣。`<rat>` 2 = WCDMA、4 = LTE、9 = NR。RSRP / RSRQ は 3GPP インデックス (RSRP 0 は「-140 dBm 未満または検出不可」なので値なし扱い)。TAC / Cell ID は 16 進、EARFCN / PCI は 10 進 (マニュアルに記載がないため、実機出力 `1,4,262,1,05D5,0019BF801,1300,358,103,100,13,60,60,22` ([OpenWrt フォーラム](https://forum.openwrt.org/t/fibocom-fm350-gl-support/142682/327)) と fibocom-connect-fm350 の実装で確認) |
| SINR | `GTCCINFO` の LTE サービングセル `<rssnr_value>` | -100〜100 で **0.5 dB 刻み** とマニュアルに明記 (255 = 不明) |
| CA | `GTCAINFO?` | `PCC:<band>,<pci>,<earfcn>,<dl_bw>,...` と `SCC<n>:<state>,<ul>,<band>,<pci>,<earfcn>,<dl_bw>,...`。帯域幅はリソースブロック数。`<band>` 101〜199 (LTE) のみ数え、NR (501〜) は除く |
| 温度 | `GTSENRDTEMP=1` (センサー 1 = `soc_max`) | マニュアルに単位の記載がない。FM350 用の既存ツール ([fm350-util](https://github.com/wargio/fm350-util)、fibocom-connect-fm350) がいずれも 1000 で割っているので m℃ とみなす |
| RAT / バンド | `GTACT?` | `<rat>` 1 = UMTS、2 = LTE、4 = LTE/UMTS、10 = 自動 (照会すると 20)、14 = NR、16 = NR/WCDMA、17 = NR/LTE、20 = NR/WCDMA/LTE。優先 2 = WCDMA、3 = LTE、6 = NR。バンドは 1〜99 = UMTS、101〜199 = 100 + LTE、`50` + n = NR n (501 = n1、5078 = n78、50257 = n257)。XACT とは符号が異なる |

### 対応していないもの

- **QMI over MBIM** (`d1a30bc2-f97a-6e43-bf65-c7e24fb0f0d3`、Qualcomm 系モデムの標準的な拡張): QMI のクライアント ID の確保・解放が必要で、
  実機なしで扱うと解放漏れのリスクがあるため実装していない。Sierra Wireless (EM7xxx) や Foxconn など、AT の経路が公開されていない
  Qualcomm 系モデムはこれがないと WinRT の値だけになる。
- **5G NR のサービングセル表示**: NR セルは 2G/3G 判定から除外する (ダウングレード扱いしない) だけで、画面には LTE のみ表示する。
- **旧 Quectel 系列の RAT 設定** (`AT+QCFG`)。
- **MediaTek 系の MBIM 経由 AT**: libmbim に該当サービスが見当たらない。Fibocom AT サービスで届く可能性はあるが未確認。
