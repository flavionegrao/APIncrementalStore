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


#pragma mark - Cache Support Attribute Key Names

/// Cached objects will be uniquely identified by this attribute. It won't be propageted to the user's context.
extern NSString* const APObjectUIDAttributeName;

/// Cached objects will have this attribute to enable conflict identification when merging objects from the BaaS provider.
extern NSString* const APObjectLastModifiedAttributeName;

/// Cached objects set with YES for this attribute will be merged with the BaaS provider objects.
extern NSString* const APObjectIsDirtyAttributeName;

/// When the user context requests that an object has to be deleted, when the user context is saved the equivalent cache object is marked as deleted via this attribute. We have this approach to allow for the other devices merging the same object be able to indentify that this object was deleted.
extern NSString* const APObjectIsDeletedAttributeName;

/// 
extern NSString* const APObjectIsCreatedRemotelyAttributeName;


#pragma mark - Logs

/// Set it to YES to see at the console a message everytime that a method from an instance is called
extern BOOL AP_DEBUG_METHODS;

/// Set it to YES to see at the console a message error messages
extern BOOL AP_DEBUG_ERRORS;

/// Set it to YES to see at the console a informative messages to support debugging
extern BOOL AP_DEBUG_INFO;

