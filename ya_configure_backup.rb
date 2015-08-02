#!/usr/bin/env ruby

# Yet Another Backup to S3 Solution - ya_configure_backup.rb 

# Configures backups to ya_backup config yaml file and writes out cron file based on arguments passed when we invoke this script
# Example use: ./ya_configure_backups.rb --bucket yet-another-server-mail-config --backup-name mail_config --daily --max-backups 7 --files /etc/mail,/some/file.php

require 'rubygems'
require 'getoptlong'
require 'fileutils'
require 'yaml'
require 'tempfile'

# Define some constants and variables
s3_bucket = nil
s3_prefix = nil
frequency = nil
preflight = nil
postflight = nil
max_backups = 14
files_to_backup = []
encryption = ""
encrypt_for = ""
backup_control_file = "/etc/ya_back_me_up.yml"
ya_backup_path = "/root/ya_backup/ya_backup.rb"
backup_cron_skel_file = "/root/ya_backup/ya_backup_cron_skel"


begin
  opts = GetoptLong.new(
    [ '--bucket', '-b', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--backup-name', '-n', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--daily', GetoptLong::NO_ARGUMENT ],
    [ '--hourly', GetoptLong::NO_ARGUMENT ],
    [ '--weekly', GetoptLong::NO_ARGUMENT ],
    [ '--monthly', GetoptLong::NO_ARGUMENT ],
    [ '--preflight', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--postflight', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--max-backups', '-m', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--files', '-f', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--encrypt', '-e', GetoptLong::NO_ARGUMENT ],
    [ '--encrypt-for', '-u', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--control-file', '-c', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--skel-file', '-s', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--ya-backup-app-path', '-a', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--help', '-h', GetoptLong::NO_ARGUMENT ]
  )

  opts.each do |opt, arg|
    case opt
      when '--bucket', '-b'
        s3_bucket = arg
      when '--backup-name', '-n'
        s3_prefix = arg
      when '--max-backups', '-m'
        max_backups = arg
      when '--files', '-f'
        arg.split(',').each do |i|
          files_to_backup << i
        end
      when '--hourly'
        frequency = "hourly"
      when '--daily'
        frequency = "daily"
      when '--weekly'
        frequency = "weekly"
      when '--monthly'
        frequency = "monthly"
      when '--preflight'
        preflight = arg
      when '--postflight'
        postflight = arg
      when '--encrypt', '-e'
        encryption = "--encrypt"
      when '--encrypt-for', '-u'
        encrypt_for = "--encrypt-for " + arg
      when '--control-file', '-c'
        backup_control_file = arg
      when '--skel-file', '-s'
        backup_cron_skel_file = arg
      when '--ya-backup-app-path', '-a'
        ya_backup_path = arg
      when '--help', '-h'
        puts <<-EOF
ya_configure_backup.rb [OPTIONS]
Ex: ./ya_configure_backups.rb --bucket yet-another-server-mail-config --backup-name mail_config --daily --max-backups 7 --files /etc/mail,/some/file.conf --preflight /bin/backup_prep.sh


OPTIONS:
-b, --bucket [string]:
  The name of the bucket you want to upload to.  Required.
  
-n, --backup-name [string]:
  The name of the backup, used for both the prefix of the backup file itself as well as
  for finding the information for the backup in the control file. Required.
  
-m, --max-backups:
  The quantity of backups to store before we delete the oldest.  Optional, defaults to 14.
  
-f, --files [csv string]:
  A csv list of files with full paths to (recursively) backup. Required.
  Eg, /etc/some/folder,/some/file.inc,/yet/more/crap
  
--hourly, --daily, --weekly, --monthly:
  The period we want to be doing the backups.  Eg, "daily" backup.  Required.
  
--preflight, --postflight [string]:
  Have the backup execute an arbitrary script/command before or after the creation of
  the backup tarball.  Eg, "--preflight /bin/backup_prep.sh."  Optional.
  
