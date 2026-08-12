package main

import (
	"log"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/abcdlsj/den/RelayService/internal/controlplane"
)

func main() {
	address := env("BURROW_RELAY_LISTEN", ":8080")
	server, err := controlplane.NewServer(controlplane.Config{
		PublicURL:     env("BURROW_RELAY_PUBLIC_URL", "http://127.0.0.1:8080"),
		AdminToken:    os.Getenv("BURROW_RELAY_ADMIN_TOKEN"),
		SigningKey:    []byte(os.Getenv("BURROW_RELAY_SIGNING_KEY")),
		DataURL:       env("BURROW_RELAY_DATA", "./data/registry.json"),
		AllowedOrigin: os.Getenv("BURROW_RELAY_ALLOWED_ORIGIN"),
		PairingTTL:    10 * time.Minute,
		AccessTTL:     30 * 24 * time.Hour,
		Logger:        slog.Default(),
	})
	if err != nil {
		log.Fatal(err)
	}
	slog.Info("Burrow Relay listening", "address", address)
	httpServer := &http.Server{
		Addr: address, Handler: server,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    32 * 1024,
	}
	log.Fatal(httpServer.ListenAndServe())
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
