#!/bin/bash

set -e

gather_ip() {

    echo "[I] Determining OS Type and Attempting to Gather External IP Address"
    unameOut="$(uname -s)"
    case "${unameOut}" in
        Linux*)     machine=Linux;;
        Darwin*)    machine=Mac;;
        *)          machine="UNKNOWN:${unameOut}"
    esac
    echo "Host is detected as ${machine}"

    if [[ $machine == Linux ]]; then
        HOST_IP=$(ip route get 8.8.8.8 | awk -F"src " 'NR==1{split($2,a," ");print a[1]}')
    elif [[ $machine == Mac ]]; then
        HOST_IP=$(route get default | grep gateway | awk '{print $2}')
    else
        echo "Cannot determine IP address."
        read -p "Please input the hosts external IP Address: " HOST_IP
    fi
}

valid_ip() {
    local  ip=$1
    local  stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
            && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

confirm_ip() {

    read -p "Is this the correct external IP Address: ${HOST_IP} [Y/n]? " cont
    case "$cont" in
        y|Y)
            return 0
            ;;
        n|N)
            read -p "Please input the hosts external IP Address: " HOST_IP
            if valid_ip $HOST_IP; then
                return 0
            else
                echo "Please enter a valid IP Address."
                gather_ip
                return 1
            fi
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

CONFIG_DIR=$PWD/volumes/config-init/db

GLUU_VERSION=3.1.4_dev
INIT_CONFIG_CMD=""

DOMAIN=""
ADMIN_PW=""
EMAIL=""
ORG_NAME=""
COUNTRY_CODE=""
STATE=""
CITY=""

mkdir -p $CONFIG_DIR

# deploy service defined in docker-compose.yml
load_services() {
    echo "[I] Deploying containers"
    DOMAIN=$DOMAIN HOST_IP=$HOST_IP docker-compose up -d
}

prepare_config() {
    echo "[I] Preparing cluster-wide configuration"

    # guess if config already in Consul
    if [[ ! -z $(docker ps --filter name=consul -q) ]]; then
        consul_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' consul)
        DOMAIN=$(curl $consul_ip:8500/v1/kv/gluu/config/hostname?raw -s)
    fi

    # if there's no config in Consul, ask users whether they want to load from previously saved config
    if [[ -z $DOMAIN ]]; then
        echo "[W] Configuration not found in Consul"

        if [[ -f $CONFIG_DIR/config.json ]]; then
            read -p "[I] Load previously saved configuration in local disk? [Y/n]" load_choice
            
            if [[ $load_choice != "n" && $load_choice != "N" ]]; then
                DOMAIN=$(cat $CONFIG_DIR/config.json |  awk ' /'hostname'/ {print $2} ' | sed 's/[",]//g')
                INIT_CONFIG_CMD="load"
            fi
        fi
    fi

    # config is not loaded from previously saved configuration
    if [[ -z $DOMAIN ]]; then
        echo "[I] Creating new configuration, please input the following parameters"
        read -p "Enter Domain:                 " DOMAIN
        read -p "Enter Country Code:           " COUNTRY_CODE
        read -p "Enter State:                  " STATE
        read -p "Enter City:                   " CITY
        read -p "Enter Email:                  " EMAIL
        read -p "Enter Organization:           " ORG_NAME
        while true; do
            read -s -p "Enter Admin/LDAP Password:    " ADMIN_PW
            echo
            read -s -p "Confirm Admin/LDAP Password:    " password2
            echo
            [ "$ADMIN_PW" = "$password2" ] && break || echo "Please try again"
        done

        case "$ADMIN_PW" in
            * ) ;;
            "") echo "Password cannot be empty"; exit 1;
        esac

        read -p "Continue with the above settings? [Y/n]" choiceCont

        case "$choiceCont" in
            y|Y ) ;;
            n|N ) exit 1 ;;
            * )   ;;
        esac

        INIT_CONFIG_CMD="generate"
    fi
}

load_config() {
    echo "[I] Loading existing config."
    docker run \
        --rm \
        --network container:consul \
        -v $CONFIG_DIR:/opt/config-init/db/ \
        -e GLUU_CONFIG_ADAPTER=consul \
        -e GLUU_CONSUL_HOST=consul \
        gluufederation/config-init:$GLUU_VERSION \
        load
}

generate_config() {
    echo "[I] Generating configuration for the first time; this may take a moment"
    docker run \
        --rm \
        --network container:consul \
        -v $CONFIG_DIR:/opt/config-init/db/ \
        -e GLUU_CONFIG_ADAPTER=consul \
        -e GLUU_CONSUL_HOST=consul \
        gluufederation/config-init:$GLUU_VERSION \
        generate \
        --admin-pw $ADMIN_PW \
        --email $EMAIL \
        --domain $DOMAIN \
        --org-name "$ORG_NAME" \
        --country-code $COUNTRY_CODE \
        --state $STATE \
        --city $CITY \
        --ldap-type opendj
}

gather_ip
until confirm_ip; do : ; done

# ==========
# entrypoint
# ==========
prepare_config
load_services

case $INIT_CONFIG_CMD in
    "load")
        load_config
        ;;
    "generate")
        generate_config
        ;;
esac
