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

#import "ADAuthenticationContext+Internal.h"
#import "ADOAuth2Constants.h"
#import "ADHelpers.h"
#import "ADUserIdentifier.h"
#import "ADTokenCacheStoreItem+Internal.h"

@implementation ADAuthenticationContext (TokenCaching)

//Gets an item from the cache, where userId may be nil. Raises error, if items for multiple users
//are present and user id is not specified.
- (ADTokenCacheStoreItem*)extractCacheItemWithKey:(ADTokenCacheStoreKey*)key
                                           userId:(ADUserIdentifier*)userId
                                            error:(ADAuthenticationError* __autoreleasing*)error
{
    if (!key || !self.tokenCacheStore)
    {
        return nil;//Nothing to return
    }
    
    ADAuthenticationError* localError;
    ADTokenCacheStoreItem* item = [self.tokenCacheStore getItemWithKey:key userId:userId.userId error:&localError];
    if (!item && !localError && userId)
    {//ADFS fix, where the userId is not received by the server, but can be passed to the API:
        //We didn't find element with the userId, try finding an item with nil userId:
        NSArray* items = [self.tokenCacheStore getItemsWithKey:key error:&localError];
        if(items.count) {
            item = items.firstObject;
        }else{
            item = nil;
        }
        
        if (item && item.userInformation)
        {
            item = nil;//Different user id, just clear.
        }
    }
    if (error && localError)
    {
        *error = localError;
    }
    return item;
}

//Checks the cache for item that can be used to get directly or indirectly an access token.
//Checks the multi-resource refresh tokens too.
- (ADTokenCacheStoreItem*)findCacheItemWithKey:(ADTokenCacheStoreKey*) key
                                        userId:(ADUserIdentifier*)userId
                                useAccessToken:(BOOL*) useAccessToken
                          requestCorrelationId:(NSUUID*) requestCorrelationId
                                         error:(ADAuthenticationError* __autoreleasing*) error
{
    if (!key || !self.tokenCacheStore)
    {
        return nil;//Nothing to return
    }
    ADAuthenticationError* localError;
    ADTokenCacheStoreItem* item = [self extractCacheItemWithKey:key userId:userId error:&localError];
    if (localError)
    {
        if (error)
        {
            *error = localError;
        }
        return nil;//Quick return if an error was detected.
    }
    
    if (item)
    {
        *useAccessToken = item.accessToken && !item.isExpired;
        if (*useAccessToken)
        {
            return item;
        }
        else if (![NSString adIsStringNilOrBlank:item.refreshToken])
        {
            return item;//Suitable direct refresh token found.
        }
        else
        {
            //We have a cache item that cannot be used anymore, mark it as dead in the cache:
            [self.tokenCacheStore tombstoneItem:item requestCorrelationId:[requestCorrelationId UUIDString] error:nil];
        }
    }
    *useAccessToken = false;//No item with suitable access token exists
    
    if (![NSString adIsStringNilOrBlank:key.resource])
    {
        //The request came for specific resource. Try returning a multi-resource refresh token:
        ADTokenCacheStoreKey* broadKey = [ADTokenCacheStoreKey keyWithAuthority:self.authority
                                                                       resource:nil
                                                                       clientId:key.clientId
                                                                          error:&localError];
        if (!broadKey)
        {
            AD_LOG_WARN(@"Unexpected error", [self correlationId], localError.errorDetails);
            return nil;//Recover
        }
        ADTokenCacheStoreItem* broadItem = [self extractCacheItemWithKey:broadKey userId:userId error:&localError];
        if (localError)
        {
            if (error)
            {
                *error = localError;
            }
            return nil;
        }
        return broadItem;
    }
    return nil;//Nothing suitable
}

//Stores the result in the cache. cacheItem parameter may be nil, if the result is successfull and contains
//the item to be stored.
- (void)updateCacheToResult:(ADAuthenticationResult*)result
                  cacheItem:(ADTokenCacheStoreItem*)cacheItem
           withRefreshToken:(NSString*)refreshToken
       requestCorrelationId:(NSUUID*)requestCorrelationId
{
    [self updateCacheToResult:result
                cacheInstance:self.tokenCacheStore
                    cacheItem:cacheItem
             withRefreshToken:refreshToken
         requestCorrelationId:requestCorrelationId];
}

