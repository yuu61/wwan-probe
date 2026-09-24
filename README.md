# wwan-probe

Windows のモバイルブロードバンド (WWAN) モデム向けの LTE 信号監視ツール (TUI) です。
Windows の PowerShell 7.4 以降で動作します。
実機で確認しているのは Fibocom L860-GL だけです。Quectel や Fibocom FM350 などは仕様上の対応です ([`docs/modem-support.md`](docs/modem-support.md) 参照)。

## 機能

- **リアルタイム監視**: RSRP, RSRQ, SNR, 送受信レート, モデム温度の履歴グラフ表示
- **詳細情報の取得**: CA (キャリアアグリゲーション) 情報、利用可能な LTE バンド、RAT 情報の取得
- **2G/3G ダウングレード検知**: 偽基地局対策として、国内では利用されない 2G/3G へのダウングレードを検知して警告 (詳細は [`docs/downgrade-detection.md`](docs/downgrade-detection.md) 参照)
- **近隣セル情報の表示**: モデムの AT コマンド (L860-GL は MBIM の Intel AT Tunnel 経由の `AT+XMCI`) で近隣セル (Neighbor cells) の情報を取得・表示。AT で取れない場合は WinRT が報告する近隣セルを使用 (詳細は [`docs/neighbor-cells.md`](docs/neighbor-cells.md) 参照)
- **複数ベンダーの AT コマンド**: 起動時に AT の経路 (Intel / Fibocom / Compal / Quectel の MBIM サービス、または COM ポート) とコマンドセット (Intel `+X`、Quectel `+Q`、Fibocom `+GT`) を自動判定 (詳細は [`docs/modem-support.md`](docs/modem-support.md) 参照)
- **ハンドオーバー履歴**: LTE 主セルの変更を検出し、時刻と切り替え先の Cell ID・バンド・PCI などを表示
- **GPS / GNSS 表示**: `-Gps` で衛星測位の緯度・経度・高度・精度・速度・方位・HDOP・測位時刻を表示。未測位や取得不能も表示。`-Nmea` で捕捉衛星の一覧 (衛星系ごとに色分け、仰角・方位角・SNR・測位への使用) も表示 (詳細は [`docs/gps.md`](docs/gps.md) 参照)
- **CSV ログ出力**: 取得した情報を CSV ファイルに記録可能

## 必須要件

- **OS**: Windows 10 / 11
- **PowerShell**: バージョン 7.4 以降 (Windows PowerShell 5.1 では動作しません)
- **対象モデム**: Windows が認識する MBIM モデム。温度・SINR・CA・近隣セルなどは AT コマンドに対応したモデムのみ
  - 実機確認済み: Fibocom L860-GL (Intel XMM 7560)
  - 仕様上の対応 (未確認): Intel XMM 系、Quectel (RM5xx など `AT+QENG` 対応機)、Fibocom FM350-GL など `AT+GTCCINFO` 対応機
  - AT が使えないモデムでも、WinRT で取れるサービングセルの情報・履歴・CSV は表示・記録できます

## セットアップ

PowerShell 7.4+ がインストールされている環境で、初回のみ WinRT プロジェクション (CsWinRT) の DLL をダウンロード・展開する必要があります。

```powershell
.\setup.ps1
```

これにより、`.\lib` ディレクトリに実行に必要な DLL (`WinRT.Runtime.dll`, `Microsoft.Windows.SDK.NET.dll`) が配置されます。

## 使い方

以下のスクリプトを実行して TUI モニターを起動します。

```powershell
.\lte_monitor.ps1 [-Interval <秒>] [-Count <回数>] [-CsvPath "log.csv"] [-AtPort COM7] [-Gps] [-Nmea]
```

オプション名は大文字・小文字を区別しません。存在しないオプション (綴りの誤りを含む) を指定するとエラーで終了します。

### 引数 (オプション)

