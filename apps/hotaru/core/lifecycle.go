package core

import (
	"runtime"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

var (
	isInit     atomic.Bool
	isRunning  atomic.Bool
	sdkVersion atomic.Int32
)

func handleInitClash(params *InitParams) bool {
	configMu.Lock()
	defer configMu.Unlock()
	sdkVersion.Store(int32(params.Version))
	constant.SetHomeDir(params.HomeDir)
	initOwnership(params.HomeDir)
	clearSpilledResponses()
	isInit.Store(true)
	return true
}

func handleGetIsInit() bool {
	return isInit.Load()
}

func handleStartListener() bool {
	configMu.Lock()
	defer configMu.Unlock()
	isRunning.Store(true)
	// A probe already out belongs to the previous attempt's routes, so its
	// answer must not stand for this one — even if this attempt goes on to
	// fail, which in this build it openly can.
	bumpRouteEpoch()
	startSingBox()
	if !sbIsUp.Load() {
		// No fallback: a failed sing-box start is a failed connection,
		// reported as such instead of being covered by mihomo listeners.
		isRunning.Store(false)
		return false
	}
	sbApplySelections(sbSelectionsFromState())
	updateListeners(currentConfig)
	resolver.ResetConnection()
	return true
}

func handleStopListener() bool {
	stopSingBox()
	configMu.Lock()
	defer configMu.Unlock()
	isRunning.Store(false)
	listener.StopListener()
	resolver.ResetConnection()
	return true
}

func updateListeners(cfg *config.Config) {
	if cfg == nil || !isRunning.Load() {
		return
	}
	// Pure sing-box data plane: sing-box owns every port and the TUN
	// device. Mihomo binds nothing here, ever — there is no fallback.
}

func handleShutdown() bool {
	handleStopLog()
	stopRouteWatch()
	stopSingBox()

	configMu.Lock()
	isRunning.Store(false)
	listener.StopListener()
	updater.StopGeoUpdater()
	executor.Shutdown()
	currentConfig = nil
	isInit.Store(false)
	configMu.Unlock()

	handleForceGC()
	return true
}

func handleForceGC() {
	tunnel.InvalidateAllProxies()
	debug.FreeOSMemory()
}

// mihomo loads providers without waiting for them, so its own GC misses their decode buffers.
var (
	loadReleaseDelay  = 2 * time.Second
	releaseLoadMemory = debug.FreeOSMemory

	loadReleaseMu    sync.Mutex
	loadReleaseTimer *time.Timer
)

func scheduleLoadMemoryRelease() {
	loadReleaseMu.Lock()
	defer loadReleaseMu.Unlock()
	if loadReleaseTimer == nil {
		loadReleaseTimer = time.AfterFunc(loadReleaseDelay, func() { releaseLoadMemory() })
		return
	}
	loadReleaseTimer.Reset(loadReleaseDelay)
}

// HeapIdle still counts spans the runtime has already handed back to the OS,
// so the retained-but-unused figure subtracts HeapReleased.
func handleGetMemoryStats() MemoryStats {
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	return MemoryStats{
		Rss:          statistic.DefaultManager.Memory(),
		HeapInuse:    stats.HeapInuse,
		HeapIdle:     stats.HeapIdle - stats.HeapReleased,
		StackInuse:   stats.StackInuse,
		RuntimeOther: stats.MSpanInuse + stats.MCacheInuse + stats.BuckHashSys + stats.GCSys + stats.OtherSys,
	}
}
