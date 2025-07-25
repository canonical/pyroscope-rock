#! /usr/bin/env bash

# This script is a copy of https://github.com/goss-org/goss/blob/master/extras/kgoss/kgoss
# with a hardcoded original timeout changed to 300s as pyroscope takes longer than 60s to start

set -eo pipefail

info() {
    echo -e "[INFO]: $*" >&2
}

error() {
    echo -e "[ERROR]: $*" >&2
    exit 1
}

usage() {
>&2 cat <<-'EOF'
Usage: $(basename $0) [command] [options]

## Commands:

* `run` executes goss in the pod/container with ./goss.yaml as input (by
default).
* `edit` opens a prompt inside the container to run `goss add ...`
and copies out files when complete.

## Options:

-i="image_url:tag" - full URL of container image
-d="additional directories to copy to container" - may be specified zero to
    many times
-e="envvar_key=value" - may be specified zero to many times
-p - (flag) pause container on entry
-c="cmd to run" - command to execute as container entry point
-a="args to entrypoint"

If -p, -c and -a are not specified, container will run its ENTRYPOINT.

-e and -d can be specified multiple times.

## Environment variables and default values:

GOSS_KUBECTL_BIN="$(which kubectl)": location of kubectl-compatible binary
GOSS_KUBECTL_OPTS="": hook to inject more options such as "--namespace=default"
GOSS_PATH="$(which goss)": location of goss binary
GOSS_FILES_PATH=".": location of goss.yaml and other configuration files
GOSS_VARS="": path to a goss.vars file
GOSS_OPTS="--color --format documentation": options passed to goss
GOSS_WAIT_OPTS="-r 30s -s 1s > /dev/null": options passed to goss
GOSS_CONTAINER_PATH="/tmp/goss": path to copy files in container, and working dir for tests
EOF

exit 2
}

# GOSS_PATH
if [[ -z "${GOSS_PATH}" ]]; then
    if [[ $(which goss 2> /dev/null) ]]; then
        GOSS_PATH=$(which goss 2> /dev/null)
    elif [[ -e "${HOME}/goss" ]]; then
        GOSS_PATH="${HOME}/goss"
    elif [[ -e "${HOME}/bin/goss" ]]; then
        GOSS_PATH="${HOME}/bin/goss"
    else
        error "Couldn't find goss, please set GOSS_PATH to it"
    fi
fi

# GOSS_KUBECTL_BIN
GOSS_KUBECTL_BIN=${GOSS_KUBECTL_BIN:-$(which kubectl 2> /dev/null || true)}
if [[ -z "$GOSS_KUBECTL_BIN" ]]; then error "kgoss requires kubectl in your PATH"; fi
k=${GOSS_KUBECTL_BIN}

GOSS_FILES_PATH="${GOSS_FILES_PATH:-.}"
GOSS_OPTS=${GOSS_OPTS:-"--color --format documentation"}
GOSS_WAIT_OPTS=${GOSS_WAIT_OPTS:-"-r 30s -s 1s > /dev/null"}
GOSS_CONTAINER_PATH=${GOSS_CONTAINER_PATH:-/tmp/goss}
GOSS_KUBECTL_OPTS=${GOSS_KUBECTL_OPTS:-""}

kgoss_cmd=run
image=
pause=0
cmd=''
args=''
to_exec=''
envs=''
include_goss_files_dir=0
dirs_array=()

cleanup() {
    set +ex
    rm -rf "$tmp_dir"
    if [[ -n "$id" ]]; then
        info "Deleting pod/container"
        ${k} delete pod "$id" ${GOSS_KUBECTL_OPTS} > /dev/null
    fi
}

# parse checks for a bare `-d` flag and if set includes GOSS_FILES_PATH in dirs
# to upload to pod
parse() {
  # handle deprecated bare `-d`
  i=0
  original_args=("$@")
  new_args=()
  re='^-'
  for arg in "${original_args[@]}"; do
    if [[ "${arg}" == '-d' ]]; then
      # check if next word starts with '-'
      if [[ "${original_args[$(($i+1))]}" =~ $re ]]; then
        # since it does, mark to copy whole dir and remove this arg
        include_goss_files_dir=1
        i=$(($i+1))
        continue
      fi
    fi
    i=$(($i+1))
    new_args+=("${arg}")
  done
  # end handle `-d`

  # now call original parse_internal func
  parse_internal "${new_args[@]}"
}

