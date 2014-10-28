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

// Less interferences
//#define NSLog(FORMAT, ...) printf("%s\n", [[NSString stringWithFormat:FORMAT, ##__VA_ARGS__] UTF8String]);

// Debug
#define DLog(fmt, ...) NSLog((@"ℹ️ %@ [L:%d] - " fmt),NSStringFromClass([self class]), __LINE__, ##__VA_ARGS__);

// Error
#define ELog(fmt, ...) NSLog((@"⚠️ %@ [L:%d] - " fmt),NSStringFromClass([self class]), __LINE__, ##__VA_ARGS__);

// Method call
#define MLog(fmt, ...) NSLog((@"🆔 %@ [L:%d] %s" fmt),NSStringFromClass([self class]), __LINE__, __PRETTY_FUNCTION__, ##__VA_ARGS__);

// Attention call
#define ALog(fmt, ...) NSLog((@"‼️ %@ [L:%d] %s - " fmt),NSStringFromClass([self class]), __LINE__, __PRETTY_FUNCTION__, ##__VA_ARGS__);

// Use XCode Shortcut to jump to a specific line CMD+L :-)