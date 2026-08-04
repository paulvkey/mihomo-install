#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

while IFS= read -r file; do
    bash -n "$file"
done < <(find . -type f -name '*.sh' ! -path './.git/*' | sort)
sh -n system/profile.d/mihomo-system.sh system/profile.d/zz-mihomo-system-auto.sh

bash tests/run.sh
bash tests/mihomo_auth.sh

if command -v shellcheck >/dev/null 2>&1; then
    while IFS= read -r file; do
        shellcheck --severity=error "$file"
    done < <(find . -type f -name '*.sh' ! -path './.git/*' | sort)
else
    echo '[WARN] 未安装 shellcheck，已跳过静态检查。' >&2
fi

echo '[PASS] 项目检查全部完成。'
