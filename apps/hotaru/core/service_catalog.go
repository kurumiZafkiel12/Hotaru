package core

func init() {
	serviceCheckers = append(serviceCheckers,
		endpointChecker("youtube-music", "https://music.youtube.com/"),
		endpointChecker("apple-music", "https://music.apple.com/"),
		endpointChecker("peacock", "https://www.peacocktv.com/"),
		endpointChecker("u-next", "https://video.unext.jp/"),
		endpointChecker("fod", "https://fod.fujitv.co.jp/"),
		endpointChecker("hulu-japan", "https://www.hulu.jp/"),
		endpointChecker("openai-api", "https://api.openai.com/v1/models"),
		endpointChecker("claude-api", "https://api.anthropic.com/v1/models"),
		endpointChecker("copilot", "https://copilot.microsoft.com/"),
		endpointChecker("perplexity", "https://www.perplexity.ai/"),
		endpointChecker("grok", "https://grok.com/"),
		endpointChecker("poe", "https://poe.com/"),
		endpointChecker("midjourney", "https://www.midjourney.com/"),
		endpointChecker("deepseek", "https://chat.deepseek.com/"),
		endpointChecker("kimi", "https://www.kimi.com/"),
		endpointChecker("doubao", "https://www.doubao.com/"),
		endpointChecker("apple-tv", "https://tv.apple.com/"),
		endpointChecker("hbo-max", "https://www.hbomax.com/"),
		endpointChecker("hulu", "https://www.hulu.com/"),
		endpointChecker("paramount", "https://www.paramountplus.com/"),
		endpointChecker("bbc", "https://www.bbc.co.uk/iplayer"),
		endpointChecker("dazn", "https://www.dazn.com/"),
		endpointChecker("crunchyroll", "https://www.crunchyroll.com/"),
		endpointChecker("twitch", "https://www.twitch.tv/"),
		endpointChecker("abema", "https://abema.tv/"),
		endpointChecker("tver", "https://tver.jp/"),
		endpointChecker("bahamut", "https://ani.gamer.com.tw/"),
		endpointChecker("viu", "https://www.viu.com/"),
		endpointChecker("bilibili-main", "https://www.bilibili.com/"),
		endpointChecker("iqiyi", "https://www.iqiyi.com/"),
		endpointChecker("tencent-video", "https://v.qq.com/"),
		endpointChecker("netease", "https://music.163.com/"),
		endpointChecker("qq-music", "https://y.qq.com/"),
		serviceChecker{name: "telegram", connectivityURL: "https://web.telegram.org/", check: checkTelegram},
		endpointChecker("x", "https://x.com/"),
		endpointChecker("reddit", "https://www.reddit.com/"),
		endpointChecker("instagram", "https://www.instagram.com/"),
		endpointChecker("whatsapp", "https://web.whatsapp.com/"),
		endpointChecker("line", "https://access.line.me/"),
		endpointChecker("wechat", "https://wx.qq.com/"),
		endpointChecker("docker", "https://registry-1.docker.io/v2/"),
		endpointChecker("huggingface", "https://huggingface.co/"),
		endpointChecker("office", "https://www.office.com/"),
		endpointChecker("notion", "https://www.notion.so/"),
		endpointChecker("wikipedia", "https://www.wikipedia.org/"),
		serviceChecker{name: "steam", connectivityURL: "https://store.steampowered.com/", check: checkSteam},
		endpointChecker("epic", "https://store.epicgames.com/"),
		endpointChecker("psn", "https://store.playstation.com/"),
		endpointChecker("nintendo", "https://www.nintendo.com/"),
		endpointChecker("google-play", "https://play.google.com/store"),
	)
}

func endpointChecker(name, url string) serviceChecker {
	return serviceChecker{name: name, connectivityURL: url, check: checkServiceEndpoint(url)}
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
