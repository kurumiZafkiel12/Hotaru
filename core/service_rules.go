package core

import (
	"net/url"
	"regexp"
	"slices"
	"strings"

	"github.com/metacubex/http"
)

// disneyAuthHeader is the public browser client token Disney+ hands to any web
// visitor; the device and token calls below are rejected without it.
const disneyAuthHeader = "Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84"

var (
	youTubeRegionPatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)id=["']country-code["'][^>]*>\s*([A-Za-z]{2,3})\s*<`),
		regexp.MustCompile(`"GL"\s*:\s*"([A-Za-z]{2})"`),
		regexp.MustCompile(`"countryCode"\s*:\s*"([A-Za-z]{2})"`),
		regexp.MustCompile(`"country_code"\s*:\s*"([A-Za-z]{2})"`),
	}
	tikTokRegionPattern    = regexp.MustCompile(`"webapp\.app-context"\s*:\s*\{[^{}]*?"region"\s*:\s*"([^"]*)"`)
	primeRegionPattern     = regexp.MustCompile(`"currentTerritory":"([^"]+)"`)
	disneyAssertionPattern = regexp.MustCompile(`"assertion"\s*:\s*"([^"]+)"`)
	disneyRefreshPattern   = regexp.MustCompile(`"refresh_token"\s*:\s*"([^"]+)"`)
	disneyCountryPattern   = regexp.MustCompile(`"countryCode"\s*:\s*"([^"]+)"`)
	disneySupportedPattern = regexp.MustCompile(`"inSupportedLocation"\s*:\s*(false|true)`)
	spotifyCountryPattern  = regexp.MustCompile(`"countryCode"\s*:\s*"([^"]+)"`)
	discordCountryPattern  = regexp.MustCompile(`"country_code"\s*:\s*"([^"]+)"`)
	geminiRegionMarker     = `,2,1,200,"`
	claudeBlockedRegions   = []string{"AF", "BY", "CN", "CU", "HK", "IR", "KP", "MO", "RU", "SY"}
	geminiBlockedRegions   = []string{"CHN", "RUS", "BLR", "CUB", "IRN", "PRK", "SYR", "HKG", "MAC"}

	// A playable episode runs past the small body cap; only its leading code is read.
	bilibiliCodePattern = regexp.MustCompile(`^\s*\{\s*"code"\s*:\s*(-?\d+)`)
)

func firstSubmatch(pattern *regexp.Regexp, body string) string {
	match := pattern.FindStringSubmatch(body)
	if len(match) < 2 {
		return ""
	}
	return match[1]
}

func checkClaude(env serviceEnv) ServiceCheckItem {
	trace := env.get("https://claude.ai/cdn-cgi/trace", serviceSmallMaxBody)
	web := env.get("https://claude.ai/login", serviceHtmlMaxBody)
	return classifyClaude(trace, web)
}

func classifyClaude(trace, web *ProbeResult) ServiceCheckItem {
	item := classifyServiceEndpoint(web)
	if trace != nil && trace.Error == "" && trace.StatusCode == http.StatusOK {
		item.Region = normalizeRegion(traceValue(trace.Body, "loc"))
		if slices.Contains(claudeBlockedRegions, item.Region) {
			item.Status = serviceUnsupportedRegion
		}
	}
	return item
}

func checkGemini(env serviceEnv) ServiceCheckItem {
	result := env.scan("https://gemini.google.com", func(tail string) bool {
		index := strings.Index(tail, geminiRegionMarker)
		return index >= 0 && index+len(geminiRegionMarker)+3 <= len(tail)
	})
	item := itemFrom(result)
	if !answered(item, result) {
		return item
	}
	index := strings.Index(result.Body, geminiRegionMarker)
	if index < 0 || index+len(geminiRegionMarker)+3 > len(result.Body) {
		item.Status = serviceFailed
		return item
	}
	start := index + len(geminiRegionMarker)
	code := result.Body[start : start+3]
	if !isAsciiUpper(code) {
		item.Status = serviceFailed
		return item
	}
	item.Region = normalizeRegion(code)
	item.Status = serviceAvailable
	if slices.Contains(geminiBlockedRegions, code) {
		item.Status = serviceUnsupportedRegion
	}
	return item
}

