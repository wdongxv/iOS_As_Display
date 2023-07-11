/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app's primary view controller that presents the camera interface.
*/

@import AVFoundation;
@import CoreLocation;
@import Photos;

#import "AVCamCameraViewController.h"
#import "AVCamPreviewView.h"
#import "AVCamPhotoCaptureDelegate.h"

static void*  SessionRunningContext = &SessionRunningContext;
static void*  SystemPreferredCameraContext = &SystemPreferredCameraContext;
static void*  VideoRotationAngleForHorizonLevelPreviewContext = &VideoRotationAngleForHorizonLevelPreviewContext;

typedef NS_ENUM(NSInteger, AVCamSetupResult) {
    AVCamSetupResultSuccess,
    AVCamSetupResultCameraNotAuthorized,
    AVCamSetupResultSessionConfigurationFailed
};

typedef NS_ENUM(NSInteger, AVCamCaptureMode) {
    AVCamCaptureModePhoto = 0,
    AVCamCaptureModeMovie = 1
};

typedef NS_ENUM(NSInteger, AVCamLivePhotoMode) {
    AVCamLivePhotoModeOn,
    AVCamLivePhotoModeOff
};

typedef NS_ENUM(NSInteger, AVCamHDRVideoMode) {
    AVCamHDRVideoModeOn,
    AVCamHDRVideoModeOff
};

@interface AVCaptureDeviceDiscoverySession (Utilities)

- (NSInteger)uniqueDevicePositionsCount;

@end

@implementation AVCaptureDeviceDiscoverySession (Utilities)

- (NSInteger)uniqueDevicePositionsCount
{
    NSMutableArray<NSNumber* >* uniqueDevicePositions = [NSMutableArray array];
    
    for (AVCaptureDevice* device in self.devices) {
        if (![uniqueDevicePositions containsObject:@(device.position)]) {
            [uniqueDevicePositions addObject:@(device.position)];
        }
    }
    
    return uniqueDevicePositions.count;
}

@end

@interface AVCamCameraViewController () <AVCaptureFileOutputRecordingDelegate, AVCapturePhotoOutputReadinessCoordinatorDelegate>
{
    UIInterfaceOrientationMask _supportedInterfaceOrientations;
}

// Session management.
@property (nonatomic, weak) IBOutlet AVCamPreviewView* previewView;
@property (nonatomic, weak) IBOutlet UISegmentedControl* captureModeControl;

@property (nonatomic) AVCamSetupResult setupResult;
@property (nonatomic) dispatch_queue_t sessionQueue;
@property (nonatomic) AVCaptureSession* session;
@property (nonatomic, getter=isSessionRunning) BOOL sessionRunning;
@property (nonatomic) AVCaptureDeviceInput* videoDeviceInput;

// Device configuration.
@property (nonatomic, weak) IBOutlet UIButton* cameraButton;
@property (nonatomic, weak) IBOutlet UILabel* cameraUnavailableLabel;
@property (nonatomic) AVCaptureDeviceDiscoverySession* videoDeviceDiscoverySession;
@property (nonatomic) AVCaptureDeviceRotationCoordinator* videoDeviceRotationCoordinator;

// Capturing photos.
@property (nonatomic, weak) IBOutlet UIButton* photoButton;
@property (nonatomic, weak) IBOutlet UIButton* livePhotoModeButton;
@property (nonatomic) AVCamLivePhotoMode livePhotoMode;
@property (nonatomic, weak) IBOutlet UILabel* capturingLivePhotoLabel;
@property (nonatomic, weak) IBOutlet UISegmentedControl *photoQualityPrioritizationSegControl;
@property (nonatomic) AVCapturePhotoQualityPrioritization photoQualityPrioritizationMode;
@property (nonatomic, weak) IBOutlet UIButton* HDRVideoModeButton;
@property (nonatomic) AVCamHDRVideoMode HDRVideoMode;
@property (nonatomic) AVCapturePhotoOutputReadinessCoordinator* photoOutputReadinessCoordinator;
@property (nonatomic) AVCapturePhotoSettings* photoSettings;

@property (nonatomic) AVCapturePhotoOutput* photoOutput;
@property (nonatomic) NSMutableDictionary<NSNumber* , AVCamPhotoCaptureDelegate* >* inProgressPhotoCaptureDelegates;
@property (nonatomic) NSInteger inProgressLivePhotoCapturesCount;

@property (nonatomic) CLLocationManager *locationManager;

// Recording movies.
@property (nonatomic, weak) IBOutlet UIButton* recordButton;
@property (nonatomic, weak) IBOutlet UIButton* resumeButton;

@property (nonatomic, strong) AVCaptureMovieFileOutput* movieFileOutput;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundRecordingID;
@property (nonatomic) AVCaptureDeviceFormat *selectedMovieMode10BitDeviceFormat;

@property (nonatomic, readwrite) UIInterfaceOrientationMask supportedInterfaceOrientations;

@end

@implementation AVCamCameraViewController

- (instancetype) initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        _supportedInterfaceOrientations = UIInterfaceOrientationMaskAll;
    }
    return self;
}

#pragma mark View Controller Life Cycle

