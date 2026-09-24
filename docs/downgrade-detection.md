# 2G/3G ダウングレード検知

作成日: 2026-09-24
対象: Fibocom L860-GL (Intel XMM 7560) / KDDI (au) 回線

## 背景

4G/5G を妨害電波で使えなくし、端末を 2G/3G に落として偽基地局 (IMSI キャッチャー等) に
接続させる攻撃がある。2G は相互認証がなく、3G も偽基地局との組み合わせで悪用され得る。

日本では 2G は運用されておらず、3G も全キャリアで終了している
(au 2022-03-31、ソフトバンク 2024-07-31、ドコモ FOMA 2026-03-31)。
**国内で 2G/3G のセルに接続・検出された時点で異常**とみなせる (海外ローミング中は除く)。

## このモジュールの状態

`AT+XACT?` → `+XACT: 4,2,1,1,2,4,5,8,101,...`

| 項目 | 値 | 意味 |
| --- | --- | --- |
| 許可 RAT (AcT) | 4 | **3G+4G** |
| 優先 RAT | 2 | 4G |
| 3G バンド | 1,2,4,5,8 | UMTS B1/B2/B4/B5/B8 が有効 |
| 2G バンド | なし | `AT+XACT=?` の候補にも 2G バンド (>300) がない。WinRT `DataClasses` にも GPRS/EDGE がない → 2G 非対応 |

- XACT の書式はマニュアルに記載がなく、ModemManager の実装
  ([mm-modem-helpers-xmm.c](https://gitlab.freedesktop.org/mobile-broadband/ModemManager/-/blob/main/src/plugins/xmm/mm-modem-helpers-xmm.c))
  に従って解釈している:
  - AcT / 優先 AcT: 0=2G, 1=3G, 2=4G, 3=2G+3G, 4=3G+4G, 5=2G+4G, 6=2G+3G+4G (3 番目のフィールドは無視)
  - バンド: <100 = UTRA バンド番号、101〜299 = 100 + E-UTRA バンド番号、>300 = GSM (MHz)
- つまり **3G へのダウングレードは設定上起こり得る**。

## 検知ルール (`src/domain/Downgrade.ps1`)

毎回の更新で次を評価する。

| レベル | 条件 | 情報源 |
| --- | --- | --- |
| Alert (赤) | 登録中の DataClass が 2G/3G 系 (Gprs/Edge/Umts/Hsdpa/Hsupa/Cdma*) のみで LTE/NR を含まない | WinRT `RegisteredDataClass` |
| Alert (赤) | GSM/UMTS/TD-SCDMA/CDMA のサービングセルがある | WinRT `GetCellsInfoAsync()` |
| Alert (赤) | AT のセル一覧に GSM/UMTS のサービングセルがある (XMCI では TYPE 0/2) | `AT+XMCI=0` (Quectel は `AT+QENG`、Fibocom GT は `AT+GTCCINFO?`) |
| Warning (黄) | AT のセル一覧に GSM/UMTS の近隣セルがある (XMCI では TYPE 1/3) | 同上 |

- 理由の末尾の `(XMCI)` / `(QENG)` / `(GTCCINFO)` は情報源のコマンド。5G NR のセルはダウングレード扱いしない。
- ベンダー別のコマンドと RAT 設定の読み方は [modem-support.md](modem-support.md) を参照。

- 一度でも検知したら、回数と最後の時刻・理由をセッション中ずっと表示する
  (`Add-DowngradeLog`、瞬間的なダウングレードの見落とし防止)。
  TUI の `R` (統計情報のリセット) でこの履歴も消える。現在のサンプルの Alert / Warning は引き続き表示される。
- 起動時に RAT 設定 (L860-GL は `AT+XACT?`、Quectel は `AT+QNWPREFCFG="mode_pref"`、Fibocom GT は `AT+GTACT?`) を読み、
  2G/3G が許可されていれば `[2G/3G enabled: downgrade possible]` と常時表示する。
  Quectel の `AUTO` は WCDMA を含むため警告対象。

## 表示

```text
 !! 2G/3G DOWNGRADE: registered on Umts/Hsdpa; UMTS serving ch:10900 (XMCI)     <- 赤 (現在)
 !  2G/3G cells visible: UMTS neighbor ch:10900 (XMCI)                           <- 黄 (現在)
 !  2G/3G seen earlier (alert 1 / warning 0 samples), last 2026-09-24 15:00:00 [Alert]: ...  <- 過去
 RAT: 3G+4G (prefer 4G)   2G/3G bands: B1 B2 B4 B5 B8   [2G/3G enabled: downgrade possible]
```

## 制約・未検証

- 実際のダウングレードは再現できていない。判定と表示は模擬データでのみ確認した。
- 2G/3G 接続時に WinRT の `RegisteredDataClass` / `ServingCellsUmts` や XMCI の TYPE 2/3 が
  実際にどう報告されるかは未確認 (本モジュールの UMTS 行は、マニュアルでは `<CI><PSC>` の間のカンマが抜けて
  記載されている。チャネル番号の位置はカンマありとして解釈している)。
- `AT+XMCI=0` はときどき測定結果を 1 行も返さない (`OK` のみ)。近隣セルの Warning はその回は出ない。
- 検知できるのは「2G/3G に落ちた・2G/3G が見える」ことまで。LTE の偽基地局は検知しない。
- 更新間隔の間に起きて戻った短いダウングレードは検知できない。

## 対策の選択肢 (未実施)

`AT+XACT=2` (4G のみ) にすれば 3G へのダウングレード自体を防げる (ModemManager も同コマンドで 4G 専用にする)。
ただし:

- モデムの設定変更であり、永続するか・Windows (WwanSvc) や FirmwareSwitchService に戻されないかは未確認
- 4G 圏外では通信できなくなる (国内では 3G 網がないので実害は小さいと考えられる)
