// Thin, defensive wrappers around the private macOS display APIs Snappy uses
// for its BetterDisplay-style features. Everything is resolved at runtime
// (dlopen/dlsym, NSClassFromString), so nothing here is a link-time dependency:
// if Apple removes or renames an API the wrapper reports "unsupported" and the
// feature is hidden instead of crashing.
//
//  - DisplayServices   brightness of Apple displays (built-in, Studio Display, …)
//  - IOAVService       DDC/CI over I2C to external monitors (Apple Silicon)
//  - CoreDisplay       IODisplayLocation of a CGDirectDisplayID (to pair it with its I2C service)
//  - CGSConfigureDisplayEnabled   disconnect / reconnect a display
//  - MonitorPanel      MPDisplay orientation (rotation works on Apple Silicon)
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: DisplayServices

BOOL SDPCanChangeBrightness(CGDirectDisplayID display);
/// Brightness 0…1, or -1 when unavailable.
float SDPGetBrightness(CGDirectDisplayID display);
BOOL SDPSetBrightness(CGDirectDisplayID display, float value);

// MARK: DDC / I2C (Apple Silicon)

/// One external display's I2C channel plus what the IORegistry says about the
/// framebuffer it hangs off (used to pair it with a CGDirectDisplayID).
@interface SDPI2CService : NSObject
@property (readonly, copy) NSString *framebufferPath;
@property (readonly, copy, nullable) NSString *manufacturerID;   // EISA "DEL", "GSM", …
@property (readonly) uint32_t productID;
@property (readonly) uint32_t serialNumber;
@property (readonly, copy, nullable) NSString *productName;
@property (readonly) uint32_t yearOfManufacture;
@property (readonly) uint32_t weekOfManufacture;

- (BOOL)writeChip:(uint8_t)chip offset:(uint8_t)offset data:(NSData *)data;
- (nullable NSData *)readChip:(uint8_t)chip offset:(uint8_t)offset length:(NSUInteger)length;
@end

/// External DCPAVServiceProxy services (empty on Intel or if the API is gone).
NSArray<SDPI2CService *> *SDPCopyI2CServices(void);

/// CoreDisplay's "IODisplayLocation" (IOService-plane path) for a display, if any.
NSString *_Nullable SDPDisplayLocation(CGDirectDisplayID display);

/// CoreDisplay's product name for a display (works for mirrored displays,
/// which have no NSScreen), if any.
NSString *_Nullable SDPDisplayName(CGDirectDisplayID display);

// MARK: Enable / disable

BOOL SDPCanToggleDisplays(void);
CGError SDPConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, BOOL enabled);

// MARK: Rotation (MonitorPanel)

BOOL SDPCanRotate(CGDirectDisplayID display);
/// Degrees (0/90/180/270) or -1 when unknown.
int SDPRotation(CGDirectDisplayID display);
BOOL SDPSetRotation(CGDirectDisplayID display, int degrees);

NS_ASSUME_NONNULL_END
