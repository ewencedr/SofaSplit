// SofaSplitHook — injected into every game instance with DYLD_INSERT_LIBRARIES.
//
// The macOS counterpart of Nucleus Co-op's custom xinput DLL + ForceFocus hooks:
//   * Gamepad routing: hides every gamepad except the ones assigned to this
//     instance, both from IOKit HID (SDL, hidapi, most engines) and from the
//     GameController framework.
//   * Force focus: the instance keeps believing it is the active app, so it
//     keeps rendering and reading input while another instance has focus.
//   * Window placement: moves/resizes (optionally borderless) the game window
//     into its split-screen slot from inside the process.
//
// Configuration comes from environment variables set by the launcher:
//   SOFASPLIT_ALLOWED_DEVICES   "vid:pid:loc;..."  ("none" hides all gamepads; unset disables filtering)
//   SOFASPLIT_GAMEPAD_ORDINALS  "0,2"  fallback when a GCController cannot be mapped to a HID device
//   SOFASPLIT_FORCE_FOCUS       "1"
//   SOFASPLIT_WINDOW_FRAME      "x,y,w,h" in Cocoa global coordinates
//   SOFASPLIT_BORDERLESS        "1"
//   SOFASPLIT_LEGACY_PAD_NAMES  "1"  report PlayStation 4 pads by the name older macOS gave them
//   SOFASPLIT_DS4_BLUETOOTH     "1"  decode Bluetooth DUALSHOCK 4 reports for HID-element readers (DualShock4Bluetooth.m)
//   SOFASPLIT_HOOK_LOG          path of a log file (default stderr)

#import <AppKit/AppKit.h>
#import <GameController/GameController.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <objc/runtime.h>
#import <os/lock.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdarg.h>

static NSSet<NSString *> *gAllowedKeys;   // nil = no gamepad filtering
static NSSet<NSNumber *> *gFallbackOrdinals;
static BOOL gForceFocus;
static BOOL gBorderless;
static BOOL gHaveFrame;
static NSRect gFrame;
static FILE *gLog;

void SofaSplitHookLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void SofaSplitHookLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *out = gLog ?: stderr;
    fprintf(out, "[SofaSplitHook %d] %s\n", getpid(), msg.UTF8String);
    fflush(out);
}
#define HookLog SofaSplitHookLog

// DualShock4Bluetooth.m
void SofaSplitDS4Init(BOOL enabled);

// SteamLobbyEmu.m
void SofaSplitSteamEmuInit(NSDictionary<NSString *, NSString *> *env);
void *SofaSplitSteamEmuResolve(void *handle, const char *symbol, void *real);

#pragma mark - Device identity (must match DeviceKey in SofaSplitCore)

static NSNumber *IntProp(io_registry_entry_t e, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, key, kCFAllocatorDefault, 0);
    if (!v) return nil;
    id obj = CFBridgingRelease(v);
    return [obj isKindOfClass:[NSNumber class]] ? obj : nil;
}

// Walks up from any HID service to its IOHIDDevice and builds "vid:pid:location".
static NSString *KeyForService(io_service_t service) {
    if (!service) return nil;
    io_registry_entry_t entry = service;
    IOObjectRetain(entry);
    for (int depth = 0; depth < 10; depth++) {
        if (IOObjectConformsTo(entry, "IOHIDDevice")) {
            uint64_t rid = 0;
            IORegistryEntryGetRegistryEntryID(entry, &rid);
            NSNumber *vid = IntProp(entry, CFSTR(kIOHIDVendorIDKey));
            NSNumber *pid = IntProp(entry, CFSTR(kIOHIDProductIDKey));
            NSNumber *loc = IntProp(entry, CFSTR(kIOHIDLocationIDKey));
            IOObjectRelease(entry);
            NSString *locPart = loc ? [NSString stringWithFormat:@"%08x", (uint32_t)loc.longLongValue]
                                    : [NSString stringWithFormat:@"r%llx", rid];
            return [NSString stringWithFormat:@"%04x:%04x:%@", (uint32_t)vid.longLongValue,
                                              (uint32_t)pid.longLongValue, locPart];
        }
        io_registry_entry_t parent = 0;
        kern_return_t kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent);
        IOObjectRelease(entry);
        if (kr != KERN_SUCCESS) return nil;
        entry = parent;
    }
    IOObjectRelease(entry);
    return nil;
}

static NSString *KeyForRegistryID(uint64_t rid) {
    io_service_t s = IOServiceGetMatchingService(MACH_PORT_NULL, IORegistryEntryIDMatching(rid));
    if (!s) return nil;
    NSString *k = KeyForService(s);
    IOObjectRelease(s);
    return k;
}

#pragma mark - IOKit HID filtering

static BOOL IsGamepad(IOHIDDeviceRef d) {
    return IOHIDDeviceConformsTo(d, kHIDPage_GenericDesktop, kHIDUsage_GD_GamePad) ||
           IOHIDDeviceConformsTo(d, kHIDPage_GenericDesktop, kHIDUsage_GD_Joystick) ||
           IOHIDDeviceConformsTo(d, kHIDPage_GenericDesktop, kHIDUsage_GD_MultiAxisController);
}

// Bluetooth addresses of the assigned pads (from SOFASPLIT_DEVICE_TOKENS): a pad that switches between cable and
// Bluetooth mid-game reappears under a new key but keeps its address.
static NSSet<NSString *> *gAllowedAddresses;

