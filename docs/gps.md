# GPS / GNSS の取得と表示

`pwsh -File .\lte_monitor.ps1 -Gps` で GPS 欄を有効にします。
通常画面とプレーン出力に、緯度・経度 (十進度)、高度 (m)、水平精度 (m)、速度 (m/s)、方位 (度)、HDOP、測位時刻 (UTC) を表示します。
未取得の値は `n/a` です。高度はドライバーの高度基準による値で、海抜とは限りません。
GPS は指定したときだけ開始し、終了時に購読を解除します。

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
衛星数はこの API から取得できないため表示しません。

## 捕捉衛星の一覧と衛星系ごとの色分け

現在の `GeocoordinateSatelliteData` が公開するのは DOP (幾何・水平・位置・時間・垂直) です。
衛星ID・衛星系・衛星ごとの信号強度・仰角・方位角・測位への使用有無は取得できません。
このため、現在の `-Gps` の取得経路だけでは衛星一覧を実装できません。

NMEA の `GSV` を受信できれば衛星ID・仰角・方位角・SNRを一覧化し、衛星系ごとの色分けが可能です。
`GSA` も取得できれば、見えている衛星と測位に使用している衛星を区別できます。
GNSS は衛星測位システムの総称で、色の分類は GPS / GLONASS / QZSS / Galileo / BeiDou / NavIC / SBAS 等になります。
実際に表示できる衛星系は受信機・ファームウェア・出力形式に依存します。

L860-GL のこの Windows 環境では、2026-09-24 に次を確認しました。

- GNSS デバイスインターフェースは存在しますが、通常権限での読み取りオープンは Win32 エラー5 (`Access is denied`) でした。
  インストール済み GNSS ドライバーの INF も System / Administrators / UMDF ドライバー向けのアクセス設定です。
  管理者権限での NMEA 取得成功は未確認です。
- Windows GNSS ドライバー仕様には `GNSS_FIXDATA_SATELLITE` / `GNSS_SATELLITEINFO` と `IOCTL_GNSS_LISTEN_NMEA` があります。
  ただし一般アプリ向け `Geolocator` からは利用できず、NMEA の直接取得にはドライバー対応と NMEA ロギングの有効化が必要です。
- COM6 / COM9 は L860-GL の AT / Modem Control ポートです。既存調査では ModemControl ドライバーが占有しています
  ([neighbor-cells.md](neighbor-cells.md) の 2.)。
- Intel AT Tunnel の `AT+XLCSLSR=?` は NMEA を含む対応パラメーターを返しましたが、
  GPS 開始後の短時間の確認では、この経路の `CommandReceived` に NMEA は届きませんでした。
  コマンドへの対応だけでは、Windows アプリから衛星一覧を受信できることは確認できません。

衛星一覧と色分け表示は未実装です。次に必要なのは、管理者権限で GNSS ドライバーから `GSV` / `GSA` を受信できるかの確認です。
権限だけで取得可能になるとは限らず、Windows 位置情報サービスとの共存も検証が必要です。

参考:

- [Microsoft: GeocoordinateSatelliteData の公開プロパティ](https://learn.microsoft.com/en-us/uwp/api/windows.devices.geolocation.geocoordinatesatellitedata)
- [Microsoft: GNSS_SATELLITEINFO](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/gnssdriver/ns-gnssdriver-gnss_satelliteinfo)
- [Microsoft: IOCTL_GNSS_LISTEN_NMEA](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/gnssdriver/ni-gnssdriver-ioctl_gnss_listen_nmea)
- [Microsoft: GNSS ドライバーの構成とアクセス経路](https://learn.microsoft.com/en-us/windows-hardware/drivers/gnss/gnss-driver-architecture)
- [Trimble: NMEA GSV](https://receiverhelp.trimble.com/oem-gnss/nmea0183-messages-gsv.html)
- [Trimble: NMEA GSA](https://receiverhelp.trimble.com/oem-gnss/nmea0183-messages-gsa.html)

## CSV

`-CsvPath` を併用すると、既存列の後ろに以下の列を追加します。

`GPS_Status`, `GPS_Source`, `GPS_Timestamp_UTC`, `GPS_Latitude`, `GPS_Longitude`,
`GPS_Altitude_m`, `GPS_Accuracy_m`, `GPS_Speed_mps`, `GPS_Heading_deg`, `GPS_HDOP`, `GPS_Error`

`-Gps` なしではこれらは空欄です。GPS 固有のエラーは `GPS_Error` に記録します。

## 確認状況と出典

2026-09-24: L860-GL / Fibocom GNSS Sensor の認識、WinRT の受信、基地局由来の座標を採用しない動作を実機で確認。
衛星測位成功時の実機確認は未完了です。座標・欠測・失効・表示・CSV は疑似データで検証しています。

- [Microsoft: Geolocator](https://learn.microsoft.com/en-us/uwp/api/windows.devices.geolocation.geolocator)
- [Microsoft: GPS を有効にする高精度指定](https://learn.microsoft.com/en-us/windows/uwp/maps-and-location/guidelines-and-checklist-for-detecting-location)
- [Microsoft: PositionSource](https://learn.microsoft.com/en-us/uwp/api/windows.devices.geolocation.positionsource)
- [Microsoft: PositionChanged](https://learn.microsoft.com/en-us/uwp/api/windows.devices.geolocation.geolocator.positionchanged)
