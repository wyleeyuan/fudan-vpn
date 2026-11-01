package router

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func mustParse(t *testing.T, src string) *Router {
	t.Helper()
	rt, err := Parse(strings.NewReader(src))
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	return rt
}

func TestMatchDomain(t *testing.T) {
	rt := mustParse(t, `
DOMAIN,ehall.fudan.edu.cn,TUNNEL
DOMAIN-SUFFIX,fudan.edu.cn,TUNNEL
DOMAIN-KEYWORD,library,TUNNEL
IP-CIDR,10.0.0.0/8,TUNNEL,no-resolve
IP-CIDR,172.16.0.0/12,TUNNEL,no-resolve
MATCH,DIRECT
`)

	cases := []struct {
		host string
		ip   string
		want Action
		why  string
	}{
		{"ehall.fudan.edu.cn", "1.2.3.4", Tunnel, "DOMAIN 精确命中"},
		{"www.fudan.edu.cn", "1.2.3.4", Tunnel, "后缀命中子域"},
		{"fudan.edu.cn", "1.2.3.4", Tunnel, "后缀命中自身"},
		{"evfudan.edu.cn", "1.2.3.4", Direct, "后缀不能跨 dot 边界误伤"},
		{"fudan.edu.cn.evil.com", "1.2.3.4", Direct, "后缀要在末尾，不能是前缀"},
		{"lib.library.fudan.edu.cn", "1.2.3.4", Tunnel, "关键词命中"},
		{"", "10.1.2.3", Tunnel, "纯 IP 走 CIDR"},
		{"", "172.20.0.9", Tunnel, "172.16/12 命中"},
		{"", "172.32.0.9", Direct, "172.32 不在 /12 里"},
		{"", "8.8.8.8", Direct, "公网 IP 落到 MATCH"},
		{"api.openai.com", "104.18.0.1", Direct, "境外站直连"},
		{"github.com", "20.205.243.166", Direct, "GitHub 直连"},
	}

	for _, c := range cases {
		var ip net.IP
		if c.ip != "" {
			ip = net.ParseIP(c.ip)
		}
		if got := rt.Match(c.host, ip); got != c.want {
			t.Errorf("Match(%q, %q) = %v，期望 %v（%s）", c.host, c.ip, got, c.want, c.why)
		}
	}
}

func TestOrderFirstMatchWins(t *testing.T) {
	// 具体的写前面才能压住笼统的，反过来的话第一条就吃掉全部
	rt := mustParse(t, `
DOMAIN-SUFFIX,fudan.edu.cn,DIRECT
DOMAIN,ehall.fudan.edu.cn,TUNNEL
MATCH,DIRECT
`)
	if got := rt.Match("ehall.fudan.edu.cn", nil); got != Direct {
		t.Errorf("后缀在前时应先命中 DIRECT，得到 %v", got)
	}

	rt = mustParse(t, `
DOMAIN,ehall.fudan.edu.cn,TUNNEL
DOMAIN-SUFFIX,fudan.edu.cn,DIRECT
MATCH,DIRECT
`)
	if got := rt.Match("ehall.fudan.edu.cn", nil); got != Tunnel {
		t.Errorf("精确规则在前时应命中 TUNNEL，得到 %v", got)
	}
	if got := rt.Match("www.fudan.edu.cn", nil); got != Direct {
		t.Errorf("子域应落到后缀规则 DIRECT，得到 %v", got)
	}
}

func TestActionAliases(t *testing.T) {
	rt := mustParse(t, `
DOMAIN,proxy.example.com,PROXY
DOMAIN,vpn.example.com,VPN
DOMAIN,udp.example.com,DIRECT
MATCH,DIRECT
`)
	for _, host := range []string{"proxy.example.com", "vpn.example.com"} {
		if got := rt.Match(host, nil); got != Tunnel {
			t.Errorf("%s 应视同 TUNNEL，得到 %v", host, got)
		}
	}
}

