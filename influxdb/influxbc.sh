# !/bin/dash -x

# back up yesterday data

if [ -f /home/ubuntu/varconf/backup_var.conf ]; then
    source /home/ubuntu/varconf/backup_var.conf
else
    echo "backup_var.conf not found"
    exit 1
fi

# azure config
if ! az --version >>/dev/null 2>&1; then
    echo "az CLI env is required !!!"
    exit 1
fi

# may be used in VM
# export AZURE_STORAGE=${AZURE_STORAGE}
# : ${AZURE_STORAGE_SAS_TOKEN:?"AZURE_STORAGE_SAS_TOKEN env variable is required"}
# : ${INFLUXDB_HOST:?"INFLUXDB_HOST env variable is required"}
# : ${INFLUXDB_ORG:?"INFLUXDB_ORG env variable is required"}
# : ${INFLUXDB_TOKEN:?"INFLUXDB_TOKEN env variable is required"}

export VAR_CONF_PATH=${VAR_CONF_PATH:-$var_conf_path}
startDate=$startDate
export BACKUP_PATH=${BACKUP_PATH:-$backup_tar_path}
export BACKUP_ARCHIVE_PATH=${BACKUP_ARCHIVE_PATH:-$backup_tar_path}
export INFLUXDB_HOST=${INFLUXDB_HOST:-$influxdb_host}
export INFLUXDB_ORG=${INFLUXDB_ORG:-$influxdb_org}
export INFLUXDB_BACKUP_PORT=${INFLUXDB_BACKUP_PORT:-$influxdb_backup_port}
export AZURE_ACCOUNT_NAME=${AZURE_ACCOUNT_NAME:-$azure_account_name}
export AZURE_CONTAINER_NAME=${AZURE_CONTAINER_NAME:-$azure_container_name}
export AZURE_FILE_NAME=${AZURE_FILE_NAME:-${backup_tar_file}}
export AZURE_STORAGE_AUTH_MODE=${AZURE_STORAGE_AUTH_MODE:-$azure_storage_auth_mode} # <option login|key>
export AZURE_ACCESS_TIER=${AZURE_ACCESS_TIER:-$azure_access_tier}                   # <option Hot|Cool|Archive>

# replace by a sas token. has to be container sas token, not the account.
export AZURE_STORAGE_SAS_TOKEN=${AZURE_STORAGE_SAS_TOKEN:-$azure_storage_sas_token}
# export AZURE_ACCESS_KEY=${AZURE_ACCESS_KEY:-}

# AZURE_STORAGE_CONNECTION_STRING: A connection string that includes the storage account key or a SAS token.
# export AZURE_STORAGE_CONNECTION_STRING=${AZURE_STORAGE_CONNECTION_STRING:-}
export CRON=${CRON:-$cron} #for testing。 if we want to back up at mid-night everyday, the format is  0 0 * * *

startcron() {
    if ! service cron status >>/dev/null 2>&1; then
        service cron start
    fi

    db=$2
    backup_tar_file=$db$backup_tar_file
    backup_tmp_file=$db$backup_tmp_file

    # echo "$1 . $HOME/backup_var.conf;  $HOME/influx_bc.sh backup $db >> /var/log/cron.log 2>&1" >/etc/cron.d/influxdbbackup
    echo "$1 . $VAR_CONF_PATH;  /bin/bash -c '$HOME/influx_bc.sh backup $db'>> /var/log/cron.log 2>&1" >/etc/cron.d/influxdbbackup
    cat /etc/cron.d/influxdbbackup
    crontab /etc/cron.d/influxdbbackup
    touch /var/log/cron.log
    crontab #&& tail -f /var/log/cron.log
}

