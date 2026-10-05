require 'open3'

module MacNetworkDNS
  def self.run(*args)
    output, status = Open3.capture2e(*args)
    raise "Network configuration failed: #{output.strip}" unless status.success?
    output.strip
  end
  def self.automatic?
    # This address belongs only to the private userspace router; it is not
    # the physical computer's gateway and exposes DNS, not its other services.
    router, status = Open3.capture2e('/usr/sbin/ipconfig', 'getoption', 'en0', 'router')
    status.success? && router.strip == '192.168.127.1'
  end
  def self.services
    run('/usr/sbin/networksetup', '-listallnetworkservices').lines.drop(1).map(&:strip).reject { |s| s.empty? || s.start_with?('*') }
  end
  def self.apply(backend:nil, renew:false)
    raise 'Invalid network backend' unless backend.nil? || %w[native vpn].include?(backend)
    if renew
      run('/usr/sbin/ipconfig', 'set', 'en0', 'NONE')
      run('/usr/sbin/ipconfig', 'set', 'en0', 'DHCP')
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      loop do
        router, status = Open3.capture2e('/usr/sbin/ipconfig', 'getoption', 'en0', 'router')
        break if status.success? && !router.strip.empty? && (backend == 'vpn') == (router.strip == '192.168.127.1')
        raise 'DHCP has not settled; run vm network refresh on the host to retry.' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.25
      end
    end
    servers = (backend ? backend == 'vpn' : automatic?) ? [] : %w[9.9.9.9 149.112.112.112]
    services.each do |service|
      current = run('/usr/sbin/networksetup', '-getdnsservers', service)
      next if (servers.empty? && current.start_with?("There aren't any DNS Servers set")) || current.split == servers
      run('/usr/sbin/networksetup', '-setdnsservers', service, *(servers.empty? ? ['empty'] : servers))
    end
  end
end

MacNetworkDNS.apply(backend:ARGV[0], renew:ARGV[1] == 'renew') if $PROGRAM_NAME == __FILE__
