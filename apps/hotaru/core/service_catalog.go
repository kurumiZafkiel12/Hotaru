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
		serviceChecker{name: "bbc", check: checkServiceEndpoint("https://www.bbc.co.uk/iplayer")},
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
	)
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
