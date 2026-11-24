// Wii plugin orientation integration v17 -- standalone build, without modifying the OpenEmu checkout.
// Original Wii controller/responder implementation remains in the local OpenEmu-Silicon source tree.
#import "OEWiiSystemController.h"
#import "OEWiiOrientationGameplay.h"
#import <CoreFoundation/CoreFoundation.h>

// Wii Controls orientation integration, compiled as a Wii-only source file.
// This code deliberately does not patch, subclass, or modify any OpenEmu app class.
// It uses the already-exposed OESystemController artwork properties, listens for
// window updates, and adds two native radio buttons to two reserved Wii rows.
//
// Compatibility note: this UI enhancement uses OpenEmu view lookup and
// mutable image/mask backing without modifying shared application source.

#import <Cocoa/Cocoa.h>
#import <string.h>
#import <math.h>
#import <objc/runtime.h>

// Swift's ControllerImageView caches its [String:NSValue] dictionary when built.
// Values are reference objects, so mutable NSValue subclasses can supply live
// points without writing to any private Swift properties.
@interface OEWiiLivePointValue : NSValue
@property(nonatomic, assign) NSPoint livePoint;
- (instancetype)initWithLivePoint:(NSPoint)point;
@end

@implementation OEWiiLivePointValue
- (instancetype)initWithLivePoint:(NSPoint)point
{
    if((self = [super init])) _livePoint = point;
    return self;
}
- (const char *)objCType { return @encode(NSPoint); }
- (void)getValue:(void *)value { memcpy(value, &_livePoint, sizeof(NSPoint)); }
- (NSPoint)pointValue { return _livePoint; }
@end

// Keep the system radio controls visually enabled during an animation.
// Disabling NSButton itself makes AppKit gray/fade the controls. Instead,
// consume interaction while the image/mask/key-map transition is in progress.
@interface OEWiiOrientationRadioButton : NSButton
@property(nonatomic, assign) BOOL interactionLocked;
@end

@implementation OEWiiOrientationRadioButton
- (void)mouseDown:(NSEvent *)event
{
    if(self.interactionLocked) return;
    [super mouseDown:event];
}

- (void)keyDown:(NSEvent *)event
{
    if(self.interactionLocked) return;
    [super keyDown:event];
}

- (void)performClick:(id)sender
{
    if(self.interactionLocked) return;
    [super performClick:sender];
}
@end

// Measure the offset where AppKit ACTUALLY paints radio-button text. The
// circle-to-title gap changes with macOS appearance and control size; the
// older fixed offset was wrong in both v4 and v5 screenshots.
@interface OEWiiMeasuredRadioCell : NSButtonCell
@property(nonatomic, assign) CGFloat titleInset;
@property(nonatomic, assign) BOOL hasMeasuredTitle;
@end

@implementation OEWiiMeasuredRadioCell
- (NSRect)drawTitle:(NSAttributedString *)title withFrame:(NSRect)frame inView:(NSView *)view
{
    if(view && title.length) {
        self.titleInset = NSMinX(frame) - NSMinX(view.bounds);
        self.hasMeasuredTitle = YES;
    }
    return [super drawTitle:title withFrame:frame inView:view];
}
@end

static BOOL OEWiiHasClassSuffix(NSView *view, NSString *name)
{
    return [NSStringFromClass(view.class) hasSuffix:name];
}

static void OEWiiFindViews(NSView *root, NSMutableArray<NSView *> *out)
{
    [out addObject:root];
    for(NSView *child in root.subviews) OEWiiFindViews(child, out);
}

// OpenEmu's wooden ControlsLabel draws attributed strings. Assigning
// NSTextField.font alone may leave the existing attributed font unchanged,
// making a requested device-heading enlargement visually ineffective.
// Update both the field/cell and the attributed text explicitly. Preserve
// the host's colors, shadow, and row size; apply 13.5 pt bold.
//
// Maintain the approved 4.5-point optical adjustment for normal group
// labels. For Wiimote only, a 3-point downward nudge plus the 2-point
// font increase reduces the visible gap before Orientation. No other
// group heading or radio/button/section geometry is repositioned.
// Track the last adjusted frame to avoid drift on repeated window updates.
static char OEWiiBalancedHeadingRectKey;
static char OEWiiHeadingLogKey;
static const CGFloat OEWiiOrientationTitleDown = 4.5;
static const CGFloat OEWiiWiimoteTitleDown = 3.0;

static BOOL OEWiiIsDeviceHeading(NSString *label)
{
    return [label isEqualToString:@"Wiimote"] ||
           [label isEqualToString:@"Nunchuk"] ||
           [label isEqualToString:@"Classic Controller"];
}

