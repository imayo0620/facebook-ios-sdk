// Copyright (c) 2014-present, Facebook, Inc. All rights reserved.
//
// You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
// copy, modify, and distribute this software in source code or binary form for use
// in connection with the web services and APIs provided by Facebook.
//
// As with any software that integrates with the Facebook platform, your use of
// this software is subject to the Facebook Developer Principles and Policies
// [http://developers.facebook.com/policy/]. This copyright notice shall be
// included in all copies or substantial portions of the software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "FBSDKTestUsersManager.h"

#import "FBSDKCoreKit+Internal.h"

static NSString *const kFBGraphAPITestUsersPathFormat = @"%@/accounts/test-users";
static NSString *const kAccountsDictionaryTokenKey = @"access_token";
static NSString *const kAccountsDictionaryPermissionsKey = @"permissions";
static NSMutableDictionary *gInstancesDictionary;

@interface FBSDKTestUsersManager()
- (instancetype)initWithAppId:(NSString *)appId appSecret:(NSString *)appSecret NS_DESIGNATED_INITIALIZER;
@end

@implementation FBSDKTestUsersManager
{
  NSString *_appId;
  NSString *_appSecret;
  // dictionary with format like:
  // { user_id :  { kAccountsDictionaryTokenKey : "token",
  //                kAccountsDictionaryPermissionsKey : [ permissions ] }
  NSMutableDictionary *_accounts;
}

- (instancetype)initWithAppId:(NSString *)appId appSecret:(NSString *)appSecret {
  if ((self = [super init])) {
    _appId = [appId copy];
    _appSecret = [appSecret copy];
    _accounts = [NSMutableDictionary dictionary];
  }
  return self;
}

- (instancetype)init
{
  FBSDK_NOT_DESIGNATED_INITIALIZER
  return [self initWithAppId:nil appSecret:nil];
}

+ (instancetype)sharedInstanceForAppId:(NSString *)appId appSecret:(NSString *)appSecret {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    gInstancesDictionary = [NSMutableDictionary dictionary];
  });

  NSString *instanceKey = [NSString stringWithFormat:@"%@|%@", appId, appSecret];
  if (!gInstancesDictionary[instanceKey]) {
    gInstancesDictionary[instanceKey] = [[FBSDKTestUsersManager alloc] initWithAppId:appId appSecret:appSecret];
  }
  return gInstancesDictionary[instanceKey];
}

- (void)requestTestAccountTokensWithArraysOfPermissions:(NSArray *)arraysOfPermissions
                                       createIfNotFound:(BOOL)createIfNotFound
                                      completionHandler:(FBSDKTestUsersManagerRetrieveTestAccountTokensHandler)handler {
  arraysOfPermissions = arraysOfPermissions ?: @[[NSSet set]];

  // wrap work in a block so that we can chain it to after a fetch of existing accounts if we need to.
  void (^helper)(NSError *) = ^(NSError *error){
    if (error) {
      if (handler) {
        handler(nil, error);
      }
      return;
    }
    NSMutableArray *tokenDatum = [NSMutableArray arrayWithCapacity:arraysOfPermissions.count];
    NSMutableSet *collectedUserIds = [NSMutableSet setWithCapacity:arraysOfPermissions.count];
    __block BOOL canInvokeHandler = YES;
    __weak id weakSelf = self;
    [arraysOfPermissions enumerateObjectsUsingBlock:^(NSSet *desiredPermissions, NSUInteger idx, BOOL *stop) {
      NSArray* userIdAndTokenPair = [self userIdAndTokenOfExistingAccountWithPermissions:desiredPermissions skip:collectedUserIds];
      if (!userIdAndTokenPair) {
        if (createIfNotFound) {
          [self addTestAccountWithPermissions:desiredPermissions
                            completionHandler:^(NSArray *tokens, NSError *addError) {
                              if (addError) {
                                if (handler) {
                                  handler(nil, addError);
                                }
                              } else {
                                [weakSelf requestTestAccountTokensWithArraysOfPermissions:arraysOfPermissions
                                                                         createIfNotFound:createIfNotFound
                                                                        completionHandler:handler];
                              }
                            }];
          // stop the enumeration (ane flag so that callback to addTestAccount* will resolve our handler now).
          canInvokeHandler = NO;
          *stop = YES;
          return;
        } else {
          [tokenDatum addObject:[NSNull null]];
        }
      } else {
        NSString *userId = userIdAndTokenPair[0];
        NSString *tokenString = userIdAndTokenPair[1];
        [collectedUserIds addObject:userId];
        [tokenDatum addObject:[self tokenDataForTokenString:tokenString
                                                permissions:desiredPermissions
                                                     userId:userId]];
      }
    }];

    if (canInvokeHandler && handler) {
      handler(tokenDatum, nil);
    }
  };
  if (_accounts.count == 0) {
    [self fetchExistingTestAccounts:helper];
  } else {
    helper(NULL);
  }
}

