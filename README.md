# wwan-probe

Fibocom L860-GL 向けの LTE 信号監視ツール (TUI) です。
Windows の PowerShell 7.4 以降で動作します。

## 機能

- **リアルタイム監視**: RSRP, RSRQ, SNR, 送受信レート, モデム温度の履歴グラフ表示
- **詳細情報の取得**: CA (キャリアアグリゲーション) 情報、利用可能な LTE バンド、RAT 情報の取得
- **2G/3G ダウングレード検知**: 偽基地局対策として、国内では利用されない 2G/3G へのダウングレードを検知して警告 (詳細は `docs/downgrade-detection.md` 参照)
- **近隣セル情報の表示**: MBIM の Intel AT Tunnel (`AT+XMCI`) 経由で近隣セル (Neighbor cells) の情報を取得・表示 (詳細は `docs/neighbor-cells.md` 参照)
- **CSV ログ出力**: 取得した情報を CSV ファイルに記録可能

## 必須要件

- **OS**: Windows 10 / 11
- **PowerShell**: バージョン 7.4 以降 (Windows PowerShell 5.1 では動作しません)
- **対象モデム**: Fibocom L860-GL (Intel XMM 7560 ベース) などの互換モデム

## セットアップ

PowerShell 7.4+ がインストールされている環境で、初回のみ WinRT プロジェクション (CsWinRT) の DLL をダウンロード・展開する必要があります。

```powershell
.\setup.ps1
```

これにより、`.\lib` ディレクトリに実行に必要な DLL (`WinRT.Runtime.dll`, `Microsoft.Windows.SDK.NET.dll`) が配置されます。

## 使い方

以下のスクリプトを実行して TUI モニターを起動します。

```powershell
.\lte_monitor.ps1 [-Interval <秒>] [-Count <回数>] [-CsvPath "log.csv"]
```

### 引数 (オプション)

- `-Interval`: 測定間隔 (秒)。デフォルトは `0` で、バックトゥバックサンプリング (カウンターの関係で約1秒間隔) を行います。
- `-Count`: 測定回数。デフォルトは `0` で無限ループします。
- `-CsvPath`: 指定すると、結果を CSV ファイルにログ出力します。

### TUI での操作

TUI (Text User Interface) 画面起動中は以下のキー操作が可能です。

- `q` / `Esc` / `Ctrl+C` : 終了
- `p` : 一時停止 / 再開
- `r` : すぐに更新 (リフレッシュ)
- `1`〜`6` : 各ヒストリーグラフの表示・非表示 (1:RSRP, 2:RSRQ, 3:SNR, 4:RX, 5:TX, 6:Temp)
- `g` : 全グラフの一括表示切り替え
- `↑` / `↓` : ヒストリーグラフの高さ (行数) を増減 (1〜10 行、既定 2 行。1 行あたり 8 段階)

（標準入出力がリダイレクトされている場合は、プレーンテキストによる逐次出力にフォールバックします）

## ディレクトリ構成 (`src/`)

本ツールは Domain-Driven Design (DDD) 風のレイヤードアーキテクチャを採用しており、`src/` 以下がそれぞれの責務に分割されています。
(上位レイヤーのスクリプトは下位レイヤーを呼び出しますが、逆はありません)

- **`domain/`** : ドメインモデルとルール (`Signal.ps1`, `Downgrade.ps1`, `CellMeasurement.ps1` など)
- **`infrastructure/`** : ハードウェアや OS との通信 (`Modem.ps1`, `WinRt.ps1`, `PerfCounter.ps1`, `CsvFile.ps1` など)
- **`application/`** : アプリケーションロジック (`MonitorSession.ps1`, `Snapshot.ps1` など)
- **`presentation/`** : ユーザーインターフェース (`TuiMonitor.ps1`, `ConsoleRenderer.ps1`, `Gauge.ps1` など)

## ドキュメント

より詳細な技術情報については `docs/` 以下の Markdown ファイルを参照してください。

- [2G/3G ダウングレード検知](docs/downgrade-detection.md)
- [近隣セル (Neighbors) の取得方法](docs/neighbor-cells.md)
