#!/bin/bash
bold=$(tput bold)
underline=$(tput sgr 0 1)
reset=$(tput sgr0)

purple=$(tput setaf 171)
red=$(tput setaf 1)
green=$(tput setaf 76)
tan=$(tput setaf 3)
blue=$(tput setaf 38)

verbose=0
NAME=`basename ${BASH_SOURCE[0]}`
e_header() {
    echo; echo -n "${bold}${purple}==========" ; echo -n $@; echo "==========${reset}"
}
e_arrow() { echo "➜ $@"
}
e_success() { echo -n "${green}✔ "; echo -n "$@" ; echo "${reset}"
}
e_error() { echo -n "${red}✖ "; echo -n "$@"; echo "${reset}"
}
e_warning() { echo -n "${tan}➜ "; echo -n "$@"; echo "${reset}"
}
e_underline() { echo "${underline}${bold} $@ ${reset}"
}
e_bold() { echo "${bold} $@ ${reset}"
}
e_note() { echo -n "${underline}${bold}${blue}Note:${reset}  ${blue}"
    echo -n $@
    echo "${reset}"
}


#saveLog() {
#LOGFILE_DIR=$1
#  if [[ "${LOGFILE_DIR}" ]]; then
#    readonly LOG_FILE="${LOGFILE_DIR}/$(basename -- q"$0").log"
#    tee -a "${LOG_FILE}" >&2
#  else
#    cat
#  fi
#}
readonly DATE_FORMAT="%Y-%m-%d"
info()    { [ $verbose -ge 2 ] && e_note "[`date +$DATE_FORMAT`] [INFO]    $*" | cat ; }
warning() { [ $verbose -ge 1 ] && e_warning "[`date +$DATE_FORMAT`] [WARNING] $*" | cat ; }
debug()   { [ $verbose -ge 3 ] && e_warning "[`date +$DATE_FORMAT`] [DEBUG]   $*" | cat  ; }
error()   { dt=$(date +"${DATE_FORMAT}"); e_error "[${dt}] [ERROR]   $*" | cat ; }
fatal()   { dt=$(date +"${DATE_FORMAT}"); e_error "[${dt}] [FATAL]   $*" | cat ; exit 1 ; }

UNDEFINED="UNDEFINED"
HPC_DOMAIN="hpc.aganitha.ai"
PORTS_ADDED=()
## Purpose: Wrapper for docker to inject dependencies by interpreting bare minimum parameters passed
## through configuration file and additional parameters through command line.
HELPSTR=$(cat << END_HELP
Usage example: ${NAME}  -v[FOR VERBOSE MODE] -f CONFIG_FILE -a <ANY ADDITIONAL DOCKER ARGUMENTS(OPTIONAL)>
-c <COMMAND TO RUN AFTER DOCKER STARTS(OPTIONAL)>
END_HELP
)


# Sourcing the Aganitha standard variables. If not found, creating one with specified configuration.
source_aganitha_vars()
{
if [[ ! -f ${STANDARD_CONFIG_ROOT} ]]; then
error "File ${STANDARD_CONFIG_ROOT} not found"
error "Standard aganitha variables will remain undefined."
else
source ${STANDARD_CONFIG_ROOT}
info "sourcing $STANDARD_CONFIG_ROOT"
fi
}

## Given port number, adds corresponding traefik label
add_traefik_port()
{
TRAEFIK_ROUTER_NAME=$1
PORT=$2
info "Port being used in $PORT"
if [[ "${PORT}" == "AUTO" ]];then
    gen_random_port
fi
if [[ -z "$HPC"  || "$HPC" = false ]]; then
PORT_LABEL=$(cat <<- ADDPORTLABELS
--label traefik.http.services.$TRAEFIK_ROUTER_NAME.loadbalancer.server.port=${PORT} \
--label traefik.http.routers.$TRAEFIK_ROUTER_NAME-secured.service=$TRAEFIK_ROUTER_NAME
ADDPORTLABELS
)
else
PORT_LABEL="traefik.http.services.$TRAEFIK_ROUTER_NAME.loadbalancer.server.port=${PORT},\
traefik.http.routers.$TRAEFIK_ROUTER_NAME-secured.service=$TRAEFIK_ROUTER_NAME"
fi
}

