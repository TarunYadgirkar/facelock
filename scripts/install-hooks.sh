#!/bin/bash
# Installs the pre-commit hook that runs check-no-biometrics.sh on staged files. Each clone needs
# this once. The hook does nothing in a checkout without the script (older branches, other worktrees).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
hooks=$(git -C "$root" rev-parse --git-path hooks)
mkdir -p "$hooks"
cat > "$hooks/pre-commit" <<'HOOK'
#!/bin/bash
check="$(git rev-parse --show-toplevel)/scripts/check-no-biometrics.sh"
[[ -f "$check" ]] || exit 0
exec /bin/bash "$check" --staged
HOOK
chmod +x "$hooks/pre-commit"
echo "installed $hooks/pre-commit"
