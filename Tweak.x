// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// WeatherPad 1.2.2
// Loaded into three processes only (see WeatherPad.plist):
//
// 1. The Weather Today widget (com.apple.weather.WeatherAppTodayWidget, iPhone 5s iOS 12.5.8 build).
//    -[WATodayViewController _widgetTapped:] builds a WFURLComponents for the current city and does
//        [components setDestination:(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone)];
//        [self.extensionContext openURL:components.URL completionHandler:nil];
//    destination 1 = the Weather app ("weather://..." private scheme), 0 = https://www.weather.com/...
//    On iPad the idiom check picks weather.com, so we force destination 1. Nothing else in the widget
//    (layout, the "_IPAD" nib variants) is touched.
//    The widget is sandboxed and may not be able to read our preferences, so SpringBoard publishes the
//    settings as the state of a Darwin notification, which the widget (and the app) read.
//
// 2. The Weather app (com.apple.weather): native, adaptive iPad layout (full screen portrait/landscape,
//    Split View, Slide Over). See "Weather app (native iPad layout)" below. Follows the Enabled switch.
//
// 3. SpringBoard: optional "iPhone layout" fallback for com.apple.weather (off by default since 1.1.0).
//    We hide the iPad device family from SpringBoard (-[SBApplicationInfo supportedTypes] /
//    -_supportsApplicationType:); SpringBoard then runs it like any iPhone-only app (2x button, no multitasking).
//    Takes effect after a respring.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <notify.h>

#define kWPDomain CFSTR("com.itsallexb.weatherpad")
#define kWPNotification "com.itsallexb.weatherpad/prefschanged"
#define kWPStateName "com.itsallexb.weatherpad/state"
#define kWPStateValid   0x100ULL
#define kWPStateWidget  0x1ULL
#define kWPStateIPhone  0x2ULL
#define kWPStateEnabled 0x4ULL
#define kWPStateAnimBG  0x8ULL

static NSString *const kWPWeatherBundleID = @"com.apple.weather";

static BOOL WPPrefBool(CFStringRef key, BOOL def, BOOL *found) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, kWPDomain);
    if (found) *found = (v != NULL);
    BOOL r = v ? [(__bridge id)v boolValue] : def;
    if (v) CFRelease(v);
    return r;
}

#pragma mark - SpringBoard

static BOOL gIPhoneLayout = NO;
static int gStateToken = -1;

static void WPPublishState(void) {
    CFPreferencesAppSynchronize(kWPDomain);
    BOOL enabled = WPPrefBool(CFSTR("enabled"), YES, NULL);
    BOOL widget = WPPrefBool(CFSTR("widgetOpensApp"), YES, NULL);
    BOOL animBG = WPPrefBool(CFSTR("animatedBackgrounds"), YES, NULL);
    gIPhoneLayout = enabled && WPPrefBool(CFSTR("iPhoneLayout"), NO, NULL);
    uint64_t state = kWPStateValid | (enabled ? kWPStateEnabled : 0) | ((enabled && widget) ? kWPStateWidget : 0)
        | (gIPhoneLayout ? kWPStateIPhone : 0) | ((enabled && animBG) ? kWPStateAnimBG : 0);
    if (gStateToken == -1) notify_register_check(kWPStateName, &gStateToken);
    if (gStateToken != -1) notify_set_state(gStateToken, state);
}

static void WPSBPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef ui) {
    WPPublishState();
}

static BOOL WPIsWeatherInfo(id info) {
    if (!gIPhoneLayout) return NO;
    if (![info respondsToSelector:@selector(bundleIdentifier)]) return NO;
    NSString *bid = [info performSelector:@selector(bundleIdentifier)];
    return [bid isKindOfClass:[NSString class]] && [bid isEqualToString:kWPWeatherBundleID];
}

%group WPSpringBoard
%hook SBApplicationInfo
- (unsigned int)supportedTypes {
    unsigned int types = %orig;
    // Only when it still supports iPhone (bit 0); 2 = iPad.
    if ((types & 1u) && WPIsWeatherInfo(self)) types &= ~2u;
    return types;
}
- (BOOL)_supportsApplicationType:(unsigned int)type {
    if (type == 2 && WPIsWeatherInfo(self)) return NO;
    return %orig;
}
%end
%end

#pragma mark - Shared state

static uint64_t WPReadState(void) {
    int token = -1;
    uint64_t state = 0;
    if (notify_register_check(kWPStateName, &token) == NOTIFY_STATUS_OK) {
        notify_get_state(token, &state);
        notify_cancel(token);
    }
    return state;
}

