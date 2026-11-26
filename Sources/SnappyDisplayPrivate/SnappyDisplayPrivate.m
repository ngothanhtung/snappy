#import "SnappyDisplayPrivate.h"
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

// MARK: - Symbol loading

static void *SDPSymbol(const char *framework, const char *name) {
    void *handle = framework ? dlopen(framework, RTLD_LAZY) : RTLD_DEFAULT;
    return handle ? dlsym(handle, name) : NULL;
}

static const char *kDisplayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices";
static const char *kCoreDisplay = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay";
static const char *kMonitorPanel = "/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel";

// MARK: - DisplayServices

typedef bool (*DSCanChangeFn)(CGDirectDisplayID);
typedef int (*DSGetFn)(CGDirectDisplayID, float *);
typedef int (*DSSetFn)(CGDirectDisplayID, float);

BOOL SDPCanChangeBrightness(CGDirectDisplayID display) {
    static DSCanChangeFn fn; static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (DSCanChangeFn)SDPSymbol(kDisplayServices, "DisplayServicesCanChangeBrightness"); });
    return fn ? fn(display) : NO;
}

float SDPGetBrightness(CGDirectDisplayID display) {
    static DSGetFn fn; static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (DSGetFn)SDPSymbol(kDisplayServices, "DisplayServicesGetBrightness"); });
    float value = -1;
    if (!fn || fn(display, &value) != 0) return -1;
    return value;
}

BOOL SDPSetBrightness(CGDirectDisplayID display, float value) {
    static DSSetFn fn; static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (DSSetFn)SDPSymbol(kDisplayServices, "DisplayServicesSetBrightness"); });
    return fn ? fn(display, value) == 0 : NO;
}

// MARK: - IOAVService (DDC/CI)

typedef CFTypeRef (*AVCreateFn)(CFAllocatorRef, io_service_t);
typedef IOReturn (*AVWriteFn)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
typedef IOReturn (*AVReadFn)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);

static AVCreateFn avCreate;
static AVWriteFn avWrite;
static AVReadFn avRead;

static BOOL SDPLoadAV(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        avCreate = (AVCreateFn)SDPSymbol(NULL, "IOAVServiceCreateWithService");
        avWrite = (AVWriteFn)SDPSymbol(NULL, "IOAVServiceWriteI2C");
        avRead = (AVReadFn)SDPSymbol(NULL, "IOAVServiceReadI2C");
    });
    return avCreate && avWrite && avRead;
}

@interface SDPI2CService ()
@property (readwrite, copy) NSString *framebufferPath;
@property (readwrite, copy, nullable) NSString *manufacturerID;
@property (readwrite) uint32_t productID;
@property (readwrite) uint32_t serialNumber;
@property (readwrite, copy, nullable) NSString *productName;
@property (readwrite) uint32_t yearOfManufacture;
@property (readwrite) uint32_t weekOfManufacture;
@end

@implementation SDPI2CService {
    CFTypeRef _service;
}

- (instancetype)initWithService:(CFTypeRef)service {
    if ((self = [super init])) { _service = service; _framebufferPath = @""; }
    return self;
}

- (void)dealloc {
    if (_service) CFRelease(_service);
}

- (BOOL)writeChip:(uint8_t)chip offset:(uint8_t)offset data:(NSData *)data {
    if (!SDPLoadAV()) return NO;
    NSMutableData *copy = [data mutableCopy];
    return avWrite(_service, chip, offset, copy.mutableBytes, (uint32_t)copy.length) == kIOReturnSuccess;
}

- (nullable NSData *)readChip:(uint8_t)chip offset:(uint8_t)offset length:(NSUInteger)length {
    if (!SDPLoadAV()) return nil;
    NSMutableData *buffer = [NSMutableData dataWithLength:length];
    if (avRead(_service, chip, offset, buffer.mutableBytes, (uint32_t)length) != kIOReturnSuccess) return nil;
    return buffer;
}
@end

static id SDPProperty(io_registry_entry_t entry, NSString *key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
    return CFBridgingRelease(value);
}

static uint32_t SDPUInt(NSDictionary *dict, NSString *key) {
    id v = dict[key];
    return [v isKindOfClass:[NSNumber class]] ? [v unsignedIntValue] : 0;
}