- (void) viewDidLoad
{
    [super viewDidLoad];
    
    // Disable UI. The UI is enabled if and only if the session starts running.
    self.cameraButton.enabled = NO;
    self.recordButton.enabled = NO;
    self.photoButton.enabled = NO;
    self.livePhotoModeButton.enabled = NO;
    self.captureModeControl.enabled = NO;
    self.photoQualityPrioritizationSegControl.enabled = NO;
    self.HDRVideoModeButton.hidden = YES;
    
    // Create the AVCaptureSession.
    self.session = [[AVCaptureSession alloc] init];
    
    // Create a device discovery session.
    NSArray<AVCaptureDeviceType>* deviceTypes = @[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInDualCamera, AVCaptureDeviceTypeBuiltInTrueDepthCamera];
    self.videoDeviceDiscoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
    
    // Set up the preview view.
    self.previewView.session = self.session;
    
    // Communicate with the session and other session objects on this queue.
    self.sessionQueue = dispatch_queue_create("session queue", DISPATCH_QUEUE_SERIAL);
    
    self.setupResult = AVCamSetupResultSuccess;
    
    // Request location authorization so photos and videos can be tagged with
    // their location.
    self.locationManager = [[CLLocationManager alloc] init];
    if (self.locationManager.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
        [self.locationManager requestWhenInUseAuthorization];
    }
    
    /*
     Check video authorization status. Video access is required and audio
     access is optional. If audio access is denied, audio is not recorded
     during movie recording.
    */
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo])
    {
        case AVAuthorizationStatusAuthorized:
        {
            // The user has previously granted access to the camera.
            break;
        }
        case AVAuthorizationStatusNotDetermined:
        {
            /*
             The user has not yet been presented with the option to grant
             video access. We suspend the session queue to delay session
             setup until the access request has completed.
             
             Note that audio access will be implicitly requested when we
             create an AVCaptureDeviceInput for audio during session setup.
            */
            dispatch_suspend(self.sessionQueue);
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                if (!granted) {
                    self.setupResult = AVCamSetupResultCameraNotAuthorized;
                }
                dispatch_resume(self.sessionQueue);
            }];
            break;
        }
        default:
        {
            // The user has previously denied access.
            self.setupResult = AVCamSetupResultCameraNotAuthorized;
            break;
        }
    }
    
    /*
     Setup the capture session.
     In general, it is not safe to mutate an AVCaptureSession or any of its
     inputs, outputs, or connections from multiple threads at the same time.
     
     Don't perform these tasks on the main queue because
     AVCaptureSession.startRunning() is a blocking call, which can
     take a long time. We dispatch session setup to the sessionQueue, so
     that the main queue isn't blocked, which keeps the UI responsive.
    */
    dispatch_async(self.sessionQueue, ^{
        [self configureSession];
    });
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    dispatch_async(self.sessionQueue, ^{
        switch (self.setupResult)
        {
            case AVCamSetupResultSuccess:
            {
                // Only setup observers and start the session running if setup
                // succeeded.
                [self addObservers];
                [self.session startRunning];
                self.sessionRunning = self.session.isRunning;
                break;
            }
            case AVCamSetupResultCameraNotAuthorized:
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString* message = NSLocalizedString(@"AVCam doesn't have permission to use the camera, please change privacy settings", @"Alert message when the user has denied access to the camera");
                    UIAlertController* alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", @"Alert OK button") style:UIAlertActionStyleCancel handler:nil];
                    [alertController addAction:cancelAction];
                    // Provide quick access to Settings.
                    UIAlertAction* settingsAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Settings", @"Alert button to open Settings") style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
                        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
                    }];
                    [alertController addAction:settingsAction];
                    [self presentViewController:alertController animated:YES completion:nil];
                });
                break;
            }
            case AVCamSetupResultSessionConfigurationFailed:
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString* message = NSLocalizedString(@"Unable to capture media", @"Alert message when something goes wrong during capture session configuration");
                    UIAlertController* alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", @"Alert OK button") style:UIAlertActionStyleCancel handler:nil];
                    [alertController addAction:cancelAction];
                    [self presentViewController:alertController animated:YES completion:nil];
                });
                break;
            }
        }
    });
}

- (void) viewDidDisappear:(BOOL)animated
{
    dispatch_async(self.sessionQueue, ^{
        if (self.setupResult == AVCamSetupResultSuccess) {
            [self.session stopRunning];
            [self removeObservers];
        }
    });
    
    [super viewDidDisappear:animated];
}

- (UIInterfaceOrientationMask) supportedInterfaceOrientations
{
    return _supportedInterfaceOrientations;
}

- (void) setSupportedInterfaceOrientations:(UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    _supportedInterfaceOrientations = supportedInterfaceOrientations;
}

#pragma mark Session Management

// Call this on the session queue.
- (void) configureSession
{
    if (self.setupResult != AVCamSetupResultSuccess) {
        return;
    }
    
    NSError* error = nil;
    
    [self.session beginConfiguration];
    
    // We do not create an AVCaptureMovieFileOutput when setting up the session
    // because Live Photo is not supported when AVCaptureMovieFileOutput is
    // added to the session.
    self.session.sessionPreset = AVCaptureSessionPresetPhoto;
    
    // Handle the situation when the system-preferred camera is nil.
    AVCaptureDevice *videoDevice = AVCaptureDevice.systemPreferredCamera;
    
    NSUserDefaults *userDefaults = NSUserDefaults.standardUserDefaults;
    if (![userDefaults boolForKey:@"setInitialUserPreferredCamera"] || !videoDevice) {
        AVCaptureDeviceDiscoverySession *backVideoDeviceDiscoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInDualCamera, AVCaptureDeviceTypeBuiltInWideAngleCamera] mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
        
        videoDevice = backVideoDeviceDiscoverySession.devices.firstObject;
        
        AVCaptureDevice.userPreferredCamera = videoDevice;
        
        [userDefaults setBool:YES forKey:@"setInitialUserPreferredCamera"];
    }
    
    AVCaptureDeviceInput* videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
    if (!videoDeviceInput) {
        NSLog(@"Could not create video device input: %@", error);
        self.setupResult = AVCamSetupResultSessionConfigurationFailed;
        [self.session commitConfiguration];
        return;
    }
    
    [AVCaptureDevice addObserver:self forKeyPath:@"systemPreferredCamera" options:NSKeyValueObservingOptionNew context:SystemPreferredCameraContext];
    
    if ([self.session canAddInput:videoDeviceInput]) {
        [self.session addInput:videoDeviceInput];
        self.videoDeviceInput = videoDeviceInput;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Dispatch video streaming to the main queue because
            // AVCaptureVideoPreviewLayer is the backing layer for PreviewView.
            // You can manipulate UIView only on the main thread. Note: As an
            // exception to the above rule, it is not necessary to serialize
            // video orientation changes on the AVCaptureVideoPreviewLayer’s
            // connection with other session manipulation.
            [self createDeviceRotationCoordinator];
        });
    }
    else {
        NSLog(@"Could not add video device input to the session");
        self.setupResult = AVCamSetupResultSessionConfigurationFailed;
        [self.session commitConfiguration];
        return;
    }
    
    // Add audio input.
    AVCaptureDevice* audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    AVCaptureDeviceInput* audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];
    if (!audioDeviceInput) {
        NSLog(@"Could not create audio device input: %@", error);
    }
    if ([self.session canAddInput:audioDeviceInput]) {
        [self.session addInput:audioDeviceInput];
    }
    else {
        NSLog(@"Could not add audio device input to the session");
    }
    
    // Add photo output.
    AVCapturePhotoOutput* photoOutput = [[AVCapturePhotoOutput alloc] init];
    if ([self.session canAddOutput:photoOutput]) {
        [self.session addOutput:photoOutput];
        self.photoOutput = photoOutput;
        
        self.livePhotoMode = self.photoOutput.livePhotoCaptureSupported ? AVCamLivePhotoModeOn : AVCamLivePhotoModeOff;
        self.photoQualityPrioritizationMode = AVCapturePhotoQualityPrioritizationBalanced;
        
        self.inProgressPhotoCaptureDelegates = [NSMutableDictionary dictionary];
        self.inProgressLivePhotoCapturesCount = 0;

        [self configurePhotoOutput];
    
        AVCapturePhotoOutputReadinessCoordinator *readinessCoordinator = [[AVCapturePhotoOutputReadinessCoordinator alloc] initWithPhotoOutput:photoOutput];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.photoOutputReadinessCoordinator = readinessCoordinator;
            readinessCoordinator.delegate = self;
        });
    }
    else {
        NSLog(@"Could not add photo output to the session");
        self.setupResult = AVCamSetupResultSessionConfigurationFailed;
        [self.session commitConfiguration];
        return;
    }
    
    self.backgroundRecordingID = UIBackgroundTaskInvalid;
    self.selectedMovieMode10BitDeviceFormat = nil;
    
    [self.session commitConfiguration];
}

