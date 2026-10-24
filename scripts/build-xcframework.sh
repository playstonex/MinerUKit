#!/bin/bash
# build-xcframework.sh — Build MinerUKit as a binary (dynamic) .xcframework
#
# Produces: build/xcframework/MinerUKit.xcframework + .zip
#           with TWO slices:
#             - macos-arm64  (built via `swift build` + manual bundle)
#             - ios-arm64    (built via `xcodebuild archive`, iOS 18.0+, device only)
#
# WHY A DYNAMIC XCFRAMEWORK
#   MinerUKit statically pulls in MLX (macOS 14+) and ships a metal3.2 metallib,
#   so the package declares .macOS(.v15). The host app (Petal) must keep a
#   macOS 13 deployment target, so it CANNOT link MinerUKit (or MLX) directly —
#   SPM would refuse the platform mismatch and, even if forced, the whole app
#   binary would then require macOS 15 at load. Instead we ship MinerUKit as a
#   dynamic framework the app `dlopen`s only behind `#available(macOS 15,*)`.
#   On macOS 13/14 the framework is never loaded, its code never enters the
#   process, and the app does not crash. This mirrors the existing
#   PetalASR.xcframework loader pattern.
#
# HOW THE APP CALLS IT
#   MinerUKit's native API is pure-Swift async; the app reaches it through the
#   `@objc MinerUKitBridge` façade (Sources/MinerUKit/ObjCBridge.swift) via
#   NSClassFromString + the ObjC runtime — no `import MinerUKit`, no static link.
#
# MLX METALLIB
#   In the source SPM build, mlx-swift auto-builds a 9-kernel default.metallib
#   and JIT-compiles the rest. In the binary .xcframework path MLX's C++ loader
#   looks for mlx.metallib colocated in the framework's Resources/. We compile a
#   full metallib from mlx-swift's .metal sources and bundle it, exactly like
#   the PetalASR build.
#
# TARGET
#   macOS 15.0: MinerU is a macOS 15+ feature by product decision, and 15.0 is
#   also the floor the bundled metallib imposes (-std=metal3.2 is rejected by
#   macOS 14's Metal runtime; metal3.1 cannot compile fence.metal). MLX itself
#   only needs 14, but pinning 15 keeps the declared floor, the metallib floor
#   and the app's `#available(macOS 15,*)` gate all equal to one number.
#   iOS 18.0: experimental device-only slice. MinerUKit's sources import only
#   CoreGraphics + PDFKit (both on iOS), and the MLX/MLXVLM graph cross-compiles
#   for iOS. The app loads it behind #available(iOS 18,*). NOTE: the VLM may OOM
#   on lower-RAM iPhones — this slice exists so that can be tested on a device.
#
set -euo pipefail

cd "$(dirname "$0")/.."

PRODUCT="MinerUKit"
FW_NAME="MinerUKit"
BUILD_DIR="build/xcframework"
MACOS_DEPLOYMENT_TARGET="15.0"
IOS_DEPLOYMENT_TARGET="18.0"

echo "=== Cleaning previous build ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- Temporarily make the MinerUKit product dynamic (for this build only) ---
# The committed Package.swift keeps the product type unspecified so `swift test`
# and source consumers behave normally. For the framework we need an actual
# dylib, so swap in a manifest that declares `type: .dynamic`, then restore.
ORIG_MANIFEST="Package.swift"
BACKUP_MANIFEST="Package.swift.prebuild"
cp "$ORIG_MANIFEST" "$BACKUP_MANIFEST"

# Insert `type: .dynamic` into the MinerUKit library product line.
#   .library(name: "MinerUKit", targets: ["MinerUKit"]),
# becomes
#   .library(name: "MinerUKit", type: .dynamic, targets: ["MinerUKit"]),
/usr/bin/sed -i '' \
    's/\.library(name: "MinerUKit", targets:/\.library(name: "MinerUKit", type: .dynamic, targets:/' \
    "$ORIG_MANIFEST"

cleanup() {
    echo "=== Restoring Package.swift ==="
    if [ -f "$BACKUP_MANIFEST" ]; then
        cp "$BACKUP_MANIFEST" "$ORIG_MANIFEST"
        rm -f "$BACKUP_MANIFEST"
    fi
}
trap cleanup EXIT