// Weather app: layout fixes follow the "Enabled" switch. The app is sandboxed, so read SpringBoard's published state.
static BOOL WPAppShouldFixLayout(void) {
    uint64_t state = WPReadState();
    if (state & kWPStateValid) return (state & kWPStateEnabled) != 0;
    return WPPrefBool(CFSTR("enabled"), YES, NULL);
}

static BOOL WPAppShouldAnimateBackgrounds(void) {
    uint64_t state = WPReadState();
    if (state & kWPStateValid) return (state & kWPStateAnimBG) != 0;
    return WPPrefBool(CFSTR("enabled"), YES, NULL) && WPPrefBool(CFSTR("animatedBackgrounds"), YES, NULL);
}

#pragma mark - Weather widget

static BOOL WPWidgetShouldOpenApp(void) {
    uint64_t state = WPReadState();
    if (state & kWPStateValid) return (state & kWPStateWidget) != 0;
    // SpringBoard part not running yet: try the preferences directly, default on.
    BOOL enabled = WPPrefBool(CFSTR("enabled"), YES, NULL);
    BOOL widget = WPPrefBool(CFSTR("widgetOpensApp"), YES, NULL);
    return enabled && widget;
}

%group WPWidget
%hook WFURLComponents
- (void)setDestination:(unsigned long long)destination {
    if (destination == 0 && WPWidgetShouldOpenApp()) destination = 1;
    %orig(destination);
}
%end
%end


#pragma mark - Weather app (native iPad layout)

// The iPhone Weather app (iOS 12.5.8) still carries most of an unfinished iPad design:
//  - WAContainerViewController always embeds a UISplitViewController. -isValidPhoneDeviceWithSize: (size.width <= 896
//    && idiom == phone) decides whether the split view is forced collapsed (compact override trait). On iPad it says
//    NO, so the app switches to an unfinished "expanded" mode: the city list as a 320 pt sidebar, the city pages
//    without the dynamic background (black) and without the bottom toolbar (page dots, list button).
//    -> we answer YES on iPad too, so the app always runs its finished, phone-style navigation (pages <-> city list).
//  - -[WAWeatherCityViewLayoutOptions initWithViewSize:traitCollection:] picks a metrics set from the view size.
//    Anything taller than 896 pt (or wider than 896 pt with a regular vertical size class) gets
//    _configureForRegulariPadOneColumn / _configureForRegulariPadTwoColumns, but those never set
//    pageCityNameBaselineY, temperatureBaselineOffset and temperatureBaselineToFirstDayBaseline (left 0). With 0 the
//    city name and the 138 pt temperature are drawn at the very top (clipped) and the daily forecast rows are laid out
//    from y < 0, i.e. under the hourly strip -> the overlapping layout. A 320 pt wide Split View / Slide Over window
//    (height 1024 or 768) also ends up in the iPad one-column set (138 pt temperature in 320 pt).
//    -> we choose the metrics set ourselves from the size the app passes in (its window / view size, so this also
//    follows Split View, Slide Over and divider drags; the app re-creates the options on every size transition):
//       width >= 660: two columns (hourly strip full width, daily forecast | details side by side), header metrics
//                     sized for the available height; tighter gutters below 900 pt.
//       width <  660: the stock iPhone one-column sets (320 pt -> iPhone SE set, wider -> Plus set).
//    Each variant gets its own uid because -isEqual: only compares uid (the app skips relayout for "equal" options).

static BOOL gWPAppHooksActive = NO;

static BOOL WPIsPadIdiom(void) {
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
}

typedef NS_ENUM(long long, WPUid) {
    WPUidTwoColumnTall = 1005,
    WPUidTwoColumnWide = 1006,
    WPUidTwoColumnNarrow = 1007,
    WPUidOneColumnSmall = 1001,
    WPUidOneColumnLarge = 1003,
};

static void WPSet(id o, NSString *key, double v) { [o setValue:@(v) forKey:key]; }
static double WPGet(id o, NSString *key) { return [[o valueForKey:key] doubleValue]; }
static void WPCall(id o, const char *sel) {
    SEL s = sel_registerName(sel);
    if ([o respondsToSelector:s]) ((void (*)(id, SEL))objc_msgSend)(o, s);
}