- (IBAction) resumeInterruptedSession:(id)sender
{
    dispatch_async(self.sessionQueue, ^{
        // The session might fail to start running, e.g., if a phone or FaceTime
        // call is still using audio or video. A failure to start the session
        // running will be communicated via a session runtime error
        // notification. To avoid repeatedly failing to start the session
        // running, we only try to restart the session running in the session
        // runtime error handler if we aren't trying to resume the
        // session running.
        [self.session startRunning];
        self.sessionRunning = self.session.isRunning;
        if (!self.session.isRunning) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString* message = NSLocalizedString(@"Unable to resume", @"Alert message when unable to resume the session running");
                UIAlertController* alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", @"Alert OK button") style:UIAlertActionStyleCancel handler:nil];
                [alertController addAction:cancelAction];
                [self presentViewController:alertController animated:YES completion:nil];
            });
        }
        else {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.resumeButton.hidden = YES;
            });
        }
    });
}

- (AVCaptureDeviceFormat *) tenBitVariantOfFormat:(AVCaptureDeviceFormat *)activeFormat
{
    NSArray<AVCaptureDeviceFormat *> *formats = self.videoDeviceInput.device.formats;
    NSUInteger formatIndex = [formats indexOfObject:activeFormat];
    
    CMVideoDimensions activeDimensions = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription);
    Float64 activeMaxFrameRate = activeFormat.videoSupportedFrameRateRanges.lastObject.maxFrameRate;
    FourCharCode activePixelFormat = CMFormatDescriptionGetMediaSubType(activeFormat.formatDescription);
    
    // AVCaptureDeviceFormats are sorted from smallest to largest in resolution
    // and frame rate. For each resolution and max frame rate there's a cluster
    // of formats that only differ in pixelFormatType. Here, we're looking for
    // an 'x420' variant of the current activeFormat.
    if (activePixelFormat != kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
        // Current activeFormat is not a 10-bit HDR format, find its 10-bit HDR
        // variant.
        for (NSUInteger index = formatIndex + 1; index < formats.count; index++) {
            AVCaptureDeviceFormat *format = formats[index];
            CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            Float64 maxFrameRate = format.videoSupportedFrameRateRanges.lastObject.maxFrameRate;
            FourCharCode pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription);
            
            // Don't advance beyond the current format cluster
            if (activeMaxFrameRate != maxFrameRate || activeDimensions.width != dimensions.width || activeDimensions.height != dimensions.height) {
                break;
            }
            
            if (pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
                return format;
            }
        }
    }
    else
    {
        return activeFormat;
    }
    
    return nil;
}
    
- (IBAction) toggleCaptureMode:(UISegmentedControl*)captureModeControl
{
    if (captureModeControl.selectedSegmentIndex == AVCamCaptureModePhoto) {
        self.recordButton.enabled = NO;
        self.HDRVideoModeButton.hidden = YES;
        self.selectedMovieMode10BitDeviceFormat = nil;
        
        dispatch_async(self.sessionQueue, ^{
            // Remove the AVCaptureMovieFileOutput from the session because Live
            // Photo capture is not supported when an AVCaptureMovieFileOutput
            // is connected to the session.
            [self.session beginConfiguration];
            [self.session removeOutput:self.movieFileOutput];
            self.session.sessionPreset = AVCaptureSessionPresetPhoto;
            
            self.movieFileOutput = nil;
            
            [self configurePhotoOutput];
            BOOL livePhotoCaptureEnabled = self.photoOutput.livePhotoCaptureEnabled;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                self.livePhotoModeButton.hidden = NO;
                self.livePhotoModeButton.enabled = livePhotoCaptureEnabled;
                self.photoQualityPrioritizationSegControl.hidden = NO;
                self.photoQualityPrioritizationSegControl.enabled = YES;
            });
            
            [self.session commitConfiguration];
        });
    }
    else if (captureModeControl.selectedSegmentIndex == AVCamCaptureModeMovie) {
        self.livePhotoModeButton.hidden = YES;
        self.photoQualityPrioritizationSegControl.hidden = YES;
        
        dispatch_async(self.sessionQueue, ^{
            AVCaptureMovieFileOutput* movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];
            
            if ([self.session canAddOutput:movieFileOutput])
            {
                [self.session beginConfiguration];
                [self.session addOutput:movieFileOutput];
                self.session.sessionPreset = AVCaptureSessionPresetHigh;
                
                self.selectedMovieMode10BitDeviceFormat = [self tenBitVariantOfFormat:self.videoDeviceInput.device.activeFormat];

                if (self.selectedMovieMode10BitDeviceFormat) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.HDRVideoModeButton.hidden = NO;
                        self.HDRVideoModeButton.enabled = YES;
                    });
                    
                    if (self.HDRVideoMode == AVCamHDRVideoModeOn) {
                        NSError* error = nil;
                        if ([self.videoDeviceInput.device lockForConfiguration:&error]) {
                            self.videoDeviceInput.device.activeFormat = self.selectedMovieMode10BitDeviceFormat;
                            NSLog(@"Setting 'x420' format (%@) for video recording.", self.selectedMovieMode10BitDeviceFormat);
                            [self.videoDeviceInput.device unlockForConfiguration];
                        }
                        else {
                            NSLog(@"Could not lock device for configuration: %@", error);
                        }
                    }
                }
                
                AVCaptureConnection* connection = [movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
                if (connection.isVideoStabilizationSupported) {
                    connection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
                }
                [self.session commitConfiguration];
                
                self.movieFileOutput = movieFileOutput;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.recordButton.enabled = YES;
                    
                    // For photo captures during movie recording, Balanced
                    // quality photo processing is prioritized to get high
                    // quality stills and avoid frame drops during recording.
                    self.photoQualityPrioritizationSegControl.selectedSegmentIndex = 1;
                    [self.photoQualityPrioritizationSegControl sendActionsForControlEvents:UIControlEventValueChanged];
                });
            }
        });
    }
}