static NSString *HexString(const uint8_t *bytes, int count, BOOL reversed) {
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < count; i++) [s appendFormat:@"%02x", bytes[reversed ? count - 1 - i : i]];
    return s;
}

// Must stay in sync with ControllerIdentity.hardwareAddress(of:) in SofaSplitCore.
static NSString *HardwareAddress(IOHIDDeviceRef d, io_service_t service) {
    CFTypeRef serial = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDSerialNumberKey));
    if (serial && CFGetTypeID(serial) == CFStringGetTypeID()) {
        NSMutableString *hex = [NSMutableString string];
        for (NSUInteger i = 0; i < [(__bridge NSString *)serial length]; i++) {
            unichar ch = [(__bridge NSString *)serial characterAtIndex:i];
            if (isxdigit(ch)) [hex appendFormat:@"%C", (unichar)tolower(ch)];
        }
        if (hex.length == 12) return hex;
    }
    CFTypeRef vidRef = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDVendorIDKey));
    CFTypeRef pidRef = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDProductIDKey));
    int vid = 0, pid = 0;
    if (vidRef) CFNumberGetValue(vidRef, kCFNumberIntType, &vid);
    if (pidRef) CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
    if (vid != 0x054c) return nil;
    uint8_t reportID;
    CFIndex length;
    if (pid == 0x05c4 || pid == 0x09cc) { reportID = 0x12; length = 16; }
    else if (pid == 0x0ce6 || pid == 0x0df2) { reportID = 0x09; length = 20; }
    else return nil;
    uint8_t buffer[20] = {reportID};
    // The game's device may not be open yet: read through a device of our own.
    IOHIDDeviceRef own = service ? IOHIDDeviceCreate(kCFAllocatorDefault, service) : NULL;
    if (!own) return nil;
    NSString *address = nil;
    if (IOHIDDeviceOpen(own, kIOHIDOptionsTypeNone) == kIOReturnSuccess) {
        if (IOHIDDeviceGetReport(own, kIOHIDReportTypeFeature, reportID, buffer, &length) == kIOReturnSuccess && length >= 7)
            address = HexString(buffer + 1, 6, YES);
        IOHIDDeviceClose(own, kIOHIDOptionsTypeNone);
    }
    CFRelease(own);
    return [address isEqualToString:@"000000000000"] ? nil : address;
}

// Keyed by the IORegistry entry ID, which identifies the physical device for as long as it is connected.
// (Not by IOHIDDeviceRef: those are freed and their addresses reused for other devices.)
static os_unfair_lock gCacheLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSNumber *, NSNumber *> *gDeviceCache;

static BOOL DeviceAllowed(IOHIDDeviceRef d) {
    if (!gAllowedKeys || !d) return YES;
    io_service_t service = IOHIDDeviceGetService(d);
    uint64_t rid = 0;
    if (service) IORegistryEntryGetRegistryEntryID(service, &rid);
    if (!rid) return YES;  // can't tell which device (e.g. already gone): don't hide a removal from the game
    os_unfair_lock_lock(&gCacheLock);
    NSNumber *cached = rid ? gDeviceCache[@(rid)] : nil;
    os_unfair_lock_unlock(&gCacheLock);
    if (cached) return cached.boolValue;

    BOOL allowed = YES;
    if (IsGamepad(d)) {
        NSString *key = KeyForService(service);
        allowed = key && [gAllowedKeys containsObject:key];
        NSString *how = @"";
        if (!allowed && gAllowedAddresses.count) {
            NSString *address = HardwareAddress(d, service);
            if (address && [gAllowedAddresses containsObject:address]) {
                allowed = YES;
                how = @" (same controller, other connection)";
            }
        }
        HookLog(@"HID gamepad %@ -> %@%@", key ?: @"(unknown)", allowed ? @"visible" : @"hidden", how);
    }
    if (rid) {
        os_unfair_lock_lock(&gCacheLock);
        if (!gDeviceCache) gDeviceCache = [NSMutableDictionary dictionary];
        gDeviceCache[@(rid)] = @(allowed);
        os_unfair_lock_unlock(&gCacheLock);
    }
    return allowed;
}

typedef struct { IOHIDDeviceCallback cb; void *ctx; } NHDeviceCallback;
typedef struct { IOHIDValueCallback cb; void *ctx; } NHValueCallback;

static void NH_DeviceTrampoline(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef d) {
    NHDeviceCallback *w = ctx;
    if (DeviceAllowed(d)) w->cb(w->ctx, r, sender, d);
}

static void NH_RemovalTrampoline(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef d) {
    NHDeviceCallback *w = ctx;
    if (!DeviceAllowed(d)) return;  // the game never saw it
    if (IsGamepad(d)) HookLog(@"HID gamepad %@ disconnected", KeyForService(IOHIDDeviceGetService(d)));
    w->cb(w->ctx, r, sender, d);
}

static void NH_IOHIDManagerRegisterDeviceRemovalCallback(IOHIDManagerRef m, IOHIDDeviceCallback cb, void *ctx) {
    if (!gAllowedKeys || !cb) { IOHIDManagerRegisterDeviceRemovalCallback(m, cb, ctx); return; }
    NHDeviceCallback *w = malloc(sizeof *w);
    w->cb = cb; w->ctx = ctx;
    IOHIDManagerRegisterDeviceRemovalCallback(m, NH_RemovalTrampoline, w);
}