- (void)addTestAccountWithPermissions:(NSSet *)permissions
                    completionHandler:(FBSDKTestUsersManagerRetrieveTestAccountTokensHandler)handler {
  NSDictionary *params = @{
                           @"installed" : @"true",
                           @"permissions" : [[permissions allObjects] componentsJoinedByString:@","],
                           @"access_token" : self.appAccessToken
                           };
  FBSDKGraphRequest *request = [[FBSDKGraphRequest alloc] initWithGraphPath:[NSString stringWithFormat:kFBGraphAPITestUsersPathFormat, _appId]
                                                                 parameters:params
                                                                tokenString:[self appAccessToken]
                                                                    version:nil
                                                                 HTTPMethod:@"POST"];
  [request startWithCompletionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
    if (error) {
      if (handler) {
        handler(nil, error);
      }
    } else {
      NSMutableDictionary *accountData = [NSMutableDictionary dictionaryWithCapacity:2];
      accountData[kAccountsDictionaryPermissionsKey] = [NSSet setWithSet:permissions];
      accountData[kAccountsDictionaryTokenKey] = result[@"access_token"];
      _accounts[result[@"id"]] = accountData;

      if (handler) {
        FBSDKAccessToken *token = [self tokenDataForTokenString:accountData[kAccountsDictionaryTokenKey]
                                                    permissions:permissions
                                                         userId:result[@"id"]];
        handler(@[token], nil);
      }
    }
  }];
}

- (void)makeFriendsWithFirst:(FBSDKAccessToken *)first second:(FBSDKAccessToken *)second callback:(void (^)(NSError *))callback
{
  __block int expectedCount = 2;
  void (^complete)(NSError *) = ^(NSError *error) {
    // ignore if they're already friends
    if ([error.userInfo[FBSDKGraphRequestErrorGraphErrorCode] integerValue] == 522) {
      error = nil;
    }
    if (--expectedCount == 0 || error) {
      callback(error);
    }
  };
  FBSDKGraphRequest *one = [[FBSDKGraphRequest alloc] initWithGraphPath:[NSString stringWithFormat:@"%@/friends/%@", first.userID, second.userID]
                                                             parameters:nil
                                                            tokenString:first.tokenString
                                                                version:nil
                                                             HTTPMethod:@"POST"];
  FBSDKGraphRequest *two = [[FBSDKGraphRequest alloc] initWithGraphPath:[NSString stringWithFormat:@"%@/friends/%@", second.userID, first.userID]
                                                             parameters:nil
                                                            tokenString:second.tokenString
                                                                version:nil
                                                             HTTPMethod:@"POST"];
  FBSDKGraphRequestConnection *conn = [[FBSDKGraphRequestConnection alloc] init];
  [conn addRequest:one completionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
    complete(error);
  }];
  [conn addRequest:two completionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
    complete(error);
  }];
  [conn start];
}

- (void)removeTestAccount:(NSString *)userId completionHandler:(FBSDKTestUsersManagerRemoveTestAccountHandler)handler {
  FBSDKGraphRequest *request = [[FBSDKGraphRequest alloc] initWithGraphPath:userId
                                                                 parameters:nil
                                                                tokenString:self.appAccessToken
                                                                    version:nil
                                                                 HTTPMethod:@"DELETE"];
  [request startWithCompletionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
    if (handler) {
      handler(error);
    }
  }];
}

