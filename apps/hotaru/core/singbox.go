package core

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

// The data plane is sing-box, full stop: the listeners and the TUN device
// belong to a sing-box child process configured from the same effective
// config the core builds for profile parsing. Mihomo never binds a port
// and never carries traffic in this build — if sing-box cannot start, the
// connection fails openly instead of falling back. Selections, delay
// tests and traffic all read from sing-box, so what the UI reports is
// what actually carries the user's traffic.

const (
	sbControllerAddr = "127.0.0.1:19090"
	sbBinaryName     = "sing-box"
)

var (
	sbMu       sync.Mutex
	sbCancel   context.CancelFunc
	sbDone     chan struct{}
	sbIsUp     atomic.Bool
	sbRateUp   atomic.Int64
	sbRateDown atomic.Int64
	sbTotalUp  atomic.Int64
	sbTotalDn  atomic.Int64
)

func sbConfigPath() string {
	return filepath.Join(constant.Path.HomeDir(), "singbox.json")
}

func sbSecret() string {
	path := filepath.Join(constant.Path.HomeDir(), "singbox-secret.txt")
	if buf, err := os.ReadFile(path); err == nil {
		if secret := strings.TrimSpace(string(buf)); secret != "" {
			return secret
		}
	}
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "hotaru-beta"
	}
	secret := hex.EncodeToString(buf)
	_ = os.WriteFile(path, []byte(secret), 0o600)
	return secret
}

func sbBinaryPath() (string, error) {
	if path := os.Getenv("HOTARU_SINGBOX_PATH"); path != "" {
		return path, nil
	}
	name := sbBinaryName
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	if exe, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(exe), name)
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}
	if path, err := exec.LookPath(sbBinaryName); err == nil {
		return path, nil
	}
	return "", fmt.Errorf("%s not found beside the core executable or on PATH", name)
}

func sbBuildConfig() error {
	raw, err := os.ReadFile(runningConfigPath())
	if err != nil {
		return err
	}
	doc, warnings, err := translateSingBoxConfig(raw)
	if err != nil {
		return fmt.Errorf("translate config for sing-box: %w", err)
	}
	for _, warning := range warnings {
		log.Warnln("[sing-box] %s", warning)
	}
	doc["experimental"] = map[string]any{
		"clash_api": map[string]any{
			"external_controller": sbControllerAddr,
			"secret":              sbSecret(),
		},
		"cache_file": map[string]any{
			"enabled": true,
			"path":    filepath.Join(constant.Path.HomeDir(), "singbox-cache.db"),
		},
	}
	buf, err := json.Marshal(doc)
	if err != nil {
		return err
	}
	return os.WriteFile(sbConfigPath(), buf, 0o644)
}

func sbRequest(ctx context.Context, method, path string, body io.Reader) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, "http://"+sbControllerAddr+path, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+sbSecret())
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return http.DefaultClient.Do(req)
}

func sbWaitReady(ctx context.Context) error {
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return errors.New("sing-box exited during startup")
		default:
		}
		pollCtx, cancel := context.WithTimeout(ctx, time.Second)
		resp, err := sbRequest(pollCtx, http.MethodGet, "/version", nil)
		cancel()
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("sing-box clash_api did not come up within 10s")
}

func startSingBox() {
	sbMu.Lock()
	defer sbMu.Unlock()
	if sbIsUp.Load() {
		return
	}
	if err := sbBuildConfig(); err != nil {
		logError("[sing-box] %v", err)
		return
	}
	binary, err := sbBinaryPath()
	if err != nil {
		logError("[sing-box] %v", err)
		return
	}
	logFile, err := os.OpenFile(
		filepath.Join(constant.Path.HomeDir(), "singbox.log"),
		os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644,
	)
	if err != nil {
		logError("[sing-box] open log: %v", err)
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, binary, "run", "-c", sbConfigPath(),
		"-D", constant.Path.HomeDir())
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		cancel()
		_ = logFile.Close()
		logError("[sing-box] start: %v", err)
		return
	}
	done := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		_ = logFile.Close()
		close(done)
	}()
	sbCancel = cancel
	sbDone = done
	if err := sbWaitReady(ctx); err != nil {
		logError("[sing-box] %v (see singbox.log)", err)
		cancel()
		<-done
		sbCancel = nil
		sbDone = nil
		return
	}
	sbIsUp.Store(true)
	go sbWatchTraffic(ctx)
	log.Infoln("[sing-box] data plane up (controller %s)", sbControllerAddr)
}

