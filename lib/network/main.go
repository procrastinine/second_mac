package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"flag"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/containers/gvisor-tap-vsock/pkg/types"
	"github.com/containers/gvisor-tap-vsock/pkg/virtualnetwork"
)

var guest = netip.MustParseAddr("192.168.127.2")
var gateway = netip.MustParseAddr("192.168.127.1")

type filtered struct {
	net.Conn
	mac            net.HardwareAddr
	blocks         []netip.Prefix
	offline        bool
	bootstrap      bool
	bootstrapPeers sync.Map
}

func addr(b []byte) netip.Addr { return netip.AddrFrom4([4]byte{b[0], b[1], b[2], b[3]}) }
func (c *filtered) allow(b []byte) bool {
	if len(b) < 14 || !bytes.Equal(b[6:12], c.mac) {
		return false
	}
	switch binary.BigEndian.Uint16(b[12:14]) {
	case 0x806:
		return len(b) >= 42 && binary.BigEndian.Uint16(b[14:16]) == 1 && binary.BigEndian.Uint16(b[16:18]) == 0x800 && b[18] == 6 && b[19] == 4 && (b[21] == 1 || b[21] == 2) && b[20] == 0 && bytes.Equal(b[22:28], c.mac) && (addr(b[28:32]) == guest || addr(b[28:32]).IsUnspecified()) && (addr(b[38:42]) == gateway || addr(b[38:42]) == guest)
	case 0x800:
		if len(b) < 34 || b[14] != 0x45 {
			return false
		}
		ip := b[14:]
		n := int(binary.BigEndian.Uint16(ip[2:4]))
		if n < 20 || n > len(ip) {
			return false
		}
		ip = ip[:n]
		src, dst := addr(ip[12:16]), addr(ip[16:20])
		proto := ip[9]
		fragment := binary.BigEndian.Uint16(ip[6:8])&0x3fff != 0
		if proto == 17 && !fragment && len(ip) >= 28 && binary.BigEndian.Uint16(ip[20:22]) == 68 && binary.BigEndian.Uint16(ip[22:24]) == 67 && (dst == gateway || dst == netip.MustParseAddr("255.255.255.255")) {
			dhcp := ip[28:]
			return len(dhcp) >= 240 && dhcp[0] == 1 && dhcp[1] == 1 && dhcp[2] == 6 && bytes.Equal(dhcp[28:34], c.mac)
		}
		if src != guest {
			return false
		}
		if dst == gateway {
			if fragment || len(ip) < 28 {
				return false
			}
			if c.bootstrap && proto == 6 && len(ip) >= 40 && binary.BigEndian.Uint16(ip[20:22]) == 22 {
				_, expected := c.bootstrapPeers.Load(binary.BigEndian.Uint16(ip[22:24]))
				return expected
			}
			return !c.offline && (proto == 6 || proto == 17) && binary.BigEndian.Uint16(ip[22:24]) == 53
		}
		if !dst.IsGlobalUnicast() || dst.IsPrivate() || dst.As4()[0] == 0 {
			return false
		}
		for _, p := range c.blocks {
			if p.Contains(dst) {
				return false
			}
		}
		return proto == 6 || proto == 17
	}
	return false
}

// Bootstrap SSH is host-initiated and loopback-only. Permit replies only to a
// SYN actually emitted by that forwarder, never arbitrary router connections.
func (c *filtered) Write(b []byte) (int, error) {
	if c.bootstrap && len(b) >= 54 && b[12] == 8 && b[13] == 0 && b[14] == 0x45 && b[23] == 6 {
		ip := b[14:]
		if addr(ip[12:16]) == gateway && addr(ip[16:20]) == guest && binary.BigEndian.Uint16(ip[22:24]) == 22 && ip[33]&0x12 == 2 {
			c.bootstrapPeers.Store(binary.BigEndian.Uint16(ip[20:22]), true)
		}
	}
	return c.Conn.Write(b)
}
func (c *filtered) Read(b []byte) (int, error) {
	for {
		n, e := c.Conn.Read(b)
		if e != nil {
			return n, e
		}
		if c.allow(b[:n]) {
			return n, nil
		}
	}
}

func run() error {
	fd := flag.Int("vm-fd", -1, "Tart network descriptor")
	macText := flag.String("vm-mac-address", "", "Tart hardware address")
	blocks := flag.String("block", "", "restricted destinations")
	allow := flag.String("allow", "", "bootstrap input")
	flag.Parse()
	if *fd < 0 || (*allow != "" && *allow != "in @host") {
		return fmt.Errorf("unsupported network arguments")
	}
	mac, e := net.ParseMAC(*macText)
	if e != nil || len(mac) != 6 {
		return fmt.Errorf("expected a six-byte MAC address")
	}
	f := os.NewFile(uintptr(*fd), "network")
	conn, e := net.FileConn(f)
	f.Close()
	if e != nil {
		return e
	}
	defer conn.Close()
	policy := &filtered{Conn: conn, mac: mac, bootstrap: *allow != ""}
	for _, b := range []string{"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4"} {
		policy.blocks = append(policy.blocks, netip.MustParsePrefix(b))
	}
	interfaces, e := net.Interfaces()
	if e != nil {
		return e
	}
	for _, iface := range interfaces {
		addresses, e := iface.Addrs()
		if e != nil {
			return e
		}
		for _, a := range addresses {
			p, e := netip.ParsePrefix(a.String())
			if e != nil || !p.Addr().Is4() {
				continue
			}
			policy.blocks = append(policy.blocks, netip.PrefixFrom(p.Addr(), 32))
			if iface.Flags&net.FlagPointToPoint == 0 && p.Bits() > 0 {
				policy.blocks = append(policy.blocks, p.Masked())
			}
		}
	}
	for _, b := range strings.Split(*blocks, ",") {
		b = strings.TrimPrefix(b, "out ")
		if b == "@host" || b == "" {
			continue
		}
		p, e := netip.ParsePrefix(b)
		if e != nil {
			return e
		}
		policy.blocks = append(policy.blocks, p)
		if p.Bits() == 0 {
			policy.offline = true
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	parent := os.Getppid()
	go func() {
		t := time.NewTicker(time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				conn.Close()
				return
			case <-t.C:
				if os.Getppid() != parent {
					os.Exit(0)
				}
			}
		}
	}()
	forwards := map[string]string{}
	if *allow != "" {
		port, e := strconv.Atoi(os.Getenv("SECOND_MAC_BOOTSTRAP_PORT"))
		if e != nil || port < 1024 || port > 65535 {
			return fmt.Errorf("missing private bootstrap port")
		}
		forwards[net.JoinHostPort("127.0.0.1", strconv.Itoa(port))] = net.JoinHostPort(guest.String(), "22")
	}
	v, e := virtualnetwork.New(&types.Configuration{MTU: 1500, Subnet: "192.168.127.0/24", GatewayIP: gateway.String(), GatewayMacAddress: "5a:94:ef:e4:0c:01", DHCPStaticLeases: map[string]string{guest.String(): mac.String()}, Forwards: forwards})
	if e != nil {
		return e
	}
	fmt.Fprintln(os.Stderr, "Private userspace networking ready")
	e = v.AcceptVfkit(ctx, policy)
	if ctx.Err() != nil {
		return nil
	}
	return e
}
func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