// Header collapse while the page scrolls (-[WAWeatherCityView scrollViewDidScroll:]): p = contentOffset.y / D (0...1),
// D = how far the pinned today row + hourly strip slide up before the strip parks at pageScrollViewOriginY. The header
// (city, condition, temperature) moves up by p * headerMaximumScrollOffset, the temperature gets alpha
// 1 - p * pageTemperatureFadeMultiplier and the today row (day, high/low) 1 - p * pageDayInfoFadeMultiplier.
// _configureForRegulariPadTwoColumns sets both multipliers to 0, so the 138 pt temperature never faded and the strip slid
// over it (visible while dragging / rubber-banding the page up).
// -> derive them from our header metrics: the strip top starts G = temperatureBaselineToFirstDayBaseline + 17 below the
//    temperature baseline (_layoutPinnedContainer) and closes in on it by (D - H) / D per point scrolled, so they would
//    meet at p = G / (D - H). Finish the fade at ~70% of that, like Apple's iPhone sets (Plus: 2.2 where ~1.5 would just
//    touch); the today row fades 3 / 2.2 as fast as the temperature, also as on iPhone.
static void WPSetHeaderFade(id opts) {
    double H = WPGet(opts, @"headerMaximumScrollOffset");
    double conditionBaseline = WPGet(opts, @"pageCityNameBaselineY") + 21.5;   // 32 pt city name -> 15 pt condition
    double G = WPGet(opts, @"temperatureBaselineToFirstDayBaseline") + 17;
    double stripTop = conditionBaseline + WPGet(opts, @"temperatureBaselineOffset") + G;
    double D = stripTop - MAX(WPGet(opts, @"pageScrollViewOriginY"), conditionBaseline + 6 - H);
    double m = (D > H && G > 0) ? 1.45 * (D - H) / G : 2.2;
    m = MIN(MAX(m, 1), 6);
    WPSet(opts, @"pageTemperatureFadeMultiplier", m);
    WPSet(opts, @"pageDayInfoFadeMultiplier", m * 3 / 2.2);
}

static void WPConfigureForSize(id opts, CGSize size) {
    CGFloat w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    if (w >= 660) {
        WPCall(opts, "_configureForRegulariPadTwoColumns");
        BOOL tall = h >= 900;
        BOOL narrow = w < 900;
        [opts setValue:@(tall ? WPUidTwoColumnTall : (narrow ? WPUidTwoColumnNarrow : WPUidTwoColumnWide)) forKey:@"uid"];
        if (tall) {
            // full-screen portrait: big header, a little lower on the page
            WPSet(opts, @"pageCityNameBaselineY", 130);
            WPSet(opts, @"conditionBaseline", 171);
            WPSet(opts, @"temperatureBaselineOffset", 138);
            WPSet(opts, @"pageScrollViewOriginY", 161);
            WPSet(opts, @"temperatureBaselineToFirstDayBaseline", 100);
        } else {
            WPSet(opts, @"pageCityNameBaselineY", 100);
            WPSet(opts, @"temperatureBaselineOffset", 120);
            WPSet(opts, @"temperatureBaselineToFirstDayBaseline", 80);
        }
        if (narrow) {
            WPSet(opts, @"pageScrollViewInset", 20);
            WPSet(opts, @"verticalDividerLateralPadding", 24);
        }
        WPSetHeaderFade(opts);
    } else if (w <= 360) {
        WPCall(opts, "_configureFor568Height");
        [opts setValue:@(WPUidOneColumnSmall) forKey:@"uid"];
    } else {
        WPCall(opts, "_configureForLargePhoneOneColumn");
        [opts setValue:@(WPUidOneColumnLarge) forKey:@"uid"];
    }
}

// Header snapping: -[WAWeatherCityView scrollViewWillEndDragging:withVelocity:targetContentOffset:] turns any release
// target between 0 and D (underDivider.y - pageScrollView.y, the fully collapsed offset) into D, so like on iPhone a page
// rests either fully open (0) or fully collapsed (D; pulling back down to the top opens it again). iPhone pages are always
// long enough to scroll to D, our pages often are not (two columns at 1024 x 768 / 694 x 768: ~37 pt of scroll for
// D ~200 pt; the Plus set at 438 x 1024: ~54 pt), so UIScrollView clamped the snap target and the page rested part-way,
// with the temperature half faded.
// -> whenever the app sizes the scroll content (-setContentSizeForExtendedWeatherVisible:), give the page scroll view the
//    bottom inset it needs to reach D. Only if the content scrolls at all: the page scroll view does not always bounce, so
//    a page whose content fits (full-screen portrait) stays put, as it would on iPhone. The inset is empty space below the
//    "Today: ..." line and the scroll view ends above the toolbar, so that line stays visible when collapsed.
static void WPFitCollapsedScroll(UIView *cityView) {
    UIScrollView *sv = [cityView valueForKey:@"pageScrollView"];
    UIView *under = [cityView valueForKey:@"underDivider"];
    if (![sv isKindOfClass:[UIScrollView class]] || ![under isKindOfClass:[UIView class]]) return;
    CGFloat collapsed = CGRectGetMinY(under.frame) - CGRectGetMinY(sv.frame);   // D, as the app computes it
    CGFloat overflow = sv.contentSize.height - sv.bounds.size.height;
    CGFloat inset = (overflow > 0.5 && collapsed > overflow) ? ceil(collapsed - overflow) : 0;
    UIEdgeInsets ci = sv.contentInset;
    if (fabs(ci.bottom - inset) < 0.5) return;
    ci.bottom = inset;
    sv.contentInset = ci;
    // e.g. collapsed in landscape, then rotated to portrait where the content fits: don't leave it stuck part-way
    if (sv.tracking || sv.decelerating) return;
    CGFloat maxY = MAX(0, sv.contentSize.height + sv.adjustedContentInset.bottom - sv.bounds.size.height);
    CGFloat y = sv.contentOffset.y;
    if (y > maxY + 0.5) sv.contentOffset = CGPointMake(sv.contentOffset.x, maxY >= collapsed - 0.5 ? maxY : 0);
}