# ============================================================================
# Shared helper: compile MLX's Metal kernels into mlx.metallib for a given SDK.
# (Adapted from PetalASR/scripts/build-xcframework.sh.)
# Args: $1 = macosx|iphoneos  $2 = output .metallib path
# ============================================================================
build_metallib() {
    local SDK="$1"
    local OUT_METALLIB="$2"
    local MLX_SWIFT_DIR=".build/checkouts/mlx-swift"
    local KERNELS_DIR="$MLX_SWIFT_DIR/Source/Cmlx/mlx/mlx/backend/metal/kernels"

    if [ ! -d "$KERNELS_DIR" ]; then
        echo "ERROR: MLX kernels dir not found at $KERNELS_DIR (run the swift build first)"
        exit 1
    fi

    local -a METAL_SRCS=()
    while IFS= read -r line; do
        METAL_SRCS+=("$line")
    done < <(find "$KERNELS_DIR" -type f -name '*.metal' ! -name '*_nax.metal' | LC_ALL=C sort)

    if [ "${#METAL_SRCS[@]}" -eq 0 ]; then
        echo "ERROR: no .metal sources found under $KERNELS_DIR"
        exit 1
    fi

    local TMP
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/mlx-metallib.XXXXXX")"
    local -a AIR_FILES=()
    # Pin the Metal language version. Without -std the toolchain default wins
    # (Xcode 27: metal4.1 -> air64_v29-apple-macosx27.0.0), and macOS 15's Metal
    # runtime rejects that library ("language version 4.1 which is not supported
    # on this OS"); MLX then calls exit(-1) and the app dies right after
    # "[MinerU] bridge loaded OK". metal3.2 targets macOS 15 and compiles every
    # MLX kernel; metal3.1 (macOS 14) fails on fence.metal (metal::thread_scope).
    # -std alone is NOT enough: with the SDK sysroot that `xcrun -sdk` adds, the
    # emitted AIR still targets the SDK's OS (macosx27) unless a deployment floor
    # is given, so -mmacosx-version-min is required too.
    local -a METAL_FLAGS=(-x metal -std=metal3.2 -Wall -Wextra -fno-fast-math
        -Wno-c++17-extensions -Wno-c++20-extensions)
    if [ "$SDK" = "macosx" ]; then
        METAL_FLAGS+=(-mmacosx-version-min=15.0)
    elif [ "$SDK" = "iphoneos" ]; then
        METAL_FLAGS+=(-mios-version-min=18.0)
    fi

    echo "  Compiling ${#METAL_SRCS[@]} Metal sources (sdk=${SDK})..."
    for SRC in "${METAL_SRCS[@]}"; do
        local REL="${SRC#"$KERNELS_DIR/"}"
        local KEY
        KEY="$(printf '%s' "$REL" | shasum -a 256 | awk '{print $1}' | cut -c1-16)"
        local OUT_AIR="$TMP/$KEY.air"
        if ! xcrun -sdk "$SDK" metal "${METAL_FLAGS[@]}" -c "$SRC" \
                -I"$KERNELS_DIR" -I"$MLX_SWIFT_DIR/Source/Cmlx/mlx" -o "$OUT_AIR" 2>"$TMP/metal.err"; then
            if grep -q "missing Metal Toolchain" "$TMP/metal.err" 2>/dev/null; then
                echo "ERROR: Xcode Metal Toolchain is missing." >&2
                echo "  run: xcodebuild -downloadComponent MetalToolchain" >&2
            fi
            cat "$TMP/metal.err" >&2
            rm -rf "$TMP"
            exit 1
        fi
        AIR_FILES+=("$OUT_AIR")
    done

    echo "  Linking -> $OUT_METALLIB"
    xcrun -sdk "$SDK" metallib "${AIR_FILES[@]}" -o "$OUT_METALLIB"
    rm -rf "$TMP"

    # Guard against a toolchain default sneaking back in: refuse a metallib whose
    # target OS is newer than the oldest system we ship to (macOS 15).
    local OS_NAME="macosx" OS_MAX=15
    if [ "$SDK" = "iphoneos" ]; then OS_NAME="ios"; OS_MAX=18; fi
    local TARGET_OS
    TARGET_OS="$(strings "$OUT_METALLIB" | grep -o "air64_v[0-9]*-apple-${OS_NAME}[0-9]*" \
        | sed "s/.*${OS_NAME}//" | sort -n | tail -1 || true)"
    if [ "${TARGET_OS:-999}" -gt "$OS_MAX" ]; then
        echo "ERROR: $OUT_METALLIB targets ${OS_NAME}${TARGET_OS}, newer than ${OS_NAME} ${OS_MAX}." >&2
        exit 1
    fi
}

# ============================================================================
# SLICE: macOS arm64  (swift build → dylib → manual versioned .framework)
# ============================================================================

echo "=== Building $PRODUCT (macOS ${MACOS_DEPLOYMENT_TARGET}, release, arm64) ==="
rm -rf .build
MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
    swift build -c release --product "$PRODUCT"

