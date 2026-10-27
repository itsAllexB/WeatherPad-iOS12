// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>

@interface WPRootListController : PSListController
@end

@implementation WPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// Relaunch SpringBoard the same way Settings > General > Reset does (no reboot).
- (void)respring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring?"
        message:@"SpringBoard will restart and open apps will close." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        Class actionClass = objc_getClass("SBSRelaunchAction");
        Class serviceClass = objc_getClass("FBSSystemService");
        if (!actionClass || !serviceClass) return;
        id action = ((id (*)(id, SEL, id, unsigned long long, id))objc_msgSend)(actionClass,
            sel_registerName("actionWithReason:options:targetURL:"), @"WeatherPad", 4 /* fade to black */, nil);
        id service = ((id (*)(id, SEL))objc_msgSend)(serviceClass, sel_registerName("sharedService"));
        ((void (*)(id, SEL, id, id))objc_msgSend)(service, sel_registerName("sendActions:withResult:"), [NSSet setWithObject:action], nil);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
