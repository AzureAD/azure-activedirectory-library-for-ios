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

#import <Security/Security.h>
#import "ADALiOS.h"
#import "ADKeychainTokenCacheStore.h"
#import "ADTokenCacheStoreItem.h"
#import "NSString+ADHelperMethods.h"
#import "ADTokenCacheStoreKey.h"
#import "ADUserInformation.h"
#import "ADKeychainQuery.h"

NSString* const sNilKey = @"CC3513A0-0E69-4B4D-97FC-DFB6C91EE132";//A special attribute to write, instead of nil/empty one.
NSString* const sDelimiter = @"|";
NSString* const sKeyChainlog = @"Keychain token cache store";
NSString* const sMultiUserError = @"The token cache store for this resource contain more than one user. Please set the 'userId' parameter to determine which one to be used.";
NSString* const sKeychainSharedGroup = @"com.microsoft.adalcache";

static NSString* const s_kDefaultADALServiceKey = @"MSOpenTech.ADAL";

const long sKeychainVersion = 1;//will need to increase when we break the forward compatibility

static dispatch_queue_t s_keychainQueue = NULL;
static const char * s_keychainQueueLabel = "ADAL.keychain";

static void adkeychain_dispatch_if_needed(dispatch_block_t block)
{
    const char* szLabel = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    if (strcmp(s_keychainQueueLabel, szLabel) == 0)
    {
        block();
    }
    else
    {
        dispatch_sync(s_keychainQueue, block);
    }
}


@implementation ADKeychainTokenCacheStore
{
    NSString* _sharedGroup;
    NSString* _serviceKey;
}

- (id)init
{
    // Shouldn't be called.
    return [self initWithGroup:sKeychainSharedGroup];
}

- (id)initWithGroup:(NSString *)sharedGroup
{
    if (!(self = [super init]))
    {
        return nil;
    }
    
    _sharedGroup = sharedGroup;
    _serviceKey = s_kDefaultADALServiceKey;
    
    return self;
}

+ (void)initialize
{
    // +initialize is called on the first use of this class. Create a concurrent queue to do all keychain operations.
    // While it's still possible (albeit unlikely) that another process could slip in and alter the keychain underneath
    // us while we're running, this will keep the same process from stomping on itself.
    
    s_keychainQueue = dispatch_queue_create(s_keychainQueueLabel, DISPATCH_QUEUE_CONCURRENT);
}

#define CHECK_OSSTATUS(_err) if ([ADKeychainTokenCacheStore handleKeychainCode:_err operation:__PRETTY_FUNCTION__ error:error]) { return; }

+ (BOOL)handleKeychainCode:(OSStatus)errCode
                 operation:(const char*)operation
                     error:(ADAuthenticationError* __autoreleasing *)error
{
    if (error)
    {
        *error = nil;
    }
    
    if (errCode == errSecSuccess)
    {
        NSString* log = [NSString stringWithFormat:@"ADAL Keychain \"%s\" operation succeeded.", operation];
        AD_LOG_INFO(log, nil);
        return NO;
    }
    
    if (errCode == errSecItemNotFound)
    {
        // If we didn't find anything we don't log it as an error as there's usually a number of cases where that's expected
        // and we don't want to send up red herrings.
        NSString* log = [NSString stringWithFormat:@"ADAL Keychain \"%s\" found no matching items.", operation];
        AD_LOG_INFO(log, nil);
        return YES;
    }
    
    NSString* log = [NSString stringWithFormat:@"ADAL Keychain \"%s\" operation failed with error code %d.", operation, (int)errCode];
    // Creating the ADError object will cause the error to get logged.
    ADAuthenticationError* adError = [ADAuthenticationError errorFromKeychainError:errCode errorDetails:log];
    
    if (error)
    {
        *error = adError;
    }
    
    return YES;
}

/*! Log operations that result in storing or reading cache item */
- (void)logItem:(ADTokenCacheStoreItem*)item
        message:(NSString*)additionalMessage
{
    AD_LOG_VERBOSE_F(sKeyChainlog, @"%@. scopes: %@ Access token hash: %@; Refresh token hash: %@", additionalMessage, item.scopes, [ADLogger getHash:item.accessToken], [ADLogger getHash:item.refreshToken]);
}

#pragma mark Keychain Helper Methods

- (ADKeychainQuery*)createBaseQuery
{
    ADKeychainQuery* query = [[ADKeychainQuery alloc] init];
    [query setAccessGroup:_sharedGroup];
    [query setServiceKey:_serviceKey];
    return query;
}

