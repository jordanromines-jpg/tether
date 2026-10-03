#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin wrapper over macOS's private CGVirtualDisplay API (the same one used by
/// DeskPad/BetterDisplay). Classes are looked up at runtime, so nothing links against
/// private symbols: if a future macOS removes them, `isAvailable` simply returns NO.
@interface TetherVirtualDisplay : NSObject

+ (BOOL)isAvailable;

/// Creates a HiDPI virtual display whose desktop is `pointsWide` × `pointsHigh` points
/// (rendered at 2× pixels). Returns nil on failure. The display disappears when this object is released.
- (nullable instancetype)initWithName:(NSString *)name pointsWide:(uint32_t)pointsWide pointsHigh:(uint32_t)pointsHigh;

@property (nonatomic, readonly) CGDirectDisplayID displayID;

@end

NS_ASSUME_NONNULL_END