static void NH_ValueTrampoline(void *ctx, IOReturn r, void *sender, IOHIDValueRef v) {
    NHValueCallback *w = ctx;
    IOHIDElementRef el = v ? IOHIDValueGetElement(v) : NULL;
    if (el && !DeviceAllowed(IOHIDElementGetDevice(el))) return;
    w->cb(w->ctx, r, sender, v);
}

// Trampoline contexts are leaked on purpose: registrations live as long as the manager.
static void NH_IOHIDManagerRegisterDeviceMatchingCallback(IOHIDManagerRef m, IOHIDDeviceCallback cb, void *ctx) {
    if (!gAllowedKeys || !cb) { IOHIDManagerRegisterDeviceMatchingCallback(m, cb, ctx); return; }
    NHDeviceCallback *w = malloc(sizeof *w);
    w->cb = cb; w->ctx = ctx;
    IOHIDManagerRegisterDeviceMatchingCallback(m, NH_DeviceTrampoline, w);
}

static void NH_IOHIDManagerRegisterInputValueCallback(IOHIDManagerRef m, IOHIDValueCallback cb, void *ctx) {
    if (!gAllowedKeys || !cb) { IOHIDManagerRegisterInputValueCallback(m, cb, ctx); return; }
    NHValueCallback *w = malloc(sizeof *w);
    w->cb = cb; w->ctx = ctx;
    IOHIDManagerRegisterInputValueCallback(m, NH_ValueTrampoline, w);
}

static CFSetRef NH_IOHIDManagerCopyDevices(IOHIDManagerRef m) {
    CFSetRef all = IOHIDManagerCopyDevices(m);
    if (!all || !gAllowedKeys) return all;
    CFIndex n = CFSetGetCount(all);
    const void **values = malloc(sizeof(void *) * (size_t)MAX(n, 1));
    CFSetGetValues(all, values);
    CFMutableSetRef out = CFSetCreateMutable(kCFAllocatorDefault, 0, &kCFTypeSetCallBacks);
    for (CFIndex i = 0; i < n; i++)
        if (DeviceAllowed((IOHIDDeviceRef)values[i])) CFSetAddValue(out, values[i]);
    free(values);
    CFRelease(all);
    return out;
}

#define DYLD_INTERPOSE(_replacement, _replacee)                                              \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
        _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {           \
            (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

#pragma mark - Legacy controller names

// Recent macOS names a PS4 pad "DUALSHOCK 4 Wireless Controller"; older input libraries (InControl, Rewired,
// Unity's own mappings) only know the names macOS used before, so they ignore the pad. Reporting the old
// manufacturer and product names makes them pick their PlayStation 4 profile.
static BOOL gLegacyPadNames;

static BOOL IsDualShock4(IOHIDDeviceRef d) {
    CFTypeRef vid = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDVendorIDKey));
    CFTypeRef pid = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDProductIDKey));
    int v = 0, p = 0;
    if (!vid || !pid || CFGetTypeID(vid) != CFNumberGetTypeID() || CFGetTypeID(pid) != CFNumberGetTypeID()) return NO;
    CFNumberGetValue(vid, kCFNumberIntType, &v);
    CFNumberGetValue(pid, kCFNumberIntType, &p);
    return v == 0x054c && (p == 0x05c4 || p == 0x09cc || p == 0x0ba0);
}

static CFTypeRef NH_IOHIDDeviceGetProperty(IOHIDDeviceRef d, CFStringRef key) {
    if (gLegacyPadNames && key && d && IsDualShock4(d)) {
        if (CFEqual(key, CFSTR(kIOHIDManufacturerKey))) return CFSTR("Sony Interactive Entertainment");
        if (CFEqual(key, CFSTR(kIOHIDProductKey))) return CFSTR("Wireless Controller");
    }
    return IOHIDDeviceGetProperty(d, key);
}

DYLD_INTERPOSE(NH_IOHIDDeviceGetProperty, IOHIDDeviceGetProperty)
DYLD_INTERPOSE(NH_IOHIDManagerRegisterDeviceMatchingCallback, IOHIDManagerRegisterDeviceMatchingCallback)
DYLD_INTERPOSE(NH_IOHIDManagerRegisterInputValueCallback, IOHIDManagerRegisterInputValueCallback)
DYLD_INTERPOSE(NH_IOHIDManagerRegisterDeviceRemovalCallback, IOHIDManagerRegisterDeviceRemovalCallback)
DYLD_INTERPOSE(NH_IOHIDManagerCopyDevices, IOHIDManagerCopyDevices)

#pragma mark - Steam Input filtering

// Games using Steam Input never touch the pads: the Steam client reads them and hands every
// controller to every process. We intercept the flat API (resolved by Mono/IL2CPP through dlsym)
// so each instance only gets the controller at its ordinal.

typedef uint64_t InputHandle_t;
#define STEAM_INPUT_HANDLE_ALL_CONTROLLERS UINT64_MAX
#pragma pack(push, 1)
typedef struct { bool bState; bool bActive; } NHDigitalActionData;
typedef struct { int32_t eMode; float x, y; bool bActive; } NHAnalogActionData;
#pragma pack(pop)

