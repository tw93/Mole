//go:build darwin && cgo

package main

/*
#cgo LDFLAGS: -framework CoreFoundation -lIOReport
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <time.h>
#include <stdint.h>

// Private IOReport API — no public header, symbols live in /usr/lib/libIOReport.dylib.
// This is how tools like macmon read power without root; it is undocumented and
// may change between macOS releases, which is why the reader fails soft (-1).
typedef struct __IOReportSubscription* IOReportSubscriptionRef;
typedef CFDictionaryRef IOReportSampleRef;

extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
extern IOReportSubscriptionRef IOReportCreateSubscription(void* a, CFMutableDictionaryRef channels, CFMutableDictionaryRef* subbed, uint64_t d, CFTypeRef e);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub, CFMutableDictionaryRef channels, CFTypeRef a);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, CFTypeRef a);
extern void IOReportIterate(CFDictionaryRef samples, int(^cb)(IOReportSampleRef ch));
extern CFStringRef IOReportChannelGetGroup(IOReportSampleRef ch);
extern CFStringRef IOReportChannelGetChannelName(IOReportSampleRef ch);
extern CFStringRef IOReportChannelGetUnitLabel(IOReportSampleRef ch);
extern int64_t IOReportSimpleGetIntegerValue(IOReportSampleRef ch, int index);

static int cfstr(CFStringRef s, char* buf, int n) {
    if (!s) { buf[0] = 0; return 0; }
    return CFStringGetCString(s, buf, n, kCFStringEncodingUTF8);
}

// mole_read_gpu_power_watts returns average GPU power in watts over `interval`
// seconds, or -1 on failure. It reads the "Energy Model" IOReport group, takes
// two samples, and divides the GPU energy delta by the elapsed time. No root.
static double mole_read_gpu_power_watts(double interval) {
    CFMutableDictionaryRef channels = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!channels) return -1;

    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, channels, &subbed, 0, NULL);
    if (!sub) { CFRelease(channels); return -1; }

    CFDictionaryRef s1 = IOReportCreateSamples(sub, subbed, NULL);

    struct timespec ts;
    ts.tv_sec = (time_t)interval;
    ts.tv_nsec = (long)((interval - (double)ts.tv_sec) * 1e9);
    nanosleep(&ts, NULL);

    CFDictionaryRef s2 = IOReportCreateSamples(sub, subbed, NULL);

    // The private API returns NULL on some machines / macOS versions. Delta needs
    // both samples, and IOReportIterate dereferences its argument, so guard both:
    // a missing sample or delta means "unavailable", which the reader reports as -1.
    CFDictionaryRef delta = NULL;
    if (s1 && s2) delta = IOReportCreateSamplesDelta(s1, s2, NULL);

    __block double joules = -1;
    if (delta) IOReportIterate(delta, ^int(IOReportSampleRef ch) {
        char grp[128], name[128], unit[32];
        cfstr(IOReportChannelGetGroup(ch), grp, sizeof(grp));
        cfstr(IOReportChannelGetChannelName(ch), name, sizeof(name));
        // Match the "GPU Energy" aggregate exactly, not any name containing "GPU".
        // The Energy Model group also carries per-rail channels (GPU0, GPU SRAM0,
        // ...) that read 0 mJ; a substring match with no break let whichever GPU
        // channel iterated last win, so a reordered iteration could silently pin
        // the reading to a 0-value rail. "GPU Energy" (nJ) is the whole-device
        // total macmon/asitop read.
        if (strcmp(grp, "Energy Model") == 0 && strcmp(name, "GPU Energy") == 0) {
            int64_t v = IOReportSimpleGetIntegerValue(ch, 0);
            cfstr(IOReportChannelGetUnitLabel(ch), unit, sizeof(unit));
            double scale = 1e-3; // assume mJ if the unit label is unrecognised
            if (strstr(unit, "nJ")) scale = 1e-9;
            else if (strstr(unit, "uJ") || strstr(unit, "\xc2\xb5J")) scale = 1e-6;
            else if (strstr(unit, "mJ")) scale = 1e-3;
            else if (strstr(unit, "J")) scale = 1.0;
            joules = (double)v * scale;
        }
        return 0;
    });

    if (s1) CFRelease(s1);
    if (s2) CFRelease(s2);
    if (delta) CFRelease(delta);
    // subbed (the subscribed-channels dict) and sub (the subscription itself) are
    // created every call; without releasing them each sample leaks a CF dict and a
    // kernel-backed IOReport subscription. Sampling every ~2s, that accumulation is
    // what eventually stalls the status TUI. Release sub before channels since the
    // subscription references the channel set.
    if (subbed) CFRelease(subbed);
    if (sub) CFRelease((CFTypeRef)sub);
    if (channels) CFRelease(channels);

    if (joules < 0) return -1;
    return joules / interval;
}
*/
import "C"

import "time"

// readGPUPowerWatts samples GPU power over the given window via IOReport. It
// blocks for roughly `window` and returns -1 when the figure is unavailable.
func readGPUPowerWatts(window time.Duration) float64 {
	return float64(C.mole_read_gpu_power_watts(C.double(window.Seconds())))
}
