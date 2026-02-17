#!/usr/bin/env bash
# Exit on error
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Detect OS
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    IS_WINDOWS=true
    ;;
  Darwin*)
    IS_MACOS=true
    ;;
  Linux*)
    IS_LINUX=true
    ;;
  *)
    echo "Unsupported operating system: $(uname -s)"
    exit 1
    ;;
esac

root=$SCRIPT_DIR/sdk
doSim=${1:-"true"}

echo "=========================================="
echo "Script directory: $SCRIPT_DIR"
echo "Project root: $PROJECT_ROOT"
echo "SDK root: $root"
echo "=========================================="

if type -p java; then
    _java=java
elif [[ -n "$JAVA_HOME" ]] && [[ -x "$JAVA_HOME/bin/java" ]];  then
    _java="$JAVA_HOME/bin/java"
else
    echo "no java"
    exit
fi

if [[ "$_java" ]]; then
    version=$(javap -verbose java.lang.String | grep "major version" | cut -d " " -f5)
    if [[ "$version" -lt "69" ]]; then
        echo Error: JDK version is lower than 25
        exit
    fi
fi

if [[ ! -d "sdk" ]]; then
  mkdir sdk
fi

cd sdk || exit

# Function to clone git repository with retry logic
# Usage: clone_with_retry <repo_url> <target_dir> <max_attempts>
clone_with_retry() {
  local repo_url="$1"
  local target_dir="$2"
  local max_attempts="${3:-3}"  # Default 3 attempts
  local attempt=1

  while [[ $attempt -le $max_attempts ]]; do
    echo "Cloning $repo_url (attempt $attempt/$max_attempts)..."

    # Remove partial clone if it exists
    if [[ -d "$target_dir" ]]; then
      echo "Removing incomplete clone..."
      rm -rf "$target_dir"
    fi

    # Try to clone with depth 1 for faster download
    if git clone --depth 1 "$repo_url" "$target_dir" 2>&1; then
      # Verify the clone was successful
      if [[ -d "$target_dir/.git" ]] && git -C "$target_dir" rev-parse HEAD >/dev/null 2>&1; then
        echo "✅ Successfully cloned $repo_url"
        return 0
      else
        echo "⚠️  Clone completed but verification failed"
      fi
    else
      echo "❌ Clone attempt $attempt failed"
    fi

    # If not the last attempt, wait before retrying
    if [[ $attempt -lt $max_attempts ]]; then
      local wait_time=$((attempt * 5))  # Exponential backoff: 5s, 10s, 15s
      echo "Waiting ${wait_time}s before retry..."
      sleep $wait_time
    fi

    attempt=$((attempt + 1))
  done

  echo "❌ Failed to clone $repo_url after $max_attempts attempts"
  return 1
}

if [[ ! -d "libffi" ]] && [[ -n "$IS_MACOS" ]]; then
  echo "========== FFI ==========="
  mkdir libffi
  wget -nv -O libffi/libffi-ios.zip https://github.com/openjdk-mobile/ios-tools/releases/download/libffi-build/libffi-ios.zip
  unzip -q libffi/libffi-ios.zip -d libffi
  rm libffi/libffi-ios.zip
fi
if [[ "$doSim" == true ]] && [[ ! -d "libffi-sim" ]] && [[ -n "$IS_MACOS" ]]; then
  echo "========== FFI Sim ==========="
  mkdir libffi-sim
  wget -nv -O libffi-sim/libffi-ios-sim.zip https://github.com/openjdk-mobile/ios-tools/releases/download/libffi-build/libffi-ios-sim.zip
  unzip -q libffi-sim/libffi-ios-sim.zip -d libffi-sim
  rm libffi-sim/libffi-ios-sim.zip
fi

if [[ ! -d "openjfx-build" ]]; then
  clone_with_retry "https://github.com/openjdk-mobile/openjfx-build.git" "openjfx-build" 3 || exit 1
fi

if [[ ! -d "jfx" ]]; then
  clone_with_retry "https://github.com/openjdk/jfx.git" "jfx" 5 || exit 1
