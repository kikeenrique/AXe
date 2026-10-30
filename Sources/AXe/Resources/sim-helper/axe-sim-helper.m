// axe-sim-helper runs inside a foldable iOS Simulator (started with `xcrun simctl spawn`) and posts
// the private HID events that Xcode's Device Hub uses for the hinge and the device orientation.
// AXe compiles it on first use for the iphonesimulator SDK and caches the ad-hoc signed binary.
//
//   axe-sim-helper hinge <degrees>                     set the hinge directly (0 closed, 180 flat)
//   axe-sim-helper hinge-sweep <from> <to> <seconds>   move the hinge with an eased 60 Hz sweep
//   axe-sim-helper hinge-angle                         print the CoreMotion hinge angle in degrees
//   axe-sim-helper orientation <value>                 portrait | pud | landscape-left | landscape-right |
//                                                      faceup | facedown (device orientation)
//
// Any command can be prefixed with `--deadline <seconds>` (a positive integer). The helper then
// exits through SIGALRM after that many seconds, so it stops even when the `xcrun simctl spawn`
// that started it was killed on the host after a timeout. AXe passes its spawn timeout here.
//
// Vendor event format: usage page 0xFF61, usage 0x5B, carrying an IOCFSerialize binary dictionary
// { provider, source, type, value }. locationd turns it into a hinge angle or a device orientation:
//
//   hinge        source "hinge-slider-control"        type "range"  value <degrees>
//   orientation  source "orientation-picker-control"  type "enum"   value <device orientation>
//
// The provider name differs between CoreSimulator versions, so every event is sent under both
// "com.apple.Virtualization.VirtualMachines" and "com.apple.Virtualization". Each event carries an
// absolute value, so the duplicate is harmless.
//
// The hinge angle is read from CoreMotion's private CMAngleManager, the source UIKit's UIHinge reads.
//
// Derived from two MIT-licensed projects:
//
//   hinge, https://github.com/artemnovichkov/hinge
//   Copyright (c) 2026 Artem Novichkov
//   (vendor event format, CMAngleManager readback)
//
//   duoctl, https://github.com/skarol/duoctl
//   Copyright (c) 2026 Karolina Samorek
//   (both provider names, eased sweep, settle delay)
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
//   associated documentation files (the "Software"), to deal in the Software without restriction,
//   including without limitation the rights to use, copy, modify, merge, publish, distribute,
//   sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
//   furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all copies or
//   substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
//   NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
//   OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import <Foundation/Foundation.h>
#import <mach/mach_time.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef, int, CFDictionaryRef);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);
extern CFDataRef IOCFSerialize(CFTypeRef, CFOptionFlags);
extern IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(CFAllocatorRef, uint64_t, uint32_t usagePage, uint32_t usage,
    uint32_t version, const uint8_t *data, CFIndex length, uint32_t options);

enum {
    kClientTypeSimple = 4,
    kSerializeBinary = 1,
    kVendorUsagePage = 0xFF61,
    kVendorUsage = 0x5B,
    kExitUsage = 64,
};

static const double kSweepRate = 60.0;
// The event system delivers asynchronously; exiting at once can drop the last event.
static const useconds_t kSettleMicros = 100000;
static const CFTimeInterval kAngleTimeout = 2;
static const CFTimeInterval kRunLoopSlice = 0.05;

#pragma mark - Device state events

static NSArray<NSString *> *deviceStateProviders(void) {
    return @[ @"com.apple.Virtualization.VirtualMachines", @"com.apple.Virtualization" ];
}

static void dispatchDeviceState(IOHIDEventSystemClientRef client, NSString *source, NSString *type, id value) {
    for (NSString *provider in deviceStateProviders()) {
        NSDictionary *payload = @{
            @"provider": provider,
            @"source": source,
            @"type": type,
            @"value": value,
        };
        CFDataRef serialized = IOCFSerialize((__bridge CFTypeRef)payload, kSerializeBinary);
        if (!serialized) {
            fprintf(stderr, "axe-sim-helper: could not serialize the %s event\n", source.UTF8String);
            continue;
        }
        IOHIDEventRef event = IOHIDEventCreateVendorDefinedEvent(NULL, mach_absolute_time(), kVendorUsagePage,
            kVendorUsage, 0, CFDataGetBytePtr(serialized), CFDataGetLength(serialized), 0);
        if (event) {
            IOHIDEventSystemClientDispatchEvent(client, event);
            CFRelease(event);
        } else {
            fprintf(stderr, "axe-sim-helper: could not create the %s event\n", source.UTF8String);
        }
        CFRelease(serialized);
    }
}

static IOHIDEventSystemClientRef createClient(void) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateWithType(NULL, kClientTypeSimple, NULL);
    if (!client) fprintf(stderr, "axe-sim-helper: could not create a HID event system client\n");
    return client;
}

static void finishClient(IOHIDEventSystemClientRef client) {
    usleep(kSettleMicros);
    CFRelease(client);
}

static double clampAngle(double degrees) {
    return fmin(fmax(degrees, 0), 180);
}

static int setHinge(double degrees) {
    IOHIDEventSystemClientRef client = createClient();
    if (!client) return 1;
    dispatchDeviceState(client, @"hinge-slider-control", @"range", @(clampAngle(degrees)));
    finishClient(client);
    return 0;
}

