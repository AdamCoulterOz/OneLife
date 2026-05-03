#!/usr/bin/env bash
set -euo pipefail

platform="${1:?platform required}"
package_label="${2:-v434-floorfix_d435}"
data_version_expected="${3:-435}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$(cd "$repo_root/.." && pwd)"
data_root="$workspace_root/OneLifeData7"
dist_root="$repo_root/dist"
package_root="$dist_root/OneLife_${package_label}_${platform}"
payload_root="$package_root/OneLife_${package_label}"

if [[ ! -d "$workspace_root/minorGems" ]]; then
    echo "Missing sibling minorGems checkout at $workspace_root/minorGems" >&2
    exit 1
fi

if [[ ! -d "$data_root" ]]; then
    echo "Missing sibling OneLifeData7 checkout at $data_root" >&2
    exit 1
fi

data_version="$(tr -d '\r\n' < "$data_root/dataVersionNumber.txt")"
if [[ "$data_version" != "$data_version_expected" ]]; then
    echo "OneLifeData7 dataVersionNumber.txt is $data_version, expected $data_version_expected" >&2
    exit 1
fi

ensure_image_convert() {
    if command -v convert >/dev/null 2>&1 &&
        convert -version 2>/dev/null | grep -qi 'ImageMagick'; then
        return 0
    fi

    if command -v magick >/dev/null 2>&1 &&
        magick -version 2>/dev/null | grep -qi 'ImageMagick'; then
        local tools_dir="${RUNNER_TEMP:-/tmp}/one-life-tools"
        mkdir -p "$tools_dir"
        printf '#!/usr/bin/env bash\nexec magick "$@"\n' > "$tools_dir/convert"
        chmod +x "$tools_dir/convert"
        export PATH="$tools_dir:$PATH"
        return 0
    fi

    echo "ImageMagick convert is required to regenerate gameSource/*.tga assets." >&2
    exit 1
}

rm -rf "$package_root"
mkdir -p "$payload_root"

copy_dir() {
    local src="$1"
    local dest="$2"
    mkdir -p "$dest"
    cp -R "$src"/. "$dest"/
}

copy_common_payload() {
    mkdir -p \
        "$payload_root/graphics" \
        "$payload_root/otherSounds" \
        "$payload_root/settings" \
        "$payload_root/languages" \
        "$payload_root/reverbCache" \
        "$payload_root/groundTileCache" \
        "$payload_root/mods" \
        "$payload_root/steamModUploads" \
        "$payload_root/import_add" \
        "$payload_root/import_replace"

    copy_dir "$repo_root/gameSource/graphics" "$payload_root/graphics"
    copy_dir "$repo_root/gameSource/otherSounds" "$payload_root/otherSounds"
    copy_dir "$repo_root/gameSource/settings" "$payload_root/settings"
    copy_dir "$repo_root/gameSource/languages" "$payload_root/languages"

    cp "$repo_root/gameSource/language.txt" "$payload_root/"
    cp "$repo_root/gameSource/us_english_60.txt" "$payload_root/"
    cp "$repo_root/gameSource/reverbImpulseResponse.aiff" "$payload_root/"
    cp "$repo_root/gameSource/wordList.txt" "$payload_root/"
    cp "$repo_root/documentation/Readme.txt" "$payload_root/"
    cp "$repo_root/no_copyright.txt" "$payload_root/"

    copy_dir "$data_root/sprites" "$payload_root/sprites"
    copy_dir "$data_root/objects" "$payload_root/objects"
    copy_dir "$data_root/categories" "$payload_root/categories"
    copy_dir "$data_root/transitions" "$payload_root/transitions"
    copy_dir "$data_root/animations" "$payload_root/animations"
    copy_dir "$data_root/music" "$payload_root/music"
    copy_dir "$data_root/sounds" "$payload_root/sounds"
    copy_dir "$data_root/ground" "$payload_root/ground"
    copy_dir "$data_root/contentSettings" "$payload_root/contentSettings"
    cp "$data_root/dataVersionNumber.txt" "$payload_root/"

    rm -f \
        "$payload_root/settings/email.ini" \
        "$payload_root/settings/accountKey.ini" \
        "$payload_root/settings/loginSuccess.ini" \
        "$payload_root/settings/countingOnVsync.ini" \
        "$payload_root/settings/targetFrameRate.ini"
}

