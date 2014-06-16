/*
 *
 * Copyright 2014 Flavio Negrão Torres
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <Foundation/Foundation.h>
#import "APWebServiceSyncOperation.h"
#import <Parse-iOS-SDK/Parse.h>

#import "APError.h"
#import "APCommon.h"

extern NSString* const APParseRelationshipTypeUserInfoKey;

typedef NS_ENUM(NSUInteger, APParseRelationshipType) {
    APParseRelationshipTypePFRelation = 0, //Default
    APParseRelationshipTypeArray = 1,
};

@interface APParseSyncOperation : APWebServiceSyncOperation

/**
 @param user A already authenticated user
 @param policy one of defined APMergePolicy options
 @param the managed context to be synced
 */
- (instancetype)initWithMergePolicy:(APMergePolicy) policy
             authenticatedParseUser:(PFUser*) authenticatedUser;

@property (nonatomic, strong) PFUser* authenticatedUser;

@end
