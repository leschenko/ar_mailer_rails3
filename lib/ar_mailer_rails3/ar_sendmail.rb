require 'optparse'
require 'yaml'
require 'net/smtp'
require 'smtp_tls' unless Net::SMTP.instance_methods.include?('enable_starttls_auto')

##
# Hack in RSET

module Net # :nodoc:
  class SMTP # :nodoc:

    unless instance_methods.include? 'reset' then
      ##
      # Resets the SMTP connection.

      def reset
        getok 'RSET'
      end
    end

  end
end

##
# ActionMailer::ARSendmail delivers email from the email table to the
# SMTP server configured in your application's config/environment.rb.
# ar_sendmail does not work with sendmail delivery.
#
# ar_mailer can deliver to SMTP with TLS using smtp_tls.rb borrowed from Kyle
# Maxwell's action_mailer_optional_tls plugin.  Simply set the :tls option in
# ActionMailer::Base's smtp_settings to true to enable TLS.
#
# See ar_sendmail -h for the full list of supported options.
#
# The interesting options are:
# * --daemon
# * --mailq

module ArMailerRails3
  class ARSendmail

    ##
    # The version of ActionMailer::ARSendmail you are running.

    VERSION = '2.1.8'

    ##
    # Maximum number of times authentication will be consecutively retried

    MAX_AUTH_FAILURES = 2

    ##
    # Email delivery attempts per run

    attr_accessor :batch_size

    ##
    # Seconds to delay between runs

    attr_accessor :delay

    ##
    # Maximum age of emails in seconds before they are removed from the queue.

    attr_accessor :max_age

    ##
    # Be verbose

    attr_accessor :verbose


    ##
    # True if only one delivery attempt will be made per call to run

    attr_reader :once

    ##
    # Times authentication has failed

    attr_accessor :failed_auth_count

    attr_accessor :quota, :period, :quota_filename, :emails_count, :start_period, :domains, :current_domain, :smtp_config

    @@pid_file = nil

    def self.remove_pid_file
      if @@pid_file
        require 'shell'
        sh = Shell.new
        sh.rm @@pid_file
      end
    end

    ##
    # Get email class

    def self.email_class
      ActionMailer::Base.active_record_settings[:email_class]
    end

    ##
    # Prints a list of unsent emails and the last delivery attempt, if any.
    #
    # If ActiveRecord::Timestamp is not being used the arrival time will not be
    # known.  See http://api.rubyonrails.org/classes/ActiveRecord/Timestamp.html
    # to learn how to enable ActiveRecord::Timestamp.

    def self.mailq
      emails = self.email_class.find :all

      if emails.empty? then
        puts 'Mail queue is empty'
        return
      end

      total_size = 0

      puts '-Queue ID- --Size-- ----Arrival Time---- -Sender/Recipient-------'
      emails.each do |email|
        size = email.mail.length
        total_size += size

        create_timestamp = email.created_on rescue
            email.created_at rescue
                Time.at(email.created_date) rescue # for Robot Co-op
                    nil

        created = if create_timestamp.nil? then
                    '             Unknown'
                  else
                    create_timestamp.strftime '%a %b %d %H:%M:%S'
                  end

        puts '%10d %8d %s  %s' % [email.id, size, created, email.from]
        if email.last_send_attempt > 0 then
          puts "Last send attempt: #{Time.at email.last_send_attempt}"
        end
        puts "                                         #{email.to}"
        puts
      end

      puts "-- #{total_size/1024} Kbytes in #{emails.length} Requests."
    end

    ##
    # Processes command line options in +args+

    def self.process_args(args)
      name = File.basename $0

      options = {}
      options[:Chdir] = '.'
      options[:Daemon] = false
      options[:Delay] = 60
      options[:MaxAge] = 86400 * 7
      options[:Once] = false
      options[:RailsEnv] = ENV['RAILS_ENV']
      options[:Pidfile] = options[:Chdir] + '/log/ar_sendmail.pid'

      opts = OptionParser.new do |opts|
        opts.banner = "Usage: #{name} [options]"
        opts.separator ''

        opts.separator "#{name} scans the email table for new messages and sends them to the"
        opts.separator "website's configured SMTP host."
        opts.separator ''
        opts.separator "#{name} must be run from a Rails application's root."

        opts.separator ''
        opts.separator 'Sendmail options:'

        opts.on('-b', '--batch-size BATCH_SIZE',
                'Maximum number of emails to send per delay',
                'Default: Deliver all available emails', Integer) do |batch_size|
          options[:BatchSize] = batch_size
        end

        opts.on('--delay DELAY',
                'Delay between checks for new mail',
                'in the database',
                "Default: #{options[:Delay]}", Integer) do |delay|
          options[:Delay] = delay
        end

        opts.on('-q', '--quota QUOTA', Integer,
                'Quota of emails per period') do |quota|
          options[:Quota] = quota
        end

        opts.on('-r', '--period PERIOD', Integer,
                'Period for quota in seconds',
                'Default: 1 day') do |period|
          options[:Period] = period
        end

        opts.on('-s', '--smtp_config_path CONFIG_PATH', String,
                'Smtp config file path') do |path|
          options[:smtp_config_path] = path
        end

        opts.on('--max-age MAX_AGE',
                'Maxmimum age for an email. After this',
                'it will be removed from the queue.',
                'Set to 0 to disable queue cleanup.',
                "Default: #{options[:MaxAge]} seconds", Integer) do |max_age|
          options[:MaxAge] = max_age
        end

        opts.on('-o', '--once',
                'Only check for new mail and deliver once',
                "Default: #{options[:Once]}") do |once|
          options[:Once] = once
        end

        opts.on('-d', '--daemonize',
                'Run as a daemon process',
                "Default: #{options[:Daemon]}") do |daemon|
          options[:Daemon] = true
        end

        opts.on('-p', '--pidfile PIDFILE',
                'Set the pidfile location',
                "Default: #{options[:Chdir]}#{options[:Pidfile]}", String) do |pidfile|
          options[:Pidfile] = pidfile
        end

        opts.on('--mailq',
                'Display a list of emails waiting to be sent') do |mailq|
          options[:MailQ] = true
        end

        opts.separator ''
        opts.separator 'Setup Options:'

        opts.separator ''
        opts.separator 'Generic Options:'

        opts.on('-c', '--chdir PATH',
                'Use PATH for the application path',
                "Default: #{options[:Chdir]}") do |path|
          usage opts, "#{path} is not a directory" unless File.directory? path
          usage opts, "#{path} is not readable" unless File.readable? path
          options[:Chdir] = path
        end

        opts.on('-e', '--environment RAILS_ENV',
                'Set the RAILS_ENV constant',
                "Default: #{options[:RailsEnv]}") do |env|
          options[:RailsEnv] = env
        end

        opts.on('-v', '--[no-]verbose',
                'Be verbose',
                "Default: #{options[:Verbose]}") do |verbose|
          options[:Verbose] = verbose
        end

        opts.on('-h', '--help',
                "You're looking at it") do
          usage opts
        end

        opts.on('--version', 'Version of ARMailer') do
          usage "ar_mailer #{VERSION} (adzap fork)"
        end

        opts.separator ''
      end

      opts.parse! args

      ENV['RAILS_ENV'] = options[:RailsEnv]

      Dir.chdir options[:Chdir] do
        begin
          break if name == 'rspec'
          require Dir.pwd + '/config/environment'
          require 'ar_mailer_rails3/active_record'
        rescue LoadError
          usage opts, <<-EOF
