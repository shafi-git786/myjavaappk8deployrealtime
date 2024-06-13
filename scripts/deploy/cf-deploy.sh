#!/usr/bin/env bash

set -o errexit
set -o pipefail
# set -o nounset
# set -o xtrace

SCRIPT_NAME=$(basename "$0")
DIR_NAME="$(dirname "$0")"

##
## Default usage message.
##
function usage() {
    echo "Usage: ${SCRIPT_NAME} [artifact] [manifest] [env]" 1>&2
}

##
## Verify that the script has the correct input and environment settings
## required to complete the process.
##
function validate_env() {
    : "${CF_USERNAME:?"The environment variable 'CF_USERNAME' must be set and non-empty"}"
    : "${CF_PASSWORD:?"The environment variable 'CF_PASSWORD' must be set and non-empty"}"
    : "${CF_ORG:?"The environment variable 'CF_ORG' must be set and non-empty"}"
    : "${CF_SPACE:?"The environment variable 'CF_SPACE' must be set and non-empty"}"
    : "${CF_APPNAME:?"The environment variable 'CF_APPNAME' must be set and non-empty"}"
    : "${CF_DOMAINS:?"The environment variable 'CF_DOMAINS' must be set and non-empty"}"

    command -v cf >/dev/null 2>&1 || error_exit "$LINENO: the cf-cli is not available on this machine" 1
    cf -v || error_exit "$LINENO: the cf-cli is not working on this machine" 1
}

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
## Invokes the final clean up activities for the script.  This is especially
## important if running on a CI "agent" so that any other jobs can't take
## advantage of an already authenticated CLI.
##
## This method is registered with the trap command prior to invoking the
## "main" and will be called automatically on those exit conditions.
##
function clean_up() {
    cf logout
}

##
## Logs in to the target CloudFoundry API endpoint as the user provided by the
## environment.
##
## INPUT(S):
##  $1: cf_api
##
function cf_login() {
    # TODO remove skip-ssl-validation when all the certs are valid
    cf api "$1" --skip-ssl-validation
    cf login -u "${CF_USERNAME}" -p "${CF_PASSWORD}" -o "${CF_ORG}" -s "${CF_SPACE}" || error_exit "$LINENO: Unable to log into $1" $?
}

##
## Determine the current active "color" of the application being deployed.  It
## is possible that this is the very first deployment of the application and
## it will not be able to determine it.
##
## INPUT(S):
##  $1: app_name_env - the app name plus the target environment (ex. myapp-dev)
##  $2: domain - the domain of the route to check
##
function determine_active_color() {
    local determined_color
    determined_color=$(cf routes | awk -v route="^${1}\$" -v domain="^${2}\$" '$2 ~ route && $3 ~ domain && $4 ~ /green$/ { print "green" } $2 ~ route && $3 ~ domain && $4 ~ /blue$/ { print "blue" }')
    echo "${determined_color}"
}

##
## Determine the alternate "color" of the application being deployed.  This is
## simply just by providing the opposite of the current color.
##
## INPUT(S):
##  $1: input_color - the color to find the opposite of
##
## OUTPUT:
##  output_color - the alternate color of the input_color
##
function determine_alt_color() {
    if [ "${1}" == "blue" ]; then
        echo "green"
    else
        echo "blue"
    fi
}

##
## Determine the current number of instances that are running before the
## cut over so that the new application can be scaled up to be able to handle
## the current load.
##
## INPUT(S):
##  $1: app_name - the current application name
##
## OUTPUT:
##  instance_count - the current number of application instances
##
function determine_active_scale() {
    local instance_count
    instance_count=$(cf scale "${1}" | grep instances | cut -d' ' -f2)
    if ! [[ "$instance_count" =~ ^[0-9]+$ ]] ; then
        echo "1"
    else
        echo "${instance_count}"
    fi
}

##
## Check for for an existing app route (or create one if it does not exist).
##
## INPUT(S):
##  $1: host - the host name of the route to check
##  $2: domain - the domain of the route to check
##
function check_primary_route() {
    local cf_route_exists
    cf_route_exists=$(cf check-route "$1" "$2" || error_exit "$LINENO: Unable to verify route with host ${1} on ${2}" $?)

    if [[ "${cf_route_exists}" == *"not exist"* ]]; then
        echo "Creating route: create-route ${CF_SPACE} $2 -n $1"
        cf create-route "${CF_SPACE}" "$2" -n "$1" || error_exit "$LINENO: Unable to create primary route" $?
    fi
}

##
## Pushes target application artifact to CloudFoundry.
##
## INPUT(S):
##  $1: app_name - the application name to use
##  $2: cf_domain - the target CloudFoundry domain
##  $3: path - the path to app directory or to a zip file of the contents of the app directory
##  $4: manifest_path - the path to the manifest
##
function push_app() {
    echo "##teamcity[progressStart 'cf-push $1 to $2']"
    cf push "$1" -p "$3" -f "$4" || { local exit_code=$?; cf logs "$1" --recent; error_exit "$LINENO: Unable to start $1 on $2" ${exit_code}; }
    echo "##teamcity[progressFinish 'cf-push $1 to $2']"
}

