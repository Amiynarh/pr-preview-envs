package main

import (
	"fmt"
	"net/http"
	"os"
)

// These values are empty at compile time and get injected by the
// linker via -ldflags -X during the Docker build. See the Dockerfile.
var (
	prNumber = "local"
	gitSha   = "dev"
)

func handler(w http.ResponseWriter, r *http.Request) {
	// Kubernetes injects these via the Downward API — see deployment.yaml
	namespace := os.Getenv("POD_NAMESPACE")
	podName := os.Getenv("POD_NAME")

	if namespace == "" {
		namespace = "not-in-kubernetes"
	}
	if podName == "" {
		podName, _ = os.Hostname()
	}

	fmt.Fprintf(w, "Preview environment is live\n\n")
	fmt.Fprintf(w, "PR number  : %s\n", prNumber)
	fmt.Fprintf(w, "Git SHA    : %s\n", gitSha)
	fmt.Fprintf(w, "Namespace  : %s\n", namespace)
	fmt.Fprintf(w, "Pod name   : %s\n", podName)
}

func healthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	fmt.Fprintln(w, "ok")
}

func main() {
	http.HandleFunc("/", handler)
	http.HandleFunc("/healthz", healthz)

	fmt.Println("Server starting on port 8080...")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		fmt.Fprintf(os.Stderr, "server error: %v\n", err)
		os.Exit(1)
	}
}