build_regenerate_caches() {
    case "$platform" in
        windows)
            ( cd "$repo_root/gameSource" && sh ./makeRegenerateCachesWindows )
            if [[ -f "$repo_root/gameSource/regenerateCaches.exe" ]]; then
                cp "$repo_root/gameSource/regenerateCaches.exe" "$payload_root/"
            elif [[ -f "$repo_root/gameSource/regenerateCaches" ]]; then
                cp "$repo_root/gameSource/regenerateCaches" "$payload_root/regenerateCaches.exe"
            else
                echo "makeRegenerateCachesWindows did not produce regenerateCaches.exe" >&2
                exit 1
            fi
            ( cd "$payload_root" && ./regenerateCaches.exe )
            rm -f "$payload_root/regenerateCaches.exe"
            ;;
        *)
            ( cd "$repo_root/gameSource" && sh ./makeRegenerateCaches )
            cp "$repo_root/gameSource/regenerateCaches" "$payload_root/"
            ( cd "$payload_root" && ./regenerateCaches )
            rm -f "$payload_root/regenerateCaches"
            ;;
    esac

    find "$payload_root" -name 'bin_*cache.fcz' -delete
}

build_linux() {
    ensure_image_convert
    ( cd "$repo_root" && ./configure 1 )
    make -C "$repo_root/gameSource"

    copy_common_payload
    cp "$repo_root/gameSource/OneLife" "$payload_root/OneLifeApp"
    build_regenerate_caches
    chmod +x "$payload_root/OneLifeApp"

    ( cd "$package_root" && tar czf "$dist_root/OneLife_${package_label}_Linux.tar.gz" "OneLife_${package_label}" )
}

