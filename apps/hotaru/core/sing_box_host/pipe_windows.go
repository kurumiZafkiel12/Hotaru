package main

import (
	"context"
	"errors"
	"os"
	"regexp"
	"time"

	"golang.org/x/sys/windows"
)

func runPipe(ctx context.Context, address string) error {
	if !regexp.MustCompile(`^\\\\\.\\pipe\\HotaruCore_[0-9a-f]{32}$`).MatchString(address) {
		return errors.New("invalid host pipe namespace")
	}
	path, err := windows.UTF16PtrFromString(address)
	if err != nil {
		return err
	}
	deadline := time.Now().Add(10 * time.Second)
	var pipe *os.File
	for {
		handle, openErr := windows.CreateFile(path, windows.GENERIC_READ|windows.GENERIC_WRITE,
			0, nil, windows.OPEN_EXISTING,
			windows.FILE_FLAG_OVERLAPPED|windows.SECURITY_SQOS_PRESENT|windows.SECURITY_IDENTIFICATION, 0)
		if openErr == nil {
			pipe = os.NewFile(uintptr(handle), address)
			break
		}
		if !errors.Is(openErr, windows.ERROR_PIPE_BUSY) && !errors.Is(openErr, windows.ERROR_FILE_NOT_FOUND) {
			return openErr
		}
		if time.Now().After(deadline) {
			return errors.New("host pipe connection timed out")
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
	defer pipe.Close()
	if err = pipe.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		return err
	}
	config, err := readBootstrap(pipe)
	if err != nil {
		return err
	}
	if err = pipe.SetDeadline(time.Time{}); err != nil {
		return err
	}
	return serveFramed(ctx, config, pipe, newEngineConfig)
}