#{name} must be run from a Rails application's root to deliver email.
#{Dir.pwd} does not appear to be a Rails application root.
          EOF
        end
      end

      options
    end

    ##
    # Processes +args+ and runs as appropriate

    def self.run(args = ARGV)
      options = process_args args

      if options.include? :MailQ then
        mailq
        exit
      end

      if options[:Daemon] then
        require 'webrick/server'
        @@pid_file = File.expand_path(options[:Pidfile], options[:Chdir])
        if File.exists? @@pid_file
          # check to see if process is actually running
          pid = ''
          File.open(@@pid_file, 'r') { |f| pid = f.read.chomp }
          if system("ps -p #{pid} | grep #{pid}") # returns true if process is running, o.w. false
            $stderr.puts "Warning: The pid file #{@@pid_file} exists and ar_sendmail is running. Shutting down."
            exit -1
          else
            # not running, so remove existing pid file and continue
            self.remove_pid_file
            $stderr.puts 'ar_sendmail is not running. Removing existing pid file and starting up...'
          end
        end
        WEBrick::Daemon.start
        File.open(@@pid_file, 'w') { |f| f.write("#{Process.pid}\n") }
      end

      new(options).run

    rescue SystemExit
      raise
    rescue SignalException
      exit
    rescue Exception => e
      $stderr.puts "Unhandled exception #{e.message}(#{e.class}):"
      $stderr.puts "\t#{e.backtrace.join "\n\t"}"
      exit -2
    end

    ##
    # Prints a usage message to $stderr using +opts+ and exits

    def self.usage(opts, message = nil)
      if message then
        $stderr.puts message
        $stderr.puts
      end

      $stderr.puts opts
      exit 1
    end

    ##
    # Creates a new ARSendmail.
    #
    # Valid options are:
    # <tt>:BatchSize</tt>:: Maximum number of emails to send per delay
    # <tt>:Delay</tt>:: Delay between deliver attempts
    # <tt>:Once</tt>:: Only attempt to deliver emails once when run is called
    # <tt>:Verbose</tt>:: Be verbose.

    def initialize(options = {})
      options[:Delay] ||= 60
      options[:MaxAge] ||= 86400 * 7

      @batch_size = options[:BatchSize]
      @delay = options[:Delay]
      @once = options[:Once]
      @verbose = options[:Verbose]
      @max_age = options[:MaxAge]
      
      if options[:smtp_config_path]
        @smtp_config = YAML.load_file(options[:smtp_config_path]).each_with_object({}) { |(k, v), h| h[k] = v.symbolize_keys }
        @domains = @smtp_config.keys
        log "INIT DOMAINS #{@domains}"
      end

      @quota = options[:Quota]
      if @quota
        @period = options[:Period] || 86400
        @quota_filename = quota_filename
      end
      reset_emails_stat

      @failed_auth_count = 0
    end

    ##
    # Removes emails that have lived in the queue for too long.  If max_age is
    # set to 0, no emails will be removed.

    def cleanup
      return if @max_age == 0
      timeout = Time.now - @max_age
      conditions = ['last_send_attempt > 0 and created_on < ?', timeout]
      mail = self.class.email_class.destroy_all conditions

      log "expired #{mail.length} emails from the queue"
    end

    ##
    # Delivers +emails+ to ActionMailer's SMTP server and destroys them.

    def deliver(emails)
      # for dev testing
      if smtp_settings[:domain] == 'stub'
        emails.each do |email|
          log ['STUB EMAIL', email.id, email.from, email.to].join(' ')
          @emails_count += 1
          email.destroy
        end
        return
      end

      settings = [
          smtp_settings[:domain],
          (smtp_settings[:user] || smtp_settings[:user_name]),
          smtp_settings[:password],
          smtp_settings[:authentication]
      ]

      smtp = Net::SMTP.new(smtp_settings[:address], smtp_settings[:port])
      if smtp.respond_to?(:enable_starttls_auto)
        smtp.enable_starttls_auto unless smtp_settings[:tls] == false
      else
        settings << smtp_settings[:tls]
      end

      smtp.start(*settings) do |session|
        @failed_auth_count = 0
        until emails.empty? do
          email = emails.shift
          begin
            res = session.send_message email.mail, email.from, email.to
            @emails_count += 1
            email.destroy
            log 'sent email %011d from %s to %s: %p' %
                    [email.id, email.from, email.to, res]
          rescue Net::SMTPFatalError => e
            log "5xx error sending email %d from %s to %s, removing from queue: %p(%s):\n\t%s" %
                    [email.id, email.from, email.to, e.message, e.class, e.backtrace.join("\n\t")]
            email.destroy
            session.reset
          rescue Net::SMTPServerBusy => e
            log 'server too busy, stopping delivery cycle'
            return
          rescue Net::SMTPUnknownError, Net::SMTPSyntaxError, TimeoutError, Timeout::Error => e
            email.last_send_attempt = Time.now.to_i
            email.save rescue nil
            log "error sending email %d from %s to %s: %p(%s):\n\t%s" %
                    [email.id, email.from, email.to, e.message, e.class, e.backtrace.join("\n\t")]
            session.reset
          end
        end
      end
    rescue Net::SMTPAuthenticationError => e
      @failed_auth_count += 1
      if @failed_auth_count >= MAX_AUTH_FAILURES then
        log "authentication error, giving up: #{e.message}"
        raise e
      else
        log "authentication error, retrying: #{e.message}"
      end
      sleep delay
    rescue Net::SMTPServerBusy, SystemCallError, OpenSSL::SSL::SSLError
      # ignore SMTPServerBusy/EPIPE/ECONNRESET from Net::SMTP.start's ensure
    end

    ##
    # Prepares ar_sendmail for exiting

    def do_exit
      log 'caught signal, shutting down'
      self.class.remove_pid_file
      exit 130
    end

    ##
    # Returns emails in email_class that haven't had a delivery attempt in the
    # last 300 seconds.

    def find_emails
      emails = self.class.email_class.where('last_send_attempt < ?', Time.now.to_i - 300)
      emails = emails.where(domain: @current_domain) if @current_domain
      emails = emails.limit(batch_size) unless batch_size.nil?

      log "found #{emails.length} emails to send"
      emails
    end

    ##
    # Installs signal handlers to gracefully exit.

    def install_signal_handlers
      trap 'TERM' do
        do_exit
      end
      trap 'INT' do
        do_exit
      end
    end

    ##
    # Logs +message+ if verbose

    def log(message)
      msg = "[#{Time.now}] ar_sendmail: #{message}"
      $stderr.puts msg if @verbose
      Rails.logger.info msg if defined? Rails
    end

    ##
    # Scans for emails and delivers them every delay seconds.  Only returns if
    # once is true.
    def run
      install_signal_handlers

      loop do
        begin
          if exceed_quota?
            log "quota #{@quota} exceeded until #{Time.at(@start_period + @period)}"
          else
            cleanup
            if @domains
              @current_domain = @domains.first
              @domains.rotate!
            end
            emails = find_emails.first(available_quota)
            deliver(emails) unless emails.empty?
            store_emails_stat if @quota
          end
        rescue => e
          log "ERROR #{e.message} \n #{e.backtrace}"
          raise(e) unless defined? Rails
        end
        break if @once
        sleep @delay
      end
    end

    def exceed_quota?
      return false unless @quota
      fetch_emails_stat
      if @start_period + @period > Time.now.utc.to_i
        available_quota.zero?
      else
        reset_emails_stat
        false
      end
    end

    def available_quota
      return 99999 unless @quota
      return @quota unless @emails_count
      [0, @quota - @emails_count].max
    end

    def fetch_emails_stat
      return unless File.exists?(@quota_filename)
      @start_period, @emails_count = File.read(@quota_filename).split.map(&:to_i)
    end

    def store_emails_stat
      File.open(@quota_filename, 'w+') { |f| f.write [@start_period, @emails_count].join(' ') }
    end

    def reset_emails_stat
      @start_period, @emails_count = Time.now.utc.to_i, 0
    end

    def quota_filename
      if defined? Rails
        Rails.root.join('tmp', 'ar_mailer_rails3_quota')
      else
        File.expand_path('../../../ar_mailer_rails3_quota', __FILE__)
      end
    end

    ##
    # Proxy to ActionMailer::Base::smtp_settings.  See
    # http://api.rubyonrails.org/classes/ActionMailer/Base.html
    # for instructions on how to configure ActionMailer's SMTP server.
    #
    # Falls back to ::server_settings if ::smtp_settings doesn't exist for
    # backwards compatibility.

    def smtp_settings
      if @smtp_config && @current_domain
        @smtp_config[@current_domain]
      else
        ActionMailer::Base.smtp_settings
      end
    end

  end
end
