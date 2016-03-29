#!/usr/bin/env bash
# Export MySQL databases into individual backup files and upload them
# to Amazon S3 (with optional GPG encryption).

# Path to config file to allow variables to be overridden.
readonly config_file=$(dirname "$0")/backup.cfg

# Date and time used to create backup directories "YYYY-MM-DD_HHII".
timestamp=$(date +"%Y-%m-%d_%H%M")
# Local backup directory path used to store files prior to upload.
backup_dir="/tmp/mysql-s3-backups/${timestamp}"
# Remove local backup directory upon script completion (true or false).
backup_dir_remove=true
# Default file extension for exported databases.
file_extension=".sql.gz"
# Lock file directory.
lock_dir="/tmp/mysql-s3-backup-lock"
# PID file.
pid_file="$lock_dir/pid"
# Display colored output.
colors=true

# Auto lookup path to mysql.
mysql_cmd=$(which mysql)
# Set to true if backing up from a MySQL slave server, this will stop the slave
# and start it again when the script is finished.
mysql_slave=false
# Use default MySQL config file.
mysql_use_defaults_file=true
# Specifically set the defaults file location, e.g. "/etc/my.cnf".
mysql_defaults_file=""
# If mysql_use_defaults_file is false, it will attempt to use the following
# parameters to connect to MySQL.
mysql_user=""
mysql_password=""
mysql_host=""
# List of databases to exclude from the export, this is a pipe separated list.
mysql_exclude="information_schema|performance_schema|mysql|sys"

# Auto lookup path to mysqladmin, used to start / stop slave.
mysqladmin_cmd=$(which mysqladmin)
# Auto lookup path to mysqldump.
mysqldump_cmd=$(which mysqldump)
# Default flags used for database dump.
mysqldump_args="--triggers --routines --force --opt --add-drop-database"

# Auto lookup path to gpg.
gpg_cmd=$(which gpg)
# If true, backups will be encrypted with GPG and the suffix ".gpg" added to
# each of the backup files.
gpg_enabled=false
# Default flags used for GPG encryption.
gpg_args="--encrypt --batch --trust-model always"
# Recipient of the public-key encrypted files
gpg_recipient=""
# Flag to enforce signing of the backups.
gpg_sign=false
# Default GPG key to sign with.
gpg_signer=""

# Default compress command, this must be set but can be changed.
compress_cmd="gzip -c"

# Auto lookup path to aws command.
aws_cmd=$(which aws)
# Enable upload to Amazon S3, if this is disabled, the "backup_dir_remove"
# flag will be set to false.
aws_enabled=true
# Set the AWS profile to use (~/.aws/credentials and ~/.aws/config)
aws_profile="mysql-s3-backup"
# Default AWS S3 bucket name.
aws_bucket="mysql-s3-backups"
# Default AWS directory to store backups.
aws_dir="$timestamp"

# Load overrides from external config file.
if [ -f "$config_file" ]; then
  . $config_file
fi

# Parse optional command line args.
for i in "$@"; do
  case $i in
    --no-colors) colors=false; shift;;
    --backup-dir=*) backup_dir="${i#*=}"; shift;;
  esac
done

# Set traps for specific signals.
trap finish EXIT
trap forced_cleanup SIGHUP SIGINT SIGTERM SIGQUIT SIGUSR1

# Force cleanup if script was terminated.
function forced_cleanup {
  message "error" "Script terminated"
  cleanup
  exit 1
}

# Tidy up after the script is finished, restarting the slave and removing
# the local backup dir if necessary.
function cleanup {
  echo "[Cleanup]"
  # Restart slave if required.
  if [ "$mysql_slave" == "true" ]; then
     printf "Restart slave ... "
     if [ "$mysql_slave_restart" == "true" ]; then
       "$mysqladmin_cmd" ${mysql_args} start-slave >/dev/null
       success_or_error
     else
       message "warn" "Skipped"
     fi
  fi
  # Tidy up files by deleting the backup directory.
  printf "Deleting local backup directory ... "
  if [ "$backup_dir_remove" == "true" ]; then
    rm -rf "$backup_dir"
    success_or_error
  else
    message "warn" "Skipped"
  fi
  # Remove the lock dir.
  printf "Removing lock file ... "
  rm -rf "$lock_dir"
  success_or_error
}