- (void)updateCacheToResult:(ADAuthenticationResult*)result
              cacheInstance:(id<ADTokenCacheStoring>)tokenCacheStoreInstance
                  cacheItem:(ADTokenCacheStoreItem*)cacheItem
           withRefreshToken:(NSString*)refreshToken
       requestCorrelationId:(NSUUID*)requestCorrelationId
{
    if(![ADAuthenticationContext handleNilOrEmptyAsResult:result argumentName:@"result" authenticationResult:&result]){
        return;
    }
    
    if (!tokenCacheStoreInstance)
        return;//No cache to update
    
    if (AD_SUCCEEDED == result.status)
    {
        if(![ADAuthenticationContext handleNilOrEmptyAsResult:result.tokenCacheStoreItem argumentName:@"tokenCacheStoreItem" authenticationResult:&result]
           || ![ADAuthenticationContext handleNilOrEmptyAsResult:result.tokenCacheStoreItem.resource argumentName:@"resource" authenticationResult:&result]
           || ![ADAuthenticationContext handleNilOrEmptyAsResult:result.tokenCacheStoreItem.accessToken argumentName:@"accessToken" authenticationResult:&result])
        {
            return;
        }
        
        //In case of success we use explicitly the item that comes back in the result:
        cacheItem = result.tokenCacheStoreItem;
        NSString* savedRefreshToken = cacheItem.refreshToken;
        if (result.multiResourceRefreshToken)
        {
            AD_LOG_VERBOSE_F(@"Token cache store", [self correlationId], @"Storing multi-resource refresh token for authority: %@", self.authority);
            
            //If the server returned a multi-resource refresh token, we break
            //the item into two: one with the access token and no refresh token and
            //another one with the broad refresh token and no access token and no resource.
            //This breaking is useful for further updates on the cache and quick lookups
            ADTokenCacheStoreItem* multiRefreshTokenItem = [cacheItem copy];
            cacheItem.refreshToken = nil;
            
            multiRefreshTokenItem.accessToken = nil;
            multiRefreshTokenItem.resource = nil;
            multiRefreshTokenItem.expiresOn = nil;
            [tokenCacheStoreInstance addOrUpdateItem:multiRefreshTokenItem error:nil];
        }
        
        AD_LOG_VERBOSE_F(@"Token cache store", [self correlationId], @"Storing access token for resource: %@", cacheItem.resource);
        [tokenCacheStoreInstance addOrUpdateItem:cacheItem error:nil];
        cacheItem.refreshToken = savedRefreshToken;//Restore for the result
    }
    else
    {
        if (AD_ERROR_INVALID_REFRESH_TOKEN == result.error.code)
        {//Bad refresh token. Remove it from the cache:
            if(![ADAuthenticationContext handleNilOrEmptyAsResult:cacheItem argumentName:@"cacheItem" authenticationResult:&result]
               || ![ADAuthenticationContext handleNilOrEmptyAsResult:cacheItem.resource argumentName:@"cacheItem.resource" authenticationResult:&result]
               || ![ADAuthenticationContext handleNilOrEmptyAsResult:refreshToken argumentName:@"refreshToken" authenticationResult:&result])
            {
                return;
            }
            
            BOOL removed = NO;
            //The refresh token didn't work. We need to mark this refresh item as dead in the cache.
            ADTokenCacheStoreKey* exactKey = [cacheItem extractKey:nil];
            if (exactKey)
            {
                ADTokenCacheStoreItem* existing = [tokenCacheStoreInstance getItemWithKey:exactKey userId:cacheItem.userInformation.userId error:nil];
                if ([refreshToken isEqualToString:existing.refreshToken])//If still there, attempt to remove
                {
                    AD_LOG_VERBOSE_F(@"Token cache store", [self correlationId], @"Tombstoning cache for resource: %@", cacheItem.resource);
                    [tokenCacheStoreInstance tombstoneItem:cacheItem requestCorrelationId:[requestCorrelationId UUIDString] error:nil];
                    removed = YES;
                }
            }
            
            if (!removed)
            {
                //Now try finding a broad refresh token in the cache and remove it accordingly
                ADTokenCacheStoreKey* broadKey = [ADTokenCacheStoreKey keyWithAuthority:self.authority resource:nil clientId:cacheItem.clientId error:nil];
                if (broadKey)
                {
                    ADTokenCacheStoreItem* broadItem = [tokenCacheStoreInstance getItemWithKey:broadKey userId:cacheItem.userInformation.userId error:nil];
                    if (broadItem && [refreshToken isEqualToString:broadItem.refreshToken])//Remove if still there
                    {
                        AD_LOG_VERBOSE_F(@"Token cache store", [self correlationId], @"Tombstoning multi-resource refresh token for authority: %@", self.authority);
                        [tokenCacheStoreInstance tombstoneItem:broadItem requestCorrelationId:[requestCorrelationId UUIDString] error:nil];
                    }
                }
            }
        }
    }
}

@end
