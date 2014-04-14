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

#import <CoreData/CoreData.h>

typedef NS_ENUM(NSInteger, APMergePolicy) {
    APMergePolicyServerWins = 0,
    APMergePolicyClientWins = 1
};

@protocol APRemoteDBConnector;


@interface APLocalCache : NSObject

/**
 Designated Initializar
 @param model
 @param translateBlock block that translates ManagedObjectID to reference ObjectUID, usually implemented by -[NSIncrementalStore referenceObjectForObjectID:]. This class use it to translate the predicates to ones complatible for query the local cache.
 @param incrementalStore the NSIncrementalStore subclass that this instance is providing cache support
 @param localStoreURL the name of the SQLite store to be used by this class
 */
- (id)initWithManagedModel:(NSManagedObjectModel*) model
 translateToObjectUIDBlock:(NSString* (^)(NSManagedObjectID*)) translateBlock
        localStoreFileName:(NSString*) localStoreFileName
      shouldResetCacheFile:(BOOL) shouldResetCache
         remoteDBConnector:(id <APRemoteDBConnector>) remoteDBConnector;


/**
 Retrieve cached objects representations using the following format:
 [  
    {
        "kAPLocalCacheObjectUIDAttributeName": objectUID,
        "AttributeName1": provertyValue1,
        "AttributeName2": provertyValue2,
        "AttributeData1": NSData,
        "RelationshipToOneName": obectUIDValue,
        "RelationshipToMany": [
            obectUID,
            obectUID,
            obectUID,
        ]
    },
    ...
 ]
 
 If         PropertyName is a to-one relationhip then propertyValue has the related object objectUID
 Else If    PropertyName is a to-many relationhip then propertyValue has a array of related objectsUID
 Else       PropertyName is a attribute then propertyValue has the value of its attribute
 
 @param fetchRequest the fetchRequest requested (same requested by the NSIncremental Store)
 @param error case something goes wrong, this will have more info about the problem
 @returns Array of representations or nil if error occurs
 */
- (NSArray*) fetchObjectRepresentations:(NSFetchRequest *)fetchRequest
                                  error:(NSError *__autoreleasing*)error;

- (NSUInteger) countObjectRepresentations:(NSFetchRequest *)fetchRequest
                                    error:(NSError *__autoreleasing*)error;

- (NSDictionary*) fetchObjectRepresentationForObjectUUID:(NSString*) objectUUID
                                              entityName:(NSString*) entityName;


- (BOOL)inserteObjectRepresentations:(NSArray*) insertedObjects
                          entityName:(NSString*) entityName
                               error:(NSError *__autoreleasing *)error;

- (BOOL)updateObjectRepresentations:(NSArray*) updateObjects
                         entityName:(NSString*) entityName
                              error:(NSError *__autoreleasing *)error;

- (BOOL)deleteObjectRepresentations:(NSArray*) deleteObjects
                         entityName:(NSString*) entityName
                              error:(NSError *__autoreleasing *)error;
/**
 Permanent objectIDs are only allocated when the objects are syncronized with the remoteDB. Before that
 we must allocated a temporary objectID to allow for uniquely identify objects between the APIncrementalStore
 context and the cache context.
 @returns a new temporary object identifier
 */
- (NSString*) newTemporaryObjectUID;

/**
 Requests the localCache to start the sync process with its remoteDBConnector
 @param allObjects if YES it will ignore whether an object had been already syncronized previously
 @param numberOfObjectsBlock before starting merging the objects this block will be called passing the total number of objects to be synced
 @param didSyncedObjectBlock whenever a object is synced this block gets called. The block parameter isRemoteObject is set to YES if the synced objects merged from the server otherwise it is a local object merged.
 @param completionBlock the block to be called when the sync is done passing the objects that were synced from the server as argument
 */
- (void) syncAllObjects: (BOOL) allObjects
                onCountingObjects: (void (^)(NSUInteger localObjects, NSUInteger remoteObjects)) countingBlock
           onSyncObject: (void (^)(BOOL isRemoteObject)) syncObjectBlock
           onCompletion: (void (^)(NSArray* objectUIDs, NSError* syncError)) conpletionBlock;

- (void) resetCache;

@end


@protocol APRemoteDBConnector <NSObject>

- (instancetype)initWithAuthenticatedUser:(id) user
                              mergePolicy:(APMergePolicy) policy;

- (void) setMergePolicy:(APMergePolicy) policy;
//- (BOOL) saveLastSyncDate;

- (NSDictionary*) mapOfTemporaryToPermanentUID;

/**
 Get all remote objets that the user has access to and merge into the given context.
 @param context the context to be syncronised
 @param fullSync if YES ignores the last sync and syncs the whole DB.
 @returns ManagedObjectIDs of the merged objects
 */
- (NSArray*) mergeRemoteObjectsWithContext: (NSManagedObjectContext*) context
                                  fullSync: (BOOL) fullSync
                               onSyncObject: (void (^)(void)) onSyncObject
                                     error: (NSError*__autoreleasing*) error;

/**
 Merge all managedObjects marked as "dirty".
 @param replaceBlock block will be called whenever a temporary objectUID is replaced by a permanent one.
 @returns YES if the merge was successful otherwise NO.
 */
- (BOOL) mergeManagedContext:(NSManagedObjectContext *)context
                 onSyncObject: (void (^)(void)) onSyncObject
                       error:(NSError*__autoreleasing*) error;


- (NSUInteger) countLocalObjectsToBeSyncedInContext: (NSManagedObjectContext *)context
                                              error: (NSError*__autoreleasing*) error;

- (NSUInteger) countRemoteObjectsToBeSyncedInContext: (NSManagedObjectContext *)context
                                            fullSync: (BOOL) fullSync
                                               error: (NSError*__autoreleasing*) error;

@end