@interface WAContainerViewController : UIViewController
@end

%group WPApp
%hook WAContainerViewController
- (BOOL)isValidPhoneDeviceWithSize:(CGSize)size {
    if (gWPAppHooksActive && WPIsPadIdiom()) return YES;
    return %orig;
}

// The app leaves its window transparent. On iPhone the system shows black behind it; on iPad SpringBoard keeps the
// wallpaper behind app scenes (for Split View / Slide Over), so the city list showed the wallpaper. Use black like iPhone.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIWindow *w = self.view.window;
    if (gWPAppHooksActive && WPIsPadIdiom() && w && CGColorGetAlpha(w.backgroundColor.CGColor) == 0)
        w.backgroundColor = UIColor.blackColor;
}
%end

%hook WAWeatherCityViewLayoutOptions
- (id)initWithViewSize:(CGSize)size traitCollection:(id)tc {
    id me = %orig;
    if (me && gWPAppHooksActive && WPIsPadIdiom()) {
        @try { WPConfigureForSize(me, size); } @catch (NSException *e) { NSLog(@"[WeatherPad] layout options: %@", e); }
    }
    return me;
}
%end

%hook WAWeatherCityView
- (void)setContentSizeForExtendedWeatherVisible:(BOOL)visible {
    %orig;
    if (gWPAppHooksActive && WPIsPadIdiom()) {
        @try { WPFitCollapsedScroll((UIView *)self); } @catch (NSException *e) { NSLog(@"[WeatherPad] collapse inset: %@", e); }
    }
}
%end
%end


#pragma mark - Weather app (animated backgrounds)

// The animated condition backgrounds come from WeatherUI.framework's resources (.caml files). iPadOS 12 has WeatherUI's
// code in the dyld cache but no WeatherUI.framework folder, so they only work once the iPhone resources are installed in
// /System/Library/PrivateFrameworks/WeatherUI.framework (not part of this package). Without them this part does nothing.
//  - -[WUIAsynchronousAssetLoader filenameForCondition:isDay:] builds the name from the screen: on this iPad
//    (_referenceBounds height 1024 > 896) it asks for e.g. "26_day@3x-736h", which no iPhone ships. If that file is
//    missing we use the iPhone XR set ("@2x-896h-n84", the tallest one in the iPhone 5s firmware), then Apple's misspelled
//    "@2x-896-n84" (snow / hail), then "@2x-568m".
//  - WUIWeatherCondition puts the CAML root layer (designed for 414 x 896 pt) in the bottom-left corner of its full-screen
//    layer. 1024 pt is taller/wider than 896, which left an empty band at the top in portrait and on the right in
//    landscape. After WeatherUI lays out we scale its sublayers up from that corner (max side / 896, never below 1), so
//    the animation fills the page. Split View / Slide Over sizes up to 896 pt keep the phone scale.

static NSMutableDictionary *gWPBGNames;

static NSString *WPBGResolve(id loader, NSString *name) {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return name;
    @synchronized ([NSObject class]) {
        if (!gWPBGNames) gWPBGNames = [NSMutableDictionary dictionary];
        NSString *cached = gWPBGNames[name];
        if (cached) return cached;
        NSBundle *bundle = [NSBundle bundleForClass:object_getClass(loader)];
        NSString *result = name;
        if (![bundle URLForResource:name withExtension:@"caml"]) {
            NSRange at = [name rangeOfString:@"@"];
            if (at.location != NSNotFound && at.location > 0) {
                NSString *base = [name substringToIndex:at.location];
                for (NSString *suffix in @[ @"@2x-896h-n84", @"@2x-896-n84", @"@2x-568m" ]) {
                    NSString *candidate = [base stringByAppendingString:suffix];
                    if ([bundle URLForResource:candidate withExtension:@"caml"]) { result = candidate; break; }
                }
            }
        }
        gWPBGNames[name] = result;
        return result;
    }
}

