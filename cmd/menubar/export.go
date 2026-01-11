package main

// #include <stdlib.h>
import "C"

import (
	"encoding/json"
	"fmt"
	"sync"
	"unsafe"

	"github.com/tw93/mole/pkg/metrics"
)

// Global collector instance
var (
	globalCollector *metrics.Collector
	collectorMutex  sync.Mutex
)

//export InitMetrics
func InitMetrics() *C.char {
	collectorMutex.Lock()
	defer collectorMutex.Unlock()

	globalCollector = metrics.NewCollector()

	return C.CString("OK")
}

//export GetMetricsJSON
func GetMetricsJSON() *C.char {
	collectorMutex.Lock()
	defer collectorMutex.Unlock()

	if globalCollector == nil {
		return C.CString(`{"error": "Collector not initialized. Call InitMetrics() first."}`)
	}

	snapshot, err := globalCollector.Collect()
	if err != nil {
		errMsg := fmt.Sprintf(`{"error": "%s"}`, err.Error())
		return C.CString(errMsg)
	}

	jsonData, err := json.Marshal(snapshot)
	if err != nil {
		errMsg := fmt.Sprintf(`{"error": "Failed to serialize metrics: %s"}`, err.Error())
		return C.CString(errMsg)
	}

	return C.CString(string(jsonData))
}

//export FreeString
func FreeString(s *C.char) {
	C.free(unsafe.Pointer(s))
}

//export CleanupMetrics
func CleanupMetrics() {
	collectorMutex.Lock()
	defer collectorMutex.Unlock()

	globalCollector = nil
}

// Required for c-shared build mode
func main() {}
