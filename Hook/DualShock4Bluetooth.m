// DualShock4Bluetooth — makes PS4 controllers connected over Bluetooth readable for games that read HID elements.
//
// macOS switches a Bluetooth DUALSHOCK 4 to its extended input report (ID 0x11), which the controller's HID
// descriptor only describes as one opaque vendor field. Games that read buttons and sticks as HID elements
// (Unity's legacy input up to at least 2017.4, many older engines) then see the controller but never get a
// single value from it. This file reads the controllers on its own thread, decodes report 0x11 and feeds the
// values to the game through the element API it already uses: input value callbacks (run on the run loop the
// game scheduled its HID manager on), IOHIDQueue polling and IOHIDDeviceGetValue.
//
// Games that parse raw reports (SDL/hidapi) or use the GameController framework are unaffected: they never ask
// for these elements' values.

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDLib.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <os/lock.h>

void SofaSplitHookLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

// Element slots, in the order of the controller's standard report 0x01.
enum { kButtons = 14, kSlotX = kButtons, kSlotY, kSlotZ, kSlotRz, kSlotRx, kSlotRy, kSlotHat, kSlots };

typedef struct { IOHIDValueCallback cb; void *ctx; } NHValueTarget;

@interface NHPad : NSObject {
@public
    IOHIDDeviceRef device;
    uint64_t registryID;  // the physical controller, shared by every IOHIDDeviceRef for it
    IOHIDElementRef elements[kSlots];
    IOHIDElementCookie cookies[kSlots];
    int32_t values[kSlots];
    IOHIDValueRef lastRead[kSlots];  // IOHIDDeviceGetValue hands out unowned values: keep the latest alive
    NSMutableArray<NSValue *> *targets;  // NHValueTarget
}
@end
@implementation NHPad
@end

@interface NHQueue : NSObject {
@public
    NHPad *pad;
    BOOL slots[kSlots];
    CFMutableArrayRef pending;  // IOHIDValueRef
}
@end
@implementation NHQueue
@end

static void StartReader(void);
static BOOL gEnabled;
// Diagnostics (SOFASPLIT_HOOK_DEBUG=1): what the game does with the decoded values.
static _Atomic long gReports, gDelivered, gQueuePolls, gQueueServed, gGetValues, gGetValuesServed, gCallbacks;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef gPads;    // IOHIDDeviceRef -> NHPad (NSNull when not a Bluetooth DS4)
static CFMutableDictionaryRef gQueues;  // IOHIDQueueRef -> NHQueue
static CFRunLoopRef gGameRunLoop;      // where the game's HID manager delivers callbacks
static CFStringRef gGameRunLoopMode;

void SofaSplitDS4Init(BOOL enabled) {
    gEnabled = enabled;
    gPads = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    gQueues = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (enabled) StartReader();
    if (enabled && getenv("SOFASPLIT_HOOK_DEBUG")) {
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(0, 0));
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(t, ^{
            SofaSplitHookLog(@"DS4 debug: reports=%ld delivered=%ld queuePolls=%ld served=%ld getValue=%ld served=%ld callbacks=%ld queues=%ld",
                             gReports, gDelivered, gQueuePolls, gQueueServed, gGetValues, gGetValuesServed, gCallbacks,
                             (long)CFDictionaryGetCount(gQueues));
        });
        dispatch_resume(t);
        static dispatch_source_t keep;
        keep = t;
    }
}

static int IntProperty(IOHIDDeviceRef d, CFStringRef key) {
    CFTypeRef v = IOHIDDeviceGetProperty(d, key);
    int n = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &n);
    return n;
}

static int SlotForUsage(uint32_t page, uint32_t usage) {
    if (page == kHIDPage_Button && usage >= 1 && usage <= kButtons) return (int)usage - 1;
    if (page != kHIDPage_GenericDesktop) return -1;
    switch (usage) {
    case kHIDUsage_GD_X: return kSlotX;
    case kHIDUsage_GD_Y: return kSlotY;
    case kHIDUsage_GD_Z: return kSlotZ;
    case kHIDUsage_GD_Rz: return kSlotRz;
    case kHIDUsage_GD_Rx: return kSlotRx;
    case kHIDUsage_GD_Ry: return kSlotRy;
    case kHIDUsage_GD_Hatswitch: return kSlotHat;
    default: return -1;
    }
}

