#!/usr/bin/env ruby

########
# 'Yet Another Backup to S3 Solution' - ya_backup.rb - github.com/mastamark 
#
# Uses combination of arguments passed when we start the script (bucket names and prefix)
# in addition to reading in 'backup control file' as yaml to figure out how many backups we
# store and what files we are backing up for that specific backup type.
#
# Default is creation of gzip tarball.  Also supports creation of gpg encrypted tarball.
#
# Currently using ruby-s3cmd gem to passthrough to local config of s3cmd for all s3 operations
#
# Example evocation: 
# => .tar.gz file: ./ya_backup.rb --bucket yet-another-server-mail-config --backup-name mail_config
# => .tar.gpg file: ./ya_backup.rb --bucket yet-another-server-mail-config --backup-name mail_config --encrypt --encrypt-for mark@someplace.com
########

require 'rubygems'
require 'getoptlong'
require 'fileutils'
require 'yaml'
require 'ruby-s3cmd'

# Define some constants and variables
config_bucket = nil
config_prefix = nil
@encryption = FALSE
@encrypt_for = nil
backup_control_file = "/etc/ya_back_me_up.yml"
HOME="/root"
BACKUPFILE_DATE=`date +%Y%m%d%H%M`.strip

begin
  opts = GetoptLong.new(
    [ '--bucket', '-b', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--backup-name', '-n', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--encrypt', '-e', GetoptLong::NO_ARGUMENT ],
    [ '--encrypt-for', '-u', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--control-file', '-c', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--help', '-h', GetoptLong::NO_ARGUMENT ]
  )

  opts.each do |opt, arg|
    case opt
      when '--bucket', '-b'
        config_bucket = arg
      when '--backup-name', '-n'
        config_prefix = arg
      when '--encrypt', '-e'
        @encryption = TRUE
      when '--encrypt-for', '-u'
        @encrypt_for = arg
      when '--control-file', '-c'
        backup_control_file = arg
      when '--help', '-h'
        puts <<-EOF
ya_backup [OPTIONS]
Ex1: ./ya_backup.rb --bucket yet-another-server-mail-config --backup-name mail_config
Ex2: ./ya_backup.rb --bucket yet-another-server-mail-config --backup-name mail_config --encrypt --encrypt-for mark@someplace.com

OPTIONS:
-b, --bucket [string]:
  The name of the bucket you want to upload to.  Required.
  
-n, --backup-name [string]:
  The name of the backup, used for both the prefix of the backup file itself as well as
  for finding the information for the backup in the control file. Required.
  
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
        EOF
        exit 0
    end
  end
  
rescue GetoptLong::InvalidOption => ex
  puts "Needed arguments seem to be incorrect.  Try --help."
end

# Sanity Checks for required flags and build our backup file name from options.
if config_bucket.nil? || config_prefix.nil?
  raise "Needed arguments --bucket and --backup-name are missing.  Try --help."
end
if @encryption
  if @encrypt_for.nil?
    raise "--encrypt-for must be used with --encrypt flags"
  else
    backupfilename = config_prefix + "-" + BACKUPFILE_DATE + ".tar.gpg"
  end
else
  backupfilename = config_prefix + "-" + BACKUPFILE_DATE + ".tar.gz"
end

BACKUPTMPDIR = "/tmp/#{config_prefix}_backup_temp_" + BACKUPFILE_DATE
SUCCESSTOUCHFILE = "/var/run/#{config_prefix}_backup"

def backup_file_sanity_check(backup_control_file,config_prefix)
  #
  # Load backup_items file yaml which contains details on what to backup and at what frequency based on key of service type we are backing up
  #

  # Sanity checks for the backup control file
  if File.exists?(backup_control_file)
    backup_config_hash = YAML.load(File.open(backup_control_file))
    if ! backup_config_hash.is_a?(Hash)
      raise "Config file found at #{backup_control_file} does not appear to be formatted correctly!"
    end
    if backup_config_hash[config_prefix]
      return backup_config_hash
    else
      raise "#{backup_control_file} does not appear to contain any backup info for #{config_prefix}!"
    end
  else
    raise "Error!  Backup file #{backup_control_file} not found!  Don't know what to do!"
  end
end

