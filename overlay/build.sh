#!/bin/sh
# 不用 Gradle: aapt2 + javac + d8 + zipalign + apksigner, 四步出 APK
# 依赖: JDK (javac) + Android SDK 的 build-tools 与 platforms;android-34
set -e

SDK=${ANDROID_HOME:-$HOME/android-sdk}
BT=$(ls -d "$SDK"/build-tools/* 2>/dev/null | tail -1)
PLATFORM=$(ls -d "$SDK"/platforms/android-* 2>/dev/null | tail -1)/android.jar
[ -x "$BT/aapt2" ] || { echo "找不到 aapt2, 先跑: sdkmanager 'build-tools;34.0.0' 'platforms;android-34'"; exit 1; }
[ -f "$PLATFORM" ] || { echo "找不到 android.jar"; exit 1; }

OUT=build
rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"

echo "[1/5] aapt2 link"
"$BT/aapt2" link -o "$OUT/base.apk" -I "$PLATFORM" \
    --manifest AndroidManifest.xml \
    --min-sdk-version 30 --target-sdk-version 34

echo "[2/5] javac"
javac -nowarn --release 8 -cp "$PLATFORM" -d "$OUT/classes" \
    $(find src -name '*.java')

echo "[3/5] d8"
"$BT/d8" --release --lib "$PLATFORM" --min-api 30 --output "$OUT/dex" \
    $(find "$OUT/classes" -name '*.class')

echo "[4/5] 打包 dex"
cp "$OUT/base.apk" "$OUT/app.apk"
(cd "$OUT" && zip -q -j app.apk dex/classes.dex)

echo "[5/5] 对齐 + 签名"
"$BT/zipalign" -f 4 "$OUT/app.apk" "$OUT/app-aligned.apk"
if [ ! -f keystore.jks ]; then
    keytool -genkeypair -keystore keystore.jks -alias k90hud \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -storepass android -keypass android \
        -dname "CN=K90HUD, O=local, C=CN" >/dev/null 2>&1
    echo "  已生成签名用 keystore.jks (口令 android)"
fi
"$BT/apksigner" sign --ks keystore.jks --ks-pass pass:android --key-pass pass:android \
    --out "$OUT/k90hud.apk" "$OUT/app-aligned.apk"
"$BT/apksigner" verify --print-certs "$OUT/k90hud.apk" | head -3

ls -lh "$OUT/k90hud.apk"