static int SlotForElement(NHPad *pad, IOHIDElementRef element) {
    IOHIDElementCookie cookie = IOHIDElementGetCookie(element);
    for (int i = 0; i < kSlots; i++)
        if (pad->elements[i] && pad->cookies[i] == cookie) return i;
    return -1;
}

static void Deliver(NHPad *pad, int slot, int32_t value) {
    IOHIDValueRef v = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, pad->elements[slot], mach_absolute_time(), value);
    if (!v) return;
    gDelivered++;
    NSMutableArray *targets = [NSMutableArray array];
    os_unfair_lock_lock(&gLock);
    pad->values[slot] = value;
    CFIndex n = CFDictionaryGetCount(gQueues);
    const void **queues = malloc(sizeof(void *) * (size_t)MAX(n, 1));
    CFDictionaryGetKeysAndValues(gQueues, NULL, queues);
    for (CFIndex i = 0; i < n; i++) {
        NHQueue *q = (__bridge NHQueue *)queues[i];
        if (q->pad != pad || !q->slots[slot]) continue;
        if (CFArrayGetCount(q->pending) >= 1024) CFArrayRemoveValueAtIndex(q->pending, 0);
        CFArrayAppendValue(q->pending, v);
    }
    free(queues);
    [targets addObjectsFromArray:pad->targets];
    os_unfair_lock_unlock(&gLock);
    if (targets.count) {
        IOHIDDeviceRef device = pad->device;
        CFRetain(v);
        void (^run)(void) = ^{
            for (NSValue *t in targets) {
                NHValueTarget target;
                [t getValue:&target];
                gCallbacks++;
                target.cb(target.ctx, kIOReturnSuccess, device, v);
            }
            CFRelease(v);
        };
        os_unfair_lock_lock(&gLock);
        CFRunLoopRef loop = gGameRunLoop;
        CFStringRef mode = gGameRunLoopMode;
        if (loop) { CFRetain(loop); CFRetain(mode); }
        os_unfair_lock_unlock(&gLock);
        if (loop) {
            CFRunLoopPerformBlock(loop, mode, run);
            CFRunLoopWakeUp(loop);
            CFRelease(loop);
            CFRelease(mode);
        } else {
            run();
        }
    }
    CFRelease(v);
}

static void OnReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID,
                     uint8_t *r, CFIndex length) {
    gReports++;
    if (reportID != 0x11 || length < 12) return;
    uint64_t registryID = (uint64_t)(uintptr_t)ctx;
    // Report 0x11 = the USB report 0x01 shifted by two bytes: sticks, buttons/hat, more buttons, PS/touchpad, triggers.
    int32_t next[kSlots];
    uint8_t b0 = r[7], b1 = r[8], b2 = r[9];
    const uint8_t faceBits[4] = {0x10, 0x20, 0x40, 0x80};  // square, cross, circle, triangle
    for (int i = 0; i < 4; i++) next[i] = (b0 & faceBits[i]) != 0;
    for (int i = 0; i < 8; i++) next[4 + i] = (b1 >> i) & 1;  // L1 R1 L2 R2 share options L3 R3
    next[12] = b2 & 1;                                         // PS
    next[13] = (b2 >> 1) & 1;                                  // touchpad click
    next[kSlotX] = r[3];
    next[kSlotY] = r[4];
    next[kSlotZ] = r[5];
    next[kSlotRz] = r[6];
    next[kSlotRx] = r[10];
    next[kSlotRy] = r[11];
    next[kSlotHat] = b0 & 0x0F;  // 0-7 clockwise from up, 8 = released (the element's null state)
    NSMutableArray<NHPad *> *pads = [NSMutableArray array];
    os_unfair_lock_lock(&gLock);
    CFIndex n = CFDictionaryGetCount(gPads);
    const void **all = malloc(sizeof(void *) * (size_t)MAX(n, 1));
    CFDictionaryGetKeysAndValues(gPads, NULL, all);
    for (CFIndex i = 0; i < n; i++) {
        id pad = (__bridge id)all[i];
        if (pad != [NSNull null] && ((NHPad *)pad)->registryID == registryID) [pads addObject:pad];
    }
    free(all);
    os_unfair_lock_unlock(&gLock);
    for (NHPad *pad in pads)
        for (int i = 0; i < kSlots; i++)
            if (pad->elements[i] && next[i] != pad->values[i]) Deliver(pad, i, next[i]);
}

