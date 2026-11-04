package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"runtime/debug"
	"strings"
	"syscall"

	box "github.com/sagernet/sing-box"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/experimental/deprecated"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	boxJSON "github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
)

const controlProtocol = "hotaru-stdio-v1"

type engine interface {
	Start() error
	Close() error
}

type engineFactory func(context.Context, string) (engine, error)

type hostEvent struct {
	Protocol string `json:"protocol"`
	Event    string `json:"event"`
	PID      int    `json:"pid"`
	Clean    bool   `json:"clean,omitempty"`
}

func emit(output io.Writer, event string, clean bool) error {
	return json.NewEncoder(output).Encode(hostEvent{
		Protocol: controlProtocol, Event: event, PID: os.Getpid(), Clean: clean,
	})
}

func readStop(input io.Reader) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 64), 512)
	if scanner.Scan() {
		if scanner.Text() != "stop" {
			return errors.New("invalid host control command")
		}
		return nil
	}
	return scanner.Err()
}

func serve(parent context.Context, configPath string, input io.Reader, output io.Writer, create engineFactory) (result error) {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	clean := false
	defer func() { result = errors.Join(result, emit(output, "stopped", clean)) }()
	control := make(chan error, 1)
	go func() {
		err := readStop(input)
		control <- err
		cancel()
	}()
	instance, err := create(ctx, configPath)
	if err != nil {
		clean = true
		return err
	}
	defer func() {
		clean = false
		err := instance.Close()
		clean = err == nil
		result = errors.Join(result, err)
	}()
	if err = instance.Start(); err != nil {
		return err
	}
	if ctx.Err() == nil {
		if err = emit(output, "ready", false); err != nil {
			return err
		}
	}
	<-ctx.Done()
	select {
	case err = <-control:
		return err
	default:
		return nil
	}
}

func newEngine(ctx context.Context, path string) (engine, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return newEngineConfig(ctx, content)
}

func newEngineConfig(ctx context.Context, content []byte) (engine, error) {
	ctx = include.Context(service.ContextWith(ctx, deprecated.NewStderrManager(log.StdLogger())))
	options, err := boxJSON.UnmarshalExtendedContext[option.Options](ctx, content)
	if err != nil {
		return nil, err
	}
	if options.Log != nil && options.Log.Output != "" {
		return nil, errors.New("host logging is managed by the client")
	}
	return box.New(box.Options{Context: ctx, Options: options})
}

func pinnedVersion() (string, error) {
	info, ok := debug.ReadBuildInfo()
	if ok {
		for _, dependency := range info.Deps {
			if dependency.Path == "github.com/sagernet/sing-box" &&
				dependency.Version == "v1.14.4" && dependency.Replace == nil {
				return strings.TrimPrefix(dependency.Version, "v"), nil
			}
		}
	}
	return "", errors.New("host requires the pinned, unreplaced sing-box v1.14.4 module")
}

func command(args []string) error {
	version, err := pinnedVersion()
	if err != nil {
		return err
	}
	C.Version = version
	if len(args) == 1 && strings.HasPrefix(args[0], `\\.\pipe\`) {
		ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer cancel()
		return runPipe(ctx, args[0])
	}
	if len(args) == 1 && args[0] == "version" {
		fmt.Printf("sing-box version %s\nHost control: %s\n", version, controlProtocol)
		return nil
	}
	if len(args) == 0 || args[0] != "run" && args[0] != "check" {
		return errors.New("usage: hotaru-box-host version | check -c <path> | run -c <path> --stdio-control")
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	var configPath string
	var control bool
	flags.StringVar(&configPath, "c", "", "compiled configuration path")
	flags.BoolVar(&control, "stdio-control", false, "enable owned-parent lifecycle control")
	if err = flags.Parse(args[1:]); err != nil {
		return err
	}
	if configPath == "" || flags.NArg() != 0 {
		return errors.New("a compiled configuration path is required")
	}
	if args[0] == "check" {
		instance, err := newEngine(context.Background(), configPath)
		if err != nil {
			return err
		}
		return instance.Close()
	}
	if !control {
		return errors.New("run requires --stdio-control")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	return serve(ctx, configPath, os.Stdin, os.Stdout, newEngine)
}

func main() {
	if err := command(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
