// inventory: stock counts kept in Redis.
//
// No tracing / OpenTelemetry code on purpose: OBI must see it from the kernel
// (and, for Go, via uprobes on net/http and the Redis client inside this binary).
//
// Env: PORT (default 8080), REDIS_ADDR (default redis:6379)
package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/redis/go-redis/v9"
)

// Seed stock, written once at startup if the key does not exist yet.
var seed = map[string]int64{"apple": 100, "banana": 150, "cherry": 80}

var rdb *redis.Client

func stockKey(item string) string { return "stock:" + item }

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

// GET /items -> all items with stock
func listItems(w http.ResponseWriter, r *http.Request) {
	out := map[string]int64{}
	for item := range seed {
		n, err := rdb.Get(r.Context(), stockKey(item)).Int64()
		if err != nil {
			writeJSON(w, 500, map[string]string{"error": err.Error()})
			return
		}
		out[item] = n
	}
	writeJSON(w, 200, out)
}

// GET /items/{id} -> stock of one item
func getItem(w http.ResponseWriter, r *http.Request) {
	item := r.PathValue("id")
	n, err := rdb.Get(r.Context(), stockKey(item)).Int64()
	if err == redis.Nil {
		writeJSON(w, 404, map[string]string{"error": "unknown item"})
		return
	} else if err != nil {
		writeJSON(w, 500, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, 200, map[string]any{"item": item, "stock": n})
}

// POST /reserve {"item":"apple","qty":2} -> take stock (409 if not enough)
func reserve(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Item string `json:"item"`
		Qty  int64  `json:"qty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Item == "" || req.Qty <= 0 {
		writeJSON(w, 400, map[string]string{"error": "item and qty>0 are required"})
		return
	}
	if _, ok := seed[req.Item]; !ok {
		writeJSON(w, 404, map[string]string{"error": "unknown item"})
		return
	}
	left, err := rdb.DecrBy(r.Context(), stockKey(req.Item), req.Qty).Result()
	if err != nil {
		writeJSON(w, 500, map[string]string{"error": err.Error()})
		return
	}
	if left < 0 { // not enough: give it back
		rdb.IncrBy(r.Context(), stockKey(req.Item), req.Qty)
		writeJSON(w, 409, map[string]string{"error": "out of stock"})
		return
	}
	writeJSON(w, 200, map[string]any{"item": req.Item, "reserved": req.Qty, "left": left})
}

// POST /restock -> reset all items to seed values (lets loadgen run forever)
func restock(w http.ResponseWriter, r *http.Request) {
	for item, n := range seed {
		if err := rdb.Set(r.Context(), stockKey(item), n, 0).Err(); err != nil {
			writeJSON(w, 500, map[string]string{"error": err.Error()})
			return
		}
	}
	writeJSON(w, 200, seed)
}

func main() {
	port := getenv("PORT", "8080")
	rdb = redis.NewClient(&redis.Options{Addr: getenv("REDIS_ADDR", "redis:6379")})

	// Seed stock; retry until Redis is reachable.
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		err := func() error {
			for item, n := range seed {
				if err := rdb.SetNX(ctx, stockKey(item), n, 0).Err(); err != nil {
					return err
				}
			}
			return nil
		}()
		cancel()
		if err == nil {
			break
		}
		log.Printf("waiting for redis: %v", err)
		time.Sleep(2 * time.Second)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /items", listItems)
	mux.HandleFunc("GET /items/{id}", getItem)
	mux.HandleFunc("POST /reserve", reserve)
	mux.HandleFunc("POST /restock", restock)

	log.Printf("inventory listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
