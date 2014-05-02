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
 *
 *
 * This class implements what is described on Apple's NSIncrementalStore Programing
 * Guide as "The Disk Cache".
 * https://developer.apple.com/library/mac/documentation/DataManagement/Conceptual/IncrementalStorePG/Introduction/Introduction.html#//apple_ref/doc/uid/TP40010706
 *
 * The cache is only populated assyncronously through the method -[APDiskCache syncAllObjects:onCountingObjects:onSyncObject:onCompletion:],
 * so that fetching the cache will not triger any network operation.
 */

@import CoreData;

typedef NS_ENUM(NSInteger, APMergePolicy) {
    APMergePolicyServerWins = 0,
    APMergePolicyClientWins = 1
};

@protocol APWebServiceConnector;


@interface APDiskCache : NSObject

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
       webServiceConnector:(id <APWebServiceConnector>) connector;


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

- (NSDictionary*) fetchObjectRepresentationForObjectUID:(NSString*) objectUID
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
 Permanent objectIDs are only allocated when the objects are syncronized with the remote webservice. Before that
 we must allocate a temporary objectID to allow for unique identification of objects between the APIncrementalStore
 context and the disk cache context.
 @returns a new temporary object identifier
 */
- (NSString*) createObjectUID;

/**
 Requests the localCache to start the sync process using its remoteDBConnector
 @param allObjects if YES it will ignore whether an object had been already syncronized previously
 @param countingBlock before starting merging the objects this block will be called passing the total number of objects to be synced, if counting is not supported by the employed webservice it will return -1
 @param syncObjectBlock whenever a object is synced this block gets called. The block parameter isRemoteObject is set to YES if the synced objects merged from the server otherwise it is a local object merged.
 @param conpletionBlock the block to be called when the sync is done passing a disctionary containing the objects that were successfuly synced keyed by the corresponding entity name.
 */
- (void) syncAllObjects:(BOOL) allObjects
      onCountingObjects:(void(^)(NSInteger localObjects, NSInteger remoteObjects)) countingBlock
           onSyncObject:(void(^)(BOOL isRemoteObject)) syncObjectBlock
           onCompletion:(void(^)(NSDictionary* objectUIDsNestedByEntityName, NSError* syncError)) conpletionBlock;

- (void) resetCache;

@end


/**
 Buid a class that this protocol's methods and pass it when init an instance of APDiskCache.
 The APDiskCache will use it to interact with the remote web service provider to persist
 your data remotely. This API implements connectivity to Parse through the class APParseConnector
 */
@protocol APWebServiceConnector <NSObject>

- (instancetype)initWithAuthenticatedUser:(id) user
                              mergePolicy:(APMergePolicy) policy;

- (NSString*) authenticatedUserID;

- (void) setMergePolicy:(APMergePolicy) policy;


/**
 Get all remote objets that the user has access to and merge into the given context.
 @param context the context to be syncronised
 @param fullSync if YES ignores the last sync and syncs the whole DB.
 @returns A NSDictionary containing the merged objectUIDs keyed by entity name.
 */
- (NSDictionary*) mergeRemoteObjectsWithContext:(NSManagedObjectContext*) context
                                       fullSync:(BOOL) fullSync
                                   onSyncObject:(void (^)(void)) onSyncObject
                                          error:(NSError*__autoreleasing*) error;

/**
 Merge all managedObjects marked as "dirty".
 @param replaceBlock block will be called whenever a temporary objectUID is replaced by a permanent one.
 @returns YES if the merge was successful otherwise NO.
 */
- (BOOL) mergeManagedContext:(NSManagedObjectContext *)context
                onSyncObject:(void (^)(void)) onSyncObject
                       error:(NSError*__autoreleasing*) error;

/**
 Let connector know that sync process has been finished
 Use this method to free any resource in use related to sync or save last versions of synced objects.
 @param success whether the process was succesful or not
 */
- (void) syncProcessDidFinish:(BOOL) success;

/**
 Counts and return the local objects that need to be synced. Doesn't make much sense implement it 
 if the webservice does not support couting.
 @returns the total number of local objects that need to be synced, if it's not supported return -1
 */
- (NSInteger) countLocalObjectsToBeSyncedInContext:(NSManagedObjectContext *)context
                                              error:(NSError*__autoreleasing*) error;

/**
 If the webservice supports couting return the total number of objects that need to be synced.
 @returns the total number of objects that need to be synced localy, if it's not supported return -1
 */
- (NSInteger) countRemoteObjectsToBeSyncedInContext:(NSManagedObjectContext *)context
                                            fullSync:(BOOL) fullSync
                                               error:(NSError*__autoreleasing*) error;

@end