# Output a styled mini success or error message.
function message {
  icon="✘"
  case "$1" in
    "success") color=32; icon="✔"; message="Done" ;;
    "warn") color=33; message="Warning" ;;
    *) color=31; message="Error" ;;
  esac
  if [ "$2" ]; then message="$2"; fi
  if [ "$colors" == "true" ]; then
    printf "\e[0;${color}m${icon} ${message}\e[0m\n"
  else
    echo "${icon} ${message}"
  fi
}

# Display the script run time when it finishes.
function finish {
  local h=$(($SECONDS/3600))
  local m=$(($SECONDS%3600/60))
  local s=$(($SECONDS%60))
  printf "[Finished: %dh %dm %ds]\n" $h $m $s
}

# Stop the script, usually due to an error, triggers exit trap.
function quit {
  if [ "$1" ]; then message "error" "$1"; fi
  cleanup
  exit 1
}

# Display success or error message based on cmd response.
function success_or_error {
  if [ $? -eq 0 ]; then message "success"; else message "error"; fi
}

# Display success or error message based on cmd response.
function success_or_quit {
  if [ $? -eq 0 ]; then message "success"; else quit "error"; fi
}

# Check if the script is already running.
mkdir -p "$lock_dir" 2> /dev/null
if [ $? -eq 0 ]; then
  # Write process ID (PID) to pid_file.
  echo $$ > $pid_file
else
  quit "Backup is already running. ($pid_file)"
  exit 6
fi

# If GPG is enabled, check the package was found.
if [ "$gpg_enabled" == "true" ]; then
  if [ -z "$gpg_cmd" ]; then
    quit "GPG package not found, install gpg or set gpg_enabled to false."
  fi
fi

# If s3 upload is enabled, check for s3cmd package.
if [ "$aws_enabled" = "true" ]; then
  if [ -z "$aws_cmd" ]; then
    quit "AWSCli package not found, install awscli or set aws_enabled to false."
  fi
fi

# Create backup dir if it does not exist.
if [ ! -d "$backup_dir" ]; then
  mkdir -p "$backup_dir"
  if [ $? -ne 0 ]; then
    quit "Failed to create backup directory ${backup_dir}.";
  fi
fi

# Build AWS cli options (profile).
aws_args="--profile $aws_profile"
# Ensure the S3 bucket exists and we have access to it, or attempt to create.
# If AWS is disabled, we force set the backup directory removal flag to false.
if [ "$aws_enabled" == "true" ]; then
  echo "[Checks]"
  # Check if bucket exists, if not create it
  printf "AWS bucket '${aws_bucket}' accessible ... "
  aws_bucket_check=$("$aws_cmd" s3 ls "s3://${aws_bucket}" ${aws_args} 2>&1)
  if [ $? -eq 0 ]; then
    message "success" # Bucket exists
  elif [[ "$aws_bucket_check" == *NoSuchBucket* ]]; then
    message "warn" "No such bucket"
    printf "Creating AWS S3 bucket ... "
    $aws_cmd s3 mb "s3://${aws_bucket}" ${aws_args} >/dev/null 2>&1
    success_or_quit
  else
    quit "Failed to check bucket."
  fi
else
  backup_dir_remove=false
fi

# Build mysql args list based on the defined config options (defaults file or
# user and password combination).
mysql_args_array=();
if [ "$mysql_use_defaults_file" == "true" ]; then
  if [ ! -z "$mysql_defaults_file" ]; then
    mysql_args_array+=("--defaults-file=${mysql_defaults_file}")
  fi
