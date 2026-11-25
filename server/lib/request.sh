# shellcheck shell=bash
# request.sh: what a gateway request file (server/requests/<request>.sh) sources first. serve.sh runs the file as
# its own bash process, with a clean environment it set itself, after the words passed grammar.sh and the user's key
# was rechecked; the file gets the validated values as "$@" and these variables:
#
#   FNKC_USER  FNKC_REQUEST  FNKC_ROOT  FNKC_LIB  FNKC_VERSION  FNKC_REQ_DIR (private, removed afterwards)
#   FNKC_AGENT_CONFIG  FNKC_KEYS_DIR  FNKC_REQUIRE_PROVENANCE (true|false)  FNKC_TRUSTED_ROOT_FILE
#   FNKC_STDIN_FILE    for requests with json stdin: the request document, at most 2 MiB, without NUL bytes
#
# The result: one JSON value on stdout (written with jq), exit 0. A refusal: one of
#
#   fail <message>                               error without a code
#   fail_code <code> <message>                   with a code from reply.sh
#   fail_image_missing <message> <image> <arch>  code image-missing with imageMissing {image, arch}
#   fail_checkout_pins <message> <image>         code checkout-pins with checkoutPins
#
# They record the error and exit 1; they work inside subshells and command substitutions too (the first one counts).
# Any other failure (set -e) answers "internal error". Also:
#
#   info <message>          progress on stderr
#   warn <message>          a warning on stderr, also kept for the journal line
#   journal_set <key> <value>...   extra fields for the journal line (journal.sh)
#
# A file declares the capabilities it adds with one comment line, collected by ping:
#
#   # fnkc-capabilities: qualified-stop-v1 checkout-query-v1

source "$FNKC_LIB/core.sh"
source "$FNKC_LIB/grammar.sh"
source "$FNKC_LIB/reply.sh"
source "$FNKC_LIB/journal.sh"

: "${FNKC_REQ_DIR:?request.sh: run through fnkc-ctl serve}"
_FNKC_JOURNAL_DIR="$FNKC_REQ_DIR"

# _request_error <json-object>: keep the first error and stop.
_request_error() {
  [[ -e "$FNKC_REQ_DIR/error" ]] || printf '%s\n' "$1" >"$FNKC_REQ_DIR/error"
  exit 1
}

fail() {
  _request_error "$(jq -cn --arg error "${1-}" '{error: $error}')"
}

fail_code() {
  is_error_code "${1-}" || die "fail_code: unknown error code"
  _request_error "$(jq -cn --arg code "$1" --arg error "${2-}" '{error: $error, code: $code}')"
}

fail_image_missing() {
  [[ "${3-}" == x64 || "${3-}" == arm64 ]] || die "fail_image_missing: arch must be x64 or arm64"
  _request_error "$(jq -cn --arg error "${1-}" --arg image "${2-}" --arg arch "$3" \
    '{error: $error, code: "image-missing", imageMissing: {image: $image, arch: $arch}}')"
}

fail_checkout_pins() {
  _request_error "$(jq -cn --arg error "${1-}" --arg image "${2-}" \
    '{error: $error, code: "checkout-pins", checkoutPins: $image}')"
}

info() {
  printf '==> %s\n' "$(_fnkc_oneline "$*")" >&2
}

warn() {
  journal_warn "$*"
  printf 'Warning: %s\n' "$(_fnkc_oneline "$*")" >&2
}