// These are the only three enlarged device-name headings. OpenEmu's wooden
// ControlsLabel draws its ATTRIBUTED string, so a bold font must be installed
// on both the field/cell and the attributed text. Merely changing .font or
// checking font size alone can leave the visible glyphs at their old weight.
// No frame or row size changes are necessary.
static void OEWiiSetDeviceHeadingFont(NSTextField *heading)
{
    NSFont *desiredFont = [NSFont boldSystemFontOfSize:13.5];
    NSFont *currentFont = heading.font;
    NSAttributedString *currentText = heading.attributedStringValue;
    NSFont *textFont = currentText.length ?
        [currentText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] : nil;
    NSFont *cellFont = [(NSTextFieldCell *)heading.cell font];

    // Compare font FAMILY/WEIGHT as well as size. The v11 size-only check
    // would have skipped this change because headings were already 13.5 pt.
    BOOL correctField = currentFont &&
        fabs(currentFont.pointSize - desiredFont.pointSize) < 0.01 &&
        [currentFont.fontName isEqualToString:desiredFont.fontName];
    BOOL correctText = textFont &&
        fabs(textFont.pointSize - desiredFont.pointSize) < 0.01 &&
        [textFont.fontName isEqualToString:desiredFont.fontName];
    BOOL correctCell = cellFont &&
        fabs(cellFont.pointSize - desiredFont.pointSize) < 0.01 &&
        [cellFont.fontName isEqualToString:desiredFont.fontName];
    if(correctField && correctText && correctCell) return;

    NSMutableAttributedString *updated = currentText.length ? [currentText mutableCopy] :
        [[NSMutableAttributedString alloc] initWithString:heading.stringValue ?: @""];
    if(updated.length)
        [updated addAttribute:NSFontAttributeName value:desiredFont
                       range:NSMakeRange(0, updated.length)];
    heading.font = desiredFont;
    heading.cell.font = desiredFont;
    if(updated.length) heading.attributedStringValue = updated;
    heading.needsDisplay = YES;
}

