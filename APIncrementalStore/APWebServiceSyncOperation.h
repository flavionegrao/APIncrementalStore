//
//  APWebServiceSyncOperation.h
//  Pods
//
//  Created by Flavio Negrão Torres on 6/15/14.
//
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, APMergePolicy) {
    APMergePolicyServerWins = 0,
    APMergePolicyClientWins = 1
};


@interface APWebServiceSyncOperation : NSOperation

/**
 @param policy one of defined APMergePolicy options
 */
- (instancetype)initWithMergePolicy:(APMergePolicy) policy;

@property (nonatomic, assign) BOOL fullSync;

@property (nonatomic, copy) NSString* envID;

@property (nonatomic, readonly) APMergePolicy mergePolicy;

@property (nonatomic, copy) void (^perObjectCompletionBlock) (BOOL isRemote, NSString* entityName);

@property (nonatomic, copy) void (^syncCompletionBlock) (
                                    NSDictionary* mergedObjectsUIDsNestedByEntityName,
                                    NSError* error);
@end
