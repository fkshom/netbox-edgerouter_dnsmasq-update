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
    '%<address>-15s %<dns_name>s' % record
#    "#{record[:address]} #{record[:dns_name]}"
  end
  puts "generated dns record file entry"
  puts "=" * 20
  pp dns_record_lines

  File.write(filepath, dns_record_lines.join("\n") + "\n")
end

def save_dns_records_to_edge_router(dns_records)
  filepath = '/tmp/abcde'
  generate_dns_record_file(dns_records, filepath)

  # set service dns forwarding options addn-hosts=/config/dnsmasq.hosts.d
  Net::SSH.start(ENV['EDGEROUTER_HOSTNAME'], ENV['EDGEROUTER_USER'], password: ENV['EDGEROUTER_PASS']) do |ssh|
    ssh.exec!('mkdir -p /config/dnsmasq.hosts.d')
  end

  Net::SCP.upload!(
    ENV['EDGEROUTER_HOSTNAME'], ENV['EDGEROUTER_USER'],
    filepath, '/config/dnsmasq.hosts.d/dnsmasq-hosts-config.conf',
    ssh: { password: ENV['EDGEROUTER_PASS'] }
  )
  puts "Upadated '/config/dnsmasq.hosts.d/dnsmasq-hosts-config.conf' on edge router"
  Net::SSH.start(ENV['EDGEROUTER_HOSTNAME'], ENV['EDGEROUTER_USER'], password: ENV['EDGEROUTER_PASS']) do |ssh|
    ssh.exec!('sudo /etc/init.d/dnsmasq systemd-reload')
  end
  puts "reload dnsmasq"
end

def main
  dns_records = dns_records_from_netbox
  puts "get from netbox"
  puts "=" * 20
  pp dns_records
  save_dns_records_to_edge_router(dns_records)
end

main