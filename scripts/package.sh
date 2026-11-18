#!/bin/sh
# Build self-contained trial bundles into dist/.
#
# Usage: scripts/package.sh [version]
#
# Nothing is downloaded and no external repository is read: the binary and the
# repository's own config assets are the whole bundle. Run this from any
# directory; paths are resolved from this script.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dist=${RIME_CONFIG_DIST_DIR:-"$root/dist"}
version=${1:-${RIME_CONFIG_VERSION:-0.2.0}}

# Explicit public asset allowlist. Anything else under config/ is user-local
# (frontends.json, private dictionaries, logs) and must never be shipped.
public_assets='
config/frontends.json.example
config/custom_phrase_user.dict.yaml.example
config/local/wanxiang.custom.yaml
config/common/default.custom.yaml
config/common/wanxiang_phrase.custom.yaml
config/frontends/squirrel/squirrel.custom.yaml
config/frontends/weasel/weasel.custom.yaml
config/frontends/hamster3/include_keyboard_rime_files.txt
'

copy_public_assets() {
	bundle=$1
	for rel in $public_assets; do
		src="$root/$rel"
		if [ ! -f "$src" ]; then
			echo "missing public asset: $rel" >&2
			exit 1
		fi
		mkdir -p "$(dirname "$bundle/$rel")"
		cp "$src" "$bundle/$rel"
	done
}

build() {
	os=$1
	arch=$2
	binary=$3
	bundle="$dist/$os-$arch"

	rm -rf "$bundle"
	mkdir -p "$bundle/config"

	echo "building $os/$arch -> $bundle"
	(
		cd "$root"
		CGO_ENABLED=0 GOOS=$os GOARCH=$arch \
			go build -trimpath -ldflags "-s -w" -o "$bundle/$binary" ./cmd/rime-config
	)
	copy_public_assets "$bundle"
	cp "$root/README.md" "$bundle/README.md"

	case "$os" in
	windows)
		(
			cd "$dist"
			rm -f "$os-$arch.zip"
			zip -qr "$os-$arch.zip" "$os-$arch"
		)
		;;
	*)
		(
			cd "$dist"
			rm -f "$os-$arch.tar.gz"
			tar -czf "$os-$arch.tar.gz" "$os-$arch"
		)
		;;
	esac
	printf '%s\n' "$version" >"$bundle/VERSION"
}

mkdir -p "$dist"
build windows amd64 rime-config.exe
build darwin arm64 rime-config
build darwin amd64 rime-config

echo "done: $dist"
