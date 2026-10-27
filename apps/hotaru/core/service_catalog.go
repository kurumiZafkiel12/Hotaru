package core

func init() {
	serviceCheckers = append(serviceCheckers,
		serviceChecker{name: "openai-api", check: checkServiceEndpoint("https://api.openai.com/v1/models")},
		serviceChecker{name: "claude-api", check: checkServiceEndpoint("https://api.anthropic.com/v1/models")},
		serviceChecker{name: "copilot", check: checkServiceEndpoint("https://copilot.microsoft.com/")},
		serviceChecker{name: "perplexity", check: checkServiceEndpoint("https://www.perplexity.ai/")},
		serviceChecker{name: "grok", check: checkServiceEndpoint("https://grok.com/")},
		serviceChecker{name: "poe", check: checkServiceEndpoint("https://poe.com/")},
		serviceChecker{name: "midjourney", check: checkServiceEndpoint("https://www.midjourney.com/")},
		serviceChecker{name: "deepseek", check: checkServiceEndpoint("https://chat.deepseek.com/")},
		serviceChecker{name: "kimi", check: checkServiceEndpoint("https://www.kimi.com/")},
		serviceChecker{name: "doubao", check: checkServiceEndpoint("https://www.doubao.com/")},
		serviceChecker{name: "apple-tv", check: checkServiceEndpoint("https://tv.apple.com/")},
		serviceChecker{name: "hbo-max", check: checkServiceEndpoint("https://www.hbomax.com/")},
		serviceChecker{name: "hulu", check: checkServiceEndpoint("https://www.hulu.com/")},
		serviceChecker{name: "paramount", check: checkServiceEndpoint("https://www.paramountplus.com/")},
		serviceChecker{name: "bbc", check: checkBBCiPlayer},
		serviceChecker{name: "dazn", check: checkServiceEndpoint("https://www.dazn.com/")},
		serviceChecker{name: "crunchyroll", check: checkServiceEndpoint("https://www.crunchyroll.com/")},
		serviceChecker{name: "twitch", check: checkServiceEndpoint("https://www.twitch.tv/")},
		serviceChecker{name: "abema", check: checkServiceEndpoint("https://abema.tv/")},
		serviceChecker{name: "tver", check: checkServiceEndpoint("https://tver.jp/")},
		serviceChecker{name: "bahamut", check: checkServiceEndpoint("https://ani.gamer.com.tw/")},
		serviceChecker{name: "viu", check: checkServiceEndpoint("https://www.viu.com/")},
		serviceChecker{name: "bilibili-main", check: checkServiceEndpoint("https://www.bilibili.com/")},
		serviceChecker{name: "iqiyi", check: checkServiceEndpoint("https://www.iqiyi.com/")},
		serviceChecker{name: "tencent-video", check: checkServiceEndpoint("https://v.qq.com/")},
		serviceChecker{name: "netease", check: checkServiceEndpoint("https://music.163.com/")},
		serviceChecker{name: "qq-music", check: checkServiceEndpoint("https://y.qq.com/")},
		serviceChecker{name: "telegram", check: checkTelegram},
		serviceChecker{name: "x", check: checkServiceEndpoint("https://x.com/")},
		serviceChecker{name: "reddit", check: checkServiceEndpoint("https://www.reddit.com/")},
		serviceChecker{name: "instagram", check: checkServiceEndpoint("https://www.instagram.com/")},
		serviceChecker{name: "whatsapp", check: checkServiceEndpoint("https://web.whatsapp.com/")},
		serviceChecker{name: "line", check: checkServiceEndpoint("https://access.line.me/")},
		serviceChecker{name: "wechat", check: checkServiceEndpoint("https://wx.qq.com/")},
		serviceChecker{name: "docker", check: checkServiceEndpoint("https://registry-1.docker.io/v2/")},
		serviceChecker{name: "huggingface", check: checkServiceEndpoint("https://huggingface.co/")},
		serviceChecker{name: "office", check: checkServiceEndpoint("https://www.office.com/")},
		serviceChecker{name: "notion", check: checkServiceEndpoint("https://www.notion.so/")},
		serviceChecker{name: "wikipedia", check: checkServiceEndpoint("https://www.wikipedia.org/")},
		serviceChecker{name: "steam", check: checkSteam},
		serviceChecker{name: "epic", check: checkServiceEndpoint("https://store.epicgames.com/")},
		serviceChecker{name: "psn", check: checkServiceEndpoint("https://store.playstation.com/")},
		serviceChecker{name: "nintendo", check: checkServiceEndpoint("https://www.nintendo.com/")},
		serviceChecker{name: "google-play", check: checkServiceEndpoint("https://play.google.com/store")},
		// The unlock-test catalog beyond the audit set; endpoint rules
		// judge these, so a plain 200 only ever reads as reachable.
		serviceChecker{name: "sora", check: checkServiceEndpoint("https://sora.chatgpt.com/")},
		serviceChecker{name: "meta-ai", check: checkServiceEndpoint("https://www.meta.ai/")},
		serviceChecker{name: "deepl", check: checkServiceEndpoint("https://www.deepl.com/")},
		serviceChecker{name: "cursor", check: checkServiceEndpoint("https://www.cursor.com/")},
		serviceChecker{name: "suno", check: checkServiceEndpoint("https://suno.com/")},
		serviceChecker{name: "openrouter", check: checkServiceEndpoint("https://openrouter.ai/")},
		serviceChecker{name: "peacock", check: checkServiceEndpoint("https://www.peacocktv.com/")},
		serviceChecker{name: "discovery-plus", check: checkServiceEndpoint("https://www.discoveryplus.com/")},
		serviceChecker{name: "itvx", check: checkServiceEndpoint("https://www.itv.com/")},
		serviceChecker{name: "channel4", check: checkServiceEndpoint("https://www.channel4.com/")},
		serviceChecker{name: "sky-go", check: checkServiceEndpoint("https://www.sky.com/watch")},
		serviceChecker{name: "now-tv", check: checkServiceEndpoint("https://www.nowtv.com/")},
		serviceChecker{name: "mola", check: checkServiceEndpoint("https://mola.tv/")},
		serviceChecker{name: "hotstar", check: checkServiceEndpoint("https://www.hotstar.com/")},
		serviceChecker{name: "fubotv", check: checkServiceEndpoint("https://www.fubo.tv/")},
		serviceChecker{name: "sling", check: checkServiceEndpoint("https://www.sling.com/")},
		serviceChecker{name: "tubi", check: checkServiceEndpoint("https://tubitv.com/")},
		serviceChecker{name: "youtube-music", check: checkServiceEndpoint("https://music.youtube.com/")},
		serviceChecker{name: "apple-music", check: checkServiceEndpoint("https://music.apple.com/")},
		serviceChecker{name: "tidal", check: checkServiceEndpoint("https://tidal.com/")},
		serviceChecker{name: "kkbox", check: checkServiceEndpoint("https://www.kkbox.com/")},
		serviceChecker{name: "soundcloud", check: checkServiceEndpoint("https://soundcloud.com/")},
		serviceChecker{name: "facebook", check: checkServiceEndpoint("https://www.facebook.com/")},
		serviceChecker{name: "linkedin", check: checkServiceEndpoint("https://www.linkedin.com/")},
		serviceChecker{name: "kktv", check: checkServiceEndpoint("https://www.kktv.me/")},
		serviceChecker{name: "myvideo", check: checkServiceEndpoint("https://www.myvideo.net.tw/")},
		serviceChecker{name: "friday", check: checkServiceEndpoint("https://video.friday.tw/")},
		serviceChecker{name: "line-tv", check: checkServiceEndpoint("https://www.linetv.tw/")},
		serviceChecker{name: "hami", check: checkServiceEndpoint("https://hamivideo.hinet.net/")},
		serviceChecker{name: "unext", check: checkServiceEndpoint("https://video.unext.jp/")},
		serviceChecker{name: "hulu-jp", check: checkServiceEndpoint("https://www.hulu.jp/")},
		serviceChecker{name: "dmm", check: checkServiceEndpoint("https://tv.dmm.com/")},
		serviceChecker{name: "niconico", check: checkServiceEndpoint("https://www.nicovideo.jp/")},
		serviceChecker{name: "radiko", check: checkServiceEndpoint("https://radiko.jp/")},
		serviceChecker{name: "fod", check: checkServiceEndpoint("https://fod.fujitv.co.jp/")},
		serviceChecker{name: "lemino", check: checkServiceEndpoint("https://lemino.docomo.ne.jp/")},
		serviceChecker{name: "wowow", check: checkServiceEndpoint("https://www.wowow.co.jp/")},
		serviceChecker{name: "music-jp", check: checkServiceEndpoint("https://music.jp/")},
		serviceChecker{name: "mytv-super", check: checkServiceEndpoint("https://www.mytvsuper.com/")},
		serviceChecker{name: "now-e", check: checkServiceEndpoint("https://www.nowe.com/")},
		serviceChecker{name: "viutv", check: checkServiceEndpoint("https://viu.tv/")},
		serviceChecker{name: "canal-plus", check: checkServiceEndpoint("https://www.canalplus.com/")},
		serviceChecker{name: "molotov", check: checkServiceEndpoint("https://www.molotov.tv/")},
		serviceChecker{name: "cbc-gem", check: checkServiceEndpoint("https://gem.cbc.ca/")},
		serviceChecker{name: "crave", check: checkServiceEndpoint("https://www.crave.ca/")},
		serviceChecker{name: "stan", check: checkServiceEndpoint("https://www.stan.com.au/")},
		serviceChecker{name: "xbox", check: checkServiceEndpoint("https://www.xbox.com/")},
		serviceChecker{name: "battle-net", check: checkServiceEndpoint("https://www.battle.net/")},
		serviceChecker{name: "ubisoft", check: checkServiceEndpoint("https://store.ubisoft.com/")},
		serviceChecker{name: "genshin", check: checkServiceEndpoint("https://genshin.hoyoverse.com/")},
		serviceChecker{name: "gitlab", check: checkServiceEndpoint("https://gitlab.com/")},
		serviceChecker{name: "npm", check: checkServiceEndpoint("https://registry.npmjs.org/")},
		serviceChecker{name: "pypi", check: checkServiceEndpoint("https://pypi.org/")},
	)
}

