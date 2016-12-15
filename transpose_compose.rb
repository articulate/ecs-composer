#!/usr/bin/ruby
require 'json'
require 'yaml'

DEFAULT_MEM_LIMIT = '256m'

image_name = ARGV[0]
build_name = ARGV[1]

def detect_command(service)
  command = service["command"]
  command ||= `cat Dockerfile | grep CMD | sed 's/CMD //'`.strip

  ["bash", "-c", "make pr-prepare ; #{command}"]
end

if File.exists?('.app.json')
  app_config = File.read('.app.json')
  peer_config = JSON.parse(app_config)["peer"] || {}
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

  service["image"] = image_name if service.delete("build")
  service["mem_limit"] ||= DEFAULT_MEM_LIMIT

  dependant = service.delete('depends_on')
  service["links"] ||= []
  service["links"].concat dependant if dependant

  service["environment"] ||= []
  
  if service_name == "app"
    service["command"] = detect_command(service)

    # Fabio Config
    service["environment"] << "SERVICE_3000_CHECK_INTERVAL=15s"
    service["environment"] << "SERVICE_3000_CHECK_TCP=true"
    service["environment"] << "SERVICE_3000_NAME=#{build_name}"
    service["environment"] << "SERVICE_3000_TAGS=urlprefix-#{build_name}.peer.articulate.zone/"

    # Consul/Vault Config
    service["environment"] << "VAULT_ADDR=http://vault.priv"
    service["environment"] << "CONSUL_ADDR=consul.priv:8500"
  end

  # Local Service Env    
  if peer_config["env_mapping"]
    local_env_key = peer_config["env_mapping"][service_name]
    service["environment"].concat peer_config.fetch(local_env_key, [])
  elsif service_name == "app"
    service["environment"].concat peer_config.fetch("env", [])
  end

  compose["services"][service_name] = service
end

File.open('docker-compose-ecs.yml', 'w') {|f| f.write compose.to_yaml }