copy_macos_dylibs() {
    local app_path="$1"
    local exe_path="$app_path/Contents/MacOS/OneLife"
    local frameworks_path="$app_path/Contents/Frameworks"
    mkdir -p "$frameworks_path"

    # Homebrew sdl12-compat links through SDL2.  Copy any Homebrew dylibs that
    # the binary names directly, then make their install names bundle-relative.
    local dylibs
    dylibs="$(otool -L "$exe_path" | awk '/\/opt\/homebrew|\/usr\/local/ { print $1 }')"

    for dylib in $dylibs; do
        cp -L "$dylib" "$frameworks_path/"
        install_name_tool -change "$dylib" "@executable_path/../Frameworks/$(basename "$dylib")" "$exe_path"
    done

    local changed=1
    while [[ "$changed" == "1" ]]; do
        changed=0
        for bundled in "$frameworks_path"/*.dylib; do
            [[ -e "$bundled" ]] || continue
            local deps
            deps="$(otool -L "$bundled" | awk '/\/opt\/homebrew|\/usr\/local/ { print $1 }')"
            for dep in $deps; do
                local dep_base
                dep_base="$(basename "$dep")"
                if [[ ! -e "$frameworks_path/$dep_base" ]]; then
                    cp -L "$dep" "$frameworks_path/"
                    changed=1
                fi
                install_name_tool -change "$dep" "@loader_path/$dep_base" "$bundled" || true
            done
        done
    done
}

sign_and_notarize_macos() {
    local app_path="$1"
    local zip_path="$2"

    if [[ -z "${APPLE_CERTIFICATE_P12_BASE64:-}" ]]; then
        echo "APPLE_CERTIFICATE_P12_BASE64 not set; leaving macOS app unsigned."
        return 0
    fi

    local keychain_path="$RUNNER_TEMP/one-life-signing.keychain-db"
    local keychain_password="${APPLE_KEYCHAIN_PASSWORD:-$(openssl rand -hex 24)}"
    local certificate_path="$RUNNER_TEMP/developer_id_application.p12"

    echo "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$certificate_path"
    security create-keychain -p "$keychain_password" "$keychain_path"
    security set-keychain-settings -lut 21600 "$keychain_path"
    security unlock-keychain -p "$keychain_password" "$keychain_path"
    security import "$certificate_path" -P "$APPLE_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$keychain_path"
    security list-keychain -d user -s "$keychain_path"
    security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain_path"

    local identity="${APPLE_CODESIGN_IDENTITY:-}"
    if [[ -z "$identity" ]]; then
        identity="$(security find-identity -v -p codesigning "$keychain_path" | awk -F '"' '/Developer ID Application/ { print $2; exit }')"
    fi

    if [[ -z "$identity" ]]; then
        echo "No Developer ID Application identity found in imported certificate." >&2
        exit 1
    fi

    find "$app_path/Contents/Frameworks" -name '*.dylib' -print0 | while IFS= read -r -d '' dylib; do
        codesign --force --timestamp --options runtime --sign "$identity" "$dylib"
    done

    codesign --force --timestamp --options runtime --sign "$identity" "$app_path"
    codesign --verify --deep --strict --verbose=2 "$app_path"

    if [[ -z "${APPLE_ID:-}" || -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" || -z "${APPLE_TEAM_ID:-}" ]]; then
        echo "Apple notarization credentials not set; app was signed but not notarized."
        return 0
    fi

    local notary_zip="$RUNNER_TEMP/OneLife_${package_label}_app.zip"
    rm -f "$notary_zip"
    ditto -c -k --keepParent "$app_path" "$notary_zip"

    xcrun notarytool submit "$notary_zip" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait

    xcrun stapler staple "$app_path"
    codesign --verify --deep --strict --verbose=2 "$app_path"

    rm -f "$zip_path"
    ( cd "$package_root" && ditto -c -k --sequesterRsrc --keepParent "OneLife_${package_label}" "$zip_path" )
}

build_macos() {
    ensure_image_convert
    ( cd "$repo_root" && ./configure 2 )

    local sdl_prefix
    sdl_prefix="$(brew --prefix sdl12-compat)"

    make -C "$repo_root/gameSource" \
        PLATFORM_COMPILE_FLAGS="-DBSD -D__mac__ -I/System/Library/Frameworks/OpenGL.framework/Headers -I${sdl_prefix}/include" \
        PLATFORM_LINK_FLAGS="-framework OpenGL ../../minorGems/game/platforms/SDL/mac/SDLMain.m -L${sdl_prefix}/lib -lSDL -framework Cocoa"

    copy_common_payload

    # The legacy SDL launcher chdirs to the .app's parent, so keep the app
    # next to the data folders and name it after the release payload.
    local app_path="$payload_root/OneLife_${package_label}.app"
    cp -R "$repo_root/build/macOSX/OneLife.app" "$app_path"
    rm -f "$app_path/Contents/MacOS/empty.txt" "$app_path/Contents/Frameworks/empty.txt"
    cp "$repo_root/gameSource/OneLife" "$app_path/Contents/MacOS/OneLife"
    chmod +x "$app_path/Contents/MacOS/OneLife"
    copy_macos_dylibs "$app_path"

    build_regenerate_caches

    local zip_path="$dist_root/OneLife_${package_label}_macOS.zip"
    ( cd "$package_root" && ditto -c -k --sequesterRsrc --keepParent "OneLife_${package_label}" "$zip_path" )
    sign_and_notarize_macos "$app_path" "$zip_path"
}

windows_dependency_paths() {
    local binary="$1"

    ldd "$binary" | awk '
        /=>/ {
            if ($(NF - 1) ~ /^\//) {
                print $(NF - 1)
            }
            next
        }
        /^[[:space:]]*\// {
            print $1
        }'
}

is_windows_system_dependency() {
    local dep_lower
    dep_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

    [[ "$dep_lower" == /c/windows/* || "$dep_lower" == /windows/* ]]
}

copy_windows_runtime_dependencies() {
    local binary="$1"

    if ! command -v ldd >/dev/null 2>&1; then
        echo "ldd not found; cannot validate Windows runtime DLL dependencies" >&2
        exit 1
    fi

    local -a queue=("$binary")
    local -a seen=()
    local current

    while ((${#queue[@]} > 0)); do
        current="${queue[0]}"
        queue=("${queue[@]:1}")

        local current_key
        current_key="$(cygpath -am "$current" | tr '[:upper:]' '[:lower:]')"

        local already_seen=false
        local seen_key
        for seen_key in "${seen[@]}"; do
            if [[ "$seen_key" == "$current_key" ]]; then
                already_seen=true
                break
            fi
        done
        if [[ "$already_seen" == true ]]; then
            continue
        fi
        seen+=("$current_key")

        local dep
        while IFS= read -r dep; do
            [[ -n "$dep" ]] || continue
            is_windows_system_dependency "$dep" && continue

            if [[ ! -f "$dep" ]]; then
                echo "Required Windows runtime dependency missing: $dep" >&2
                exit 1
            fi

            local dep_base="$payload_root/$(basename "$dep")"
            if [[ ! -f "$dep_base" ]]; then
                cp "$dep" "$payload_root/"
                queue+=("$dep_base")
            fi
        done < <(windows_dependency_paths "$current")
    done
}

validate_windows_runtime_dependencies() {
    local failed=false
    local binary

    for binary in "$payload_root/OneLife.exe" "$payload_root"/*.dll; do
        [[ -f "$binary" ]] || continue

        if ldd "$binary" | grep -qi 'not found'; then
            echo "Unresolved Windows runtime dependencies for $binary:" >&2
            ldd "$binary" >&2
            failed=true
        fi
    done

    if [[ "$failed" == true ]]; then
        exit 1
    fi

    {
        echo "Windows runtime dependency manifest"
        echo
        for binary in "$payload_root/OneLife.exe" "$payload_root"/*.dll; do
            [[ -f "$binary" ]] || continue
            echo "## $(basename "$binary")"
            ldd "$binary"
            echo
        done
    } > "$payload_root/windows-runtime-dependencies.txt"
}

build_windows() {
    ensure_image_convert
    ( cd "$repo_root" && ./configure 3 )
    make -C "$repo_root/gameSource"

    copy_common_payload
    if [[ -f "$repo_root/gameSource/OneLife.exe" ]]; then
        cp "$repo_root/gameSource/OneLife.exe" "$payload_root/"
    elif [[ -f "$repo_root/gameSource/OneLife" ]]; then
        cp "$repo_root/gameSource/OneLife" "$payload_root/OneLife.exe"
    else
        echo "Windows build did not produce OneLife.exe" >&2
        exit 1
    fi

    if ! command -v cygpath >/dev/null 2>&1; then
        echo "cygpath not found; cannot locate MSYS2/MinGW runtime DLLs" >&2
        exit 1
    fi

    copy_windows_runtime_dependencies "$payload_root/OneLife.exe"
    validate_windows_runtime_dependencies

    build_regenerate_caches

    ( cd "$package_root" && 7z a "$dist_root/OneLife_${package_label}_Windows.zip" "OneLife_${package_label}" )
}

rm -rf "$dist_root"
mkdir -p "$dist_root"

case "$platform" in
    linux) build_linux ;;
    macos) build_macos ;;
    windows) build_windows ;;
    *) echo "Unknown platform: $platform" >&2; exit 1 ;;
esac