else
  if [ "$mysql_user" != "" ]; then
    mysql_args_array+=("--user=${mysql_user}")
  fi
  if [ "$mysql_password" != "" ]; then
    mysql_args_array+=("--password=${mysql_password}")
  fi
  if [ "$mysql_host" != "" ]; then
    mysql_args_array+=("--host=${mysql_host}")
  fi
fi

# Join the MySQL args by single space.
mysql_args="${mysql_args_array[@]}"

echo "[Start MySQL Export]"

# If the slave flag is set, check if it is currently running and stop it,
# setting the restart flag to ensure we start it up again upon completion.
if [ "$mysql_slave" == "true" ]; then
  mysql_slave_restart=false
  slave_mysql=$("$mysql_cmd" ${mysql_args} -e "SHOW SLAVE STATUS \G")
  slave_io=$(echo "$slave_mysql" | grep 'Slave_IO_Running:' | awk '{print $2}')
  slave_sql=$(echo "$slave_mysql" | grep 'Slave_SQL_Running:' | awk '{print $2}')
  printf "Stop slave ... "
  if [ "Yes" == "$slave_io" ] || [ "Yes" == "$slave_sql" ]; then
    "$mysqladmin_cmd" ${mysql_args} stop-slave >/dev/null
    success_or_error
    mysql_slave_restart=true
  else
    message "warn" "Skipped"
  fi
fi

# Fetch list of database names, excluding those we do not want to export.
printf "Generating database list ... "
databases=($("$mysql_cmd" ${mysql_args} --batch --skip-column-names -e 'SHOW DATABASES;' | grep -Ev "^(${mysql_exclude})$"))
success_or_quit "Failed to export databases"

# Check we have some databases to export, otherwise stop here.
database_count=${#databases[@]}
if [ "$database_count" -eq 0 ]; then
  quit "No databases to export"
fi

# Print out number of databases and output destination.
printf "Exporting ${database_count} database";
if [ $database_count -ne 1 ]; then printf "s"; fi;
echo " to ${backup_dir}/<db>.sql.gz"

# If GPG is enabled, build the GPG args based on the config options.
if [ "$gpg_enabled" == true ]; then
  if [ -z "$gpg_recipient" ]; then
    quit "'gpg_recipient' must be set if GPG is enabled."
  fi
  gpg_command="${gpg_cmd} ${gpg_args} --recipient ${gpg_recipient}"
  if [ -z "$gpg_sign" ]; then
    gpg_command+=" --sign"
    if [ -z "$gpg_signer" ]; then
      gpg_command+=" --default-key $gpg_signer"
    fi
  fi
fi

# Build the mysqldump command with all flags and output.
mysql_export_cmd="${mysqldump_cmd} ${mysql_args} ${mysqldump_args} --databases %s"
if [ "$compress_cmd" ]; then
  mysql_export_cmd+=" | ${compress_cmd}"
fi
if [ "$gpg_enabled" == "true" ]; then
  mysql_export_cmd+=" | ${gpg_command} --output ${backup_dir}/%s${file_extension}.gpg"
else
  mysql_export_cmd+=" > ${backup_dir}/%s${file_extension}"
fi

# Loop through and create compressed backup files for each database.
for db in "${databases[@]}"; do
  printf "┕ "
  printf "%-30s" "$db" | tr ' ' .
  printf -v export_cmd "$mysql_export_cmd" "$db" "$db"
  printf " "
  eval "$export_cmd 2>&1"
  success_or_quit
done

# Upload all files in backup directory to S3.
if [ "$aws_enabled" == "true" ]; then
  echo "[Start AWS S3 upload]"
  printf "Uploading ${backup_dir} ... "
  $aws_cmd s3 cp "$backup_dir" "s3://${aws_bucket}/${aws_dir}" ${aws_args} --recursive >/dev/null 2>&1
  success_or_error
fi

# Perform cleanup script now all processing is complete.
cleanup
