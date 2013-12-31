// Created by Boris Vidolov on 12/19/13.
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

#import "ADTestAuthenticationContext.h"
#import "ADALiOS.h"
#import "ADOAuth2Constants.h"

@implementation ADTestAuthenticationContext

-(ADTestAuthenticationContext*) initWithAuthority: (NSString*) authority
                                validateAuthority: (BOOL) validateAuthority
                                  tokenCacheStore: (id<ADTokenCacheStoring>)tokenCache
                                            error: (ADAuthenticationError* __autoreleasing *) error
{
    self = [super initWithAuthority:authority validateAuthority:validateAuthority tokenCacheStore:tokenCache error:error];
    if (self)
    {
        mResponse1 = [NSMutableDictionary new];
        mResponse2 = [NSMutableDictionary new];
        mExpectedRequest1 = [NSMutableDictionary new];
        mExpectedRequest2 = [NSMutableDictionary new];
        mAllowTwoRequests = NO;
        mNumRequests = 0;
    }
    return self;
}

-(NSMutableDictionary*) getExpectedRequest
{
    return (mNumRequests == 1) ? mExpectedRequest1 : mExpectedRequest2;
}

-(NSMutableDictionary*) getResponse
{
    return (mNumRequests == 1) ? mResponse1 : mResponse2;
}



//Override of the parent's request to allow testing of the class behavior.
-(void)request:(NSString *)authorizationServer requestData:(NSDictionary *)request_data completion:( void (^)(NSDictionary *) )completionBlock
{
    ++mNumRequests;
    if (mNumRequests > 2 || (!mAllowTwoRequests && mNumRequests > 1))
    {
        mErrorMessage = @"Too many server requests per single acquireToken.";
    }
    if (!request_data || !request_data.count)
    {
        mErrorMessage = @"Nil or empty request send to the server.";
        completionBlock([self getResponse]);
        return;
    }
    
    //Verify the data sent to the server:
    NSMutableDictionary* expectedRequest = [self getExpectedRequest];
    for(NSString* key in [expectedRequest allKeys])
    {
        NSString* expected = [expectedRequest objectForKey:key];
        NSString* result = [request_data objectForKey:key];
        if (![result isKindOfClass:[NSString class]])
        {
            mErrorMessage = [NSString stringWithFormat:@"Unexpected type for the key (%@): %@", key, result];
            completionBlock([self getResponse]);
            return;
        }
        if (![expected isEqualToString:result])
        {
            mErrorMessage = [NSString stringWithFormat:@"Unexpected value for the key (%@): Expected: '%@'; Actual: '%@'", key, expected, result];
            completionBlock([self getResponse]);
            return;
        }
    }
    
    //If everything is ok, pass over the desired response:
    completionBlock([self getResponse]);
}

@end

