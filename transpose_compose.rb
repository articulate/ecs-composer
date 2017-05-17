#!/usr/bin/ruby
require 'json'
require 'yaml'
require 'ostruct'

# Encapsulates each service block in a compose file
class Service
  DEFAULT_MEM_RESERVATION = '64m'

  attr_reader :image_name, :build_name, :app_name

  def initialize(name, defn)
    @name = name
    @defn = defn

    @image_name = ARGV[0]
    @build_name = ARGV[1]
    @app_name = @build_name.split('-')[0...-1].join("-")

    # A few required things
    @defn["environment"] ||= []
    @defn["links"] ||= []
    @defn["volumes"] ||= []
  end

  def setup_env(config)
    if config["env_mapping"]
      local_env_key = config["env_mapping"][@name]
      @defn["environment"].concat config.fetch(local_env_key, [])
    elsif is_app?
      @defn["environment"].concat config.fetch("env", [])
    end
  end

  def mount_volumes(config)
    if config["volumes"] && config["volumes"][@name]
      config["volumes"][@name].each do |container_path|
        @defn["volumes"] << "/var/peer-storage/#{build_name}/#{@name}:#{container_path}"
      end
    end
  end

  def serialize!
    add_logging
    delete_labels
    ensure_mem_reservation
    ensure_image
    convert_links
    add_peer_env

    build_command do
      prepare_system if is_app?
      delay_for_database if db_required?
    end

    @defn
  end

  def base_command
    @command = service["command"]
    @command ||= `cat Dockerfile | grep CMD | sed 's/CMD //'`.strip if is_app?
  end

  def db_required?
    links.include?("db") ||
      links.include?("postgres") ||
      links.include?("postgresql") ||
      links.include?("redis") ||
      links.include?("elasticsearch") ||
      links.include?("memcache") ||
      links.include?("memcached") ||
      links.include?("cache")
  end

  def is_app?
    @name == "app"
  end

  def reuse_app_image?
    @defn['image'] == "#{app_name.gsub("-", "")}_app"
  end

  private

  def links
    @defn['links']
  end

  def add_logging
    @defn['logging'] = {
      "driver" => "syslog",
      "options" => {
        "syslog-address" => "udp://rsyslog.priv:514",
        "tag" => "peer-#{build_name}-#{@name}"
      }
    }
  end

  def delete_labels
    @defn.delete("labels")
  end

  def ensure_mem_reservation
    @defn["mem_reservation"] = @defn.delete("mem_limit")
    @defn["mem_reservation"] ||= DEFAULT_MEM_RESERVATION
  end

  def ensure_image
    image = @defn.fetch("image", "")
    @defn["image"] = image_name if @defn.delete("build")
    @defn["image"] = image_name if reuse_app_image?
  end

  def convert_links
    dependant = @defn.delete('depends_on')
    @defn["links"].concat dependant if dependant
  end

  def add_peer_env
    @defn["environment"] << "APP_NAME=#{app_name}"
    @defn["environment"] << "APP_ENV=peer-#{build_name}"
    @defn["environment"] << "VAULT_ADDR=http://vault.priv"
    @defn["environment"] << "CONSUL_ADDR=consul.priv:8500"
    @defn["environment"] << "SYSTEM_URL=#{build_name}.peer.articulate.zone"

    if is_app?
      @defn["environment"] << "SERVICE_3000_CHECK_INTERVAL=15s"
      @defn["environment"] << "SERVICE_3000_CHECK_TCP=true"
      @defn["environment"] << "SERVICE_3000_NAME=#{build_name}"
      @defn["environment"] << "SERVICE_3000_TAGS=urlprefix-#{build_name}.peer.articulate.zone/"
    end
  end

  def delay_for_database
    @command.unshift "make peer-wait-for-it"
  end

  def prepare_system
    @command.unshift "make peer-prepare"
  end

  def build_command
    command = @defn["command"]

    # use the Dockerfile command if we're the app and nothing is yet specified
    command ||= `cat Dockerfile | grep CMD | sed 's/CMD //'`.strip if is_app?

    if !command.nil?
      @command = Array(command)
      yield
      @command = ["bash", "-c", @command.join(" && ")]
      @defn['command'] = @command
    else
      # No command modification
      true
    end
  end

end

if File.exists?('service.json')
  app_config = File.read('service.json')
  peer_config = JSON.parse(app_config)["peer"] || {}
else
  raise "No service.json file detected"
end

compose = YAML.load_file('docker-compose.yml')
compose["services"].each do |service_name, details|
  service = Service.new(service_name, details)

  service.setup_env(peer_config)
  service.mount_volumes(peer_config)

  compose["services"][service_name] = service.serialize!
end

File.open('docker-compose-ecs.yml', 'w') {|f| f.write compose.to_yaml }
