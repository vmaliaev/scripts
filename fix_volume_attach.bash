#!/usr/bin/env bash
set -o pipefail
 
OPENRC_FILE=${HOME}/openrc
DB_NOVA_USER=nova
CURR_DATE=$(date +'%F_%H-%M-%S')
LOG_FILE="${HOME}/fix-volume-issues-$CURR_DATE.log"
MYSQL_DUMP_FILE="${HOME}/nova-db-$CURR_DATE.mysqldump"
DRY_RUN_MODE=1
while getopts ":u:p:H:l:m:o:Pdh" FLAG; do
        case $FLAG in
               u)
                       DB_NOVA_USER=$OPTARG
                       ;;
               p)
                       DB_NOVA_PASS=$OPTARG
                       ;;
               H)
                       DB_HOST=$OPTARG
                       ;;
                l)
                        LOG_FILE=$OPTARG
                        ;;
                m)
                        MYSQL_DUMP_FILE=$OPTARG
                        ;;
                P)
                        DRY_RUN_MODE=0
                        ;;
                o)
                        OPENRC_FILE=$OPTARG
                        ;;
                d)
                        set -x
                        ;;
               \?)
                       echo "Invalid option: -$OPTARG. Use -h for help" >&2
                       exit 1
                       ;;
               :)
                       echo "Option -$OPTARG requires an argument." >&2
                       exit 1
                       ;;
               h)
                       echo -e "This script cleans up Cinder volumes entries for really deleted volumes in Nova database\n\nUsage: $(basename $0) OPTIONS\n\n\
[-u <nova_db_user>]            - Optional. Nova database username. Default value: nova\n\
-p <nova_db_pass>              - Mandatory. Password for nova database. Can be provided as DB_NOVA_PASS env variable\n\
-H <database_host>             - Mandatory. IP or hostname of Nova database host. Can be provided as DB_HOST env variable\n\
[-P]                           - Optional. Disable dry-run mode (default) and go to production mode. Allows changes saving to nova database.\n\
[-l <log_file_name>]           - Optional. Name of log file. Default value: ${HOME}/fix-volume-issues-<current_date>\n\
[-m <mysql_dump_file>]         - Optional. Name of file for storing Nova DB dump prior to make any changes. Default value: ${HOME}/nova-db-<current_date>.mysqldump\n\
[-d]                           - Optional. Enable debug mode (e.g. run bash with -x key)\n\
[-o <openrc_file>]                    - Optional. Location of Openrc file with Openstack credentials. Default value: ${HOME}/openrc"
                       exit
                       ;;
        esac
done
shift $((OPTIND-1))
 
if [[ -z "$DB_HOST" || -z "$DB_NOVA_PASS" ]]; then
        echo "Invalid usage. <nova_db_password> and <database_host> arguments are mandatory. Use -h fo help."
        exit 1
fi
 
source $OPENRC_FILE
 
# Grab list of instances ids
INSTANCES=$(nova list --all-tenants | awk -F '|' '{print $2}' | grep -v -E "ID|^$")
if [ "$?" != "0" -o -z "$INSTANCES" ]; then
  echo "Cannot retreive list of instances! Aborting..." | tee -a $LOG_FILE
  exit 1
else
  echo -e ">>>>>>>>>>>> The total amount of instances to proceed: $(echo "$INSTANCES" | wc -l) <<<<<<<<<<<<\n"
fi
 
