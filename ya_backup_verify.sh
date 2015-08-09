#!/bin/bash

# simple script to verify that the various backup scripts are working successfully and emails @@EMAIL_ADDRESS@@ about it.
# intended to live in /etc/cron.daily, or whatever period of nagging emails you want.
# note - will fire both if the backup touch script file does not exist OR if it hasn't been modified for the "right" time, eg "daily"

export contact_email=@@EMAIL_ADDRESS@@ 
failing_operations=""

# Find the backup files and verify based on the scope (eg, daily, weekly, hourly)
for i in /etc/cron.*/*_backup; do
  echo "Found Ya Backup '*_backup' named file: $i"
  scope=`ls $i | awk -F. '{print $2}' | awk -F/ '{print $1}'` #eg, scope="daily"
  name=`ls $i | awk -F/ '{print $4}'` #eg, name="example_config_backup"
  case $scope in
    "hourly")
      echo "Checking hourly backups"
      if [ ! -f /var/run/$name ]; then
        test=$i
      else
        test=`find /var/run -name "$name" -mmin +60 | xargs -I{} ls {}`
      fi;
      failing_operations="$failing_operations $test" 
      ;;
    "daily")
      echo "Checking daily backups"
      if [ ! -f /var/run/$name ]; then
        test=$i
      else
        test=`find /var/run -name "$name" -mtime +1 | xargs -I{} ls {}`
      fi;
      failing_operations="$failing_operations $test" 
      ;;
    "weekly")
      echo "Checking weekly backups"
      if [ ! -f /var/run/$name ]; then
        test=$i
      else
        test=`find /var/run -name "$name" -mtime +7 | xargs -I{} ls {}`
      fi;
      failing_operations="$failing_operations $test"
      ;;
    "monthly")
      echo "Checking monthly backups"
      # picking 31 days as a safe non-false alarm value, eg. tripping on short months
      if [ ! -f /var/run/$name ]; then
        test=$i
      else
        test=`find /var/run -name "$name" -mtime +31 | xargs -I{} ls {}`
      fi;
      failing_operations="$failing_operations $test" 
      ;;
    "d")
      echo "Skipping backup found in 'cron.d'"
      ;;
    *)
      echo "Crazypants error - full of bees."
      exit 1
      ;;
  esac
done

# Call for help or spit out a happy message to syslog via logger
logger -t YetAnotherBackupCheck "*** executing Yet Another Backup simple check ***"
if [[ -z "${failing_operations// }" ]]; then
  logger -t YetAnotherBackupCheck "All backup operations appear to normal!"
else
  logger -t YetAnotherBackupCheck "Detected failing backup(s)!  Sending email!"
  logger -t YetAnotherBackupCheck "Failing operations: $failing_operations"
  echo "$failing_operations" | mail -s "Backup system seems to be failing!  Please check logs on host '`hostname`' for the following:" $contact_email
fi
logger -t YetAnotherBackupCheck "*** Yet Another Backup simple health check complete ***"
