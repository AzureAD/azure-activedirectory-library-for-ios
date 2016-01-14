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

#import "ADAL.h"
#import "ADTokenCacheStoreItem+Internal.h"
#import "ADAuthenticationError.h"
#import "ADOAuth2Constants.h"
#import "ADUserInformation.h"
#import "ADLogger+Internal.h"
#import "NSString+ADHelperMethods.h"
#import "ADAuthenticationContext+Internal.h"

@implementation ADTokenCacheStoreItem (Internal)

#define CHECK_ERROR(_CHECK, _ERR) { if (_CHECK) { if (error) {*error = _ERR;} return; } }

- (void)checkCorrelationId:(NSDictionary*)response
      requestCorrelationId:(NSUUID*)requestCorrelationId
{
    AD_LOG_VERBOSE(@"Token extraction", requestCorrelationId, @"Attempt to extract the data from the server response.");
    
    NSString* responseId = [response objectForKey:OAUTH2_CORRELATION_ID_RESPONSE];
    NSUUID* responseUUID;
    if (![NSString adIsStringNilOrBlank:responseId])
    {
        responseUUID = [[NSUUID alloc] initWithUUIDString:responseId];
        if (!responseUUID)
        {
            AD_LOG_INFO_F(@"Bad correlation id", nil, @"The received correlation id is not a valid UUID. Sent: %@; Received: %@", requestCorrelationId, responseId);
        }
        else if (![requestCorrelationId isEqual:responseUUID])
        {
            AD_LOG_INFO_F(@"Correlation id mismatch", nil, @"Mismatch between the sent correlation id and the received one. Sent: %@; Received: %@", requestCorrelationId, responseId);
        }
    }
    else
    {
        AD_LOG_INFO_F(@"Missing correlation id", nil, @"No correlation id received for request with correlation id: %@", [requestCorrelationId UUIDString]);
    }
}

- (ADAuthenticationResult *)processTokenResponse:(NSDictionary *)response
                                     fromRefresh:(BOOL)fromRefreshTokenWorkflow
                            requestCorrelationId:(NSUUID*)requestCorrelationId
{
    return [self processTokenResponse:response
                          fromRefresh:fromRefreshTokenWorkflow
                 requestCorrelationId:requestCorrelationId
                         fieldToCheck:OAUTH2_ACCESS_TOKEN];
}

- (ADAuthenticationResult *)processTokenResponse:(NSDictionary *)response
                                     fromRefresh:(BOOL)fromRefreshTokenWorkflow
                            requestCorrelationId:(NSUUID*)requestCorrelationId
                                    fieldToCheck:(NSString*)fieldToCheck
{
    if (!response)
    {
        ADAuthenticationError* error = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_CACHE_PERSISTENCE
                                                                              protocolCode:@"adal cachce"
                                                                              errorDetails:@"processTokenResponse called without a response dictionary"];
        return [ADAuthenticationResult resultFromError:error];
    }
    
    [self checkCorrelationId:response requestCorrelationId:requestCorrelationId];
    
    ADAuthenticationError* error = [ADAuthenticationContext errorFromDictionary:response errorCode:(fromRefreshTokenWorkflow) ? AD_ERROR_INVALID_REFRESH_TOKEN : AD_ERROR_AUTHENTICATION];
    if (error)
    {
        return [ADAuthenticationResult resultFromError:error];
    }
    
    NSString* value = [response objectForKey:fieldToCheck];
    if (![NSString adIsStringNilOrBlank:value])
    {
        BOOL isMrrt = [self fillItemWithResponse:response];
        return [ADAuthenticationResult resultFromTokenCacheStoreItem:self
                                           multiResourceRefreshToken:isMrrt
                                                       correlationId:[response objectForKey:OAUTH2_CORRELATION_ID_RESPONSE]];
    }
    else
    {
        // Bad item, the field we're looking for is missing.
        NSString* details = [NSString stringWithFormat:@"Authentication response received without expected \"%@\"", fieldToCheck];
        ADAuthenticationError* error = [ADAuthenticationError unexpectedInternalError:details];
        return [ADAuthenticationResult resultFromError:error];
    }
    
    //No access token and no error, we assume that there was another kind of error (connection, server down, etc.).
    //Note that for security reasons we log only the keys, not the values returned by the user:
    NSString* errorMessage = [NSString stringWithFormat:@"The server returned without providing an error. Keys returned: %@", [response allKeys]];
    error = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_AUTHENTICATION
                                                   protocolCode:nil
                                                   errorDetails:errorMessage];
    return [ADAuthenticationResult resultFromError:error];
}

