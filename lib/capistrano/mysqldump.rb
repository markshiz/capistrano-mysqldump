Capistrano::Configuration.instance.load do
  namespace :mysqldump do
    task :default, :roles => :db do
      dump
      import
    end
    
    task :setup do
      set :mysqldump_config, YAML.load_file("config/database.yml")[rails_env.to_s]    
      host = mysqldump_config["host"]

      # overwrite these if necessary
      set :mysqldump_bin, "/usr/local/mysql/bin/mysqldump" unless exists?(:mysqldump_bin)
      set :mysqldump_remote_tmp_dir, "/tmp" unless exists?(:mysqldump_remote_tmp_dir)
      set :mysqldump_local_tmp_dir, "/tmp" unless exists?(:mysqldump_local_tmp_dir)
      set :mysqldump_location, host == "localhost" ? :local : :remote unless exists?(:mysqldump_location)

      # for convenience
      set :mysqldump_filename, "%s.sql" % application
      set :mysqldump_filename_gz, "%s.gz" % mysqldump_filename
      set :mysqldump_remote_filename, File.join( mysqldump_remote_tmp_dir, mysqldump_filename )
      set :mysqldump_remote_filename_gz, File.join( mysqldump_remote_tmp_dir, mysqldump_filename_gz )
      set :mysqldump_local_filename, File.join( mysqldump_local_tmp_dir, mysqldump_filename )
      set :mysqldump_local_filename_gz, File.join( mysqldump_local_tmp_dir, mysqldump_filename_gz )
    end

    task :dump, :roles => :web do
      setup 
      username, password, database, host = mysqldump_config.values_at *%w( username password database host )

      mysqldump_cmd = "%s --quick --single-transaction" % mysqldump_bin
      mysqldump_cmd += " -h #{host}" if host
      
      case mysqldump_location
      when :remote
        mysqldump_cmd += " -u %s -p %s" % [ username, database ]
        mysqldump_cmd += " | gzip > %s" % mysqldump_remote_filename_gz

        run mysqldump_cmd do |ch, stream, out|
          ch.send_data "#{password}\n" if out =~ /^Enter password:/
        end

        download mysqldump_remote_filename_gz, mysqldump_local_filename_gz, :via => :scp
        run "rm #{mysqldump_remote_filename_gz}"
        
        `gunzip #{mysqldump_local_filename_gz}`
      when :local
        mysqldump_cmd += " -u %s" % username
        mysqldump_cmd += " -p#{password}" if password 
        mysqldump_cmd += " %s > %s" % [ database, mysqldump_local_filename]

        `#{mysqldump_cmd}`
      end
    end

    task :import, :roles => :web do
      setup 
      config = YAML.load_file("config/database.yml")[rails_env.to_s]
      username, password, database, host = config.values_at *%w( username password database host )
      puts "import to host: #{host}"
      set :mysql_location, host == "localhost" ? :local : :remote unless exists?(:mysql_location)

      mysql_cmd = "mysql -u#{username}"
      mysql_cmd += " -p#{password}" if password 
      mysql_cmd += " -h#{host} "

      case mysql_location
      when :remote
        `gzip #{mysqldump_local_filename}`
        upload mysqldump_local_filename_gz, mysqldump_remote_filename_gz, :via => :scp
        run "gunzip #{mysqldump_remote_filename_gz}"
        run "#{mysql_cmd} #{database} < #{mysqldump_remote_filename}" do |ch, stream, out|
          ch.send_data "#{password}\n" if out =~ /^Enter password:/
        end
        run "rm #{mysqldump_remote_filename}"
        `rm #{mysqldump_local_filename_gz}`
      when :local
        `#{mysql_cmd} -e "drop database #{database}; create database #{database}"`
        `#{mysql_cmd} #{database} < #{mysqldump_local_filename}`
        `rm #{mysqldump_local_filename}`
      end

    end
  end
end
