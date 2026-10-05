package main

import (
	"encoding/binary"
	"net"
	"net/netip"
	"testing"
)

func testPolicy() *filtered {
	mac, _ := net.ParseMAC("5a:94:ef:e4:0c:02")
	p := &filtered{mac: mac}
	for _, s := range []string{"0.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4", "203.0.113.0/24"} {
		p.blocks = append(p.blocks, netip.MustParsePrefix(s))
	}
	return p
}

func packet(p *filtered, destination string, port uint16) []byte {
	b := make([]byte, 54)
	copy(b[6:12], p.mac)
	binary.BigEndian.PutUint16(b[12:14], 0x800)
	ip := b[14:]
	ip[0] = 0x45
	ip[9] = 6
	binary.BigEndian.PutUint16(ip[2:4], uint16(len(ip)))
	copy(ip[12:16], guest.AsSlice())
	copy(ip[16:20], netip.MustParseAddr(destination).AsSlice())
	binary.BigEndian.PutUint16(ip[20:22], 40000)
	binary.BigEndian.PutUint16(ip[22:24], port)
	return b
}

func TestDestinationIsolation(t *testing.T) {
	p := testPolicy()
	for _, ip := range []string{"127.0.0.1", "10.1.2.3", "100.64.1.1", "169.254.169.254", "172.16.0.1", "192.168.0.1", "203.0.113.2", "224.0.0.1", "240.0.0.1", "0.1.2.3"} {
		if p.allow(packet(p, ip, 443)) {
			t.Errorf("allowed restricted destination %s", ip)
		}
	}
	for _, ip := range []string{"1.1.1.1", "9.9.9.9"} {
		if !p.allow(packet(p, ip, 443)) {
			t.Errorf("blocked public destination %s", ip)
		}
	}
	for _, port := range []uint16{22, 80, 443, 5353, 8080, 65535} {
		if p.allow(packet(p, gateway.String(), port)) {
			t.Errorf("exposed router service %d", port)
		}
	}
	if !p.allow(packet(p, gateway.String(), 53)) {
		t.Fatal("private DNS endpoint unavailable")
	}
}

func TestMalformedOrSpoofedFramesCannotEscape(t *testing.T) {
	p := testPolicy()
	valid := packet(p, "1.1.1.1", 443)
	for n := 0; n < len(valid); n++ {
		if p.allow(valid[:n]) {
			t.Fatalf("accepted truncated packet of size %d", n)
		}
	}
	for _, mutate := range []func([]byte){
		func(b []byte) { b[6] ^= 1 },
		func(b []byte) { b[26] = 8 },
		func(b []byte) { b[14] = 0x46 },
		func(b []byte) { b[12] = 0x86; b[13] = 0xdd },
		func(b []byte) { b[23] = 47 },
	} {
		b := append([]byte{}, valid...)
		mutate(b)
		if p.allow(b) {
			t.Fatal("accepted spoofed source, IP options, IPv6 or tunnel protocol")
		}
	}
	b := packet(p, gateway.String(), 53)
	b[20] = 0x20
	if p.allow(b) {
		t.Fatal("accepted fragmented DNS packet")
	}
}

func TestDHCPPermitsOnlyThisGuest(t *testing.T) {
	p := testPolicy()
	b := packet(p, "255.255.255.255", 67)
	b = append(b, make([]byte, 248)...)
	ip := b[14:]
	ip[9] = 17
	binary.BigEndian.PutUint16(ip[2:4], uint16(len(ip)))
	binary.BigEndian.PutUint16(ip[20:22], 68)
	dhcp := ip[28:]
	dhcp[0] = 1
	dhcp[1] = 1
	dhcp[2] = 6
	copy(dhcp[28:34], p.mac)
	if !p.allow(b) {
		t.Fatal("DHCP unavailable")
	}
	dhcp[28] ^= 1
	if p.allow(b) {
		t.Fatal("accepted another guest's DHCP identity")
	}
}

func TestBootstrapAndOfflineNeverOpenRouterServices(t *testing.T) {
	p := testPolicy()
	p.offline = true
	if p.allow(packet(p, gateway.String(), 53)) {
		t.Fatal("offline mode allowed DNS")
	}
	p.bootstrap = true
	b := packet(p, gateway.String(), 43000)
	binary.BigEndian.PutUint16(b[34:36], 22)
	if p.allow(b) {
		t.Fatal("guest initiated router connection accepted")
	}
	p.bootstrapPeers.Store(uint16(43000), true)
	if !p.allow(b) {
		t.Fatal("host-initiated SSH reply blocked")
	}
	p.bootstrap = false
	if p.allow(b) {
		t.Fatal("bootstrap allowance survived its phase")
	}
}
