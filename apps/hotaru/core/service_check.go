package core

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/http"
)

const (
	// A sweep runs a few checks at a time so it cannot take every probe slot.
	// It therefore runs in waves, and a rule like Disney+ spends several
	// requests in sequence, so the run gets a multiple of the request budget.
	serviceCheckConcurrency  = 4
	serviceSweepBudgetFactor = 24

	// Region markers sit deep inside these pages; endpoints that answer with a
	// few lines get the small cap.
	serviceHtmlMaxBody  = 512 * 1024
	serviceSmallMaxBody = 16 * 1024

	// Gemini's region sits past 800 KiB, Prime Video's at times past 4 MiB.
	serviceScanMaxBody = 8 * 1024 * 1024
)

// Statuses a check reports. Dart maps each to a localized label, so these
// strings are part of the contract and cannot be reworded on one side alone.
const (
	serviceAvailable         = "available"
	serviceUnavailable       = "unavailable"
	serviceRestricted        = "restricted"
	serviceDisallowedIsp     = "disallowed-isp"
	serviceBlocked           = "blocked"
	serviceUnsupportedRegion = "unsupported-region"
	serviceOriginalsOnly     = "originals-only"
	serviceComingSoon        = "coming-soon"
	serviceTimeout           = "timeout"
	serviceFailed            = "failed"
	serviceReachable         = "reachable"
	serviceAuthentication    = "authentication-required"
	serviceChallenge         = "challenge"
	serviceInconclusive      = "inconclusive"
)

// An empty Names runs every check.
type ServiceCheckParams struct {
	ProxyName string   `json:"proxy-name"`
	Names     []string `json:"names"`
	Timeout   int64    `json:"timeout"`
	RunID     string   `json:"run-id"`
	Cancel    bool     `json:"cancel"`
}

// runServiceCheck stamps Name; a blank Status means a rule has yet to judge it.
type ServiceCheckItem struct {
	Name         string               `json:"name"`
	Status       string               `json:"status"`
	Region       string               `json:"region,omitempty"`
	Delay        int64                `json:"delay,omitempty"`
	Chains       []string             `json:"chains,omitempty"`
	CheckedAt    int64                `json:"checked-at"`
	CoreEpoch    uint64               `json:"core-epoch"`
	RouteVersion uint64               `json:"route-version"`
	Hits         []RouteHit           `json:"hits,omitempty"`
	Observations []ServiceObservation `json:"observations,omitempty"`
}

type ServiceObservation struct {
	URL         string   `json:"url"`
	StatusCode  int      `json:"status-code"`
	Rule        string   `json:"rule"`
	RulePayload string   `json:"rule-payload"`
	Chains      []string `json:"chains"`
	Error       string   `json:"error,omitempty"`
}

var (
	serviceCheckSlots = make(slots, serviceCheckConcurrency)

	serviceClaimsMu  sync.Mutex
	serviceClaims    = map[string]*context.CancelFunc{}
	serviceRunsMu    sync.Mutex
	serviceRuns      = map[string]*serviceRun{}
	serviceCancelled = map[string]time.Time{}
)

type serviceRun struct {
	ctx    context.Context
	cancel context.CancelFunc
	users  int
}

func acquireServiceRun(id string) (context.Context, func()) {
	if id == "" {
		return context.Background(), func() {}
	}
	serviceRunsMu.Lock()
	if cancelledAt, ok := serviceCancelled[id]; ok {
		if time.Since(cancelledAt) <= defaultProbeTimeout*serviceSweepBudgetFactor {
			serviceRunsMu.Unlock()
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			return ctx, func() {}
		}
		delete(serviceCancelled, id)
	}
	run := serviceRuns[id]
	if run == nil {
		ctx, cancel := context.WithCancel(context.Background())
		run = &serviceRun{ctx: ctx, cancel: cancel}
		serviceRuns[id] = run
	}
	run.users++
	serviceRunsMu.Unlock()
	return run.ctx, func() {
		serviceRunsMu.Lock()
		defer serviceRunsMu.Unlock()
		run.users--
		if run.users == 0 {
			run.cancel()
			delete(serviceRuns, id)
		}
	}
}

