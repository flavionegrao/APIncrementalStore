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


#pragma mark - Exceptions

extern NSString* const APIncrementalStoreExceptionIncompatibleRequest;
extern NSString* const APIncrementalStoreExceptionInconsistency;
extern NSString* const APIncrementalStoreExceptionLocalCacheStore;


#pragma mark - Erros

extern NSString* const APIncrementalStoreErrorDomain;

typedef NS_ENUM(NSInteger, APIncrementalStoreErrorCode) {
    APIncrementalStoreErrorCodeUserCredentials = 0,
    APIncrementalStoreErrorCodeObtainingPermanentUUID = 1,
    APIncrementalStoreErrorCodeMergingLocalObjects = 2,
    APIncrementalStoreErrorCodeMergingRemoteObjects = 3,
    
    APIncrementalStoreErrorSyncOperationWasCancelled = 100
};