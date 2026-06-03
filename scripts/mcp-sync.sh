#!/usr/bin/env bash
# mcp-sync.sh — 同步 Hermes Agent 的 mcp_servers 配置到 mcp2cli baked tools
# 读取 $HERMES_HOME/config.yaml 中的 mcp_servers，为每个 server 生成 mcp2cli bake 配置
# 
# 用法:
#   scripts/mcp-sync.sh [--config path/to/config.yaml] [--dry-run]
#
# 环境变量:
#   HERMES_HOME          — Hermes 数据目录 (默认: hermes_data)
#   MCP2CLI_CONFIG_DIR   — mcp2cli 配置目录 (默认: ~/.config/mcp2cli)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="${1:-${HERMES_HOME:-$PROJECT_DIR/hermes_data}/config.yaml}"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --config=*) CONFIG_FILE="${arg#*=}" ;;
    --config) shift; CONFIG_FILE="$1" ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "❌ 配置文件不存在: $CONFIG_FILE" >&2
  exit 1
fi

# 检查是否有 python3 和 PyYAML
if ! command -v python3 &>/dev/null; then
  echo "❌ 需要 python3" >&2
  exit 1
fi

# 用 Python 解析 YAML 中的 mcp_servers，输出 JSON 供后续处理
SERVERS_JSON=$(python3 -c "
import yaml, json, sys

with open('$CONFIG_FILE', encoding='utf-8') as f:
    cfg = yaml.safe_load(f) or {}

servers = cfg.get('mcp_servers', {})
if not isinstance(servers, dict):
    print('{}')
    sys.exit(0)

result = {}
for name, scfg in servers.items():
    if not isinstance(scfg, dict):
        continue
    enabled = str(scfg.get('enabled', True)).strip().lower()
    if enabled in {'0', 'false', 'no', 'off'}:
        continue

    entry = {}

    transport = scfg.get('transport', '')

    # stdio 模式
    if scfg.get('command'):
        cmd = scfg['command']
        args = scfg.get('args', [])
        if isinstance(args, list):
            full_cmd = ' '.join([cmd] + [str(a) for a in args])
        else:
            full_cmd = cmd
        entry['mcp_stdio'] = full_cmd

    # HTTP/SSE 模式
    elif scfg.get('url'):
        entry['mcp'] = scfg['url']
        if transport:
            entry['transport'] = transport
        headers = scfg.get('headers', {})
        if isinstance(headers, dict):
            for hk, hv in headers.items():
                entry.setdefault('auth_header', []).append(f'{hk}:{hv}')

    else:
        continue  # 没有 command 也没有 url，跳过

    # 环境变量
    env = scfg.get('env', {})
    if isinstance(env, dict):
        entry['env'] = [f'{k}={v}' for k, v in env.items()]

    # 超时
    if scfg.get('timeout'):
        entry['timeout'] = scfg['timeout']

    result[name] = entry

print(json.dumps(result, ensure_ascii=False))
")

echo "📋 从 $CONFIG_FILE 读取到以下 MCP 服务器:"
echo "$SERVERS_JSON" | python3 -c "
import json, sys
servers = json.load(sys.stdin)
if not servers:
    print('  (无已启用的 MCP 服务器)')
    sys.exit(0)
for name, cfg in servers.items():
    mode = 'stdio' if 'mcp_stdio' in cfg else 'http'
    target = cfg.get('mcp_stdio', cfg.get('mcp', ''))
    print(f'  • {name} [{mode}]: {target[:80]}')
"

if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "🔍 DRY RUN — 以下命令将会执行:"
  echo "$SERVERS_JSON" | python3 -c "
import json, sys
servers = json.load(sys.stdin)
for name, cfg in servers.items():
    parts = ['mcp2cli', 'bake', 'create', name]
    if 'mcp_stdio' in cfg:
        parts.append(f'--mcp-stdio \"{cfg[\"mcp_stdio\"]}\"')
    elif 'mcp' in cfg:
        parts.append(f'--mcp \"{cfg[\"mcp\"]}\"')
        if cfg.get('transport'):
            parts.append(f'--transport {cfg[\"transport\"]}')
    for ah in cfg.get('auth_header', []):
        parts.append(f'--auth-header \"{ah}\"')
    for env in cfg.get('env', []):
        parts.append(f'--env \"{env}\"')
    print('  ' + ' '.join(parts))
"
  exit 0
fi

echo ""
echo "🔄 同步中..."

# 逐个创建 baked tool
echo "$SERVERS_JSON" | python3 -c "
import json, sys, subprocess

servers = json.load(sys.stdin)
if not servers:
    print('  跳过 — 没有需要同步的服务器')
    sys.exit(0)

for name, cfg in servers.items():
    # 先删除已有的
    subprocess.run(['mcp2cli', 'bake', 'remove', name],
                   capture_output=True, text=True)

    cmd = ['mcp2cli', 'bake', 'create', name]
    if 'mcp_stdio' in cfg:
        cmd.extend(['--mcp-stdio', cfg['mcp_stdio']])
    elif 'mcp' in cfg:
        cmd.extend(['--mcp', cfg['mcp']])
        if cfg.get('transport'):
            cmd.extend(['--transport', cfg['transport']])
    for ah in cfg.get('auth_header', []):
        cmd.extend(['--auth-header', ah])
    for env in cfg.get('env', []):
        cmd.extend(['--env', env])

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        print(f'  ✅ {name}')
    else:
        err = result.stderr.strip() or result.stdout.strip()
        print(f'  ❌ {name}: {err}')
"

echo ""
echo "✅ 同步完成! 使用以下命令测试:"
echo "   mcp2cli bake list"
echo "   mcp2cli @<server-name> --list"
