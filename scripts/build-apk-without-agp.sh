#!/usr/bin/env bash
# Builds a signed debug APK directly with the Android SDK build tools (aapt2, d8, zipalign,
# apksigner) and the Kotlin compiler from Maven Central — no Android Gradle Plugin needed.
#
# The normal way to build is Android Studio / `./gradlew :app:assembleDebug` (AGP). This script
# exists for environments where Google's Maven repository (AGP, AndroidX) is unreachable, and as
# a transparent, reproducible check that the app compiles and packages.
#
# Usage: scripts/build-apk-without-agp.sh [--lint]   -> out-apk/TrailMind-debug.apk (+ out-apk/lint.txt)
# Env:   ANDROID_HOME (default /usr/local/lib/android/sdk), TRAILMIND_PLATFORM (default android-36)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
PLATFORM="${TRAILMIND_PLATFORM:-android-36}"
ANDROID_JAR="$SDK/platforms/$PLATFORM/android.jar"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
TOOLS="$ROOT/.toolcache"
OUT="$ROOT/out-apk"
KOTLIN_VERSION="2.4.0"
MIN_SDK=26
TARGET_SDK=36
VERSION_CODE=1
VERSION_NAME="0.1.0"
PACKAGE="com.trailmind.app"

[ -f "$ANDROID_JAR" ] || { echo "Missing $ANDROID_JAR (set ANDROID_HOME / TRAILMIND_PLATFORM)"; exit 1; }
echo "SDK: $SDK  platform: $PLATFORM  build-tools: $(basename "$BT")"

mkdir -p "$TOOLS"
fetch() { # group artifact version -> path of verified jar
  local group="$1" artifact="$2" version="$3"
  local file="$TOOLS/$artifact-$version.jar"
  local url="https://repo1.maven.org/maven2/${group//.//}/$artifact/$version/$artifact-$version.jar"
  if [ ! -f "$file" ]; then
    curl -fsSL "$url" -o "$file.part"
    local expected actual
    expected="$(curl -fsSL "$url.sha1" | cut -c1-40)"
    actual="$(sha1sum "$file.part" | cut -c1-40)"
    [ "$expected" = "$actual" ] || { echo "Checksum mismatch for $artifact"; rm -f "$file.part"; exit 1; }
    mv "$file.part" "$file"
  fi
  echo "$file"
}

KOTLIN_CP="$(fetch org.jetbrains.kotlin kotlin-compiler-embeddable $KOTLIN_VERSION)"
for spec in \
  "org.jetbrains.kotlin kotlin-stdlib $KOTLIN_VERSION" \
  "org.jetbrains.kotlin kotlin-script-runtime $KOTLIN_VERSION" \
  "org.jetbrains.kotlin kotlin-reflect 1.6.10" \
  "org.jetbrains.kotlin kotlin-daemon-embeddable $KOTLIN_VERSION" \
  "org.jetbrains.kotlin kotlin-build-tools-api $KOTLIN_VERSION" \
  "org.jetbrains.kotlinx kotlinx-coroutines-core-jvm 1.8.0" \
  "org.jetbrains annotations 13.0"; do
  # shellcheck disable=SC2086
  KOTLIN_CP="$KOTLIN_CP:$(fetch $spec)"
done
STDLIB="$TOOLS/kotlin-stdlib-$KOTLIN_VERSION.jar"
ANNOTATIONS="$TOOLS/annotations-13.0.jar"

rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/rclasses" "$OUT/classes" "$OUT/dex"

echo "[1/6] Resources (aapt2)"
# AGP injects the package from `namespace`; do the same for aapt2.
sed "s|<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\">|<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"$PACKAGE\">|" \
  "$ROOT/app/src/main/AndroidManifest.xml" > "$OUT/AndroidManifest.xml"
"$BT/aapt2" compile --dir "$ROOT/app/src/main/res" -o "$OUT/res.zip"
"$BT/aapt2" link -I "$ANDROID_JAR" --manifest "$OUT/AndroidManifest.xml" \
  --min-sdk-version $MIN_SDK --target-sdk-version $TARGET_SDK \
  --version-code $VERSION_CODE --version-name $VERSION_NAME \
  --java "$OUT/gen" --auto-add-overlay -o "$OUT/base.apk" "$OUT/res.zip"

