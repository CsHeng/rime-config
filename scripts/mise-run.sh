#!/bin/sh
# Thin wrapper used by the mise tasks: resolve the platform bundle, run from the
# project root and pass extra arguments through to the binary.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

mode=${1:-}
if [ -z "$mode" ]; then
	echo "usage: scripts/mise-run.sh <setup|info|plan|update|sync|package> [args...]" >&2
	exit 2
fi
shift

config="$root/config/frontends.json"

detect() {
	os=$(uname -s 2>/dev/null || echo unknown)
	arch=$(uname -m 2>/dev/null || echo unknown)
	case "$os" in
	Darwin) goos=darwin ;;
	MINGW* | MSYS* | CYGWIN*) goos=windows ;;
	*)
		echo "unsupported platform: $os (macOS and Windows only)" >&2
		exit 2
		;;
	esac
	case "$arch" in
	arm64 | aarch64) goarch=arm64 ;;
	x86_64 | amd64) goarch=amd64 ;;
	*)
		echo "unsupported architecture: $arch" >&2
		exit 2
		;;
	esac
	binary="$root/dist/$goos-$goarch/rime-config"
	if [ "$goos" = windows ]; then
		binary="$binary.exe"
	fi
}

require_config() {
	if [ ! -f "$config" ]; then
		echo "missing $config" >&2
		echo "run first: mise run setup (detects Squirrel/Weasel/Hamster3 and cloud sync folders)" >&2
		exit 2
	fi
}

require_binary() {
	detect
	if [ ! -x "$binary" ]; then
		echo "missing platform binary: $binary" >&2
		echo "run first: mise run package" >&2
		exit 2
	fi
}

has_user_config() {
	for arg in "$@"; do
		case "$arg" in
		--config | --config=*) return 0 ;;
		esac
	done
	return 1
}

run_tool() {
	mode_flag=$1
	shift
	if ! has_user_config "$@"; then
		require_config
		set -- --config "$config" "$@"
	fi
	if [ -n "$mode_flag" ]; then
		set -- "$mode_flag" "$@"
	fi
	require_binary
	exec "$binary" "$@"
}

case "$mode" in
setup)
	require_binary
	if ! has_user_config "$@"; then
		set -- --config "$config" "$@"
	fi
	exec "$binary" --setup "$@"
	;;
info)
	detect
	printf 'os=%s arch=%s\nbinary=%s\nconfig=%s exists=%s\n' \
		"$goos" "$goarch" "$binary" "$config" "$([ -f "$config" ] && echo yes || echo no)"
	if [ "$#" -gt 0 ]; then
		printf 'args=%s\n' "$*"
	fi
	;;
plan)
	run_tool --dry-run "$@"
	;;
update)
	run_tool '' "$@"
	;;
sync)
	run_tool --sync-only "$@"
	;;
package)
	exec "$root/scripts/package.sh" "$@"
	;;
*)
	echo "unknown task: $mode" >&2
	exit 2
	;;
esac