#pragma mark - private methods
- (FBSDKAccessToken *)tokenDataForTokenString:(NSString *)tokenString permissions:(NSSet *)permissions userId:(NSString *)userId{
  return [[FBSDKAccessToken alloc] initWithTokenString:tokenString
                                           permissions:[permissions allObjects]
                                   declinedPermissions:nil
                                                 appID:_appId
                                                userID:userId
                                        expirationDate:nil
                                           refreshDate:nil];
}

- (NSArray *)userIdAndTokenOfExistingAccountWithPermissions:(NSSet *)permissions skip:(NSSet *)setToSkip {
  __block NSString *userId = nil;
  __block NSString *token = nil;

  [_accounts enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *accountData, BOOL *stop) {
    if ([setToSkip containsObject:key]) {
      return;
    }
    NSSet *accountPermissions = accountData[kAccountsDictionaryPermissionsKey];
    if ([permissions isSubsetOfSet:accountPermissions]) {
      token = accountData[kAccountsDictionaryTokenKey];
      userId = key;
      *stop = YES;
    }
  }];
  if (userId && token) {
    return @[userId, token];
  } else {
    return nil;
  }
}

- (NSString *)appAccessToken {
  return [NSString stringWithFormat:@"%@|%@", _appId, _appSecret];
}

- (void)fetchExistingTestAccounts:(void(^)(NSError *error))handler {
  FBSDKGraphRequestConnection *connection = [[FBSDKGraphRequestConnection alloc] init];
  FBSDKGraphRequest *requestForAccountIds = [[FBSDKGraphRequest alloc] initWithGraphPath:[NSString stringWithFormat:kFBGraphAPITestUsersPathFormat, _appId]
                                                                              parameters:nil
                                                                             tokenString:self.appAccessToken
                                                                                 version:nil
                                                                              HTTPMethod:nil];
  __block BOOL noTestAccounts = YES;
  [connection addRequest:requestForAccountIds completionHandler:^(FBSDKGraphRequestConnection *innerConnection, id result, NSError *error) {
    if (error) {
      if (handler) {
        handler(error);
      }
    } else {
      for (NSDictionary *account in result[@"data"]) {
        NSString *userId = account[@"id"];
        _accounts[userId] = [NSMutableDictionary dictionaryWithCapacity:2];
        _accounts[userId][kAccountsDictionaryTokenKey] = account[@"access_token"];
        noTestAccounts = NO;
      }
    }
  } batchParameters:@{@"name":@"test-accounts", @"omit_response_on_success":@(NO)}];

  FBSDKGraphRequest *requestForUsersPermissions = [[FBSDKGraphRequest alloc] initWithGraphPath:@"?ids={result=test-accounts:$.data.*.id}&fields=permissions"
                                                                                    parameters:nil
                                                                                   tokenString:self.appAccessToken
                                                                                       version:nil
                                                                                    HTTPMethod:nil];
  [connection addRequest:requestForUsersPermissions completionHandler:^(FBSDKGraphRequestConnection *innerConnection, id result, NSError *error) {
    if (noTestAccounts) {
      if (handler) {
        handler(nil);
      }
      return;
    }
    if (error) {
      if (handler) {
        handler(error);
      }
    } else {
      for (NSString *userId in [result allKeys]) {
        NSMutableSet *grantedPermissions = [NSMutableSet set];
        NSArray *resultPermissionsDictionaries = result[userId][@"permissions"][@"data"];
        [resultPermissionsDictionaries enumerateObjectsUsingBlock:^(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
          [grantedPermissions addObject:obj[@"permission"]];
        }];
        _accounts[userId][kAccountsDictionaryPermissionsKey] = grantedPermissions;
      }
    }
    if (handler) {
      handler(nil);
    }
  }];
  [connection start];
}
@end
