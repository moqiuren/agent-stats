#!/usr/bin/env bash
set -euo pipefail

REPO_SLUG="${AGENT_STATS_REPO:-moqiuren/agent-stats}"
ARCHIVE_PATH=""
MODE="auto"
APPLICATIONS_DIR="${AGENT_STATS_APPLICATIONS_DIR:-}"

usage() {
  cat <<'EOF'
用法: bash Scripts/install.sh [选项]
  --archive <path>           从本地 .zip 或 .dmg 安装包离线安装
  --release                  优先从 GitHub Releases 下载预编译包安装
  --from-source              强制从源码编译并安装
  --applications-dir <dir>   覆盖安装目标应用程序目录（默认 /Applications）
  -h, --help                 显示帮助
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive)
      [ "$#" -ge 2 ] || { echo "错误：--archive 需要指定文件路径" >&2; exit 1; }
      ARCHIVE_PATH="$2"
      MODE="archive"
      shift 2
      ;;
    --release)
      MODE="release"
      shift
      ;;
    --from-source)
      MODE="source"
      shift
      ;;
    --applications-dir)
      [ "$#" -ge 2 ] || { echo "错误：--applications-dir 需要指定目录" >&2; exit 1; }
      APPLICATIONS_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "错误：Agent Stats 仅支持 macOS。" >&2
  exit 1
fi

ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
  echo "错误：当前仅支持 Apple Silicon (arm64)，检测到：$ARCH" >&2
  exit 1
fi

OS_MAJOR="$(sw_vers -productVersion | awk -F. '{print $1}')"
if [ -n "$OS_MAJOR" ] && [ "$OS_MAJOR" -lt 13 ]; then
  echo "错误：需要 macOS 13.0 Ventura 或更高版本，当前为 $(sw_vers -productVersion)" >&2
  exit 1
fi

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
REPO_ROOT=""
if [ -n "$SCRIPT_SOURCE" ] && [ -f "$SCRIPT_SOURCE" ]; then
  CANDIDATE_ROOT="$(cd "$(dirname "$SCRIPT_SOURCE")/.." && pwd)"
  if [ -f "$CANDIDATE_ROOT/products.json" ] && [ -f "$CANDIDATE_ROOT/install.py" ] && [ -f "$CANDIDATE_ROOT/Package.swift" ]; then
    REPO_ROOT="$CANDIDATE_ROOT"
  fi
fi

if [ -z "$REPO_ROOT" ] && [ -f "./products.json" ] && [ -f "./install.py" ] && [ -f "./Package.swift" ]; then
  REPO_ROOT="$(pwd)"
fi

TMP_DIR="$(mktemp -d -t agent-stats-install-XXXXXX)"
MOUNT_DIR=""

cleanup() {
  if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
    /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

install_from_archive() {
  local archive="$1"
  local allow_untrusted_fallback="${2:-0}"
  if [ ! -f "$archive" ]; then
    echo "错误：找不到安装包 $archive" >&2
    exit 1
  fi
  local extract_dir="$TMP_DIR/extracted"
  mkdir -p "$extract_dir"
  case "$archive" in
    *.zip|*.ZIP)
      /usr/bin/ditto -x -k "$archive" "$extract_dir"
      ;;
    *.dmg|*.DMG)
      MOUNT_DIR="$TMP_DIR/mount"
      mkdir -p "$MOUNT_DIR"
      /usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$archive" >/dev/null
      local mounted_app=""
      mounted_app="$(find "$MOUNT_DIR" -maxdepth 2 -name "Agent Stats.app" -print -quit)"
      if [ -z "$mounted_app" ]; then
        echo "错误：DMG 中未找到 Agent Stats.app" >&2
        exit 1
      fi
      /usr/bin/ditto "$mounted_app" "$extract_dir/Agent Stats.app"
      /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
      MOUNT_DIR=""
      ;;
    *)
      echo "错误：仅支持 .zip 或 .dmg 安装包：$archive" >&2
      exit 1
      ;;
  esac

  local app_bundle=""
  if [ -d "$extract_dir/Agent Stats.app" ]; then
    app_bundle="$extract_dir/Agent Stats.app"
  else
    app_bundle="$(find "$extract_dir" -maxdepth 2 -name "Agent Stats.app" -print -quit)"
  fi
  if [ -z "$app_bundle" ] || [ ! -x "$app_bundle/Contents/MacOS/AgentStats" ]; then
    echo "错误：安装包内缺少有效可执行文件 Agent Stats.app/Contents/MacOS/AgentStats" >&2
    exit 1
  fi

  for attr in com.apple.quarantine com.apple.FinderInfo com.apple.ResourceFork; do
    /usr/bin/xattr -dr "$attr" "$app_bundle" >/dev/null 2>&1 || true
  done
  if ! /usr/bin/codesign --verify --deep --strict "$app_bundle"; then
    if [ "$allow_untrusted_fallback" = "1" ]; then
      echo "提示：预编译安装包签名证书未在本机受信任，自动切换为从源码构建并使用本机证书安装…" >&2
      return 2
    fi
    return 1
  fi

  if [ -n "$APPLICATIONS_DIR" ]; then
    "$app_bundle/Contents/MacOS/AgentStats" --install --applications-dir "$APPLICATIONS_DIR"
  else
    "$app_bundle/Contents/MacOS/AgentStats" --install
  fi
}