parse_internal() {
  info "Parsing command line"
  kgoss_cmd=$1; shift
  if [[ ( ! "${kgoss_cmd}" == "run" ) && ( ! "${kgoss_cmd}" == 'edit' ) ]]; then usage; fi
  envs_array=()
  while getopts 'i:pc::a::d::e::' arg; do
    case $arg in
      i)
        image="${OPTARG}"
        info "using image: $image"
        ;;
      p)
        pause=1
        ;;
      c)
        cmd="${OPTARG}"
        ;;
      a)
        args="${OPTARG}"
        ;;
      d)
        dirs_array+=("${OPTARG}")
        ;;
      e)
        envs_array+=("${OPTARG}")
        ;;
      *)
        info "invalid option specified"
        usage
        ;;
    esac
  done

  for envvar in "${envs_array[@]}"; do
    envs+=" --env=${envvar}"
  done

  # if -p (pause) is set, then -c (command) and -a (args) should be empty and
  # we inject a pause
  if [[ $pause == 1 ]]; then
    if [[ ! ( -z "$cmd" && -z "$args" ) ]]; then
      error "cannot specify -p and -c or -a"
    fi
    to_exec="--command -- sleep 1h"
  else
    # if not -p (pause), then either:
    #   * one of -c (command) or -a (args) should be set
    #   * neither should be set and we default to entrypoint
    if [[ -n "$cmd" && -n "$args" ]]; then
      error "cannot specify both -c and -a"
    fi
    if [[ -n "$cmd" ]]; then
      to_exec="--command -- $cmd"
    fi
    if [[ -n $"args" ]]; then
      to_exec="-- $args"
    fi
  fi
  info "going to execute (may be blank): ${to_exec}"
}

