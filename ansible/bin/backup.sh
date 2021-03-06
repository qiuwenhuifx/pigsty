#!/bin/bash
set -uo pipefail

#==============================================================#
# File      :   backup.sh
# Mtime     :   2018-12-06
# Desc      :   PostgreSQL backup script
# Path      :   /pg/bin/backup.sh
# Author    :   Vonng(fengruohang@outlook.com)
# Depend    :   lz4, ~/.pgpass for replication, openssl
#==============================================================#

# module info
__MODULE_BACKUP="backup"

PROG_DIR="$(cd $(dirname $0) && pwd)"
PROG_NAME="$(basename $0)"

# psql & pg_basebackup PATH
export PATH=/usr/pgsql/bin:${PATH}


#==============================================================#
#                             Usage                            #
#==============================================================#
function usage(){
    cat <<- 'EOF'

    NAME
        backup.sh   -- make base backup from PostgreSQL instance

    SYNOPSIS
        backup.sh -sdfeukr
        backup.sh --src postgres://localhost:5433/mydb --dst . --file mybackup.tar.lz4

    DESCRIPTION
        -s, --src, --url
            Backup source URL, optional, "postgres://replication@127.0.0.1/postgres" by default
            Note: if password is required, it should be provided in url or ~/.pgpass

        -d, --dst, --dir
            Where to put backup files, "/pg/backup" by default

        -f, --file
            Backup filename, "backup_${tag}_${date}.tar.lz4" by default

        -r, --remove
            .lz4 Files mtime before n minuts ago will be removed, default is 1200 (20hour)

        -t, --tag
            Backup file tag, if not set, local ip address will be used.
            Also used as part of default filename

        -k, --key
            Encryption key when --encrypt is specified, default key is ${tag}

        -u, --upload
            Upload backup files to ufile, filemgr & /etc/ufile/config.cfg is required

        -e, --encryption
            Encrypt with RC4 using OpenSSL, if not key is specified, tag is used

        -h, --help
            Print this message

    EXAMPLES
        routine backup for coredb:
            00 01 * * * /pg/bin/backup.sh --encrypt --upload --tag=paymentdb 2>> /pg/tlog/backup.log

        manual & one-time backup:
            ./backup.sh -s postgres://10.189.1.1:5432/mydb -d . -f once_backup.tar.lz4 -e -tag manual

        extract backup files:
            unlz4 -d -c ${BACKUP_FILE} | tar -xC ${DATA_DIR}
            openssl enc -rc4 -d -k ${PASSWORD} -in ${BACKUP_FILE} | unlz4 -d -c | tar -xC ${DATA_DIR}
EOF
}


#==============================================================#
#                             Utils                            #
#==============================================================#
# logger functions
function log_debug() {
    [ -t 2 ] && printf "\033[0;34m[$(date "+%Y-%m-%d %H:%M:%S")][DEBUG] $*\033[0m\n" >&2 ||\
     printf "[$(date "+%Y-%m-%d %H:%M:%S")][DEBUG] $*\n" >&2
}
function log_info() {
    [ -t 2 ] && printf "\033[0;32m[$(date "+%Y-%m-%d %H:%M:%S")][INFO] $*\033[0m\n" >&2 ||\
     printf "[$(date "+%Y-%m-%d %H:%M:%S")][INFO] $*\n" >&2
}
function log_warn() {
    [ -t 2 ] && printf "\033[0;33m[$(date "+%Y-%m-%d %H:%M:%S")][WARN] $*\033[0m\n" >&2 ||\
     printf "[$(date "+%Y-%m-%d %H:%M:%S")][INFO] $*\n" >&2
}
function log_error() {
    [ -t 2 ] && printf "\033[0;31m[$(date "+%Y-%m-%d %H:%M:%S")][ERROR] $*\033[0m\n" >&2 ||\
     printf "[$(date "+%Y-%m-%d %H:%M:%S")][INFO] $*\n" >&2
}

