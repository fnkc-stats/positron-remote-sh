#!/usr/bin/env bash
# ping: what this host runs and serves (docs/spec.md «Protocol and capabilities»; src/agent.ts ping). PingResult:
# version, protocol, minProtocol, capabilities, user, requiresProvenance, and trustRootRefreshed (the trust root's
# mtime, ISO) when provenance is required. Capabilities are those the installed request files declare
# ("# fnkc-capabilities: …", request.sh), so a host advertises only what it has.
source "$FNKC_LIB/request.sh"

FNKC_PROTOCOL=1
FNKC_MIN_PROTOCOL=1

capabilities() {
  local f line cap
  local -a found=() words
  for f in "$FNKC_ROOT"/requests/*.sh; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      read -r -a words <<<"${line#'# fnkc-capabilities:'}"
      for cap in "${words[@]}"; do
        is_match '[a-z][a-z0-9]*(-[a-z0-9]+)*-v[0-9]+' "$cap" 64 || die "bad capability in ${f##*/}: $cap"
        found+=("$cap")
      done
    done < <(grep -E '^# fnkc-capabilities:( [a-z0-9-]+)+$' -- "$f" || true)
  done
  ((${#found[@]})) || return 0
  printf '%s\n' "${found[@]}" | sort -u
}

refreshed=''
if [[ "$FNKC_REQUIRE_PROVENANCE" == true && -f "$FNKC_TRUSTED_ROOT_FILE" ]]; then
  refreshed="$(date -u -r "$FNKC_TRUSTED_ROOT_FILE" '+%Y-%m-%dT%H:%M:%S.%3NZ')"
fi

caps="$(capabilities)"
jq -cn --arg version "$FNKC_VERSION" --argjson protocol "$FNKC_PROTOCOL" --argjson min "$FNKC_MIN_PROTOCOL" \
  --arg caps "$caps" --arg user "$FNKC_USER" --argjson prov "$FNKC_REQUIRE_PROVENANCE" --arg refreshed "$refreshed" '
  {version: $version, protocol: $protocol, minProtocol: $min,
   capabilities: ($caps | split("\n") | map(select(. != ""))), user: $user, requiresProvenance: $prov}
  + (if $prov and $refreshed != "" then {trustRootRefreshed: $refreshed} else {} end)'
