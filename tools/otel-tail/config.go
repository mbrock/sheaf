package main

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

func envDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// loadDotEnvFromCheckout walks up from the otel executable looking for a `.env`
// file at the root of a sheaf checkout, and merges its KEY=VALUE pairs into
// the process env without overriding values that are already set. This lets
// `bin/otel` pick up SHEAF_OTEL_* and SHEAF_NODE_BASENAME from the checkout's
// `.env` even when running from an interactive shell where the systemd service
// env is not visible.
func loadDotEnvFromCheckout() {
	exe, err := os.Executable()
	if err != nil {
		return
	}

	dir := filepath.Dir(exe)
	for i := 0; i < 6; i++ {
		candidate := filepath.Join(dir, ".env")
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			mergeDotEnv(candidate)
			return
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return
		}
		dir = parent
	}
}

func mergeDotEnv(path string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		value := strings.TrimSpace(line[eq+1:])
		if len(value) >= 2 {
			first, last := value[0], value[len(value)-1]
			if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
				value = value[1 : len(value)-1]
			}
		}
		if _, present := os.LookupEnv(key); !present {
			os.Setenv(key, value)
		}
	}
}
