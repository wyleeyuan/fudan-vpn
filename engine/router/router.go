// Package router 实现 Clash 风格的本地分流规则。
//
// 复旦的 aTrust 下发的是全量资源，上游 dialer 的白名单判断对每一条连接都成立，
// 等于不分流。所以客户端要自己再判一层：命中规则才送进隧道，其余直连。
//
// 规则文件格式与 Clash 一致，一条一行：
//
//	DOMAIN-SUFFIX,fudan.edu.cn,TUNNEL
//	IP-CIDR,10.0.0.0/8,TUNNEL,no-resolve
//	MATCH,DIRECT
//
// 从上往下匹配，第一条命中的生效。字段解析失败会直接报错并指出行号——
// 静默跳过一个写错的规则，比报错更难查。
package router

import (
	"bufio"
	"bytes"
	_ "embed"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Action 是一条连接的去向。
type Action int

const (
	// Direct 本机直连，不经过隧道。
	Direct Action = iota
	// Tunnel 送进复旦隧道。
	Tunnel
)

func (a Action) String() string {
	if a == Tunnel {
		return "TUNNEL"
	}
	return "DIRECT"
}

type ruleType int

const (
	typeDomain ruleType = iota
	typeDomainSuffix
	typeDomainKeyword
	typeIPCIDR
	typeMatch
)

type rule struct {
	typ    ruleType
	value  string
	cidr   *net.IPNet
	action Action
}

// reloadInterval 是两次检查规则文件是否变动的最小间隔。
//
// 每个新连接都会匹配一次规则，如果每次都 stat 一遍文件，
// 高并发时会白跑很多系统调用；两秒一次足够「改完存盘即生效」的手感。
// 测试里会把它调成 0。
var reloadInterval = 2 * time.Second

// Router 是解析后的规则表。并发匹配安全。
//
// 规则文件改过之后会在下一个连接上自动重载（见 refresh），
// 所以用户不用重启 App —— 这一点 rules.conf 的注释里是承诺过的。
type Router struct {
	mu       sync.RWMutex
	rules    []rule
	path     string
	modTime  time.Time
	size     int64
	lastStat time.Time
}

// Path 返回规则文件路径，空字符串表示用的是内置默认规则。
func (r *Router) Path() string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.path
}

// Len 返回规则条数。
func (r *Router) Len() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.rules)
}

