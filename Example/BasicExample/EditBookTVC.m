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

#import "EditBookTVC.h"
#import <MobileCoreServices/UTCoreTypes.h>

typedef void (^Block)();
typedef void (^BlockWithString)(NSString* string);

@interface EditBookTVC () <UIActionSheetDelegate,UIImagePickerControllerDelegate,UINavigationControllerDelegate>
@property (weak, nonatomic) IBOutlet UITextField *nameOfTheBookTextField;
@property (weak, nonatomic) IBOutlet UIButton *deleteButton;
@property (weak, nonatomic) IBOutlet UIButton *addCoverButton;
@property (weak, nonatomic) IBOutlet UIImageView *coverImageView;

@property (strong, nonatomic) Block viewDidSaveBlock;
@property (strong, nonatomic) Block viewDidCancelBlock;
@property (strong, nonatomic) Block viewDidDeleteBlock;

@end

@implementation EditBookTVC

- (void) viewDidLoad {
    [super viewDidLoad];
    if (self.book) {
        self.nameOfTheBookTextField.text = self.book.name;
        self.deleteButton.hidden = NO;
        
        if (self.book.picture) {
            self.coverImageView.image = [UIImage imageWithData:self.book.picture];
            self.addCoverButton.hidden = YES;
        } else {
            self.addCoverButton.hidden = NO;
        }
    }
}

- (void) setViewDidCancelCallBackBlock: (void (^)(void)) block {
    _viewDidCancelBlock = block;
}

- (void) setViewDidSaveCallBackBlock: (void (^)(void)) block {
    _viewDidSaveBlock = block;
}

- (void) setViewDidDeleteCallBackBlock: (void (^)(void)) block {
    _viewDidDeleteBlock = block;
}

- (IBAction)viewDidSave:(id)sender {
    self.book.name = self.nameOfTheBookTextField.text;
    if (self.viewDidSaveBlock) self.viewDidSaveBlock();
}

- (IBAction)viewDidCancel:(id)sender {
    if (self.viewDidCancelBlock) self.viewDidCancelBlock();
}

- (IBAction)deleteButtonTouched:(id)sender {
    if (self.viewDidDeleteBlock) self.viewDidDeleteBlock();
}

#pragma mark - Foto
- (IBAction) addCoverButtonClicked: (id)sender {
    [self presentPhotoSourceOptionsFromView:sender];
}


- (void) presentPhotoSourceOptionsFromView: (UIView*) view {
    
    
    UIActionSheet* actionSheet = [[UIActionSheet alloc]initWithTitle:@"Select image source"
                                                            delegate:self
                                                   cancelButtonTitle:@"Cancelar"
                                              destructiveButtonTitle:nil
                                                   otherButtonTitles:@"New Photo",@"Select Existing", nil];
    actionSheet.actionSheetStyle = UIActionSheetStyleBlackTranslucent;
    
    [actionSheet showFromRect:view.frame inView:self.view animated:YES];
}

- (void) actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    
    NSString* buttonTitle = [actionSheet buttonTitleAtIndex:buttonIndex];
    
    if ([buttonTitle isEqualToString:@"New Photo"] ) {
        [self presentImagePickerForSourceType:UIImagePickerControllerSourceTypeCamera];
        
    } else if ([buttonTitle isEqualToString:@"Select Existing"]) {
        [self presentImagePickerForSourceType:UIImagePickerControllerSourceTypePhotoLibrary];
        
    }
}


- (void) presentImagePickerForSourceType:(UIImagePickerControllerSourceType) sourceType {
    
    UIImagePickerController* picker = [UIImagePickerController new];
    picker.delegate = self;
    
    //Only pictures
    picker.mediaTypes = @[(NSString *) kUTTypeImage];
    
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera] &&
        sourceType == UIImagePickerControllerSourceTypeCamera) {
        //Probably iOS Simulator
        self.coverImageView.image = [UIImage imageNamed:@"book_sample"];
        self.book.picture = UIImagePNGRepresentation(self.coverImageView.image);
        self.addCoverButton.hidden = YES;
        
    } else {
        picker.sourceType = sourceType;
        [self presentViewController:picker animated:YES completion:nil];
    }
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    
    self.coverImageView.image = [info objectForKey:UIImagePickerControllerOriginalImage];
    self.book.picture = UIImagePNGRepresentation(self.coverImageView.image);
    [picker dismissViewControllerAnimated:YES completion:nil];
    self.addCoverButton.hidden = YES;
    
}


- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    
    [self dismissViewControllerAnimated:YES completion:nil];
    self.navigationItem.rightBarButtonItem.enabled = YES;
}


@end
