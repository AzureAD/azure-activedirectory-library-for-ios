// Copyright (c) Microsoft Corporation.
// All rights reserved.
//
// This code is licensed under the MIT License.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import <objc/runtime.h>

#import "NSDictionary+ADExtensions.h"

#import "ADBrokerHelper.h"
#import "ADBrokerNotificationManager.h"
#import "ADOAuth2Constants.h"
#import "ADWebAuthController+Internal.h"

typedef BOOL (*applicationOpenURLPtr)(id, SEL, UIApplication*, NSURL*, NSString*, id);
IMP __original_ApplicationOpenURL = NULL;

BOOL __swizzle_ApplicationOpenURL(id self, SEL _cmd, UIApplication* application, NSURL* url, NSString* sourceApplication, id annotation)
{
    if (![ADAuthenticationContext isResponseFromBroker:sourceApplication response:url])
    {
        if (__original_ApplicationOpenURL)
            return ((applicationOpenURLPtr)__original_ApplicationOpenURL)(self, _cmd, application, url, sourceApplication, annotation);
        else
            return NO;
    }
    
    [ADAuthenticationContext handleBrokerResponse:url];
    return YES;
}

@implementation ADBrokerHelper

+ (void)load
{
    __block id observer = nil;
    
    observer =
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification* notification)
     {
         (void)notification;
         // We don't want to swizzle multiple times so remove the observer
         [[NSNotificationCenter defaultCenter] removeObserver:observer name:UIApplicationDidFinishLaunchingNotification object:nil];
         
         SEL sel = @selector(application:openURL:sourceApplication:annotation:);
         
         // Dig out the app delegate (if there is one)
         __strong id appDelegate = [[UIApplication sharedApplication] delegate];
         
         // There's not much we can do if there's no app delegate and there might be scenarios where
         // that is valid...
         if (appDelegate == nil)
             return;
         
         if ([appDelegate respondsToSelector:sel])
         {
             Method m = class_getInstanceMethod([appDelegate class], sel);
             __original_ApplicationOpenURL = method_getImplementation(m);
             method_setImplementation(m, (IMP)__swizzle_ApplicationOpenURL);
         }
         else
         {
             NSString* typeEncoding = [NSString stringWithFormat:@"%s%s%s%s%s%s%s", @encode(BOOL), @encode(id), @encode(SEL), @encode(UIApplication*), @encode(NSURL*), @encode(NSString*), @encode(id)];
             class_addMethod([appDelegate class], sel, (IMP)__swizzle_ApplicationOpenURL, [typeEncoding UTF8String]);
             
             // UIApplication caches whether or not the delegate responds to certain selectors. Clearing out the delegate and resetting it gaurantees that gets updated
             [[UIApplication sharedApplication] setDelegate:nil];
             // UIApplication employs dark magic to assume ownership of the app delegate when it gets the app delegate at launch, it won't do that for setDelegate calls so we
             // have to add a retain here to make sure it doesn't turn into a zombie
             [[UIApplication sharedApplication] setDelegate:(__bridge id)CFRetain((__bridge CFTypeRef)appDelegate)];
         }
         
     }];
}

+ (BOOL)canUseBroker
{
    return [[UIApplication sharedApplication] canOpenURL:[[NSURL alloc] initWithString:[NSString stringWithFormat:@"%@://broker", ADAL_BROKER_SCHEME]]];
}

+ (void)invokeBroker:(NSDictionary *)brokerParams
   completionHandler:(ADAuthenticationCallback)completion
{
    NSString* query = [brokerParams adURLFormEncode];
    
    NSURL* appUrl = [[NSURL alloc] initWithString:[NSString stringWithFormat:@"%@://broker?%@", ADAL_BROKER_SCHEME, query]];
    
    [[ADBrokerNotificationManager sharedInstance] enableNotifications:completion];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ADWebAuthWillSwitchToBrokerApp object:nil];
        
        [[UIApplication sharedApplication] openURL:appUrl];
    });
}

+ (void)saveToPasteBoard:(NSURL*) url
{
    UIPasteboard *appPasteBoard = [UIPasteboard pasteboardWithName:@"WPJ"
                                                            create:YES];
    appPasteBoard.persistent = YES;
    url = [NSURL URLWithString:[NSString stringWithFormat:@"%@&%@=%@", url.absoluteString, @"sourceApplication",[[NSBundle mainBundle] bundleIdentifier]]];
    [appPasteBoard setURL:url];
}

+ (void)promptBrokerInstall:(NSDictionary *)brokerParams
          completionHandler:(ADAuthenticationCallback)completion
{
    NSString* query = [brokerParams adURLFormEncode];
    
    NSURL* appUrl = [[NSURL alloc] initWithString:[NSString stringWithFormat:@"%@://broker?%@", ADAL_BROKER_SCHEME, query]];
    
    [[ADBrokerNotificationManager sharedInstance] enableNotifications:completion];
    
    //no broker installed. go to app store
    NSString* qp = [appUrl query];
    NSDictionary* qpDict = [NSDictionary adURLFormDecode:qp];
    NSString* url = [qpDict valueForKey:@"app_link"];
    [self saveToPasteBoard:appUrl];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] openURL:[[NSURL alloc] initWithString:url]];
    });
}

+ (ADAuthenticationCallback)copyAndClearCompletionBlock
{
    return [[ADBrokerNotificationManager sharedInstance] copyAndClearCallback];
}

@end