typedef int (*GetConnectedControllers_t)(void *, InputHandle_t *);
typedef NHDigitalActionData (*GetDigitalActionData_t)(void *, InputHandle_t, uint64_t);
typedef NHAnalogActionData (*GetAnalogActionData_t)(void *, InputHandle_t, uint64_t);
typedef void (*SetLEDColor_t)(void *, InputHandle_t, uint8_t, uint8_t, uint8_t, unsigned int);

static BOOL gSteamInputFilter;
static GetConnectedControllers_t gOrigGetConnected;
static GetDigitalActionData_t gOrigGetDigital;
static GetAnalogActionData_t gOrigGetAnalog;
static SetLEDColor_t gSetLED;
static void *gSteamInputLib;  // handle steam_api was dlsym'd from
static _Atomic InputHandle_t gSteamAllowed;  // 0 = none (yet)
static int gPlayer;

// Light the pad in the player's colour so it's obvious which window it drives.
// Re-applied periodically because Steam resets the lightbar when the game's action set changes.
static void ApplyPlayerLED(void *self, InputHandle_t h) {
    static CFAbsoluteTime lastApplied;
    static InputHandle_t lastHandle;
    if (!h) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (h == lastHandle && now - lastApplied < 3) return;
    if (!gSetLED && gSteamInputLib) gSetLED = (SetLEDColor_t)dlsym(gSteamInputLib, "SteamAPI_ISteamInput_SetLEDColor");
    if (!gSetLED) return;
    // P1 blue, P2 green, P3 yellow, P4 pink, then cyan, purple, orange, white. No red: on PlayStation pads it
    // reads as "low battery".
    static const uint8_t colors[8][3] = {{0, 80, 255}, {0, 255, 0}, {255, 200, 0}, {255, 0, 160},
                                         {0, 220, 220}, {160, 0, 255}, {255, 110, 0}, {255, 255, 255}};
    const uint8_t *c = colors[(gPlayer > 0 ? gPlayer - 1 : 0) % 8];
    gSetLED(self, h, c[0], c[1], c[2], 0 /* k_ESteamControllerLEDFlag_SetColor */);
    if (h != lastHandle) HookLog(@"Steam Input: lightbar set to %d,%d,%d", c[0], c[1], c[2]);
    lastHandle = h;
    lastApplied = now;
}

// Steam hands out controller handles in connection order, matching the launcher's ordering.
static InputHandle_t AllowedSteamHandle(void *self) {
    InputHandle_t handles[16] = {0};
    int n = gOrigGetConnected ? gOrigGetConnected(self, handles) : 0;
    if (n <= 0) return 0;
    if (n > 16) n = 16;
    qsort_b(handles, (size_t)n, sizeof handles[0], ^int(const void *a, const void *b) {
        InputHandle_t x = *(const InputHandle_t *)a, y = *(const InputHandle_t *)b;
        return x < y ? -1 : x > y;
    });
    NSNumber *ordinal = gFallbackOrdinals.anyObject;
    InputHandle_t h = (ordinal && ordinal.intValue < n) ? handles[ordinal.intValue] : 0;
    InputHandle_t previous = atomic_exchange(&gSteamAllowed, h);
    if (h != previous)
        HookLog(@"Steam Input: %d controller(s), this instance gets %llu (ordinal %@)", n, h, ordinal ?: @"none");
    ApplyPlayerLED(self, h);
    return h;
}

// The game's own lightbar changes would overwrite the player colour.
static void NH_SetLEDColor(void *self, InputHandle_t h, uint8_t r, uint8_t g, uint8_t b, unsigned int flags) {}

static int NH_GetConnectedControllers(void *self, InputHandle_t *out) {
    InputHandle_t h = AllowedSteamHandle(self);
    if (!h) return 0;
    if (out) out[0] = h;
    return 1;
}

static BOOL SteamHandleAllowed(void *self, InputHandle_t *handle) {
    InputHandle_t allowed = atomic_load(&gSteamAllowed);
    if (!allowed) allowed = AllowedSteamHandle(self);
    if (*handle == STEAM_INPUT_HANDLE_ALL_CONTROLLERS) { *handle = allowed; return allowed != 0; }
    return *handle == allowed && allowed != 0;
}

static NHDigitalActionData NH_GetDigitalActionData(void *self, InputHandle_t handle, uint64_t action) {
    if (!SteamHandleAllowed(self, &handle)) return (NHDigitalActionData){0};
    return gOrigGetDigital(self, handle, action);
}

static NHAnalogActionData NH_GetAnalogActionData(void *self, InputHandle_t handle, uint64_t action) {
    if (!SteamHandleAllowed(self, &handle)) return (NHAnalogActionData){0};
    return gOrigGetAnalog(self, handle, action);
}

