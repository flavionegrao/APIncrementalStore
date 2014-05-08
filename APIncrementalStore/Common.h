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

/// Cached objects will have this attribute to enable conflict identification when merging objects from the webservice provider.
extern NSString* const APObjectLastModifiedAttributeName;

/// Cached objects set with YES for this attribute will be merged with the BaaS provider objects.
extern NSString* const APObjectIsDirtyAttributeName;

/// When the user context requests that an object has to be deleted, when the user context is saved the equivalent cache object is marked as deleted via this attribute. We have this approach to allow for the other devices merging the same object be able to indentify that this object has been deleted.
extern NSString* const APObjectIsDeletedAttributeName;

/// Through this attribute the APParseConnector is able to identify which class it should insert a new object comming from the webservice provider. This is the case when a entity inheritance is enployed in the model. At the webservice database only the root entities will be create and subentities will be identified by this attribute.
extern NSString* const APObjectEntityNameAttributeName;

/// Whether or not an object is created remotely.
extern NSString* const APObjectIsCreatedRemotelyAttributeName;

/** 
 If a Core Data entity has this attribute it will be interpreted as a Parse PFACL attribute. 
 It should be Binary Property containing a JSON object encoded with UTF-8. 
 It will follow the same Parse REST format, which means a Dictionary
 
 Example:
 
 NSMutableDictionary* ACL = [NSMutableDictionary dictionary];
 
 NSString* roleName = [NSString stringWithFormat:@"role:%@",role.name];
 NSString* permission = [NSString stringWithFormat:@"write:YES"];
 [ACL setValue:permission forKey:roleName];
 NSData* ACLData = [NSJSONSerialization dataWithJSONObject:ACL options:0 error:nil];
 
 [managedObject setValue:ACLData forKey:@"__ACL"];
 
 @see https://www.parse.com/docs/rest#roles
 */
extern NSString* const APCoreDataACLAttributeName;


#pragma mark - Logs

/// Set it to YES to see at the console a message everytime that a method from an instance is called
extern BOOL AP_DEBUG_METHODS;

/// Set it to YES to see at the console a message error messages
extern BOOL AP_DEBUG_ERRORS;

/// Set it to YES to see at the console a informative messages to support debugging
extern BOOL AP_DEBUG_INFO;