backup() {
    # parameters used in this function
    #  $1  ->  # the value for line 173
    db=$1

    echo "Backing up to $BACKUP_PATH"
    backup_tar_file=$db$backup_tar_file
    backup_tmp_file=$db$backup_tmp_file

    if [ -d $BACKUP_PATH$backup_tmp_file ]; then
        rm -rf $BACKUP_PATH$backup_tmp_file
    fi
    mkdir -p $BACKUP_PATH$backup_tmp_file

    # back up command
    influxd backup -portable -db $db -start $startDate $BACKUP_PATH$backup_tmp_file
    # # influxd backup -portable -db $1 $BACKUP_PATH$backup_tmp_file

    # remove temp file
    if [ $? -ne 0 ]; then
        echo "Failed to backup to $BACKUP_PATH/$backup_tmp_file"
        exit 1
    fi

    if [ -e $BACKUP_ARCHIVE_PATH$backup_tar_file ]; then
        rm -rf $BACKUP_ARCHIVE_PATH$backup_tar_file
    fi

    # Create archive
    echo $(date +"%d-%B-%Y@%H:%M:%S")" - Creating archive $BACKUP_PATH$backup_tar_file."
    tar -cvzf $BACKUP_ARCHIVE_PATH$backup_tar_file -C$BACKUP_PATH $backup_tmp_file # tar files but ignoring the dirctionary
    rm -rf $BACKUP_PATH$backup_tmp_file
    echo "Sending file to azure cloud"

    # upload to blob
    if az storage blob upload --account-name $AZURE_ACCOUNT_NAME --container-name $AZURE_CONTAINER_NAME --name $backup_tar_file --file $BACKUP_ARCHIVE_PATH$backup_tar_file --tier $AZURE_ACCESS_TIER --sas-token $AZURE_STORAGE_SAS_TOKEN --auth-mode $AZURE_STORAGE_AUTH_MODE; then
        echo "Backup file copied to azure"
    else
        echo "Backup file failed to upload"
        exit 1
    fi

    rm -f $BACKUP_ARCHIVE_PATH$backup_tar_file
    echo "Backup is finished!"
}

restore() {

    # echo "input a database name that is backuped"
    # read -p 'database name: ' oldDB
    # inputValidation $oldDB

    # echo "input a database name that isn't exist"
    # read -p 'NEW database name using format <new_database_name new>: ' newDB
    # inputValidation $newDB

    oldDB=$1
    newDB=$2

    backup_tar_file=$oldDB$backup_tar_file
    backup_tmp_file=$oldDB$backup_tmp_file

    if [ -d $BACKUP_PATH$backup_tmp_file ]; then
        echo "Removing out of date backup"
        rm -rf $BACKUP_PATH$backup_tmp_file
    fi
    if [ -e $BACKUP_ARCHIVE_PATH$backup_tar_file ]; then
        echo "Removing out of date backup"
        rm -rf $BACKUP_ARCHIVE_PATH$backup_tar_file
    fi

    echo "Downloading latest backup from azure"
    if az storage blob download --account-name $AZURE_ACCOUNT_NAME --container-name $AZURE_CONTAINER_NAME --name $backup_tar_file --file $BACKUP_ARCHIVE_PATH$backup_tar_file --sas-token $AZURE_STORAGE_SAS_TOKEN --auth-mode $AZURE_STORAGE_AUTH_MODE; then
        echo "Downloaded"
    else
        echo "Failed to download latest backup"
        exit 1
    fi
    mkdir -p $BACKUP_PATH$backup_tmp_file
    # tar -xzf $BACKUP_ARCHIVE_PATH #-C $BACKUP_PATH
    tar -xvzf $BACKUP_ARCHIVE_PATH$backup_tar_file -C $BACKUP_PATH

    echo "Running restore"
    if influxd restore -portable -db $oldDB -newdb $newDB $BACKUP_PATH$backup_tmp_file; then
        echo "Successfully restored"
    else
        echo "Restore failed"
        exit 1
    fi
    echo "Done"
}

case "$1" in
"startcron")
    startcron "$CRON" $2
    ;;
"backup")
    backup $2
    ;;
"restore")
    restore $2 $3
    ;;
*)
    echo "Invalid command '$@'"
    echo "Usage: $0 {backup|restore|startcron}"
    ;;
esac