// Mono / IL2CPP resolve P/Invokes with dlsym, which bypasses symbol interposing — so interpose dlsym.
static void *NH_dlsym(void *handle, const char *symbol) {
    void *real = dlsym(handle, symbol);
    if (!real || !symbol || strncmp(symbol, "SteamAPI_", 9) != 0) return real;
    void *emulated = SofaSplitSteamEmuResolve(handle, symbol, real);
    if (emulated != real) return emulated;
    if (!gSteamInputFilter || strncmp(symbol, "SteamAPI_ISteamInput_", 21) != 0) return real;
    gSteamInputLib = handle;
    const char *fn = symbol + 21;
    if (!strcmp(fn, "GetConnectedControllers")) { gOrigGetConnected = real; return (void *)NH_GetConnectedControllers; }
    if (!strcmp(fn, "GetDigitalActionData")) { gOrigGetDigital = real; return (void *)NH_GetDigitalActionData; }
    if (!strcmp(fn, "GetAnalogActionData")) { gOrigGetAnalog = real; return (void *)NH_GetAnalogActionData; }
    if (!strcmp(fn, "SetLEDColor")) { gSetLED = real; return (void *)NH_SetLEDColor; }
    return real;
}

DYLD_INTERPOSE(NH_dlsym, dlsym)

#pragma mark - GameController filtering

static IMP gOrigControllers;
static IMP gOrigCurrent;
static char kControllerKeyAssoc;

static NSArray *AllControllers(void) {
    return gOrigControllers ? ((NSArray * (*)(id, SEL)) gOrigControllers)([GCController class], @selector(controllers)) : @[];
}

// key -> identifier tokens (serial / Bluetooth address, LocationID, registry id), from SOFASPLIT_DEVICE_TOKENS.
static NSDictionary<NSString *, NSArray<NSString *> *> *gDeviceTokens;

static NSString *HexOnly(NSString *s) {
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar ch = [s characterAtIndex:i];
        if (isxdigit(ch)) [out appendFormat:@"%C", (unichar)tolower(ch)];
    }
    return out;
}

// GameController runs out of process on modern macOS, so hidServices is usually empty. Its
// identifier ("LOGICAL_DEVICE(10-18-49-da-fa-df)") embeds the Bluetooth address / serial instead.
static NSString *KeyFromIdentifierTokens(GCController *c) {
    NSMutableString *ids = [NSMutableString string];
    for (NSString *prop in @[ @"identifier", @"persistentIdentifier", @"deviceIdentifier" ]) {
        @try {
            id v = [c valueForKey:prop];
            if ([v isKindOfClass:[NSString class]]) [ids appendFormat:@"|%@", HexOnly(v)];
        } @catch (__unused NSException *e) {
        }
    }
    if (ids.length == 0) return nil;
    NSString *match = nil;
    NSUInteger bestLength = 0;
    for (NSString *key in gDeviceTokens)
        for (NSString *token in gDeviceTokens[key])
            if (token.length >= 6 && token.length > bestLength && [ids containsString:token]) {
                match = key;
                bestLength = token.length;
            }
    return match;
}

