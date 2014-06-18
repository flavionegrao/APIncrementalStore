//
//  APWebServiceSyncOperation.m
//  Pods
//
//  Created by Flavio Negrão Torres on 6/15/14.
//
//

#import "APWebServiceSyncOperation.h"

@implementation APWebServiceSyncOperation

- (instancetype)initWithMergePolicy:(APMergePolicy) policy {
    
    self = [super init];
    if (self) {
        _mergePolicy = policy;
    }
    return self;
}

- (NSString*) debugDescription {
    NSString* customDescription =  [NSString stringWithFormat:@"%@\n    • isExecuting: %@\n    • isCancelled: %@\n    • isFinished: %@\n    • isReady:%@\n    • Merge Policy: %@\n",
                                    self,
                                    [self isExecuting] ? @"👍" : @"👎",
                                    [self isCancelled] ? @"👍" : @"👎",
                                    [self isFinished]  ? @"👍" : @"👎",
                                    [self isReady] ? @"👍" : @"👎",
                                    (self.mergePolicy == APMergePolicyClientWins) ? @"Client Wins" : @"Server Wins"];
    return customDescription;
}
@end
