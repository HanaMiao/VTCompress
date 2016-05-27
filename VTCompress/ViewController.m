//
//  ViewController.m
//  VTCompress
//
//  Created by 张颂 on 16/5/28.
//  Copyright © 2016年 张颂. All rights reserved.
//

#import "ViewController.h"
#import "rawH264Encoder.h"

@interface ViewController ()<rawH264EncoderDelegate>

@property (weak, nonatomic) IBOutlet UIButton *goButton;

@end

@implementation ViewController
{
    rawH264Encoder *h264Encoder;
    NSString *sourceFilePath;
    NSString *h264FilePath;
    NSFileHandle *fileHandle;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.goButton.enabled = NO;
    [self prepareFile];
    h264Encoder = [[rawH264Encoder alloc] initWithWidth:480 height:640];
    h264Encoder.delegate = self;
    self.goButton.enabled = YES;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (IBAction)clickGo:(id)sender {
    [self carolWork];
    return;
}

#pragma mark <rawH264EncoderDelegate>
- (void)gotSpsPps:(NSData*)sps pps:(NSData*)pps
{
    NSLog(@"gotSpsPps %d %d", (int)[sps length], (int)[pps length]);
    const char bytes[] = "\x00\x00\x00\x01";
    size_t length = (sizeof bytes) - 1; //string literals have implicit trailing '\0'
    NSData *ByteHeader = [NSData dataWithBytes:bytes length:length];
    [fileHandle writeData:ByteHeader];
    [fileHandle writeData:sps];
    [fileHandle writeData:ByteHeader];
    [fileHandle writeData:pps];
}

- (void)gotEncodedData:(NSData*)data isKeyFrame:(BOOL)isKeyFrame
{
    NSLog(@"gotEncodedData %d", (int)[data length]);
    static int keyFrameCount = 1;
    static int totalCount = 1;
    NSString * log = [NSString stringWithFormat:@"===> %d", totalCount++];
    if (isKeyFrame) {
        log = [log stringByAppendingString:[NSString stringWithFormat:@"( key - %d )", keyFrameCount++]];
    }
    NSLog(@"%@", log);
    
    if (fileHandle != NULL)
    {
        const char bytes[] = "\x00\x00\x00\x01";
        size_t length = (sizeof bytes) - 1; //string literals have implicit trailing '\0'
        NSData *ByteHeader = [NSData dataWithBytes:bytes length:length];
        [fileHandle writeData:ByteHeader];
        [fileHandle writeData:data];
    }
}

- (void)gotCompressedSampleBuffer:(CMSampleBufferRef) sampleBuffer
{
    
}

#pragma mark private
- (void)prepareFile
{
    NSError *error = nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *documentsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    
    h264FilePath = [documentsDirectory stringByAppendingPathComponent:@"result.h264"];
    [fileManager removeItemAtPath:h264FilePath error:nil];
    [fileManager createFileAtPath:h264FilePath contents:nil attributes:nil];
    fileHandle = [NSFileHandle fileHandleForWritingAtPath:h264FilePath];
    
    NSString *originPath=[[NSBundle mainBundle] pathForResource:@"daemon" ofType:@"mp4"];
    sourceFilePath = [documentsDirectory stringByAppendingPathComponent:@"source.mp4"];
    [[NSFileManager defaultManager] removeItemAtPath:sourceFilePath error:nil];
    [[NSFileManager defaultManager] copyItemAtURL:[NSURL fileURLWithPath:originPath] toURL:[NSURL fileURLWithPath:sourceFilePath] error:&error];
    if (error) {
        NSLog(@"copy file fail: %@", [error description]);
        return;
    }else{
        NSFileHandle * documentFile = [NSFileHandle fileHandleForReadingAtPath:sourceFilePath];
        NSLog(@"copy file success (file size: %lld )\n %@", [documentFile seekToEndOfFile], sourceFilePath);
        [documentFile closeFile];
    }
}

- (void)carolWork
{
    NSError * error = nil;
    
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:sourceFilePath]];
    AVAssetReader * assetReader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error) {
        NSLog(@"Error creating Asset Reader: %@", [error description]);
    }
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    AVAssetTrack *videoTrack = (AVAssetTrack *)[videoTracks firstObject];
    NSLog(@"frameRate : %f", videoTrack.nominalFrameRate);
    NSLog(@"timeScale : %d", videoTrack.naturalTimeScale);
    
    NSString* key = (NSString*)kCVPixelBufferPixelFormatTypeKey;
    NSNumber* val = [NSNumber numberWithUnsignedInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange];
    NSDictionary* videoSettings = [NSDictionary dictionaryWithObject:val forKey:key];
    AVAssetReaderTrackOutput *videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:videoSettings];
    
    if ([assetReader canAddOutput:videoTrackOutput]) {
        [assetReader addOutput:videoTrackOutput];
    }
    
    BOOL didStart = [assetReader startReading];
    NSAssert(didStart, @"startReading fail");
    
    int sourceFileSampleCount = 0;
    NSLog(@"================ start ==================");
    while (assetReader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sampleBuffer = [videoTrackOutput copyNextSampleBuffer];
        if (sampleBuffer) {
            sourceFileSampleCount++;
            if (sourceFileSampleCount > 190) {
                //7秒视频
                break;
            }else if (sourceFileSampleCount%5 == 0){
                //24的帧率，适当丢帧
                continue;
            }
            [h264Encoder encode:sampleBuffer];
        }
        else if (assetReader.status == AVAssetReaderStatusFailed){
            NSLog(@"Asset Reader failed with error: %@", [[assetReader error] description]);
        } else if (assetReader.status == AVAssetReaderStatusCompleted){
            NSLog(@"Reached the end of the video.");
            NSLog(@"================ end ====== frame count %d ===========", sourceFileSampleCount);
        }
    }
    
    [h264Encoder finish];
    NSLog(@">>>>>>> final file size ( %lld ) >>>>>", [fileHandle seekToEndOfFile]);
    [fileHandle closeFile];
    fileHandle = NULL;
}

@end
