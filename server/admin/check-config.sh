#!/usr/bin/env bash
# fnkc-ctl admin check-config [--account <name>] [--agent-config <file>] [file]
#
# Prints the settings in force, defaults filled in, as pretty JSON; warns on stderr about keys that are not settings
# (with the setting a key is probably a typo of). Exit 1 with the reason when the file is invalid. Root is not
# required. The file is [file], else --agent-config, else /etc/fnkc-ctl-sh/agent.json if it exists (else all
# defaults). Defaults under "~" are the home of the gateway account, --account (default fnkcsh).
# Ported from positron-remote src/cli.ts (admin check-config).

FNKC_LIB="${FNKC_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)}"
# shellcheck source=server/lib/config.sh
source "$FNKC_LIB/config.sh"

usage() {
  die "usage: fnkc-ctl admin check-config [--account <name>] [--agent-config <file>] [file]"
}

account=fnkcsh option_file="" file="" have_file=0
while (($#)); do
  case "$1" in
    --account)
      (($# >= 2)) || usage
      account="$2"
      shift 2
      ;;
    --agent-config)
      (($# >= 2)) || usage
      option_file="$2"
      shift 2
      ;;
    --) shift && break ;;
    -*) usage ;;
    *)
      ((! have_file)) && [[ -n "$1" ]] || usage
      file="$1" have_file=1
      shift
      ;;
  esac
done
if (($#)); then
  ((! have_file && $# == 1)) && [[ -n "$1" ]] || usage
  file="$1"
fi
[[ -n "$file" ]] || file="$option_file"

home="$(config_account_home "$account")"
config_require "$file" "$home"

while IFS= read -r warning; do
  printf '%s: warning: %s\n' "$FNKC_LOG_TAG" "$warning" >&2
done < <(config_unknown_keys)
jq . <<<"$CFG_JSON"
