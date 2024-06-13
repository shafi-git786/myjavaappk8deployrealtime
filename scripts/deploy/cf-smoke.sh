#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset
# set -o xtrace

SCRIPT_NAME=$(basename "$0")

##
## Global error handling method to assist with debugging if an error would
## occur.
##
## INPUT(S):
##  $1: error_message
##  $2: exit_code
##
function error_exit() {
    echo "${SCRIPT_NAME}: ${1:-"Unknown Error"}" 1>&2
    echo "##teamcity[message text='$1' errorDetails='${SCRIPT_NAME}:$1' status='ERROR']"
    exit "$2"
}

##
## Invokes the final clean up activities for the script.
##
## This method is registered with the trap command prior to invoking the
## "main" and will be called automatically on those exit conditions.
##
function clean_up() {
    echo "clean up"
}

##
## Invoke the deployed apps health check.
##
## Naively assume that any non-200 response code is an error that should stop
## the deploy.
##
## INPUT(S):
##  $1: app_name - the application name to use
##  $2: cf_domain - the target CloudFoundry domain
##
function main() {
    local app_name="${1:?"Usage: ${SCRIPT_NAME} [app_name] [cf_domain]"}"
    local cf_domain="${2:?"Usage: ${SCRIPT_NAME} [app_name] [cf_domain]"}"

    echo "##teamcity[progressStart 'check /manage/health']"
    # TODO remove --insecure when the certs in sandbox are working
    curl --fail --insecure "https://${app_name}.${cf_domain}/manage/health" ||
        error_exit "$LINENO: health check failed for ${app_name} on ${cf_domain}" $?
    echo "##teamcity[progressFinish 'check /health']"
}

##
trap clean_up INT TERM EXIT
main "$@"
