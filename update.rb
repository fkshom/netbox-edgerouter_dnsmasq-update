require 'netbox-client-ruby'
require 'net/ssh'
require 'ed25519'
require 'net/scp'
require 'dotenv'
Dotenv.load

NetboxClientRuby.configure do |config|
  config.netbox.auth.token = ENV['NETBOX_AUTH_TOKEN']
  config.netbox.api_base_url = ENV['NETBOX_API_BASE_URL']

  # these are optional:
  # config.netbox.auth.rsa_private_key.path = '~/.ssh/netbox_rsa'
  # config.netbox.auth.rsa_private_key.password = ''
  # config.netbox.pagination.default_limit = 50
  # config.faraday.adapter = Faraday.default_adapter
  # config.faraday.request_options = { open_timeout: 1, timeout: 5 }
  # config.faraday.logger = :logger # built-in options: :logger, :detailed_logger; default: nil
end

def dns_service_records_from_netbox
  NetboxClientRuby.ipam.services.inject([]) do |result, service|
    service.ipaddresses.to_a.each do |ipaddress|
      result << {
        dns_name: service.name,  # xx or xx.home.fukuda.dev
        address: ipaddress.address.to_s[%r{\A[^/]+}]
      }
    end
    result
  end.reject do |record|
    record[:dns_name] == ''
  end
end

def dns_records_from_netbox
  NetboxClientRuby.ipam.ip_addresses.map do |ip_address|
    {
      dns_name: ip_address.dns_name,
      address: ip_address.address.to_s[%r{\A[^/]+}]
    }
  end.reject do |record|
    record[:dns_name] == ''
  end
end

def generate_dns_record_file(dns_records, filepath)
  dns_record_lines = dns_records.map do |record|
    '%<address>-30s %<dns_name>s' % record
    #    "#{record[:address]} #{record[:dns_name]}"
  end
  puts 'generated dns record file entry'
  puts '=' * 20
  pp dns_record_lines

  File.write(filepath, dns_record_lines.join("\n") + "\n")
end

class VirtualizationVminterfaces
  class << self
    def objects
      @objects ||= NetboxClientRuby.virtualization.interfaces.to_a
      @objects
    end

    def [](id)
      objects.find do |obj|
        obj['id'] == id
      end
    end
  end
end

class DcimInterfaces
  class << self
    def objects
      @objects ||= NetboxClientRuby.dcim.interfaces.to_a
      @objects
    end

    def [](id)
      objects.find do |obj|
        obj['id'] == id
      end
    end
  end
end

def dhcp_records_from_netbox_edgerouter(filepath)
  record_lines = []

  NetboxClientRuby.ipam.ip_addresses.each do |record|
    ip_address = record['address']
    lan_group = case ip_address
                when /^192\.168\.1\./
                  'LAN1'
                when /^192\.168\.2\./
                  'LAN2'
                else
                  next
                end

    hostname = nil
    interface_name = nil
    # pp record
    case record['assigned_object_type']
    when 'dcim.interface'
      interface = DcimInterfaces[record['assigned_object_id']]
      next unless interface['mac_address']

      mac_address = interface['mac_address']
      hostname = interface['device']['name']
      interface_name = interface['name']
    when 'virtualization.vminterface'
      interface = VirtualizationVminterfaces[record['assigned_object_id']]
      # pp interface
      next unless interface['mac_address']

      mac_address = interface['mac_address']
      hostname = interface['virtual_machine']['name']
      interface_name = interface['name']
    else
      warn "#{ip_address} has unknown assigned_object_type: #{record['assigned_object_type']}"
    end

    record_lines << format("#{mac_address},set:#{lan_group},%<ipa>-14s  # #{hostname} (#{interface_name})",
                           ipa: ip_address.to_s[%r{\A[^/]+}])
  end
  puts 'generated dns record file entry'
  puts '=' * 20
  pp record_lines

  File.write(filepath, record_lines.join("\n") + "\n")
end

def dhcp_records_from_netbox(filepath)
  record_lines = []

  NetboxClientRuby.ipam.ip_addresses.each do |record|
    ip_address = record['address']
    lan_group = case ip_address
                when /^192\.168\.1\./
                  'LAN1'
                when /^192\.168\.2\./
                  'LAN2'
                else
                  next
                end

    hostname = nil
    interface_name = nil
    # pp record
    case record['assigned_object_type']
    when 'dcim.interface'
      interface = DcimInterfaces[record['assigned_object_id']]
      next unless interface['mac_address']

      mac_address = interface['mac_address']
      hostname = interface['device']['name']
      interface_name = interface['name']
    when 'virtualization.vminterface'
      interface = VirtualizationVminterfaces[record['assigned_object_id']]
      # pp interface
      next unless interface['mac_address']

      mac_address = interface['mac_address']
      hostname = interface['virtual_machine']['name']
      interface_name = interface['name']
    else
      warn "#{ip_address} has unknown assigned_object_type: #{record['assigned_object_type']}"
    end

    if lan_group != 'LAN2'
      record_lines << format("#{mac_address},%<ipa>-14s  # #{hostname} (#{interface_name})",
                            ipa: ip_address.to_s[%r{\A[^/]+}])
    end
  end
  puts 'generated dns record file entry'
  puts '=' * 20
  pp record_lines

  File.write(filepath, record_lines.join("\n") + "\n")
end