- (void) configurePhotoOutput
{
    NSArray<NSValue *> *supportedMaxPhotoDimensions = self.videoDeviceInput.device.activeFormat.supportedMaxPhotoDimensions;
    CMVideoDimensions largestDimension = supportedMaxPhotoDimensions.lastObject.CMVideoDimensionsValue;
    self.photoOutput.maxPhotoDimensions = largestDimension;
    self.photoOutput.livePhotoCaptureEnabled = self.photoOutput.livePhotoCaptureSupported;
    self.photoOutput.maxPhotoQualityPrioritization = AVCapturePhotoQualityPrioritizationQuality;
    self.photoOutput.responsiveCaptureEnabled = self.photoOutput.responsiveCaptureSupported;
    self.photoOutput.fastCapturePrioritizationEnabled = self.photoOutput.fastCapturePrioritizationSupported;
    self.photoOutput.autoDeferredPhotoDeliveryEnabled = self.photoOutput.autoDeferredPhotoDeliverySupported;
    
    AVCapturePhotoSettings *photoSettings = [self setUpPhotoSettings];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.photoSettings = photoSettings;
    });
}

#pragma mark Device Configuration

- (IBAction) changeCameraButtonPressed:(id)sender
{
    self.cameraButton.enabled = NO;
    self.recordButton.enabled = NO;
    self.photoButton.enabled = NO;
    self.livePhotoModeButton.enabled = NO;
    self.captureModeControl.enabled = NO;
    self.photoQualityPrioritizationSegControl.enabled = NO;
    self.HDRVideoModeButton.enabled = NO;
    self.selectedMovieMode10BitDeviceFormat = nil;
    
    [self changeCamera:nil isUserSelection:YES completion:^{
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.cameraButton.enabled = YES;
            self.recordButton.enabled = self.captureModeControl.selectedSegmentIndex == AVCamCaptureModeMovie;
            self.photoButton.enabled = YES;
            self.livePhotoModeButton.enabled = YES;
            self.captureModeControl.enabled = YES;
            self.photoQualityPrioritizationSegControl.enabled = YES;
        });
    }];
}
 
- (void)changeCamera:(AVCaptureDevice *)videoDevice isUserSelection:(BOOL)isUserSelection completion:(dispatch_block_t)completion
{
    dispatch_async(self.sessionQueue, ^{
        AVCaptureDevice* currentVideoDevice = self.videoDeviceInput.device;
        AVCaptureDevice *newVideoDevice = nil;
        
        if (videoDevice) {
            newVideoDevice = videoDevice;
        }
        else {
            AVCaptureDevicePosition currentPosition = currentVideoDevice.position;
            
            AVCaptureDeviceDiscoverySession *backVideoDeviceDiscoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInDualCamera, AVCaptureDeviceTypeBuiltInWideAngleCamera] mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
            AVCaptureDeviceDiscoverySession *frontVideoDeviceDiscoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInTrueDepthCamera, AVCaptureDeviceTypeBuiltInWideAngleCamera] mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionFront];
            AVCaptureDeviceDiscoverySession *externalVideoDeviceDiscoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal] mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
            
            switch (currentPosition)
            {
                case AVCaptureDevicePositionUnspecified:
                case AVCaptureDevicePositionFront:
                    newVideoDevice = backVideoDeviceDiscoverySession.devices.firstObject;
                    break;
                case AVCaptureDevicePositionBack:
                    if (externalVideoDeviceDiscoverySession.devices.count > 0) {
                        newVideoDevice = externalVideoDeviceDiscoverySession.devices.firstObject;
                    }
                    else {
                        newVideoDevice = frontVideoDeviceDiscoverySession.devices.firstObject;
                    }
                    break;
                default:
                    NSLog(@"Unknown capture position. Defaulting to back, dual-camera.");
                    newVideoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInDualCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
            }
        }

        if (newVideoDevice && (newVideoDevice != self.videoDeviceInput.device)) {
            
            AVCaptureDeviceInput* videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:newVideoDevice error:NULL];
            
            [self.session beginConfiguration];
            
            // Remove the existing device input first, because using the front
            // and back camera simultaneously is not supported.
            [self.session removeInput:self.videoDeviceInput];
            
            if ([self.session canAddInput:videoDeviceInput]) {
                [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:currentVideoDevice];
                
                [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:newVideoDevice];
                
                [self.session addInput:videoDeviceInput];
                self.videoDeviceInput = videoDeviceInput;
                
                if (isUserSelection) {
                    AVCaptureDevice.userPreferredCamera = newVideoDevice;
                }
				
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self createDeviceRotationCoordinator];
                });
            }
            else {
                [self.session addInput:self.videoDeviceInput];
            }
            
            // If mode is AVCamCaptureModeMovie
            AVCaptureConnection* movieFileOutputConnection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
            if (movieFileOutputConnection) {
                self.session.sessionPreset = AVCaptureSessionPresetHigh;
                self.selectedMovieMode10BitDeviceFormat = [self tenBitVariantOfFormat:self.videoDeviceInput.device.activeFormat];

                if (self.selectedMovieMode10BitDeviceFormat) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.HDRVideoModeButton.enabled = YES;
                    });
                    
                    if (self.HDRVideoMode == AVCamHDRVideoModeOn) {
                        NSError* error = nil;
                        if ([self.videoDeviceInput.device lockForConfiguration:&error]) {
                            self.videoDeviceInput.device.activeFormat = self.selectedMovieMode10BitDeviceFormat;
                            NSLog(@"Setting 'x420' format (%@) for video recording.", self.selectedMovieMode10BitDeviceFormat);
                            [self.videoDeviceInput.device unlockForConfiguration];
                        }
                        else {
                            NSLog(@"Could not lock device for configuration: %@", error);
                        }
                    }
                }
                
                if (movieFileOutputConnection.isVideoStabilizationSupported) {
                    movieFileOutputConnection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
                }
            }
            
            // `livePhotoCaptureEnabled` and other properties of the
            // `AVCapturePhotoOutput` are `NO` when a video device disconnects
            // from the session. After the session acquires a new video device,
            // you need to reconfigure the photo output to enable those
            // properties, if applicable.
            [self configurePhotoOutput];
            
            [self.session commitConfiguration];
        }

        if (completion) {
            completion();
        }
    });
}

