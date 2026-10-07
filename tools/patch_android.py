"""Run inside the generated Flutter project folder. Patches manifest + minSdk for Jarvis."""
import glob
import re

# ---- AndroidManifest.xml ----
path = "android/app/src/main/AndroidManifest.xml"
s = open(path, encoding="utf-8").read()

perms = """    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE"/>
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
"""
s = s.replace("<application", perms + "    <application", 1)

q_intents = """        <intent><action android:name="android.speech.RecognitionService"/></intent>
        <intent><action android:name="android.intent.action.TTS_SERVICE"/></intent>
"""
if "</queries>" in s:
    s = s.replace("</queries>", q_intents + "    </queries>", 1)
else:
    s = s.replace("</manifest>", "    <queries>\n" + q_intents + "    </queries>\n</manifest>", 1)

service = """        <service
            android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
            android:foregroundServiceType="microphone"
            android:exported="false"/>
"""
s = s.replace("</application>", service + "    </application>", 1)
s = s.replace('android:name=".MainActivity"',
              'android:name=".MainActivity"\n            android:showWhenLocked="true"\n            android:turnScreenOn="true"', 1)
open(path, "w", encoding="utf-8").write(s)

# ---- minSdk 24 ----
for g in glob.glob("android/app/build.gradle*"):
    t = open(g, encoding="utf-8").read()
    repl = "minSdk = 24" if g.endswith(".kts") else "minSdkVersion 24"
    t2 = re.sub(r"minSdk(Version)?\s*=?\s*flutter\.minSdkVersion", repl, t)
    open(g, "w", encoding="utf-8").write(t2)
    print("patched", g, t != t2)
print("manifest patched")
