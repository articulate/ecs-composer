#!/usr/bin/ruby
require 'json'
require 'yaml'

DEFAULT_MEM_LIMIT = '256m'

image_name = ARGV[0]
build_name = ARGV[1]
app_name = build_name.split('-')[0...-1].join("-")

def detect_command(service)
  command = service["command"]
  command ||= `cat Dockerfile | grep CMD | sed 's/CMD //'`.strip

  ["bash", "-c", "make pr-prepare ; #{command}"]
end

if File.exists?('service.json')
  app_config = File.read('service.json')
  peer_config = JSON.parse(app_config)["peer"] || {}
else
  raise "No service.json file detected"
end

compose = YAML.load_file('docker-compose.yml')
compose["services"].each do |service_name, service|
  # logging
  service["logging"] = {
    "driver" => "syslog",
    "options" => {
      "syslog-address" => "udp://rsyslog.priv:514",
      "tag" => "peer-#{build_name}-#{service_name}"
    }
  }

  service.delete("labels")

  image = service.fetch("image", "")
  service["image"] = image_name if service.delete("build")
  service["image"] = image_name if image == "#{app_name.gsub("-", "")}_app"

  service["mem_limit"] ||= DEFAULT_MEM_LIMIT

  dependant = service.delete('depends_on')
  service["links"] ||= []
  service["links"].concat dependant if dependant

  service["environment"] ||= []

  # Consul/Vault Config
  service["environment"] << "APP_NAME=#{app_name}"
  service["environment"] << "APP_ENV=peer-#{build_name}"
  service["environment"] << "VAULT_ADDR=http://vault.priv"
  service["environment"] << "CONSUL_ADDR=consul.priv:8500"
  service["environment"] << "SYSTEM_URL=#{build_name}.peer.articulate.zone"

  if service_name == "app"
    service["command"] = detect_command(service)

    # Fabio Config
    service["environment"] << "SERVICE_3000_CHECK_INTERVAL=15s"
    service["environment"] << "SERVICE_3000_CHECK_TCP=true"
    service["environment"] << "SERVICE_3000_NAME=#{build_name}"
    service["environment"] << "SERVICE_3000_TAGS=urlprefix-#{build_name}.peer.articulate.zone/"
  end

  # Local Service Env
  if peer_config["env_mapping"]
    local_env_key = peer_config["env_mapping"][service_name]
    service["environment"].concat peer_config.fetch(local_env_key, [])
  elsif service_name == "app"
    service["environment"].concat peer_config.fetch("env", [])
  end

  # Volume mounting
  service["volumes"] ||= []

  if peer_config["volumes"] && peer_config["volumes"][service_name]
    peer_config["volumes"][service_name].each do |container_path|
      service["volumes"] << "/var/peer-storage/#{build_name}/#{service_name}:#{container_path}"
    end
  end

  compose["services"][service_name] = service
end

File.open('docker-compose-ecs.yml', 'w') {|f| f.write compose.to_yaml }