##
## Scales the application to a specified number of instances.
##
## INPUT(S):
##  $1: app_name - the application name to use
##  $2: instance_count - the number of instances to scale to
##
function scale_app() {
    echo "##teamcity[progressStart 'cf-scale $1 to $2']"
    cf scale "${1}" -i "${2}" || { local exit_code=$?; cf logs "$1" --recent; error_exit "$LINENO: Unable to scale $1 to $2" ${exit_code}; }
    echo "##teamcity[progressFinish 'cf-scale $1 to $2']"
}

##
## Perform associate "smoke" testing.  If these tests fail, the script should
## stop and exit with an error code.
##
## INPUT(S):
##  $1: app_name - the application name to use
##  $2: cf_domain - the target CloudFoundry domain
##
function smoke_test() {
    echo "##teamcity[progressStart 'smoke-test $1 on $2']"
    "${DIR_NAME}"/cf-smoke.sh "${1}" "${2}"
    echo "##teamcity[progressFinish 'smoke-test $1 on $2']"
}

##
## The "main" method for the cf-deploy.sh script.  This script acts as a
## simple reference for a basic blue-green deployments.  The script first
## loops over all target CloudFoundry domains and pushes the application as a
## new "alternate" color.
##
## Once the application is successfully started and smoke tested on all
## domains, the script maps the primary application route to the new color
## route and then un-maps and stops the old application.
##
## INPUT(S):
##  $1: artifact
##  $2: manifest
##  $3: target_env
##
function main() {
    local artifact="${1:?"Usage: ${SCRIPT_NAME} [artifact] [manifest] [env]"}"
    local manifest="${2:?"Usage: ${SCRIPT_NAME} [artifact] [manifest] [env]"}"
    local target_env="${3:?"Usage: ${SCRIPT_NAME} [artifact] [manifest] [env]"}"

    validate_env

    local active_color
    local app_name_alt
    local app_name_env="${CF_APPNAME}"
    # Strip 'prod' from app name if present
    local vanity_app_name="${CF_APPNAME%prod}"

    echo "##teamcity[progressStart 'cf-deploy-sh']"

    # split comma separated CF_DOMAINS into an array
    IFS=',' read -r -a cf_domain_array <<< "${CF_DOMAINS}"

    for cf_domain in "${cf_domain_array[@]}"
    do
        local route_domain="kroger.com"

        if [ "${cf_domain}" == "ocf.kroger.com" ]; then
            route_domain="ocf.kroger.com"
        fi

        cf_login "https://api.${cf_domain}"

        active_color=$(determine_active_color "${vanity_app_name}" "${route_domain}")
        app_name_alt="${app_name_env}-$(determine_alt_color "${active_color}")"

        echo "Next application is: ${app_name_alt}"

        check_primary_route "${app_name_env}" "${cf_domain}"
        check_primary_route "${vanity_app_name}" "${route_domain}"

        cf delete "${app_name_alt}" -r -f
        push_app "${app_name_alt}" "${cf_domain}" "${artifact}" "${manifest}"

        if [ "${active_color}" != "" ]; then
            local app_name_current="${app_name_env}-${active_color}"
            scale_app "${app_name_alt}" "$(determine_active_scale "${app_name_current}")"
        fi

        smoke_test "${app_name_alt}" "${cf_domain}"
    done

    for cf_domain in "${cf_domain_array[@]}"
    do
        cf_login "https://api.${cf_domain}"

        active_color=$(determine_active_color "${vanity_app_name}" "${route_domain}")
        app_name_alt="${app_name_env}-$(determine_alt_color "${active_color}")"

        echo "Deploy succeeded, mapping primary route to '${app_name_alt}'"
        cf map-route "${app_name_alt}" "${cf_domain}" -n "${app_name_env}" || error_exit "$LINENO: Unable to map primary route" $?
        cf map-route "${app_name_alt}" "${route_domain}" -n "${vanity_app_name}" || error_exit "$LINENO: Unable to map vanity route" $?

        if [ "${active_color}" == "" ]; then
          echo "This is an initial deploy, so there is no previous route to unmap."
        else
          local app_name_current="${app_name_env}-${active_color}"
          echo "Un-mapping and stopping the previous route at '${app_name_current}'"
          cf unmap-route "${app_name_current}" "${cf_domain}" -n "${app_name_env}" || error_exit "$LINENO: Unable to unmap old primary route" $?
          cf unmap-route "${app_name_current}" "${route_domain}" -n "${vanity_app_name}" || error_exit "$LINENO: Unable to unmap old vanity route" $?
          cf stop "${app_name_current}" || error_exit "$LINENO: Unable to stop old app ${app_name_current}" $?
        fi
    done

    echo "##teamcity[progressFinish 'cf-deploy-sh']"
}

##
trap clean_up INT TERM EXIT
main "$@"
