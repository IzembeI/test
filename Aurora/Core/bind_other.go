//go:build !darwin

package corebridge

import "syscall"

// interfaceControl is only needed on Apple platforms; elsewhere tests use
// the default route.
func interfaceControl(name string) func(network, address string, c syscall.RawConn) error {
	return nil
}