- `-Interval`: 測定間隔 (秒)。デフォルトは `0` で、バックトゥバックサンプリング (カウンターの関係で約1秒間隔) を行います。
- `-Count`: 測定回数。デフォルトは `0` で無限ループします。
- `-CsvPath`: 指定すると、結果を CSV ファイルにログ出力します。
- `-AtPort`: AT コマンドを MBIM ではなく指定の COM ポート (例: `COM7`) で送ります。ベンダードライバが AT ポートを公開しているモデム向けです。省略時は MBIM の AT サービスを自動で探します。
- `-Gps`: Windows の GNSS ドライバー経路で衛星測位を取得します。GPS 以外 (Wi-Fi・基地局・IP 等) の座標は表示・記録しません。Windows の位置情報サービスとデスクトップアプリの位置情報アクセスを有効にしてください。API の制約により特定のモデムは選択できません。省略時は GPS を取得しません。
- `-Nmea`: `-Gps` に加えて、GNSS ドライバーの NMEA から捕捉衛星の一覧を取得します。`-Nema` とも書けます。ドライバーが管理者権限を要求するため、起動時に UAC で受信用のヘルパープロセスだけを昇格します (管理者ターミナルでは確認なし)。UAC を拒否しても LTE と GPS 欄の監視は続きます。衛星一覧は CSV には記録しません。

GPS を表示し、LTE 測定と一緒に CSV へ記録する例:

```powershell
.\lte_monitor.ps1 -Gps -CsvPath "log.csv"
```

### TUI での操作

TUI (Text User Interface) 画面起動中は以下のキー操作が可能です。

- `q` / `Esc` / `Ctrl+C` : 終了
- `p` : 一時停止 / 再開
- `r` : すぐに更新 (リフレッシュ)
- `R` (`Shift`+`r`) : すべての統計情報をリセット (ヒストリーグラフと min/avg/max、ハンドオーバー履歴と累計件数、2G/3G の検知履歴)。Caps Lock 中は `r` でもリセットになります
- `1`〜`6` : 各ヒストリーグラフの表示・非表示 (1:RSRP, 2:RSRQ, 3:SNR, 4:RX, 5:TX, 6:Temp)
- `g` : 全グラフの一括表示切り替え
- `h` : ハンドオーバー履歴の詳細一覧 / 通常画面を切り替え。詳細一覧では `↑` / `↓` で新しい / 古い履歴へ移動
- `s` : 衛星一覧 / 通常画面を切り替え (`-Nmea` 指定時)。一覧では `↑` / `↓` でスクロール。`h` の一覧とは排他
- `↑` / `↓` : ヒストリーグラフの高さ (行数) を増減 (1〜10 行、既定 2 行。1 行あたり 8 段階。Temp は常にその 1/2 (切り捨て、最低 1 行))

測定はバックグラウンドで行うため、モデムの応答待ちや通信量の取得中もキー操作できます。
一時停止時に取得中の測定は完了後に反映され、次の自動測定から停止します。取得中の `r` はその測定の完了を待ちます。
`R` はすぐにリセットし、取得中の測定は完了後にリセット後の統計に含めます。
リセットしても、画面上の測定回数 (`-Count` の進捗)、最新の測定値、CSV ログはそのままです。

ハンドオーバー履歴は通常画面に直近3件、`h` の詳細一覧に最大100件を新しい順で表示します。
各履歴は「その時刻にどのセルへ切り替わったか」を表示します。詳細には検出時刻、切り替え先の PLMN・Cell ID・バンド・PCI・EARFCN・TAC・RSRP を表示します。
履歴と累計件数は起動中のみ保持し、`R` で 0 件に戻せます。リセット直前のセルは比較基準として残すため、リセットをまたいだ切り替えも検出します。標準出力への逐次出力にも直近3件が含まれます。

判定対象はモデムが返す先頭の LTE 接続セル（本ツールでの主セル）の PLMN と Cell ID の変更です。
CA の副セルの追加・削除、信号強度や TAC だけの変化は数えません。初回取得、取得失敗・圏外・識別情報不明の後は比較基準を設定し直します。
測定間のセル変更を観測するため、セル再選択と通信中のハンドオーバーは区別できず、測定間隔内の切り替えをすべて捕捉できるものではありません。