static BOOL IsBluetoothDS4(IOHIDDeviceRef device) {
    int vid = IntProperty(device, CFSTR(kIOHIDVendorIDKey)), pid = IntProperty(device, CFSTR(kIOHIDProductIDKey));
    CFTypeRef transport = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDTransportKey));
    return vid == 0x054c && (pid == 0x05c4 || pid == 0x09cc) && transport && CFGetTypeID(transport) == CFStringGetTypeID()
           && CFStringFind(transport, CFSTR("Bluetooth"), 0).location != kCFNotFound;
}

static uint64_t RegistryID(IOHIDDeviceRef device) {
    uint64_t rid = 0;
    io_service_t service = IOHIDDeviceGetService(device);
    if (service) IORegistryEntryGetRegistryEntryID(service, &rid);
    return rid;
}

static void OnReaderDevice(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef device) {
    if (!IsBluetoothDS4(device)) return;
    uint8_t *buffer = malloc(128);  // lives as long as the device; a reconnect gets a new one
    IOHIDDeviceRegisterInputReportCallback(device, buffer, 128, OnReport, (void *)(uintptr_t)RegistryID(device));
}

/// The game may never schedule its own devices for report callbacks, so the hook reads the controllers itself.
static void StartReader(void) {
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        IOHIDManagerSetDeviceMatching(m, (__bridge CFDictionaryRef)@{@kIOHIDVendorIDKey : @0x054c});
        IOHIDManagerRegisterDeviceMatchingCallback(m, OnReaderDevice, NULL);
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
        for (;;) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 60, false);
    }];
    thread.name = @"SofaSplit DS4 reader";
    [thread start];
}

/// The translator for a device, set up the first time the game touches it; nil when it isn't a Bluetooth DS4.
static NHPad *PadFor(IOHIDDeviceRef device) {
    if (!gEnabled || !device) return nil;
    os_unfair_lock_lock(&gLock);
    id known = (__bridge id)CFDictionaryGetValue(gPads, device);
    os_unfair_lock_unlock(&gLock);
    if (known) return known == [NSNull null] ? nil : known;

    NHPad *pad = nil;
    if (IsBluetoothDS4(device)) {
        pad = [NHPad new];
        pad->device = (IOHIDDeviceRef)CFRetain(device);
        pad->registryID = RegistryID(device);
        pad->targets = [NSMutableArray array];
        for (int i = 0; i < kSlots; i++) pad->values[i] = i == kSlotHat ? 8 : (i >= kSlotX && i <= kSlotRz ? 128 : 0);
        CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
        int found = 0;
        for (CFIndex i = 0; elements && i < CFArrayGetCount(elements); i++) {
            IOHIDElementRef e = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
            IOHIDElementType t = IOHIDElementGetType(e);
            if (t != kIOHIDElementTypeInput_Button && t != kIOHIDElementTypeInput_Misc && t != kIOHIDElementTypeInput_Axis) continue;
            int slot = SlotForUsage(IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e));
            if (slot < 0 || pad->elements[slot]) continue;
            pad->elements[slot] = (IOHIDElementRef)CFRetain(e);
            pad->cookies[slot] = IOHIDElementGetCookie(e);
            found++;
        }
        if (elements) CFRelease(elements);
        if (found) {
            SofaSplitHookLog(@"DUALSHOCK 4 over Bluetooth: decoding its reports for %d buttons and axes", found);
        } else {
            pad = nil;
        }
    }
    os_unfair_lock_lock(&gLock);
    if (!CFDictionaryGetValue(gPads, device)) CFDictionarySetValue(gPads, device, (__bridge const void *)(pad ?: [NSNull null]));
    pad = (__bridge id)CFDictionaryGetValue(gPads, device);
    os_unfair_lock_unlock(&gLock);
    return (id)pad == [NSNull null] ? nil : pad;
}

#pragma mark - Interposed element API

static IOReturn NH_IOHIDDeviceGetValue(IOHIDDeviceRef device, IOHIDElementRef element, IOHIDValueRef *value) {
    gGetValues++;
    NHPad *pad = element ? PadFor(device) : nil;
    int slot = pad ? SlotForElement(pad, element) : -1;
    if (slot < 0 || !value) return IOHIDDeviceGetValue(device, element, value);
    gGetValuesServed++;
    os_unfair_lock_lock(&gLock);
    int32_t current = pad->values[slot];
    IOHIDValueRef v = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, pad->elements[slot], mach_absolute_time(), current);
    if (pad->lastRead[slot]) CFRelease(pad->lastRead[slot]);
    pad->lastRead[slot] = v;
    os_unfair_lock_unlock(&gLock);
    *value = v;
    return v ? kIOReturnSuccess : kIOReturnNoMemory;
}

