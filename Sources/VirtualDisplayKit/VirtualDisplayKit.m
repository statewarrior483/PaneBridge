#import "VirtualDisplayKit.h"

// CGVirtualDisplay is a private CoreGraphics API (no public header). We only
// describe the bits we use as protocols and look the classes up at runtime, so
// nothing links against private symbols and a missing class fails gracefully.

@protocol PBCGVirtualDisplayDescriptor <NSObject>
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end

@protocol PBCGVirtualDisplayMode <NSObject>
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@protocol PBCGVirtualDisplaySettings <NSObject>
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@protocol PBCGVirtualDisplay <NSObject>
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@end

@implementation PBVirtualDisplay {
    id<PBCGVirtualDisplay> _display;
}

- (nullable instancetype)initWithName:(NSString *)name
                                width:(uint32_t)width
                               height:(uint32_t)height
                          refreshRate:(double)refreshRate
                                hiDPI:(BOOL)hiDPI {
    self = [super init];
    if (!self) return nil;

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descriptorClass || !displayClass || !settingsClass || !modeClass) {
        NSLog(@"CGVirtualDisplay API not available on this macOS version");
        return nil;
    }

    uint32_t pixelsWide = hiDPI ? width * 2 : width;
    uint32_t pixelsHigh = hiDPI ? height * 2 : height;

    id<PBCGVirtualDisplayDescriptor> descriptor = [[descriptorClass alloc] init];
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    descriptor.name = name;
    descriptor.maxPixelsWide = pixelsWide;
    descriptor.maxPixelsHigh = pixelsHigh;
    // Pretend to be a ~110 ppi monitor so macOS picks sensible UI scaling.
    const double ppi = 110.0;
    descriptor.sizeInMillimeters = CGSizeMake(width / ppi * 25.4, height / ppi * 25.4);
    descriptor.vendorID = 0x5042;  // "PB"
    descriptor.productID = 0x0001;
    descriptor.serialNum = 0x0001;
    descriptor.terminationHandler = ^(id a, id b) {
        NSLog(@"Virtual display was terminated by the system");
    };

    id<PBCGVirtualDisplay> display = [(id<PBCGVirtualDisplay>)[displayClass alloc] initWithDescriptor:descriptor];
    if (!display) return nil;

    id<PBCGVirtualDisplaySettings> settings = [[settingsClass alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    id mode = [(id<PBCGVirtualDisplayMode>)[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate];
    settings.modes = @[ mode ];

    if (![display applySettings:settings]) {
        NSLog(@"Failed to apply virtual display settings");
        return nil;
    }

    _display = display;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

@end
