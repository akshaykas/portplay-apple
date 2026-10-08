# PortPlay for iPad and Mac

A native SwiftUI version of PortPlay for iPads with a USB-C port (iPadOS 17 or later) and Macs (macOS 14 or later). It shows video and plays audio from a USB HDMI capture dongle.

Both apps share one codebase and one bundle ID, so they appear as a single App Store listing. Buying it once gets you both.

## Features

The same features as the Windows version:

* Profiles that remember resolution, frame rate, scaling, filter and audio sync, and come back automatically for each dongle
* Scaling modes: Fit, Stretch, Pixel (pixel perfect) and 4:3
* Retro filters: Scanlines and CRT, ported straight from the Windows shaders
* Volume up to 150%, mute, and audio sync up to 300 ms
* Screenshots (also copied to the clipboard), recording, and 30 second instant replay
* Low latency mode, which pauses filters and instant replay
* Stats: display delay, frame rate, dropped frames, audio delay, signal, scale and mode
* Picture in picture, and full screen on Mac
* Settings panel, troubleshooting tips, and a waiting screen when the console is off
* Controller shortcuts (hold Select and press a button) and keyboard shortcuts

Platform differences:

* **Microphone in recordings is Mac only.** iPadOS allows one audio input at a time, and that's the dongle.
* **Full screen is Mac only.** iPad apps are already full screen.
* **Where captures go:** Pictures and Movies, in a PortPlay folder, on Mac. The Photos library on iPad.

Everything below can be done from a Windows laptop. GitHub's macOS runners do the building, signing and uploading.

## What's in here

| Path | What it does |
|---|---|
| `PortPlay/App` | App entry point |
| `PortPlay/Model` | Settings, profiles and `AppModel`, which ties everything together like `renderer.js` |
| `PortPlay/Capture` | Opens the dongle and hands every frame out |
| `PortPlay/Render` | Metal renderer, scaling modes and the retro filter shaders |
| `PortPlay/Audio` | Game audio, audio sync, volume and the Mac microphone mixer |
| `PortPlay/Media` | Recording, instant replay, picture in picture and saving |
| `PortPlay/Input` | Controller shortcuts |
| `PortPlay/UI` | Control bar, settings panel, stats, tips, toasts and status screens |
| `project.yml` | XcodeGen spec with an iPad target (`PortPlay`) and a Mac target (`PortPlayMac`). CI turns it into the Xcode project, so you never edit a project file by hand |
| `fastlane/` | Signing (match) and TestFlight upload for each platform |
| `.github/workflows/build-check.yml` | Compiles both apps on every push to catch Swift errors. No secrets needed |
| `.github/workflows/testflight.yml` | Signs and uploads iPad and Mac builds to TestFlight |

## One-time setup

### 1. Apple Developer account
Enroll in the Apple Developer Program at developer.apple.com ($99 per year). Note your **Team ID** from the Membership details page.

### 2. Register the bundle ID
In Certificates, Identifiers & Profiles, go to Identifiers and add an App ID. Choose an explicit bundle ID such as `com.yourname.portplay`. No extra capabilities are needed.

### 3. Create the app in App Store Connect
In App Store Connect, go to Apps and click New App. Check both **iOS** and **macOS**, name it **PortPlay**, select the bundle ID from step 2, and enter any SKU. If you already created it as iOS only, open the app and use the plus button next to the platform list in the sidebar to add macOS.

### 4. Create an App Store Connect API key
Go to Users and Access, then Integrations, then App Store Connect API. Create a key with the **Admin** role (fastlane needs it to create the signing certificate on the first run). Download the `.p8` file (you can only download it once) and note the **Key ID** and **Issuer ID**.

Convert the key to base64 in PowerShell:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\AuthKey_XXXXXXXXXX.p8")) | Set-Clipboard
```

### 5. Create a private repo for signing certificates
Create an empty **private** GitHub repo, for example `portplay-certificates`. fastlane match stores the encrypted certificate and profile there.

Create a fine-grained personal access token with **Contents: Read and write** access to that repo only. Then encode `username:token` in PowerShell:

```powershell
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("your-github-username:github_pat_xxx")) | Set-Clipboard
```

Pick a strong password for encrypting the certificates. Keep it in your password manager.

### 6. Push this folder to GitHub and add settings
Create a repo for this folder (private is fine) and push it. In the repo, go to Settings, then Secrets and variables, then Actions.

**Variables tab**

| Name | Value |
|---|---|
| `BUNDLE_ID` | The bundle ID from step 2 |
| `TEAM_ID` | Your Team ID from step 1 |

**Secrets tab**

| Name | Value |
|---|---|
| `ASC_KEY_ID` | Key ID from step 4 |
| `ASC_ISSUER_ID` | Issuer ID from step 4 |
| `ASC_KEY_P8_BASE64` | The base64 key from step 4 |
| `MATCH_GIT_URL` | `https://github.com/your-github-username/portplay-certificates.git` |
| `MATCH_GIT_BASIC_AUTHORIZATION` | The base64 `username:token` from step 5 |
| `MATCH_PASSWORD` | The password from step 5 |

## Shipping a build

1. Open the **Actions** tab, pick **TestFlight**, click **Run workflow**, and choose `ipad`, `mac` or `both`. Each platform takes around 10 to 20 minutes. Pushing a tag like `v1.0.0` ships both.
2. In App Store Connect, open PortPlay, go to TestFlight, create an Internal Testing group and add yourself.
3. Install the **TestFlight** app on your iPad (and on a Mac, once you have one). The build shows up after Apple finishes processing it (usually 5 to 30 minutes).
4. Plug in your dongle and test.

The first Mac run creates a second signing certificate (Mac Installer Distribution), since Mac App Store uploads are installer packages. That happens automatically.

## Submitting to the App Store

In App Store Connect, fill in the description, keywords, support URL and privacy policy URL (the `privacy.html` page from the web version works). Each platform has its own version page and screenshots.

* **iPad:** at least one 13-inch iPad screenshot, which you can take on the iPad itself.
* **Mac:** at least one Mac screenshot at 1280x800, 1440x900, 2560x1600 or 2880x1800.

Add each TestFlight build to its version and submit. You can submit the iPad version alone and add the Mac version later.

**Test the Mac build on a real Mac before submitting it.** CI proves it compiles and signs, but only a Mac with a dongle proves it works.

**Important for App Review:** reviewers probably won't have a capture dongle. In the review notes, explain that the app needs a USB HDMI (UVC) capture dongle and include a link to a short video of PortPlay working with a console. This avoids a rejection for "app does nothing." Also mention that the iPad app uses the background audio mode only so picture in picture keeps working.

## Notes

* iPhone isn't supported because iOS has no driver for USB video devices. Only iPadOS does.
* PlayStation consoles send HDCP by default, which blocks capture. Turn off HDCP in the console settings.
* On Mac, PortPlay pairs the dongle's video and audio automatically. If it picks the wrong one, choose it under Game audio in settings.
* Picture in picture on iPad keeps going only on iPads that allow camera use while multitasking. On others the picture pauses when PortPlay leaves the screen.
* Video pauses if PortPlay shares the screen in Split View or Stage Manager on iPads that don't allow camera use while multitasking. The app tells the user when this happens.
