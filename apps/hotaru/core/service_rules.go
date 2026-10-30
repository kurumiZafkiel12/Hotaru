package core

import (
	"net/url"
	"regexp"
	"slices"
	"strings"

	"github.com/metacubex/http"
)

var (
	youTubeRegionPatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)id=["']country-code["'][^>]*>\s*([A-Za-z]{2,3})\s*<`),
		regexp.MustCompile(`"GL"\s*:\s*"([A-Za-z]{2})"`),
		regexp.MustCompile(`"countryCode"\s*:\s*"([A-Za-z]{2})"`),
		regexp.MustCompile(`"country_code"\s*:\s*"([A-Za-z]{2})"`),
	}
	tikTokRegionPattern    = regexp.MustCompile(`"webapp\.app-context"\s*:\s*\{[^{}]*?"region"\s*:\s*"([^"]*)"`)
	primeRegionPattern     = regexp.MustCompile(`"currentTerritory":"([^"]+)"`)
	primeRestrictedPattern = regexp.MustCompile(`"isServiceRestricted"\s*:\s*(true|false)`)
	disneyCountryPattern   = regexp.MustCompile(`"countryCode"\s*:\s*"([^"]+)"`)
	disneySupportedPattern = regexp.MustCompile(`"inSupportedLocation"\s*:\s*(false|true)`)
	spotifyCountryPattern  = regexp.MustCompile(`"countryCode"\s*:\s*"([^"]+)"`)
	discordCountryPattern  = regexp.MustCompile(`"country_code"\s*:\s*"([^"]+)"`)
	geminiRegionMarker     = `,2,1,200,"`

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
	item.Region = serviceTraceRegion(web, trace)
	return item
}

func checkGemini(env serviceEnv) ServiceCheckItem {
	result := env.get("https://gemini.google.com/", serviceHtmlMaxBody)
	item := classifyServiceEndpoint(result)
	if result == nil || result.Error != "" {
		return item
	}
	index := strings.Index(result.Body, geminiRegionMarker)
	if index >= 0 && index+len(geminiRegionMarker)+3 <= len(result.Body) {
		item.Region = normalizeRegion(result.Body[index+len(geminiRegionMarker) : index+len(geminiRegionMarker)+3])
	}
	return item
}

func checkChatGpt(env serviceEnv) ServiceCheckItem {
	web := env.get("https://chatgpt.com/", serviceHtmlMaxBody)
	item := classifyServiceEndpoint(web)
	trace := env.get("https://chatgpt.com/cdn-cgi/trace", serviceSmallMaxBody)
	item.Region = serviceTraceRegion(web, trace)
	return item
}

func checkYouTubePremium(env serviceEnv) ServiceCheckItem {
	result := env.get("https://www.youtube.com/premium?hl=en", serviceHtmlMaxBody)
	item := classifyServiceEndpoint(result)
	if result == nil || result.Error != "" {
		return item
	}
	for _, pattern := range youTubeRegionPatterns {
		if code := firstSubmatch(pattern, result.Body); code != "" {
			item.Region = normalizeRegion(code)
			break
		}
	}
	return item
}

func checkSpotify(env serviceEnv) ServiceCheckItem {
	result := env.get("https://www.spotify.com/api/content/v1/country-selector?platform=web&format=json", serviceSmallMaxBody)
	item := classifyServiceEndpoint(result)
	if result != nil && result.Error == "" {
		item.Region = normalizeRegion(spotifyRegion(result))
	}
	return item
}

// spotifyRegion prefers the country Spotify redirected the request into, and
// falls back to the one named in the payload.
func spotifyRegion(result *ProbeResult) string {
	if final, err := url.Parse(result.Url); err == nil {
		segments := strings.Split(strings.Trim(final.Path, "/"), "/")
		if locale := strings.Split(segments[0], "-"); len(locale) == 2 && len(locale[0]) == 2 && len(locale[1]) == 2 {
			return locale[1]
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
	return classifyServiceEndpoint(result).Status
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
	item := classifyServiceEndpoint(result)
	if result != nil && result.Error == "" {
		item.Region = normalizeRegion(firstSubmatch(discordCountryPattern, result.Body))
	}
	return item
}

func checkPrimeVideo(env serviceEnv) ServiceCheckItem {
	result := env.scan("https://www.primevideo.com/", func(tail string) bool {
		return primeRestrictedPattern.MatchString(tail) && primeRegionPattern.MatchString(tail)
	})
	return classifyPrimeVideo(result)
}

func classifyPrimeVideo(result *ProbeResult) ServiceCheckItem {
	item := classifyServiceEndpoint(result)
	if result == nil || result.Error != "" {
		return item
	}
	item.Region = normalizeRegion(firstSubmatch(primeRegionPattern, result.Body))
	if item.Status == serviceReachable && firstSubmatch(primeRestrictedPattern, result.Body) == "true" {
		item.Status = serviceUnsupportedRegion
	}
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

func checkDisneyPlus(env serviceEnv) ServiceCheckItem {
	result := env.get("https://www.disneyplus.com/", serviceHtmlMaxBody)
	item := classifyServiceEndpoint(result)
	if result == nil || result.Error != "" {
		return item
	}
	item.Region = normalizeRegion(firstSubmatch(disneyCountryPattern, result.Body))
	if item.Status == serviceReachable && firstSubmatch(disneySupportedPattern, result.Body) == "false" {
		item.Status = serviceUnsupportedRegion
	}
	return item
}

func serviceTraceRegion(web, trace *ProbeResult) string {
	if web == nil || web.Error != "" || trace == nil || trace.Error != "" || trace.StatusCode != http.StatusOK || !slices.Equal(web.Chains, trace.Chains) {
		return ""
	}
	return normalizeRegion(traceValue(trace.Body, "loc"))
}
