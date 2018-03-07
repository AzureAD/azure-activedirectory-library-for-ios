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

#import "ADTokenCacheAccessor.h"
#import "ADUserIdentifier.h"
#import "ADTokenCacheKey.h"
#import "ADAuthenticationContext+Internal.h"
#import "ADAuthorityValidation.h"
#import "ADTokenCacheItem+Internal.h"
#import "ADUserInformation.h"
#import "ADTelemetry.h"
#import "MSIDTelemetry+Internal.h"
#import "MSIDTelemetryCacheEvent.h"
#import "MSIDTelemetryEventStrings.h"
#import "ADAuthorityUtils.h"
#import "MSIDAadAuthorityCache.h"
#import "ADHelpers.h"

@implementation ADTokenCacheAccessor

+ (NSString*)familyClientId:(NSString*)familyID
{
    if (!familyID)
    {
        familyID = @"1";
    }
    
    return [NSString stringWithFormat:@"foci-%@", familyID];
}

- (id)initWithDataSource:(id<ADTokenCacheDataSource>)dataSource
               authority:(NSString *)authority
{
    if (!(self = [super init]))
    {
        return nil;
    }
    
    _dataSource = dataSource;
    _authority = authority;
    
    return self;
}

- (id<ADTokenCacheDataSource>)dataSource
{
    return _dataSource;
}

- (ADTokenCacheItem *)getItemForUser:(NSString *)userId
                            resource:(NSString *)resource
                            clientId:(NSString *)clientId
                             context:(id<MSIDRequestContext>)context
                               error:(ADAuthenticationError * __autoreleasing *)error
{
    NSArray<NSURL *> *aliases = [[MSIDAadAuthorityCache sharedInstance] cacheAliasesForAuthority:[NSURL URLWithString:_authority]];
    for (NSURL *alias in aliases)
    {
        ADTokenCacheKey* key = [ADTokenCacheKey keyWithAuthority:[alias absoluteString]
                                                        resource:resource
                                                        clientId:clientId
                                                           error:error];
        if (!key)
        {
            return nil;
        }
        
        ADAuthenticationError *adError = nil;
        ADTokenCacheItem *item = [_dataSource getItemWithKey:key
                                                      userId:userId
                                               correlationId:[context correlationId]
                                                       error:&adError];
        item.storageAuthority = item.authority;
        item.authority = _authority;
        
        if (item)
        {
            return item;
        }
        
        if (adError)
        {
            if (error)
            {
                *error = adError;
            }
            return nil;
        }
    }
    
    return nil;
}

/*!
    Returns a AT/RT Token Cache Item for the given parameters. The RT in this item will only be good
    for the given resource. If no RT is returned in the item then a MRRT or FRT should be used (if
    available).
 */
- (ADTokenCacheItem *)getATRTItemForUser:(ADUserIdentifier *)identifier
                                resource:(NSString *)resource
                                clientId:(NSString *)clientId
                                 context:(id<MSIDRequestContext>)context
                                   error:(ADAuthenticationError * __autoreleasing *)error
{
    [[MSIDTelemetry sharedInstance] startEvent:[context telemetryRequestId] eventName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_LOOKUP];
    
    ADTokenCacheItem* item = [self getItemForUser:identifier.userId resource:resource clientId:clientId context:context error:error];
    MSIDTelemetryCacheEvent* event = [[MSIDTelemetryCacheEvent alloc] initWithName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_LOOKUP
                                                                       context:context];
    [event setTokenType:MSIDTokenTypeAccessToken];
    [event setStatus:item? MSID_TELEMETRY_VALUE_SUCCEEDED : MSID_TELEMETRY_VALUE_FAILED];
    [event setSpeInfo:item.speInfo];
    [[MSIDTelemetry sharedInstance] stopEvent:[context telemetryRequestId] event:event];
    return item;
}

/*!
    Returns a Multi-Resource Refresh Token (MRRT) Cache Item for the given parameters. A MRRT can
    potentially be used for many resources for that given user, client ID and authority.
 */
