package main

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/mythologyli/zju-connect/router"
	wailsruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// 复旦统一身份认证的授权入口。
//
// redirect_uri 必须和 aTrust 服务端下发的逐字一致，服务端会校验 sfDomain，
// 改一个字符 code 就换不回会话。
const (
	authHost  = "id.fudan.edu.cn"
	authPath  = "/idp/authCenter/authenticate"
	callHost  = "vpn.fudan.edu.cn"
	callPath  = "/passport/v1/auth/httpsOauth2"
	rulePath  = "sfDomain=id.fudan.edu.cn"
	maxLogLen = 800
)

// LoginURL 是点「登录」时用系统浏览器打开的那个地址。
func LoginURL() string {
	q := url.Values{}
	q.Set("client_id", "vpn")
	q.Set("redirect_uri", "https://"+callHost+callPath+"?"+rulePath)
	q.Set("response_type", "code")

	u := url.URL{Scheme: "https", Host: authHost, Path: authPath, RawQuery: q.Encode()}
	return u.String()
}

// ExtractCode 从登录完成后地址栏里那条 URL 取出授权码。
//
// 用户把整条 URL 粘进来就行，多余的参数、前后空格都容忍。
func ExtractCode(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", fmt.Errorf("没有粘贴内容")
	}
	// 有人会连 "code=" 一起复制，或者粘过来的是一段带引号的文本
	raw = strings.Trim(raw, "\"'<> ")

	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		// 退一步：直接在整段文本里找 code=
		if i := strings.Index(raw, "code="); i >= 0 {
			rest := raw[i+len("code="):]
			if j := strings.IndexAny(rest, "&# "); j >= 0 {
				rest = rest[:j]
			}
			if rest != "" {
				return rest, nil
			}
		}
		return "", fmt.Errorf("这不是一条完整的网址，需要包含 %s", callPath)
	}

	if !strings.EqualFold(u.Host, callHost) || !strings.Contains(u.Path, callPath) {
		return "", fmt.Errorf("这条网址不是登录回调，需要是 %s 开头", "https://"+callHost+callPath)
	}
	code := u.Query().Get("code")
	if code == "" {
		return "", fmt.Errorf("网址里没有 code 参数")
	}
	return code, nil
}

// App 是绑定给前端的对象，方法名就是前端能调的 API。
type App struct {
	ctx    context.Context
	engine *Engine

	mu   sync.Mutex
	logs []string
}

func NewApp() *App {
	a := &App{engine: NewEngine()}
	a.engine.onLog = func(line string) {
		a.appendLog(line)
		wailsruntime.EventsEmit(a.ctx, "log", line)
	}
	a.engine.onPhase = func(p Phase, msg string) {
		wailsruntime.EventsEmit(a.ctx, "phase", map[string]string{
			"phase": string(p),
			"error": msg,
		})
	}
	return a
}

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	ensureRulesFile()
}

func (a *App) shutdown(ctx context.Context) {
	a.engine.Stop()
}

func (a *App) appendLog(line string) {
	a.mu.Lock()
	a.logs = append(a.logs, line)
	if len(a.logs) > maxLogLen {
		a.logs = a.logs[len(a.logs)-maxLogLen:]
	}
	a.mu.Unlock()
}

// ---------------------------------------------------------------- 前端 API

// LoginURL 返回登录页地址，前端拿它显示成按钮。
func (a *App) LoginURL() string { return LoginURL() }

// OpenLogin 用系统浏览器打开登录页。
//
// 不做内嵌浏览器：三个平台的 WebView 拦截导航各是一套胶水，
// 而回调 URL 是固定的，让用户粘回来一步就够，出问题也好排查。
func (a *App) OpenLogin() {
	wailsruntime.BrowserOpenURL(a.ctx, LoginURL())
	a.appendLog("已在浏览器打开登录页，扫码后把地址栏那条网址复制回来")
	wailsruntime.EventsEmit(a.ctx, "log", "已在浏览器打开登录页，扫码后把地址栏那条网址复制回来")
}