install_from_source_dir() {
  local source_dir="$1"
  if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    echo "错误：缺少 Xcode Command Line Tools，请先运行 xcode-select --install 完成安装后重试。" >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "错误：未找到 python3。" >&2
    exit 1
  fi
  echo "正在从源码编译并安装 Agent Stats…"
  if [ -n "$APPLICATIONS_DIR" ]; then
    (cd "$source_dir" && python3 install.py --applications-dir "$APPLICATIONS_DIR")
  else
    (cd "$source_dir" && python3 install.py)
  fi
}

fetch_latest_release_url() {
  /usr/bin/python3 - "$REPO_SLUG" <<'PY'
import json
import re
import sys
import urllib.request

repo = sys.argv[1]
url = f"https://api.github.com/repos/{repo}/releases/latest"
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "agent-stats-installer"})
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode("utf-8"))
except Exception:
    sys.exit(0)
assets = data.get("assets") or []
for pattern in (r"^Agent-Stats-.*-macos-arm64\.zip$", r"^Agent-Stats-.*\.dmg$"):
    for asset in assets:
        name = asset.get("name", "")
        dl = asset.get("browser_download_url", "")
        if dl and re.match(pattern, name):
            print(name)
            print(dl)
            sys.exit(0)
PY
}

if [ "$MODE" = "archive" ]; then
  install_from_archive "$ARCHIVE_PATH"
  exit 0
fi

if [ "$MODE" = "source" ] || { [ "$MODE" = "auto" ] && [ -n "$REPO_ROOT" ]; }; then
  if [ -z "$REPO_ROOT" ]; then
    echo "错误：未在 Agent Stats 源码目录内执行 --from-source。" >&2
    exit 1
  fi
  install_from_source_dir "$REPO_ROOT"
  exit 0
fi

RELEASE_INFO="$(fetch_latest_release_url || true)"
if [ -n "$RELEASE_INFO" ]; then
  ASSET_NAME="$(printf '%s\n' "$RELEASE_INFO" | sed -n '1p')"
  ASSET_URL="$(printf '%s\n' "$RELEASE_INFO" | sed -n '2p')"
  if [ -n "$ASSET_NAME" ] && [ -n "$ASSET_URL" ]; then
    echo "正在下载预编译安装包：$ASSET_NAME"
    DOWNLOADED="$TMP_DIR/$ASSET_NAME"
    /usr/bin/curl -fsSL "$ASSET_URL" -o "$DOWNLOADED"
    rc=0
    install_from_archive "$DOWNLOADED" 1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      exit 0
    elif [ "$rc" -ne 2 ]; then
      exit "$rc"
    fi
  fi
fi

echo "未检测到预编译 Release 包，正在拉取源码自动构建安装…"
if ! command -v git >/dev/null 2>&1; then
  echo "错误：未找到 git 且无可用的预编译 Release 包。" >&2
  exit 1
fi
CLONE_DIR="$TMP_DIR/repo"
/usr/bin/git clone --depth 1 "https://github.com/${REPO_SLUG}.git" "$CLONE_DIR"
install_from_source_dir "$CLONE_DIR"
