// CGVirtualDisplay is private CoreGraphics API (also used by Chromium and DeskPad).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@end

@interface CGVirtualDisplayMode : NSObject
// A transfer function of 1 gives the display HDR headroom.
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate transferFunction:(unsigned int)transferFunction;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) unsigned int displayID;
@end
