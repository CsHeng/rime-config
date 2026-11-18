// Command rime-config updates Wanxiang Rime resources, composes layered
// configuration and distributes it to the selected Rime frontends.
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"rime-config-go/internal/app"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	os.Exit(app.New().Run(ctx, os.Args[1:]))
}
