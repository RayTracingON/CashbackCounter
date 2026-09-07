#!/bin/bash
# 双击这个文件即可打开卡片模板编辑器（Finder 里双击，或终端里直接运行）。
cd "$(dirname "$0")/.." || exit 1
exec /usr/bin/env python3 tools/cardeditor/server.py "$@"