static void OEWiiBalanceGroupHeadings(NSView *list)
{
    for(NSView *view in list.subviews) {
        if(!OEWiiHasClassSuffix(view, @"ControlsKeyHeadline") ||
           ![view isKindOfClass:[NSTextField class]] ||
           NSWidth(view.frame) <= 0 || NSHeight(view.frame) <= 0) continue;

        NSTextField *heading = (NSTextField *)view;
        NSString *label = heading.stringValue;
        BOOL deviceHeading = OEWiiIsDeviceHeading(label);
        if(deviceHeading) OEWiiSetDeviceHeadingFont(heading);

        // The invisible placeholder rows are anchors for the radio controls.
        // Leave ALL invisible spacer anchors at their native positions;
        // includes the new three-space rows before Nunchuk / Classic Controller.
        if([[label stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] == 0) continue;

        CGFloat headingDown = [label isEqualToString:@"Orientation"]
                            ? OEWiiOrientationTitleDown
                            : [label isEqualToString:@"Wiimote"]
                            ? OEWiiWiimoteTitleDown : 4.5;

        NSRect current = view.frame;
        NSValue *lastAdjusted = objc_getAssociatedObject(view, &OEWiiBalancedHeadingRectKey);
        if(!lastAdjusted || !NSEqualRects(current, lastAdjusted.rectValue)) {
            current.origin.y -= headingDown; // AppKit list uses bottom-left coordinates.
            view.frame = current;
            objc_setAssociatedObject(view, &OEWiiBalancedHeadingRectKey,
                                     [NSValue valueWithRect:current], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        // Print a one-time per-view diagnostic if we need to distinguish a
        // cached/old plugin from this build on the user's Mac.
        if(deviceHeading && !objc_getAssociatedObject(view, &OEWiiHeadingLogKey)) {
            NSFont *drawnFont = heading.attributedStringValue.length ?
                [heading.attributedStringValue attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] : nil;
            NSLog(@"[WiiOrientation v17] %@ heading: field=%.1fpt attributed=%.1fpt",
                  label, heading.font.pointSize, drawnFont.pointSize);
            objc_setAssociatedObject(view, &OEWiiHeadingLogKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

@interface OEWiiOrientationCoordinator : NSObject
@property(nonatomic, strong) NSImage *liveImage;
@property(nonatomic, strong) NSImage *liveMask;
@property(nonatomic, strong) NSDictionary<NSString *, NSValue *> *livePoints;
@property(nonatomic, strong) NSBundle *resourceBundle;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSBitmapImageRep *> *frameCache;
@property(nonatomic, weak) NSView *activeImageView;
@property(nonatomic, weak) NSView *activeControlsList;
@property(nonatomic, strong) OEWiiOrientationRadioButton *uprightButton;
@property(nonatomic, strong) OEWiiOrientationRadioButton *sidewaysButton;
@property(nonatomic, strong) NSTimer *animationTimer;
@property(nonatomic, strong) NSView *inputShield;
@property(nonatomic, assign) BOOL sideways;
@property(nonatomic, assign) BOOL transitioning;
@property(nonatomic, assign) NSUInteger nextAnimationIndex;
@property(nonatomic, strong) NSArray<NSString *> *animationNames;
+ (instancetype)shared;
- (void)configureWithBundle:(NSBundle *)bundle;
- (void)refreshWindow:(NSWindow *)window;
@end

// Cross-process, plugin-only preference. Controls live in the main app, but
// OEWiiSystemResponder lives in OpenEmuHelperApp. Their default NSUserDefaults
// domains are different, so publish this to an explicit shared CFPreferences
// application ID, without modifying OpenEmu or Dolphin.
static void OEWiiPublishGameplayOrientation(BOOL sideways)
{
    CFPreferencesSetAppValue(CFSTR("sideways"), sideways ? kCFBooleanTrue : kCFBooleanFalse,
                             CFSTR("org.openemu.WiiOrientation"));
    if(!CFPreferencesAppSynchronize(CFSTR("org.openemu.WiiOrientation"))) {
        NSLog(@"[WiiOrientation v17] WARNING: could not save shared gameplay orientation");
    }
}

@implementation OEWiiOrientationCoordinator

+ (instancetype)shared
{
    static OEWiiOrientationCoordinator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [OEWiiOrientationCoordinator new]; });
    return shared;
}

- (NSPoint)pointFromImagePixelX:(CGFloat)x y:(CGFloat)y
{
    // Images are 900 x 900 pixels stored in @2x asset-catalog entries.
    // ControllerImageView's key positions use image-relative *points*.
    return NSMakePoint(x / 2.0, y / 2.0);
}

- (NSDictionary<NSString *, NSArray<NSValue *> *> *)pointPairs
{
    static NSDictionary *pairs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pairs = @{
            // Locations measured at the CENTER of each red dot in the
            // user-provided 900x900 Upright / Sideways button-location maps.
            // These are bottom-left-origin pixel coordinates, converted to
            // AppKit @2x point coordinates by pointFromImagePixelX:y:.
            // Both orientations place Up/Down/Left/Right on the *visible*
            // top/bottom/left/right arms of the D-pad (screen-relative).
            // Sideways must NOT reuse the rotational mapping of the physical
            // Wiimote buttons; this is the on-screen selection ring only.
            // Dolphin gameplay orientation and keyboard mappings are unchanged.
            @"OEWiiMoteButtonUp":    @[[NSValue valueWithPoint:NSMakePoint(458, 769)], [NSValue valueWithPoint:NSMakePoint(170, 487)]],
            @"OEWiiMoteButtonDown":  @[[NSValue valueWithPoint:NSMakePoint(458, 711)], [NSValue valueWithPoint:NSMakePoint(170, 429)]],
            @"OEWiiMoteButtonLeft":  @[[NSValue valueWithPoint:NSMakePoint(429, 740)], [NSValue valueWithPoint:NSMakePoint(141, 458)]],
            @"OEWiiMoteButtonRight": @[[NSValue valueWithPoint:NSMakePoint(487, 740)], [NSValue valueWithPoint:NSMakePoint(199, 458)]],
            @"OEWiiMoteButtonA":     @[[NSValue valueWithPoint:NSMakePoint(461, 619)], [NSValue valueWithPoint:NSMakePoint(290, 460)]],
            // B is physically behind the remote, so no red dot was supplied.
            // Estimate it ~67px toward Home from A, on the controller body;
            // this minimizes accidental selection when clicking A itself.
            @"OEWiiMoteButtonB":     @[[NSValue valueWithPoint:NSMakePoint(461, 552)], [NSValue valueWithPoint:NSMakePoint(357, 460)]],
            @"OEWiiMoteButtonMinus": @[[NSValue valueWithPoint:NSMakePoint(404, 484)], [NSValue valueWithPoint:NSMakePoint(426, 405)]],
            @"OEWiiMoteButtonHome":  @[[NSValue valueWithPoint:NSMakePoint(460, 484)], [NSValue valueWithPoint:NSMakePoint(426, 461)]],
            @"OEWiiMoteButtonPlus":  @[[NSValue valueWithPoint:NSMakePoint(516, 484)], [NSValue valueWithPoint:NSMakePoint(427, 516)]],
            @"OEWiiMoteButton1":     @[[NSValue valueWithPoint:NSMakePoint(461, 273)], [NSValue valueWithPoint:NSMakePoint(638, 462)]],
            @"OEWiiMoteButton2":     @[[NSValue valueWithPoint:NSMakePoint(461, 199)], [NSValue valueWithPoint:NSMakePoint(712, 462)]]
        };
    });
    return pairs;
}

- (void)configureWithBundle:(NSBundle *)bundle
{
    if(self.liveImage) return;
    self.resourceBundle = bundle;
    self.frameCache = [NSMutableDictionary dictionary];
    self.sideways = [[NSUserDefaults standardUserDefaults] boolForKey:@"OEWiiOrientationSidewaysPreview"];
    // Migrate the approved v14 UI choice into the shared gameplay preference.
    OEWiiPublishGameplayOrientation(self.sideways);
    NSLog(@"[WiiOrientation v17] Artwork configured, sideways=%d", (int)self.sideways);

    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for(NSString *key in [self pointPairs]) {
        OEWiiLivePointValue *value = [[OEWiiLivePointValue alloc] initWithLivePoint:NSZeroPoint];
        values[key] = value;
    }
    self.livePoints = [values copy];
    self.liveImage = [[NSImage alloc] initWithSize:NSMakeSize(450, 450)];
    self.liveMask  = [[NSImage alloc] initWithSize:NSMakeSize(450, 450)];
    [self updateEndpointWithOrientation:self.sideways];
}

- (NSBitmapImageRep *)bitmapForAsset:(NSString *)name
{
    NSBitmapImageRep *cached = self.frameCache[name];
    if(cached) return cached;
    NSImage *source = [self.resourceBundle imageForResource:name];
    if(!source) {
        NSLog(@"Wii orientation: missing asset %@", name);
        return nil;
    }
    CGImageRef cgImage = [source CGImageForProposedRect:NULL context:nil hints:nil];
    if(!cgImage) {
        NSLog(@"Wii orientation: image %@ could not decode", name);
        return nil;
    }
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
    rep.size = NSMakeSize(450, 450);
    self.frameCache[name] = rep;
    return rep;
}

- (void)replaceBackingOf:(NSImage *)image asset:(NSString *)assetName
{
    NSBitmapImageRep *newRep = [self bitmapForAsset:assetName];
    if(!newRep) return;
    // Retain the *same* NSImage instance given to OpenEmu. This avoids
    // replacing ControllerImageView and disturbing its native click handler.
    for(NSImageRep *existing in [image.representations copy])
        [image removeRepresentation:existing];
    [image addRepresentation:newRep];
    [image setSize:NSMakeSize(450, 450)];
}

- (void)redrawImageView
{
    [self.activeImageView setNeedsDisplay:YES];
}

- (void)updateEndpointWithOrientation:(BOOL)sideways
{
    [self replaceBackingOf:self.liveImage asset:sideways ? @"controller_wii_sideways" : @"controller_wii_upright"];
    [self replaceBackingOf:self.liveMask asset:sideways ? @"controller_wii_sideways_mask" : @"controller_wii_upright_mask"];

    [[self pointPairs] enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSArray<NSValue *> *pair, BOOL *stop) {
        NSPoint pixelPoint = pair[sideways ? 1 : 0].pointValue;
        ((OEWiiLivePointValue *)self.livePoints[key]).livePoint =
            [self pointFromImagePixelX:pixelPoint.x y:pixelPoint.y];
    }];
    [self redrawImageView];
}

- (void)finishTransition
{
    [self.animationTimer invalidate];
    self.animationTimer = nil;
    [self updateEndpointWithOrientation:self.sideways];
    [self.inputShield removeFromSuperview];
    self.inputShield = nil;
    self.transitioning = NO;
    // Restore interaction without ever changing the buttons' visual opacity.
    self.uprightButton.interactionLocked = NO;
    self.sidewaysButton.interactionLocked = NO;
    self.uprightButton.state = self.sideways ? NSControlStateValueOff : NSControlStateValueOn;
    self.sidewaysButton.state = self.sideways ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)tick:(NSTimer *)timer
{
    if(self.nextAnimationIndex >= self.animationNames.count) {
        [self finishTransition];
        return;
    }
    NSString *asset = self.animationNames[self.nextAnimationIndex++];
    [self replaceBackingOf:self.liveImage asset:asset];
    [self redrawImageView];
    if(self.nextAnimationIndex == self.animationNames.count) [self finishTransition];
}

// Cancel an active blue ring, dark overlay, and key-binding target before
// starting a Wiimote rotation. OpenEmu's Swift ControllerImageView does not
// expose a public clearSelection API, but its existing mouseDown: behavior
// already performs the complete deselection and notifies
// PrefControlsController.changeInputControl:. Sending that *view* a local
// transparent-corner click uses the native selection path rather than only
// hiding the ring (which would leave keyboard/controller reassignment active).
//
// The bitmap masks in both orientations have fully transparent corners.
// We send the synthetic event directly to that specific Wii artwork view;
// nothing is posted into the app's general event queue or to other plugins.
- (void)cancelCurrentArtworkSelection
{
    NSView *imageView = self.activeImageView;
    NSWindow *window = imageView.window;
    if(!imageView || !window || NSWidth(imageView.bounds) < 8 ||
       NSHeight(imageView.bounds) < 8) return;

    NSPoint emptyCorner = NSMakePoint(NSMinX(imageView.bounds) + 2,
                                      NSMinY(imageView.bounds) + 2);
    NSPoint windowPoint = [imageView convertPoint:emptyCorner toView:nil];
    NSEvent *blankClick = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                             location:windowPoint
                                        modifierFlags:0
                                            timestamp:0
                                         windowNumber:window.windowNumber
                                              context:nil
                                          eventNumber:0
                                           clickCount:1
                                             pressure:1.0];
    if(!blankClick) return;

    // Suppress the native ring's normal fade-out so it disappears BEFORE the
    // first rotation frame, not halfway through the user's animation.
    [NSAnimationContext beginGrouping];
    [NSAnimationContext currentContext].duration = 0;
    [imageView mouseDown:blankClick];
    [NSAnimationContext endGrouping];

    // OpenEmu exposes these three highlight properties as @objc dynamic for
    // its own Core Animation. If they are present, finish any in-flight fade
    // immediately, including its dark background overlay. Their absence on
    // a future OpenEmu version is harmless: the native deselection above is
    // still the authoritative way to cancel the binding selection.
    if([imageView respondsToSelector:NSSelectorFromString(@"setRingAlpha:")] &&
       [imageView respondsToSelector:NSSelectorFromString(@"setOverlayAlpha:")] &&
       [imageView respondsToSelector:NSSelectorFromString(@"setRingPosition:")]) {
        [imageView.layer removeAnimationForKey:@"ringAlpha"];
        [imageView.layer removeAnimationForKey:@"overlayAlpha"];
        [imageView.layer removeAnimationForKey:@"ringPosition"];
        [imageView setValue:@0.0 forKey:@"ringAlpha"];
        [imageView setValue:@0.0 forKey:@"overlayAlpha"];
        [imageView setValue:[NSValue valueWithPoint:NSZeroPoint] forKey:@"ringPosition"];
        imageView.needsDisplay = YES;
    }
}

- (void)chooseOrientation:(NSButton *)sender
{
    BOOL wantSideways = (sender == self.sidewaysButton);
    if(self.transitioning || !self.resourceBundle) return;

    // A radio-button click ends an active assignment even if the user clicked
    // the radio button that was already selected (no rotation in that case).
    [self cancelCurrentArtworkSelection];
    if(wantSideways == self.sideways) return;

    self.transitioning = YES;
    self.sideways = wantSideways;
    [[NSUserDefaults standardUserDefaults] setBool:wantSideways forKey:@"OEWiiOrientationSidewaysPreview"];
    // Update the helper process immediately; gameplay will apply the setting
    // through the Wii responder without changing Dolphin itself.
    OEWiiPublishGameplayOrientation(wantSideways);

    // Reserve all controller clicks until image, hit mask, and key coordinates
    // have reached their next stable endpoint.
    if(self.activeImageView) {
        NSView *shield = [[NSView alloc] initWithFrame:self.activeImageView.bounds];
        shield.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.activeImageView addSubview:shield];
        self.inputShield = shield;
    }
    // Block input without disabling/fading the native radio buttons.
    self.uprightButton.interactionLocked = YES;
    self.sidewaysButton.interactionLocked = YES;
    self.uprightButton.state = wantSideways ? NSControlStateValueOff : NSControlStateValueOn;
    self.sidewaysButton.state = wantSideways ? NSControlStateValueOn : NSControlStateValueOff;

    if([[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceMotion]) {
        [self finishTransition];
        return;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for(NSInteger i=1; i<=14; i++) {
        [names addObject:[NSString stringWithFormat:@"controller_wii_%@_%02ld", wantSideways ? @"u2s" : @"s2u", (long)i]];
    }
    [names addObject:wantSideways ? @"controller_wii_sideways" : @"controller_wii_upright"];
    // Decode all 15 upcoming frames before starting the 30 fps timer,
    // preventing first-use PNG decompression from making the motion stutter.
    for(NSString *name in names) [self bitmapForAsset:name];
    self.animationNames = [names copy];
    self.nextAnimationIndex = 0;
    // The starting endpoint is already displayed. 15 additional frames
    // spaced at 1/30 second give a 0.50-second transition.
    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0/30.0)
                                                          target:self
                                                        selector:@selector(tick:)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (OEWiiOrientationRadioButton *)radioButtonWithTitle:(NSString *)title
{
    OEWiiOrientationRadioButton *button = [[OEWiiOrientationRadioButton alloc] initWithFrame:NSMakeRect(0,0,150,20)];
    // Custom cell only observes where the native control draws its title;
    // the drawing, keyboard behavior, and radio appearance stay native.
    button.cell = [[OEWiiMeasuredRadioCell alloc] initTextCell:title];
    button.buttonType = NSButtonTypeRadio;
    button.title = title;
    button.toolTip = @"Wii System Plugin v17";
    button.target = self;
    button.action = @selector(chooseOrientation:);
    return button;
}

- (void)refreshWindow:(NSWindow *)window
{
    if(!window.contentView || !self.liveImage || self.transitioning) return;
    NSMutableArray<NSView *> *views = [NSMutableArray array];
    OEWiiFindViews(window.contentView, views);

    NSView *list = nil;
    NSView *imageView = nil;
    NSView *firstRow = nil;
    NSView *secondRow = nil;
    for(NSView *view in views) {
        if(OEWiiHasClassSuffix(view, @"ControlsButtonSetupView")) list = view;
        else if(OEWiiHasClassSuffix(view, @"ControllerImageView")) imageView = view;
    }
    if(!list || !imageView) return;

    // The two space-only labels are reserved by the plugin controlPageList.
    // Other consoles have no such pair, so this cannot decorate their views.
    for(NSView *view in list.subviews) {
        if(!OEWiiHasClassSuffix(view, @"ControlsKeyHeadline") || ![view isKindOfClass:[NSTextField class]]) continue;
        NSString *name = [(NSTextField *)view stringValue];
        if([name isEqualToString:@" "]) firstRow = view;
        if([name isEqualToString:@"  "]) secondRow = view;
    }
    if(!firstRow || !secondRow) {
        // ControlsButtonSetupView is reused across systems. The radio buttons
        // are Wii-only and must not remain attached to another system's pane.
        if(self.uprightButton.superview == list) [self.uprightButton removeFromSuperview];
        if(self.sidewaysButton.superview == list) [self.sidewaysButton removeFromSuperview];
        return;
    }

    self.activeImageView = imageView;
    self.activeControlsList = list;
    if(!self.uprightButton) self.uprightButton = [self radioButtonWithTitle:@"Upright"];
    if(!self.sidewaysButton) self.sidewaysButton = [self radioButtonWithTitle:@"Sideways"];

    // Optically balance the headings before measuring the selector position.
    // Our offset calculation below removes Orientation's VISUAL nudge so the
    // already-approved radio-button spacing and position do not change.
    OEWiiBalanceGroupHeadings(list);

    // Align the BEGINNING OF THE RADIO TEXT with the real input-box left edge.
    // The NSButton frame itself starts to the left because AppKit reserves
    // space for the native radio circle. v4 used a guessed 36-pt inset;
    // v5 used none. Both were visibly wrong. Use the cell's measured
    // drawTitle:withFrame: geometry (22 pt fallback for the initial paint).
    CGFloat bindingX = NSMinX(firstRow.frame) + 78.0; // fallback
    for(NSView *view in list.subviews) {
        if(OEWiiHasClassSuffix(view, @"ControlsKeyButton") && NSWidth(view.frame) > 0) {
            bindingX = NSMinX(view.frame);
            break;
        }
    }
    CGFloat textInset = 22.0;
    OEWiiMeasuredRadioCell *cell = (OEWiiMeasuredRadioCell *)self.uprightButton.cell;
    if([cell isKindOfClass:[OEWiiMeasuredRadioCell class]] &&
       cell.hasMeasuredTitle && cell.titleInset > 12.0 && cell.titleInset < 50.0)
        textInset = cell.titleInset;
    CGFloat x = bindingX - textInset;
    CGFloat width = MAX(100.0, list.bounds.size.width - x - 12.0);
    CGFloat height = 20.0;

    // Balance the visible top/bottom gaps by shifting BOTH radio controls
    // together. The two placeholder rows continue to define their spacing;
    // the D-Pad begins immediately after them (no full-height spacer row).
    NSView *orientationHeading = nil;
    NSView *nearestDPadHeading = nil;
    CGFloat lowerRadioY = NSMidY(secondRow.frame);
    for(NSView *view in list.subviews) {
        if(!OEWiiHasClassSuffix(view, @"ControlsKeyHeadline") ||
           ![view isKindOfClass:[NSTextField class]]) continue;
        NSString *label = [(NSTextField *)view stringValue];
        if([label isEqualToString:@"Orientation"]) orientationHeading = view;
        if([label isEqualToString:@"D-Pad"] && NSMidY(view.frame) < lowerRadioY &&
           (!nearestDPadHeading || NSMidY(view.frame) > NSMidY(nearestDPadHeading.frame)))
            nearestDPadHeading = view;
    }
    CGFloat offsetY = 0.0;
    if(orientationHeading && nearestDPadHeading) {
        // The heading is visually nudged closer to Upright, but the two radio
        // controls must NOT move. Recover the original heading center when
        // calculating their shared offset. This is stable across repeated
        // refreshes and host relayouts (the adjustment is recorded per view).
        CGFloat originalHeadingY = NSMidY(orientationHeading.frame);
        NSValue *lastAdjustedHeading = objc_getAssociatedObject(orientationHeading, &OEWiiBalancedHeadingRectKey);
        if(lastAdjustedHeading && NSEqualRects(orientationHeading.frame, lastAdjustedHeading.rectValue))
            originalHeadingY += OEWiiOrientationTitleDown;
        CGFloat upperGap = originalHeadingY - NSMidY(firstRow.frame);
        CGFloat lowerGap = NSMidY(secondRow.frame) - NSMidY(nearestDPadHeading.frame);
        if(upperGap > 0 && upperGap < 120 && lowerGap > 0 && lowerGap < 120)
            offsetY = (upperGap - lowerGap) * 0.5;
    }

    self.uprightButton.frame = NSMakeRect(x, NSMidY(firstRow.frame) + offsetY - height/2.0, width, height);
    self.sidewaysButton.frame = NSMakeRect(x, NSMidY(secondRow.frame) + offsetY - height/2.0, width, height);

    // Crucial: OpenEmu's ControlsSectionTitleView is a *sticky* header and
    // draws its own wood background to occlude scrolling content. It was
    // initially sorted above all regular controls, but our late-added radio
    // buttons ended up ABOVE that header, making their text bleed through it.
    // Keep both buttons at the BACK of the list's z-order, just like native
    // binding rows. This also ensures the header takes mouse hits while pinned.
    NSArray<NSView *> *subviews = list.subviews;
    if(self.uprightButton.superview != list || [subviews indexOfObjectIdenticalTo:self.uprightButton] != 0)
        [list addSubview:self.uprightButton positioned:NSWindowBelow relativeTo:nil];
    subviews = list.subviews;
    if(self.sidewaysButton.superview != list || [subviews indexOfObjectIdenticalTo:self.sidewaysButton] > 1)
        [list addSubview:self.sidewaysButton positioned:NSWindowBelow relativeTo:self.uprightButton];

    self.uprightButton.state = self.sideways ? NSControlStateValueOff : NSControlStateValueOn;
    self.sidewaysButton.state = self.sideways ? NSControlStateValueOn : NSControlStateValueOff;
}
@end

// There are no modifications to PrefControlsController, ControllerImageView,
// ControlsButtonSetupView, the OpenEmu app bundle, or any framework.
@implementation OEWiiSystemController (OEWiiOrientationPreview)

// Reserve only the heading and two radio rows in Wii's native control list.
// The original Wii-Info.plist in the user's checkout stays untouched.
- (NSArray *)controlPageList
{
    NSArray *original = [super controlPageList];
    if(original.count < 2 || ![original[1] isKindOfClass:[NSArray class]]) return original;

    // OpenEmu's controlPageList is [page title, [group arrays], ...].
    // The Wiimote heading and D-Pad heading are inside the FIRST group array,
    // not direct children of the gameplay-page array. v1 missed this nesting,
    // so the reserved radio rows were never inserted.
    NSMutableArray *gameplayGroups = [original[1] mutableCopy];
    BOOL inserted = NO;
    for(NSUInteger groupIndex = 0; groupIndex < gameplayGroups.count; ++groupIndex) {
        NSArray *originalGroup = gameplayGroups[groupIndex];
        if(![originalGroup isKindOfClass:[NSArray class]]) continue;
        NSMutableArray *group = [originalGroup mutableCopy];
        for(NSUInteger rowIndex = 0; rowIndex + 1 < group.count; ++rowIndex) {
            if([group[rowIndex] isKindOfClass:[NSString class]] &&
               [group[rowIndex+1] isKindOfClass:[NSString class]] &&
               [group[rowIndex] isEqualToString:@"Wiimote"] &&
               [group[rowIndex+1] isEqualToString:@"D-Pad"]) {
                // Just the heading and two native-height placeholder rows.
                // v5's third blank row doubled the gap before D-Pad.
                // The overlay positions are balanced using actual heading
                // frames instead of consuming another complete 33-pt row.
                [group insertObject:@"Orientation" atIndex:rowIndex+1];
                [group insertObject:@" " atIndex:rowIndex+2];
                [group insertObject:@"  " atIndex:rowIndex+3];
                gameplayGroups[groupIndex] = group;
                inserted = YES;
                break;
            }
        }
        if(inserted) break;
    }
    if(!inserted) {
        NSLog(@"[WiiOrientation v17] ERROR: Wiimote/D-Pad control-list anchor absent");
        return original;
    }

    // Give Nunchuk and Classic Controller their own stronger visual grouping.
    // Adding one native-height invisible row before EACH device name produces
    // about one extra row of whitespace (24pt row + 9pt inter-row spacing),
    // roughly doubling the existing section separation. All later rows move
    // down together; no other internal gaps, fonts, or UI coordinates change.
    // Three spaces deliberately differs from the single/double-space radio
    // anchors, so the selector lookup cannot accidentally attach to these.
    NSUInteger deviceSeparatorsAdded = 0;
    for(NSUInteger groupIndex = 0; groupIndex < gameplayGroups.count; ++groupIndex) {
        NSArray *originalGroup = gameplayGroups[groupIndex];
        if(![originalGroup isKindOfClass:[NSArray class]]) continue;
        NSMutableArray *group = [originalGroup mutableCopy];
        BOOL changed = NO;
        for(NSUInteger rowIndex = 0; rowIndex < group.count; ++rowIndex) {
            id row = group[rowIndex];
            if([row isKindOfClass:[NSString class]] &&
               ([row isEqualToString:@"Nunchuk"] ||
                [row isEqualToString:@"Classic Controller"])) {
                [group insertObject:@"   " atIndex:rowIndex];
                deviceSeparatorsAdded++;
                changed = YES;
                rowIndex++; // Skip the device label; do not insert twice.
            }
        }
        if(changed) gameplayGroups[groupIndex] = [group copy];
    }
    if(deviceSeparatorsAdded != 2)
        NSLog(@"[WiiOrientation v17] WARNING: expected two device spacers; added %lu", (unsigned long)deviceSeparatorsAdded);

    // Supersede the legacy orientation hotkeys in Controls preferences only.
    // Keep the underlying responder/key definitions unchanged for compatibility
    // with existing saved bindings; this UI-only step does not alter Dolphin.
    NSUInteger removed = 0;
    NSUInteger shortened = 0;
    for(NSUInteger groupIndex = 0; groupIndex < gameplayGroups.count; ++groupIndex) {
        NSArray *originalGroup = gameplayGroups[groupIndex];
        if(![originalGroup isKindOfClass:[NSArray class]]) continue;
        NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:originalGroup.count];
        BOOL changedGroup = NO;
        for(id row in originalGroup) {
            if([row isKindOfClass:[NSDictionary class]]) {
                NSString *keyName = ((NSDictionary *)row)[OEControlListKeyNameKey];
                if([keyName isEqualToString:@"OEWiimoteSideways"] ||
                   [keyName isEqualToString:@"OEWiimoteUpright"]) {
                    removed++;
                    changedGroup = YES;
                    continue;
                }
                // OpenEmu's fixed-width label area wraps "Backward:" at the
                // colon. Shorten only its displayed text, not its binding key.
                // Both Tilt and Swing continue to use their original controls.
                if([keyName isEqualToString:@"OEWiiMoteTiltBackward"] ||
                   [keyName isEqualToString:@"OEWiiMoteSwingBackward"]) {
                    NSMutableDictionary *shortRow = [(NSDictionary *)row mutableCopy];
                    shortRow[OEControlListKeyLabelKey] = @"Back";
                    [filtered addObject:[shortRow copy]];
                    shortened++;
                    changedGroup = YES;
                    continue;
                }
            }
            [filtered addObject:row];
        }
        if(changedGroup) gameplayGroups[groupIndex] = filtered;
    }

    NSMutableArray *pages = [original mutableCopy];
    pages[1] = gameplayGroups;
    NSLog(@"[WiiOrientation v17] Wii selector rows registered; %lu legacy orientation rows hidden; %lu labels shortened", (unsigned long)removed, (unsigned long)shortened);

    // The host constructs ControlsButtonSetupView after reading this value.
    // Refresh after that layout pass as well as on subsequent window updates.
    dispatch_async(dispatch_get_main_queue(), ^{
        for(NSWindow *window in NSApp.windows)
            [[OEWiiOrientationCoordinator shared] refreshWindow:window];
    });
    return pages;
}


+ (void)load
{
    // Registration is passive and only paints controls if the Wii placeholder
    // rows and native ControllerImageView both exist in a visible window.
    NSLog(@"[WiiOrientation v17] Wii UI extension loaded");
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSArray<NSNotificationName> *names = @[
        NSWindowDidUpdateNotification,
        NSWindowDidBecomeKeyNotification,
        NSWindowDidResizeNotification,
        NSApplicationDidBecomeActiveNotification
    ];
    for(NSNotificationName name in names) {
        [center addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            if([note.object isKindOfClass:[NSWindow class]]) {
                [[OEWiiOrientationCoordinator shared] refreshWindow:note.object];
            } else {
                for(NSWindow *window in NSApp.windows)
                    [[OEWiiOrientationCoordinator shared] refreshWindow:window];
            }
        }];
    }
}

