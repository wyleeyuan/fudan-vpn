package service

import (
	"context"
	"errors"
	"net"
	"time"

	"github.com/mythologyli/zju-connect/dial"
	"github.com/mythologyli/zju-connect/internal/hook_func"
	"github.com/mythologyli/zju-connect/log"
	"github.com/mythologyli/zju-connect/resolve"
	"github.com/mythologyli/zju-connect/router"
	"github.com/things-go/go-socks5"
)

// ServeRouter 起一个带规则分流的 SOCKS5 服务。
//
// 和 ServeSocks5 的区别只在 Dial：那边把所有连接都交给隧道 dialer，
// 这边先查一遍规则，命中 TUNNEL 才交给隧道，否则走本机直连。
//
// 域名从 context 里取：上游的 Resolver 会在解析前把原始域名塞进
// resolve.ContextKeyResolveHost，所以 DOMAIN / DOMAIN-SUFFIX 这类规则
// 在 SOCKS5 握手只拿到 IP 的情况下依然有效。
func ServeRouter(bindAddr string, vpnDialer *dial.Dialer, resolver *resolve.Resolver, rt *router.Router) {
	direct := &net.Dialer{
		Timeout:   10 * time.Second,
		KeepAlive: 30 * time.Second,
	}

	dialFunc := func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, _ := ctx.Value(resolve.ContextKeyResolveHost).(string)

		var ip net.IP
		if hostPart, _, err := net.SplitHostPort(addr); err == nil {
			ip = net.ParseIP(hostPart)
		}

		if rt.Match(host, ip) == router.Tunnel {
			conn, err := vpnDialer.DialIPPort(ctx, network, addr)
			if err == nil {
				return conn, nil
			}
			// 隧道这条腿走不通就退回直连，有两种常见原因：
			//   1. ErrACLDenied：目标不在学校下发的资源列表里；
			//   2. 服务端拒绝：jwc、cs 这类公网站点会回
			//      "tcp tunnel connection not allowed"。
			// 这两种目标本来就公网可达，直连即可；真正的内网地址直连也到不了
			// （拨过去只会超时），所以回落不会把内网流量漏到公网。
			log.Printf("隧道拨号失败（%v），%s 改走直连", err, addr)
			if directConn, directErr := direct.DialContext(ctx, network, addr); directErr == nil {
				return directConn, nil
			}
			return nil, err
		}
		// 规则判为直连，但用户可能同时开着 Clash 翻墙。这条腿交给 dialer
		// 的直连分支走：配了 --dial-direct-proxy 就交给那个代理，没配就是普通直连。
		// 代理挂了就退回裸直连，别把国内站一起拖死。
		if vpnDialer != nil {
			if conn, err := vpnDialer.DialDirect(ctx, network, addr); err == nil {
				return conn, nil
			} else {
				log.Printf("直连代理不可用（%v），%s 改走裸直连", err, addr)
			}
		}
		return direct.DialContext(ctx, network, addr)
	}

	opts := []socks5.Option{
		socks5.WithDial(dialFunc),
		socks5.WithLogger(socks5.NewLogger(log.NewLogger("[router] "))),
	}
	// resolver 为 nil 时交给 go-socks5 自己的默认解析，方便单测直接起服务。
	if resolver != nil {
		opts = append(opts, socks5.WithResolver(resolver))
	}
	server := socks5.NewServer(opts...)

	log.Printf("分流 SOCKS5 监听 %s（规则 %d 条）", bindAddr, rt.Len())

	listener, err := net.Listen("tcp", bindAddr)
	if err != nil {
		panic("router listen failed: " + err.Error())
	}

	hook_func.RegisterTerminalFunc("CloseRouterListener", func(ctx context.Context) error {
		log.Println("Closing router listener...")
		return listener.Close()
	})

	if err := server.Serve(listener); err != nil {
		if errors.Is(err, net.ErrClosed) {
			log.Println("Router server closed")
		} else {
			log.Println("Router listen failed: " + err.Error())
		}
	}
}