/// Moves the hinge in eased steps at 60 Hz, like Device Hub's slider. An instant jump between
/// closed and open leaves the iOS 27.1 runtime unable to switch screens.
static int sweepHinge(double from, double to, double seconds) {
    IOHIDEventSystemClientRef client = createClient();
    if (!client) return 1;
    from = clampAngle(from);
    to = clampAngle(to);
    int steps = MAX(1, (int)lround(seconds * kSweepRate));
    for (int step = 1; step <= steps; step++) {
        double t = (double)step / steps;
        double eased = t * t * (3 - 2 * t);
        dispatchDeviceState(client, @"hinge-slider-control", @"range", @(from + (to - from) * eased));
        if (step < steps) usleep((useconds_t)(1e6 / kSweepRate));
    }
    finishClient(client);
    return 0;
}

static int setOrientation(NSString *value) {
    IOHIDEventSystemClientRef client = createClient();
    if (!client) return 1;
    dispatchDeviceState(client, @"orientation-picker-control", @"enum", value);
    finishClient(client);
    return 0;
}

#pragma mark - Hinge angle

@interface CMAngle : NSObject
- (float)angleDegrees;
@end

@interface CMAngleManager : NSObject
+ (BOOL)isAvailable;
- (void)startAngleUpdatesToQueue:(NSOperationQueue *)queue handler:(void (^)(CMAngle *angle))handler;
- (void)stopAngleUpdates;
@end

/// Prints the current hinge angle. CoreMotion delivers the current value right after updates start.
static int printHingeAngle(void) {
    Class managerClass = NSClassFromString(@"CMAngleManager");
    if (!managerClass || ![managerClass isAvailable]) {
        fprintf(stderr, "axe-sim-helper: this simulator reports no hinge\n");
        return 1;
    }
    CMAngleManager *manager = [[managerClass alloc] init];
    dispatch_semaphore_t received = dispatch_semaphore_create(0);
    __block double degrees = 0;
    __block BOOL delivered = NO;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    [manager startAngleUpdatesToQueue:queue handler:^(CMAngle *angle) {
        if (delivered) return;
        delivered = YES;
        degrees = [angle angleDegrees];
        dispatch_semaphore_signal(received);
    }];

    // The run loop runs in slices so the manager can deliver while the main thread waits.
    BOOL printed = NO;
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + kAngleTimeout;
    while (CFAbsoluteTimeGetCurrent() < deadline) {
        if (dispatch_semaphore_wait(received, DISPATCH_TIME_NOW) == 0) {
            printed = YES;
            break;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, kRunLoopSlice, false);
    }
    [manager stopAngleUpdates];
    if (!printed) {
        fprintf(stderr, "axe-sim-helper: timed out reading the hinge angle\n");
        return 1;
    }
    printf("%.1f\n", degrees);
    fflush(stdout);
    return 0;
}

#pragma mark - Entry point

static int usage(void) {
    fprintf(stderr,
            "usage: axe-sim-helper [--deadline <seconds>] hinge <degrees>\n"
            "       axe-sim-helper [--deadline <seconds>] hinge-sweep <from> <to> <seconds>\n"
            "       axe-sim-helper [--deadline <seconds>] hinge-angle\n"
            "       axe-sim-helper [--deadline <seconds>] orientation "
            "<portrait|pud|landscape-left|landscape-right|faceup|facedown>\n");
    return kExitUsage;
}

static BOOL parseNumber(const char *text, double *value) {
    char *end = NULL;
    double parsed = strtod(text, &end);
    if (end == text || *end != '\0' || !isfinite(parsed)) return NO;
    *value = parsed;
    return YES;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc >= 3 && strcmp(argv[1], "--deadline") == 0) {
            double deadline;
            if (!parseNumber(argv[2], &deadline) || deadline < 1 || deadline > 3600) return usage();
            // The default SIGALRM action terminates the process.
            alarm((unsigned)ceil(deadline));
            argc -= 2;
            argv += 2;
        }
        if (argc < 2) return usage();
        NSString *command = @(argv[1]);

        if ([command isEqualToString:@"hinge"] && argc == 3) {
            double degrees;
            if (!parseNumber(argv[2], &degrees)) return usage();
            return setHinge(degrees);
        }
        if ([command isEqualToString:@"hinge-sweep"] && argc == 5) {
            double from, to, seconds;
            if (!parseNumber(argv[2], &from) || !parseNumber(argv[3], &to) || !parseNumber(argv[4], &seconds)) {
                return usage();
            }
            return sweepHinge(from, to, fmax(seconds, 0));
        }
        if ([command isEqualToString:@"hinge-angle"] && argc == 2) {
            return printHingeAngle();
        }
        if ([command isEqualToString:@"orientation"] && argc == 3) {
            NSSet<NSString *> *valid = [NSSet setWithArray:@[ @"portrait", @"pud", @"landscape-left",
                                                              @"landscape-right", @"faceup", @"facedown" ]];
            NSString *value = @(argv[2]);
            if (![valid containsObject:value]) return usage();
            return setOrientation(value);
        }
        return usage();
    }
}