主セルの信号値が取得できない場合も、セルの識別情報は保持します。画面・信号履歴・CSV・ハンドオーバー判定は同じ主セルを使い、CA の副セルを代用しません。
取得不能な測定値は画面では `n/a`、CSV では空欄、履歴グラフでは欠測として扱います。通信量の実測ゼロは `0 B/s` と表示し、カウンター取得失敗は画面と CSV の `Error` 列に理由を記録します。
LTE セルを取得できない回も履歴の位置を残し、取得できた温度などのモデム全体の測定値は保持します。

（標準入出力がリダイレクトされている場合は、プレーンテキストによる逐次出力にフォールバックします）

## ディレクトリ構成 (`src/`)

本ツールは Domain-Driven Design (DDD) 風のレイヤードアーキテクチャを採用しており、`src/` 以下がそれぞれの責務に分割されています。
domain は他のレイヤーに依存せず、application が infrastructure の取得結果にドメインルールを適用します。presentation はその結果を表示します。

- **`domain/`** : 信号の評価・統計、ダウングレード判定、セル同一性とハンドオーバー履歴 (`Signal.ps1`, `Downgrade.ps1`, `Handover.ps1` など)
- **`infrastructure/`** : ハードウェア・OS・CSV との入出力、AT 経路の検出、ベンダー別パーサーと WinRT 値の正規化 (`ModemObservation.ps1`, `AtProfile.ps1`, `SignalConversion.ps1` など)
- **`application/`** : 主セル・副セルを明示した snapshot の作成、セッション更新、履歴・CSV の連携と測定の実行管理 (`MonitorSession.ps1`, `Snapshot.ps1`, `MonitorSampler.ps1` など)
- **`presentation/`** : ユーザーインターフェース (`TuiMonitor.ps1`, `ConsoleRenderer.ps1`, `Gauge.ps1` など)

`src/Load.ps1` が共通のロード構成を管理します。エントリーポイントは全体を、測定 runspace は `-Components Core` で表示以外の共通部分を読み込みます。
RAT の許可設定は `AllowedRats` (GSM / UMTS / LTE / NR) と表示文言を分け、2G/3G 許可の判定結果を application から画面に渡します。

## 開発

`tool.ps1` で PowerShell と C# (`Add-Type` で実行時にコンパイルする `src/`・`diagnostics/` の `.cs`) のリント・整形を行います。

```powershell
.\tool.ps1 lint           # PSScriptAnalyzer と Roslyn Analyzers
.\tool.ps1 format         # Invoke-Formatter と dotnet format (whitespace / style) で整形
.\tool.ps1 format -Check  # 整形が必要なファイルの報告のみ (変更しない)
```

- 必要なもの: PSScriptAnalyzer モジュール、.NET 10 SDK、`.\setup.ps1` で展開した `lib\` の DLL
- `global.json` で SDK を 10.0.x (インストール済みの最新の 10.0 系) に固定しています。`tool.ps1` はリポジトリ直下で `dotnet` を実行するので、どのディレクトリから呼んでもこの指定が効きます
- C# は検査専用のプロジェクト `tools/csharp/WwanProbe.csproj` 経由で検査します。実行時には使いません。検査対象は PowerShell 7.4 (.NET 8) の `Add-Type` に合わせて net8.0 (C# 12)、implicit usings と nullable は無効です
- Roslyn Analyzers は .NET 10 SDK 同梱のもの (`AnalysisLevel` = `latest-recommended`) を使い、警告もエラーとして扱います。書式やコードスタイルの設定は `.editorconfig` にあります
- `format` はアナライザーのコード修正 (`dotnet format analyzers`) を適用しません。動作が変わる修正もあるため、`lint` で報告して手で直します

## ドキュメント

より詳細な技術情報については `docs/` 以下の Markdown ファイルを参照してください。

- [2G/3G ダウングレード検知](docs/downgrade-detection.md)
- [近隣セル (Neighbors) の取得方法](docs/neighbor-cells.md)
- [対応モデム (L860-GL 以外)](docs/modem-support.md)
- [GPS / GNSS の取得と表示](docs/gps.md)
