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
    router == '192.168.127.1'
  end
  def self.router
    value, status = Open3.capture2e('/usr/sbin/ipconfig', 'getoption', 'en0', 'router')
    status.success? ? value.strip : ''
  end
  def self.services
    run('/usr/sbin/networksetup', '-listallnetworkservices').lines.drop(1).map(&:strip).reject { |s| s.empty? || s.start_with?('*') }
  end
  def self.ethernet_service
    name = nil
    enabled = services
    run('/usr/sbin/networksetup', '-listnetworkserviceorder').each_line do |line|
      match = line.match(/^\((\d+|\*)\) (.+)$/)
      name = match[1] == '*' ? nil : match[2] if match
      return name if enabled.include?(name) && line.match?(/Device: en0\)\s*$/)
    end
    raise 'No enabled network service for en0; inspect guest Network settings.'
  end
  def self.wait_for
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    until yield
      raise 'DHCP has not settled; run vm network refresh on the host to retry.' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.25
    end
  end
  def self.apply(backend:nil, renew:false)
    raise 'Invalid network backend' unless backend.nil? || %w[native vpn].include?(backend)
    if renew
      # ipconfig set creates a temporary service whose DHCP DNS overrides the
      # saved networksetup settings. Renew the managed service instead, keeping
      # its DNS and IPv6 policy. Wait for the old lease to disappear before
      # restoring DHCP, so a same-backend replacement cannot accept stale state.
      service = ethernet_service
      run('/usr/sbin/networksetup', '-setv4off', service)
      begin
        wait_for { router.empty? }
      ensure
        run('/usr/sbin/networksetup', '-setdhcp', service)
      end
      wait_for do
        current = router
        !current.empty? && (backend == 'vpn') == (current == '192.168.127.1')
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
