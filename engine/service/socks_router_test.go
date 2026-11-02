package service

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/mythologyli/zju-connect/dial"
	"github.com/mythologyli/zju-connect/router"
	"github.com/things-go/go-socks5"
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

// 规则判 DIRECT 的流量，若配了 --dial-direct-proxy，必须真的从那个代理出去。
//
// 这条是「连上复旦 VPN 之后 ChatGPT 还能不能用」的关键：浏览器被指到 1082，
// 非校内流量要顺着用户自己的 Clash 走，而不是被裸直连（然后在墙内失败）。
func TestServeRouterDirectUsesUpstreamProxy(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "ok")
	}))
	defer target.Close()

	// 假的 Clash：只负责转发，顺便记一下被用了几次
	var used atomic.Int32
	upstreamLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("占端口失败: %v", err)
	}
	defer upstreamLn.Close()
	upstream := socks5.NewServer(socks5.WithDial(
		func(ctx context.Context, network, addr string) (net.Conn, error) {
			used.Add(1)
			var d net.Dialer
			return d.DialContext(ctx, network, addr)
		}))
	go func() { _ = upstream.Serve(upstreamLn) }()

	dialer := dial.NewDialer(nil, nil, nil, false, "socks://"+upstreamLn.Addr().String(), false)

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

	go ServeRouter(addr, dialer, nil, rt)

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

	client5, err := proxy.SOCKS5("tcp", addr, nil, proxy.Direct)
	if err != nil {
		t.Fatalf("构造 SOCKS5 客户端失败: %v", err)
	}
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(_ context.Context, network, address string) (net.Conn, error) {
				return client5.Dial(network, address)
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
	if used.Load() == 0 {
		t.Fatal("直连流量没有走上游代理")
	}
}

// 上游代理没在跑的时候（用户关了 Clash），直连流量必须还能走通。
// 不然「连上 VPN 之后连百度都打不开」，比不连还糟。
func TestServeRouterDirectFallsBackWhenProxyDead(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "ok")
	}))
	defer target.Close()

	// 指向一个没人听的端口
	dialer := dial.NewDialer(nil, nil, nil, false, "socks://127.0.0.1:1", false)

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

	go ServeRouter(addr, dialer, nil, rt)

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

	client5, err := proxy.SOCKS5("tcp", addr, nil, proxy.Direct)
	if err != nil {
		t.Fatalf("构造 SOCKS5 客户端失败: %v", err)
	}
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(_ context.Context, network, address string) (net.Conn, error) {
				return client5.Dial(network, address)
			},
		},
		Timeout: 5 * time.Second,
	}

	resp, err := client.Get(target.URL)
	if err != nil {
		t.Fatalf("上游代理挂了之后请求失败: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("状态码 %d，期望 200", resp.StatusCode)
	}
}
