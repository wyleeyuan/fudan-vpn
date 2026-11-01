package dial

import (
	"net"
	"sync"
	"time"

	"github.com/mythologyli/zju-connect/log"
)

// 本机常见的代理端口，按命中概率排序。
// 刻意跳过 1080/1081/1082 —— 那是本程序自己的端口，转过去会成环。
var defaultAutoProxyPorts = []string{
	"127.0.0.1:7890",
	"127.0.0.1:7891",
	"127.0.0.1:6152",
	"127.0.0.1:10808",
	"127.0.0.1:8889",
}

// autoSocks 在需要时探一遍本机的代理端口。
//
// 为什么要一次一次地探：用户常常先连 VPN，过一会儿才想起开 Clash。端口如果
// 在进程启动那一刻定死，这段时间里 Google、ChatGPT 会一直按直连处理，在墙内
// 就是打不开。结果缓存 10 秒，既能及时跟上「Clash 后开」，也不至于每条连接
// 都探一遍端口。
type autoSocks struct {
	ports []string

	mu      sync.Mutex
	addr    string
	expires time.Time
}

func newAutoSocks(ports ...string) *autoSocks {
	if len(ports) == 0 {
		ports = defaultAutoProxyPorts
	}
	return &autoSocks{ports: ports}
}

func (a *autoSocks) current() string {
	a.mu.Lock()
	defer a.mu.Unlock()

	if time.Now().Before(a.expires) {
		return a.addr
	}

	found := ""
	for _, p := range a.ports {
		conn, err := net.DialTimeout("tcp", p, 150*time.Millisecond)
		if err != nil {
			continue
		}
		_ = conn.Close()
		found = p
		break
	}

	if found != a.addr {
		if found != "" {
			log.Printf("直连出口接上本机代理 %s", found)
		} else if a.addr != "" {
			log.Println("本机代理已不可用，直连出口恢复为裸直连")
		}
	}

	a.addr = found
	a.expires = time.Now().Add(10 * time.Second)
	return found
}
