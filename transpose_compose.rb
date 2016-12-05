#!/usr/bin/ruby
require 'yaml'

DEFAULT_MEM_LIMIT = '256m'

image_name = ARGV[0]
build_name = ARGV[1]
app_container_name = ARGV[2]

logging = {
  "driver" => "syslog",
  "options" => {
    "syslog-address" => "udp://rsyslog.priv:514",
    "tag" => "peer-#{build_name}"
  }
}

def detect_command(service)
  command = service["command"]
  command ||= `cat Dockerfile | grep CMD | sed 's/CMD //'`.strip

  ["bash", "-c", "make pr-prepare ; #{command}"]
end

def detect_entrypoint(service)
  entrypoint = service['entrypoint']
  entrypoint ||= `docker inspect #{app_container_name} | jq -r ".[0].Config.Entrypoint[0] | .[]"`.strip.split("\n")
  entrypoint ||= []

  entrypoint << "./local-env.sh"
end

app_config = YAML.load_file('.app.yml')["peer"] if File.exists?('.app.yml')

compose = YAML.load_file('docker-compose.yml')
compose["services"].each do |service_name, service|
  service.delete("labels")

  service["image"] = image_name if service.delete("build")
  service["mem_limit"] ||= DEFAULT_MEM_LIMIT

  # service["links"] ||= []
  service["links"] = service.delete('depends_on')

  if service_name == "app"
    service["command"] = detect_command(service)

    service["environment"] ||= []

    # Fabio Config
    service["environment"] << "SERVICE_3000_CHECK_INTERVAL=15s"
    service["environment"] << "SERVICE_3000_CHECK_TCP=true"
    service["environment"] << "SERVICE_3000_NAME=#{build_name}"
    service["environment"] << "SERVICE_3000_TAGS=urlprefix-#{build_name}.peer.articulate.zone/"

    # Env Config
    service["environment"] << "VAULT_ADDR=http://vault.priv"
    service["environment"] << "CONSUL_ADDR=consul.priv:8500"

    # local app config
    service["entrypoint"] = detect_entrypoint
    service["logging"] = logging
  end

  compose["services"][service_name] = service
end

File.open('docker-compose-ecs.yml', 'w') {|f| f.write compose.to_yaml }
