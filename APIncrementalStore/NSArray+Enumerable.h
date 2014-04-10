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

typedef id(^MapBlock)(id item);

/**
 This category provides a helper method to take a provided array of objects and enumerate over them, applying the given block to each item. 
 */
@interface NSArray (Enumerable)

/**
 Helper method to enumerate over an array and apply the block to each object.
 @param block The block to apply to each object in the array.
 @return A new array where the provided block has been applied to each object.
 
 */
- (NSArray *)map:(MapBlock)block;

@end
