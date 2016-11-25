#!/usr/bin/ruby
require 'yaml'

DEFAULT_MEM_LIMIT = '256m'

image_name = ARGV[0]
build_name = ARGV[1]

def detect_command(service)
  command = service["command"]
  command ||= `cat Dockerfile | grep CMD | sed 's/CMD //'`.strip

  ["bash", "-c", "make pr-prepare ; #{command}"]
end

compose = YAML.load_file('docker-compose.yml')
compose["services"].each do |service_name, service|
  service.delete("labels")

  service["image"] = image_name if service.delete("build")
  service["mem_limit"] ||= DEFAULT_MEM_LIMIT

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
    service["environment"] << "CONSUL_ADDR=http://consul.priv:8500"
    service["environment"] << "PEER_CONSUL_ADDR=http://consul.peer.articulate.zone:8500"
  end

  compose["services"][service_name] = service
end

File.open('docker-compose-ecs.yml', 'w') {|f| f.write compose.to_yaml }