# Check if dry-run mode disabled
if [ "$DRY_RUN_MODE" == "0" ]; then
echo -e "---------- ATTENTION! Script runs in production mode! All changes to nova database will be recorded! ----------\n"
commit_changes() {
  bdm_ids_to_fix=$(mysql -BN -u nova -p$DB_NOVA_PASS -h $DB_HOST nova -e "select id from block_device_mapping where volume_id='$id' and instance_uuid='$instance' and deleted='0'")
 
  if [ "$?" == "0" ]; then
 
  # Iterate over volume incremental ids retreived from block_device_mapping table
    for bdm_id in $bdm_ids_to_fix; do
      if mysql -BN -u nova -p$DB_NOVA_PASS -h $DB_HOST nova -e "update block_device_mapping set deleted='$bdm_id' where id='$bdm_id' and volume_id='$id' and instance_uuid='$instance'"; then
        echo "SUCCESS: Volume $id with internal id $bdm_id was cleaned up!" | tee -a $LOG_FILE
        FIXED_VOLUMES="$FIXED_VOLUMES""FIXED: volume $id, inernal volume id $bdm_id, instance $instance\n";
      else
        echo "CRITICAL: Impossible to issue mysql UPDATE command for volume $id, internal id $bdm_id, instance $instance" | tee -a $LOG_FILE
        NON_FIXED_VOLUMES="$NON_FIXED_VOLUMES""NOT FIXED: volume $id, inernal volume id $bdm_id, instance $instance\n";
        EXIT_CODE=1
      fi # end of mysql update if
    done # end of loop over $bdm_ids_to_fix
 
  else
    echo "ERROR: mysql SELECT query for volume $id, instance $instance failed!" | tee -a $LOG_FILE
    NON_FIXED_VOLUMES="$NON_FIXED_VOLUMES""NOT FIXED: volume $id, inernal volume id $bdm_id, instance $instance\n";
    EXIT_CODE=1
  fi # end of mysql select exit code if
}
else
echo -e "---------- INFO: Script runs in dry-run mode. Changes won't be saved ----------\n" | tee -a $LOG_FILE
commit_changes(){
  VOLUMES_TO_FIX="$VOLUMES_TO_FIX""FIXME: volume $id, inernal volume id $bdm_id, instance $instance\n";
}
fi
 
 
# Check if we have mysql-client utilities
which mysqldump &> /dev/null && which mysql &>/dev/null
if [ "$?" != "0" ]; then
  echo "mysql client and mysqldump utility aren't installed. Trying to isntall them..." | tee -a $LOG_FILE
  # Check if percona ubuntu repo is enabled
  if ! grep -riq "deb[ \t]*http://repo.percona.com/apt[ \t]precise[ \t]main[ \t]*$" /etc/apt/; then
    echo "Percona Ubuntu repositry isn't enabled. This is not database node. Installing mysql-client" | tee -a $LOG_FILE
    mysql_client_pkg="mysql-client"
  else
    echo "Percona cluster node is detected. Installing percona-xtradb-cluster-client-5.6..." | tee -a $LOG_FILE
    mysql_client_pkg="percona-xtradb-cluster-client-5.6"
  fi
  apt-get update -qq
  if ! apt-get install -y -q $mysql_client_pkg; then echo "$mysql_client_pkg package cannot be installed. Aborting..." | tee -a $LOG_FILE; exit 1; fi
fi
 
# Create backup of nova DB:
if ! mysqldump -u nova -p$DB_NOVA_PASS -h $DB_HOST nova > $MYSQL_DUMP_FILE; then
  echo "ERROR: Couldn't create backup of nova database. Exitting..." | tee -a $LOG_FILE
  exit 1
fi
 
# Main loop tries to fix as many volume entries as possible and don't break on any errors
# But if at least one volume won't be fixed, script will exit witn non-zero code
EXIT_CODE=0
 