// The helper process instantiates the responder through this SDK hook.
// Use our Wii-only subclass to relay radio choices to the existing Dolphin
// hotkey path, while inheriting all original button and analog mappings.
- (OESystemResponder *)newGameSystemResponder
{
    return [[OEWiiOrientationGameplayResponder alloc] initWithController:self];
}

- (NSImage *)controllerImage
{
    OEWiiOrientationCoordinator *coordinator = [OEWiiOrientationCoordinator shared];
    [coordinator configureWithBundle:self.bundle];
    return coordinator.liveImage;
}

- (NSImage *)controllerImageMask
{
    OEWiiOrientationCoordinator *coordinator = [OEWiiOrientationCoordinator shared];
    [coordinator configureWithBundle:self.bundle];
    return coordinator.liveMask;
}

- (NSDictionary<NSString *, NSValue *> *)controllerKeyPositions
{
    OEWiiOrientationCoordinator *coordinator = [OEWiiOrientationCoordinator shared];
    [coordinator configureWithBundle:self.bundle];
    // Preserve every pre-existing Classic Controller button coordinate.
    // Only Wiimote keys are made orientation-dependent.
    NSMutableDictionary<NSString *, NSValue *> *all = [[super controllerKeyPositions] mutableCopy];
    if(!all) all = [NSMutableDictionary dictionary];
    [all addEntriesFromDictionary:coordinator.livePoints];
    return all;
}
@end