static void WPBGFit(id condition) {
    CALayer *layer = nil;
    @try { layer = [condition valueForKey:@"layer"]; } @catch (NSException *e) { return; }
    if (![layer isKindOfClass:[CALayer class]]) return;
    NSString *file = nil;
    @try { file = [condition valueForKey:@"loadedFileName"]; } @catch (NSException *e) {}
    CGFloat design = 0;
    if ([file isKindOfClass:[NSString class]]) {
        if ([file containsString:@"-896"]) design = 896;
        else if ([file containsString:@"-568m"]) design = 568;
    }
    CGFloat k = layer.transform.m11;                 // WeatherUI draws at pixel size, scaled by 1/screen scale
    if (k <= 0) k = 1;
    CGSize pt = CGSizeMake(layer.bounds.size.width * k, layer.bounds.size.height * k);
    CGFloat s = design > 0 ? MAX(pt.width, pt.height) / design : 1;
    if (!(s > 1.001) || s > 4) s = 1;
    CATransform3D t = CATransform3DMakeScale(s, s, 1);
    if (CATransform3DEqualToTransform(layer.sublayerTransform, t)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.sublayerTransform = t;                     // pivots on the layer's anchor point = bottom-left corner
    [CATransaction commit];
}

%group WPBackgrounds
%hook WUIAsynchronousAssetLoader
- (id)filenameForCondition:(long long)condition isDay:(BOOL)isDay {
    NSString *name = %orig;
    return WPBGResolve(self, name);
}
%end

%hook WUIWeatherCondition
- (void)layoutSublayersOfLayer:(CALayer *)layer {
    %orig;
    if ([NSThread isMainThread]) WPBGFit(self);
}
- (void)setLoadedFileName:(NSString *)name {
    %orig;
    if ([NSThread isMainThread]) WPBGFit(self);
    else { id me = self; dispatch_async(dispatch_get_main_queue(), ^{ WPBGFit(me); }); }
}
%end
%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if ([bid isEqualToString:@"com.apple.springboard"]) {
            if (!objc_getClass("SBApplicationInfo")
                || ![objc_getClass("SBApplicationInfo") instancesRespondToSelector:@selector(supportedTypes)]) {
                NSLog(@"[WeatherPad] SBApplicationInfo not as expected; not hooking SpringBoard");
                return;
            }
            WPPublishState();
            %init(WPSpringBoard);
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, WPSBPrefsChanged,
                CFSTR(kWPNotification), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        } else if ([bid isEqualToString:@"com.apple.weather"]) {
            if (objc_getClass("WAContainerViewController") && objc_getClass("WAWeatherCityViewLayoutOptions")
                && [objc_getClass("WAWeatherCityViewLayoutOptions") instancesRespondToSelector:@selector(initWithViewSize:traitCollection:)]) {
                gWPAppHooksActive = WPAppShouldFixLayout();
                %init(WPApp);
                if (WPIsPadIdiom() && WPAppShouldAnimateBackgrounds()) {
                    Class loader = objc_getClass("WUIAsynchronousAssetLoader"), cond = objc_getClass("WUIWeatherCondition");
                    if (loader && cond && [loader instancesRespondToSelector:@selector(filenameForCondition:isDay:)]
                        && [cond instancesRespondToSelector:@selector(layoutSublayersOfLayer:)]
                        && [cond instancesRespondToSelector:@selector(setLoadedFileName:)]) {
                        %init(WPBackgrounds);
                    } else {
                        NSLog(@"[WeatherPad] WeatherUI classes not as expected; not hooking backgrounds");
                    }
                }
            } else {
                NSLog(@"[WeatherPad] Weather classes not as expected; not hooking the app");
            }
        } else if ([bid isEqualToString:@"com.apple.weather.WeatherAppTodayWidget"]) {
            Class c = objc_getClass("WFURLComponents");
            if (c && [c instancesRespondToSelector:@selector(setDestination:)]) {
                %init(WPWidget);
            } else {
                NSLog(@"[WeatherPad] WFURLComponents -setDestination: not found; not hooking widget");
            }
        }
    }
}