for instance in $INSTANCES; do
  vol_ids=$(nova show $instance | grep os-extended-volumes:volumes_attached | awk -F '|' '{print $3}')
  if [ "$?" != "0" ]; then
    printf '=%.0s' {1..178} | tee -a $LOG_FILE
    echo -e "\nERROR: Instance $instance won't be processed: cannot determine volumes attached to it! 'nova show $instance' command failed" | tee -a $LOG_FILE
    printf '=%.0s' {1..178} | tee -a $LOG_FILE
    echo -e "\n\n"| tee -a $LOG_FILE
    NOVA_SHOW_FAILS="$NOVA_SHOW_FAILS""Instance $instance wasn't processed due to 'nova show' fail\n"
    EXIT_CODE=1
    continue
  fi
  if [[ ! "$vol_ids" =~ "[]" ]]; then
    printf '=%.0s' {1..139} | tee -a $LOG_FILE
    for id in $(echo $vol_ids |grep -o -E "[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}"); do
      echo -e "\nNova shows that volume $id attached to instance $instance" | tee -a $LOG_FILE
      cinder_status_mes=$(cinder show $id 2>&1)
      if [ "$?" != "0" ] ; then
        if [ "$cinder_status_mes" == "ERROR: No volume with a name or ID of '$id' exists." ]; then
          echo "WARNING: Volume $id marked as attached to instance $instance in nova block_device_mapping table, but realy doesn't exist" | tee -a $LOG_FILE
          commit_changes
        else
          echo "ERROR: Impossible to check volume status: 'cinder show $id' command was failed. Error message: $cinder_status_mes" | tee -a $LOG_FILE
          CINDER_SHOW_FAILS="$CINDER_SHOW_FAILS""Volume $id wasn't checked due to of 'cinder show' failure\n"
          EXIT_CODE=1
        fi # cinder show status message check
      else
        echo "Volume $id is attached to instance $instance correctly and exists in cinder DB" | tee -a $LOG_FILE
      fi # cinder show exit code check
    done
    printf '=%.0s' {1..139} | tee -a $LOG_FILE
    echo -e "\n\n"| tee -a $LOG_FILE
  else
    printf '=%.0s' {1..97} | tee -a $LOG_FILE
    echo -e "\nInstance $instance is already OK and doesn't have any attached volumes" | tee -a $LOG_FILE
    printf '=%.0s' {1..97} | tee -a $LOG_FILE
    echo -e "\n\n"| tee -a $LOG_FILE
  fi
done
 
if [ "$EXIT_CODE" != "0" ]; then
  echo "CRITICAL: Not all volumes were checked or fixed! Check logfile $LOG_FILE for more information!\
You can restore Nova DB from file $MYSQL_DUMP_FILE if needed"
fi
 
# Some statistics
if [ "$DRY_RUN_MODE" != "0" ]; then
  echo -e ">>>>>>>>>>>>DRY RUN MODE RESULTS<<<<<<<<<<<<\n\n"
  echo -e "NON-CHECKED INSTANCES: $(echo -e "$NOVA_SHOW_FAILS" | grep -c -v "^$") from $(echo "$INSTANCES" | wc -l)\n\n"$NOVA_SHOW_FAILS"\n\n" | tee -a $LOG_FILE
  echo -e "NON-CHECKED VOLUMES: $(echo -e "$CINDER_SHOW_FAILS" | grep -c -v "^$")\n\n"$CINDER_SHOW_FAILS"\n\n" | tee -a $LOG_FILE
  echo -e "VOLUMES TO FIX: $(echo -e "$VOLUMES_TO_FIX" | grep -c -v "^$")\n\n"$VOLUMES_TO_FIX"\n\n" | tee -a $LOG_FILE
else
  echo -e ">>>>>>>>>>>>PRODUCTION MODE RESULTS<<<<<<<<<<<<\n\n"
  echo -e "NON-CHECKED INSTANCES: $(echo -e "$NOVA_SHOW_FAILS" | grep -c -v "^$") from $(echo "$INSTANCES" | wc -l)\n\n"$NOVA_SHOW_FAILS"\n\n" | tee -a $LOG_FILE
  echo -e "NON-CHECKED VOLUMES: $(echo -e "$CINDER_SHOW_FAILS" | grep -c -v "^$")\n\n"$CINDER_SHOW_FAILS"\n\n" | tee -a $LOG_FILE
  echo -e "NUMBER OF FIXED VOLUMES: $(echo -e "$FIXED_VOLUMES" | grep -c -v "^$")\n\n"$FIXED_VOLUMES"\n\n\
NUMBER OF NON-FIXED VOLUMES: $(echo -e "$NON_FIXED_VOLUMES" | grep -c -v "^$")\n\n"$NON_FIXED_VOLUMES"" | tee -a $LOG_FILE
fi
 
exit $EXIT_CODE