- (OSStatus)copyDictionary:(CFMutableDictionaryRef *)outKeychainItems
                    userId:(NSString*)userId
                     error:(ADAuthenticationError * __autoreleasing *)error
{
    if (!outKeychainItems)
    {
        ADAuthenticationError* adError = [ADAuthenticationError invalidArgumentError:@"outKeychainItems must be provided"];
        if (error)
        {
            *error = adError;
        }
        return errSecParam;
    }
    
    *outKeychainItems = NULL;
    
    ADKeychainQuery* retrieveQuery = [self createBaseQuery];
    [retrieveQuery setUserId:userId];
    [retrieveQuery setCopyData];
    
    CFTypeRef data = NULL;
    OSStatus err = SecItemCopyMatching([retrieveQuery queryDictionary], &data);
    if (err != errSecSuccess)
    {
        return err;
    }
    
    CFErrorRef cfError = NULL;
    // If this keychain entry is bad, we might as well zap the whole thing, rather then let the user get stuck in a bad, unrecoverable state
    CFMutableDictionaryRef cfmdKeychainItem = (CFMutableDictionaryRef)CFPropertyListCreateWithData(NULL, (CFDataRef)data, kCFPropertyListMutableContainers, NULL, &cfError);
    if (!cfmdKeychainItem)
    {
        ADAuthenticationError* adError = [ADAuthenticationError errorFromNSError:(__bridge NSError*)cfError
                                                                    errorDetails:@"failure deserializing data from keychain."];
        if (error)
        {
            *error = adError;
        }
        
        return errSecDecode;
    }
    
    *outKeychainItems = cfmdKeychainItem;
    return errSecSuccess;
}
- (OSStatus)writeDictionary:(CFDictionaryRef)dictionary
                 userId:(NSString*)userId
{
    
    CFErrorRef cfError = NULL;
    
    if (!dictionary)
    {
        return errSecParam;
    }
    
    CFDataRef data = CFPropertyListCreateData(NULL, dictionary, kCFPropertyListBinaryFormat_v1_0, 0, &cfError);
    if (!data)
    {
        return errSecAllocate;
    }
    
    ADKeychainQuery* writeQuery = [self createBaseQuery];
    [writeQuery setUserId:userId];
    
    const void * keys[] = { kSecAttrGeneric };
    const void * values[] = { data };
    
    // Create an attributes dictionary for the generic data on the specified item
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(data);
    if (!attributes)
    {
        return errSecAllocate;
    }
    
    // Write it out ot keychain
    OSStatus err = SecItemUpdate([writeQuery queryDictionary], attributes);
    
    CFRelease(attributes);
    
    return err;
}

- (void)removeAllForUser:(NSString*)userId
                   error:(ADAuthenticationError* __autoreleasing*)error
{
    adkeychain_dispatch_if_needed(^{
        ADKeychainQuery* keychainQuery = [self createBaseQuery];
        [keychainQuery setUserId:userId];
        OSStatus err = SecItemDelete([keychainQuery queryDictionary]);
        CHECK_OSSTATUS(err);
    });
}



#pragma mark ADTokenCacheStoring methods

- (NSArray*)allItems:(ADAuthenticationError *__autoreleasing *)error
{
    __block NSArray* returnItems = nil;
    
    adkeychain_dispatch_if_needed(^{
        ADKeychainQuery* query = [self createBaseQuery];
        [query setCopyAttributes];
        [query setMatchAll];
        
        CFArrayRef cfaItems = NULL;
        OSStatus err = SecItemCopyMatching([query queryDictionary], (CFTypeRef*)&cfaItems);
        CHECK_OSSTATUS(err);
        
        NSMutableArray* cacheItems = [NSMutableArray new];
        
        for (NSDictionary* attrs in (__bridge NSArray*)cfaItems)
        {
            if (![attrs isKindOfClass:[NSDictionary class]])
            {
                continue;
            }
            
            NSString* account = [attrs objectForKey:(__bridge id)(kSecAttrAccount)];
            if (account && ![account isKindOfClass:[NSString class]])
            {
                continue;
            }
            
            AD_LOG_INFO_F(@"Found account in keychain", @"account: %@", account);
            
            CFMutableDictionaryRef keychainItems = NULL;
            OSStatus err = [self copyDictionary:&keychainItems
                                         userId:account
                                          error:error];
            if (err != errSecSuccess)
            {
                return;
            }
            
            [(__bridge NSDictionary*)keychainItems enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop)
            {
                NSData* itemData = (NSData*)obj;
                ADTokenCacheStoreItem* cacheItem = [ADTokenCacheStoreItem itemFromData:itemData];
                if (!cacheItem)
                {
                    return;
                }
            }];
            CFRelease(keychainItems);
        }
        
        CFRelease(cfaItems);
        
        returnItems = cacheItems;
    });
    
    if ([returnItems count] == 0)
    {
        AD_LOG_INFO(@"No accounts found in keychain.", nil);
    }
    
    return returnItems;
}

