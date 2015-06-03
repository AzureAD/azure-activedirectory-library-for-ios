// Copyright © Microsoft Open Technologies, Inc.
//
// All Rights Reserved
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
// OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
// ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A
// PARTICULAR PURPOSE, MERCHANTABILITY OR NON-INFRINGEMENT.
//
// See the Apache License, Version 2.0 for the specific language
// governing permissions and limitations under the License.

#import <Foundation/Foundation.h>
#import "ADAuthenticationDelegate.h"

extern NSString * const AD_FAILED_NO_CONTROLLER;
extern NSString * const AD_FAILED_NO_RESOURCES;

@interface ADAuthenticationWindowController : NSObject

#if TARGET_OS_IPHONE
- (void)setParentController:(UIViewController*)parentController;
- (void)setFullScreen:(BOOL)fullScreen;
#endif //TARGET_OS_IPHONE

- (ADAuthenticationError*)showWindowWithStartURL:(NSURL*)startURL
                                          endURL:(NSURL*)endURL;
- (void)dismissAnimated:(BOOL)animated
             completion:(void(^)())completion;

- (void)setDelegate:(id<ADAuthenticationDelegate>)delegate;

@end
