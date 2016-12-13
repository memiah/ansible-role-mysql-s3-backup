MySQL S3 Backup
===============

An Ansible Role that installs Amazon AWS Command Line Interface and
configures a bash script to upload individual MySQL database backups
to Amazon S3.

Requirements
------------

The role assumes you already have MySQL installed.

If enabling GPG, you will need to have created those credentials too.

It is recommended that you create a user with locked down permissions.
Below is a policy named `AmazonS3CreateReadWriteAccess-[bucket-name]`
that can be used to provide limited (create/list/put) access to the
bucket `[bucket-name]`.

    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [ "s3:CreateBucket", "s3:ListBucket" ],
                "Resource": [ "arn:aws:s3:::[bucket-name]" ]
            },
            {
                "Effect": "Allow",
                "Action": [ "s3:PutObject" ],
                "Resource": [ "arn:aws:s3:::[bucket-name]/*" ]
            }
        ]
    }

Additionally, you may wish to consider bucket versioing and lifecycles
within S3.

Role Variables
--------------

Available variables are listed below, along with default values (see 
`defaults/main.yml`):

    mysql_backup_name: "mysql-s3-backup"
    
Name used to identify this role, used for default directory, file and aws profile naming.

    mysql_backup_dir: "/opt/{{ mysql_backup_name }}"

Directory where the backup script and config will be stored.

    mysql_backup_cronfile: "{{ mysql_backup_name }}"
    mysql_backup_cron_enabled: true
    mysql_backup_cron_hour: 23
    mysql_backup_cron_minute: 0
    mysql_backup_cron_email: false

Cron is enabled and set to run at at 23:00 every day and not emailed to
a recipient. If you want the output emailed, set this to the recipient
email address.

    mysql_backup_aws_profile: "{{ mysql_backup_name }}"

For separation we create a new AWS profile for this script context, you
could set this to `"default"` to ignore profiles.

    mysql_backup_aws_access_key: "[accesss-key]"
    
Your Amazon AWS access key.

    mysql_backup_aws_secret_key: "[secret-key]"
    
Your Amazon AWS secret key.

    mysql_backup_aws_region: eu-west-1
    
Region name where the S3 bucket is located.

    mysql_backup_aws_format: text

Output format from the AWS CLI.

    mysql_backup_gpg_secret_key: False

GPG secret key that the backups are encrypted for.

    mysql_backup_gpg_secret_dest: "~/{{ mysql_backup_name }}-gpg.asc"

Location used to store the GPG secret key.

    mysql_backup_system_user: root

User that will own and run the backup script as well as the cron job.

    mysql_backup_config: []

Customisations to the backup script itself (values use bash syntax).

* `timestamp: "$(date +"%Y-%m-%d_%H%M")"`
  Date and time used to create backup directories "YYYY-MM-DD_HHII".
* `backup_dir: "/tmp/mysql-s3-backups/${timestamp}"`
  Local backup directory path used to store files prior to upload.
* `backup_dir_remove: "true"`
  Remove local backup directory upon script completion.
* `aws_bucket: "mysql-s3-backups"`
  Default AWS S3 bucket name.
* `aws_dir: "$timestamp"`
  Default AWS directory to store backups.
* `aws_enabled: "true"`
  Enable upload to Amazon S3, if false the "backup_dir_remove" flag will be set to false.
* `aws_profile: "mysql-s3-backup"`
  Set the AWS profile to use (~/.aws/credentials and ~/.aws/config).
* `mysql_slave: "false"`
  Set to true if backing up from a MySQL slave server, this will stop the slave and start it again when the script is finished.
* `mysql_use_defaults_file: "true"`
  Use default MySQL config file.
* `mysql_defaults_file: ""`
  Specifically set the defaults file location, e.g. "/etc/my.cnf".
* `mysql_user: ""`, `mysql_password: ""`, `mysql_host: ""`
  If mysql_use_defaults_file is false, it will attempt to use these parameters to connect to MySQL.
* `mysql_exclude: "information_schema|performance_schema|mysql|sys"`
  List of databases to exclude from the export, this is a pipe separated list (RegEx).
* `mysqldump_args: "--triggers --routines --force --opt --add-drop-database"`
  Default flags used for database dump.
* `gpg_enabled: "false"`
  If true, backups will be encrypted with GPG and the suffix ".gpg" added to each of the backup files.
* `gpg_args: "--encrypt --batch --trust-model always"`
  Default flags used for GPG encryption.
* `gpg_recipient: ""`
  Recipient of the public-key encrypted files
* `gpg_sign: "false"`
  Flag to enforce signing of the backups.
* `gpg_signer: ""`
  Default GPG key to sign with.

Dependencies
------------

- [memiah.aws-cli](https://galaxy.ansible.com/memiah/aws-cli/)

Example Playbook
----------------

    - hosts: mysql-servers
      vars_files:
        - vars/main.yml
      roles:
         - memiah.mysql-s3-backup

*Inside `vars/main.yml`*:

    mysql_backup_aws_access_key: "access_key_here"
    mysql_backup_aws_secret_key: "secret_key_here"
    mysql_backup_aws_region: eu-west-1
    mysql_backup_config:
      aws_profile: "{{ mysql_backup_aws_profile }}"
      aws_bucket: "bucket_name_here"
      backup_dir: "{{ mysql_backup_dir }}/backups/${timestamp}"

License
-------

MIT / BSD

Author Information
------------------

This role was created in 2016 by [Memiah Limited](https://github.com/memiah).