- (void)createDeviceRotationCoordinator
{
    self.videoDeviceRotationCoordinator = [[AVCaptureDeviceRotationCoordinator alloc] initWithDevice:self.videoDeviceInput.device previewLayer:self.previewView.videoPreviewLayer];
    self.previewView.videoPreviewLayer.connection.videoRotationAngle = self.videoDeviceRotationCoordinator.videoRotationAngleForHorizonLevelPreview;
    
    [self.videoDeviceRotationCoordinator addObserver:self forKeyPath:@"videoRotationAngleForHorizonLevelPreview" options:NSKeyValueObservingOptionNew context:VideoRotationAngleForHorizonLevelPreviewContext];
}

- (IBAction) focusAndExposeTap:(UIGestureRecognizer*)gestureRecognizer
{
    CGPoint devicePoint = [self.previewView.videoPreviewLayer captureDevicePointOfInterestForPoint:[gestureRecognizer locationInView:gestureRecognizer.view]];
    [self focusWithMode:AVCaptureFocusModeAutoFocus exposeWithMode:AVCaptureExposureModeAutoExpose atDevicePoint:devicePoint monitorSubjectAreaChange:YES];
}

- (void) focusWithMode:(AVCaptureFocusMode)focusMode
        exposeWithMode:(AVCaptureExposureMode)exposureMode
         atDevicePoint:(CGPoint)point
monitorSubjectAreaChange:(BOOL)monitorSubjectAreaChange
{
    dispatch_async(self.sessionQueue, ^{
        AVCaptureDevice* device = self.videoDeviceInput.device;
        NSError* error = nil;
        if ([device lockForConfiguration:&error]) {
            // Setting (focus/exposure)PointOfInterest alone does not initiate a
            // (focus/exposure) operation.
            // Call set(Focus/Exposure)Mode() to apply the new point of
            // interest.
            if (device.isFocusPointOfInterestSupported && [device isFocusModeSupported:focusMode]) {
                device.focusPointOfInterest = point;
                device.focusMode = focusMode;
            }
            
            if (device.isExposurePointOfInterestSupported && [device isExposureModeSupported:exposureMode]) {
                device.exposurePointOfInterest = point;
                device.exposureMode = exposureMode;
            }
            
            device.subjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange;
            [device unlockForConfiguration];
        }
        else {
            NSLog(@"Could not lock device for configuration: %@", error);
        }
    });
}

#pragma mark Readiness Coordinator

- (void) readinessCoordinator:(AVCapturePhotoOutputReadinessCoordinator *)coordinator captureReadinessDidChange:(AVCapturePhotoOutputCaptureReadiness)captureReadiness
{
    // Enable user interaction for the shutter button only when the output is
    // ready to capture.
    self.photoButton.userInteractionEnabled = (captureReadiness == AVCapturePhotoOutputCaptureReadinessReady) ? YES : NO;
    
    // Note: You can customize the shutter button's appearance based on
    // `captureReadiness`.
}

#pragma mark Capturing Photos

- (IBAction) capturePhoto:(id)sender
{
    if (self.photoSettings == nil) {
        NSLog(@"No photo settings to capture");
        return;
    }
    
    // Create a unique settings object for this request.
    AVCapturePhotoSettings* photoSettings = [AVCapturePhotoSettings photoSettingsFromPhotoSettings:self.photoSettings];

    // Provide a unique temporary URL because Live Photo captures can overlap.
    if (photoSettings.livePhotoMovieFileURL) {
        photoSettings.livePhotoMovieFileURL = [self livePhotoMovieUniqueTemporaryDirectoryFileURL];
    }
    
    // Start tracking capture readiness on the main thread to synchronously
    // update the shutter button's availability and appearance to include this
    // request.
    [self.photoOutputReadinessCoordinator startTrackingCaptureRequestUsingPhotoSettings:photoSettings];
    
    CGFloat videoRotationAngle = self.videoDeviceRotationCoordinator.videoRotationAngleForHorizonLevelCapture;
    
    dispatch_async(self.sessionQueue, ^{
        
        AVCaptureConnection* photoOutputConnection = [self.photoOutput connectionWithMediaType:AVMediaTypeVideo];
        photoOutputConnection.videoRotationAngle = videoRotationAngle;
        
        // Use a separate object for the photo capture delegate to isolate each
        // capture life cycle.
        AVCamPhotoCaptureDelegate* photoCaptureDelegate = [[AVCamPhotoCaptureDelegate alloc] initWithRequestedPhotoSettings:photoSettings willCapturePhotoAnimation:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                self.previewView.videoPreviewLayer.opacity = 0.0;
                [UIView animateWithDuration:0.25 animations:^{
                    self.previewView.videoPreviewLayer.opacity = 1.0;
                }];
            });
        } livePhotoCaptureHandler:^(BOOL capturing) {
            // Because Live Photo captures can overlap, we need to keep track of
            // the number of in progress Live Photo captures to ensure that the
            // Live Photo label stays visible during these captures.
            dispatch_async(self.sessionQueue, ^{
                if (capturing) {
                    self.inProgressLivePhotoCapturesCount++;
                }
                else {
                    self.inProgressLivePhotoCapturesCount--;
                }
                
                NSInteger inProgressLivePhotoCapturesCount = self.inProgressLivePhotoCapturesCount;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (inProgressLivePhotoCapturesCount > 0) {
                        self.capturingLivePhotoLabel.hidden = NO;
                    }
                    else if (inProgressLivePhotoCapturesCount == 0) {
                        self.capturingLivePhotoLabel.hidden = YES;
                    }
                    else {
                        NSLog(@"Error: In progress Live Photo capture count is less than 0.");
                    }
                });
            });
        } completionHandler:^(AVCamPhotoCaptureDelegate* photoCaptureDelegate) {
            // When the capture is complete, remove a reference to the photo
            // capture delegate so it can be deallocated.
            dispatch_async(self.sessionQueue, ^{
                self.inProgressPhotoCaptureDelegates[@(photoCaptureDelegate.requestedPhotoSettings.uniqueID)] = nil;
            });
        }];
        
        // Specify the location the photo was taken
        photoCaptureDelegate.location = self.locationManager.location;
        
        // The Photo Output keeps a weak reference to the photo capture delegate
        // so we store it in an array to maintain a strong reference to this
        // object until the capture is completed.
        self.inProgressPhotoCaptureDelegates[@(photoCaptureDelegate.requestedPhotoSettings.uniqueID)] = photoCaptureDelegate;
        
        [self.photoOutput capturePhotoWithSettings:photoSettings delegate:photoCaptureDelegate];
    
        // Stop tracking the capture request because it's now destined for the
        // photo output.
        [self.photoOutputReadinessCoordinator stopTrackingCaptureRequestUsingPhotoSettingsUniqueID:photoSettings.uniqueID];
    });
}