// checkChatGpt folds Verge's separate iOS and Web results into one entry: the
// card shows a single row per service, and a split would put two identical
// OpenAI icons next to each other.
func checkChatGpt(env serviceEnv) ServiceCheckItem {
	ios := env.get("https://ios.chat.openai.com/", serviceSmallMaxBody)
	item := itemFrom(ios)
	if answered(item, ios) {
		item.Status = chatGptIosStatus(ios)
	}

	trace := env.get("https://chat.openai.com/cdn-cgi/trace", serviceSmallMaxBody)
	if traceItem := itemFrom(trace); answered(traceItem, trace) {
		item.Region = normalizeRegion(traceValue(trace.Body, "loc"))
	}

	web := env.get("https://api.openai.com/compliance/cookie_requirements", serviceSmallMaxBody)
	if webItem := itemFrom(web); answered(webItem, web) &&
		bodyContains(web, "unsupported_country") {
		item.Status = serviceUnsupportedRegion
	}
	return item
}

func chatGptIosStatus(result *ProbeResult) string {
	switch {
	case bodyContains(result, "you may be connected to a disallowed isp"):
		return serviceDisallowedIsp
	case bodyContains(result, "sorry, you have been blocked"):
		return serviceBlocked
	case bodyContains(result, "request is not allowed. please try again later."):
		// Being turned away as an API client is what a reachable region looks
		// like here; anything else means the request never got that far.
		return serviceAvailable
	default:
		return serviceFailed
	}
}

func checkYouTubePremium(env serviceEnv) ServiceCheckItem {
	result := env.get("https://www.youtube.com/premium?hl=en", serviceHtmlMaxBody)
	item := itemFrom(result)
	if !answered(item, result) {
		return item
	}
	for _, pattern := range youTubeRegionPatterns {
		if code := firstSubmatch(pattern, result.Body); code != "" {
			item.Region = normalizeRegion(code)
			break
		}
	}
	switch {
	case bodyContains(result,
		"youtube premium is not available in your country",
		"premium is not available in your country",
		"premium is not available in your region"):
		item.Status = serviceUnsupportedRegion
	case result.StatusCode >= 200 && result.StatusCode < 300 &&
		bodyContains(result, "youtube premium", "ad-free", `"browseid":"spunlimited"`):
		item.Status = serviceAvailable
	default:
		item.Status = statusFromCode(result.StatusCode)
	}
	return item
}

func checkSpotify(env serviceEnv) ServiceCheckItem {
	result := env.get(
		"https://www.spotify.com/api/content/v1/country-selector?platform=web&format=json",
		serviceSmallMaxBody,
	)
	item := itemFrom(result)
	if !answered(item, result) {
		return item
	}
	item.Region = normalizeRegion(spotifyRegion(result))
	switch {
	case result.StatusCode == http.StatusForbidden ||
		result.StatusCode == http.StatusUnavailableForLegalReasons:
		item.Status = serviceUnsupportedRegion
	case result.StatusCode < 200 || result.StatusCode >= 300:
		item.Status = statusFromCode(result.StatusCode)
	case bodyContains(result, "not available in your country"):
		item.Status = serviceUnsupportedRegion
	default:
		item.Status = serviceAvailable
	}
	return item
}

// spotifyRegion prefers the country Spotify redirected the request into, and
// falls back to the one named in the payload.
func spotifyRegion(result *ProbeResult) string {
	if final, err := url.Parse(result.Url); err == nil {
		segments := strings.Split(strings.Trim(final.Path, "/"), "/")
		if first := segments[0]; first != "" && first != "api" {
			return strings.Split(first, "-")[0]
		}
	}
	return firstSubmatch(spotifyCountryPattern, result.Body)
}

// TikTok is not behind Cloudflare: /cdn-cgi/trace redirects to a 404 page.
func checkTikTok(env serviceEnv) ServiceCheckItem {
	result := env.scan("https://www.tiktok.com/", tikTokRegionPattern.MatchString)
	item := itemFrom(result)
	if !answered(item, result) {
		return item
	}
	item.Status = tikTokStatus(result)
	item.Region = tikTokRegion(result.Body)
	return item
}