# get primary IP address
function local_ip(){
    # ip range in 10.xxx.xxx.xx or 192.xxx.xx.xx
    echo $(/sbin/ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' \
    | grep -v 127.0.0.1 | grep -Eo '(10|192)\.([0-9]*\.){2}[0-9]*' | head -n1 )
}

# send mail via mail service
function send_mail(){
    local subject=$1
    local content=$2
    local to=${3-"fengruohang@p1.com"}
    local mail_service="http://10.191.167.134:28888/v1/sendmail/"

    curl -s -d "subject=${subject}&content=${content}&to=${to}" ${mail_service} > /dev/null
}

# slave returns 't', psql access required
function is_slave(){
    echo $(psql -Atqc "SELECT pg_is_in_recovery();")
}


#==============================================================#
#                            Backup                            #
#==============================================================#


#--------------------------------------------------------------#
# Name: make_backup
# Desc: make pg base backup to given path
# Arg1: Postgres URI
# Arg2: Backup filepath
# Arg3: Encrytion key, optional
# Note: if key is provided, encrypt backup with openssl rc4
#--------------------------------------------------------------#
function make_backup(){
    local pg_url=$1
    local backup_path=$2
    local key=${3-''}

    if [[ ! -z "${key}" ]]; then
        # if key is provided, encrypt with rc4 using openssl
        pg_basebackup -d ${pg_url} -Xf -Ft -c fast -v -D -  \
        | lz4 -q -z \
        | openssl enc -rc4 -k ${key} > "${backup_path}"
        # extract:  openssl enc -rc4 -d -k ${KEY} -in ${BKUP_FILE} | unlz4 -c | tar -xC ${DATA_DIR}
        return $?
    else
        pg_basebackup -d ${pg_url} -Xf -Ft -c fast -v -D -  \
            | lz4 -q -z > "${backup_path}"
        # extract:  unlz4 ${BKUP_FILE} -c | tar -xC ${DATA_DIR}
        return $?
    fi
}

#--------------------------------------------------------------#
# Name: kill_base_backup
# Desc: kill existing running backup process
#--------------------------------------------------------------#
function kill_base_backup(){
    local pids=$(ps aux | grep pg_basebackup | grep -e "-Xf")
    log_warn "killing basebackup processes ${pids}"

    for pid in ${pids}
    do
        log_warn "kill basebackup process: $pid"
        echo $pid | awk '{print $2}' | xargs -n1 kill
        log_info "kill basebackup process ${pid} done"
    done

    log_warn "basebackup processes killed"
}


#--------------------------------------------------------------#
# Name: remove_backup
# Desc: remove old backup files (*.lz4) in given backup dir
# Arg1: backup directory
# Arg2: remove threshhold (minutes, default 1200, i.e 20hour)
#--------------------------------------------------------------#
function remove_backup(){
    # delete *.lz4 file mtime before 20h ago by default
    local backup_dir=$1
    local remove_condition=${2-'1200'}
    remove_condition="-mmin +${remove_condition}"

    log_warn "[BKUP] local obsolete backups:"
    log_warn "$(find "${backup_dir}" -maxdepth 1 -type f ${remove_condition} -name '*.lz4')"
    find "${backup_dir}" -maxdepth 1 -type f -name '*.lz4' ${remove_condition} -delete
    return $?
}


#--------------------------------------------------------------#
# Name: upload_backup
# Desc: upload backup files to ufile
# Arg1: backup_filepath
# Arg2: tag , backup taged with it will be removed
#--------------------------------------------------------------#
function upload_backup(){
    local backup_filepath=$1
    local tag=$2
    local filename=$(basename ${backup_filepath})

    log_info "[UFILE] upload ${backup_filepath}"
    filemgr -action mput -speedlimit 104857600 -bucket postgresql-backup \
            -key ${filename} -file ${backup_filepath} -trycontinue 1&>2

    local status=$?
    if [[ ${status} != 0 ]]; then
        log_error "[UFILE] upload failed! status: ${status}"
        return 1
    fi
    log_info "[UFILE] upload to ${filename}"

    # old remote backups needs to be delete
    local prefix="backup_${tag}_"
    keys_to_delete=$(filemgr -action getfilelist -bucket postgresql-backup -prefix ${prefix} -format '{key}' \
    | grep backup \
    | grep -v $(basename ${backup_filepath}))

    log_warn "[UFILE] obsolete backups: ${keys_to_delete}"
    for key in ${keys_to_delete}
    do
        log_warn "[UFILE] remove ${key} @ ufile due to retention"
        filemgr -action delete -bucket postgresql-backup -key ${key}
    done
    return 0
}



#==============================================================#
#                            MAIN                              #
#==============================================================#
function main(){
    # default settings
    local lock_path="/tmp/backup.lock"
    local src="postgres://replication@127.0.0.1/postgres"
    local dst="/pg/backup"
    local tag=$(local_ip)
    local remove="1200"
    local upload="false"
    local encrypt="false"

    local filename=""
    local key=""
    local provided_filename=""
    local provided_key=""


    # parse arguments
    while (( $# > 0)); do
        case "$1" in
            -s|--src=*|--url=*)
                [ "$1" == "-s" ] && shift
                src=${1##*=};       shift
            ;;
            -d|--dst=*|--dir=*)
                [ "$1" == "-d" ] && shift
                dst=${1##*=};       shift
            ;;
            -f|--file=*)
                [ "$1" == "-f" ] && shift
                provided_filename=${1##*=};  shift
            ;;
            -r|--remove=*)
                [ "$1" == "-r" ] && shift
                remove=${1##*=};    shift
            ;;
            -k|--key=*)
                [ "$1" == "-k" ] && shift
                provided_key=${1##*=};       shift
            ;;
            -t|--tag=*)
                [ "$1" == "-t" ] && shift
                tag=${1##*=};       shift
            ;;
            -u|--upload)
                upload="true";      shift
            ;;
            -e|--encrypt)
                encrypt="true";     shift
            ;;
            -h) usage ;             exit
            ;;
            *)
                usage
                exit 1
            ;;
        esac
    done

    # overwrite filename & key with tag
    if [[ -z "${provided_filename}" ]]; then
        # if filename is not specified, use "backup_${tag}_${date}.tar.lz4" as filename
        filename="backup_${tag}_$(date +%Y%m%d).tar.lz4"
    else
        filename=${provided_filename}
    fi
    local backup_filepath="${dst}/${filename}"


    if [[ -z "${provided_key}" ]]; then
        # if key is not specified, use ${tag} as key
        key=${tag}
    else
        key=${provided_key}
    fi



    # check parameters
    log_info "[INIT] checking parameters"

    if [[ ! -d ${dst} ]]; then
        log_error "[INIT] destination directory ${dst} not exist"
        exit 2
    fi

    if [[ ${remove} != [0-9]* ]]; then
        log_error "[INIT] -r,--remove should be an integer represent minutes of retention"
        exit 3
    fi

    if [[ -z $(command -v pg_basebackup) ]]; then
        log_error "[INIT] pg_basebackup binary not found in PATH"
        exit 4
    fi

    if [[ ${upload} == "true" ]]; then
        # if upload is specified, filemgr should exist
        if [[ -z $(command -v filemgr) ]]; then
            log_error "[INIT] filemgr binary not found in PATH when upload is specified"
            exit 5
        fi

        if [[ ! -f "/etc/ufile/config.cfg" ]]; then
            log_error "[INIT] filemgr requires config file in /etc/ufile/config.cfg"
            exit 6
        fi
    fi

    if [[ ${encrypt} == "true" ]]; then
        # if encrypt is specified, openssl sould exist
        if [[ -z $(command -v openssl) ]]; then
            log_error "[INIT] openssl binary not found in PATH when encrypt is specified"
            exit 7
        fi
    fi

    log_debug "[INIT] #====== BINARY"
    log_debug "[INIT] pg_basebackup     :   $(command -v pg_basebackup)"
    log_debug "[INIT] filemgr           :   $(command -v filemgr)"
    log_debug "[INIT] openssl           :   $(command -v openssl)"

    log_debug "[INIT] #====== PARAMETER"
    log_debug "[INIT] filename  (-f)    :   ${filename}"
    log_debug "[INIT] src       (-s)    :   ${src}"
    log_debug "[INIT] dst       (-d)    :   ${dst}"
    log_debug "[INIT] tag       (-t)    :   ${tag}"
    log_debug "[INIT] key       (-k)    :   ${key}"
    log_debug "[INIT] encrypt   (-e)    :   ${encrypt}"
    log_debug "[INIT] upload    (-u)    :   ${upload}"
    log_debug "[INIT] remove    (-r)    :   -mmin +${remove}"



    # Lock (Avoid multiple instance)
    if [ -e ${lock_path} ] && kill -0 $(cat ${lock_path}); then
        log_error "[LOCK] acquire lock @ ${lock_path} failed, other_pid=$(cat ${lock_path})"
        exit 8
    fi
    log_info "[LOCK] acquire lock @ ${lock_path}"
    trap "rm -f ${lock_path}; exit" INT TERM EXIT
    echo $$ > ${lock_path}
    log_info "[LOCK] lock acquired success on ${lock_path}, pid=$$"




    # Start Backup
    log_info "[BKUP] backup begin, from ${src} to ${backup_filepath}"
    if [[ ${encrypt} != "true" ]]; then
        log_info "[BKUP] backup in normal mode"
        key=""
    else
        log_info "[BKUP] backup in encryption mode"
    fi

    make_backup ${src} ${backup_filepath} ${key}

    if [[ $? != 0 ]]; then
        log_error "[BKUP] backup failed!"
        exit 9
    fi
    log_info "[BKUP] backup complete!"


    # remove old local backup
    log_info "[RMBK] remove local obsolete backup: ${remove}"
    remove_backup ${dst} ${remove}
    if [[ $? != 0 ]]; then
        log_error "[RMBK] remove local obsolete backup failed!"
        exit 10
    fi
    log_info "[RMBK] remove old backup complete"


    # upload local backup to remote ufile
    if [[ ${upload} == "true" ]]; then
        log_info "[UPLD] upload backup ${backup_filepath} to ufile"
        upload_backup ${backup_filepath} ${tag}
        if [[ $? != 0 ]]; then
            log_err "[UPLD] upload backup failed"
            exit 11
        fi
        log_info "[UPLD] upload backup complete: ${filename}"
    fi

    # unlock
    rm -f ${lock_path}
    log_info "[LOCK] release lock @ ${lock_path}"

    # done
    log_info "[DONE] backup procdure complete!"
}

main "$@"