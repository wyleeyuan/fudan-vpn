package service

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mythologyli/zju-connect/router"
	"golang.org/x/net/proxy"
)

// 起一个真实的本机服务，走分流器的直连路径去够它。
// 隧道那条路没法在单测里伪造（要真的登录），但直连路径是规则写错时最容易出事的那条。
func TestServeRouterDirect(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "ok")
	}))
	defer target.Close()

	rt, err := router.Parse(strings.NewReader("MATCH,DIRECT\n"))
	if err != nil {
		t.Fatalf("规则解析失败: %v", err)
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("占端口失败: %v", err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()

	go ServeRouter(addr, nil, nil, rt)

	// 等监听就绪
	var conn net.Conn
	for i := 0; i < 50; i++ {
		conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("分流器没起来: %v", err)
	}

	dialer, err := proxy.SOCKS5("tcp", addr, nil, proxy.Direct)
	if err != nil {
		t.Fatalf("构造 SOCKS5 客户端失败: %v", err)
	}

	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(_ context.Context, network, address string) (net.Conn, error) {
				return dialer.Dial(network, address)
			},
		},
		Timeout: 5 * time.Second,
	}

	resp, err := client.Get(target.URL)
	if err != nil {
		t.Fatalf("经分流器请求失败: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("状态码 %d，期望 200", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if string(body) != "ok" {
		t.Fatalf("响应体 %q，期望 ok", body)
	}
}
