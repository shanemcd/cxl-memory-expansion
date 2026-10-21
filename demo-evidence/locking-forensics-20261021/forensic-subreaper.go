package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	if len(os.Args) < 2 {
		os.Exit(2)
	}
	_, _, e := syscall.Syscall6(syscall.SYS_PRCTL, 36, 1, 0, 0, 0, 0)
	if e != 0 {
		panic(e)
	}
	p, err := os.StartProcess(os.Args[1], os.Args[1:], &os.ProcAttr{Env: os.Environ(), Files: []*os.File{os.Stdin, os.Stdout, os.Stderr}})
	if err != nil {
		panic(err)
	}
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		for s := range ch {
			_ = p.Signal(s)
		}
	}()
	for {
		var st syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &st, 0, nil)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if pid == p.Pid {
			os.Exit(st.ExitStatus())
		}
	}
}
