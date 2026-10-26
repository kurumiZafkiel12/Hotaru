package core

import (
	"crypto/sha256"
	"encoding/hex"
)

const gitHubRawProbe = "https://raw.githubusercontent.com/github/gitignore/5808b77453dec299d4daf8557b05a80be832a5b8/Global/Windows.gitignore"
const gitHubRawSHA256 = "d763006b3cb986d97d8d5d9081e3e82783060cb9afceaef1544c43f5e6bf796f"

func checkGitHub(env serviceEnv) ServiceCheckItem {
	page := env.get("https://github.com/", serviceSmallMaxBody)
	item := classifyServiceEndpoint(page)
	if item.Status != serviceReachable {
		return item
	}
	raw := env.get(gitHubRawProbe, serviceSmallMaxBody)
	item = classifyServiceEndpoint(raw)
	if item.Status != serviceReachable {
		return item
	}
	hash := sha256.Sum256([]byte(raw.Body))
	if hex.EncodeToString(hash[:]) != gitHubRawSHA256 {
		item.Status = serviceFailed
		if env.observations != nil && len(*env.observations) > 0 {
			observations := *env.observations
			observations[len(observations)-1].Error = "content-sha256-mismatch"
		}
	}
	return item
}
