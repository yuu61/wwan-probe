# GPS / GNSS の取得と表示

`pwsh -File .\lte_monitor.ps1 -Gps` で GPS 欄を有効にします。
通常画面とプレーン出力に、緯度・経度 (十進度)、高度 (m)、水平精度 (m)、速度 (m/s)、方位 (度)、HDOP、測位時刻 (UTC) を表示します。
未取得の値は `n/a` です。高度はドライバーの高度基準による値で、海抜とは限りません。
GPS は指定したときだけ開始し、終了時に購読を解除します。
`-Nmea` を付けると、管理者権限の NMEA 経路で捕捉衛星の一覧も表示します ([衛星一覧](#衛星一覧--nmea))。

## 取得経路と制約

Windows の `Geolocator` を高精度 (`DesiredAccuracy = High`) で継続購読します。
この PC の L860-GL は `Fibocom GNSS Sensor` として Windows に認識されています。
この API は取得機器を指定できないため、**特定の WWAN モデムに取得元を固定する機能ではありません**。
GPS 機器が複数ある場合、どの機器の測位かは識別できません。AT コマンドで GPS を制御する実装ではありません。

採用する座標は `PositionSource = Satellite` かつローカル取得のものだけです。
Wi-Fi・基地局・IP・既定の位置・リモート由来の座標は GPS として採用せず、画面には `NoFix` と取得元を表示します。
Windows 自体が GPS 以外の測位を試すことを禁止する設定ではありません。
高精度指定でも衛星測位が必ず返るわけではありません。
Windows の位置情報サービスとデスクトップアプリの位置情報アクセスを許可し、衛星信号を受信できる場所で使用してください。

GPS 待ちは LTE のサンプリングをブロックしません。受信処理は常に最新の1件だけを保持します。
`p` による一時停止中も測位は継続しますが、画面・CSV への反映は LTE 測定の更新時です。
GPS の失敗は LTE 測定やハンドオーバー判定に影響しません。

| 表示 | 意味 |
| --- | --- |
| 座標と `Source: Satellite` | 有効な衛星測位 |
| `NoFix` | 測位待ち、または衛星以外の位置しか取得できない |
| `Stale` | 衛星測位の時刻が15秒より古い、または5秒より未来 |
| `Disabled` | Windows の位置情報アクセスが無効 |
| `Unavailable` | 取得処理の初期化失敗、位置情報プロバイダーなし等 (理由も表示) |

測位時刻は `PositionSourceTimestamp` を優先し、なければ `Timestamp` を使用します。
失効・未測位・取得不能になった座標は表示・記録せず空欄に戻します。
衛星数はこの API から取得できないため、`-Gps` だけでは表示しません (`-Nmea` で表示)。

## 衛星一覧 (`-Nmea`)

```powershell
.\lte_monitor.ps1 -Nmea
```

`-Nmea` は `-Gps` を含みます。`-Nema` と書いても同じです。オプション名は大文字・小文字を区別せず、存在しないオプションはエラーになります。
起動時に一度だけ UAC で NMEA 受信ヘルパーを昇格させ、TUI の `s` で衛星一覧と通常画面を切り替えます。
UAC の確認は TUI の表示前に行います。拒否しても LTE と GPS 欄の監視は続き、衛星欄に理由を表示します。
通常画面の GPS 欄には `Satellites: 18 in view (GPS 12, GLONASS 6), 6 used  [s]` のような要約を表示します。
`s` の一覧と `h` のハンドオーバー履歴は同時には開かず、一方を開くと他方は閉じます。

| 一覧の列 | 意味 |
| --- | --- |
| System | 衛星系。GPS / QZSS / SBAS / GLONASS / Galileo / BeiDou / NavIC / Unknown ごとに行を色分け |
| ID | NMEA の衛星番号 (GLONASS は 65–96) |
| Sig | NMEA 4.10 の信号ID (L860-GL では `1`)。4.10 より前の形式では空欄 |
| Elev / Azim | 仰角・方位角 (度) |
| SNR / バー | C/N0 (dB-Hz、バーは 0–50)。`n/a` と `not tracked` は視野内だが未追尾 |
| Used | GSA が測位に使用していると報告した衛星 |

一覧は衛星と信号の組ごとに1行で、画面に収まらない場合は `↑` / `↓` でスクロールします。
要約の `in view` は重複を除いた衛星数、`used` は GSA の使用衛星数です (GPGSA と GNGSA に同じ衛星があっても1基と数えます)。
衛星系は GSV の送信元 (GL=GLONASS 等) で判定し、GP / GN では NMEA の番号範囲 (1–32 GPS, 33–64・120–158 SBAS, 65–96 GLONASS, 193–202 QZSS) で判定します。
GSA の DOP は表示しません。GPS 欄の HDOP は従来どおり Windows (Geolocator) の値です。

GSV は 1..N のメッセージが順番どおりそろった周期だけを採用します。10秒間更新のない衛星系の GSV・GSA は一覧から外します。
画面への反映は LTE 測定の更新時です。衛星一覧の失敗は LTE 測定と GPS 欄に影響しません。CSV には衛星一覧を記録しません。

| 表示 | 意味 |
| --- | --- |
| `Starting` | ヘルパーの起動待ち |
| `waiting for NMEA from the GNSS driver` | ヘルパーは動作中だが NMEA を未受信 |
| `Stale` | ヘルパーの状態更新が10秒以上止まっている |
| `Unavailable` | UAC の拒否、GNSS デバイスなし、他の NMEA セッション実行中など (理由を表示) |

### 構成と後始末

- ヘルパー (`src/infrastructure/NmeaHelper.ps1`) は非表示の `pwsh` で動作します。モニターが管理者なら UAC なしで起動します。
  子プロセスには呼び出し元と同じ実行ポリシーを渡します。
- ヘルパーは高精度の Geolocator を購読して Windows に測位セッションを任せます。最初の GNSS デバイスで NMEA ロギングを有効にし、GSV / GSA だけを解析します。
- 結果は約1秒ごとに `%TEMP%\wwan-nmea-<GUID>\state.json` を置き換えて書き込み、モニターが読み取ります。緯度・経度 (GGA / RMC) は書き込みません。
  モニターの読み取りと重なった書き込みは失敗するため、次の周期で再試行します。
- 通常権限のモニターは昇格したヘルパーを終了できません。終了時は停止ファイルで依頼し、最大5秒待ちます。
  ヘルパーはモニターのプロセス終了 (PID と起動時刻で確認) も約1秒ごとに確認するため、モニターの強制終了後も自分で終了します。
- ヘルパーは終了時に NMEA ロギングを `NONE` に戻し、一時ディレクトリを削除します。起動や受信に失敗した場合は理由を画面に表示します。
- NMEA の受信は `Global\WwanProbeGnssNmea` ミューテックスで1つに限ります。`lte_monitor.ps1 -Nmea` と `Test-Gnss.ps1 -Nmea` は同時に実行できず、後から起動した側がエラーになります。
  どちらも終了時にロギングを `NONE` に戻すため、同時に動くと他方の受信を止めてしまうためです。

## Geolocator だけでは衛星一覧を取得できない理由

`-Gps` が使う `GeocoordinateSatelliteData` が公開するのは DOP (幾何・水平・位置・時間・垂直) です。
衛星ID・衛星系・衛星ごとの信号強度・仰角・方位角・測位への使用有無は取得できません。
このため、衛星一覧は管理者権限の NMEA 経路 (`-Nmea`) で取得します。

NMEA の `GSV` を受信できれば衛星ID・仰角・方位角・SNRを一覧化し、衛星系ごとの色分けが可能です。
`GSA` も取得できれば、見えている衛星と測位に使用している衛星を区別できます。
GNSS は衛星測位システムの総称で、色の分類は GPS / GLONASS / QZSS / Galileo / BeiDou / NavIC / SBAS 等になります。
実際に表示できる衛星系は受信機・ファームウェア・出力形式に依存します。

L860-GL のこの Windows 環境では、2026-09-24 に次を確認しました。

- GNSS デバイスインターフェースは存在しますが、通常権限での読み取りオープンは Win32 エラー5 (`Access is denied`) でした。
  インストール済み GNSS ドライバーの INF も System / Administrators / UMDF ドライバー向けのアクセス設定です。
  その後の管理者権限での検証では、読み取り・読み書きの両方でオープンできました。
- Windows GNSS ドライバー仕様には `GNSS_FIXDATA_SATELLITE` / `GNSS_SATELLITEINFO` と `IOCTL_GNSS_LISTEN_NMEA` があります。
  ただし一般アプリ向け `Geolocator` からは利用できず、NMEA の直接取得にはドライバー対応と NMEA ロギングの有効化が必要です。
- COM6 / COM9 は L860-GL の AT / Modem Control ポートです。既存調査では ModemControl ドライバーが占有しています
  ([neighbor-cells.md](neighbor-cells.md) の 2.)。
- Intel AT Tunnel の `AT+XLCSLSR=?` は NMEA を含む対応パラメーターを返しましたが、
  GPS 開始後の短時間の確認では、この経路の `CommandReceived` に NMEA は届きませんでした。
  コマンドへの対応だけでは、Windows アプリから衛星一覧を受信できることは確認できません。

以下の実機検証で衛星一覧に必要なデータを取得できたため、`-Nmea` として実装しました。

## 管理者権限・NMEA・UAC の実機検証

2026-09-24、L860-GL / Intel GNSS ドライバー 4.19042.7.2 で確認しました。

| 検証 | 結果 |
| --- | --- |
| 管理者トークン | `IsInRole(Administrator) = True` |
| ネイティブ GNSS インターフェースのオープン | 成功。通常権限のエラー5を解消 |
| `IOCTL_GNSS_GET_DEVICE_CAPABILITY` | 成功。構造体604バイト、DDI Version 4 |
| 対応セッション | ContinuousTracking = True、MultipleFixSessions / MultipleAppSessions = False |
| `GNSS_SetNMEALogging = ALL` | 成功 |
| `IOCTL_GNSS_LISTEN_NMEA` | 30秒で109イベント受信。診断スクリプトでも30秒93イベント、15秒48イベント受信 |
| 衛星データ | `GPGSV` に11基、`GLGSV` に4基。ID・仰角・方位角・SNRあり |
| 測位への使用 | `GPGSA` / `GNGSA` の使用衛星ID、Fix種別、DOPを受信 |
| WinRTとの併用 | Windowsの測位セッションを利用したままNMEAを受信。30秒実行中に `Fix / Satellite` を確認 |
| LTEモニターとの併用 | `-Gps -Count 2` と同時実行し、LTE更新と衛星座標の表示を確認 |
| 終了処理 | ロギングを `NONE` に戻すコマンド成功、ハンドル・WinRT購読を解放 |

GSVの掲載数は、その時点で受信機が報告した「視野内の衛星数」です。
SNRが空欄の衛星も含まれ、全15基の信号を追尾・測位に使用したという意味ではありません。
QZSS / Galileo / BeiDou のメッセージは今回未確認で、機種の対応や電波の受信状況と区別が必要です。
衛星測位は別の15秒実行では `NoFix / Cellular` でした。昇格自体が測位成功を保証するものではありません。

### 再現用診断

```powershell
# 機能情報だけを読む (管理者ターミナル)
.\diagnostics\Test-Gnss.ps1

# 30秒間NMEAを受信。通常権限ならUACで診断用子プロセスを昇格
.\diagnostics\Test-Gnss.ps1 -Elevate -Nmea -Seconds 30 | Format-List
```

`-Nmea` を付けると、高精度の Geolocator を購読し、NMEAロギングを一時的に有効にします。
ネイティブな測位セッションは追加せず、Windowsが測位と補助情報を管理します。
位置情報サービスの停止、デバイス設定やアクセス権の変更は行いません。
診断結果には受信種別とチェックサム検証済みの最新GSV/GSAを含めます。緯度・経度の生データは出力しません。
GSV/GSAは最後に届いた各メッセージを保持する診断用の情報で、同一時刻の衛星一覧や現在の使用衛星数に集計したものではありません。

ドライバーにはNMEAロギングの現在値を読むAPIがないため、終了時は既定値の `NONE` に戻します。
**他のNMEA診断ツールとは同時に実行しないでください。** `lte_monitor.ps1 -Nmea` と同じ名前のミューテックスを取るため、同時には実行できません。
診断スクリプトはモニター本体の NMEA 実装 (`src/infrastructure`) を使わず、独自のネイティブ呼び出し (`diagnostics/GnssProbe.cs`) と解析で動作します。
通常終了・例外時とも復旧を試み、失敗時は `LoggingDisableError` に理由を残します。
プロセスの強制終了では後処理を保証できません。
受信待ちは最大3秒ごとにキャンセルしますが、キャンセル完了はドライバーの応答に依存します。

### UACを使う方針

`Start-Process -Verb RunAs` により、通常権限から診断用の子プロセスだけを昇格できます。
`-Elevate` を明示したときだけ要求し、管理者の場合はそのまま実行します。
子プロセスは非表示で動作し、結果を元のPowerShellへ返します。UAC拒否時はエラー終了し、再要求しません。
管理者環境から `RunAs` による子プロセス起動・結果返却は実機確認済みです。
**非管理者環境でのUAC同意画面の表示・承認・拒否操作は未確認**です。

モニターの `-Gps` だけでは昇格しません。Geolocator による座標取得には管理者権限は不要で、権限が必要なのはネイティブ NMEA 経路です。
モニターは `-Nmea` を指定したときだけ、同じ `RunAs` の方式で NMEA 受信ヘルパーを昇格します (「衛星一覧 (`-Nmea`)」)。
短時間の併用は成功しましたが、Windows仕様上GNSSは排他的な資源として扱われるため、
この実験の成功だけで全ドライバーでの併用を保証するものではありません。

`-Nmea` の実機確認 (2026-09-24、管理者ターミナル):

- プレーン出力の `-Nmea -Count 8` で GPS 12基・GLONASS 6基、使用 6基を表示。終了後にヘルパーと一時ディレクトリが残らないこと
- モニターを強制終了すると、ヘルパーが約0.6秒で終了して一時ディレクトリを削除。その後の `Test-Gnss.ps1 -Nmea` が NMEA を受信できること
- モニター実行中の `Test-Gnss.ps1 -Nmea`、診断実行中のモニターが、それぞれ排他エラーになり、先行側の受信は継続すること

非管理者ターミナルからの UAC 承認・拒否、TUI 上での `s` の操作は実機では未確認です (キー操作と画面はテストで確認)。

参考:

- [Microsoft: GeocoordinateSatelliteData の公開プロパティ](https://learn.microsoft.com/en-us/uwp/api/windows.devices.geolocation.geocoordinatesatellitedata)
- [Microsoft: GNSS_SATELLITEINFO](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/gnssdriver/ns-gnssdriver-gnss_satelliteinfo)
- [Microsoft: IOCTL_GNSS_LISTEN_NMEA](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/gnssdriver/ni-gnssdriver-ioctl_gnss_listen_nmea)
- [Microsoft: GNSS ドライバーの構成とアクセス経路](https://learn.microsoft.com/en-us/windows-hardware/drivers/gnss/gnss-driver-architecture)
- [Microsoft: GNSS_SetNMEALogging](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/gnssdriver/ne-gnssdriver-gnss_drivercommand_type)
- [Microsoft: Start-Process / RunAs](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-process)
- [Trimble: NMEA GSV](https://receiverhelp.trimble.com/oem-gnss/nmea0183-messages-gsv.html)
- [Trimble: NMEA GSA](https://receiverhelp.trimble.com/oem-gnss/nmea0183-messages-gsa.html)

## CSV

`-CsvPath` を併用すると、既存列の後ろに以下の列を追加します。

`GPS_Status`, `GPS_Source`, `GPS_Timestamp_UTC`, `GPS_Latitude`, `GPS_Longitude`,
`GPS_Altitude_m`, `GPS_Accuracy_m`, `GPS_Speed_mps`, `GPS_Heading_deg`, `GPS_HDOP`, `GPS_Error`

`-Gps` なしではこれらは空欄です。GPS 固有のエラーは `GPS_Error` に記録します。

## 確認状況と出典

2026-09-24: L860-GL / Fibocom GNSS Sensor の認識、WinRT の受信、基地局由来の座標を採用しない動作を実機で確認。
同日の管理者権限でのNMEA併用検証中に `Fix / Satellite` を実機確認。
座標の正確さや屋外での長時間安定性は未検証です。座標・欠測・失効・表示・CSV は疑似データでも検証しています。

- [Microsoft: Geolocator](https://learn.microsoft.com/en-us/uwp/api/windows.devices.geolocation.geolocator)
- [Microsoft: GPS を有効にする高精度指定](https://learn.microsoft.com/en-us/windows/uwp/maps-and-location/guidelines-and-checklist-for-detecting-location)
- [Microsoft: PositionSource](https://learn.microsoft.com/en-us/uwp/api/windows.devices.geolocation.positionsource)
- [Microsoft: PositionChanged](https://learn.microsoft.com/en-us/uwp/api/windows.devices.geolocation.geolocator.positionchanged)