func TestParseErrors(t *testing.T) {
	bad := []string{
		"UNKNOWN,x,TUNNEL",            // 不认识的类型
		"DOMAIN-SUFFIX,fudan.edu.cn",  // 缺动作
		"IP-CIDR,10.0.0.0/33,TUNNEL",  // 网段非法
		"DOMAIN,x.example.com,REJECT", // 不认识的动作
	}
	for _, src := range bad {
		if _, err := Parse(strings.NewReader(src)); err == nil {
			t.Errorf("应当报错但没报: %q", src)
		}
	}
}

func TestCommentsAndBlankLines(t *testing.T) {
	rt := mustParse(t, `
# 这是注释
DOMAIN-SUFFIX,fudan.edu.cn,TUNNEL   # 行尾注释
   
MATCH,DIRECT
`)
	if rt.Len() != 2 {
		t.Fatalf("应解析出 2 条规则，得到 %d", rt.Len())
	}
	if got := rt.Match("www.fudan.edu.cn", nil); got != Tunnel {
		t.Errorf("行尾注释不应影响规则，得到 %v", got)
	}
}

func TestDefaultRules(t *testing.T) {
	rt, err := Load("")
	if err != nil {
		t.Fatalf("默认规则解析失败: %v", err)
	}
	if rt.Len() < 20 {
		t.Errorf("默认规则条数偏少: %d", rt.Len())
	}
	if got := rt.Match("www.fudan.edu.cn", nil); got != Tunnel {
		t.Errorf("默认规则里复旦域名应走隧道，得到 %v", got)
	}
	if got := rt.Match("", net.ParseIP("10.1.2.3")); got != Tunnel {
		t.Errorf("默认规则里 10/8 应走隧道，得到 %v", got)
	}
	if got := rt.Match("api.openai.com", nil); got != Direct {
		t.Errorf("默认规则里境外站应直连，得到 %v", got)
	}
	if got := rt.Match("", net.ParseIP("192.168.1.1")); got != Direct {
		t.Errorf("默认规则不应劫持家里的 192.168 网段，得到 %v", got)
	}
}

// 登录域名必须直连：送进隧道时出口那边返回 host unreachable，
// 浏览器表现成登录页一直转圈。
func TestDefaultRulesLoginDirect(t *testing.T) {
	rt, err := Load("")
	if err != nil {
		t.Fatalf("默认规则解析失败: %v", err)
	}
	for _, host := range []string{"id.fudan.edu.cn", "vpn.fudan.edu.cn"} {
		if got := rt.Match(host, nil); got != Direct {
			t.Errorf("%s 应直连，得到 %v", host, got)
		}
	}
	// 内网域名（公网 DNS 查不到）必须走隧道解析
	for _, host := range []string{"icourse.fudan.edu.cn", "ehall.fudan.edu.cn"} {
		if got := rt.Match(host, nil); got != Tunnel {
			t.Errorf("%s 应走隧道，得到 %v", host, got)
		}
	}
}

// 改完规则文件不重启也该生效。
func TestReloadOnChange(t *testing.T) {
	old := reloadInterval
	reloadInterval = 0
	defer func() { reloadInterval = old }()

	path := filepath.Join(t.TempDir(), "rules.conf")
	if err := os.WriteFile(path, []byte("MATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	rt, err := Load(path)
	if err != nil {
		t.Fatalf("加载失败: %v", err)
	}
	if got := rt.Match("ehall.fudan.edu.cn", nil); got != Direct {
		t.Fatalf("初始应为直连，得到 %v", got)
	}

	if err := os.WriteFile(path, []byte("DOMAIN-SUFFIX,fudan.edu.cn,TUNNEL\nMATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := rt.Match("ehall.fudan.edu.cn", nil); got != Tunnel {
		t.Errorf("改文件后应自动重载为隧道，得到 %v", got)
	}

	// 写坏了要保住上一版，不能让分流当场瘫痪
	if err := os.WriteFile(path, []byte("DOMAIN-SUFFIX,fudan.edu.cn\nMATCH,DIRECT\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := rt.Match("ehall.fudan.edu.cn", nil); got != Tunnel {
		t.Errorf("规则写坏时应继续用上一版，得到 %v", got)
	}
}
