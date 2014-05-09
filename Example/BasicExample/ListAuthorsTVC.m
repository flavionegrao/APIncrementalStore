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

#import "ListAuthorsTVC.h"
#import "ListBooksTVC.h"

#import "CoreDataController.h"

#import "Author+Transformable.h"
#import "Book.h"
#import <Parse-iOS-SDK/Parse.h>
#import "APCommon.h"
#import "NSLogEmoji.h"

/* Parse config */
static NSString* const APDefaultParseUserName = @"test_user";
static NSString* const APDefaultParsePassword = @"1234";


@interface ListAuthorsTVC () <UITableViewDataSource,UITableViewDelegate,UIAlertViewDelegate>

@property (nonatomic, strong) UIBarButtonItem *syncButton;
@property (nonatomic, strong) UIBarButtonItem *addButton;
@property (weak, nonatomic) IBOutlet UIBarButtonItem *loginButton;

@end


@implementation ListAuthorsTVC

- (void) viewDidLoad {
    
    [super viewDidLoad];
    
    self.syncButton = [[UIBarButtonItem alloc]
                       initWithTitle:@"Sync"
                       style:UIBarButtonItemStylePlain
                       target:self
                       action:@selector(syncButtonTouched:)];
    
    self.addButton = [[UIBarButtonItem alloc]
                      initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                      target:self
                      action:@selector(addButtonTouched:)];
    
    [self.navigationItem setRightBarButtonItems:@[self.addButton,self.syncButton]];
    
    [self configNavBarForLoggedUser:NO];
}


- (IBAction)loginButtonTouched:(id)sender {
    
    if ([PFUser currentUser] && [self.loginButton.title isEqualToString:@"Logout"]) {
        [PFUser logOut];
        self.frc = nil;
        [self configNavBarForLoggedUser:NO];
        
    } else if ([PFUser currentUser]) {
        [[[UIAlertView alloc] initWithTitle:nil
                                    message:[NSString stringWithFormat:@"User: %@ was already logged, to login with another user select logout first",[PFUser currentUser].username]
                                   delegate:self
                          cancelButtonTitle:@"Ok"
                          otherButtonTitles:nil]show];
        [CoreDataController sharedInstance].authenticatedUser = [PFUser currentUser];
        [self configFetchResultController];
        [self configNavBarForLoggedUser:YES];
        
    } else {
        [self.loginButton setTitle:@"Logging in..."];
        self.loginButton.enabled = NO;
        
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Login"
                                                        message:[NSString stringWithFormat:@"Enter username and password or leave both blank to login as test_user/1234"]
                                                       delegate:self
                                              cancelButtonTitle:@"Ok"
                                              otherButtonTitles:nil];
        
        [alert setAlertViewStyle:UIAlertViewStyleLoginAndPasswordInput];
        [alert show];
    }
}


- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)buttonIndex {
    
    if (alert.alertViewStyle == UIAlertViewStyleLoginAndPasswordInput) {
        NSString* username = ([[[alert textFieldAtIndex:0] text] length] == 0) ? APDefaultParseUserName : [[alert textFieldAtIndex:0] text];
        NSString* password = ([[[alert textFieldAtIndex:1] text] length] == 0) ? APDefaultParsePassword : [[alert textFieldAtIndex:1] text];
        
        [PFUser logInWithUsernameInBackground:username password:password block:^(PFUser *user, NSError *error) {
            if (!error) {
                DLog(@"Authentication OK");
                [CoreDataController sharedInstance].authenticatedUser = user;
                [self configFetchResultController];
                [self configNavBarForLoggedUser:YES];
                
            } else {
                NSString* errorMessage = [NSString stringWithFormat:@"Authentication failure: %@",error.localizedDescription];
                [[[UIAlertView alloc]initWithTitle:nil message:errorMessage delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil]show];
                ELog(@"Authentication Failure with error: %@",error);
                [self configNavBarForLoggedUser:NO];
            }
        }];
    }
}