def save_dns_records_to_edge_router(dns_records)
  filepath = '/tmp/abcde'
  generate_dns_record_file(dns_records, filepath)

  # set service dns forwarding options addn-hosts=/config/dnsmasq.hosts.d
  Net::SSH.start(ENV['EDGEROUTER_HOSTNAME'], ENV['EDGEROUTER_USER'], password: ENV['EDGEROUTER_PASS']) do |ssh|
    ssh.exec!('mkdir -p /config/dnsmasq-addn-hosts.d/')
    ssh.exec!('mkdir -p /config/dnsmasq-dhcp.d/')
  end

  Net::SCP.upload!(
    ENV['EDGEROUTER_HOSTNAME'], ENV['EDGEROUTER_USER'],
    filepath, '/config/dnsmasq-addn-hosts.d/netbox_defined',
    ssh: { password: ENV['EDGEROUTER_PASS'] }
  )
  puts "Upadated '/config/dnsmasq-addn-hosts.d/netbox_defined' on edge router"

  # Net::SSH.start(ENV['EDGEROUTER_HOSTNAME'], ENV['EDGEROUTER_USER'], password: ENV['EDGEROUTER_PASS']) do |ssh|
  #   ssh.exec!('sudo /etc/init.d/dnsmasq systemd-reload')
  # end
  # puts 'reload dnsmasq'
end


def save_dns_records_to_dnsmaster(dns_records)
  filepath = '/tmp/abcde'
  generate_dns_record_file(dns_records, filepath)

  # set service dns forwarding options addn-hosts=/config/dnsmasq.hosts.d
  # Net::SSH.start(ENV['DNSMASTER_HOSTNAME'], ENV['DNSMASTER_USER'], password: ENV['DNSMASTER_PASS']) do |ssh|
  #   ssh.exec!('mkdir -p /config/dnsmasq-addn-hosts.d/')
  #   ssh.exec!('mkdir -p /config/dnsmasq-dhcp.d/')
  # end
  require 'logger'
  logger = Logger.new(STDOUT)
  Net::SCP.upload!(
    ENV['DNSMASTER_HOSTNAME'], ENV['DNSMASTER_USER'],
    filepath, '/etc/dnsmasq.hosts/netbox_defined',
    ssh: { 
      password: ENV['DNSMASTER_PASS'],
      logger: logger,
      verbose: :info,
    },
    # ssh: {
    #   keys: ""
    # },
  )
  puts "Upadated '/etc/dnsmasq.hosts/netbox_defined' on dnsmaster"

  # Net::SSH.start(ENV['EDGEROUTER_HOSTNAME'], ENV['EDGEROUTER_USER'], password: ENV['EDGEROUTER_PASS']) do |ssh|
  #   ssh.exec!('sudo /etc/init.d/dnsmasq systemd-reload')
  # end
  # puts 'reload dnsmasq'
end

def save_dhcp_records_to_edge_router
  filepath = '/tmp/abcde'
  dhcp_records_from_netbox_edgerouter(filepath)

  # set service dns forwarding options addn-hosts=/config/dnsmasq.hosts.d
  Net::SSH.start(ENV['EDGEROUTER_HOSTNAME'], ENV['EDGEROUTER_USER'], password: ENV['EDGEROUTER_PASS']) do |ssh|
    ssh.exec!('mkdir -p /config/dnsmasq-addn-hosts.d/')
    ssh.exec!('mkdir -p /config/dnsmasq-dhcp.d/')
  end

  Net::SCP.upload!(
    ENV['EDGEROUTER_HOSTNAME'], ENV['EDGEROUTER_USER'],
    filepath, '/config/dnsmasq-dhcp.d/netbox_defined',
    ssh: { password: ENV['EDGEROUTER_PASS'] }
  )
  puts "Upadated '/config/dnsmasq-dhcp.d/netbox_defined' on edge router"

  Net::SSH.start(ENV['EDGEROUTER_HOSTNAME'], ENV['EDGEROUTER_USER'], password: ENV['EDGEROUTER_PASS']) do |ssh|
    ssh.exec!('sudo /etc/init.d/dnsmasq systemd-reload')
  end
  puts 'reload dnsmasq'
end

def save_dhcp_records_to_dnsmaster
  filepath = '/tmp/abcde'
  dhcp_records_from_netbox(filepath)

  # set service dns forwarding options addn-hosts=/config/dnsmasq.hosts.d
  # Net::SSH.start(ENV['DNSMASTER_HOSTNAME'], ENV['DNSMASTER_USER'], password: ENV['DNSMASTER_PASS']) do |ssh|
  #   ssh.exec!('mkdir -p /etc/dnsmasq-addn-hosts.d/')
  #   ssh.exec!('mkdir -p /config/dnsmasq-dhcp.d/')
  # end

  Net::SCP.upload!(
    ENV['DNSMASTER_HOSTNAME'], ENV['DNSMASTER_USER'],
    filepath, '/etc/dnsmasq.dhcp/netbox_defined',
    ssh: { password: ENV['DNSMASTER_PASS'] }
  )
  puts "Upadated '/etc/dnsmasq.dhcp/netbox_defined' on dnsmaster"

  Net::SSH.start(ENV['DNSMASTER_HOSTNAME'], ENV['DNSMASTER_USER'], password: ENV['DNSMASTER_PASS']) do |ssh|
    ssh.exec!('sudo systectl restart reload')
  end
  puts 'reload dnsmasq'
end

def main
  require 'pry'
  dns_records = dns_records_from_netbox
  puts 'get from netbox'
  puts '=' * 20
  pp dns_records
  save_dns_records_to_edge_router(dns_records)

  save_dhcp_records_to_edge_router
end

def main1
  require 'pry'
  dns_service_records = dns_service_records_from_netbox
  dns_records = dns_records_from_netbox
  dns_all_records = dns_service_records + dns_records
  puts 'get from netbox'
  puts '=' * 20
  pp dns_all_records
  save_dns_records_to_edge_router(dns_all_records)
  save_dns_records_to_dnsmaster(dns_all_records)
  save_dhcp_records_to_edge_router
  save_dhcp_records_to_dnsmaster
end

main1