gen_random_port()
{
if [[ "${START_CONTAINER_FROM_DOCKER} = true" ]];then
       ip_address=${HOST_IP_ADDRESS}
       PORTS_ON_HOST=`ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@"${ip_address}" \
       netstat -lnt |awk '{if(NR>2)print}'|  awk '{print $4}'| awk -F ":" '{print $NF}' | sort -n | uniq `
else
       PORTS_ON_HOST=`netstat -lnt |awk '{if(NR>2)print}'|  awk '{print $4}'| awk -F ":" '{print $NF}' | sort -n | uniq `
fi
#PORTS_ON_HOST=($(netstat -lnt |awk '{if(NR>2)print}'|  awk '{print $4}'| awk -F ":" '{print $NF}' | sort -n | uniq ))
PORTS_ON_HOST=(${PORTS_ON_HOST[@]} ${PORTS_ADDED[@]})
LAST_PORT=${PORTS_ON_HOST[-1]}
if [[  "${PORT}" -lt 65535 ]]; then
    PORT=$((${LAST_PORT}+1))
else
   PORT=65535
   if [[ "${START_CONTAINER_FROM_DOCKER} = true" ]];then
       if [[ -z "${HOST_IP_ADDRESS}" ]]; then
           error "Host IP address is not available. Please pass the variable HOST_IP_ADDRESS"
       fi
       ip_address=${HOST_IP_ADDRESS}
       CONDITION=`ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@"${ip_address}" \
       netstat -lnt |awk '{if(NR>2)print}'|  awk '{print $4}'| awk -F ":" '{print $NF}' | sort -n | uniq | grep $PORT`
   else
       CONDITION=`netstat -lnt |awk '{if(NR>2)print}'|  awk '{print $4}'| awk -F ":" '{print $NF}' | sort -n | uniq | grep $PORT`
   fi
   while ${CONDITION}; do
       PORT=$((${PORT}-1))
   done
fi
PORTS_ADDED=(${PORTS_ADDED[@]} ${PORT})
}

