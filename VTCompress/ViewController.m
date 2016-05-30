//
//  ViewController.m
//  VTCompress
//
//  Created by 张颂 on 16/5/28.
//  Copyright © 2016年 张颂. All rights reserved.
//

#import "ViewController.h"
#import "rawH264Encoder.h"

#define WEAK_OBJ_REF(obj) __weak __typeof__(obj) weak_##obj = obj

@interface ViewController ()<rawH264EncoderDelegate>

@property (weak, nonatomic) IBOutlet UIButton *goButton;
@property (strong, nonatomic)AVAssetReader *assetReader;
@property (strong, nonatomic)AVAssetReaderTrackOutput *videoTrackOutput;
@property (strong, nonatomic)AVAssetReaderTrackOutput *audioTrackOutput;

@property (strong, nonatomic)AVAssetWriter *assetWriter;
@property (strong, nonatomic)AVAssetWriterInput * videoWriterInput;
@property (strong, nonatomic)AVAssetWriterInput * audioWriterInput;

@property (assign, nonatomic)BOOL oneTrackHasFinishWrite;
@property (strong, nonatomic)NSMutableArray * compressedVideoSamples;
@property (assign, nonatomic)int keyFrameCount;
@property (assign, nonatomic)int keyFrameInterval;

@end

@implementation ViewController
{
    dispatch_queue_t writeQueue;
    rawH264Encoder *h264Encoder;
    NSString *sourceFilePath;
    NSString *h264FilePath;
    NSFileHandle *fileHandle;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    writeQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    self.goButton.enabled = NO;
    [self prepareFile];
    self.goButton.enabled = YES;
    self.oneTrackHasFinishWrite = NO;
    self.compressedVideoSamples = [[NSMutableArray alloc] init];
    self.keyFrameCount = 0;
    self.keyFrameInterval = 0;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (IBAction)clickGo:(id)sender {
    self.goButton.enabled = NO;
    [self carolStart];
    return;
}

#pragma mark <rawH264EncoderDelegate>
- (void)gotSpsPps:(NSData*)sps pps:(NSData*)pps
{
    //NSLog(@"gotSpsPps %d %d", (int)[sps length], (int)[pps length]);
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
    //NSLog(@"gotEncodedData %d", (int)[data length]);
    static int totalCount = 1;
    static int lastKeyFrameCount = 0;
    NSString * log = [NSString stringWithFormat:@"===> %d", totalCount++];
    if (isKeyFrame) {
        self.keyFrameInterval = totalCount - lastKeyFrameCount;
        lastKeyFrameCount = totalCount;
        log = [log stringByAppendingString:[NSString stringWithFormat:@"( key - %d )", self.keyFrameCount++]];
        NSLog(@"%@", log);
    }
    
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
    static int sampleCount = 1;
    //NSLog(@" = = = = = = = >> %d", sampleCount++);
    [self.compressedVideoSamples addObject:(__bridge id _Nonnull)(sampleBuffer)];
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

- (BOOL)prepareWriter
{
    NSArray * paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString * documentsDirectory = [paths objectAtIndex:0];
    NSString * finalPath = [documentsDirectory stringByAppendingPathComponent:@"final.mov"];
    NSError * error = nil;
    [[NSFileManager defaultManager] removeItemAtURL:[NSURL fileURLWithPath:finalPath] error:nil];
    
    self.assetWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:finalPath] fileType:AVFileTypeQuickTimeMovie error:&error];
    NSParameterAssert(self.assetWriter);
    
    //如果输入源是已经编码过的，setting参数必须为nil
    self.videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:nil];
    if ([self.assetWriter canAddInput:self.videoWriterInput]) {
        [self.assetWriter addInput:self.videoWriterInput];
    }else{
        return NO;
    }

    self.audioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil];
    if ([self.assetWriter canAddInput:self.audioWriterInput]) {
        [self.assetWriter addInput:self.audioWriterInput];
    }else{
        return NO;
    }
    NSLog(@"assetWriter output file type: %@", self.assetWriter.outputFileType);
    return YES;
}

