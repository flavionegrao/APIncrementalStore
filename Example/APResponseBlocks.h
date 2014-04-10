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


/**
 A block that returns nothing.
 
 */
typedef void (^APBlock)(void);

/**
 A block that returns nothing.
 
 */
typedef void (^APStringBlock)(NSString* text);

/**
 A success block that returns nothing.
 
 */
typedef void (^APSuccessBlock)(void);

/**
 A success block that returns nothing.
 
 */
typedef void (^APBoolBlock)(BOOL result);

/**
 The block parameters expected for a success response which returns an `NSDictionary`.
 
 */
typedef void (^APResultSuccessBlock)(NSArray *result);

/**
 The block parameters expected for a success response which returns an id.
 
 */
typedef void (^APIdSuccessBlock)(id result);


/**
 The block parameters expected for any failure response.
 
 */
typedef void (^APFailureBlock)(NSError *error);