BIN_PATH="$(swift build -c release --show-bin-path)"
DYLIB="$BIN_PATH/lib${FW_NAME}.dylib"
if [ ! -f "$DYLIB" ]; then
    echo "ERROR: Built dylib not found at $DYLIB"
    echo "  bin dir contents:"; ls -1 "$BIN_PATH" | head -40
    exit 1
fi
echo "Found dylib: $DYLIB"

echo "=== Constructing macOS versioned .framework bundle ==="
MAC_FW_DIR="$BUILD_DIR/macos-arm64/${FW_NAME}.framework"
mkdir -p "$MAC_FW_DIR/Versions/A/Resources"
mkdir -p "$MAC_FW_DIR/Versions/A/Modules"

cp "$DYLIB" "$MAC_FW_DIR/Versions/A/$FW_NAME"
install_name_tool -id "@rpath/${FW_NAME}.framework/${FW_NAME}" "$MAC_FW_DIR/Versions/A/$FW_NAME"

# Copy EVERY SPM-generated resource bundle next to the dylib into the framework
# Resources/ (e.g. swift-transformers_Hub.bundle — gpt2/t5 tokenizer configs).
# MinerUKit itself declares no resources, but its dependencies do, and their
# `Bundle.module` accessors fatalError at runtime if the bundle is not found
# under this framework's Resources/.
MAC_SPM_BIN="$(swift build -c release --show-bin-path)"
for b in "$MAC_SPM_BIN"/*.bundle; do
    [ -d "$b" ] || continue
    /usr/bin/ditto "$b" "$MAC_FW_DIR/Versions/A/Resources/$(basename "$b")"
    echo "Bundled dependency resource $(basename "$b") into macOS framework"
done

# MLX's Metal shader library is NO LONGER bundled inside the framework. Both
# MinerUKit and PetalASR now share ONE copy, vendored into the app's Resources
# and pointed at via mlx_metal_set_metallib_path at runtime (see the host app's
# MLXSharedMetallib / loaders). We still COMPILE it here, into a sidecar dir, so
# Scripts/pack-mlx-metallib.sh can pick it up — but it does not go into the
# framework.
echo "=== Building mlx.metallib (MLX Metal kernels, macosx) -> sidecar ==="
mkdir -p "$BUILD_DIR/metallib/macos-arm64"
build_metallib macosx "$BUILD_DIR/metallib/macos-arm64/mlx.metallib"
echo "Compiled shared mlx.metallib ($(du -h "$BUILD_DIR/metallib/macos-arm64/mlx.metallib" | cut -f1)) (NOT bundled into framework)"

# Generate Info.plist (macOS)
cat > "$MAC_FW_DIR/Versions/A/Resources/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>MinerUKit</string>
	<key>CFBundleIdentifier</key>
	<string>com.playstone.petal.MinerUKit</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MinerUKit</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>MacOSX</string>
	</array>
	<key>LSMinimumSystemVersion</key>
	<string>${MACOS_DEPLOYMENT_TARGET}</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# Module map (framework is loaded via dlopen + ObjC runtime; no swiftinterface
# consumption needed, but a modulemap keeps the bundle well-formed).
cat > "$MAC_FW_DIR/Versions/A/Modules/module.modulemap" << 'MODULEMAP'
framework module MinerUKit {
    export *
    module * { export * }
}
MODULEMAP

# Versioned symlinks (macOS framework layout).
( cd "$MAC_FW_DIR" \
    && ln -s A Versions/Current \
    && ln -s Versions/Current/$FW_NAME $FW_NAME \
    && ln -s Versions/Current/Resources Resources \
    && ln -s Versions/Current/Modules Modules )

# ============================================================================
# SLICE: iOS arm64  (xcodebuild archive → .framework)  [device only]
# ============================================================================
# xcodebuild cross-compiles the package graph for the iOS device SDK and emits
# the dynamic MinerUKit binary (the manifest sed above made the product
# .dynamic). Unlike `swift build`, xcodebuild does NOT assemble a .framework at
# a predictable path, so we build to a known SYMROOT and stage the dylib into a
# FLAT iOS framework (no Versions/). The metallib is compiled separately — same
# as the macOS slice — because MLX loads it from disk at runtime.
#
# No simulator slice (MLX requires a real GPU). CODE_SIGNING_ALLOWED=NO keeps it
# offline; the app's embed phase re-signs with the real identity at app build.

echo "=== Building $PRODUCT (iOS ${IOS_DEPLOYMENT_TARGET}, release, arm64 device) ==="
IOS_DD="$BUILD_DIR/ios-dd"
rm -rf "$IOS_DD"
xcodebuild build \
    -scheme "$PRODUCT" \
    -destination "generic/platform=iOS" \
    -configuration Release \
    -derivedDataPath "$IOS_DD" \
    CODE_SIGNING_ALLOWED=NO \
    IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    | tail -20

# xcodebuild emits the dynamic product as a .framework under PackageFrameworks.
IOS_PRODUCTS="$IOS_DD/Build/Products/Release-iphoneos"
IOS_SRC_FW="$(find "$IOS_PRODUCTS" -maxdepth 3 -name "${FW_NAME}.framework" -type d 2>/dev/null | head -1)"
if [ -z "$IOS_SRC_FW" ]; then
    echo "ERROR: no iOS framework found under $IOS_PRODUCTS" >&2
    echo "  products dir:"; find "$IOS_PRODUCTS" -maxdepth 3 2>&1 | head -40
    exit 1
fi

echo "=== Constructing iOS flat .framework bundle ==="
IOS_FW_DIR="$BUILD_DIR/ios-arm64/${FW_NAME}.framework"
rm -rf "$BUILD_DIR/ios-arm64"
mkdir -p "$BUILD_DIR/ios-arm64"
# Copy the xcodebuild-produced framework VERBATIM. It already has the correct
# flat iOS layout AND a binary-plist Info.plist carrying every key installd
# validates on-device (DT*, UIDeviceFamily, UIRequiredDeviceCapabilities, ...).
# Do NOT regenerate Info.plist: a hand-written XML plist is rejected at install
# time with "Info.plist had none of the keys that we expect" (installd requires
# a binary plist with those build keys for an embedded iOS framework).
cp -R "$IOS_SRC_FW" "$IOS_FW_DIR"
install_name_tool -id "@rpath/${FW_NAME}.framework/${FW_NAME}" "$IOS_FW_DIR/$FW_NAME"

# Flatten every SPM resource bundle (from the macOS bin-path, Contents-style)
# into the iOS framework's flat Resources/ so dependency `Bundle.module`
# accessors (e.g. swift-transformers_Hub) resolve on-device.
mkdir -p "$IOS_FW_DIR/Resources"
for b in "$MAC_SPM_BIN"/*.bundle; do
    [ -d "$b" ] || continue
    name="$(basename "$b")"
    dst="$IOS_FW_DIR/Resources/$name"
    rm -rf "$dst"; mkdir -p "$dst"
    if [ -d "$b/Contents/Resources" ]; then
        cp -R "$b/Contents/Resources/." "$dst/"
    else
        cp -R "$b/." "$dst/"
    fi
    cat > "$dst/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleIdentifier</key><string>${name%.bundle}-resources</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>${name%.bundle}</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
</dict>
</plist>
PLIST
    echo "Flattened dependency resource $name into iOS framework"
done
echo "=== Building mlx.metallib (MLX Metal kernels, iphoneos) -> sidecar ==="
mkdir -p "$BUILD_DIR/metallib/ios-arm64" "$IOS_FW_DIR/Modules"
build_metallib iphoneos "$BUILD_DIR/metallib/ios-arm64/mlx.metallib"
echo "Compiled shared mlx.metallib ($(du -h "$BUILD_DIR/metallib/ios-arm64/mlx.metallib" | cut -f1)) (NOT bundled into iOS framework)"

# Add a modulemap only if xcodebuild did not already emit one.
if [ ! -f "$IOS_FW_DIR/Modules/module.modulemap" ]; then
cat > "$IOS_FW_DIR/Modules/module.modulemap" << 'MODULEMAP'
framework module MinerUKit {
    export *
    module * { export * }
}
MODULEMAP
fi

# ============================================================================
# Assemble xcframework
# ============================================================================

echo "=== Creating xcframework ==="
xcodebuild -create-xcframework \
    -framework "$MAC_FW_DIR" \
    -framework "$IOS_FW_DIR" \
    -output "$BUILD_DIR/${FW_NAME}.xcframework"

echo "=== Zipping xcframework ==="
( cd "$BUILD_DIR" && zip -r -y ${FW_NAME}.xcframework.zip ${FW_NAME}.xcframework >/dev/null )

echo "=== Checksum ==="
shasum -a 256 "${BUILD_DIR}/${FW_NAME}.xcframework.zip"

echo ""
echo "=== Done ==="
echo "Output: $BUILD_DIR/${FW_NAME}.xcframework"
echo "Slices: macos-arm64 (macOS ${MACOS_DEPLOYMENT_TARGET}), ios-arm64 (iOS ${IOS_DEPLOYMENT_TARGET})"
echo ""
echo "To vendor into the Petal app:"
echo "  rm -rf <petal>/Frameworks/${FW_NAME}.xcframework"
echo "  cp -R $BUILD_DIR/${FW_NAME}.xcframework <petal>/Frameworks/"
