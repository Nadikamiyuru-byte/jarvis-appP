# Jarvis APK - build it online (no Flutter install needed)

GitHub builds the APK for you, free.

1. Make a free account at github.com -> New repository (name: jarvis-app, Private is fine).
2. Unzip this folder on your PC. Upload EVERYTHING inside it to the repo
   (Add file -> Upload files; drag the `.github`, `src`, `tools` folders and README.md).
   Make sure the `.github/workflows/build-apk.yml` path is kept.
3. Go to the repo -> Actions tab -> "Build Jarvis APK" -> Run workflow (or it runs on upload).
4. Wait ~8-12 minutes. Open the finished run -> Artifacts -> download `jarvis-apk` (zip) -> unzip -> app-release.apk.
5. Copy the APK to your phone and install (allow "install unknown apps").

First run on the phone:
- Allow Microphone + Notifications.
- Allow "Display over other apps" for Jarvis.
- Settings (gear) -> paste Anthropic API key + Picovoice AccessKey (free at console.picovoice.ai) -> Save.
- Phone Settings -> Apps -> Jarvis -> Battery -> Unrestricted.
- Say "Jarvis".

If the build fails: open the failed run, copy the red error text and send it to Claude.
