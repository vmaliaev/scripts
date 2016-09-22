#!/usr/bin/env bash
# This script is intended to save current Nagios monitoring state
# It tries to get and copy "immediate" snapshot of Nagios status from retention file
# If retention feature is disabled (so we cannot receive "snapshot"), it will try to backup Nagios state file which is updated every n seconds (accordingly to settings)

NAGIOS_CONFIG=/etc/nagios3/nagios.cfg
NAGIOS_RETAIN_BACKUP=${HOME}/nagios-retain-state-backup
NAGIOS_LOG_BACKUP=${HOME}/nagios-log-backup
NAGIOS_STATUS_BACKUP=${HOME}/nagios-status-state-backup

retain_state_info=$(grep retain_state_information $NAGIOS_CONFIG | cut -d '=' -f 2)
RETAIN_ERROR=0
if [ "$retain_state_info" == "1" ]; then
  retain_file=$(grep state_retention_file $NAGIOS_CONFIG | cut -d '=' -f 2)
  if [ -d "$(dirname $retain_file 2>/dev/null)" ]; then
    command_file=$(grep command_file $NAGIOS_CONFIG | cut -d '=' -f 2)
    if [ -e "$command_file" ]; then
      echo -e "Trying to backup retention file\nInitiating SAVE_STATE_INFORMATION command\nNagios command_file: $command_file\nNagios retain_file: $retain_file\n"
      now=`date +%s`
      printf "[%du] SAVE_STATE_INFORMATION\n" $now > $command_file
      NAGIOS_RETAIN_BACKUP="$NAGIOS_RETAIN_BACKUP"_"$(date -d @$(echo $now) +'%F_%H-%M-%S')"
      # Copy retention file
      if ! cp $retain_file $NAGIOS_RETAIN_BACKUP 2>/dev/null; then
        echo -e "ERROR: Backup of retain file $retain_file was failed\n"
        RETAIN_ERROR=1
      else
        echo -e "Retention file was successfully copied. Backup is located here: $NAGIOS_RETAIN_BACKUP\n"
      fi
    else
      echo -e "ERROR: Cannot find Nagios command_file for sending SAVE_STATE_INFORMATION\n"
      RETAIN_ERROR=1
    fi
  else
    echo -e "ERROR: Invalid path to retention file: $(dirname $retain_file) doesn't exist!\n"
    RETAIN_ERROR=1
  fi
else
  echo -e "WARNING: Cannot backup retain file! retain_state_info option is disabled for this Nagios server!\n"
  RETAIN_ERROR=1
fi

if [ "$RETAIN_ERROR" == "1" ]; then
  status_file=$(grep status_file $NAGIOS_CONFIG | cut -d '=' -f 2)
  if [ -e "$status_file" ]; then
    echo -e "Trying to backup Nagios status file $status_file instead of retention one\n"
    now=`date +%s`
    # Copy status file
    NAGIOS_STATUS_BACKUP="$NAGIOS_STATUS_BACKUP"_"$(date -d @$(echo $now) +'%F_%H-%M-%S')"
    if ! cp $status_file $NAGIOS_STATUS_BACKUP 2>/dev/null; then
      echo -e "ERROR: Status file $status_file backup was failed\n"
    else
      echo -e "Status file was successfully copied. Backup is located here: $NAGIOS_STATUS_BACKUP\n"
    fi
  else
    echo -e "ERROR: Invalid path to status file: $status_file doesn't exist!\n"
  fi
fi

# Backup nagios log file
log_file=$(grep log_file $NAGIOS_CONFIG | cut -d '=' -f 2)
if [ -z "$now" ]; then now=$(date +%s); fi
if [ -e "$log_file" ]; then
 echo -e "Trying to backup Nagios log file $log_file\n"
 # Copy log file
 NAGIOS_LOG_BACKUP="$NAGIOS_LOG_BACKUP"_"$(date -d @$(echo $now) +'%F_%H-%M-%S')"
 if ! cp $log_file $NAGIOS_LOG_BACKUP 2>/dev/null; then
    echo -e "ERROR: Backup of log file $log_file was failed\n"
 else
    echo -e "Log file was successfully copied. Backup is located here: $NAGIOS_LOG_BACKUP\n"
 fi
else
  echo -e "ERROR: Log file $log_file doesn't exist!\n"
fi
