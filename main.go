package main

import (
	"fmt"
	"os"
	"time"
)

func main() {
	// time.Tick is intentionally used here because this is a short-lived
	// detection lab process that runs until it is terminated.
	ticks := time.Tick(3 * time.Second)

	fmt.Printf("Go detection lab | PID=%d | executable=%s\n", os.Getpid(), os.Args[0])
	for tick := range ticks {
		fmt.Printf("heartbeat | PID=%d | time=%s\n", os.Getpid(), tick.UTC().Format(time.RFC3339))
	}
}