- (BOOL)startAssetReader
{
    NSError * error;
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:sourceFilePath]];
    self.assetReader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error) {
        NSLog(@"Error creating Asset Reader: %@", [error description]);
        return NO;
    }
    //assetReader创建视频output
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    AVAssetTrack *videoTrack = (AVAssetTrack *)[videoTracks firstObject];
    NSLog(@"frameRate : %f", videoTrack.nominalFrameRate);
    NSLog(@"timeScale : %d", videoTrack.naturalTimeScale);
    NSString* key = (NSString*)kCVPixelBufferPixelFormatTypeKey;
    NSNumber* val = [NSNumber numberWithUnsignedInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange];
    NSDictionary* videoSettings = [NSDictionary dictionaryWithObject:val forKey:key];
    self.videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:videoSettings];
    
    if ([self.assetReader canAddOutput:self.videoTrackOutput]) {
        [self.assetReader addOutput:self.videoTrackOutput];
    }else{
        return NO;
    }
    
    //assetReader创建音频output
    NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    AVAssetTrack *audioTrack = (AVAssetTrack *)[audioTracks firstObject];
    NSLog(@"frameRate : %f", audioTrack.nominalFrameRate);
    NSLog(@"timeScale : %d", audioTrack.naturalTimeScale);
    self.audioTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:nil];
    
    if ([self.assetReader canAddOutput:self.audioTrackOutput]) {
        [self.assetReader addOutput:self.audioTrackOutput];
    }else{
        return NO;
    }
    
    NSLog(@"mediaType(audio:%@, video:%@)", self.audioTrackOutput.mediaType, self.videoTrackOutput.mediaType);
    BOOL didStart = [self.assetReader startReading];
    return didStart;
}

- (void)carolStart
{
    //prepare for reader and writer
    NSParameterAssert([self startAssetReader]);
    NSParameterAssert([self prepareWriter]);
    h264Encoder = [[rawH264Encoder alloc] initWithWidth:360 height:480];
    h264Encoder.delegate = self;
    
    NSLog(@"================ start convert == video ================");
    CMSampleBufferRef sampleBuffer = [self.videoTrackOutput copyNextSampleBuffer];
    if (!sampleBuffer) {
        NSLog(@"Error Can not read video sample buffer");
        [self carolEndWork];
        return;
    }
    static int sourceFileSampleCount = 0;
    while (YES) {
        if (sampleBuffer) {
            sourceFileSampleCount++;
            [h264Encoder encode:sampleBuffer];
            if (sourceFileSampleCount > 1000 || self.assetReader.status != AVAssetReaderStatusReading) {
                //7秒视频190帧
                sampleBuffer = nil;
                break;
            }else{
                sampleBuffer = [self.videoTrackOutput copyNextSampleBuffer];
            }
        }else{
            if (self.assetReader.status == AVAssetReaderStatusFailed){
                NSLog(@"Asset Reader failed with error: %@", [[self.assetReader error] description]);
            } else if (self.assetReader.status == AVAssetReaderStatusCompleted){
                NSLog(@"Reached the end of the video.");
                NSLog(@"================ end ====== frame count %d ===========", sourceFileSampleCount);
            } else{
                NSLog(@"================ end (%ld) ====== frame count %d ===========", (long)self.assetReader.status, sourceFileSampleCount);
            }
            break;
        }
    }
    
    WEAK_OBJ_REF(self);
    [self.assetWriter startWriting];
    [self.assetWriter startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp((__bridge CMSampleBufferRef)self.compressedVideoSamples[0])];
    static int videoSampleCount = 0;
    [self.videoWriterInput requestMediaDataWhenReadyOnQueue:writeQueue usingBlock:^{
        while ([weak_self.videoWriterInput isReadyForMoreMediaData])
        {
            CMSampleBufferRef nextSampleBuffer = [weak_self nextVideoSampleBufferToWrite];
            if (nextSampleBuffer)
            {
                videoSampleCount++;
                [weak_self.videoWriterInput appendSampleBuffer:nextSampleBuffer];
                //CFRelease(nextSampleBuffer);
            }
            else
            {
                [weak_self.videoWriterInput markAsFinished];
                NSLog(@"======= end video (%d)", videoSampleCount);
                if (weak_self.oneTrackHasFinishWrite) {
                    [weak_self.assetWriter endSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp((__bridge CMSampleBufferRef)weak_self.compressedVideoSamples[weak_self.compressedVideoSamples.count - 1])];
                    [weak_self carolEndWork];
                }else{
                    weak_self.oneTrackHasFinishWrite = YES;
                }
                break;
            }
        }
    }];
    
    static int audioSampleCount = 0;
    [self.audioWriterInput requestMediaDataWhenReadyOnQueue:writeQueue usingBlock:^{
        while ([weak_self.audioWriterInput isReadyForMoreMediaData])
        {
            CMSampleBufferRef nextSampleBuffer = [weak_self nextAudioSampleBufferToWrite];
            if (nextSampleBuffer)
            {
                audioSampleCount++;
                [weak_self.audioWriterInput appendSampleBuffer:nextSampleBuffer];
                CFRelease(nextSampleBuffer);
            }
            else
            {
                [weak_self.audioWriterInput markAsFinished];
                NSLog(@"======= end audio (%d)", audioSampleCount);
                if (weak_self.oneTrackHasFinishWrite) {
                    [weak_self.assetWriter endSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp((__bridge CMSampleBufferRef)weak_self.compressedVideoSamples[weak_self.compressedVideoSamples.count - 1])];
                    [weak_self carolEndWork];
                }else{
                    weak_self.oneTrackHasFinishWrite = YES;
                }
                break;
            }
        }
    }];
}

