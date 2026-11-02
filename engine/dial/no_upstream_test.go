package dial

import (
	"context"
	"net"
	"testing"
	"time"
)

// --no-upstream 的核心契约：即使配置了上游地址，也不能再交出去。
//
// 这个开关是给「本程序被 Clash 当成上游」的场景用的：分流口把判成
// DIRECT 的域名交回 Clash，Clash 再按 fudan 规则送回分流口，就是
// 1082 -> 7890 -> 1082 的无限递归。必须能一刀切断，而不是靠探测不到上游。
func TestNoUpstreamClearsConfiguredProxy(t *testing.T) {
	d := NewDialer(nil, nil, nil, false, "socks://127.0.0.1:1", true)

	if got := d.socksUpstream(); got != "" {
		t.Fatalf("socksUpstream() = %q under --no-upstream, want empty", got)
	}
	if d.dialDirectSocksProxy != "" || d.dialDirectHTTPProxy != "" {
		t.Fatalf("上游字段未清空: socks=%q http=%q", d.dialDirectSocksProxy, d.dialDirectHTTPProxy)
	}
	if d.autoSocks != nil {
		t.Fatal("--no-upstream 仍然创建了自动探测器")
	}
}

// auto 模式同样要被压住，否则「探测到 Clash」会绕过配置。
func TestNoUpstreamDisablesAutoDetect(t *testing.T) {
	d := NewDialer(nil, nil, nil, false, "auto", true)

	if d.autoSocks != nil {
		t.Fatal("--no-upstream 下 auto 仍然被启用")
	}
	if got := d.socksUpstream(); got != "" {
		t.Fatalf("socksUpstream() = %q, want empty", got)
	}
}

// 本机真有一个 SOCKS 服务在监听时，开着 no-upstream 也绝不能连过去。
func TestNoUpstreamDoesNotReachLocalProxy(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	reached := make(chan struct{}, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		reached <- struct{}{}
		_ = conn.Close()
	}()

	d := NewDialer(nil, nil, nil, false, "socks://"+listener.Addr().String(), true)

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	if conn, dialErr := d.dialDirectHost(ctx, "tcp", "127.0.0.1:9"); conn != nil {
		_ = conn.Close()
	} else if dialErr == nil {
		t.Fatal("dialDirectHost 返回 nil conn 但也没有错误")
	}

	select {
	case <-reached:
		t.Fatal("--no-upstream 下仍然连到了上游代理")
	case <-time.After(200 * time.Millisecond):
	}
}

// 不传这个开关时行为必须完全不变，避免影响现有用户。
func TestUpstreamStillWorksByDefault(t *testing.T) {
	d := NewDialer(nil, nil, nil, false, "socks://127.0.0.1:7890", false)

	if got := d.socksUpstream(); got != "127.0.0.1:7890" {
		t.Fatalf("socksUpstream() = %q, want 127.0.0.1:7890", got)
	}
}
