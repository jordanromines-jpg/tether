#import "VirtualDisplayShim.h"
#import <objc/message.h>

@implementation TetherVirtualDisplay {
    id _display;
}

+ (BOOL)isAvailable {
    return NSClassFromString(@"CGVirtualDisplay") && NSClassFromString(@"CGVirtualDisplayDescriptor")
        && NSClassFromString(@"CGVirtualDisplaySettings") && NSClassFromString(@"CGVirtualDisplayMode");
}

- (nullable instancetype)initWithName:(NSString *)name pointsWide:(uint32_t)pointsWide pointsHigh:(uint32_t)pointsHigh {
    if (!(self = [super init])) return nil;
    if (![TetherVirtualDisplay isAvailable]) return nil;

    uint32_t pxW = pointsWide * 2, pxH = pointsHigh * 2;

    id descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    @try {
        [descriptor setValue:dispatch_get_main_queue() forKey:@"queue"];
        [descriptor setValue:name forKey:@"name"];
        [descriptor setValue:@(pxW) forKey:@"maxPixelsWide"];
        [descriptor setValue:@(pxH) forKey:@"maxPixelsHigh"];
        // ~110 DPI physical size so macOS picks sensible defaults.
        CGSize mm = CGSizeMake(pxW / 2 * 25.4 / 110.0, pxH / 2 * 25.4 / 110.0);
        [descriptor setValue:[NSValue valueWithSize:NSSizeFromCGSize(mm)] forKey:@"sizeInMillimeters"];
        [descriptor setValue:@(0x7E7E) forKey:@"vendorID"];
        [descriptor setValue:@(0x0001) forKey:@"productID"];
        [descriptor setValue:@(0x0001) forKey:@"serialNum"];
    } @catch (NSException *e) {
        NSLog(@"Tether: virtual display descriptor rejected: %@", e);
        return nil;
    }

    id (*initWithDescriptor)(id, SEL, id) = (void *)objc_msgSend;
    id display = initWithDescriptor([NSClassFromString(@"CGVirtualDisplay") alloc],
                                    NSSelectorFromString(@"initWithDescriptor:"), descriptor);
    if (!display) return nil;

    id (*initMode)(id, SEL, unsigned int, unsigned int, double) = (void *)objc_msgSend;
    id mode = initMode([NSClassFromString(@"CGVirtualDisplayMode") alloc],
                       NSSelectorFromString(@"initWithWidth:height:refreshRate:"), pxW, pxH, 60.0);
    id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    @try {
        [settings setValue:@1 forKey:@"hiDPI"];
        [settings setValue:@[mode] forKey:@"modes"];
    } @catch (NSException *e) {
        NSLog(@"Tether: virtual display settings rejected: %@", e);
        return nil;
    }
    BOOL (*applySettings)(id, SEL, id) = (void *)objc_msgSend;
    if (!applySettings(display, NSSelectorFromString(@"applySettings:"), settings)) return nil;

    _display = display;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display ? (CGDirectDisplayID)[[_display valueForKey:@"displayID"] unsignedIntValue] : 0;
}

@end