// GCController keeps the HID services it was built from in a private property;
// we map those back to the IOHIDDevice so the key matches what the launcher saw.
static NSString *KeyForController(GCController *c) {
    id cached = objc_getAssociatedObject(c, &kControllerKeyAssoc);
    if (cached) return cached == [NSNull null] ? nil : cached;

    NSString *key = nil;
    @try {
        id services = [c valueForKey:@"hidServices"];
        if ([services conformsToProtocol:@protocol(NSFastEnumeration)]) {
            for (id s in services) {
                uint64_t rid = 0;
                CFTypeRef cf = (__bridge CFTypeRef)s;
                if (CFGetTypeID(cf) == IOHIDServiceClientGetTypeID()) {
                    CFTypeRef n = IOHIDServiceClientGetRegistryID((IOHIDServiceClientRef)cf);
                    if (n && CFGetTypeID(n) == CFNumberGetTypeID()) CFNumberGetValue(n, kCFNumberSInt64Type, &rid);
                } else {
                    for (NSString *prop in @[ @"registryID", @"registryEntryID", @"serviceID" ]) {
                        if (![s respondsToSelector:NSSelectorFromString(prop)]) continue;
                        id v = [s valueForKey:prop];
                        if ([v isKindOfClass:[NSNumber class]]) { rid = [v unsignedLongLongValue]; break; }
                    }
                }
                if (rid && (key = KeyForRegistryID(rid))) break;
            }
        }
    } @catch (__unused NSException *e) {
    }
    if (!key) key = KeyFromIdentifierTokens(c);
    objc_setAssociatedObject(c, &kControllerKeyAssoc, key ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    HookLog(@"GCController '%@' -> %@", c.vendorName, key ?: @"(unmapped, using ordinal fallback)");
    return key;
}

static BOOL ControllerAllowed(GCController *c, NSArray *all) {
    if (!gAllowedKeys || !c) return YES;
    NSString *key = KeyForController(c);
    if (key) return [gAllowedKeys containsObject:key];
    NSUInteger idx = [all indexOfObjectIdenticalTo:c];
    return idx != NSNotFound && [gFallbackOrdinals containsObject:@(idx)];
}

static NSArray *Hook_controllers(id self, SEL _cmd) {
    NSArray *all = ((NSArray * (*)(id, SEL)) gOrigControllers)(self, _cmd);
    if (!gAllowedKeys) return all;
    NSMutableArray *out = [NSMutableArray array];
    for (GCController *c in all)
        if (ControllerAllowed(c, all)) [out addObject:c];
    return out;
}

static id Hook_current(id self, SEL _cmd) {
    id cur = ((id(*)(id, SEL))gOrigCurrent)(self, _cmd);
    if (!gAllowedKeys) return cur;
    NSArray *all = AllControllers();
    if (cur && ControllerAllowed(cur, all)) return cur;
    for (GCController *c in all)
        if (ControllerAllowed(c, all)) return c;
    return nil;
}

#pragma mark - Notification filtering (focus + controller connect)

static NSSet<NSString *> *gFocusNotifications;
static NSSet<NSString *> *gControllerNotifications;

static BOOL ShouldDrop(NSString *name, id object) {
    if (!name) return NO;
    if (gForceFocus && [gFocusNotifications containsObject:name]) return YES;
    if (gAllowedKeys && [gControllerNotifications containsObject:name] && [object isKindOfClass:[GCController class]])
        return !ControllerAllowed(object, AllControllers());
    return NO;
}

static IMP gOrigPost, gOrigPostNameObject, gOrigPostNameObjectInfo, gOrigAddObserver, gOrigAddObserverBlock;

// AppKit can deliver focus notifications without the posting methods below, so the game also never gets to
// subscribe to them (both the selector and the block form).
static void Hook_addObserver(id self, SEL _cmd, id observer, SEL selector, NSString *name, id object) {
    if (gForceFocus && name && [gFocusNotifications containsObject:name]) {
        HookLog(@"focus: not subscribing %@ to %@", NSStringFromClass([observer class]), name);
        return;
    }
    ((void (*)(id, SEL, id, SEL, id, id))gOrigAddObserver)(self, _cmd, observer, selector, name, object);
}

static id Hook_addObserverBlock(id self, SEL _cmd, NSString *name, id object, NSOperationQueue *queue, id block) {
    if (gForceFocus && name && [gFocusNotifications containsObject:name]) {
        HookLog(@"focus: not subscribing a block to %@", name);
        return [NSObject new];  // a token the caller may pass to removeObserver:
    }
    return ((id (*)(id, SEL, id, id, id, id))gOrigAddObserverBlock)(self, _cmd, name, object, queue, block);
}

static void Hook_post(id self, SEL _cmd, NSNotification *n) {
    if (ShouldDrop(n.name, n.object)) return;
    ((void (*)(id, SEL, id))gOrigPost)(self, _cmd, n);
}

static void Hook_postNameObject(id self, SEL _cmd, NSString *name, id obj) {
    if (ShouldDrop(name, obj)) return;
    ((void (*)(id, SEL, id, id))gOrigPostNameObject)(self, _cmd, name, obj);
}

static void Hook_postNameObjectInfo(id self, SEL _cmd, NSString *name, id obj, NSDictionary *info) {
    if (ShouldDrop(name, obj)) return;
    ((void (*)(id, SEL, id, id, id))gOrigPostNameObjectInfo)(self, _cmd, name, obj, info);
}

#pragma mark - AppKit focus + window hooks

static IMP gOrigIsKey, gOrigIsMain, gOrigCanBecomeKey, gOrigConstrain, gOrigToggleFullScreen;

static BOOL Hook_appIsActive(id self, SEL _cmd) { return YES; }

static BOOL Hook_isKeyWindow(NSWindow *self, SEL _cmd) {
    return ((BOOL(*)(id, SEL))gOrigIsKey)(self, _cmd) || self.isVisible;
}

static BOOL Hook_isMainWindow(NSWindow *self, SEL _cmd) {
    return ((BOOL(*)(id, SEL))gOrigIsMain)(self, _cmd) || self.isVisible;
}

static BOOL Hook_canBecomeKey(NSWindow *self, SEL _cmd) {
    return YES;
}

// While the window has a split-screen slot, entering native fullscreen (e.g. a game re-applying its
// display settings on a scene load) is ignored instead of flashing fullscreen and back.
static void Hook_toggleFullScreen(NSWindow *self, SEL _cmd, id sender) {
    HookLog(@"blocked native fullscreen request");
}

static NSRect Hook_constrainFrame(NSWindow *self, SEL _cmd, NSRect rect, NSScreen *screen) {
    return rect;  // let the slot overlap the menu bar / Dock when asked to
}

static IMP SwizzleInstance(Class cls, SEL sel, IMP replacement) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    // If the method is inherited, add an override instead of patching the superclass.
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(m))) method_setImplementation(m, replacement);
    return orig;
}

static IMP SwizzleClass(Class cls, SEL sel, IMP replacement) {
    Method m = class_getClassMethod(cls, sel);
    return m ? method_setImplementation(m, replacement) : NULL;
}

