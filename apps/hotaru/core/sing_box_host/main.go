package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"runtime/debug"
	"sort"
	"strings"
	"sync/atomic"
	"syscall"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/trafficcontrol"
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
	Protocol string         `json:"protocol"`
	Event    string         `json:"event"`
	PID      int            `json:"pid"`
	Clean    bool           `json:"clean,omitempty"`
	Totals   *trafficTotals `json:"totals,omitempty"`
	Features []string       `json:"features,omitempty"`
}

func emitReady(output io.Writer, instance engine) error {
	event := hostEvent{Protocol: controlProtocol, Event: "ready", PID: os.Getpid()}
	if _, ok := instance.(telemetrySource); ok {
		event.Features = append(event.Features, "telemetry")
	}
	if _, ok := instance.(runtimeMaintenanceSource); ok {
		methods := make([]string, 0, len(runtimeMaintenanceMethods))
		for method := range runtimeMaintenanceMethods {
			methods = append(methods, method)
		}
		sort.Strings(methods)
		event.Features = append(event.Features, methods...)
	}
	return json.NewEncoder(output).Encode(event)
}

func emit(output io.Writer, event string, clean bool) error {
	return json.NewEncoder(output).Encode(hostEvent{
		Protocol: controlProtocol, Event: event, PID: os.Getpid(), Clean: clean,
	})
}

func emitStopped(output io.Writer, clean bool, instance engine) error {
	event := hostEvent{Protocol: controlProtocol, Event: "stopped", PID: os.Getpid(), Clean: clean}
	if source, ok := instance.(interface{ FinalTraffic() *trafficTotals }); clean && ok {
		event.Totals = source.FinalTraffic()
	}
	return json.NewEncoder(output).Encode(event)
}

func readControl(input io.Reader, output io.Writer, source func() telemetrySource) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 64), 512)
	for scanner.Scan() {
		if scanner.Text() == "stop" {
			return nil
		}
		var command struct {
			Method string `json:"method"`
			ID     uint32 `json:"id"`
		}
		decoder := json.NewDecoder(bytes.NewReader(scanner.Bytes()))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&command) != nil || decoder.Decode(new(any)) != io.EOF ||
			(command.Method != "telemetry" && runtimeMaintenanceMethods[command.Method] == nil) || command.ID == 0 || output == nil {
			return errors.New("invalid host control command")
		}
		observed := source()
		if command.Method != "telemetry" {
			observed = maintenanceObservation{source: observed, method: command.Method}
		}
		if err := emitTelemetry(output, command.ID, observed); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func serve(parent context.Context, configPath string, input io.Reader, output io.Writer, create engineFactory) (result error) {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	output = &synchronizedWriter{Writer: output}
	var running atomic.Bool
	var instance engine
	clean := false
	defer func() { result = errors.Join(result, emitStopped(output, clean, instance)) }()
	control := make(chan error, 1)
	go func() {
		err := readControl(input, output, func() telemetrySource {
			if !running.Load() {
				return nil
			}
			source, _ := instance.(telemetrySource)
			return source
		})
		control <- err
		cancel()
	}()
	var err error
	instance, err = create(ctx, configPath)
	if err != nil {
		clean = true
		return err
	}
	defer func() {
		running.Store(false)
		clean = false
		err := instance.Close()
		clean = err == nil
		result = errors.Join(result, err)
	}()
	if err = instance.Start(); err != nil {
		return err
	}
	if ctx.Err() == nil {
		running.Store(true)
		if err = emitReady(output, instance); err != nil {
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
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		return nil, err
	}
	processes := newProcessTraffic()
	instance.Router().AppendTracker(processes)
	return &observedEngine{Box: instance, traffic: service.PtrFromContext[trafficcontrol.Manager](ctx), dns: service.FromContext[adapter.DNSRouter](ctx), processes: processes}, nil
}

const coreForkPath = "github.com/kurumiZafkiel12/Hotaru-Core"
const coreForkVersion = "v1.14.4-hotaru.1"
const coreForkSum = "h1:0dmxgd3DJyrmKhiYllipXJ0BO7WHCJUnOMZgIpqiopM="

func validPinnedModule(module *debug.Module) bool {
	if module == nil || module.Path != "github.com/sagernet/sing-box" || module.Version != "v1.14.4" {
		return false
	}
	replacement := module.Replace
	return replacement != nil && replacement.Path == coreForkPath && replacement.Version == coreForkVersion &&
		replacement.Sum == coreForkSum && replacement.Replace == nil
}

func pinnedVersion() (string, error) {
	info, ok := debug.ReadBuildInfo()
	if ok {
		for _, dependency := range info.Deps {
			if validPinnedModule(dependency) {
				return strings.TrimPrefix(dependency.Version, "v"), nil
			}
		}
	}
	return "", errors.New("host requires the pinned Hotaru-Core source for sing-box v1.14.4")
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