- (ADTokenCacheStoreItem*)getItemWithKey:(ADTokenCacheStoreKey*)key
                                   error:(ADAuthenticationError *__autoreleasing *)error
{
    API_ENTRY;
    
    __block ADTokenCacheStoreItem* item = nil;
    
    adkeychain_dispatch_if_needed(^{
        CFMutableDictionaryRef cfmdKeychainItems = NULL;
        OSStatus err = [self copyDictionary:&cfmdKeychainItems
                                userId:[key userCacheKey]
                                 error:error];
        
        if (err != errSecSuccess)
        {
            return;
        }
        
        CFDataRef data = CFDictionaryGetValue(cfmdKeychainItems, (__bridge const void *)([key key]));
        if (!data)
        {
            return;
        }
        
        item = [ADTokenCacheStoreItem itemFromData:(__bridge NSData *)(data)];
    });
    
    
    return item;
}

/*!
 Extracts the key from the item and uses it to set the cache details. If another item with the
 same key exists, it will be overriden by the new one. 'getItemWithKey' method can be used to determine
 if an item already exists for the same key.
 
 @param error    in case of an error, if this parameter is not nil, it will be filled with
 the error details.
 */
- (void)addOrUpdateItem:(ADTokenCacheStoreItem*)item
                  error:(ADAuthenticationError* __autoreleasing*)error
{
    ADTokenCacheStoreKey* key = [item extractKeyWithError:error];
    if (!key)
    {
        return;
    }
    
    adkeychain_dispatch_if_needed(^{
        CFMutableDictionaryRef cfmdKeychainDict = NULL;
        OSStatus err = [self copyDictionary:&cfmdKeychainDict
                                     userId:[item userCacheKey]
                                      error:error];
        
        if (err == errSecItemNotFound)
        {
            cfmdKeychainDict = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        }
        else if (err != errSecSuccess)
        {
            return;
        }
        
        CFDictionarySetValue(cfmdKeychainDict, (__bridge const void *)([key key]), (__bridge const void *)([item copyDataForItem]));
    });
}

- (void)removeItemWithKey:(ADTokenCacheStoreKey*)key
                    error:(ADAuthenticationError* __autoreleasing* )error
{
    API_ENTRY;
    
    if (!key)
    {
        ADAuthenticationError* adError = [ADAuthenticationError invalidArgumentError:@"removeItemWithKey requires a key to be specified."];
        if (error)
        {
            *error = adError;
        }
        return;
    }
    
    adkeychain_dispatch_if_needed(^{
        CFMutableDictionaryRef cfmdKeychainItem = NULL;
        OSStatus err = [self copyDictionary:&cfmdKeychainItem
                                userId:[key userCacheKey]
                                 error:error];
        if (err == errSecDecode)
        {
            [self removeAllForUser:[key userCacheKey]
                             error:nil];
        }
        CHECK_OSSTATUS(err);
        
        // If the item we're looking for isn't even in the dictionary then we're already done.
        if (!CFDictionaryContainsKey(cfmdKeychainItem, (__bridge const void *)([key key])))
        {
            CFRelease(cfmdKeychainItem);
            return;
        }
        
        // Remove the item from the dictionary
        CFDictionaryRemoveValue(cfmdKeychainItem, (__bridge const void *)([key key]));
        
        // And write it back out to keychain
        [self writeDictionary:cfmdKeychainItem userId:[key userCacheKey]];
    });
}

- (void)removeAll:(ADAuthenticationError *__autoreleasing *)error
{
    adkeychain_dispatch_if_needed(^{
        ADKeychainQuery* keychainQuery = [self createBaseQuery];
        OSStatus err = SecItemDelete([keychainQuery queryDictionary]);
        CHECK_OSSTATUS(err);
    });
}

@end
