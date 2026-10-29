package core

import (
	"net/http"
	"testing"
)

func TestNormalizeRegion(t *testing.T) {
	cases := map[string]string{
		"US":    "US",
		"jp":    "JP",
		"CHN":   "CN",
		"usa":   "US",
		"HKG":   "HK",
		"ZZZ":   "",
		"C":     "",
		"CNAAA": "",
		"":      "",
		"1A":    "",
	}
	for input, want := range cases {
		if got := normalizeRegion(input); got != want {
			t.Errorf("normalizeRegion(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestTikTokStatus(t *testing.T) {
	cases := []struct {
		code int
		body string
		want string
	}{
		{http.StatusOK, `{"region":"JP"}`, serviceReachable},
		{http.StatusForbidden, "", serviceRestricted},
		{http.StatusUnavailableForLegalReasons, "", serviceInconclusive},
		{http.StatusOK, "Access Denied", serviceRestricted},
		{http.StatusOK, "TikTok is not available in your region", serviceUnsupportedRegion},
		{http.StatusInternalServerError, "", serviceUnavailable},
	}
	for _, testCase := range cases {
		got := tikTokStatus(&ProbeResult{StatusCode: testCase.code, Body: testCase.body})
		if got != testCase.want {
			t.Errorf("tikTokStatus(%d, %q) = %q, want %q", testCase.code, testCase.body, got, testCase.want)
		}
	}
}

func TestTikTokRegionReadsTheAppContext(t *testing.T) {
	const cluster = `{"idc":"no1a","vdc":"no1a","region":"EU-TTP2","vregion":"EU-TTP2"}`
	page := cluster + `{"__DEFAULT_SCOPE__":{"webapp.app-context":{"language":"en","region":"GB","appId":1233}}}`
	if got := tikTokRegion(page); got != "GB" {
		t.Errorf("region = %q, want the visitor's country rather than the serving cluster", got)
	}
	if got := tikTokRegion(cluster); got != "" {
		t.Errorf("region = %q, want empty without the app context", got)
	}
	if got := tikTokRegion(`{"webapp.app-context":{"region":"zh-Hant-TW"}}`); got != "" {
		t.Errorf("region = %q, want a locale left unread rather than its language", got)
	}
}

func TestBilibiliStatusReadsTheLeadingCode(t *testing.T) {
	cases := map[string]string{
		`{"code":0,"message":"success","result":{"code":0,"accept_format":"hdf`: serviceAvailable,
		`{"code":-10403,"message":"region locked"}`:                             serviceUnsupportedRegion,
		`{"code":-412,"message":"request blocked"}`:                             serviceFailed,
		`{"message":"success","result":{"code":0}}`:                             serviceFailed,
		"": serviceFailed,
	}
	for body, want := range cases {
		if got := bilibiliStatus(body); got != want {
			t.Errorf("bilibiliStatus(%q) = %q, want %q", body, got, want)
		}
	}
}

func TestSpotifyRegionPrefersTheRedirectedPath(t *testing.T) {
	redirected := &ProbeResult{Url: "https://www.spotify.com/de-de/", Body: `{"countryCode":"US"}`}
	if got := spotifyRegion(redirected); got != "de" {
		t.Errorf("region = %q, want the path's country", got)
	}
	unredirected := &ProbeResult{
		Url:  "https://www.spotify.com/api/content/v1/country-selector",
		Body: `{"countryCode":"SE"}`,
	}
	if got := spotifyRegion(unredirected); got != "SE" {
		t.Errorf("region = %q, want the payload's country", got)
	}
}

func TestYouTubeRegionPatterns(t *testing.T) {
	bodies := map[string]string{
		`<span id="country-code"> GB </span>`: "GB",
		`{"GL":"JP","other":1}`:               "JP",
		`{"countryCode":"KR"}`:                "KR",
		`{"country_code":"BR"}`:               "BR",
	}
	for body, want := range bodies {
		var got string
		for _, pattern := range youTubeRegionPatterns {
			if code := firstSubmatch(pattern, body); code != "" {
				got = normalizeRegion(code)
				break
			}
		}
		if got != want {
			t.Errorf("region from %q = %q, want %q", body, got, want)
		}
	}
}

func TestDisneyAndPrimePatterns(t *testing.T) {
	if got := firstSubmatch(disneySupportedPattern, `{"inSupportedLocation":false}`); got != "false" {
		t.Errorf("supported = %q", got)
	}
	if got := firstSubmatch(primeRegionPattern, `{"currentTerritory":"NL"}`); got != "NL" {
		t.Errorf("territory = %q", got)
	}
}

func TestPrimeRestrictionReadsTheBooleanValue(t *testing.T) {
	for _, tc := range []struct{ body, want string }{
		{`{"currentTerritory":"JP","isServiceRestricted":false}`, serviceReachable},
		{`{"currentTerritory":"JP","isServiceRestricted":true}`, serviceUnsupportedRegion},
		{`{"currentTerritory":"JP"}`, serviceReachable},
	} {
		got := classifyPrimeVideo(&ProbeResult{StatusCode: 200, Body: tc.body})
		if got.Status != tc.want {
			t.Fatalf("%s => %s, want %s", tc.body, got.Status, tc.want)
		}
	}
}

func TestSpotifyLocaleDoesNotTurnLanguageIntoCountry(t *testing.T) {
	for _, tc := range []struct{ path, body, want string }{
		{"en-us", `{"countryCode":"GB"}`, "us"},
		{"premium", `{"countryCode":"GB"}`, "GB"},
		{"en", `{"countryCode":"US"}`, "US"},
	} {
		got := spotifyRegion(&ProbeResult{Url: "https://www.spotify.com/" + tc.path + "/", Body: tc.body})
		if got != tc.want {
			t.Fatalf("%s => %s, want %s", tc.path, got, tc.want)
		}
	}
}

func TestRegionEchoMustFollowTheSameNodeAsTheService(t *testing.T) {
	web := &ProbeResult{StatusCode: 200, Chains: []string{"Exit-A", "Group"}}
	trace := &ProbeResult{StatusCode: 200, Body: "loc=US\n", Chains: []string{"Exit-B", "Group"}}
	if got := serviceTraceRegion(web, trace); got != "" {
		t.Fatalf("different nodes reported a shared region: %s", got)
	}
	trace.Chains = web.Chains
	if got := serviceTraceRegion(web, trace); got != "US" {
		t.Fatalf("matching route region=%q", got)
	}
}