- (void)fillUserInformation:(NSString*)idToken
{
    if (!idToken)
    {
        // If there's no id token we still continue onwards
        return;
    }
    
    ADUserInformation* info = nil;
    info = [ADUserInformation userInformationWithIdToken:idToken
                                                   error:nil];
    
    self.userInformation = info;
}

- (void)fillExpiration:(NSDictionary*)responseDictionary
{
    id expires_in = [responseDictionary objectForKey:@"expires_in"];
    id expires_on = [responseDictionary objectForKey:@"expires_on"];
    
    
    NSDate *expires    = nil;
    
    if (expires_in && [expires_in respondsToSelector:@selector(doubleValue)])
    {
        expires = [NSDate dateWithTimeIntervalSinceNow:[expires_in doubleValue]];
    }
    else if (expires_on && [expires_on respondsToSelector:@selector(doubleValue)])
    {
        expires = [NSDate dateWithTimeIntervalSince1970:[expires_on doubleValue]];
    }
    else if (expires_in || expires_on)
    {
        AD_LOG_WARN_F(@"Unparsable time", nil, @"The response value for the access token expiration cannot be parsed: %@", expires);
    }
    else
    {
        AD_LOG_WARN(@"Missing expiration time.", nil, @"The server did not return the expiration time for the access token.");
    }
    
    if (!expires)
    {
        expires = [NSDate dateWithTimeIntervalSinceNow:3600.0]; //Assume 1hr expiration
    }
    self.expiresOn = expires;
}

- (void)logWithCorrelationId:(NSString*)correlationId
                        mrrt:(BOOL)isMRRT
{
    NSUUID* correlationUUID = [[NSUUID alloc] initWithUUIDString:correlationId];
    if (self.accessToken)
    {
        [ADLogger logToken:self.accessToken
                 tokenType:self.accessTokenType
                 expiresOn:self.expiresOn
             correlationId:correlationUUID];
    }
    
    if (self.refreshToken)
    {
        [ADLogger logToken:self.refreshToken
                 tokenType:isMRRT ? @"multi-resource refresh token" : @"refresh token"
                 expiresOn:nil
             correlationId:correlationUUID];
    }
}


#define FILL_FIELD(_FIELD, _KEY) { id _val = [responseDictionary valueForKey:_KEY]; if (_val) { self._FIELD = _val; } }

- (BOOL)fillItemWithResponse:(NSDictionary*)responseDictionary
{
    if (!responseDictionary)
    {
        return NO;
    }
    
    [self fillUserInformation:[responseDictionary valueForKey:OAUTH2_ID_TOKEN]];
    
    FILL_FIELD(authority, OAUTH2_AUTHORITY);
    FILL_FIELD(resource, OAUTH2_RESOURCE);
    FILL_FIELD(clientId, OAUTH2_CLIENT_ID);
    FILL_FIELD(accessToken, OAUTH2_ACCESS_TOKEN);
    FILL_FIELD(refreshToken, OAUTH2_REFRESH_TOKEN);
    FILL_FIELD(accessTokenType, OAUTH2_TOKEN_TYPE);
    FILL_FIELD(correlationId, OAUTH2_CORRELATION_ID_RESPONSE);
    
    [self fillExpiration:responseDictionary];
    
    BOOL isMRRT = ![NSString adIsStringNilOrBlank:[responseDictionary objectForKey:OAUTH2_RESOURCE]] && ![NSString adIsStringNilOrBlank:self.refreshToken];
    
    [self logWithCorrelationId:[responseDictionary objectForKey:OAUTH2_CORRELATION_ID_RESPONSE] mrrt:isMRRT];
    
    return isMRRT;
}


@end