- (ADTokenCacheItem *)getMRRTItemForUser:(ADUserIdentifier *)identifier
                                clientId:(NSString *)clientId
                                 context:(id<MSIDRequestContext>)context
                                   error:(ADAuthenticationError * __autoreleasing *)error
{
    [[MSIDTelemetry sharedInstance] startEvent:[context telemetryRequestId] eventName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_LOOKUP];
    ADTokenCacheItem* item = [self getItemForUser:identifier.userId resource:nil clientId:clientId context:context error:error];
    MSIDTelemetryCacheEvent* event = [[MSIDTelemetryCacheEvent alloc] initWithName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_LOOKUP
                                                                     requestId:[context telemetryRequestId]
                                                                 correlationId:[context correlationId]];
    [event setTokenType:MSIDTokenTypeRefreshToken];
    [event setMRRTStatus:MSID_TELEMETRY_VALUE_NOT_FOUND];
    if (item)
    {
        [event setIsMRRT:MSID_TELEMETRY_VALUE_YES];
        [event setMRRTStatus:MSID_TELEMETRY_VALUE_TRIED];
    }
    else
    {
        NSDictionary *wipeData = [_dataSource getWipeTokenData];
        
        if (wipeData)
        {
            [event setCacheWipeApp:wipeData[@"bundleId"]];
            [event setCacheWipeTime:[ADHelpers stringFromDate:wipeData[@"wipeTime"]]];
        }
    }
    
    [event setStatus:item? MSID_TELEMETRY_VALUE_SUCCEEDED : MSID_TELEMETRY_VALUE_FAILED];
    [event setSpeInfo:item.speInfo];
    [[MSIDTelemetry sharedInstance] stopEvent:[context telemetryRequestId] event:event];
    return item;
}

/*!
    Returns a Family Refresh Token for the given authority, user and family ID, if available. A FRT can
    be used for many resources within a given family of client IDs.
 */
- (ADTokenCacheItem *)getFRTItemForUser:(ADUserIdentifier *)identifier
                               familyId:(NSString *)familyId
                                context:(id<MSIDRequestContext>)context
                                  error:(ADAuthenticationError * __autoreleasing *)error
{
    [[MSIDTelemetry sharedInstance] startEvent:context.telemetryRequestId eventName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_LOOKUP];
    
    NSString* fociClientId = [ADTokenCacheAccessor familyClientId:familyId];
    ADTokenCacheItem* item = [self getItemForUser:identifier.userId resource:nil clientId:fociClientId context:context error:error];

    MSIDTelemetryCacheEvent* event = [[MSIDTelemetryCacheEvent alloc] initWithName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_LOOKUP
                                                                       context:context];
    [event setTokenType:MSIDTokenTypeRefreshToken];
    [event setFRTStatus:MSID_TELEMETRY_VALUE_NOT_FOUND];
    if (item)
    {
        [event setIsFRT:MSID_TELEMETRY_VALUE_YES];
        [event setFRTStatus:MSID_TELEMETRY_VALUE_TRIED];
    }
    else
    {
        NSDictionary *wipeData = [_dataSource getWipeTokenData];
        
        if (wipeData)
        {
            [event setCacheWipeApp:wipeData[@"bundleId"]];
            [event setCacheWipeTime:[ADHelpers stringFromDate:wipeData[@"wipeTime"]]];
        }
    }
    
    [event setStatus:item? MSID_TELEMETRY_VALUE_SUCCEEDED : MSID_TELEMETRY_VALUE_FAILED];
    [event setSpeInfo:item.speInfo];
    [[MSIDTelemetry sharedInstance] stopEvent:[context telemetryRequestId] event:event];
    return item;
}

- (ADTokenCacheItem*)getADFSUserTokenForResource:(NSString *)resource
                                        clientId:(NSString *)clientId
                                         context:(id<MSIDRequestContext>)context
                                           error:(ADAuthenticationError * __autoreleasing *)error
{
    // ADFS fix: When talking to ADFS directly we can get ATs and RTs (but not MRRTs or FRTs) without
    // id tokens. In those cases we do not know who they belong to and cache them with a blank userId
    // (@"").
    
    ADTokenCacheKey* key = [ADTokenCacheKey keyWithAuthority:_authority
                                                    resource:resource
                                                    clientId:clientId
                                                       error:error];
    if (!key)
    {
        return nil;
    }

    [[MSIDTelemetry sharedInstance] startEvent:[context telemetryRequestId] eventName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_LOOKUP];
    ADTokenCacheItem* item = [_dataSource getItemWithKey:key userId:@"" correlationId:[context correlationId] error:error];
    MSIDTelemetryCacheEvent* event = [[MSIDTelemetryCacheEvent alloc] initWithName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_LOOKUP
                                                                       context:context];
    [event setTokenType:MSIDTokenTypeLegacySingleResourceToken];
    [event setRTStatus:MSID_TELEMETRY_VALUE_NOT_FOUND];
    if ([item refreshToken])
    {
        [event setIsRT:MSID_TELEMETRY_VALUE_YES];
        [event setRTStatus:MSID_TELEMETRY_VALUE_TRIED];
    }
    [event setStatus:item? MSID_TELEMETRY_VALUE_SUCCEEDED : MSID_TELEMETRY_VALUE_FAILED];
    [event setSpeInfo:item.speInfo];
    [[MSIDTelemetry sharedInstance] stopEvent:[context telemetryRequestId] event:event];
    return item;
}


