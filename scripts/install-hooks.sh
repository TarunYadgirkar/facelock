#!/bin/bash
# Installs the pre-commit hook that runs check-no-biometrics.sh on staged files.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
hooks=$(git -C "$root" rev-parse --git-path hooks)
mkdir -p "$hooks"
cat > "$hooks/pre-commit" <<'EOF'
#!/bin/bash
exec "$(git rev-parse --show-toplevel)/scripts/check-no-biometrics.sh" --staged
EOF
chmod +x "$hooks/pre-commit"
echo "installed $hooks/pre-commit"
