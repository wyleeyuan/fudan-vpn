package main

import (
	"os/exec"
	"runtime"
)

// openWithDefaultApp 用系统默认程序打开一个文件。
func openWithDefaultApp(path string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", "-t", path)
	case "windows":
		// start 是 cmd 内建命令，第一个空参数是窗口标题占位
		cmd = exec.Command("cmd", "/c", "start", "", path)
	default:
		cmd = exec.Command("xdg-open", path)
	}
	return cmd.Start()
}