//Stores the result in the cache. cacheItem parameter may be nil, if the result is successfull and contains
//the item to be stored.
- (void)updateCacheToResult:(ADAuthenticationResult *)result
                  cacheItem:(ADTokenCacheItem *)cacheItem
               refreshToken:(NSString *)refreshToken
                    context:(id<MSIDRequestContext>)context
{
    
    if(!result)
    {
        return;
    }
    
    if (AD_SUCCEEDED == result.status)
    {
        ADTokenCacheItem* item = [result tokenCacheItem];
        
        // Validate that this item is a valid item to add.
        if(![ADAuthenticationContext handleNilOrEmptyAsResult:item argumentName:@"tokenCacheItem" authenticationResult:&result]
           || ![ADAuthenticationContext handleNilOrEmptyAsResult:item argumentName:@"resource" authenticationResult:&result]
           || ![ADAuthenticationContext handleNilOrEmptyAsResult:item argumentName:@"accessToken" authenticationResult:&result])
        {
            MSID_LOG_WARN(context, @"Told to update cache to an invalid token cache item.");
            return;
        }
        
        [self updateCacheToItem:item
                           MRRT:[result multiResourceRefreshToken]
                        context:context];
        return;
    }
    
    if (result.error.code != AD_ERROR_SERVER_REFRESH_TOKEN_REJECTED)
    {
        return;
    }
    
    // Only remove tokens from the cache if we get an invalid_grant from the server
    if (![result.error.protocolCode isEqualToString:@"invalid_grant"])
    {
        return;
    }
    
    [self removeItemFromCache:cacheItem
                 refreshToken:refreshToken
                      context:context];
}

- (void)updateCacheToItem:(ADTokenCacheItem *)cacheItem
                     MRRT:(BOOL)isMRRT
                  context:(id<MSIDRequestContext>)context
{
    NSString* telemetryRequestId = [context telemetryRequestId];
    
    NSString* savedRefreshToken = cacheItem.refreshToken;
    if (isMRRT)
    {
        MSID_LOG_VERBOSE(context, @"Token cache store - Storing multi-resource refresh token with authority host: %@", [ADAuthorityUtils isKnownHost:[_authority msidUrl]] ? [_authority msidUrl].host : @"unknown host");
        
        MSID_LOG_VERBOSE_PII(context, @"Token cache store - Storing multi-resource refresh token for authority: %@", _authority);
        
        [[MSIDTelemetry sharedInstance] startEvent:telemetryRequestId eventName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_WRITE];
        
        //If the server returned a multi-resource refresh token, we break
        //the item into two: one with the access token and no refresh token and
        //another one with the broad refresh token and no access token and no resource.
        //This breaking is useful for further updates on the cache and quick lookups
        ADTokenCacheItem* multiRefreshTokenItem = [cacheItem copy];
        cacheItem.refreshToken = nil;
        
        multiRefreshTokenItem.accessToken = nil;
        multiRefreshTokenItem.resource = nil;
        multiRefreshTokenItem.expiresOn = nil;
        [self addOrUpdateItem:multiRefreshTokenItem context:context error:nil];
        MSIDTelemetryCacheEvent* event = [[MSIDTelemetryCacheEvent alloc] initWithName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_WRITE
                                                                           context:context];
        [event setIsMRRT:MSID_TELEMETRY_VALUE_YES];
        [event setTokenType:MSIDTokenTypeRefreshToken];
        [event setSpeInfo:multiRefreshTokenItem.speInfo];
        [[MSIDTelemetry sharedInstance] stopEvent:telemetryRequestId event:event];
        
        // If the item is also a Family Refesh Token (FRT) we update the FRT
        // as well so we have a guaranteed spot to look for the most recent FRT.
        NSString* familyId = cacheItem.familyId;
        if (familyId)
        {
            [[MSIDTelemetry sharedInstance] startEvent:telemetryRequestId eventName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_WRITE];
            
            ADTokenCacheItem* frtItem = [multiRefreshTokenItem copy];
            NSString* fociClientId = [ADTokenCacheAccessor familyClientId:familyId];
            frtItem.clientId = fociClientId;
            [self addOrUpdateItem:frtItem context:context error:nil];
            
            MSIDTelemetryCacheEvent* event = [[MSIDTelemetryCacheEvent alloc] initWithName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_WRITE
                                                                               context:context];
            [event setIsFRT:MSID_TELEMETRY_VALUE_YES];
            [event setTokenType:MSIDTokenTypeRefreshToken];
            [event setSpeInfo:frtItem.speInfo];
            [[MSIDTelemetry sharedInstance] stopEvent:telemetryRequestId event:event];
        }
    }
    
    MSID_LOG_VERBOSE(context, @"Token cache store - Storing access token ");
    MSID_LOG_VERBOSE_PII(context, @"Token cache store - Storing access token for resource: %@", cacheItem.resource);
    
    [[MSIDTelemetry sharedInstance] startEvent:telemetryRequestId eventName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_WRITE];
    [self addOrUpdateItem:cacheItem context:context error:nil];
    cacheItem.refreshToken = savedRefreshToken;//Restore for the result
    MSIDTelemetryCacheEvent* event = [[MSIDTelemetryCacheEvent alloc] initWithName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_WRITE
                                                                       context:context];
    [event setTokenType:MSIDTokenTypeAccessToken];
    [event setSpeInfo:cacheItem.speInfo];
    [[MSIDTelemetry sharedInstance] stopEvent:telemetryRequestId event:event];
}