fi
jfxversion=$(grep "^[#]*\s*jfx.release.major.version" jfx/build.properties | cut -d'=' -f2)$(grep "^[#]*\s*jfx.release.suffix=" jfx/build.properties | cut -d'=' -f2)
if [[ -z "$jfxversion" ]]; then
  echo "Error: Failed to extract JavaFX version";
  jfxversion="unknown"
fi
export RUNTIME_VERSION=$jfxversion

if [[ ! -d "mobile" ]]; then
  clone_with_retry "https://github.com/openjdk/mobile/" "mobile" 5 || exit 1

  cd mobile || exit
  git apply ../openjfx-build/openjdk-ext/src/jfx.patch

  # Copy custom javafx.graphics makefiles from project
  cp "$PROJECT_ROOT/openjdk-ext/src/javafx.graphics"/*.gmk make/modules/javafx.graphics/
  # copy antlr tool for gensrc
  cp -r "$PROJECT_ROOT/openjdk-ext/src/make/data/javafx-tools" make/data
  cd ..
fi

cd mobile || exit
if [[ ! -f "$root/mobile/build/jfx/images/jdk/bin/jmod" ]];  then
  echo "========== macOS SDK with JFX ==========="
  bash configure \
              --with-conf-name=jfx \
              --with-openjfx-modules=../jfx \
              --with-boot-jdk="$JAVA_HOME" \
              --disable-warnings-as-errors
  make CONF=jfx images
fi

# Check for macOS for iOS-specific builds
if [[ -z "$IS_MACOS" ]]; then
  echo "=========================================="
  echo "Non-macOS platform detected: $(uname -s)"
  echo "iOS builds (device/simulator) will be skipped."
  echo "Only macOS JDK with JavaFX will be built."
  echo "=========================================="
fi

if [[ ! -d "$root/mobile/build/ios-aarch64-zero-release/images/static-libs/lib" ]] && [[ -n "$IS_MACOS" ]]; then
  echo "========== iOS SDK ==========="
  cp "$PROJECT_ROOT/openjdk-ext/src/hotspot/symbol_keeper.cpp" "$root/mobile/src/hotspot/os/bsd"

  bash configure \
      --with-conf-name=ios-aarch64-zero-release \
      --with-openjfx-modules=../jfx \
      --disable-warnings-as-errors \
      --openjdk-target=aarch64-macos-ios \
      --with-sysroot=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk \
      --with-libffi-include=$root/libffi/include/ffi \
      --with-libffi-lib=$root/libffi  \
      --with-cups-include="$(xcrun --sdk macosx --show-sdk-path)/usr/include"
  make CONF=ios-aarch64-zero-release javafx.controls-java javafx.fxml-java static-libs-image
  cp "$root/mobile/build/ios-aarch64-zero-release/jdk/include/ios/jni_md.h" "$root/mobile/build/ios-aarch64-zero-release/jdk/include/"
fi

if [[ "$doSim" == true ]] && [[ -n "$IS_MACOS" ]] && [[ ! -d "$root/mobile/build/iossim-aarch64-zero-release/images/static-libs/lib" ]]; then
  echo "========== iOS-Sim SDK ==========="
  bash configure \
      --with-conf-name=iossim-aarch64-zero-release \
      --with-openjfx-modules=../jfx \
      --disable-warnings-as-errors \
      --openjdk-target=aarch64-macos-ios \
      --with-sysroot=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk \
      --with-libffi-include=$root/libffi-sim/include/ffi \
      --with-libffi-lib=$root/libffi-sim  \
      --with-extra-cflags="-target arm64-apple-ios-simulator -mios-simulator-version-min=18.2" \
      --with-extra-cxxflags="-target arm64-apple-ios-simulator -mios-simulator-version-min=18.2" \
      --with-cups-include="$(xcrun --sdk macosx --show-sdk-path)/usr/include"
  make CONF=iossim-aarch64-zero-release javafx.controls-java javafx.fxml-java static-libs-image
  cp "$root/mobile/build/iossim-aarch64-zero-release/jdk/include/ios/jni_md.h" "$root/mobile/build/iossim-aarch64-zero-release/jdk/include/"
fi
cd ..

if [[ -n "$IS_MACOS" ]]; then
  echo "========== jmods ==========="
  if [[ -d "$root/mobile/build/jmods" ]]; then
    rm -rf "$root/mobile/build/jmods"
  fi
  mkdir -p "$root/mobile/build/jmods"
  module_names=("java.base" "java.desktop" "java.prefs" "java.xml" "java.datatransfer" "javafx.base" "javafx.graphics" "javafx.controls")
  for item in "${module_names[@]}"; do
    "$root/mobile/build/jfx/images/jdk/bin/jmod" create --class-path "$root/mobile/build/ios-aarch64-zero-release/jdk/modules/$item" --target-platform ios-aarch64 "$root/mobile/build/jmods/$item.jmod"
  done

  echo "========== modules ==========="
  if [[ -d "$root/mobile/build/java_bundle" ]]; then
     rm -rf "$root/mobile/build/java_bundle"
  fi
  "$root/mobile/build/jfx/images/jdk/bin/jlink" --module-path "$root/mobile/build/jmods" --add-modules javafx.controls --output "$root/mobile/build/java_bundle"

  echo "========== lidDevice.a ==========="
  DEVICE_TARGET=./device-static

  if [[ ! -d "$DEVICE_TARGET" ]]; then
    mkdir -p $DEVICE_TARGET
  fi
  cd $DEVICE_TARGET || exit
  if [[ -f "$DEVICE_TARGET/libdevice.a" ]]; then
    rm libdevice.a
  fi
  cp "$root/libffi/libffi.a" .
  cp "$root/mobile/build/ios-aarch64-zero-release/images/static-libs/lib"/*.a .
  cp "$root/mobile/build/ios-aarch64-zero-release/images/static-libs/lib/zero/libjvm.a" .
  libtool -static -o libdevice.a libjvm.a libffi.a libjava.a libzip.a libnet.a libnio.a libjimage.a \
    libglass.a libjavafx_font.a libjavafx_iio.a libprism_common.a libprism_es2.a
  cd ..

  if [[ "$doSim" == true ]]; then
    echo "========== libsimulator.a ==========="
    SIMULATOR_TARGET=./simulator-static

    if [[ ! -d "$SIMULATOR_TARGET" ]]; then
      mkdir $SIMULATOR_TARGET
    fi
    cd $SIMULATOR_TARGET || exit
    if [[ -f "$SIMULATOR_TARGET/libsimulator.a" ]]; then
      rm libsimulator.a
    fi
    cp "$root/libffi-sim/libffi.a" .
    cp "$root/mobile/build/iossim-aarch64-zero-release/images/static-libs/lib"/*.a .
    cp "$root/mobile/build/iossim-aarch64-zero-release/images/static-libs/lib/zero/libjvm.a" .
    libtool -static -o libsimulator.a libjvm.a libffi.a libjava.a libzip.a libnet.a libnio.a libjimage.a \
      libglass.a libjavafx_font.a libjavafx_iio.a libprism_common.a libprism_es2.a
    cd ..
  fi

  echo "========== Framework ==========="
  rm -rf framework
  mkdir framework
  if [[ "$doSim" == true ]]; then
    xcodebuild -create-xcframework \
      -library "$DEVICE_TARGET/libdevice.a" \
      -headers "$root/mobile/build/ios-aarch64-zero-release/jdk/include" \
      -library "$SIMULATOR_TARGET/libsimulator.a" \
      -headers "$root/mobile/build/iossim-aarch64-zero-release/jdk/include" \
      -output framework/OpenJDK.xcframework
  else
    xcodebuild -create-xcframework \
      -library "$DEVICE_TARGET/libdevice.a" \
      -headers "$root/mobile/build/ios-aarch64-zero-release/jdk/include" \
      -output framework/OpenJDK.xcframework
  fi

  cd ..
fi

echo "========== Done ==========="

