require 'sshkit'
require 'sshkit/dsl'
require 'yaml'
require 'commander'
require 'colorize'
require 'byebug'
require 'httparty'
require 'terminal-table'
require 'whirly'

include SSHKit::DSL

class SSLCheck
  include Commander::Methods

  @break = false

  def initialize(opts = {}) end

  def run
    program :name, 'Push Managment Commander'
    program :version, '0.2.0'
    program :description, 'Tool to more easily manage a bunch of installations of the Push Project.'

    global_option('-f', '--file FILE', 'Load config data for your commands to use') do |file|
      load_clients file
    end

    global_option('-b', '--break', 'Break if something goes wrong, otherwise continue') do |file|
      @break = true
    end

    global_option('-s', '--servers SERVERS', 'Indicate a list of comma seperated server names as you have in the config file. eg Test Server1,Test Server 2') do |servers|
      @servers = servers.split(',')
    end

    default_command :test

    command :test do |c|
      c.syntax = 'push_manager test [options]'
      c.description = 'Attempt to ssh into each server to verify the settings are all correct.'
      results = {}

      c.action do |args, options|
        clients = load_clients

        Whirly.start spinner: 'bouncingBall', status: 'Testing'.green do
          clients.each do |name, client|
            next if !@servers.nil? && !@servers.include?(name)

            Whirly.status = "Testing #{name}".green

            begin
              test_success = test client['url'], client['ssh-key']
            rescue => exception
              raise exception if @break
              test_success = false
            end

            if test_success
              begin
                heartbeat_success = check_server client['url']
              rescue => exception
                raise exception if @break
                heartbeat_success = false
              end
            else
              heartbeat_success = false
            end

            results[name] = { ssh: test_success,
                              heartbeat: heartbeat_success,
                              url: client['url'] }
          end
        end

        draw_statuses results, :ssh
      end
    end

    command :renew do |c|
      c.syntax = 'push_manager renew [options]'
      c.description = 'Automatically run through numerous setups of the Push server and renew the SSL certs.'

      results = {}

      c.action do |args, options|
        clients = load_clients

        Whirly.start spinner: 'bouncingBall', status: 'Running checks'.green do
          clients.each do |name, client|
            next if !@servers.nil? && !@servers.include?(name)

            Whirly.status = "Checking #{name}".green

            begin
              renew_success = renew_cert client['url'], client['ssh-key']
            rescue => exception
              raise exception if @break
              renew_success = false
            end

            if renew_success
              begin
                heartbeat_success = check_server client['url']
              rescue => exception
                raise exception if @break
                heartbeat_success = false
              end
            else
              heartbeat_success = false
            end

            results[name] = { renew: renew_success,
                              heartbeat: heartbeat_success,
                              url: client['url'] }
          end
        end

        draw_statuses results, :renew
      end
    end

    command :upgrade do |c|
      c.syntax = 'push_manager upgrade [options]'
      c.description = 'Automatically run through numerous setups of the Push server and upgrade all the git repositories.'
      results = {}

      # Manually do a git pull, probably only used once if the upgrade script doesn't exist
      c.option '-q', '--quash'
      # Don't run any migration scripts etc.
      c.option '-x', '--noscript'

      c.action do |args, options|
        options.default quash: false
        options.default noscript: false

        clients = load_clients

        Whirly.start spinner: 'bouncingBall', status: 'Upgrading'.green do
          clients.each do |name, client|
            next if !@servers.nil? && !@servers.include?(name)

            Whirly.status = "Upgrading #{name}".green

            begin
              upgrade_success = upgrade client['url'], client['ssh-key'], options.quash, options.noscript
            rescue => exception
              raise exception if @break
              upgrade_success = false
            end

            if upgrade_success
              begin
                heartbeat_success = check_server client['url']
              rescue => exception
                raise exception if @break
                heartbeat_success = false
              end
            else
              heartbeat_success = false
            end

            results[name] = { upgrade: upgrade_success,
                              heartbeat: heartbeat_success,
                              url: client['url'] }
          end
        end

        draw_statuses results, :upgrade
      end
    end

    run!
  end

  def load_clients(path = 'push-clients.yml')
    begin
      clients = YAML.load_file(path)
    rescue
      raise "No clients file found at #{path}"
    end

    raise "Clients file at #{path} is empty" if clients.nil? || clients == false
    clients
  end

  def test(server_address, key)
    host = SSHKit::Host.new(server_address)
    host.ssh_options = { keys: key }
    host.user = 'ubuntu'

    status = false
    on host, in: :parallel do
      within'~/Push-Backend' do
        output = capture(:ls)
        break unless output.include? 'app'
        status = true
      end
    end

    status
  end


  def renew_cert(server_address, key)
    host = SSHKit::Host.new(server_address)
    host.ssh_options = { keys: key }
    host.user = 'ubuntu'

    status = false
    on host, in: :parallel do
      within'~/Push-Backend' do
        output = capture(:bash, 'maintence-scripts/renew-lets_encrypt.sh')
        break unless output.include? 'Successfully renewed your SSL keys!'
        sleep 30

        status = true
      end
    end

    status
  end

  def upgrade(server_address, key, quash=false, noscript=false)
    host = SSHKit::Host.new(server_address)
    host.ssh_options = { keys: key }
    host.user = 'ubuntu'

    status = false
    output = nil

    on host, in: :parallel do
      within'~/Push-Backend' do
        # First we try the upgrade script
        begin
          output = capture(:bash, 'maintence-scripts/upgrade.sh')
        rescue => exception
          puts "There was an error running the upgrade script for #{server_address}. The '-q' flag may help here."
        end

        # Yea, this is sort of "if/else" hell, but not much to do about that
        if (output.nil? || !output.include?('Successfully pulled new code'))
          if quash
            # We'll do a force git pull, this is probably only used before
            # it's been updated to include the update script
            output = capture(:git, 'pull --rebase')
            status = true if output.include?('Already up-to-date.') ||
                                    output.include?('file changed') ||
                                    output.include?('files changed')
            if status == true
              begin
                output = capture(:bash, 'maintence-scripts/upgrade.sh')
              rescue => exception
              end

              # We try again
              break if (output.nil? || !output.include?('Successfully pulled new code'))
            end
          else
            break
          end
        end

        sleep 30

        if noscript == false
          output = capture('docker-compose', 'run web rake db:migrate')
          break if output.include?('rollback') || output.include?('Rollback')
        end

        status = true
      end
    end

    status
  end

  def check_server(server_address)

    url = "https://#{server_address}/heartbeat"
    response = HTTParty.get(url)

    if response.include? 'Success'
      return true
    end

    log "Error checking heartbeat: #{response} \n"
    false
  end

  def draw_statuses(results, key)
    rows = []
    results.each do |name, result|
      row = []
      row << name
      status = result[key] ? '✅' : '❌'
      heartbeat = result[:heartbeat] ? '✅ ' : '❌'
      row << status
      row << heartbeat
      row << "https://#{result[:url]}/heartbeat"
      rows << row
    end

    table = Terminal::Table.new :title => "Server Results", :headings => ['Server', key.capitalize, 'Heartbeat', 'Link'], :rows => rows
    puts table
  end
end

SSLCheck.new.run if $PROGRAM_NAME == __FILE__