- (AVCapturePhotoSettings *) setUpPhotoSettings
{
    AVCapturePhotoSettings* photoSettings;
    
    // Capture HEIF photos when supported.
    if ([self.photoOutput.availablePhotoCodecTypes containsObject:AVVideoCodecTypeHEVC]) {
        photoSettings = [AVCapturePhotoSettings photoSettingsWithFormat:@{ AVVideoCodecKey : AVVideoCodecTypeHEVC }];
    }
    else {
        photoSettings = [AVCapturePhotoSettings photoSettings];
    }
    
    // Set the flash to auto mode.
    if (self.videoDeviceInput.device.isFlashAvailable) {
        photoSettings.flashMode = AVCaptureFlashModeAuto;
    }
    
    // Enable high-resolution photos.
    photoSettings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions;
    if (photoSettings.availablePreviewPhotoPixelFormatTypes.count > 0) {
        photoSettings.previewPhotoFormat = @{ (NSString*)kCVPixelBufferPixelFormatTypeKey : photoSettings.availablePreviewPhotoPixelFormatTypes.firstObject };
    }
    // Live Photo capture is not supported in movie mode.
    if (self.livePhotoMode == AVCamLivePhotoModeOn && self.photoOutput.livePhotoCaptureSupported) {
        photoSettings.livePhotoMovieFileURL = [self livePhotoMovieUniqueTemporaryDirectoryFileURL];
    }
    
    photoSettings.photoQualityPrioritization = self.photoQualityPrioritizationMode;
    
    return photoSettings;
}

- (NSURL *)livePhotoMovieUniqueTemporaryDirectoryFileURL
{
    NSString* livePhotoMovieFileName = [NSUUID UUID].UUIDString;
    NSString* livePhotoMovieFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[livePhotoMovieFileName stringByAppendingPathExtension:@"mov"]];
    return [NSURL fileURLWithPath:livePhotoMovieFilePath];
}

- (IBAction) toggleLivePhotoMode:(UIButton*)livePhotoModeButton
{
    dispatch_async(self.sessionQueue, ^{
        self.livePhotoMode = (self.livePhotoMode == AVCamLivePhotoModeOn) ? AVCamLivePhotoModeOff : AVCamLivePhotoModeOn;
        AVCamLivePhotoMode livePhotoMode = self.livePhotoMode;
        
        // Update `photoSettings` to include `livePhotoMode`.
        AVCapturePhotoSettings *photoSettings = [self setUpPhotoSettings];
    
        dispatch_async(dispatch_get_main_queue(), ^{
            if (livePhotoMode == AVCamLivePhotoModeOn) {
                [self.livePhotoModeButton setImage:[UIImage imageNamed:@"LivePhotoON"] forState:UIControlStateNormal];
            }
            else {
                [self.livePhotoModeButton setImage:[UIImage imageNamed:@"LivePhotoOFF"] forState:UIControlStateNormal];
            }
            self.photoSettings = photoSettings;
        });
    });
}

- (IBAction) togglePhotoQualityPrioritizationMode:(UISegmentedControl*)photoQualityPrioritizationSegControl
{
    NSInteger selectedQuality = photoQualityPrioritizationSegControl.selectedSegmentIndex;
    dispatch_async(self.sessionQueue, ^{
        switch (selectedQuality) {
            case 0:
                self.photoQualityPrioritizationMode = AVCapturePhotoQualityPrioritizationSpeed;
                break;
            case 1:
                self.photoQualityPrioritizationMode = AVCapturePhotoQualityPrioritizationBalanced;
                break;
            case 2:
                self.photoQualityPrioritizationMode = AVCapturePhotoQualityPrioritizationQuality;
                break;
            default:
                break;
        }
    
        // Update `photoSettings` to include `photoQualityPrioritizationMode`.
        AVCapturePhotoSettings *photoSettings = [self setUpPhotoSettings];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.photoSettings = photoSettings;
        });
    });
}

- (IBAction) toggleHDRVideoMode:(UIButton*)HDRVideoModeButton
{
    dispatch_async(self.sessionQueue, ^{
        self.HDRVideoMode = (self.HDRVideoMode == AVCamHDRVideoModeOn) ? AVCamHDRVideoModeOff : AVCamHDRVideoModeOn;
        AVCamHDRVideoMode HDRVideoMode = self.HDRVideoMode;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (HDRVideoMode == AVCamHDRVideoModeOn) {
                NSError* error = nil;
                if ([self.videoDeviceInput.device lockForConfiguration:&error]) {
                    self.videoDeviceInput.device.activeFormat = self.selectedMovieMode10BitDeviceFormat;
                    [self.videoDeviceInput.device unlockForConfiguration];
                }
                else {
                    NSLog(@"Could not lock device for configuration: %@", error);
                }
                [self.HDRVideoModeButton setTitle:@"HDR On" forState:UIControlStateNormal];
            }
            else
            {
                [self.session beginConfiguration];
                self.session.sessionPreset = AVCaptureSessionPresetHigh;
                [self.session commitConfiguration];
                [self.HDRVideoModeButton setTitle:@"HDR Off" forState:UIControlStateNormal];
            }
        });
    });
}