func tikTokStatus(result *ProbeResult) string {
	switch {
	case result.StatusCode == http.StatusForbidden ||
		result.StatusCode == http.StatusUnavailableForLegalReasons:
		return serviceUnsupportedRegion
	case result.StatusCode < 200 || result.StatusCode >= 300:
		return serviceFailed
	case bodyContains(result, "access denied", "not available in your region", "tiktok is not available"):
		return serviceUnsupportedRegion
	default:
		return serviceAvailable
	}
}

// The page names its serving cluster "region" too ("EU-TTP2"); the visitor's
// country is the one in the web app's context.
func tikTokRegion(body string) string {
	return normalizeRegion(firstSubmatch(tikTokRegionPattern, body))
}

func checkBilibili(env serviceEnv) ServiceCheckItem {
	const mainland = "https://api.bilibili.com/pgc/player/web/playurl?avid=82846771&qn=0&type=&otype=json&ep_id=307247&fourk=1&fnver=0&fnval=16&module=bangumi"
	const hongKongMacauTaiwan = "https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777&qn=0&type=&otype=json&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi"
	item := bilibiliEpisode(env, mainland)
	switch item.Status {
	case serviceAvailable:
		item.Region = "CN"
		return item
	case serviceUnsupportedRegion:
		return bilibiliEpisode(env, hongKongMacauTaiwan)
	default:
		return item
	}
}

func bilibiliEpisode(env serviceEnv, url string) ServiceCheckItem {
	result := env.get(url, serviceSmallMaxBody)
	item := itemFrom(result)
	if !answered(item, result) {
		return item
	}
	item.Status = bilibiliStatus(result.Body)
	return item
}

func bilibiliStatus(body string) string {
	switch firstSubmatch(bilibiliCodePattern, body) {
	case "0":
		return serviceAvailable
	case "-10403":
		return serviceUnsupportedRegion
	default:
		return serviceFailed
	}
}

func checkDiscord(env serviceEnv) ServiceCheckItem {
	result := env.get("https://discord.com/api/v9/auth/location-metadata", serviceSmallMaxBody)
	item := itemFrom(result)
	if !answered(item, result) {
		return item
	}
	item.Status = statusFromCode(result.StatusCode)
	if item.Status == serviceAvailable {
		item.Region = normalizeRegion(firstSubmatch(discordCountryPattern, result.Body))
	}
	return item
}

func checkPrimeVideo(env serviceEnv) ServiceCheckItem {
	result := env.scan("https://www.primevideo.com", func(tail string) bool {
		return strings.Contains(tail, "isServiceRestricted") || primeRegionPattern.MatchString(tail)
	})
	item := itemFrom(result)
	if !answered(item, result) {
		return item
	}
	if strings.Contains(result.Body, "isServiceRestricted") {
		item.Status = serviceUnsupportedRegion
		return item
	}
	region := firstSubmatch(primeRegionPattern, result.Body)
	if region == "" {
		item.Status = serviceFailed
		return item
	}
	item.Region = normalizeRegion(region)
	item.Status = serviceAvailable
	return item
}

func checkNetflix(env serviceEnv) ServiceCheckItem {
	original := env.get("https://www.netflix.com/title/80057281", serviceHtmlMaxBody)
	licensed := env.get("https://www.netflix.com/title/70143836", serviceHtmlMaxBody)
	item := classifyNetflixTitles(original, licensed)
	item.Region = netflixRegion(env)
	return item
}

var netflixPlayablePattern = regexp.MustCompile(`"isPlayable"\s*:\s*true`)

func classifyNetflixTitles(original, licensed *ProbeResult) ServiceCheckItem {
	item := classifyServiceEndpoint(original)
	if item.Status != serviceReachable {
		return item
	}
	licenseItem := classifyServiceEndpoint(licensed)
	switch {
	case !netflixPlayablePattern.MatchString(original.Body):
		item.Status = serviceReachable
	case licensed != nil && licensed.Error == "" && licensed.StatusCode == http.StatusNotFound:
		item.Status = serviceOriginalsOnly
	case licenseItem.Status == serviceReachable && netflixPlayablePattern.MatchString(licensed.Body):
		item.Status = serviceAvailable
	default:
		item.Status = serviceInconclusive
	}
	return item
}