func cancelServiceRun(id string) {
	if id == "" {
		return
	}
	serviceRunsMu.Lock()
	defer serviceRunsMu.Unlock()
	if len(serviceCancelled) >= 128 {
		var oldest string
		var oldestAt time.Time
		for key, at := range serviceCancelled {
			if oldestAt.IsZero() || at.Before(oldestAt) {
				oldest, oldestAt = key, at
			}
		}
		delete(serviceCancelled, oldest)
	}
	serviceCancelled[id] = time.Now()
	if run := serviceRuns[id]; run != nil {
		run.cancel()
	}
}

type serviceEnv struct {
	ctx          context.Context
	proxyName    string
	timeout      time.Duration
	hits         *hitRecorder
	observations *[]ServiceObservation
}

func (e serviceEnv) get(url string, maxBody int64) *ProbeResult {
	return e.send(probeRequest{method: http.MethodGet, url: url, maxBody: maxBody})
}

func (e serviceEnv) scan(url string, until func(tail string) bool) *ProbeResult {
	return e.send(probeRequest{method: http.MethodGet, url: url, maxBody: serviceScanMaxBody, until: until})
}

func (e serviceEnv) send(req probeRequest) *ProbeResult {
	req.proxyName = e.proxyName
	req.timeout = e.timeout
	req.recorder = e.hits
	headers := map[string]string{"User-Agent": browserUserAgent}
	for name, value := range req.headers {
		headers[name] = value
	}
	req.headers = headers
	result := runProbe(e.ctx, req)
	if result != nil && e.observations != nil {
		*e.observations = append(*e.observations, ServiceObservation{
			URL: result.Url, StatusCode: result.StatusCode, Rule: result.Rule,
			RulePayload: result.RulePayload, Chains: result.Chains, Error: result.Error,
		})
	}
	return result
}

type serviceChecker struct {
	name  string
	check func(serviceEnv) ServiceCheckItem
}

var serviceCheckers = []serviceChecker{
	{name: "google", check: checkServiceEndpoint("https://workspace.google.com/")},
	{name: "github", check: checkGitHub},
	{name: "youtube", check: checkYouTubePremium},
	{name: "chatgpt", check: checkChatGpt},
	{name: "claude", check: checkClaude},
	{name: "gemini", check: checkGemini},
	{name: "netflix", check: checkNetflix},
	{name: "disney-plus", check: checkDisneyPlus},
	{name: "prime-video", check: checkPrimeVideo},
	{name: "spotify", check: checkSpotify},
	{name: "tiktok", check: checkTikTok},
	{name: "discord", check: checkDiscord},
	{name: "bilibili", check: checkBilibili},
}

func handleServiceCheck(params *ServiceCheckParams) []ServiceCheckItem {
	if params.Cancel {
		cancelServiceRun(params.RunID)
		return []ServiceCheckItem{}
	}
	parent, releaseRun := acquireServiceRun(params.RunID)
	defer releaseRun()
	wanted := selectedCheckers(params.Names)
	items := make([]ServiceCheckItem, len(wanted))
	if len(wanted) == 0 {
		return items
	}

	timeout := timeoutFromMillis(params.Timeout, defaultProbeTimeout)
	ctx, cancel := context.WithTimeout(parent, timeout*serviceSweepBudgetFactor)
	defer cancel()

	// Claimed before queueing, so a check waiting for a slot is cancelled the
	// moment its service is asked again.
	contexts, release := claimServices(ctx, wanted)
	defer release()
	var running sync.WaitGroup
	for index, checker := range wanted {
		granted := serviceCheckSlots.acquire(contexts[index])
		running.Add(1)
		go func(index int, checker serviceChecker) {
			defer running.Done()
			if granted {
				defer serviceCheckSlots.release()
			}
			items[index] = runServiceCheck(contexts[index], checker, params.ProxyName, timeout)
		}(index, checker)
	}
	running.Wait()
	return items
}

