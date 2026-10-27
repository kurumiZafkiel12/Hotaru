package core

import "github.com/metacubex/http"

func classifyServiceEndpoint(result *ProbeResult) ServiceCheckItem {
	item := itemFrom(result)
	if item.Status != "" {
		return item
	}
	switch {
	case bodyContains(result, "unsupported_country", "country_not_supported", "not available in your country", "not available in your region", "geo_restricted", "region_not_supported"):
		item.Status = serviceUnsupportedRegion
	case bodyContains(result, "cf-chl-", "challenge-platform", "verify you are human", "just a moment...", "g-recaptcha", "/sorry/index"):
		item.Status = serviceChallenge
	case result.StatusCode == http.StatusUnauthorized:
		item.Status = serviceAuthentication
	case result.StatusCode >= 200 && result.StatusCode < 300:
		item.Status = serviceReachable
	case result.StatusCode == http.StatusForbidden || result.StatusCode == http.StatusTooManyRequests:
		item.Status = serviceRestricted
	case result.StatusCode >= 500:
		item.Status = serviceUnavailable
	default:
		item.Status = serviceInconclusive
	}
	return item
}