#pragma mark Recording Movies

- (IBAction) toggleMovieRecording:(id)sender
{
    /*
     Disable the Camera button until recording finishes, and disable
     the Record button until recording starts or finishes.
     
     See the AVCaptureFileOutputRecordingDelegate methods.
    */
    self.cameraButton.enabled = NO;
    self.recordButton.enabled = NO;
    self.captureModeControl.enabled = NO;
    
    CGFloat videoRotationAngle = self.videoDeviceRotationCoordinator.videoRotationAngleForHorizonLevelCapture;
    
    // Lock the interface to the current orientation.
    self.supportedInterfaceOrientations = 1 << self.view.window.windowScene.interfaceOrientation;
    [self setNeedsUpdateOfSupportedInterfaceOrientations];
    
    dispatch_async(self.sessionQueue, ^{
        if (!self.movieFileOutput.isRecording) {
            if ([UIDevice currentDevice].isMultitaskingSupported) {
                // Setup background task. This is needed because the
                // -[captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:]
                // callback is not received until AVCam returns to the
                // foreground unless you request background execution time. This
                // also ensures that there will be time to write the file to the
                // photo library when AVCam is backgrounded. To conclude this
                // background execution, -[endBackgroundTask:] is called in
                // -[captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:]
                // after the recorded file has been saved.
                self.backgroundRecordingID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
            }
            
            // Update the orientation on the movie file output video connection
            // before starting recording.
            AVCaptureConnection* movieFileOutputConnection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
            movieFileOutputConnection.videoRotationAngle = videoRotationAngle;
            
            // Use HEVC codec, if supported.
            if ([self.movieFileOutput.availableVideoCodecTypes containsObject:AVVideoCodecTypeHEVC]) {
                [self.movieFileOutput setOutputSettings:@{ AVVideoCodecKey : AVVideoCodecTypeHEVC } forConnection:movieFileOutputConnection];
            }
            
            // Start recording to a temporary file.
            NSString* outputFileName = [NSUUID UUID].UUIDString;
            NSString* outputFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[outputFileName stringByAppendingPathExtension:@"mov"]];
            NSURL* outputURL = [NSURL fileURLWithPath:outputFilePath];
            [self.movieFileOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
        }
        else {
            [self.movieFileOutput stopRecording];
        }
    });
}

- (void) captureOutput:(AVCaptureFileOutput*)captureOutput
didStartRecordingToOutputFileAtURL:(NSURL*)fileURL
       fromConnections:(NSArray*)connections
{
    // Enable the Record button to let the user stop recording.
    dispatch_async(dispatch_get_main_queue(), ^{
        self.recordButton.enabled = YES;
        [self.recordButton setImage:[UIImage imageNamed:@"CaptureStop"] forState:UIControlStateNormal];
    });
}

- (void) captureOutput:(AVCaptureFileOutput*)captureOutput
didFinishRecordingToOutputFileAtURL:(NSURL*)outputFileURL
       fromConnections:(NSArray*)connections
                 error:(NSError*)error
{
    // currentBackgroundRecordingID is used to end the background task
    // associated with the current recording. It allows a new recording to be
    // started and associated with a new UIBackgroundTaskIdentifier, once the
    // movie file output's `recording` property is back to NO. Because a unique
    // file path for each recording is used, a new recording will not overwrite
    // a recording currently being saved.
    UIBackgroundTaskIdentifier currentBackgroundRecordingID = self.backgroundRecordingID;
    self.backgroundRecordingID = UIBackgroundTaskInvalid;
    
    dispatch_block_t cleanUp = ^{
        if ([[NSFileManager defaultManager] fileExistsAtPath:outputFileURL.path]) {
            [[NSFileManager defaultManager] removeItemAtPath:outputFileURL.path error:NULL];
        }
        
        if (currentBackgroundRecordingID != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:currentBackgroundRecordingID];
        }
    };
    
    BOOL success = YES;
    
    if (error) {
        NSLog(@"Movie file finishing error: %@", error);
        success = [error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] boolValue];
    }
    if (success) {
        // Check authorization status.
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized) {
                // Save the movie file to the photo library and cleanup.
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    PHAssetResourceCreationOptions* options = [[PHAssetResourceCreationOptions alloc] init];
                    options.shouldMoveFile = YES;
                    PHAssetCreationRequest* creationRequest = [PHAssetCreationRequest creationRequestForAsset];
                    [creationRequest addResourceWithType:PHAssetResourceTypeVideo fileURL:outputFileURL options:options];
                    
                    // Specify the movie's location.
                    creationRequest.location = self.locationManager.location;
                } completionHandler:^(BOOL success, NSError* error) {
                    if (!success) {
                        NSLog(@"AVCam couldn't save the movie to your photo library: %@", error);
                    }
                    cleanUp();
                }];
            }
            else {
                cleanUp();
            }
        }];
    }
    else {
        cleanUp();
    }
    
    // When recording finishes, check if the system-preferred camera changed
    // during the recording.
    dispatch_async(self.sessionQueue, ^{
        AVCaptureDevice *systemPreferredCamera = AVCaptureDevice.systemPreferredCamera;
        if (self.videoDeviceInput.device != systemPreferredCamera) {
            [self changeCamera:systemPreferredCamera isUserSelection:NO completion:nil];
        }
    });
    
    // Enable the Camera and Record buttons to let the user switch camera and
    // start another recording.
    dispatch_async(dispatch_get_main_queue(), ^{
        // Only enable the ability to change camera if the device has more than
        // one camera.
        self.cameraButton.enabled = (self.videoDeviceDiscoverySession.uniqueDevicePositionsCount > 1);
        self.recordButton.enabled = YES;
        self.captureModeControl.enabled = YES;
        [self.recordButton setImage:[UIImage imageNamed:@"CaptureVideo"] forState:UIControlStateNormal];
        self.supportedInterfaceOrientations = UIInterfaceOrientationMaskAll;
        // After the recording finishes, allow rotation to continue.
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
    });
}