// refresh 在规则文件变动后重载一次。
//
// 解析失败时保留旧规则：用户手改文件写错一行，不该让整个分流当场瘫痪。
// 错误打到 stderr，engine 的日志里能看到。
func (r *Router) refresh() {
	r.mu.RLock()
	path, last := r.path, r.lastStat
	r.mu.RUnlock()

	if path == "" || time.Since(last) < reloadInterval {
		return
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	if time.Since(r.lastStat) < reloadInterval {
		return
	}
	r.lastStat = time.Now()

	fi, err := os.Stat(r.path)
	if err != nil || (fi.ModTime().Equal(r.modTime) && fi.Size() == r.size) {
		return
	}

	f, err := os.Open(r.path)
	if err != nil {
		return
	}
	defer f.Close()

	next, err := Parse(f)
	if err != nil {
		fmt.Fprintf(os.Stderr, "规则文件有错，继续用上一版：%v\n", err)
		return
	}

	r.rules = next.rules
	r.modTime = fi.ModTime()
	r.size = fi.Size()
	fmt.Fprintf(os.Stderr, "已重载分流规则 %s（%d 条）\n", r.path, len(r.rules))
}

// Match 按顺序匹配，返回第一条命中的动作。
//
// host 是 SOCKS5 请求里的域名（可能为空，说明客户端直接给了 IP），
// ip 是解析后的地址。域名规则只在 host 非空时参与，IP 规则只在 ip 非空时参与，
// 两轮都按文件里的顺序走一遍，最后落到 MATCH。
func (r *Router) Match(host string, ip net.IP) Action {
	host = normalizeHost(host)

	r.refresh()

	r.mu.RLock()
	rules := r.rules
	r.mu.RUnlock()

	for _, ru := range rules {
		switch ru.typ {
		case typeDomain:
			if host != "" && host == ru.value {
				return ru.action
			}
		case typeDomainSuffix:
			// 后缀规则要同时命中「自身」和「子域」，
			// 但 dot 边界必须卡住：evfudan.edu.cn 不能命中 fudan.edu.cn。
			if host != "" && (host == ru.value || strings.HasSuffix(host, "."+ru.value)) {
				return ru.action
			}
		case typeDomainKeyword:
			if host != "" && strings.Contains(host, ru.value) {
				return ru.action
			}
		case typeIPCIDR:
			if ip != nil && ru.cidr != nil && ru.cidr.Contains(ip) {
				return ru.action
			}
		case typeMatch:
			return ru.action
		}
	}

	return Direct
}

func normalizeHost(host string) string {
	host = strings.TrimSpace(host)
	host = strings.TrimSuffix(host, ".")
	return strings.ToLower(host)
}

// Parse 从 r 读取规则。出错时带上行号。
func Parse(r io.Reader) (*Router, error) {
	rt := &Router{}
	scanner := bufio.NewScanner(r)
	lineNo := 0

	for scanner.Scan() {
		lineNo++
		raw := strings.TrimSpace(scanner.Text())
		if raw == "" || strings.HasPrefix(raw, "#") {
			continue
		}
		// 允许行尾注释：IP-CIDR,10.0.0.0/8,TUNNEL,no-resolve  # 校内
		if i := strings.Index(raw, "#"); i >= 0 {
			raw = strings.TrimSpace(raw[:i])
			if raw == "" {
				continue
			}
		}

		parts := strings.Split(raw, ",")
		for i := range parts {
			parts[i] = strings.TrimSpace(parts[i])
		}

		typ := strings.ToUpper(parts[0])
		switch typ {
		case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD":
			if len(parts) < 3 {
				return nil, fmt.Errorf("第 %d 行缺少动作：%s", lineNo, raw)
			}
			value := normalizeHost(parts[1])
			if value == "" {
				return nil, fmt.Errorf("第 %d 行域名为空：%s", lineNo, raw)
			}
			action, err := parseAction(parts[2])
			if err != nil {
				return nil, fmt.Errorf("第 %d 行：%w", lineNo, err)
			}
			ru := rule{value: value, action: action}
			switch typ {
			case "DOMAIN":
				ru.typ = typeDomain
			case "DOMAIN-SUFFIX":
				ru.typ = typeDomainSuffix
			default:
				ru.typ = typeDomainKeyword
			}
			rt.rules = append(rt.rules, ru)

		case "IP-CIDR", "IP-CIDR6":
			if len(parts) < 3 {
				return nil, fmt.Errorf("第 %d 行缺少动作：%s", lineNo, raw)
			}
			_, cidr, err := net.ParseCIDR(parts[1])
			if err != nil {
				return nil, fmt.Errorf("第 %d 行网段不合法（%s）：%w", lineNo, parts[1], err)
			}
			action, err := parseAction(parts[2])
			if err != nil {
				return nil, fmt.Errorf("第 %d 行：%w", lineNo, err)
			}
			rt.rules = append(rt.rules, rule{typ: typeIPCIDR, value: parts[1], cidr: cidr, action: action})

		case "MATCH", "FINAL":
			if len(parts) < 2 {
				return nil, fmt.Errorf("第 %d 行缺少动作：%s", lineNo, raw)
			}
			action, err := parseAction(parts[1])
			if err != nil {
				return nil, fmt.Errorf("第 %d 行：%w", lineNo, err)
			}
			rt.rules = append(rt.rules, rule{typ: typeMatch, action: action})

		default:
			return nil, fmt.Errorf("第 %d 行不认识规则类型 %q，支持 DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / IP-CIDR / MATCH", lineNo, parts[0])
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return rt, nil
}

func parseAction(s string) (Action, error) {
	switch strings.ToUpper(strings.TrimSpace(s)) {
	case "TUNNEL", "PROXY", "VPN", "FUDAN":
		return Tunnel, nil
	case "DIRECT":
		return Direct, nil
	default:
		return Direct, fmt.Errorf("不认识的动作 %q，只支持 TUNNEL 和 DIRECT", s)
	}
}

// Load 从文件读取规则。文件不存在时，写一份默认规则再加载。
func Load(path string) (*Router, error) {
	if path == "" {
		rt, err := Parse(strings.NewReader(DefaultRules))
		if err != nil {
			return nil, err
		}
		return rt, nil
	}

	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		if dir := filepath.Dir(path); dir != "" && dir != "." {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return nil, err
			}
		}
		data = []byte(DefaultRules)
		if err := os.WriteFile(path, data, 0o644); err != nil {
			return nil, err
		}
	} else if err != nil {
		return nil, err
	}

	rt, err := Parse(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	rt.path = path
	// 记下加载时的状态，refresh 靠它判断文件有没有再被改过
	if fi, err := os.Stat(path); err == nil {
		rt.modTime = fi.ModTime()
		rt.size = fi.Size()
	}
	return rt, nil
}

// DefaultRules 是规则文件不存在时写出的默认规则。
//
// 内容放在 default_rules.conf，和 macOS App 打包时复制到
// Contents/Resources 的是同一个文件——默认规则只有这一份源。
//
//go:embed default_rules.conf
var DefaultRules string
