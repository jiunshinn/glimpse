# Android companion: monorepo

Status: step 1 done (2026-11-03): `android/` and `protocol/` exist next to the Mac app at the root. The move to `macos/` waits until no feature branch is open. Back to the [plan](README.md).

**Decision:** The macOS app, the Android app and the protocol between them live in this one repository. A protocol change and the code changes on both sides go into one pull request, so the two apps cannot drift apart.

## Target layout

```
image-viewer/
├── macos/                  Mac app (SwiftPM, no Xcode project)
│   ├── Package.swift
│   ├── Sources/Glimpse/
│   ├── Resources/
│   ├── scripts/            build-app.sh, make-icon.sh, generate-icon.swift
│   └── Makefile
├── android/                Android app (Gradle, Kotlin, Compose)
│   ├── settings.gradle.kts
│   ├── build.gradle.kts
│   ├── gradle/             wrapper + libs.versions.toml (version catalog)
│   ├── gradlew, gradlew.bat
│   └── app/
│       ├── build.gradle.kts
│       └── src/main/…, src/test/…
├── protocol/               The shared contract
│   ├── openapi.yaml        The HTTP API, version 1
│   ├── fixtures/           Sample requests and responses (JSON)
│   └── README.md           Rules: versioning, compatibility
├── docs/                   Design notes (this folder)
├── .github/workflows/
│   ├── macos.yml
│   ├── android.yml
│   └── protocol.yml
├── Makefile                Top-level entry: make mac, make android
├── README.md
└── LICENSE
```

## What the apps share

Swift and Kotlin cannot share code easily, and a cross-platform layer (for example Kotlin Multiplatform) adds a large toolchain. The apps share the **contract** only:

- `protocol/openapi.yaml` defines each endpoint and each JSON shape.
- `protocol/fixtures/*.json` holds sample messages. The Swift tests and the Kotlin tests decode the same files. When one side changes a shape, the other side's tests fail in the same pull request.
- The protocol has its own version number (`v` in Bonjour, `/v1/` in the paths). See [protocol.md](protocol.md).

## Moving the Mac app to `macos/`

Now the Mac app is at the repository root. The move is one commit with `git mv`. `git log --follow` keeps the file history.

Do the move when no feature branch is open. The move changes every path under `Sources/`, so an open branch gets a conflict on each changed file.

Steps:

1. Merge or close all open branches.
2. `git mv Package.swift Sources Resources scripts Makefile macos/`
3. Change the paths in `macos/scripts/build-app.sh`, `macos/Makefile` and `.gitignore`. The build output goes to `macos/build/`.
4. Add a root `Makefile` that calls `make -C macos …` and `android/gradlew …`.
5. Change the image path in `README.md` (`Resources/AppIcon.png` becomes `macos/Resources/AppIcon.png`).
6. Build and run the app, then merge the move alone in one pull request.

If you prefer no move, `android/` and `protocol/` can also sit next to the Mac files at the root. This works, but the root then mixes Mac files with the folders of the other parts.

## Root Makefile

```make
.PHONY: mac mac-run android android-install test

mac:            ; $(MAKE) -C macos app
mac-run:        ; $(MAKE) -C macos run
android:        ; cd android && ./gradlew assembleDebug
android-install:; cd android && ./gradlew installDebug
test:
	cd macos && swift test
	cd android && ./gradlew test
```

## CI

GitHub Actions with path filters, so a change to one app does not build the other:

| Workflow | Runner | Runs when these paths change | Steps |
| --- | --- | --- | --- |
| `macos.yml` | `macos-latest` | `macos/**`, `protocol/**` | `swift build`, `swift test`, `scripts/build-app.sh release` |
| `android.yml` | `ubuntu-latest` | `android/**`, `protocol/**` | `./gradlew lint test assembleDebug` |
| `protocol.yml` | `ubuntu-latest` | `protocol/**` | Validate `openapi.yaml`, check that each fixture matches the schema |

A protocol change runs all three workflows.

## `.gitignore` additions

```gitignore
# Android
/android/.gradle/
/android/build/
/android/app/build/
/android/local.properties
/android/.idea/
/android/.kotlin/
*.apk
*.aab
*.keystore
*.jks
```

Never commit a signing key. Keep the release keystore and its passwords in GitHub Actions secrets.

## Versions and releases

The two apps ship to different stores at different times, so each app has its own version:

| Part | Version | Git tag | Example |
| --- | --- | --- | --- |
| Mac app | `CFBundleShortVersionString` | `mac/vX.Y.Z` | `mac/v1.4.0` |
| Android app | `versionName` / `versionCode` | `android/vX.Y.Z` | `android/v0.1.0` |
| Protocol | an integer | none | `1` |

Each app states the protocol versions it supports in its `GET /v1/info` reply.

## Working rules

- Issue labels: `mac`, `android`, `protocol`.
- Branch names: `feature/<topic>`, as now. Examples: `feature/android-pairing`, `feature/mac-devices-sidebar`.
- A pull request that changes `protocol/` also updates both apps, or it adds a field that both apps can ignore.
- Android Studio opens the `android/` folder, not the repository root.