- (void)carolEndWork
{
    [h264Encoder finish];
    NSLog(@">>>>>>> h265 file size ( %lld ) >>>>>", [fileHandle seekToEndOfFile]);
    [fileHandle closeFile];
    fileHandle = NULL;
    
    [self.assetWriter finishWritingWithCompletionHandler:^{
        NSArray * paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString * documentsDirectory = [paths objectAtIndex:0];
        NSString * finalPath = [documentsDirectory stringByAppendingPathComponent:@"final.mov"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:finalPath]) {
            NSFileHandle * mp4FileHandle = [NSFileHandle fileHandleForReadingAtPath:finalPath];
            NSLog(@">>>>>>> mov file  size ( %lld ) >>>>>", [mp4FileHandle seekToEndOfFile]);
            NSLog(@"keyFrameCount: %d", self.keyFrameCount - 1);
            NSLog(@"keyFrameInterval: %d", self.keyFrameInterval);
            [mp4FileHandle closeFile];
        }
        NSLog(@" == DONE ==");
    }];
//    for (id obj in self.compressedVideoSamples) {
//        CFRelease((__bridge CMSampleBufferRef)obj);
//    }
    [self.compressedVideoSamples removeAllObjects];
}

- (CMSampleBufferRef)nextVideoSampleBufferToWrite
{
    int totalSamples = (int)self.compressedVideoSamples.count;
    static int currVideoCount = 0;
    //NSLog(@"+++ ask for video : %d", currVideoCount);
    if (currVideoCount < totalSamples) {
        CMSampleBufferRef sampleBuffer = (__bridge CMSampleBufferRef)(self.compressedVideoSamples[currVideoCount++]);
        CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        NSLog(@"V - > PTS:%lld",  presentationTimeStamp.value);
        //视频总PPS：130048
        if (presentationTimeStamp.value > 92000) {
            return nil;
        }
        return sampleBuffer;
    }
    return nil;
}

- (CMSampleBufferRef)nextAudioSampleBufferToWrite
{
    static int askedAudioCount = 0;
    //NSLog(@"--- ask for audio : %d", askedAudioCount++);
    CMSampleBufferRef sampleBuffer = [self.audioTrackOutput copyNextSampleBuffer];
    CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    NSLog(@"0 - >PTS:%lld",  presentationTimeStamp.value);
    //音频总PPS：464111
    if (presentationTimeStamp.value > 348000) {
        return nil;
    }
    return sampleBuffer;
}


@end