static void InstallHooks(void) {
    Class nc = [NSNotificationCenter class];
    gOrigPost = SwizzleInstance(nc, @selector(postNotification:), (IMP)Hook_post);
    gOrigPostNameObject = SwizzleInstance(nc, @selector(postNotificationName:object:), (IMP)Hook_postNameObject);
    gOrigPostNameObjectInfo = SwizzleInstance(nc, @selector(postNotificationName:object:userInfo:), (IMP)Hook_postNameObjectInfo);
    if (gForceFocus) {
        gOrigAddObserver = SwizzleInstance(nc, @selector(addObserver:selector:name:object:), (IMP)Hook_addObserver);
        gOrigAddObserverBlock = SwizzleInstance(nc, @selector(addObserverForName:object:queue:usingBlock:), (IMP)Hook_addObserverBlock);
    }

    if (gAllowedKeys) {
        gOrigControllers = SwizzleClass([GCController class], @selector(controllers), (IMP)Hook_controllers);
        if (@available(macOS 11.0, *))
            gOrigCurrent = SwizzleClass([GCController class], @selector(current), (IMP)Hook_current);
    }

    if (gForceFocus) {
        SwizzleInstance([NSApplication class], @selector(isActive), (IMP)Hook_appIsActive);
        gOrigIsKey = SwizzleInstance([NSWindow class], @selector(isKeyWindow), (IMP)Hook_isKeyWindow);
        gOrigIsMain = SwizzleInstance([NSWindow class], @selector(isMainWindow), (IMP)Hook_isMainWindow);
    }

    if (gBorderless) gOrigCanBecomeKey = SwizzleInstance([NSWindow class], @selector(canBecomeKeyWindow), (IMP)Hook_canBecomeKey);
    if (gHaveFrame) {
        gOrigConstrain = SwizzleInstance([NSWindow class], @selector(constrainFrameRect:toScreen:), (IMP)Hook_constrainFrame);
        gOrigToggleFullScreen = SwizzleInstance([NSWindow class], @selector(toggleFullScreen:), (IMP)Hook_toggleFullScreen);
    }
}

#pragma mark - Window placement

static NSWindow *GameWindow(void) {
    NSWindow *best = nil;
    CGFloat bestArea = 0;
    for (NSWindow *w in NSApp.windows) {
        if (!w.isVisible || [w isKindOfClass:[NSPanel class]]) continue;
        CGFloat area = w.frame.size.width * w.frame.size.height;
        if (area > bestArea) { best = w; bestArea = area; }
    }
    return best;
}

static void EnforceFrame(void) {
    NSWindow *w = GameWindow();
    if (!w) return;
    if (w.styleMask & NSWindowStyleMaskFullScreen) {
        // Already fullscreen (e.g. restored by AppKit at launch): leave through the real implementation.
        HookLog(@"leaving native fullscreen");
        ((void (*)(id, SEL, id))gOrigToggleFullScreen)(w, @selector(toggleFullScreen:), nil);
        return;
    }
    if (!(w.collectionBehavior & NSWindowCollectionBehaviorFullScreenNone))
        w.collectionBehavior = (w.collectionBehavior & ~NSWindowCollectionBehaviorFullScreenPrimary) |
                               NSWindowCollectionBehaviorFullScreenNone;
    if (gBorderless && w.styleMask != NSWindowStyleMaskBorderless) {
        w.styleMask = NSWindowStyleMaskBorderless;
        HookLog(@"window made borderless");
    }
    if (!NSEqualRects(NSIntegralRect(w.frame), NSIntegralRect(gFrame))) {
        [w setFrame:gFrame display:YES];
        HookLog(@"window placed at %@", NSStringFromRect(gFrame));
    }
}

#pragma mark - Focus for engines with their own delegates

// Engines like Unity track focus in their app and window delegates (applicationDidResignActive:,
// windowDidResignKey:), which AppKit can call without going through the notification methods filtered above.
// Unity then reports OnApplicationFocus(false) and input libraries such as InControl drop all controller input.
// So those delegate methods become no-ops, and the game is told once that it is active and key.
static void Hook_ignoreResign(id self, SEL _cmd, id notification) {}

static BOOL NeutralizeResign(id delegate, NSArray<NSString *> *selectors) {
    if (!delegate) return NO;
    BOOL any = NO;
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        Method m = class_getInstanceMethod([delegate class], sel);
        if (!m || method_getImplementation(m) == (IMP)Hook_ignoreResign) continue;
        class_replaceMethod([delegate class], sel, (IMP)Hook_ignoreResign, method_getTypeEncoding(m));
        HookLog(@"focus: ignoring -[%@ %@]", NSStringFromClass([delegate class]), name);
        any = YES;
    }
    return any;
}

/// Every class in the game's own executable that tracks focus through these methods (as an app or window
/// delegate, or as a notification observer).
static void NeutralizeEngineFocusClasses(void) {
    const char *image = class_getImageName([NSApp.delegate class] ?: [NSObject class]);
    NSString *mainImage = NSBundle.mainBundle.executablePath;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSArray *selectors = @[ @"applicationWillResignActive:", @"applicationDidResignActive:", @"windowDidResignKey:",
                            @"windowDidResignMain:" ];
    for (unsigned int i = 0; i < count; i++) {
        const char *img = class_getImageName(classes[i]);
        if (!img) continue;
        BOOL gameClass = (image && strcmp(img, image) == 0) || (mainImage && strcmp(img, mainImage.fileSystemRepresentation) == 0);
        if (!gameClass) continue;
        for (NSString *name in selectors) {
            SEL sel = NSSelectorFromString(name);
            Method m = class_getInstanceMethod(classes[i], sel);
            // Only methods the class implements itself, not ones inherited from AppKit.
            unsigned int n = 0;
            Method *own = class_copyMethodList(classes[i], &n);
            BOOL defined = NO;
            for (unsigned int j = 0; j < n; j++) if (method_getName(own[j]) == sel) defined = YES;
            free(own);
            if (!m || !defined || method_getImplementation(m) == (IMP)Hook_ignoreResign) continue;
            method_setImplementation(m, (IMP)Hook_ignoreResign);
            HookLog(@"focus: ignoring -[%s %@]", class_getName(classes[i]), name);
        }
    }
    free(classes);
}

