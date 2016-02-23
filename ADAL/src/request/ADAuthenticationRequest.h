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


#import <Foundation/Foundation.h>
#import "ADAuthenticationContext.h"

@class ADUserIdentifier;

#define AD_REQUEST_CHECK_ARGUMENT(_arg) { \
    if (!_arg || ([_arg isKindOfClass:[NSString class]] && [(NSString*)_arg isEqualToString:@""])) { \
        NSString* _details = @#_arg " must not be nil!"; \
        completionBlock([ADAuthenticationResult resultFromParameterError:_details]); \
        return; \
    } \
}

#define AD_REQUEST_CHECK_PROPERTY(_property) { \
    if (!_property || ([_property isKindOfClass:[NSString class]] && [(NSString*)_property isEqualToString:@""])) { \
        NSString* _details = @#_property " must not be nil!";\
        completionBlock([ADAuthenticationResult resultFromParameterError:_details]); \
        return; \
    } \
}

@interface ADAuthenticationRequest : NSObject
{
@protected
    ADAuthenticationContext* _context;
    NSString* _clientId;
    NSString* _redirectUri;
    
    ADUserIdentifier* _identifier;
    
    ADPromptBehavior _promptBehavior;
    
    NSString* _resource;
    
    NSString* _scope;
    NSString* _queryParams;
    
    NSString* _refreshTokenCredential;
    
    BOOL _silent;
    BOOL _allowSilent;
    
    NSUUID* _correlationId;
    NSString* _component;
    
    BOOL _requestStarted;
}

@property (retain) NSString* component;

// The default constructor. All of the parameters are mandatory
+ (ADAuthenticationRequest*)requestWithContext:(ADAuthenticationContext*)context
                                   redirectUri:(NSString*)redirectUri
                                      clientId:(NSString*)clientId
                                      resource:(NSString*)resource
                                         error:(ADAuthenticationError* __autoreleasing *)error;

// This message is sent before any stage of processing is done, it marks all the fields as un-editable and grabs the
// correlation ID from the logger
- (void)ensureRequest;

// These can only be set before the request gets sent out.
- (void)setScope:(NSString*)scope;
- (void)setExtraQueryParameters:(NSString*)queryParams;
- (void)setUserIdentifier:(ADUserIdentifier*)identifier;
- (void)setUserId:(NSString*)userId;
- (void)setPromptBehavior:(ADPromptBehavior)promptBehavior;
- (void)setSilent:(BOOL)silent;
- (void)setCorrelationId:(NSUUID*)correlationId;
- (NSUUID*)correlationId;
#if AD_BROKER
- (NSString*)redirectUri;
- (void)setRedirectUri:(NSString*)redirectUri;
- (void)setAllowSilentRequests:(BOOL)allowSilent;
- (void)setRefreshTokenCredential:(NSString*)refreshTokenCredential;
#endif

@end

#import "ADAuthenticationRequest+AcquireAssertion.h"
#import "ADAuthenticationRequest+AcquireToken.h"
#import "ADAuthenticationRequest+Broker.h"
#import "ADAuthenticationRequest+WebRequest.h"
