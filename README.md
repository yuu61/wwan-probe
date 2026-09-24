# wwan-probe

Fibocom L860-GL 向けの LTE 信号監視ツール (TUI) です。
Windows の PowerShell 7.4 以降で動作します。

## 機能

- **リアルタイム監視**: RSRP, RSRQ, SNR, 送受信レート, モデム温度の履歴グラフ表示
- **詳細情報の取得**: CA (キャリアアグリゲーション) 情報、利用可能な LTE バンド、RAT 情報の取得
- **2G/3G ダウングレード検知**: 偽基地局対策として、国内では利用されない 2G/3G へのダウングレードを検知して警告 (詳細は `docs/downgrade-detection.md` 参照)
- **近隣セル情報の表示**: MBIM の Intel AT Tunnel (`AT+XMCI`) 経由で近隣セル (Neighbor cells) の情報を取得・表示 (詳細は `docs/neighbor-cells.md` 参照)
- **ハンドオーバー履歴**: LTE 主セルの変更を検出し、時刻と切り替え先の Cell ID・バンド・PCI などを表示
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
- `h` : ハンドオーバー履歴の詳細一覧 / 通常画面を切り替え。詳細一覧では `↑` / `↓` で新しい / 古い履歴へ移動
- `↑` / `↓` : ヒストリーグラフの高さ (行数) を増減 (1〜10 行、既定 2 行。1 行あたり 8 段階。Temp は常にその 1/2 (切り捨て、最低 1 行))

測定はバックグラウンドで行うため、モデムの応答待ちや通信量の取得中もキー操作できます。
一時停止時に取得中の測定は完了後に反映され、次の自動測定から停止します。取得中の `r` はその測定の完了を待ちます。

ハンドオーバー履歴は通常画面に直近3件、`h` の詳細一覧に最大100件を新しい順で表示します。
各履歴は「その時刻にどのセルへ切り替わったか」を表示します。詳細には検出時刻、切り替え先の PLMN・Cell ID・バンド・PCI・EARFCN・TAC・RSRP を表示します。
履歴と累計件数は起動中のみ保持します。標準出力への逐次出力にも直近3件が含まれます。

判定対象はモデムが返す先頭の LTE 接続セル（本ツールでの主セル）の PLMN と Cell ID の変更です。
CA の副セルの追加・削除、信号強度や TAC だけの変化は数えません。初回取得、取得失敗・圏外・識別情報不明の後は比較基準を設定し直します。
測定間のセル変更を観測するため、セル再選択と通信中のハンドオーバーは区別できず、測定間隔内の切り替えをすべて捕捉できるものではありません。

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
