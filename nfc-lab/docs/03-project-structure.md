# 03. 프로젝트 구조 & Manifest

> 안드로이드 스튜디오에서 "Empty Views Activity"로 프로젝트 만들고 아래 파일들을 채우면 된다.
> 패키지명: `com.team6.tapnote`

## 1. 파일 구조

```
app/src/main/
├── AndroidManifest.xml
├── res/
│   ├── xml/apduservice.xml        ← HCE 서비스 설정 (AID 등록)
│   ├── layout/activity_main.xml   ← 탭 2개 UI
│   └── values/strings.xml
└── java/com/team6/tapnote/
    ├── MainActivity.kt            ← 탭 전환 + 리더 모드 제어
    ├── TapNoteCardService.kt      ← HCE 카드 역할 (보내기)
    ├── TapNoteReader.kt           ← 리더 역할 (받기)
    └── ApduProtocol.kt            ← 프로토콜 상수/유틸 (양쪽 공용)
```

## 2. AndroidManifest.xml

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- NFC 권한: 일반 권한이라 런타임 요청 불필요 -->
    <uses-permission android:name="android.permission.NFC" />

    <!-- NFC 없는 폰은 플레이스토어에서 설치 자체를 막음 -->
    <uses-feature
        android:name="android.hardware.nfc"
        android:required="true" />
    <!-- HCE 지원 폰만 -->
    <uses-feature
        android:name="android.hardware.nfc.hce"
        android:required="true" />

    <application
        android:label="TapNote"
        android:theme="@style/Theme.Material3.DayNight">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTask">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <!-- HCE 카드 서비스 등록. 여기가 핵심! -->
        <service
            android:name=".TapNoteCardService"
            android:exported="true"
            android:permission="android.permission.BIND_NFC_SERVICE">
            <intent-filter>
                <action android:name="android.nfc.cardemulation.action.HOST_APDU_SERVICE" />
            </intent-filter>
            <meta-data
                android:name="android.nfc.cardemulation.host_apdu_service"
                android:resource="@xml/apduservice" />
        </service>

    </application>
</manifest>
```

**포인트 해설**

- `BIND_NFC_SERVICE` 권한: 시스템(NFC 스택)만 이 서비스에 바인딩할 수 있게 잠그는 것. 다른 앱이 우리 카드 서비스를 사칭 호출 못 함
- 리더 쪽은 Manifest에 아무것도 필요 없음 — `enableReaderMode`는 코드에서 켜기 때문

## 3. res/xml/apduservice.xml

```xml
<?xml version="1.0" encoding="utf-8"?>
<host-apdu-service
    xmlns:android="http://schemas.android.com/apk/res/android"
    android:description="@string/hce_service_desc"
    android:requireDeviceUnlock="false">

    <!-- 우리 AID 그룹. 리더가 F0544150 4E54를 SELECT하면
         안드로이드가 TapNoteCardService로 APDU를 라우팅 -->
    <aid-group
        android:category="other"
        android:description="@string/hce_service_desc">
        <aid-filter android:name="F054415 04E54" />
    </aid-group>
</host-apdu-service>
```

> ⚠️ 위 aid-filter 값은 공백 없이 `F05441504E54`로 써야 한다 (md 표시 문제로 띄어 보일 수 있음).

**포인트 해설**

- `category="other"`: 결제(`payment`)가 아닌 일반 카드. payment로 하면 "기본 결제 앱" 설정 경쟁에 들어가서 복잡해짐
- `requireDeviceUnlock="false"`: 화면 켜져 있으면 잠금 해제 없이도 동작. 쪽지 앱이니 이 정도가 UX에 맞음 (단, 화면이 꺼져 있으면 HCE 자체가 비활성)

## 4. res/values/strings.xml

```xml
<resources>
    <string name="app_name">TapNote</string>
    <string name="hce_service_desc">TapNote 쪽지 전송 카드</string>
</resources>
```

## 다음 단계

→ `04-apdu-protocol-code.md`: 양쪽이 공유하는 `ApduProtocol.kt` 구현
→ `05-card-service.md`: `TapNoteCardService.kt` (보내기)
→ `06-reader.md`: `TapNoteReader.kt` + `MainActivity.kt` (받기 + UI)