# initialize starts the pod to be tested and copies goss files into it
initialize () {
    info "Preparing files to copy into container"
    cp "${GOSS_PATH}" "$tmp_dir/goss" && chmod 0775 "$tmp_dir/goss"
    [[ -e "${GOSS_FILES_PATH}/goss.yaml" ]] && cp "${GOSS_FILES_PATH}/goss.yaml" "$tmp_dir"
    [[ -e "${GOSS_FILES_PATH}/goss_wait.yaml" ]] && cp "${GOSS_FILES_PATH}/goss_wait.yaml" "$tmp_dir"
    [[ ! -z "${GOSS_VARS}" ]] && [[ -e "${GOSS_FILES_PATH}/${GOSS_VARS}" ]] && cp "${GOSS_FILES_PATH}/${GOSS_VARS}" "$tmp_dir"
    if [[ ${include_goss_files_dir} == 1 ]]; then cp -r ${GOSS_FILES_PATH}/* "${tmp_dir}"; fi
    for dir in "${dirs_array[@]}"; do
      cp -r ${dir} "${tmp_dir}/"
    done

    GOSS_FILES_STRATEGY=${GOSS_FILES_STRATEGY:="cp"}
    case "$GOSS_FILES_STRATEGY" in
      cp)
        info "Creating Kubernetes pod/container to test"
        test_pod_name=kgoss-tester-${RANDOM}
        set -x
        id=$(${k} run ${GOSS_KUBECTL_OPTS}  $test_pod_name --image-pull-policy=Always --restart=Never \
          --labels='app=kgoss-test' --output=jsonpath={.metadata.name} ${envs} \
          --image=${image} ${to_exec} )
        set +x
        info "Waiting for container to be ready"
        ${k} wait pod/${test_pod_name} --for=condition=Ready --timeout=900s  ${GOSS_KUBECTL_OPTS}
        info "Copying goss files into pod/container"
        ${k} cp ${GOSS_KUBECTL_OPTS} $tmp_dir/. ${id}:${GOSS_CONTAINER_PATH}/
        info "Marking copied files as executable"
         ${k} exec ${GOSS_KUBECTL_OPTS} "$id" -- sh -c "chmod -R a+x ${GOSS_CONTAINER_PATH}/"
        ;;
      *) error "Wrong kgoss files strategy used! Only \"cp\" is supported."
    esac

    info "Using pod/container: ${id}"
}

# get_pod_file copies the specified file from the pod to a local path
get_pod_file() {
    if  ${k} exec ${GOSS_KUBECTL_OPTS} "$id" -- sh -c "test -e ${GOSS_CONTAINER_PATH}/$1" &> /dev/null; then
        mkdir -p "${GOSS_FILES_PATH}"
        info "Copied '$1' from pod/container to '${GOSS_FILES_PATH}'"
        ${k} cp ${GOSS_KUBECTL_OPTS} "${id}:${GOSS_CONTAINER_PATH}/$1" "${GOSS_FILES_PATH}/$1"
    fi
}

main() {
    kernel="$(uname -s)"
    case "${kernel}" in
        MINGW*) prefix="winpty" ;;
        *)      prefix="" ;;
    esac

    tmp_dir=$(mktemp -d /tmp/tmp.XXXXXXXXXX)
    chmod 777 "$tmp_dir"
    trap 'ret=$?; cleanup; exit $ret' EXIT

    parse "$@"
    initialize

    # execute
    case $kgoss_cmd in
        run)
            # wait for goss_wait.yaml if present
            if [[ -e "${GOSS_FILES_PATH}/goss_wait.yaml" ]]; then
                info "Found goss_wait.yaml, waiting for it to pass before running tests"
                if [[ -z "${GOSS_VARS}" ]]; then
                    if !  ${k} exec ${GOSS_KUBECTL_OPTS} "$id" -- sh -c "${GOSS_CONTAINER_PATH}/goss -g ${GOSS_CONTAINER_PATH}/goss_wait.yaml validate $GOSS_WAIT_OPTS" ; then
                        error "goss_wait.yaml never passed"
                    fi
                else
                    if !  ${k} exec ${GOSS_KUBECTL_OPTS} "$id" -- sh -c "${GOSS_CONTAINER_PATH}/goss -g ${GOSS_CONTAINER_PATH}/goss_wait.yaml --vars='${GOSS_CONTAINER_PATH}/${GOSS_VARS}' validate $GOSS_WAIT_OPTS" ; then
                        error "goss_wait.yaml never passed"
                    fi
                fi
            fi

            # running tests in pod/container
            info "Running tests within pod/container"
            if [[ -z "${GOSS_VARS}" ]]; then
                 ${k} exec ${GOSS_KUBECTL_OPTS} "$id" -- sh -c "cd ${GOSS_CONTAINER_PATH}; ${GOSS_CONTAINER_PATH}/goss -g ${GOSS_CONTAINER_PATH}/goss.yaml validate $GOSS_OPTS"
            else
                 ${k} exec ${GOSS_KUBECTL_OPTS} "$id" -- sh -c "cd ${GOSS_CONTAINER_PATH}; ${GOSS_CONTAINER_PATH}/goss -g ${GOSS_CONTAINER_PATH}/goss.yaml --vars='${GOSS_CONTAINER_PATH}/${GOSS_VARS}' validate $GOSS_OPTS"
            fi
            ;;
        edit)
            info "When prompt appears you can run \`goss add\` to add resources"
            ${prefix}  ${k} exec ${GOSS_KUBECTL_OPTS} -it "$id" -- sh -c "cd ${GOSS_CONTAINER_PATH}; PATH=\"${GOSS_CONTAINER_PATH}:$PATH\" exec sh" || true
            echo "Copying goss.yaml and goss_wait.yaml files back to local dir"
            get_pod_file "goss.yaml"
            get_pod_file "goss_wait.yaml"
            [[ ! -z "${GOSS_VARS}" ]] && get_pod_file "${GOSS_VARS}"
            ;;
        *)
            echo "invalid kgoss command, valid commands are 'run' and 'edit'"
            usage
            ;;
    esac
}

main "$@"