NSArray<SDPI2CService *> *SDPCopyI2CServices(void) {
    NSMutableArray *result = [NSMutableArray array];
    if (!SDPLoadAV()) return result;

    io_iterator_t iterator = 0;
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS) {
        IOObjectRelease(root);
        return result;
    }

    // The registry is walked depth-first: each external DCPAVServiceProxy sits
    // below (after) the framebuffer (AppleCLCD2 / IOMobileFramebufferShim) that
    // drives it, so pair it with the most recent framebuffer seen.
    NSString *lastPath = nil;
    NSDictionary *lastAttributes = nil;
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        io_name_t name = {0};
        IORegistryEntryGetName(entry, name);
        NSString *n = @(name);
        if ([n containsString:@"AppleCLCD2"] || [n containsString:@"IOMobileFramebufferShim"]) {
            io_string_t path = {0};
            IORegistryEntryGetPath(entry, kIOServicePlane, path);
            lastPath = @(path);
            NSDictionary *attrs = SDPProperty(entry, @"DisplayAttributes");
            lastAttributes = [attrs isKindOfClass:[NSDictionary class]] ? attrs[@"ProductAttributes"] : nil;
        } else if ([n isEqualToString:@"DCPAVServiceProxy"] && lastPath) {
            NSString *location = SDPProperty(entry, @"Location");
            if ([location isKindOfClass:[NSString class]] && [location isEqualToString:@"External"]) {
                CFTypeRef service = avCreate(kCFAllocatorDefault, entry);
                if (service) {
                    SDPI2CService *s = [[SDPI2CService alloc] initWithService:service];
                    s.framebufferPath = lastPath;
                    if ([lastAttributes isKindOfClass:[NSDictionary class]]) {
                        id m = lastAttributes[@"ManufacturerID"];
                        s.manufacturerID = [m isKindOfClass:[NSString class]] ? m : nil;
                        s.productID = SDPUInt(lastAttributes, @"ProductID");
                        s.serialNumber = SDPUInt(lastAttributes, @"SerialNumber");
                        id pn = lastAttributes[@"ProductName"];
                        s.productName = [pn isKindOfClass:[NSString class]] ? pn : nil;
                        s.yearOfManufacture = SDPUInt(lastAttributes, @"YearOfManufacture");
                        s.weekOfManufacture = SDPUInt(lastAttributes, @"WeekOfManufacture");
                    }
                    [result addObject:s];
                }
            }
            // One service per framebuffer.
            lastPath = nil;
            lastAttributes = nil;
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
    IOObjectRelease(root);
    return result;
}

typedef CFDictionaryRef (*CDInfoFn)(CGDirectDisplayID);

static NSDictionary *SDPDisplayInfo(CGDirectDisplayID display) {
    static CDInfoFn fn; static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (CDInfoFn)SDPSymbol(kCoreDisplay, "CoreDisplay_DisplayCreateInfoDictionary"); });
    if (!fn) return nil;
    CFDictionaryRef info = fn(display);
    return info ? CFBridgingRelease(info) : nil;
}

NSString *_Nullable SDPDisplayName(CGDirectDisplayID display) {
    NSDictionary *names = SDPDisplayInfo(display)[@"DisplayProductName"];
    if (![names isKindOfClass:[NSDictionary class]] || names.count == 0) return nil;
    id name = names[@"en_US"] ?: names.allValues.firstObject;
    return [name isKindOfClass:[NSString class]] ? name : nil;
}

NSString *_Nullable SDPDisplayLocation(CGDirectDisplayID display) {
    NSDictionary *info = SDPDisplayInfo(display);
    id location = info[@"IODisplayLocation"];
    return [location isKindOfClass:[NSString class]] ? location : nil;
}

// MARK: - Enable / disable

typedef CGError (*CGSEnableFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);

static CGSEnableFn SDPEnableFn(void) {
    static CGSEnableFn fn; static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (CGSEnableFn)SDPSymbol(NULL, "CGSConfigureDisplayEnabled"); });
    return fn;
}

BOOL SDPCanToggleDisplays(void) { return SDPEnableFn() != NULL; }

CGError SDPConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, BOOL enabled) {
    CGSEnableFn fn = SDPEnableFn();
    return fn ? fn(config, display, enabled) : kCGErrorNotImplemented;
}

// MARK: - Rotation (MonitorPanel)

static id SDPMPDisplay(CGDirectDisplayID display) {
    static id manager; static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen(kMonitorPanel, RTLD_LAZY)) return;
        Class cls = NSClassFromString(@"MPDisplayMgr");
        if (cls) manager = [[cls alloc] init];
    });
    SEL sel = NSSelectorFromString(@"displayWithID:");
    if (![manager respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, int))objc_msgSend)(manager, sel, (int)display);
}

BOOL SDPCanRotate(CGDirectDisplayID display) {
    id d = SDPMPDisplay(display);
    SEL sel = NSSelectorFromString(@"canChangeOrientation");
    if (![d respondsToSelector:sel] || ![d respondsToSelector:NSSelectorFromString(@"setOrientation:")]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(d, sel);
}

int SDPRotation(CGDirectDisplayID display) {
    id d = SDPMPDisplay(display);
    SEL sel = NSSelectorFromString(@"orientation");
    if (![d respondsToSelector:sel]) return (int)CGDisplayRotation(display);
    return ((int (*)(id, SEL))objc_msgSend)(d, sel);
}

BOOL SDPSetRotation(CGDirectDisplayID display, int degrees) {
    id d = SDPMPDisplay(display);
    SEL sel = NSSelectorFromString(@"setOrientation:");
    if (![d respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL, int))objc_msgSend)(d, sel, degrees);
    return YES;
}