static void KeepDelegateFocus(void) {
    static BOOL done;
    NSWindow *w = GameWindow();
    if (done || !w) return;
    done = YES;
    NeutralizeEngineFocusClasses();
    NeutralizeResign(NSApp.delegate, @[ @"applicationWillResignActive:", @"applicationDidResignActive:" ]);
    NeutralizeResign(w.delegate, @[ @"windowDidResignKey:", @"windowDidResignMain:" ]);
    // A window started behind another app never became key: tell the engine it is.
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidBecomeKeyNotification object:w];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidBecomeMainNotification object:w];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationDidBecomeActiveNotification object:NSApp];
}

static dispatch_source_t gFrameTimer;

static void StartFrameTimer(void) {
    gFrameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gFrameTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 500 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gFrameTimer, ^{
        if (gHaveFrame) EnforceFrame();
        if (gForceFocus) KeepDelegateFocus();
    });
    dispatch_resume(gFrameTimer);
}

#pragma mark - Init

__attribute__((constructor)) static void SofaSplitHookInit(void) {
    @autoreleasepool {
        NSDictionary<NSString *, NSString *> *env = NSProcessInfo.processInfo.environment;

        if (env[@"SOFASPLIT_HOOK_LOG"].length) gLog = fopen(env[@"SOFASPLIT_HOOK_LOG"].fileSystemRepresentation, "a");

        NSString *allowed = env[@"SOFASPLIT_ALLOWED_DEVICES"];
        if (allowed) {
            NSMutableSet *keys = [NSMutableSet set];
            for (NSString *k in [allowed componentsSeparatedByString:@";"])
                if (k.length && ![k isEqualToString:@"none"]) [keys addObject:k.lowercaseString];
            gAllowedKeys = keys;
        }
        NSMutableSet *ordinals = [NSMutableSet set];
        for (NSString *o in [env[@"SOFASPLIT_GAMEPAD_ORDINALS"] componentsSeparatedByString:@","])
            if (o.length) [ordinals addObject:@(o.integerValue)];
        gFallbackOrdinals = ordinals;

        NSMutableDictionary *tokens = [NSMutableDictionary dictionary];
        for (NSString *entry in [env[@"SOFASPLIT_DEVICE_TOKENS"] componentsSeparatedByString:@";"]) {
            NSArray<NSString *> *kv = [entry componentsSeparatedByString:@"="];
            if (kv.count == 2) tokens[kv[0].lowercaseString] = [kv[1] componentsSeparatedByString:@","];
        }
        gDeviceTokens = tokens;
        NSMutableSet *addresses = [NSMutableSet set];
        for (NSString *key in gAllowedKeys)
            for (NSString *token in tokens[key.lowercaseString])
                if (token.length == 12) [addresses addObject:token];
        gAllowedAddresses = addresses;

        gSteamInputFilter = gAllowedKeys != nil;
        gPlayer = env[@"SOFASPLIT_PLAYER"].intValue;
        gForceFocus = [env[@"SOFASPLIT_FORCE_FOCUS"] isEqualToString:@"1"];
        gBorderless = [env[@"SOFASPLIT_BORDERLESS"] isEqualToString:@"1"];
        gLegacyPadNames = [env[@"SOFASPLIT_LEGACY_PAD_NAMES"] isEqualToString:@"1"];
        SofaSplitDS4Init([env[@"SOFASPLIT_DS4_BLUETOOTH"] isEqualToString:@"1"]);
        NSArray<NSString *> *f = [env[@"SOFASPLIT_WINDOW_FRAME"] componentsSeparatedByString:@","];
        if (f.count == 4) {
            gFrame = NSMakeRect(f[0].doubleValue, f[1].doubleValue, f[2].doubleValue, f[3].doubleValue);
            gHaveFrame = gFrame.size.width > 0 && gFrame.size.height > 0;
        }

        gFocusNotifications = [NSSet setWithObjects:NSApplicationWillResignActiveNotification,
                                                    NSApplicationDidResignActiveNotification,
                                                    NSWindowDidResignKeyNotification,
                                                    NSWindowDidResignMainNotification, nil];
        NSMutableSet *gcNames = [NSMutableSet setWithObjects:GCControllerDidConnectNotification,
                                                             GCControllerDidDisconnectNotification, nil];
        if (@available(macOS 11.0, *)) {
            [gcNames addObject:GCControllerDidBecomeCurrentNotification];
            [gcNames addObject:GCControllerDidStopBeingCurrentNotification];
        }
        gControllerNotifications = gcNames;

        SofaSplitSteamEmuInit(env);
        InstallHooks();
        HookLog(@"loaded into %@ (gamepads=%@ focus=%d frame=%@ borderless=%d)",
                NSProcessInfo.processInfo.processName,
                gAllowedKeys ? [gAllowedKeys.allObjects componentsJoinedByString:@","] : @"all",
                gForceFocus, gHaveFrame ? NSStringFromRect(gFrame) : @"-", gBorderless);

        // Background instances must not be App-Napped (timers/rendering throttled).
        static __unused id appNapActivity;
        appNapActivity = [NSProcessInfo.processInfo
            beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                              reason:@"SofaSplit split-screen instance"];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (@available(macOS 11.3, *)) GCController.shouldMonitorBackgroundEvents = YES;
            if (gHaveFrame || gForceFocus) StartFrameTimer();
        });
    }
}