-e, --encrypt:
  Toggles encryption via gpg of the tar file before uploading to s3.  Optional, although
  if provided you must also provide the '--encrypt-for' flag.
  
-u, --encrypt-for [string]:
  Used in conjunction with the '--encrypt' flag to provide the information from your gpg
  keychain to identify what user to encrypt the data for.  
  Eg, 'Mark' or 'some.guy@gmail.com.' Optional.
  
-c, --control-file [string]:
  Allows overriding of default location of backups control file and name.  Optional, 
  defaults to '/etc/ya_back_me_up.yml'    
  
-s, --skel-file [string]:
  Allows overriding of default location of cron skel file.  Optional, 
  defaults to '/root/ya_backup/ya_backup_cron_skel' 
  
-a, --ya-backup-app-path [string]:
  Allows overriding of default location of ya_backup.rb script.  Optional, 
  defaults to '/root/ya_backup/ya_backup.rb'
        EOF
        exit 0
    end
  end
  
rescue GetoptLong::InvalidOption => ex
  puts "Needed arguments seem to be incorrect.  Try --help."
end

# Sanity Checks for required flags and building cron file from options.
if s3_bucket.nil? || s3_prefix.nil? || frequency.nil? || files_to_backup.empty?
  raise "Needed arguments are missing.  Try --help."
end
max_backups = max_backups.to_i
if max_backups == 0
  puts "maximum backups value is not valid!"
  exit 1
end
target_cronfile="/etc/cron.#{frequency}/#{s3_prefix}_backup"

#
# Main exection - Part 1: Read in hash from yaml and append 
#

puts "Reading in config file hash and adding out our new backup values"
# Read in yaml config file, verify the contents look valid, and then add new backup hash values and write out.
if File.exists?(backup_control_file)
  backup_config_hash = YAML.load(File.open(backup_control_file))
    if ! backup_config_hash.is_a?(Hash)
      puts "Config file found at #{backup_control_file} does not appear to be formatted correctly!"
      exit(1)
    end
  puts "Found existing backup control file.  Successfully read in values for modification!"
else
  # No file, this is a problem!
  puts "No existing backup control file found!  Something isn't right!"
  exit(1)
end

# add our new backup config values to backup hash.
add_me = {"maxbackups" => [max_backups], "files" => files_to_backup}
add_me["preflight"] = preflight if preflight
add_me["postflight"] = postflight if postflight
backup_config_hash[s3_prefix] = add_me

# Write out new hash back to yaml file
File.open(backup_control_file, "w") do |f|
  f << backup_config_hash.to_yaml
end
FileUtils.chmod 0700, backup_control_file, :verbose => true
puts "Backup config files successfully written to control file"

#
# Main execution - Part 2: Write out backup cron entry to appropriate location
#

# Copy and transform cron backup skel from attachment to /etc/ locations
puts "Reading in backup cron skel from attachment and transforming in tempfile"
path = "/tmp/cronconfig"
temp_file = Tempfile.new('cronconfig')
File.open(backup_cron_skel_file, "r") do |f|
  f.each_line do |line| 
    line.gsub!(/@@CONFIG_BUCKET@@/, s3_bucket)
    line.gsub!(/@@CONFIG_PREFIX@@/, s3_prefix)
    line.gsub!(/@@YA_BACKUP_PATH@@/, ya_backup_path)
    line.gsub!(/@@ENCRYPTION@@/, encryption)
    line.gsub!(/@@ENCRYPTION_FOR@@/, encrypt_for)
    File.open(path, "w") do |file|
      temp_file.puts line
    end
  end
  temp_file.close
  puts "Moving tempfile into cron target #{target_cronfile}"
  FileUtils.mv(temp_file.path, target_cronfile, :verbose => true)
  FileUtils.rm(path, :verbose => true) 
end
FileUtils.chmod 0700, target_cronfile, :verbose => true

puts "Yet Another backup script installed successfully!"