// Connect 用回调 URL 里的授权码起隧道。
func (a *App) Connect(callbackURL string) (string, error) {
	code, err := ExtractCode(callbackURL)
	if err != nil {
		return "", err
	}
	if err := ensureRulesFile(); err != nil {
		return "", err
	}
	if err := a.engine.Start(code, RulesPath()); err != nil {
		return "", err
	}
	return code[:min(6, len(code))] + "…", nil
}

// Disconnect 断开隧道。
func (a *App) Disconnect() {
	a.engine.Disconnect()
}

// Status 给前端一次拿全状态。
func (a *App) Status() map[string]any {
	phase, msg := a.engine.Phase()
	since := a.engine.ConnectedSince()
	var sinceUnix int64
	if !since.IsZero() {
		sinceUnix = since.Unix()
	}
	return map[string]any{
		"phase":     string(phase),
		"error":     msg,
		"since":     sinceUnix,
		"splitPort": "1082",
		"rulesPath": RulesPath(),
	}
}

// Logs 返回历史日志（前端首次加载时补一次）。
func (a *App) Logs() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := make([]string, len(a.logs))
	copy(out, a.logs)
	return out
}

// ReadRules 读规则文件内容。
func (a *App) ReadRules() (string, error) {
	if err := ensureRulesFile(); err != nil {
		return "", err
	}
	data, err := os.ReadFile(RulesPath())
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// SaveRules 写回规则文件，写完立刻校验一遍，写错了当场报行号。
func (a *App) SaveRules(text string) error {
	if _, err := router.Parse(strings.NewReader(text)); err != nil {
		return err
	}
	return os.WriteFile(RulesPath(), []byte(text), 0o644)
}

// ValidateRules 只校验不保存，前端做实时提示用。
func (a *App) ValidateRules(text string) (int, error) {
	rt, err := router.Parse(strings.NewReader(text))
	if err != nil {
		return 0, err
	}
	return rt.Len(), nil
}

// OpenRules 用系统默认编辑器打开规则文件。
func (a *App) OpenRules() error {
	if err := ensureRulesFile(); err != nil {
		return err
	}
	return openWithDefaultApp(RulesPath())
}

// RevealRules 在文件管理器里定位规则文件。
func (a *App) RevealRules() error {
	if err := ensureRulesFile(); err != nil {
		return err
	}
	wailsruntime.BrowserOpenURL(a.ctx, "file://"+filepath.Dir(RulesPath()))
	return nil
}

// ---------------------------------------------------------------- 路径

// ConfigDir 是三平台的用户配置目录。
func ConfigDir() string {
	base, err := os.UserConfigDir()
	if err != nil {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, ".config")
	}
	return filepath.Join(base, "FudanVPN")
}

// RulesPath 是规则文件位置。
func RulesPath() string { return filepath.Join(ConfigDir(), "rules.conf") }

func clientDataPath() string {
	return filepath.Join(ConfigDir(), "client_data.json")
}

// ensureRulesFile 在文件不存在时放一份默认规则。
//
// 默认规则和引擎用的是同一份源（engine/router/default_rules.conf），
// 由构建脚本复制到程序旁边，这里只做拷贝，不硬编码文本。
func ensureRulesFile() error {
	path := RulesPath()
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	// 找构建时复制过来的模板
	var candidates []string
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(dir, "rules.conf"),
			filepath.Join(dir, "..", "Resources", "rules.conf"),
		)
	}
	if wd, err := os.Getwd(); err == nil {
		candidates = append(candidates,
			filepath.Join(wd, "rules.conf"),
			filepath.Join(wd, "..", "engine", "router", "default_rules.conf"),
		)
	}
	for _, c := range candidates {
		if data, err := os.ReadFile(c); err == nil {
			return os.WriteFile(path, data, 0o644)
		}
	}
	// 模板找不到也不能留空文件，否则用户一打开就是空白
	return os.WriteFile(path, []byte(router.DefaultRules), 0o644)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