def get_s3_contents(config_bucket,config_prefix)
  # Make a connection to S3 and verify results appear to be sane (creds read from ~root/.s3cfg
  @s3cmd = RubyS3Cmd::S3Cmd.new 
  @s3cmd.verbose
  # the s3cmd 'ls' command on a 403 from s3 still returns true/0 so we use a random other option to verify bucket access
  valid_bucket_access = @s3cmd.setacl "s3://#{config_bucket}"
  if ! valid_bucket_access
    raise "Error connecting to bucket: 's3://#{config_bucket}'.  Check bucket name or aws creds!"
  end
  s3_query = "s3://#{config_bucket}/#{config_prefix}"
  s3_result = @s3cmd.ls s3_query

  # sanity checking for results:
  # * overall results should be an array, even if empty in the case of a new backup lineage
  # * extracting out tarball dates from first and last values of array should give us
  #   valid 'oldest' and 'newest' file dates so we can delete the right file

  if s3_result.is_a?(Array)
    if s3_result.length.to_i <= 1
      puts "Unable to locate at least 2 previous backups for #{s3_query}.  Assuming newer backup lineage!"
      return s3_result
    else
      oldest_date = s3_result.first.split.last.split('-').last.split('.').first
      newest_date = s3_result.last.split.last.split('-').last.split('.').first
      if oldest_date > newest_date
        raise "Sanity Checking failed!  It appears that our 'oldest' date: #{oldest_date} is newer then our 'newest' date: #{newest_date}"        
      end
      return s3_result
    end
  else
    raise "Overall results from s3cmd do not seem to be an array!  Exiting!"
  end
end

def create_backup(backup_config_hash,config_prefix,backuptmpdir,backupfilename)
  # Define files to backup and frequency from config hash
  files_to_backup = backup_config_hash[config_prefix]["files"]

  # Create our new directory to copy files to, compress, and then upload
  FileUtils.mkdir backuptmpdir
  files_to_backup.each do |item|
    #FileUtils.cp_r apparently has a known problem copying symlinks before the directory exists if preserving perms.
    #Rather then write fancy logic to detect if its a symlink and circle back I choose to be lazy
    #and go with a backtick execution.
    #FileUtils.cp_r item, backuptmpdir, :verbose => true, :preserve => true
    `cp -rvp #{item} #{backuptmpdir}`
  end
  FileUtils.cd backuptmpdir
  # use system commands to execute backup because I'm lazy
  if @encryption
    `gpg-zip --encrypt --output #{backupfilename} -r #{@encrypt_for} ./`
  else
    `tar -czf #{backupfilename} ./`
  end
  if ! File.exists?(backupfilename)
    raise "Backup creation appears to have failed!  Can't find #{backupfilename}"
  else
    puts "Backup #{backupfilename} created successfully!"
    return true
  end
end

def upload_to_s3(backupfilename,backuptmpdir,config_bucket)
  # Upload to s3
  @s3cmd.put backupfilename, "s3://#{config_bucket}/#{backupfilename}"
  returncode = $?
  if returncode.to_i != 0
    puts "Error during upload to s3://#{config_bucket}/#{backupfilename}!  Return code was #{returncode} from s3 upload attempt!"
    puts "Leaving local files in #{backuptmpdir}.  Clean up manually!"
    raise returncode
  else
    puts "Upload appears successful to s3://#{config_bucket}/#{backupfilename}!  Cleaning up local scratch files."
    FileUtils.rm_r backuptmpdir, :verbose => true, :force => true
    FileUtils.cd('/tmp')
    return true
  end
end

def delete_oldest_backup(s3_result,backup_config_hash,config_prefix)
  max_backups = backup_config_hash[config_prefix]["maxbackups"].first.to_i
  # delete the oldest occurrence as cleanup
  if s3_result.count > max_backups.to_i
  kill_filename = s3_result.first.split.last
  puts "Deleting oldest backup: #{kill_filename}"
  @s3cmd.del kill_filename
  else
    puts "Located #{s3_result.count} backups.  Does not yet exceed max quantity of #{max_backups}.  Not deleting old backups."
    return true
  end
  return true
end

# Main execution

puts "####### Backup started #######"
backup_config_hash = backup_file_sanity_check(backup_control_file,config_prefix)
s3_result = get_s3_contents(config_bucket,config_prefix)
create_backup(backup_config_hash,config_prefix,BACKUPTMPDIR,backupfilename)
upload_to_s3(backupfilename,BACKUPTMPDIR,config_bucket)
delete_oldest_backup(s3_result,backup_config_hash,config_prefix) unless s3_result.nil?
# assuming we've gotten here, touch a file so we can alert on missed backups
`touch #{SUCCESSTOUCHFILE}`
puts "####### Backup complete #######"