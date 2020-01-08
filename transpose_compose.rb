#!/usr/bin/ruby
require 'json'
require 'yaml'
require 'ostruct'

# Encapsulates each service block in a compose file
class Service
  DEFAULT_MEM_RESERVATION = '256m'

  attr_reader :image_name, :build_name, :app_name, :name

  def initialize(name, defn)
    @name = name
    @defn = defn

    @image_name = ARGV[0]
    @build_name = ARGV[1]
    @account_name = ARGV[2]
    @product_name = ARGV[3]
    @app_name = @build_name.split('-')[0...-1].join("-")
    @original_labels = @defn["labels"]

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

  def add_additional_fields(config)
    if config["additional_fields"] && config["additional_fields"][@name]
      config["additional_fields"][@name].each do |field, value|
        @defn[field] = value
      end
    end
  end

  def mount_volumes(config)
    if config["volumes"] && config["volumes"][@name]
      config["volumes"][@name].each do |container_path|
        @defn["volumes"] << "/var/peer-storage/#{build_name}/#{@name}:#{container_path}"
      end
    end
  end

  def serialize!(config)
    add_logging
    delete_labels
    ensure_mem_limits
    ensure_image
    convert_links
    setup_env(config)
    add_peer_env(config)
    mount_volumes(config)
    add_additional_fields(config)

    build_command do
      prepare_system if is_app?
      delay_for_database if db_required?
    end
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

  def expose_fabio?
    if @original_labels.is_a?(Array)
      @original_labels.any? {|label| label =~ /^SERVICE_3000_NAME=/ }
    elsif @original_labels.is_a?(Hash)
      !@original_labels["SERVICE_3000_NAME"].nil?
    else
      false
    end
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
        "tag" => "peer-#{build_name}-#{@name}"
      }
    }
  end

  def delete_labels
    @defn.delete("labels")
  end

  def ensure_mem_limits
    if @defn["mem_reservation"].nil? && @defn["mem_limit"].nil?
      @defn["mem_reservation"] ||= DEFAULT_MEM_RESERVATION
    end
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

  def add_peer_env(config)
    @defn["environment"] << "APP_NAME=#{app_name}" unless @defn["environment"].any? { |e| e.start_with?('APP_NAME=') }
    @defn["environment"] << "SERVICE_PRODUCT=#{product_name}" unless @defn["environment"].any? { |e| e.start_with?('SERVICE_PRODUCT=') }
    @defn["environment"] << "APP_ENV=peer-#{build_name}"
    @defn["environment"] << "VAULT_ADDR=#{vault_address}"
    @defn["environment"] << "CONSUL_ADDR=#{consul_address}"
    @defn["environment"] << "SYSTEM_URL=#{service_host}"
    @defn["environment"] << "PEER_ID=#{build_name}"
    @defn["environment"] << "#{config["service_env_name"]}=#{service_address}" if config["service_env_name"]
    @defn["environment"] << "#{config["servicehost_env_name"]}=#{service_host}" if config["servicehost_env_name"]

    if expose_fabio?
      if is_app?
        @defn["environment"] << "SERVICE_3000_CHECK_INTERVAL=15s"
        @defn["environment"] << "SERVICE_3000_CHECK_TCP=true"
        @defn["environment"] << "SERVICE_3000_NAME=#{build_name}"
        @defn["environment"] << "SERVICE_3000_TAGS=urlprefix-#{build_name}.peer.*/,urlprefix-/#{build_name} strip=/#{build_name}"
      else
        @defn["environment"] << "SERVICE_3000_CHECK_INTERVAL=15s"
        @defn["environment"] << "SERVICE_3000_CHECK_TCP=true"
        @defn["environment"] << "SERVICE_3000_NAME=#{build_name}-#{name}"
        @defn["environment"] << "SERVICE_3000_TAGS=urlprefix-#{build_name}-#{name}.peer.*/,urlprefix-/#{build_name}-#{name} strip=/#{build_name}-#{name}"
      end
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

    if command.is_a?(String) && command =~ /^\[/
      command = JSON.parse(command).join(" ")
    end

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

  def account_name
    @account_name || "legacy"
  end

  def product_name
    @product_name || "360"
  end

  def consul_address
    "http://consul.#{account_name}.stage.art-internal.com"
  end

  def vault_address
    if account_name == "legacy"
      "http://#{vault_host}"
    else
      "https://#{vault_host}"
    end
  end

  def vault_host
    "vault.#{account_name}.stage.art-internal.com"
  end

  def service_address
    "https://#{service_host}"
  end

  def service_host
    if account_name == "legacy"
      "#{build_name}.peer.articulate.zone"
    else
      "#{build_name}.peer.rise.zone"
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
  Service.new(service_name, details).serialize!(peer_config)
end

File.open('docker-compose-ecs.yml', 'w') {|f| f.write compose.to_yaml }