// checkBBCiPlayer reads the media selector's answer: a geolocation
// refusal outside the UK, a media set inside it.
func checkBBCiPlayer(env serviceEnv) ServiceCheckItem {
	result := env.get(
		"https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/pc/vpid/bbc_one_london/format/json/jsfunc/JS_callbacks",
		serviceSmallMaxBody,
	)
	item := itemFrom(result)
	if !answered(item, result) {
		return item
	}
	switch {
	case bodyContains(result, "geolocation"):
		item.Status = serviceUnsupportedRegion
	case bodyContains(result, "\"media\""):
		item.Status = serviceAvailable
		item.Region = "GB"
	default:
		item.Status = serviceInconclusive
	}
	return item
}

func checkServiceEndpoint(url string) func(serviceEnv) ServiceCheckItem {
	return func(env serviceEnv) ServiceCheckItem {
		result := env.get(url, serviceHtmlMaxBody)
		return classifyServiceEndpoint(result)
	}
}

func checkSteam(env serviceEnv) ServiceCheckItem {
	store := env.get("https://store.steampowered.com/", serviceHtmlMaxBody)
	community := env.get("https://steamcommunity.com/", serviceHtmlMaxBody)
	item := classifyServiceEndpoint(store)
	other := classifyServiceEndpoint(community)
	if bodyContains(store, "error code: -101", "error code: -105") || bodyContains(community, "error code: -101", "error code: -105") {
		item.Status = serviceBlocked
	} else if item.Status == serviceReachable && other.Status != serviceReachable {
		item.Status = other.Status
	}
	return item
}
