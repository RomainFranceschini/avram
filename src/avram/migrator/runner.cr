require "db"
require "pg"
require "colorize"

class Avram::Migrator::Runner
  MIGRATIONS_TABLE_NAME = "migrations"

  extend LuckyCli::TextHelpers

  @@migrations = [] of Avram::Migrator::Migration::V1.class

  def initialize(@quiet : Bool = false)
  end

  def self.db_name
    (URI.parse(database_url).path || "")[1..-1]
  end

  def self.db_host
    host = URI.parse(database_url).host
    host unless host.blank?
  end

  def self.db_port
    URI.parse(database_url).port
  end

  def self.db_user
    URI.parse(database_url).user
  end

  def self.db_password
    URI.parse(database_url).password
  end

  def self.migrations
    @@migrations
  end

  def self.database_url
    Avram.settings.database_to_migrate.url
  end

  def self.cmd_args
    String.build do |args|
      args << "-U #{self.db_user}" if self.db_user
      args << " -h #{self.db_host}" if self.db_host
      args << " -p #{self.db_port}" if self.db_port
      args << " #{self.db_name}"
    end
  end

  def self.drop_db
    run "dropdb #{cmd_args}"
  rescue e : Exception
    if (message = e.message) && message.includes?(%("#{self.db_name}" does not exist))
      puts "Already dropped #{self.db_name.colorize(:green)}"
    else
      raise e
    end
  end

  def self.create_db(quiet? : Bool = false)
    run "createdb #{cmd_args}"
    unless quiet?
      puts "Done creating #{Avram::Migrator::Runner.db_name.colorize(:green)}"
    end
  rescue e : Exception
    if (message = e.message) && message.includes?(%("#{self.db_name}" already exists))
      unless quiet?
        puts "Already created #{self.db_name.colorize(:green)}"
      end
    elsif (message = e.message) && (message.includes?("createdb: not found") || message.includes?("No command 'createdb' found"))
      raise <<-ERROR
      #{message}

      Try this...

        ▸ If you are on macOS  you can install postgres tools from #{macos_postgres_tools_link}
        ▸ If you are on linux you can try running #{linux_postgres_installation_instructions}
        ▸ If you are on CI or some servers, there may already be a database created so you don't need this command"

      ERROR
    elsif (message = e.message) && message.includes?("could not connect to database template")
      raise <<-ERROR
      Creating the database failed. It looks like Postgres is not running.

      Message from Postgres:

        #{message}

      Try this...

        ▸ Make sure Postgres is running

      ERROR
    else
      raise e
    end
  end

  def self.restore_db(restore_file : String, quiet : Bool = false)
    if File.exists?(restore_file)
      run "psql -q #{cmd_args} -v ON_ERROR_STOP=1 < #{restore_file}"
      unless quiet
        puts "Done restoring #{db_name.colorize(:green)}"
      end
    else
      raise "Unable to locate the restore file: #{restore_file}"
    end
  end

  def self.dump_db(dump_to : String = "db/structure.sql", quiet : Bool = false)
    Db::VerifyConnection.new(quiet: true).call
    run "pg_dump -s #{cmd_args} > #{dump_to}"
    unless quiet
      puts "Done dumping #{db_name.colorize(:green)}"
    end
  end

  def self.setup_migration_tracking_tables
    DB.open(database_url) do |db|
      db.exec create_table_for_tracking_migrations
    end
  end

  private def self.create_table_for_tracking_migrations
    <<-SQL
    CREATE TABLE IF NOT EXISTS #{MIGRATIONS_TABLE_NAME} (
      id serial PRIMARY KEY,
      version bigint NOT NULL
    )
    SQL
  end

  private def self.macos_postgres_tools_link
    "https://postgresapp.com/documentation/cli-tools.html".colorize(:green)
  end

  private def self.linux_postgres_installation_instructions
    "sudo apt-get update && sudo apt-get install postgresql postgresql-contrib".colorize(:green)
  end

  def self.run(command : String)
    error_messages = IO::Memory.new
    ENV["PGPASSWORD"] = self.db_password if self.db_password
    result = Process.run command,
      shell: true,
      output: STDOUT,
      error: error_messages
    ENV.delete("PGPASSWORD") if self.db_password
    unless result.success?
      raise error_messages.to_s
    end
  end

  def run_pending_migrations
    prepare_for_migration do
      pending_migrations.each &.new.up(@quiet)
    end
  end

  def run_next_migration
    prepare_for_migration do
      pending_migrations.first.new.up
    end
  end

  def rollback_all
    self.class.setup_migration_tracking_tables
    migrated_migrations.reverse.each &.new.down
  end

  def rollback_one
    self.class.setup_migration_tracking_tables
    if migrated_migrations.empty?
      puts "Did not roll anything back because the database has no migrations.".colorize(:green)
    else
      migrated_migrations.last.new.down
    end
  end

  def rollback_to(last_version : Int64)
    self.class.setup_migration_tracking_tables
    subset = migrated_migrations.select do |mm|
      mm.new.version.to_i64 > last_version
    end
    subset.reverse.each &.new.down
    puts "Done rolling back to #{last_version}".colorize(:green)
  end

  def ensure_migrated!
    if pending_migrations.any?
      raise "There are pending migrations. Please run lucky db.migrate"
    end
  end

  private def migrated_migrations
    @@migrations.select &.new.migrated?
  end

  private def pending_migrations
    @@migrations.select &.new.pending?
  end

  private def prepare_for_migration
    self.class.setup_migration_tracking_tables
    if pending_migrations.empty?
      unless @quiet
        puts "Did not migrate anything because there are no pending migrations.".colorize(:green)
      end
    else
      yield
    end
  rescue e : DB::ConnectionRefused
    raise "Unable to connect to the database. Please check your configuration.".colorize(:red).to_s
  rescue e : Exception
    raise "Unexpected error while running migrations: #{e.message}".colorize(:red).to_s
  end
end