#pragma mark KVO and Notifications

- (void) addObservers
{
    [self.session addObserver:self forKeyPath:@"running" options:NSKeyValueObservingOptionNew context:SessionRunningContext];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:self.videoDeviceInput.device];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionRuntimeError:) name:AVCaptureSessionRuntimeErrorNotification object:self.session];
    
    // A session can only run when the app is full screen. It will be
    // interrupted in a multi-app layout, introduced in iOS 9, see also the
    // documentation of `AVCaptureSessionInterruptionReason`. Add observers to
    // handle these session interruptions and show a preview is paused message.
    // See `AVCaptureSessionWasInterruptedNotification` for other interruption
    // reasons.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionWasInterrupted:) name:AVCaptureSessionWasInterruptedNotification object:self.session];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionInterruptionEnded:) name:AVCaptureSessionInterruptionEndedNotification object:self.session];
}

- (void) removeObservers
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [self.session removeObserver:self forKeyPath:@"running" context:SessionRunningContext];
}

- (void) observeValueForKeyPath:(NSString*)keyPath
                       ofObject:(id)object
                         change:(NSDictionary*)change
                        context:(void*)context
{
    if (context == SessionRunningContext) {
        BOOL isSessionRunning = [change[NSKeyValueChangeNewKey] boolValue];
        BOOL livePhotoCaptureEnabled = self.photoOutput.livePhotoCaptureEnabled;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Only enable the ability to change camera if the device has more
            // than one camera.
            self.cameraButton.enabled = isSessionRunning && (self.videoDeviceDiscoverySession.uniqueDevicePositionsCount > 1);
            self.recordButton.enabled = isSessionRunning && (self.captureModeControl.selectedSegmentIndex == AVCamCaptureModeMovie);
            self.photoButton.enabled = isSessionRunning;
            self.captureModeControl.enabled = isSessionRunning;
            self.livePhotoModeButton.enabled = isSessionRunning && livePhotoCaptureEnabled;
            self.photoQualityPrioritizationSegControl.enabled = isSessionRunning;
        });
    }
    else if (context == SystemPreferredCameraContext) {
        AVCaptureDevice *systemPreferredCamera = change[NSKeyValueChangeNewKey];
        
        // Don't switch cameras if movie recording is in progress.
        if (self.movieFileOutput.isRecording) {
            return;
        }
        if (self.videoDeviceInput.device == systemPreferredCamera) {
            return;
        }
        
        [self changeCamera:systemPreferredCamera isUserSelection:NO completion:nil];
    }
    else if (context == VideoRotationAngleForHorizonLevelPreviewContext) {
        CGFloat videoRotationAngleForHorizonLevelPreview = [change[NSKeyValueChangeNewKey] floatValue];
        self.previewView.videoPreviewLayer.connection.videoRotationAngle = videoRotationAngleForHorizonLevelPreview;
    }
    else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void) subjectAreaDidChange:(NSNotification*)notification
{
    CGPoint devicePoint = CGPointMake(0.5, 0.5);
    [self focusWithMode:AVCaptureFocusModeContinuousAutoFocus exposeWithMode:AVCaptureExposureModeContinuousAutoExposure atDevicePoint:devicePoint monitorSubjectAreaChange:NO];
}

- (void) sessionRuntimeError:(NSNotification*)notification
{
    NSError* error = notification.userInfo[AVCaptureSessionErrorKey];
    NSLog(@"Capture session runtime error: %@", error);
    
    // If media services were reset, and the last start succeeded, restart the
    // session.
    if (error.code == AVErrorMediaServicesWereReset) {
        dispatch_async(self.sessionQueue, ^{
            if (self.isSessionRunning) {
                [self.session startRunning];
                self.sessionRunning = self.session.isRunning;
            }
            else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.resumeButton.hidden = NO;
                });
            }
        });
    }
    else {
        self.resumeButton.hidden = NO;
    }
}

- (void) sessionWasInterrupted:(NSNotification*)notification
{
    // In some scenarios we want to enable the user to resume the session
    // running. For example, if music playback is initiated via control center
    // while using AVCam, then the user can let AVCam resume the session
    // running, which will stop music playback. Note that stopping music
    // playback in control center will not automatically resume the session
    // running. Also note that it is not always possible to resume, see
    // -[resumeInterruptedSession:].
    BOOL showResumeButton = NO;
    
    AVCaptureSessionInterruptionReason reason = [notification.userInfo[AVCaptureSessionInterruptionReasonKey] integerValue];
    NSLog(@"Capture session was interrupted with reason %ld", (long)reason);
    
    if (reason == AVCaptureSessionInterruptionReasonAudioDeviceInUseByAnotherClient ||
        reason == AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient) {
        showResumeButton = YES;
    }
    else if (reason == AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps) {
        // Fade-in a label to inform the user that the camera is unavailable.
        self.cameraUnavailableLabel.alpha = 0.0;
        self.cameraUnavailableLabel.hidden = NO;
        [UIView animateWithDuration:0.25 animations:^{
            self.cameraUnavailableLabel.alpha = 1.0;
        }];
    }
    else if (reason == AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableDueToSystemPressure) {
        NSLog(@"Session stopped running due to shutdown system pressure level.");
    }
    
    if (showResumeButton) {
        // Fade-in a button to enable the user to try to resume the session
        // running.
        self.resumeButton.alpha = 0.0;
        self.resumeButton.hidden = NO;
        [UIView animateWithDuration:0.25 animations:^{
            self.resumeButton.alpha = 1.0;
        }];
    }
}

- (void) sessionInterruptionEnded:(NSNotification*)notification
{
    NSLog(@"Capture session interruption ended");
    
    if (!self.resumeButton.hidden) {
        [UIView animateWithDuration:0.25 animations:^{
            self.resumeButton.alpha = 0.0;
        } completion:^(BOOL finished) {
            self.resumeButton.hidden = YES;
        }];
    }
    if (!self.cameraUnavailableLabel.hidden) {
        [UIView animateWithDuration:0.25 animations:^{
            self.cameraUnavailableLabel.alpha = 0.0;
        } completion:^(BOOL finished) {
            self.cameraUnavailableLabel.hidden = YES;
        }];
    }
}

@end
