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

# 应用名可以按机型覆盖: LABEL="K Pad HUD" sh build.sh
# (同一份源码给两台机器用 —— 包名不变, 只换桌面显示的名字, 用户偏好不会丢)
LABEL=${LABEL:-}
PKG=${PKG:-}
if [ -n "$LABEL" ] || [ -n "$PKG" ]; then
    # 组件名在清单里已经是全限定类名, 所以换 package 不会把 .HudService 解析错
    sed -e "s/android:label=\"K90 HUD\"/android:label=\"${LABEL:-K90 HUD}\"/g" \
        -e "s/package=\"com.langrm.k90hud\"/package=\"${PKG:-com.langrm.k90hud}\"/g" \
        AndroidManifest.xml > "$OUT/AndroidManifest.xml"
    MANIFEST="$OUT/AndroidManifest.xml"
    [ -n "$LABEL" ] && echo "  应用名: $LABEL"
    [ -n "$PKG" ]   && echo "  包名:   $PKG"
else
    MANIFEST=AndroidManifest.xml
fi

echo "[1/5] aapt2 link"
"$BT/aapt2" link -o "$OUT/base.apk" -I "$PLATFORM" \
    --manifest "$MANIFEST" \
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
    # 【重要】生成的是一把**新 key**。已装过旧版 APK 的手机签名对不上,
    # pm install -r 会报 INSTALL_FAILED_UPDATE_INCOMPATIBLE, 而 service.sh 里的安装是
    # 静默执行的(>/dev/null), 失败不报错 —— 表现为"改了 App 但界面没变化"。
    # 所以: 原 keystore.jks 必须保留(口令 android, *.jks 已 gitignore), 换机器前先拷回来。
    keytool -genkeypair -keystore keystore.jks -alias k90hud \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -storepass android -keypass android \
        -dname "CN=K90HUD, O=local, C=CN" >/dev/null 2>&1
    echo "  警告: 已生成**新的** keystore.jks(口令 android) —— 覆盖安装到已装旧版的手机前要确认签名一致"
fi
"$BT/apksigner" sign --ks keystore.jks --ks-pass pass:android --key-pass pass:android \
    --out "$OUT/k90hud.apk" "$OUT/app-aligned.apk"
"$BT/apksigner" verify --print-certs "$OUT/k90hud.apk" | head -3

ls -lh "$OUT/k90hud.apk"
