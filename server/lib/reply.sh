# shellcheck shell=bash
# reply.sh: the reply envelope and the error codes (docs/spec.md «Reply envelope», «Error codes»; src/serve.ts
# answer, src/errors.ts). One line of JSON on stdout, always written by jq.
#
#   reply_ok <file>                              {"ok":true,"result":<the one JSON value in file>}
#   reply_error <message> [code] [extra-file]    {"ok":false,"error":…,"code":…} plus the fields of extra-file
#
# Requests do not call these: they fail through the helpers in serve.sh (fail, fail_code, fail_image_missing,
# fail_checkout_pins), and the dispatcher writes the reply.

[[ -n "${FNKC_REPLY_LOADED:-}" ]] && return 0
FNKC_REPLY_LOADED=1

# The complete list (src/errors.ts ErrorCode). `incompatible` is client-side only; the server never sends it.
FNKC_ERROR_CODES=(image-missing checkout-pins quota capacity busy incompatible unknown-command image-rejected
  provenance-refused replacement-not-ready)

is_error_code() {
  local c
  for c in "${FNKC_ERROR_CODES[@]}"; do [[ "${1-}" == "$c" ]] && return 0; done
  return 1
}

reply_ok() {
  jq -c -s 'if length == 1 then {ok: true, result: .[0]} else error("a result must be one JSON value") end' <"$1"
}

# extra-file: a JSON object with imageMissing or checkoutPins (only with codes image-missing / checkout-pins).
reply_error() {
  local message="${1-}" code="${2-}" extra="${3-}"
  if [[ -n "$code" ]] && ! is_error_code "$code"; then
    log err "reply: unknown error code dropped: $code"
    code=''
  fi
  jq -c -n --slurpfile extra "${extra:-/dev/null}" --arg error "$message" --arg code "$code" '
    {ok: false, error: $error}
    + (if $code == "" then {} else {code: $code} end)
    + (if $code == "image-missing" and ($extra[0].imageMissing | type) == "object"
         then {imageMissing: $extra[0].imageMissing}
       elif $code == "checkout-pins" and ($extra[0].checkoutPins | type) == "string"
         then {checkoutPins: $extra[0].checkoutPins}
       else {} end)'
}
