package main

import (
	"encoding/binary"
	"math"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
)

// AppleSMC's external method 2 takes an 80-byte SMCParamStruct. Only the
// key info, command, result and payload are needed for read-only queries.
type smcKeyData struct {
	key      uint32
	_        [24]byte // version and power limits
	dataSize uint32
	dataType uint32
	_        [4]byte // attributes and alignment
	result   uint8
	_        uint8 // status
	command  uint8
	_        uint8
	_        uint32
	data     [32]byte
}

type smcPowerAPI struct {
	matching func(string) uintptr
	service  func(uint32, uintptr) uint32
	release  func(uint32) int32
	taskSelf func() uint32
	open     func(uint32, uint32, uint32, *uint32) int32
	close    func(uint32) int32
	call     func(uint32, uint32, *smcKeyData, uintptr, *smcKeyData, *uintptr) int32
}

// Bind the system framework once. The release build has CGO_ENABLED=0.
var loadSMCPowerAPI = sync.OnceValue(func() *smcPowerAPI {
	lib, err := purego.Dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", purego.RTLD_LAZY|purego.RTLD_LOCAL)
	if err != nil {
		return nil
	}
	api := new(smcPowerAPI)
	for name, fn := range map[string]any{
		"IOServiceMatching":           &api.matching,
		"IOServiceGetMatchingService": &api.service,
		"IOObjectRelease":             &api.release,
		"mach_task_self":              &api.taskSelf,
		"IOServiceOpen":               &api.open,
		"IOServiceClose":              &api.close,
		"IOConnectCallStructMethod":   &api.call,
	} {
		addr, err := purego.Dlsym(lib, name)
		if err != nil {
			_ = purego.Dlclose(lib)
			return nil
		}
		purego.RegisterFunc(fn, addr)
	}
	return api
})

func readSMCDesktopPower() float64 {
	api := loadSMCPowerAPI()
	if api == nil {
		return 0
	}
	matching := api.matching("AppleSMC")
	if matching == 0 {
		return 0
	}
	service := api.service(0, matching)
	if service == 0 {
		return 0
	}
	defer api.release(service)
	var conn uint32
	if api.open(service, api.taskSelf(), 0, &conn) != 0 {
		return 0
	}
	defer api.close(conn)

	return desktopSMCWatts(func(key string) float64 { return api.readFloat(conn, key) })
}

func desktopSMCWatts(read func(string) float64) float64 {
	if watts := read("PSTR"); watts > 0 && watts < 1000 {
		return watts
	}
	volts := read("VD0R")
	amps := read("ID0R")
	if watts := volts * amps; volts > 0 && amps > 0 && watts < 1000 {
		return watts
	}
	return 0
}

func (api *smcPowerAPI) readFloat(conn uint32, key string) float64 {
	const (
		readKeyInfo = 9
		readBytes   = 5
		floatType   = 0x666c7420 // "flt "
	)
	in := smcKeyData{key: binary.BigEndian.Uint32([]byte(key)), command: readKeyInfo}
	var out smcKeyData
	query := func() bool {
		size := unsafe.Sizeof(out)
		out = smcKeyData{}
		return api.call(conn, 2, &in, unsafe.Sizeof(in), &out, &size) == 0 &&
			size == unsafe.Sizeof(out) && out.result == 0
	}
	if !query() || out.dataType != floatType || out.dataSize != 4 {
		return 0
	}
	in.command, in.dataSize = readBytes, out.dataSize
	if !query() {
		return 0
	}
	return float64(math.Float32frombits(binary.LittleEndian.Uint32(out.data[:4])))
}