- (void) configNavBarForLoggedUser: (BOOL) userIsLoggedIn {
    
    if (userIsLoggedIn) {
        self.addButton.enabled = YES;
        self.syncButton.enabled = YES;
        self.loginButton.enabled = YES;
        [self.loginButton setTitle:@"Logout"];
        self.navigationItem.prompt = [NSString stringWithFormat:@"Logged username: %@",[PFUser currentUser].username];
    } else {
        self.addButton.enabled = NO;
        self.syncButton.enabled = NO;
        self.loginButton.enabled = YES;
        [self.loginButton setTitle:@"Login"];
        self.navigationItem.prompt = nil;
    }
}


- (IBAction)syncButtonTouched:(id)sender {
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveSyncIsFinished:) name:
     CoreDataControllerNotificationDidSync object:[CoreDataController sharedInstance]];
    [[CoreDataController sharedInstance] requestSyncCache];
    self.syncButton.enabled = NO;
    
}


- (void) didReceiveSyncIsFinished: (NSNotification*) note {
    self.syncButton.enabled = YES;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:CoreDataControllerNotificationDidSync object:[CoreDataController sharedInstance]];
}


- (IBAction)addButtonTouched:(id)sender {
    
    // Scroll to the top
    [self.tableView scrollRectToVisible:CGRectMake(0, 0, 1, 1) animated:YES];
    
    NSManagedObjectContext* context = [CoreDataController sharedInstance].mainContext;
    
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    NSError* error;
    NSUInteger numberOfExistingAuthors = [context countForFetchRequest:fr error:&error];
    if(error){
        ELog(@"Fetching error: %@",error);
    }
    
    Author* newAuthor = [NSEntityDescription insertNewObjectForEntityForName:@"Author" inManagedObjectContext:[CoreDataController sharedInstance].mainContext];
    newAuthor.name = [NSString stringWithFormat:@"Author#%lu (%@)",(unsigned long)numberOfExistingAuthors,[PFUser currentUser].username];
    
    // Set ACL to the object.
    NSString* currentUserObjectId = [PFUser currentUser].objectId;
    [[CoreDataController sharedInstance] addWriteAccess:YES readAccess:YES isRole:NO forParseIdentifier:currentUserObjectId forManagedObject:newAuthor];
    [[CoreDataController sharedInstance] addWriteAccess:YES readAccess:YES isRole:YES forParseIdentifier:@"Moderators" forManagedObject:newAuthor];
    
    [context save:&error];
    if(error){
        ELog(@"Fetching error: %@",error);
    }
}


- (void) configFetchResultController {
    
    NSManagedObjectContext* moc = [CoreDataController sharedInstance].mainContext;
    NSFetchRequest* fr = [NSFetchRequest fetchRequestWithEntityName:@"Author"];
    fr.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]];
    self.frc = [[NSFetchedResultsController alloc]initWithFetchRequest:fr managedObjectContext:moc sectionNameKeyPath:nil cacheName:nil];
}


- (UITableViewCell*) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    
    static NSString* cellID = @"cellID";
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:cellID forIndexPath:indexPath];
    Author* author = [self.frc objectAtIndexPath:indexPath];
    cell.textLabel.text = [author valueForKey:@"name"];
    
    NSUInteger numberOfBooks = [author.books count];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu %@",(unsigned long)numberOfBooks, (numberOfBooks == 1)? @"book":@"books"];
    return cell;
}


#pragma mark - Navigation

- (void) prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    
    ListBooksTVC* listBooksTVC = segue.destinationViewController;
    
    UITableViewCell* cell = (UITableViewCell*) sender;
    NSIndexPath* selectedIndexPath = [self.tableView indexPathForCell:cell];
    Author* selectedAuthor = [self.frc objectAtIndexPath:selectedIndexPath];
    listBooksTVC.author = selectedAuthor;
    listBooksTVC.title = [NSString stringWithFormat:@"Books from %@", selectedAuthor.name];
    listBooksTVC.navigationItem.prompt = [NSString stringWithFormat:@"Logged username: %@",[PFUser currentUser].username];
}

@end