func stopSingBox() {
	sbMu.Lock()
	defer sbMu.Unlock()
	if sbCancel == nil {
		return
	}
	sbCancel()
	if sbDone != nil {
		<-sbDone
	}
	sbCancel = nil
	sbDone = nil
	sbIsUp.Store(false)
	sbRateUp.Store(0)
	sbRateDown.Store(0)
}

func restartSingBox(selections map[string]string) {
	stopSingBox()
	startSingBox()
	if sbIsUp.Load() {
		sbApplySelections(selections)
		return
	}
	logError("[sing-box] data plane is down after config apply — no listener is serving (there is no mihomo fallback)")
}

// The GLOBAL group is excluded: sing-box synthesizes its own, and the
// route final already points at the profile's top group.
func sbSelectionsFromState() map[string]string {
	selections := map[string]string{}
	for name, proxy := range tunnel.AllProxies() {
		if name == globalProxyName {
			continue
		}
		if selector, ok := adapterAs[pickableGroup](proxy); ok {
			selections[name] = selector.Now()
		}
	}
	return selections
}

func sbApplySelections(selections map[string]string) {
	for group, name := range selections {
		if err := sbChangeProxy(group, name); err != nil {
			log.Warnln("[sing-box] apply selection %s -> %s: %v", group, name, err)
		}
	}
}

// sbOutboundName maps the two mihomo built-ins to the tags the translator
// gives them in the sing-box document; every other name is already a tag.
func sbOutboundName(name string) string {
	switch name {
	case "DIRECT":
		return "direct"
	case "REJECT":
		return "block"
	}
	return name
}

func sbChangeProxy(group, name string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	payload, _ := json.Marshal(map[string]string{"name": sbOutboundName(name)})
	resp, err := sbRequest(ctx, http.MethodPut,
		"/proxies/"+url.PathEscape(group), strings.NewReader(string(payload)))
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusOK {
		buf, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("status %d: %s", resp.StatusCode, strings.TrimSpace(string(buf)))
	}
	return nil
}

var errSBTimeout = errors.New("timeout")

func sbTestDelay(name, testURL string, timeout time.Duration) (int32, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout+2*time.Second)
	defer cancel()
	query := url.Values{
		"url":     {testURL},
		"timeout": {fmt.Sprintf("%d", timeout.Milliseconds())},
	}
	resp, err := sbRequest(ctx, http.MethodGet,
		"/proxies/"+url.PathEscape(sbOutboundName(name))+"/delay?"+query.Encode(), nil)
	if err != nil {
		return 0, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode == http.StatusGatewayTimeout {
		return 0, errSBTimeout
	}
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("delay endpoint status %d", resp.StatusCode)
	}
	var result struct {
		Delay int32 `json:"delay"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return 0, err
	}
	return result.Delay, nil
}

func sbWatchTraffic(ctx context.Context) {
	resp, err := sbRequest(ctx, http.MethodGet, "/traffic", nil)
	if err != nil {
		return
	}
	defer func() { _ = resp.Body.Close() }()
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 64*1024), 64*1024)
	for scanner.Scan() {
		var line struct {
			Up   int64 `json:"up"`
			Down int64 `json:"down"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &line); err != nil {
			continue
		}
		sbRateUp.Store(line.Up)
		sbRateDown.Store(line.Down)
		sbTotalUp.Add(line.Up)
		sbTotalDn.Add(line.Down)
	}
}
