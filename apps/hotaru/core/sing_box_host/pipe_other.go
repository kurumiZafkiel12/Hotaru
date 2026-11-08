//go:build !windows

package main

import (
	"context"
	"errors"
)

func runPipe(context.Context, string) error {
	return errors.New("host named pipe transport requires Windows")
}
