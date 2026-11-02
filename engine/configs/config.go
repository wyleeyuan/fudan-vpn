package configs

type Config struct {
	// Common fields
	Protocol            string                 `koanf:"protocol"`
	ServerAddress       string                 `koanf:"server_address"`
	ServerPort          int                    `koanf:"server_port"`
	Username            string                 `koanf:"username"`
	Password            string                 `koanf:"password"`
	TOTPSecret          string                 `koanf:"totp_secret"`
	SocksBind           string                 `koanf:"socks_bind"`
	RouterBind          string                 `koanf:"router_bind"`
	RouterRules         string                 `koanf:"router_rules"`
	SocksUser           string                 `koanf:"socks_user"`
	SocksPasswd         string                 `koanf:"socks_passwd"`
	HTTPBind            string                 `koanf:"http_bind"`
	PortForwardingList  []SinglePortForwarding `koanf:"port_forwarding"`
	ShadowsocksURL      string                 `koanf:"shadowsocks_url"`
	DialDirectProxy     string                 `koanf:"dial_direct_proxy"`
	DisableServerConfig bool                   `koanf:"disable_server_config"`
	DisableRemoteDNS    bool                   `koanf:"disable_remote_dns"`
	DNSTTL              uint64                 `koanf:"dns_ttl"`
	RemoteDNSServer     string                 `koanf:"remote_dns_server"`
	SecondaryDNSServer  string                 `koanf:"secondary_dns_server"`
	DNSServerBind       string                 `koanf:"dns_server_bind"`
	LocalDNSServer      string                 `koanf:"local_dns_server"`
	CustomDNSList       []SingleCustomDNS      `koanf:"custom_dns"`
	DisableKeepAlive    bool                   `koanf:"disable_keep_alive"`
	KeepAliveURL        string                 `koanf:"keep_alive_url"`
	TCPTunnelMode       bool                   `koanf:"tcp_tunnel_mode"`
	TUNMode             bool                   `koanf:"tun_mode"`
	AddRoute            bool                   `koanf:"add_route"`
	DNSHijack           bool                   `koanf:"dns_hijack"`
	ProxyAll            bool                   `koanf:"proxy_all"`
	FakeIP              bool                   `koanf:"fake_ip"`
	GraphCodeFile       string                 `koanf:"graph_code_file"`
	DebugDump           bool                   `koanf:"debug_dump"`
	DebugPCAPFile       string                 `koanf:"debug_pcap_file"`
	DebugTLSLogFile     string                 `koanf:"debug_tls_log_file"`
	BindInterface       string                 `koanf:"bind_interface"`
	AutoDetectInterface bool                   `koanf:"auto_detect_interface"`

	// NoUpstream 关掉「非校内流量转交本机其他代理」这条腿。
	//
	// 本程序自己被别的代理当成上游时（Clash 把 fudan.edu.cn 指到分流口）
	// 必须打开：那些域名里有一部分会判成 DIRECT，再交回上游就又回到 Clash，
	// 形成 1082 -> 7890 -> 1082 的无限递归。
	NoUpstream bool `koanf:"no_upstream"`

	// EasyConnect fields
	CertFile           string   `koanf:"cert_file"`
	CertPassword       string   `koanf:"cert_password"`
	DisableZJUConfig   bool     `koanf:"disable_zju_config"`
	SkipDomainResource bool     `koanf:"skip_domain_resource"`
	DisableMultiLine   bool     `koanf:"disable_multi_line"`
	CustomProxyDomain  []string `koanf:"custom_proxy_domain"`
	TwfID              string   `koanf:"twf_id"`

	// aTrust fields
	AuthType                string   `koanf:"auth_type"`
	Phone                   string   `koanf:"phone"`
	LoginDomain             string   `koanf:"login_domain"`
	ClientDataFile          string   `koanf:"client_data_file"`
	CasTicket               string   `koanf:"cas_ticket"`
	OAuth2Code              string   `koanf:"oauth2_code"`
	SID                     string   `koanf:"sid"`
	DeviceID                string   `koanf:"device_id"`
	MACAddresses            []string `koanf:"mac_addresses"`
	SignKey                 string   `koanf:"sign_key"`
	ResourceFile            string   `koanf:"resource_file"`
	UpdateBestNodesInterval int      `koanf:"update_best_nodes_interval"`
	SessionRefreshInterval  int      `koanf:"session_refresh_interval"`

	// 只用 client_data 里的 cookie 恢复会话，不发起交互式登录。
	// 服务端还认这份会话就直接进（aTrust 的 isLogin=1），不认就返回
	// auth.ErrNotLoggedIn，由调用方决定要不要让用户重新登录。
	ReuseSession bool `koanf:"reuse_session"`
}

type SinglePortForwarding struct {
	NetworkType   string `koanf:"network_type"`
	BindAddress   string `koanf:"bind_address"`
	RemoteAddress string `koanf:"remote_address"`
}

type SingleCustomDNS struct {
	HostName string `koanf:"host_name"`
	IP       string `koanf:"ip"`
}

func Default() Config {
	return Config{
		Protocol:                "easyconnect",
		ServerPort:              443,
		SocksBind:               ":1080",
		HTTPBind:                ":1081",
		DNSTTL:                  3600,
		RemoteDNSServer:         "auto",
		SecondaryDNSServer:      "auto",
		LoginDomain:             "Radius",
		UpdateBestNodesInterval: 300,
		SessionRefreshInterval:  1800,
	}
}
