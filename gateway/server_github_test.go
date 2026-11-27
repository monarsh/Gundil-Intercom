//go:build updateserver

package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// GitHub's limit for checks without an account: a clear message, not "403".
func TestGithubRateLimitMessage(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		rw.Header().Set("X-RateLimit-Remaining", "0")
		rw.Header().Set("X-RateLimit-Reset", fmt.Sprint(time.Now().Add(20*time.Minute).Unix()))
		rw.WriteHeader(403)
	}))
	defer ts.Close()
	old := githubAPI
	githubAPI = ts.URL
	defer func() { githubAPI = old }()
	_, err := githubReleases("owner/repo")
	if err == nil || !strings.Contains(err.Error(), "60 checks an hour") || !strings.Contains(err.Error(), "min") {
		t.Fatalf("got %v", err)
	}
}
