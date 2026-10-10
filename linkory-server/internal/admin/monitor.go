package admin

import (
	"context"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/linkory/linkory-server/internal/apiutil"
)

// Sample is one reading of this server process (and, on Linux, the host). Values that the platform cannot
// provide stay zero; the console hides what is zero-because-unknown via the *_known flags.
type Sample struct {
	At           time.Time `json:"at"`
	CPUPercent   float64   `json:"cpu_percent"` // process CPU, % of ONE core (can exceed 100 on multi-core)
	RSSBytes     uint64    `json:"rss_bytes"`   // resident memory of the process (Linux); Go runtime total elsewhere
	HeapBytes    uint64    `json:"heap_bytes"`
	Goroutines   int       `json:"goroutines"`
	Connections  int       `json:"connections"` // live WebSocket devices
	DBOpen       int       `json:"db_open"`
	DBInUse      int       `json:"db_in_use"`
	DBMax        int       `json:"db_max"`
	Load1        float64   `json:"load1"`
	LoadKnown    bool      `json:"load_known"`
	HostMemTotal uint64    `json:"host_mem_total"`
	HostMemAvail uint64    `json:"host_mem_available"`
	HostMemKnown bool      `json:"host_mem_known"`
	CPUs         int       `json:"cpus"`
}

const monitorHistory = 60 // samples kept (5 s apart = 5 minutes)

type monitor struct {
	mu       sync.Mutex
	history  []Sample
	lastCPU  time.Duration
	lastWall time.Time
}

// readProc returns the first matching "key: value kB" style or whitespace-separated fields of a /proc file.
func readProc(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}

func rssBytes() uint64 {
	// /proc/self/statm: size resident shared ... (pages)
	f := strings.Fields(readProc("/proc/self/statm"))
	if len(f) >= 2 {
		if pages, err := strconv.ParseUint(f[1], 10, 64); err == nil {
			return pages * uint64(os.Getpagesize())
		}
	}
	return 0
}

func hostMemory() (total, avail uint64, ok bool) {
	for _, line := range strings.Split(readProc("/proc/meminfo"), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		v, err := strconv.ParseUint(f[1], 10, 64)
		if err != nil {
			continue
		}
		switch f[0] {
		case "MemTotal:":
			total = v * 1024
		case "MemAvailable:":
			avail = v * 1024
		}
	}
	return total, avail, total > 0
}

func loadAverage() (float64, bool) {
	f := strings.Fields(readProc("/proc/loadavg"))
	if len(f) == 0 {
		return 0, false
	}
	v, err := strconv.ParseFloat(f[0], 64)
	return v, err == nil
}

// Sample takes a reading now and appends it to the history; CPU is measured against the previous reading.
func (s *Service) sample() Sample {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	now := time.Now().UTC()
	cpu := processCPUTime()
	out := Sample{At: now, HeapBytes: ms.HeapAlloc, Goroutines: runtime.NumGoroutine(), CPUs: runtime.NumCPU(), RSSBytes: rssBytes()}
	if out.RSSBytes == 0 {
		out.RSSBytes = ms.Sys
	}
	if s.Hub != nil {
		out.Connections = s.Hub.OnlineCount()
	}
	if s.DB != nil {
		st := s.DB.Stats()
		out.DBOpen, out.DBInUse, out.DBMax = st.OpenConnections, st.InUse, st.MaxOpenConnections
	}
	out.Load1, out.LoadKnown = loadAverage()
	out.HostMemTotal, out.HostMemAvail, out.HostMemKnown = hostMemory()

	m := &s.mon
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.lastWall.IsZero() {
		if wall := now.Sub(m.lastWall); wall > 0 && cpu >= m.lastCPU {
			out.CPUPercent = float64(cpu-m.lastCPU) / float64(wall) * 100
		}
	}
	m.lastCPU, m.lastWall = cpu, now
	m.history = append(m.history, out)
	if len(m.history) > monitorHistory {
		m.history = m.history[len(m.history)-monitorHistory:]
	}
	return out
}

// runMonitor samples every 5 seconds so the numbers do not depend on how many consoles are open.
func (s *Service) runMonitor(ctx context.Context) {
	s.sample()
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			s.sample()
		}
	}
}

func (s *Service) monitorHandler(w http.ResponseWriter, r *http.Request) {
	s.mon.mu.Lock()
	history := append([]Sample(nil), s.mon.history...)
	s.mon.mu.Unlock()
	if len(history) == 0 {
		history = []Sample{s.sample()}
	}
	apiutil.JSON(w, 200, map[string]any{"current": history[len(history)-1], "history": history, "interval_seconds": 5})
}