## Injecting minimum traefik labels required to start a container
traefik_labels()
{
TRAEFIK_ROUTER_NAME=$1
TRAEFIK_HOST_NAME=$2
TRAEFIK_RULE=""
if [[ "${HPC}" = true ]]; then
    ACOG_DOMAINS=(${HPC_DOMAIN})
elif [[ -z "${ACOG_DOMAINS}" ]]; then
    ACOG_DOMAINS=(${ACOG_COM_DOMAIN} ${ACOG_AI_DOMAIN})
fi
NUMBER_OF_ACOG_DOMAINS=${#ACOG_DOMAINS[@]}
for (( a=1; a<${NUMBER_OF_ACOG_DOMAINS}+1; a++ ));
do
    TRAEFIK_RULE="${TRAEFIK_RULE}Host(\`${TRAEFIK_HOST_NAME}.${ACOG_DOMAINS[$a-1]}\`)"
    if [[ $a -ne ${NUMBER_OF_ACOG_DOMAINS} ]];
    then
       TRAEFIK_RULE="${TRAEFIK_RULE}||"
    fi
done
info "Traefik router name is $TRAEFIK_ROUTER_NAME"
if [[ -z "$HPC" || "$HPC" = false ]]; then
TRAEFIK_LABELS=$(cat << _ADDTRAEFIKLABELS_
--label traefik.enable=true \
--label traefik.http.routers.${TRAEFIK_ROUTER_NAME}.rule=${TRAEFIK_RULE} \
--label traefik.http.routers.${TRAEFIK_ROUTER_NAME}.entrypoints=web \
--label traefik.http.middlewares.https-only.redirectscheme.scheme=https \
--label traefik.http.routers.${TRAEFIK_ROUTER_NAME}.middlewares=https-only \
--label traefik.http.routers.${TRAEFIK_ROUTER_NAME}-secured.rule=${TRAEFIK_RULE} \
--label traefik.http.routers.${TRAEFIK_ROUTER_NAME}-secured.entrypoints=websecure \
--label traefik.http.routers.${TRAEFIK_ROUTER_NAME}-secured.tls=true
_ADDTRAEFIKLABELS_
)
else
TRAEFIK_LABELS="traefik.enable=true,traefik.http.routers.${TRAEFIK_ROUTER_NAME}.rule=${TRAEFIK_RULE},\
traefik.http.routers.${TRAEFIK_ROUTER_NAME}.entrypoints=web,\
traefik.http.middlewares.https-only.redirectscheme.scheme=https,\
traefik.http.routers.${TRAEFIK_ROUTER_NAME}.middlewares=https-only,\
traefik.http.routers.${TRAEFIK_ROUTER_NAME}-secured.rule=${TRAEFIK_RULE},\
traefik.http.routers.${TRAEFIK_ROUTER_NAME}-secured.entrypoints=websecure,\
traefik.http.routers.${TRAEFIK_ROUTER_NAME}-secured.tls=true"
fi

}

## Injecting username and description as labels to the container
interpret_description()
{
DESC_ARG=$(cat << ADDDESCLABELS
--label description=${DESCRIPTION// /_} \
--label user=${USER}
ADDDESCLABELS
)
}

## Interpreting the mount points
interpret_mount_points()
{
num_mount_points=${#MOUNT_POINTS[@]}
if [[ ${num_mount_points} -ge 1 ]]; then
    for (( m=1; m<${num_mount_points}+1; m++ ));
    do
        MOUNT_POINTS_ARG="${MOUNT_POINTS_ARG} -v ${MOUNT_POINTS[$m-1]}"
    done
    info "Mount points which are specified $MOUNT_POINTS_ARG"
else
info "No mount points are mentioned"
fi
}

## Interpreting the environment variables
interpret_env_variables()
{
num_env_variables=${#ENV_VARIABLES[@]}
if [[ ${num_env_variables} -ge 1 ]]; then
    for (( e=1; e<${num_env_variables}+1; e++ ));
    do
        ENV_VARIABLES_ARG="${ENV_VARIABLES_ARG} -e ${ENV_VARIABLES[$e-1]}"
    done
    info "Environment variables which are specified $ENV_VARIABLES_ARG"
else
info "No environment variables are mentioned"
fi
}


## Interpreting port mappings
interpret_port_mappings()
{
num_port_mappings=${#PORT_MAPPINGS[@]}
num_host_ports=${#HOST_PORTS[@]}
num_container_ports=${#CONTAINER_PORTS[@]}
if [[ ! -z ${PORT_MAPPINGS} && ${num_port_mappings} -ge 1 ]]; then
    for (( k=1; k<${num_port_mappings}+1; k++ ));
    do
        HOST_PORT=`echo ${PORT_MAPPINGS[$k-1]} | cut -d ':' -f 1`
        CONTAINER_PORT=`echo ${PORT_MAPPINGS[$k-1]} | cut -d ':' -f 2`
        if [[ "$HOST_PORT" == "AUTO" ]];then
           gen_random_port
           PORT_MAPPINGS[$k-1]="$PORT:$CONTAINER_PORT"
        fi
        PORT_MAPPINGS_ARG="${PORT_MAPPINGS_ARG} -p ${PORT_MAPPINGS[$k-1]}"
    done
    info "Port mappings which are specified $PORT_MAPPINGS_ARG"
elif [[ ! -z ${HOST_PORTS} && ${num_host_ports} -ge 1 ]]; then
   if [[ num_host_ports -ne num_container_ports ]]; then
       error "Number of host ports are not equal to number of container ports. Skipping adding port mappings"
   else
       for (( hp=1; hp<${num_host_ports}+1; hp++ ));
           do
               info "HOST PORT is  ${HOST_PORTS[hp-1]}"

               if [[ "${HOST_PORTS[hp-1]}" == "AUTO" ]];then
                  if [[ -z "${PORTS_ADDED[hp-1]}" ]];then
                      gen_random_port
                  else
                      PORT="${PORTS_ADDED[hp-1]}"
                  fi
                  info "PORT is $PORT"
                  HOST_PORTS[hp-1]=${PORT}
               fi
               PORT_MAPPINGS_ARG="${PORT_MAPPINGS_ARG} -p ${HOST_PORTS[hp-1]}:${CONTAINER_PORTS[hp-1]}"
           done
       info "Port mappings which are specified $PORT_MAPPINGS_ARG"
   fi
else
    info "No port mappings are mentioned"
fi
}

# Injecting the specified labels
interpret_labels()
{
num_labels=${#LABELS[@]}
if [[ ${num_labels} -ge 1 ]]; then
    for (( l=1; l<${num_labels}+1; l++ ));
    do
        if [[ -z "$HPC" || "$HPC" = false ]]; then
           LABELS_ARG="${LABELS_ARG} --label ${LABELS[$l-1]}"
        else
           if [[ "${LABELS[$l-1]}" == *"traefik"* ]]; then
               TRAEFIK="$TRAEFIK,${LABELS[$l-1]}"
           else
               echo "Into else loop"
               LABELS_ARG="${LABELS_ARG} --label ${LABELS[$l-1]}"
           fi
        fi
    done
    info "Labels which are specified $LABELS_ARG"
else
info "No additional labels are mentioned"
fi
}

# Injecting the router names
interpret_router_name()
{
counter=$1
counter=$((counter-1))
if [[ "${ROUTER_NAMES[$counter]}" ]]; then
    ROUTER_NAME=${ROUTER_NAMES[$counter]}
else
    if [[ $counter == 0  ]]; then
    ROUTER_NAME=$CONTAINER_NAME
    else
    ROUTER_NAME=$CONTAINER_NAME-$counter
    fi
fi
if [[ "${TRAEFIK_SERVICE[$counter]}" ]]; then
    HOST_NAME=${TRAEFIK_SERVICE[$counter]}
else
    if [[ $counter == 0 ]]; then
     HOST_NAME=$CONTAINER_NAME
    else
     HOST_NAME=$CONTAINER_NAME-$counter
    fi
fi
}

add_service_tags()
{
        TRAEFIK_VARS=(${TRAEFIK_LABELS} ${PORT_LABEL} ${AUTH_USERS_LABEL} ${AUTH_USERSFILE_LABEL})
        TRAEFIK_VARS_LEN=${#TRAEFIK_VARS[@]}
        for (( tv=1; tv<${TRAEFIK_VARS_LEN}+1; tv++ ));
        do
                if [[ ! -z ${TRAEFIK_VARS[tv-1]} ]]; then
                    if [[ ! -z ${TRAEFIK} ]]; then
                        TRAEFIK="${TRAEFIK},${TRAEFIK_VARS[tv-1]}"
                    else
                        TRAEFIK="${TRAEFIK_VARS[tv-1]}"
                    fi
                fi
        done
}

interpret_traefik_labels()
{
if [[ -z ${PORTS} ]];then
   if [[ ! -z "${HPC}" ]]; then
   arraylength=${#HOST_PORTS[@]}
   PORTS=(${HOST_PORTS[@]})
   else
      arraylength=${#CONTAINER_PORTS[@]}
      PORTS=(${CONTAINER_PORTS[@]})
   fi
else
   arraylength=${#PORTS[@]}
fi
info "PORTS are ${PORTS[@]}"
if [[ ${ENABLE_TRAEFIK} == true ]]; then
    if [[ ${arraylength} -gt 1 ]]; then
        for (( j=1; j<${arraylength}+1; j++ ));
        do
            interpret_router_name $j
            traefik_labels $ROUTER_NAME $HOST_NAME
            add_traefik_port $ROUTER_NAME ${PORTS[$j-1]}
            interpret_traefik_auth $ROUTER_NAME $j
            if [[ -z "${HPC}" || "${HPC}" = false ]]; then
                TRAEFIK="$TRAEFIK $TRAEFIK_LABELS $PORT_LABEL $AUTH_USERS_LABEL $AUTH_USERSFILE_LABEL"
            else
                add_service_tags
            fi
        done
    elif [[ ${arraylength} == 1 ]]; then
        interpret_router_name 1
        traefik_labels $ROUTER_NAME $HOST_NAME
        add_traefik_port $ROUTER_NAME ${PORTS[0]}
        interpret_traefik_auth $ROUTER_NAME 1
        if [[ -z "${HPC}" || "${HPC}" = false ]]; then
            TRAEFIK="$TRAEFIK $TRAEFIK_LABELS $PORT_LABEL $AUTH_USERS_LABEL $AUTH_USERSFILE_LABEL"
        else
            add_service_tags
        fi
    else
        interpret_router_name 1
        traefik_labels $ROUTER_NAME $HOST_NAME
        interpret_traefik_auth $ROUTER_NAME 1
        if [[ -z "${HPC}" || "${HPC}" = false ]]; then
            TRAEFIK="$TRAEFIK $TRAEFIK_LABELS $AUTH_USERS_LABEL $AUTH_USERSFILE_LABEL"
        else
            add_service_tags
        fi
    fi
fi
info "Traefik labels which are added $TRAEFIK "
}

add_traefik_basicauth_users()
{
TRAEFIK_ROUTER_NAME=$1
USERS=$2
if [[ -z "$HPC" || "$HPC" = false ]]; then
AUTH_USERS_LABEL=$(cat <<- ADDAUTHUSERSLABELS
--label traefik.http.middlewares.$TRAEFIK_ROUTER_NAME-auth-users.basicauth.users=$USERS \
--label traefik.http.routers.$TRAEFIK_ROUTER_NAME-secured.middlewares=$TRAEFIK_ROUTER_NAME-auth-users
ADDAUTHUSERSLABELS
)
else
AUTH_USERS_LABEL="traefik.http.middlewares.$TRAEFIK_ROUTER_NAME-auth-users.basicauth.users=$USERS,\
traefik.http.routers.$TRAEFIK_ROUTER_NAME-secured.middlewares=$TRAEFIK_ROUTER_NAME-auth-users"
fi
}

add_traefik_ldap_auth()
{
TRAEFIK_ROUTER_NAME=$1
if [[ -z "$HPC" || "$HPC" = false ]]; then
AUTH_USERS_LABEL=$(cat <<- ADDLDAPAUTHLABELS
--label traefik.http.middlewares.$TRAEFIK_ROUTER_NAME-ldapauth.forwardauth.address=https://eas.$ACOG_AI_DOMAIN/verify?fallback_plugin=0&config_token_store_id=primary&config_token_id=ldap_token \
--label traefik.http.middlewares.$TRAEFIK_ROUTER_NAME-ldapauth.forwardauth.trustForwardHeader=true \
--label traefik.http.middlewares.$TRAEFIK_ROUTER_NAME-ldapauth.forwardauth.authResponseHeaders=X-Auth-User,X-Secret \
--label traefik.http.routers.$TRAEFIK_ROUTER_NAME-secured.middlewares=$TRAEFIK_ROUTER_NAME-ldapauth
ADDLDAPAUTHLABELS
)
else
AUTH_USERS_LABEL="traefik.http.middlewares.$TRAEFIK_ROUTER_NAME-ldapauth.forwardauth.address=https://eas.$ACOG_AI_DOMAIN/verify?fallback_plugin=0&config_token_store_id=primary&config_token_id=ldap_token \
traefik.http.middlewares.$TRAEFIK_ROUTER_NAME-ldapauth.forwardauth.trustForwardHeader=true \
traefik.http.middlewares.$TRAEFIK_ROUTER_NAME-ldapauth.forwardauth.authResponseHeaders=X-Auth-User,X-Secret \
traefik.http.routers.$TRAEFIK_ROUTER_NAME-secured.middlewares=$TRAEFIK_ROUTER_NAME-ldapauth"
fi
}

add_traefik_basicauth_usersfile()
{
TRAEFIK_ROUTER_NAME=$1
USERSFILE=$2
if [[ -z "$HPC" || "$HPC" = false ]]; then
AUTH_USERSFILE_LABEL=$(cat <<- ADDAUTHUSERSFILELABELS
--label traefik.http.middlewares.$TRAEFIK_ROUTER_NAME-auth-usersfile.basicauth.usersfile=$USERSFILE \
--label traefik.http.routers.$TRAEFIK_ROUTER_NAME-secured.middlewares=$TRAEFIK_ROUTER_NAME-auth-usersfile
ADDAUTHUSERSFILELABELS
)
else
AUTH_USERSFILE_LABEL="traefik.http.middlewares.$TRAEFIK_ROUTER_NAME-auth-usersfile.basicauth.usersfile=$USERSFILE,\
traefik.http.routers.$TRAEFIK_ROUTER_NAME-secured.middlewares=$TRAEFIK_ROUTER_NAME-auth-usersfile"
fi
}



interpret_traefik_auth()
{
TRAEFIK_ROUTER_NAME=$1
COUNTER=$2
users_array_length=${#USERS[@]}
usersfile_array_length=${#USERSFILE[@]}
if [[ $BASICAUTH == true ]]; then
    if [[ ${users_array_length} -ge 1 ]]; then
        if [[ $users_array_length -gt $COUNTER ]]; then
            add_traefik_basicauth_users $TRAEFIK_ROUTER_NAME ${USERS[$users_array_length]}
        else
            add_traefik_basicauth_users $TRAEFIK_ROUTER_NAME ${USERS[$COUNTER-1]}
        fi
        info "Adding traefik basicauth using $USERS"
   fi
   if [[ ${usersfile_array_length} -ge 1 ]]; then
        if [[ $usersfile_array_length -gt $COUNTER ]]; then
            add_traefik_basicauth_users $TRAEFIK_ROUTER_NAME ${USERSFILE[$usersfile_array_length]}
        else
            add_traefik_basicauth_usersfile $TRAEFIK_ROUTER_NAME ${USERSFILE[$COUNTER-1]}
        fi
        info "Adding traefik basicauth using $USERSFILE"
   fi
fi

if [[ $LDAP_AUTH == true ]]; then
    info "LDAP authentication will be enabled for using this service"
    add_traefik_ldap_auth $TRAEFIK_ROUTER_NAME
fi
}


interpret_mode()
{
if [[ "${MODE}" == "detach"  ]]; then
MODE_ARG="-d"
elif [[ "${MODE}" == "interactive"  ]]; then
MODE_ARG="-it"
else
MODE_ARG="${MODE}"
fi
info "Mode in which container is being started is $MODE"
}


interpret_restart_policy()
{
RESTART_POLICY_ARG="--restart $RESTART_POLICY"
info "Restart policy for the container is ${RESTART_POLICY}"
}


interpret_autoremove()
{
if [[ ${AUTOREMOVE} = true ]];then
AUTOREMOVE_ARG="--rm"
info "Automatically removing the container when stopped."
else
AUTOREMOVE_ARG=""
fi
if [[ "$AUTOREMOVE_ARG" == "--rm"  ]]; then
if [[  ${RESTART_POLICY_ARG} == "--restart always" || ${RESTART_POLICY_ARG} == "--restart unless-stopped" || \
${RESTART_POLICY_ARG} == "--restart on-failure" ]]; then
error "Both --rm and --restart are present. Including only --restart option"
AUTOREMOVE_ARG=""
fi
fi
}


## Interprets the configuration file and adds appropriate options for starting container
interpret_config()
{
interpret_traefik_labels
interpret_traefik_auth
interpret_mode
interpret_restart_policy
interpret_autoremove
interpret_mount_points
interpret_env_variables
interpret_labels
interpret_description
interpret_port_mappings
}

check_variable_exists()
{
VARIABLE_NAME=$1
VARIABLE_VALUE=$2
if [[ "${VARIABLE_VALUE}" == "${UNDEFINED}" ]]; then
fatal "Please specify a valid $VARIABLE_NAME "
fi
}

stop_container () {
  CONTAINER_NAME=$1
  if ! [[  -z `docker ps -a -f name=${CONTAINER_NAME} -q` ]]; then
    docker rm -f ${CONTAINER_NAME}
    info "Removing the docker container $CONTAINER_NAME"
  fi
}


## Executes the docker run command with all the interpreted options from config file, additional
## options passed through command line.
run_docker() {
check_variable_exists IMAGE_NAME ${IMAGE_NAME}
check_variable_exists CONTAINER_NAME ${CONTAINER_NAME}
check_variable_exists DESCRIPTION ${DESCRIPTION}
source_aganitha_vars
stop_container ${CONTAINER_NAME}
info "Docker image on which container is being built is $IMAGE_NAME"
interpret_config
DOCKER_ARGUMENTS="--name $CONTAINER_NAME  $MODE_ARG $RESTART_POLICY_ARG $AUTOREMOVE_ARG $MOUNT_POINTS_ARG $LABELS_ARG \
$ENV_VARIABLES_ARG $DESC_ARG $ADDITIONAL_ARGUMENTS $PORT_MAPPINGS_ARG "
if [[ -z "$HPC" || "${HPC}" = false ]]; then
DOCKER_ARGUMENTS="${DOCKER_ARGUMENTS} $TRAEFIK "
else
info "Starting container on HPC environment"
# Removing leading spaces from the variable
TRAEFIK="$(echo -e "${TRAEFIK}" | sed -e 's/^[[:space:]]*//')"
DOCKER_ARGUMENTS="${DOCKER_ARGUMENTS} -e SERVICE_TAGS=$TRAEFIK "
MACHINE_ID=$(cat /etc/machine-id)
DOCKER_ARGUMENTS="${DOCKER_ARGUMENTS} -e SERVICE_NAME=${CONTAINER_NAME}-${MACHINE_ID}"
fi
info "docker run $DOCKER_ARGUMENTS $IMAGE_NAME $COMMAND"
docker run $DOCKER_ARGUMENTS $IMAGE_NAME $COMMAND
}


## Specifying options which should be used while invoking the command
## v - verbose - optional. Quiet mode is default.
## f - configuration file path - required
## a - additional docker options specified through command line - optional
## h - displays the usage of this file
## c - command to execute after container is started.
while getopts "vf:a:hc:" optname
do
    case "$optname" in
      "v")
        verbose=2
        ;;
      "f")
        FILENAME=$OPTARG
        info "Configuration file passed is $FILENAME"
        if [[ ! -f $FILENAME ]]; then
        fatal "File $FILENAME not found!"
        fi
        ;;
      "a")
        ADDITIONAL_ARGUMENTS=$OPTARG
        info "Additional arguments passed are $ADDITIONAL_ARGUMENTS"
      ;;
      "h")
      echo $HELPSTR
      exit 1
      ;;
      "c")
      COMMAND=$OPTARG
      info "Command to run after container starts ${COMMAND}"
      ;;
      "?")
        fatal "Invalid option: -$optname"
        ;;
    esac
done


if [[ -z "$1" ]]; then
    e_error "Argument not supplied"
    fatal ${HELPSTR}
else
    source ${FILENAME}
    run_docker
fi



