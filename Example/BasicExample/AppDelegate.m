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

#import "AppDelegate.h"
#import <Parse-iOS-SDK/Parse.h>

static NSString* const APParsepApplicationId = @"";
static NSString* const APParseClientKey =  @"";

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // Override point for customization after application launch.
    
    if ([APParseClientKey length] == 0 || [APParsepApplicationId length] == 0) {
        [NSException raise:@"App config exception" format:@"Set the correct Parse keys on AppDelegate.m"];
    }
    [Parse setApplicationId:APParsepApplicationId clientKey:APParseClientKey];
    
    UIApplicationState state = [application applicationState];
    switch (state) {
        case UIApplicationStateActive:
            NSLog(@"Application is Active");
            break;
        case UIApplicationStateInactive:
            NSLog(@"Application is Inactive");
            break;
        case UIApplicationStateBackground:
            NSLog(@"Application is BG");
            break;
        default:
            break;
    }
    return YES;
    
}

- (void)applicationWillTerminate:(UIApplication *)application {
    NSLog(@"App Will Terminate");
}


- (void)applicationWillEnterForeground:(UIApplication *)application {
    NSLog(@"App Will Enter Foreground");
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    NSLog(@"App Did Enter BG");
}


- (void)applicationWillResignActive:(UIApplication *)application
{
    NSLog(@"App will Resign Active");
    
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    NSLog(@"App did Become Active");
    
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    NSLog(@"Memory Warning received");
}
@end
