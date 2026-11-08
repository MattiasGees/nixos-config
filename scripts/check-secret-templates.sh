#!/usr/bin/env bash
# Guard the op-secrets templates (modules/server/op-secrets.nix) in this public
# repo: a template may hold plain config, but never a secret. Each one needs a
# 1Password reference, a secret-named key must hold nothing but a reference, and
# comments must stay free of references (op inject scans them too).
#
#   scripts/check-secret-templates.sh              # every committed *.tpl
#   scripts/check-secret-templates.sh a.tpl b.tpl  # just these
#
# .github/workflows/checks.yml runs this on PRs.
set -euo pipefail

ref='\{\{ *op://[^/ ]+/[^/ ]+/[^/ }]+ *\}\}'
assignment='^[[:space:]]*"?([A-Za-z0-9_.-]+)"?[[:space:]]*[=:][[:space:]]*(.*)$'
secret_name='pass|secret|token|credential|key'
status=0

fail() {
  echo "$1:$2: $3" >&2
  status=1
}

check_line() {
  local file=$1 lineno=$2 line=$3 name value rest

  if [[ $line =~ ^[[:space:]]*# ]]; then
    if [[ $line == *'{{'* || $line == *op://* ]]; then
      fail "$file" "$lineno" "reference in a comment; op inject scans comments too"
    fi
    return 0
  fi

  rest=$(sed -E "s#$ref##g" <<<"$line")
  if [[ $rest == *'{{'* || $rest == *op://* ]]; then
    fail "$file" "$lineno" "malformed reference; expected {{ op://vault/item/field }}"
  fi

  if [[ $line =~ $assignment ]]; then
    name=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    value=${value#\"}
    value=${value%\"}
    if [[ -n $value ]] && grep -Eiq "$secret_name" <<<"$name" && ! grep -Eq "^$ref\$" <<<"$value"; then
      fail "$file" "$lineno" "$name must be a 1Password reference, not a literal value"
    fi
  fi
  return 0
}

if [ $# -eq 0 ]; then
  cd "$(dirname "$0")/.."
  # shellcheck disable=SC2046 # no template path contains whitespace
  set -- $(git ls-files '*.tpl')
fi

for file in "$@"; do
  grep -Eq "$ref" "$file" || fail "$file" 1 "no 1Password reference"
  lineno=0
  # shellcheck disable=SC2094 # fail only prints the file name
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    check_line "$file" "$lineno" "$line"
  done <"$file"
done

[ "$status" -eq 0 ] && echo "checked $# templates"
exit "$status"
