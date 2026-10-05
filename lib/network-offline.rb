#!/usr/bin/ruby
require 'socket'

# A disconnected Ethernet endpoint: consume frames without replying or opening
# any network socket. SSH and explicit forwards use Tart's separate VirtIO link.
wire = Socket.for_fd(0)
abort 'Expected a datagram endpoint.' unless wire.getsockopt(Socket::SOL_SOCKET, Socket::SO_TYPE).int == Socket::SOCK_DGRAM
trap('INT') { exit }
loop { wire.recv(65_536) }