func netflixRegion(env serviceEnv) string {
	result := env.send(probeRequest{method: http.MethodGet, url: "https://www.netflix.com/title/80057281", noRedirect: true})
	if result == nil || result.Error != "" || result.header == nil {
		return ""
	}
	location, err := url.Parse(result.header.Get("Location"))
	if err != nil {
		return ""
	}
	segments := strings.Split(strings.Trim(location.Path, "/"), "/")
	if len(segments) == 0 {
		return ""
	}
	return normalizeRegion(strings.Split(segments[0], "-")[0])
}

// checkDisneyPlus walks the browser hand-shake: register a device, exchange the
// assertion for a refresh token, then ask the session which region it landed
// in. Any step can answer on its own that the address is not welcome.
func checkDisneyPlus(env serviceEnv) ServiceCheckItem {
	device := env.send(probeRequest{
		method: http.MethodPost,
		url:    "https://disney.api.edge.bamgrid.com/devices",
		headers: map[string]string{
			"authorization": disneyAuthHeader,
			"content-type":  "application/json; charset=UTF-8",
		},
		body:    []byte(`{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}`),
		maxBody: serviceSmallMaxBody,
	})
	item := itemFrom(device)
	if !answered(item, device) {
		return item
	}
	if device.StatusCode == http.StatusForbidden {
		item.Status = serviceBlocked
		return item
	}
	assertion := firstSubmatch(disneyAssertionPattern, device.Body)
	if assertion == "" {
		item.Status = serviceFailed
		return item
	}

	form := strings.NewReplacer("{assertion}", url.QueryEscape(assertion)).Replace(
		"grant_type=urn:ietf:params:oauth:grant-type:token-exchange" +
			"&latitude=0&longitude=0&platform=browser" +
			"&subject_token={assertion}" +
			"&subject_token_type=urn:bamtech:params:oauth:token-type:device",
	)
	token := env.send(probeRequest{
		method: http.MethodPost,
		url:    "https://disney.api.edge.bamgrid.com/token",
		headers: map[string]string{
			"authorization": disneyAuthHeader,
			"content-type":  "application/x-www-form-urlencoded",
		},
		body:    []byte(form),
		maxBody: serviceSmallMaxBody,
	})
	if tokenItem := itemFrom(token); !answered(tokenItem, token) {
		return tokenItem
	}
	if strings.Contains(token.Body, "forbidden-location") || strings.Contains(token.Body, "403 ERROR") {
		item.Status = serviceBlocked
		return item
	}
	refresh := firstSubmatch(disneyRefreshPattern, token.Body)
	if refresh == "" {
		item.Status = serviceFailed
		return item
	}

	query := `{"query":"mutation refreshToken($input: RefreshTokenInput!) { refreshToken(refreshToken: $input) { activeSession { sessionId } } }","variables":{"input":{"refreshToken":"` +
		refresh + `"}}}`
	session := env.send(probeRequest{
		method: http.MethodPost,
		url:    "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql",
		headers: map[string]string{
			"authorization": disneyAuthHeader,
			"content-type":  "application/json",
		},
		body:    []byte(query),
		maxBody: serviceSmallMaxBody,
	})
	sessionItem := itemFrom(session)
	if !answered(sessionItem, session) || session.Body == "" || session.StatusCode >= 400 {
		item.Status = serviceFailed
		return item
	}
	region := normalizeRegion(firstSubmatch(disneyCountryPattern, session.Body))
	if region == "" {
		item.Status = serviceUnavailable
		return item
	}
	item.Region = region
	switch firstSubmatch(disneySupportedPattern, session.Body) {
	case "true":
		item.Status = serviceAvailable
	case "false":
		item.Status = serviceComingSoon
	default:
		item.Status = serviceFailed
	}
	return item
}