echo "[2/6] R.java (javac)"
find "$OUT/gen" -name '*.java' > "$OUT/rsources.txt"
javac -nowarn --release 17 -classpath "$ANDROID_JAR" -d "$OUT/rclasses" @"$OUT/rsources.txt"

echo "[3/6] Kotlin (kotlinc $KOTLIN_VERSION) – app + core"
if ! java -Xmx2g -cp "$KOTLIN_CP" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-stdlib -no-reflect -jvm-target 17 -Xjdk-release=17 -Werror \
  -classpath "$ANDROID_JAR:$OUT/rclasses:$STDLIB:$ANNOTATIONS" \
  -d "$OUT/classes" \
  "$ROOT/app/src/main/kotlin" "$ROOT/core/src/main/kotlin" > "$OUT/kotlinc.log" 2>&1; then
  cat "$OUT/kotlinc.log"; echo "Kotlin compilation failed"; exit 1
fi
cat "$OUT/kotlinc.log"

echo "[4/6] Dex (d8)"
(cd "$OUT/classes" && zip -qr "$OUT/app-classes.jar" .)
(cd "$OUT/rclasses" && zip -qr "$OUT/r-classes.jar" .)
"$BT/d8" --release --min-api $MIN_SDK --lib "$ANDROID_JAR" --output "$OUT/dex" \
  "$OUT/app-classes.jar" "$OUT/r-classes.jar" "$STDLIB"

echo "[5/6] Package + align"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q "$OUT/unsigned.apk" classes*.dex)
"$BT/zipalign" -p -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

echo "[6/6] Sign (debug key, generated locally and never committed)"
KS="$TOOLS/debug.keystore"
if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -storepass android -keypass android -alias androiddebugkey \
    -dname "CN=Android Debug,O=Android,C=US" -keyalg RSA -keysize 2048 -validity 10000 >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$OUT/TrailMind-debug.apk" "$OUT/aligned.apk"
"$BT/apksigner" verify --verbose "$OUT/TrailMind-debug.apk" | sed -n 1,5p
"$BT/aapt2" dump badging "$OUT/TrailMind-debug.apk" | sed -n 1,3p
ls -l "$OUT/TrailMind-debug.apk"
echo "Done: $OUT/TrailMind-debug.apk  (install: adb install -r out-apk/TrailMind-debug.apk)"

if [ "${1:-}" = "--lint" ]; then
  LINT="$SDK/cmdline-tools/latest/bin/lint"
  [ -x "$LINT" ] || { echo "Standalone lint not found at $LINT"; exit 1; }
  echo "[lint] Android lint (standalone $("$LINT" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sed -n 1p))"
  # Standalone lint bundles an older Kotlin analyser, so give it a 1.9 stdlib to resolve against.
  LINT_STDLIB="$(fetch org.jetbrains.kotlin kotlin-stdlib 1.9.24)"
  # Mirror what AGP merges into the manifest (package, version, uses-sdk).
  mkdir -p "$OUT/lint-manifest"
  sed -e "s|package=\"$PACKAGE\"|package=\"$PACKAGE\" android:versionCode=\"$VERSION_CODE\" android:versionName=\"$VERSION_NAME\"|" \
      -e "s|<application|<uses-sdk android:minSdkVersion=\"$MIN_SDK\" android:targetSdkVersion=\"$TARGET_SDK\" />\n    <application|" \
      "$OUT/AndroidManifest.xml" > "$OUT/lint-manifest/AndroidManifest.xml"
  cp "$ROOT/app/lint.xml" "$OUT/lint-manifest/lint.xml"
  "$LINT" --sdk-home "$SDK" --compile-sdk-version $TARGET_SDK \
    --sources "$ROOT/app/src/main/kotlin" --sources "$ROOT/core/src/main/kotlin" --sources "$OUT/gen" \
    --resources "$ROOT/app/src/main/res" --classpath "$OUT/classes" --libraries "$LINT_STDLIB" \
    --text "$OUT/lint.txt" --exitcode "$OUT/lint-manifest" > "$OUT/lint-run.log" 2>&1 && LINT_OK=1 || LINT_OK=0
  tail -n 1 "$OUT/lint.txt"
  [ "$LINT_OK" = 1 ] || { echo "Lint reported errors: see $OUT/lint.txt"; exit 1; }
fi
