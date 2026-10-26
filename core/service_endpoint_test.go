package core

import (
	"context"
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

func TestServiceEndpointNeverTreatsReachabilityAsUnlock(t *testing.T) {
	for _, tc := range []struct {
		name string
		code int
		body string
		want string
	}{
		{"page", 200, "Welcome", serviceReachable},
		{"api key needed", 401, `{"error":"missing api key"}`, serviceAuthentication},
		{"region error", 403, `{"error":{"code":"unsupported_country_region_territory"}}`, serviceUnsupportedRegion},
		{"web shield", 403, "Just a moment... challenge-platform", serviceChallenge},
		{"captcha with 200", 200, "g-recaptcha", serviceChallenge},
		{"generic forbidden", 403, "Forbidden", serviceRestricted},
		{"rate limit", 429, "Too many requests", serviceRestricted},
		{"missing endpoint", 404, "Not found", serviceInconclusive},
		{"server error", 503, "Unavailable", serviceUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			item := classifyServiceEndpoint(&ProbeResult{StatusCode: tc.code, Body: tc.body})
			if item.Status != tc.want {
				t.Fatalf("status = %q, want %q", item.Status, tc.want)
			}
		})
	}
}

func TestServiceCatalogContainsAll57UniqueChecks(t *testing.T) {
	if len(serviceCheckers) != 57 {
		t.Fatalf("catalog has %d entries", len(serviceCheckers))
	}
	names := map[string]bool{}
	for _, checker := range serviceCheckers {
		if checker.name == "" || names[checker.name] || checker.check == nil {
			t.Fatalf("invalid checker %q", checker.name)
		}
		names[checker.name] = true
	}
}

func TestNetflixCatalogDoesNotTrustOnlyA200OrASpeedCdn(t *testing.T) {
	playable := &ProbeResult{StatusCode: 200, Body: `{"isPlayable":true}`}
	landing := &ProbeResult{StatusCode: 200, Body: `{"targets":[{"location":{"country":"JP"}}]}`}
	for _, tc := range []struct {
		name               string
		original, licensed *ProbeResult
		want               string
	}{
		{"generic landing pages", landing, landing, serviceReachable},
		{"original catalog only", playable, &ProbeResult{StatusCode: 404}, serviceOriginalsOnly},
		{"both catalogs expose playback metadata", playable, playable, serviceAvailable},
		{"license request challenged", playable, &ProbeResult{StatusCode: 403, Body: "Just a moment..."}, serviceInconclusive},
		{"original page blocked by region", &ProbeResult{StatusCode: 403, Body: "not available in your country"}, playable, serviceUnsupportedRegion},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := classifyNetflixTitles(tc.original, tc.licensed); got.Status != tc.want {
				t.Fatalf("status = %q, want %q", got.Status, tc.want)
			}
		})
	}
}

func TestServiceRunCancellationClosesRealRequest(t *testing.T) {
	entered := make(chan struct{})
	closed := make(chan struct{})
	server := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-r.Context().Done()
		close(closed)
	})
	withProbeProxies(t, "DIRECT")
	withServiceCheckers(t, serviceChecker{name: "controlled", check: checkServiceEndpoint(server.URL)})
	done := make(chan []ServiceCheckItem, 1)
	go func() {
		done <- handleServiceCheck(&ServiceCheckParams{RunID: "cancel-test", ProxyName: "DIRECT", Names: []string{"controlled"}, Timeout: 5000})
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("request did not reach controlled server")
	}
	handleServiceCheck(&ServiceCheckParams{RunID: "cancel-test", Cancel: true})
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("cancel left HTTP request open")
	}
	select {
	case items := <-done:
		if len(items) != 1 || items[0].Status == serviceReachable {
			t.Fatalf("cancelled items = %+v", items)
		}
	case <-time.After(time.Second):
		t.Fatal("cancel left checker running")
	}
	serviceRunsMu.Lock()
	defer serviceRunsMu.Unlock()
	if _, exists := serviceRuns["cancel-test"]; exists {
		t.Fatal("run lease was retained")
	}
}

func TestCancelledRunRejectsAnRpcThatArrivesAfterCancellation(t *testing.T) {
	var requests atomic.Int32
	server := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusOK)
	})
	withProbeProxies(t, "DIRECT")
	withServiceCheckers(t, serviceChecker{name: "controlled", check: checkServiceEndpoint(server.URL)})
	handleServiceCheck(&ServiceCheckParams{RunID: "cancel-before-start", Cancel: true})
	items := handleServiceCheck(&ServiceCheckParams{RunID: "cancel-before-start", ProxyName: "DIRECT", Timeout: 1000})
	if requests.Load() != 0 || len(items) != 1 || items[0].Status == serviceReachable {
		t.Fatalf("late RPC restarted a cancelled run: requests=%d items=%+v", requests.Load(), items)
	}
}

func TestServiceObservationRetainsRealEndpointAndChain(t *testing.T) {
	server := probeServer(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	withProbeProxies(t, "DIRECT")
	item := runServiceCheck(context.Background(), serviceChecker{name: "controlled", check: checkServiceEndpoint(server.URL)}, "DIRECT", time.Second)
	if len(item.Observations) != 1 {
		t.Fatalf("observations = %+v", item.Observations)
	}
	observed := item.Observations[0]
	if observed.URL != server.URL || observed.StatusCode != 204 || len(observed.Chains) != 1 || observed.Chains[0] != "DIRECT" {
		t.Fatalf("observed = %+v", observed)
	}
}
