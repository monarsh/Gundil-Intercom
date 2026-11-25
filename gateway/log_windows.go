//go:build windows

package main

import (
	"io"
	"log"
)

func logToEventLog(w io.Writer) { log.SetOutput(w) }