- (BOOL)addOrUpdateItem:(nonnull ADTokenCacheItem *)item
                context:(id<MSIDRequestContext>)context
                  error:(ADAuthenticationError * __nullable __autoreleasing * __nullable)error
{
    NSURL *oldAuthority = [NSURL URLWithString:item.authority];
    NSURL *newAuthority = [[MSIDAadAuthorityCache sharedInstance] cacheUrlForAuthority:oldAuthority context:context];
    
    // The authority used to retrieve the item over the network can differ from the preferred authority used to
    // cache the item. As it would be awkward to cache an item using an authority other then the one we store
    // it with we switch it out before saving it to cache.
    item.authority = [newAuthority absoluteString];
    BOOL ret = [_dataSource addOrUpdateItem:item correlationId:context.correlationId error:error];
    item.authority = [oldAuthority absoluteString];
    
    return ret;
}

- (void)removeItemFromCache:(ADTokenCacheItem *)cacheItem
               refreshToken:(NSString *)refreshToken
                    context:(id<MSIDRequestContext>)context
{
    if (!cacheItem && !refreshToken)
    {
        return;
    }
    
    
    MSIDTelemetryCacheEvent* event = [[MSIDTelemetryCacheEvent alloc] initWithName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_DELETE
                                                                       context:context];
    [event setSpeInfo:cacheItem.speInfo];
    [[MSIDTelemetry sharedInstance] startEvent:[context telemetryRequestId] eventName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_DELETE];
    [self removeImpl:cacheItem refreshToken:refreshToken context:context];
    [[MSIDTelemetry sharedInstance] stopEvent:[context telemetryRequestId] event:event];
}

- (void)removeImpl:(ADTokenCacheItem *)cacheItem
      refreshToken:(NSString *)refreshToken
           context:(id<MSIDRequestContext>)context
{
    ADTokenCacheKey* cacheKey = [cacheItem extractKey:nil];
    if (!cacheKey)
    {
        return;
    }
    
    NSUUID* correlationId = [context correlationId];
    
    ADTokenCacheItem* existing = [_dataSource getItemWithKey:cacheKey
                                                      userId:cacheItem.userInformation.userId
                                               correlationId:correlationId
                                                       error:nil];
    if (!existing)
    {
        existing = [_dataSource getItemWithKey:[cacheKey mrrtKey]
                                        userId:cacheItem.userInformation.userId
                                 correlationId:correlationId
                                         error:nil];
    }
    
    if (!existing || ![refreshToken isEqualToString:existing.refreshToken])
    {
        return;
    }
    
    [_dataSource removeItem:existing error:nil];
}

@end
