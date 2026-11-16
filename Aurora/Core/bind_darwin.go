//go:build darwin

package corebridge

import (
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

// interfaceControl binds a socket to the named interface (IP_BOUND_IF), so
// it leaves through that interface even while a VPN owns the default route.
func interfaceControl(name string) func(network, address string, c syscall.RawConn) error {
	if name == "" {
		return nil
	}
	return func(network, address string, c syscall.RawConn) error {
		iface, err := net.InterfaceByName(name)
		if err != nil {
			return err
		}
		var serr error
		err = c.Control(func(fd uintptr) {
			switch network {
			case "tcp6", "udp6":
				serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, iface.Index)
			default:
				serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, iface.Index)
			}
		})
		if err != nil {
			return err
		}
		return serr
	}
}
