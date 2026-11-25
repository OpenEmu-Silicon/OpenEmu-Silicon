// Copyright (c) 2018, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#import "NSUserDefaults+OpenEmuSDK.h"


@implementation NSUserDefaults (OpenEmuSDK)

static NSString *const OEReleaseAppIdentifier = @"org.openemu.OpenEmu";
static NSString *const OEDebugAppIdentifier = @"org.openemu.OpenEmu.debug";

static BOOL OEIsAppIdentifier(NSString *identifier)
{
    return [identifier isEqual:OEReleaseAppIdentifier] || [identifier isEqual:OEDebugAppIdentifier];
}

+ (NSString *)oe_applicationIdentifierForMainIdentifier:(NSString *)mainIdentifier enclosingAppIdentifier:(NSString *)enclosingIdentifier
{
    if (OEIsAppIdentifier(mainIdentifier))
        return mainIdentifier;
    if (OEIsAppIdentifier(enclosingIdentifier))
        return enclosingIdentifier;
    return OEReleaseAppIdentifier;
}

+ (instancetype)oe_applicationUserDefaults
{
    // The helper has its own identifier but lives in OpenEmu.app/Contents/MacOS, so the app around it says
    // which settings to read: the debug app's own for debug builds, not the release app's.
    // Read the app's Info.plist itself: +[NSBundle bundleWithURL:] hands back the helper's own main bundle here.
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSURL *contentsURL = mainBundle.executableURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSDictionary *enclosingInfo = contentsURL ? [NSDictionary dictionaryWithContentsOfURL:[contentsURL URLByAppendingPathComponent:@"Info.plist"]] : nil;
    NSString *enclosingIdentifier = [enclosingInfo[@"CFBundleIdentifier"] isKindOfClass:[NSString class]] ? enclosingInfo[@"CFBundleIdentifier"] : nil;

    NSString *identifier = [self oe_applicationIdentifierForMainIdentifier:mainBundle.bundleIdentifier
                                                    enclosingAppIdentifier:enclosingIdentifier];
    if ([identifier isEqual:mainBundle.bundleIdentifier])
        return [[self class] standardUserDefaults];
    return [[[self class] alloc] initWithSuiteName:identifier];
}

+ (NSUserDefaults *)oe_application
{
    return [self oe_applicationUserDefaults];
}

@end
