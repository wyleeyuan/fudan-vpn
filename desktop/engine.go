package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// Phase 是隧道的状态，字符串直接给前端用。
type Phase string

const (
	PhaseIdle      Phase = "idle"
	PhaseLaunching Phase = "launching"
	PhaseConnected Phase = "connected"
	PhaseFailed    Phase = "failed"
)

// Engine 管 fudan-connect 子进程。
//
// 和 macOS 那边一样用子进程而不是把引擎编进来：引擎的初始化和登录流程
// 都在它的 main 里写死了，复用它最省事，进程退出也不会带走 GUI。
type Engine struct {
	mu       sync.Mutex
	cmd      *exec.Cmd
	phase    Phase
	failMsg  string
	connectedAt time.Time

	onLog   func(string)
	onPhase func(Phase, string)

	// 看到「SOCKS5 server listening」才算真的起来了
	ready bool

	// 分流口，前端要显示
	splitPort string
}

func NewEngine() *Engine {
	return &Engine{phase: PhaseIdle, splitPort: "1082"}
}

func (e *Engine) Phase() (Phase, string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.phase, e.failMsg
}

func (e *Engine) ConnectedSince() time.Time {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.connectedAt
}

func (e *Engine) setPhase(p Phase, msg string) {
	e.mu.Lock()
	e.phase = p
	e.failMsg = msg
	if p == PhaseConnected {
		e.connectedAt = time.Now()
	} else {
		e.connectedAt = time.Time{}
	}
	cb := e.onPhase
	e.mu.Unlock()
	if cb != nil {
		cb(p, msg)
	}
}

func (e *Engine) log(line string) {
	if cb := e.onLog; cb != nil {
		cb(line)
	}
}

// binaryPath 找引擎可执行文件。
//
// 打包后它在 Contents/Resources（macOS）、exe 同目录（Windows）、
// /usr/lib/fudan-vpn（Linux 的 deb）；从源码跑的时候在仓库的 Resources/。
func binaryPath() (string, error) {
	name := "fudan-connect"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}

	var candidates []string
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(dir, name),
			filepath.Join(dir, "..", "Resources", name),
		)
	}
	if wd, err := os.Getwd(); err == nil {
		candidates = append(candidates,
			filepath.Join(wd, name),
			filepath.Join(wd, "..", "Resources", name),
		)
	}
	candidates = append(candidates, "/usr/lib/fudan-vpn/"+name)

	for _, c := range candidates {
		if info, err := os.Stat(c); err == nil && !info.IsDir() {
			return filepath.Clean(c), nil
		}
	}
	return "", fmt.Errorf("找不到 %s，请确认它和程序放在同一目录下", name)
}

// Start 用授权码起隧道。
func (e *Engine) Start(code string, rulesPath string) error {
	e.Stop()

	bin, err := binaryPath()
	if err != nil {
		return err
	}

	args := []string{
		"-protocol", "atrust",
		"-server", "vpn.fudan.edu.cn",
		"-port", "443",
		"-auth-type", "auth/httpsOauth2",
		"-login-domain", "id.fudan.edu.cn",
		"-oauth2-code", code,
		"-socks-bind", "127.0.0.1:1080",
		"-http-bind", "127.0.0.1:1081",
		"-router-bind", "127.0.0.1:" + e.splitPort,
		"-router-rules", rulesPath,
		"-client-data-file", clientDataPath(),
	}

	cmd := exec.Command(bin, args...)
	// 系统里配的代理会把连校内服务器的流量也接管，绕出国再绕回来
	env := os.Environ()
	filtered := env[:0]
	for _, kv := range env {
		lower := strings.ToLower(kv)
		skip := false
		for _, key := range []string{"http_proxy=", "https_proxy=", "all_proxy=", "no_proxy="} {
			if strings.HasPrefix(lower, key) {
				skip = true
				break
			}
		}
		if !skip {
			filtered = append(filtered, kv)
		}
	}
	cmd.Env = filtered

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = cmd.Stdout

	e.mu.Lock()
	e.cmd = cmd
	e.mu.Unlock()

	e.setPhase(PhaseLaunching, "")
	if err := cmd.Start(); err != nil {
		e.setPhase(PhaseFailed, err.Error())
		return err
	}

	go e.pump(stdout)
	go func(c *exec.Cmd) {
		err := c.Wait()
		e.mu.Lock()
		stoppedByUs := e.cmd != c
		if !stoppedByUs {
			e.cmd = nil
		}
		e.mu.Unlock()

		if stoppedByUs {
			return
		}
		if err != nil {
			e.setPhase(PhaseFailed, "引擎退出了："+err.Error())
		} else {
			e.setPhase(PhaseIdle, "")
		}
	}(cmd)

	// 引擎起来要几秒，等它就绪再报 connected
	go func() {
		deadline := time.Now().Add(30 * time.Second)
		for time.Now().Before(deadline) {
			e.mu.Lock()
			alive := e.cmd == cmd
			e.mu.Unlock()
			if !alive {
				return
			}
			if e.sawReady() {
				e.setPhase(PhaseConnected, "")
				return
			}
			time.Sleep(200 * time.Millisecond)
		}
		e.setPhase(PhaseFailed, "30 秒内没有连上，看看日志")
	}()

	return nil
}

// stop 只做进程收尾，状态由调用方决定。
func (e *Engine) Stop() {
	e.mu.Lock()
	cmd := e.cmd
	e.cmd = nil
	e.mu.Unlock()
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Kill()
	_, _ = cmd.Process.Wait()
}

// Disconnect 是用户主动断开。
func (e *Engine) Disconnect() {
	e.Stop()
	e.mu.Lock()
	e.ready = false
	e.mu.Unlock()
	e.setPhase(PhaseIdle, "")
}

func (e *Engine) pump(r io.ReadCloser) {
	defer r.Close()
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), "\r")
		if strings.Contains(line, "SOCKS5 server listening") {
			e.mu.Lock()
			e.ready = true
			e.mu.Unlock()
		}
		e.log(line)
	}
}

func (e *Engine) sawReady() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.ready
}
