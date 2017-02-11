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

  def initialize(opts = {}) end

  def run
    program :name, 'Push Renew SSL Certs'
    program :version, '0.1.0'
    program :description, 'Tool to automatically run through numerous setups of the Push server and renew the SSL certs.'

    global_option('-f', '--file FILE', 'Load config data for your commands to use') do |file|
      load_clients file
    end

    default_command :renew

    command :renew do |c|
      c.syntax = 'renew_ssl renew [options]'
      c.description = 'Renew all certs.'

      results = {}

      c.action do |args, options|
        clients = load_clients

        Whirly.start spinner: "bouncingBall", status: 'Running checks'.green do
          clients.each do |name, client|
            Whirly.status = "Checking #{name}".green

            if (renew_success = renew_cert client['url'], client['ssh-key'])
              heartbeat_success = check_server client['url']
            else
              heartbeat_success = false
            end

            results[name] = { renew: renew_success,
                              heartbeat: heartbeat_success,
                              url: client['url'] }
          end
        end

        draw_statuses results
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

  def renew_cert(server_address, key)

    host = SSHKit::Host.new(server_address)
    host.ssh_options = {keys: key}
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

    return status
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

  def draw_statuses(results)
    rows = []
    results.each do |name, result|
      row = []
      row << name
      renew = result[:renew] ? '✅' : '❌'
      heartbeat = result[:heartbeat] ? '✅ ' : '❌'
      row << renew
      row << heartbeat
      row << "https://#{result[:url]}/heartbeat"
      rows << row
    end

    table = Terminal::Table.new :title => "Server Results", :headings => ['Server', 'Renewed', 'Heartbeat', 'Link'], :rows => rows
    puts table
  end
end

SSLCheck.new.run if $PROGRAM_NAME == __FILE__