// A misbehaving rule must not take the sweep down with it.
func runServiceCheck(ctx context.Context, checker serviceChecker, proxyName string, timeout time.Duration) (item ServiceCheckItem) {
	epoch, version := routeStamp()
	hits := &hitRecorder{}
	observations := []ServiceObservation{}
	item = ServiceCheckItem{Status: serviceFailed}
	defer func() {
		if recovered := recover(); recovered != nil {
			item = ServiceCheckItem{Status: serviceFailed}
		}
		item.Name = checker.name
		item.CheckedAt = time.Now().UnixMilli()
		item.CoreEpoch = epoch
		item.RouteVersion = version
		item.Hits = hits.list()
		item.Observations = observations
	}()
	if ctx.Err() != nil {
		return item
	}
	env := serviceEnv{ctx: ctx, proxyName: proxyName, timeout: timeout, hits: hits, observations: &observations}
	item = checker.check(env)
	if item.Status == serviceTimeout && hasBudget(ctx, timeout) {
		item = checker.check(env)
	}
	return item
}

// The host asks for a service again only once the older answer can no longer
// be used, so a newer check cancels the older one and frees its probe slots.
func claimServices(parent context.Context, checkers []serviceChecker) ([]context.Context, func()) {
	contexts := make([]context.Context, len(checkers))
	claimed := make(map[string]context.Context, len(checkers))
	var releases []func()
	for index, checker := range checkers {
		ctx, ok := claimed[checker.name]
		if !ok {
			var release func()
			ctx, release = claimService(parent, checker.name)
			claimed[checker.name] = ctx
			releases = append(releases, release)
		}
		contexts[index] = ctx
	}
	return contexts, func() {
		for _, release := range releases {
			release()
		}
	}
}

func claimService(parent context.Context, name string) (context.Context, func()) {
	ctx, cancel := context.WithCancel(parent)
	claim := &cancel
	serviceClaimsMu.Lock()
	if previous := serviceClaims[name]; previous != nil {
		(*previous)()
	}
	serviceClaims[name] = claim
	serviceClaimsMu.Unlock()
	return ctx, func() {
		cancel()
		serviceClaimsMu.Lock()
		if serviceClaims[name] == claim {
			delete(serviceClaims, name)
		}
		serviceClaimsMu.Unlock()
	}
}

func hasBudget(ctx context.Context, timeout time.Duration) bool {
	deadline, ok := ctx.Deadline()
	return !ok || time.Until(deadline) >= timeout
}

func selectedCheckers(names []string) []serviceChecker {
	if len(names) == 0 {
		return serviceCheckers
	}
	wanted := make([]serviceChecker, 0, len(names))
	for _, name := range names {
		for _, checker := range serviceCheckers {
			if checker.name == name {
				wanted = append(wanted, checker)
				break
			}
		}
	}
	return wanted
}

// checkReachable is the rule for a target with no unlock semantics of its own.
func checkReachable(url string) func(serviceEnv) ServiceCheckItem {
	return func(env serviceEnv) ServiceCheckItem {
		result := env.get(url, 0)
		item := itemFrom(result)
		if item.Status != "" {
			return item
		}
		item.Status = statusFromCode(result.StatusCode)
		return item
	}
}

func itemFrom(result *ProbeResult) ServiceCheckItem {
	if result == nil {
		return ServiceCheckItem{Status: serviceFailed}
	}
	item := ServiceCheckItem{Delay: result.Delay, Chains: result.Chains}
	switch result.Error {
	case "":
	case probeErrorTimeout:
		item.Status = serviceTimeout
		item.Delay = 0
	default:
		item.Status = serviceFailed
		item.Delay = 0
	}
	return item
}

func statusFromCode(code int) string {
	switch {
	case code >= 200 && code < 300:
		return serviceAvailable
	case code == http.StatusUnauthorized,
		code == http.StatusForbidden,
		code == http.StatusTooManyRequests,
		code == http.StatusUnavailableForLegalReasons:
		return serviceRestricted
	default:
		return serviceUnavailable
	}
}

func answered(item ServiceCheckItem, result *ProbeResult) bool {
	return item.Status == "" && result != nil
}

func bodyContains(result *ProbeResult, needles ...string) bool {
	if result.lowerBody == "" {
		result.lowerBody = strings.ToLower(result.Body)
	}
	for _, needle := range needles {
		if strings.Contains(result.lowerBody, needle) {
			return true
		}
	}
	return false
}

func traceValue(body string, key string) string {
	for _, line := range strings.Split(body, "\n") {
		if rest, found := strings.CutPrefix(line, key+"="); found {
			return strings.TrimSpace(rest)
		}
	}
	return ""
}