static void NH_IOHIDDeviceRegisterInputValueCallback(IOHIDDeviceRef device, IOHIDValueCallback cb, void *ctx) {
    IOHIDDeviceRegisterInputValueCallback(device, cb, ctx);
    NHPad *pad = PadFor(device);
    if (!pad) return;
    os_unfair_lock_lock(&gLock);
    [pad->targets removeAllObjects];  // like IOKit: a device has one value callback
    if (cb) {
        NHValueTarget t = {cb, ctx};
        [pad->targets addObject:[NSValue valueWithBytes:&t objCType:@encode(NHValueTarget)]];
    }
    os_unfair_lock_unlock(&gLock);
}

static void NH_IOHIDQueueAddElement(IOHIDQueueRef queue, IOHIDElementRef element) {
    IOHIDQueueAddElement(queue, element);
    NHPad *pad = element ? PadFor(IOHIDElementGetDevice(element)) : nil;
    int slot = pad ? SlotForElement(pad, element) : -1;
    if (slot < 0) return;
    os_unfair_lock_lock(&gLock);
    NHQueue *q = (__bridge NHQueue *)CFDictionaryGetValue(gQueues, queue);
    if (!q) {
        q = [NHQueue new];
        q->pad = pad;
        q->pending = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        CFDictionarySetValue(gQueues, queue, (__bridge const void *)q);
    }
    q->slots[slot] = YES;
    os_unfair_lock_unlock(&gLock);
}

static void NH_IOHIDManagerScheduleWithRunLoop(IOHIDManagerRef manager, CFRunLoopRef loop, CFStringRef mode) {
    IOHIDManagerScheduleWithRunLoop(manager, loop, mode);
    if (!loop || !mode) return;
    os_unfair_lock_lock(&gLock);
    if (!gGameRunLoop) {
        gGameRunLoop = (CFRunLoopRef)CFRetain(loop);
        gGameRunLoopMode = CFStringCreateCopy(kCFAllocatorDefault, mode);
    }
    os_unfair_lock_unlock(&gLock);
}

static IOHIDValueRef NextPending(IOHIDQueueRef queue) {
    if (!gEnabled) return NULL;
    gQueuePolls++;
    os_unfair_lock_lock(&gLock);
    NHQueue *q = (__bridge NHQueue *)CFDictionaryGetValue(gQueues, queue);
    IOHIDValueRef v = NULL;
    if (q && CFArrayGetCount(q->pending)) {
        v = (IOHIDValueRef)CFRetain(CFArrayGetValueAtIndex(q->pending, 0));
        CFArrayRemoveValueAtIndex(q->pending, 0);
        gQueueServed++;
    }
    os_unfair_lock_unlock(&gLock);
    return v;
}

static IOHIDValueRef NH_IOHIDQueueCopyNextValueWithTimeout(IOHIDQueueRef queue, CFTimeInterval timeout) {
    return NextPending(queue) ?: IOHIDQueueCopyNextValueWithTimeout(queue, timeout);
}

static IOHIDValueRef NH_IOHIDQueueCopyNextValue(IOHIDQueueRef queue) {
    return NextPending(queue) ?: IOHIDQueueCopyNextValue(queue);
}

#define DYLD_INTERPOSE(_replacement, _replacee)                                              \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
        _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {           \
            (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

DYLD_INTERPOSE(NH_IOHIDDeviceGetValue, IOHIDDeviceGetValue)
DYLD_INTERPOSE(NH_IOHIDManagerScheduleWithRunLoop, IOHIDManagerScheduleWithRunLoop)
DYLD_INTERPOSE(NH_IOHIDDeviceRegisterInputValueCallback, IOHIDDeviceRegisterInputValueCallback)
DYLD_INTERPOSE(NH_IOHIDQueueAddElement, IOHIDQueueAddElement)
DYLD_INTERPOSE(NH_IOHIDQueueCopyNextValueWithTimeout, IOHIDQueueCopyNextValueWithTimeout)
DYLD_INTERPOSE(NH_IOHIDQueueCopyNextValue, IOHIDQueueCopyNextValue)
