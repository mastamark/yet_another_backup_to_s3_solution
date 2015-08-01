#!/usr/bin/env ruby

# Yet Another Backup to S3 Solution - ya_configure_backup.rb 

# Configures backups to ya_backup config yaml file and writes out cron file based on arguments passed when we invoke this script
# Example use: ./ya_configure_backups.rb yet-another-server-mail-config mail_config 7 daily /etc/mail,/some/file.php

require 'rubygems'
require 'fileutils'
require 'yaml'
require 'tempfile'

# Populate from arguments 
s3_bucket = ARGV[0] 
s3_prefix = ARGV[1]
max_backups = ARGV[2]
frequency = ARGV[3]
files_to_backup = ARGV[4].split(',')

# Make sure we passed needed arguments 
if s3_bucket.nil? 
  puts "Needed arguments seem to be missing.  Invoke backup script and pass along: s3_bucket_name s3_backupfile_prefix max_backups frequency /files/to/,/backup.sh" 
  puts "Example: ./ya_backup.rb yet-another-server-mail-config mail_config 7 daily /etc/mail,/some/other/mail/file.cf"
  exit 1
end 

# Probably needlessly complex sanity checks and other normalizing stuff
max_backups = max_backups.to_i
if max_backups == 0
  puts "maximum backups value is not valid!"
  exit 1
end

case frequency
  when "hourly"
    puts "Configuring for hourly backups"
  when "daily"
    puts "Configuring for daily backups"
  when "weekly"
    puts "Configuring for weekly backups"
  when "monthly"
    puts "Configuring for monthly backups"
  else
    puts "Unknown backup frequency!  Please choose 'hourly','daily','weekly' or 'monthly'"
    exit 1
end


# define some constants 
BACKUP_CONTROL_FILE = "/etc/ya_back_me_up.yml"
BACKUP_CRON_SKEL_FILE = "/root/ya_backup_cron_skel"
target_cronfile="/etc/cron.#{frequency}/#{s3_prefix}_backup"

#
# Main exection - Part 1: Read in hash from yaml and append 
#

puts "Reading in config file hash and adding out our new backup values"
# Read in yaml config file, verify the contents look valid, and then add new backup hash values and write out.
if File.exists?(BACKUP_CONTROL_FILE)
  backup_config_hash = YAML.load(File.open(BACKUP_CONTROL_FILE))
    if ! backup_config_hash.is_a?(Hash)
      puts "Config file found at #{BACKUP_CONTROL_FILE} does not appear to be formatted correctly!"
      exit(1)
    end
  puts "Found existing backup control file.  Successfully read in values for modification!"
else
  # No file, this is a problem!
  puts "No existing backup control file found!  Something isn't right!"
  exit(1)
end

# add our new backup config values to hash
backup_config_hash[s3_prefix] = {"maxbackups" => [max_backups], "files" => files_to_backup}

# Write out new hash back to yaml file
File.open(BACKUP_CONTROL_FILE, "w") do |f|
  f << backup_config_hash.to_yaml
end
FileUtils.chmod 0700, BACKUP_CONTROL_FILE, :verbose => true
puts "Backup config files successfully written to control file"

#
# Main execution - Part 2: Write out backup cron entry to appropriate location
#

# Copy and transform cron backup skel from attachment to /etc/ locations
puts "Reading in backup cron skel from attachment and transforming in tempfile"
path = "/tmp/cronconfig"
temp_file = Tempfile.new('cronconfig')
File.open(BACKUP_CRON_SKEL_FILE, "r") do |f|
  f.each_line do |line| 
    line.gsub!(/@@CONFIG_BUCKET@@/, s3_bucket)
    line.gsub!(/@@CONFIG_PREFIX@@/, s3_prefix) 
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
