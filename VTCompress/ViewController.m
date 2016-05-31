//
//  ViewController.m
//  VTCompress
//
//  Created by 张颂 on 16/5/28.
//  Copyright © 2016年 张颂. All rights reserved.
//

#import "ViewController.h"
#import "rawH264Encoder.h"
//https://developer.apple.com/library/mac/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/05_Export.html

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
@property (assign, nonatomic)int inputVideoFrameCount;
@property (assign, nonatomic)int inputAudioFrameCount;
@property (assign, nonatomic)int outputVideoFrameCount;
@property (assign, nonatomic)int outputAudioFrameCount;
@property (assign, nonatomic)BOOL ifSaveH464File;
@property (assign, nonatomic)BOOL if7Second;
@property (assign, nonatomic)BOOL ifReduceFrame;
@property (assign, nonatomic)BOOL ifUseToolBox;
@property (strong, nonatomic)dispatch_queue_t encodingQueue;
@property (assign, nonatomic)CMTime lastSamplePTS;

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
    self.inputVideoFrameCount = 0;
    self.inputAudioFrameCount = 0;
    self.outputVideoFrameCount = 0;
    self.outputAudioFrameCount = 0;
    self.ifSaveH464File = NO;
    self.if7Second = YES;
    self.ifReduceFrame = NO;
    self.ifUseToolBox = NO;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (IBAction)clickGo:(id)sender {
    self.goButton.enabled = NO;
    if (_ifUseToolBox) {
        [self carolStart];
    }else{
        [self carolStartWithOutToolBox];
    }
    return;
}

#pragma mark <rawH264EncoderDelegate>
- (void)gotSpsPps:(NSData*)sps pps:(NSData*)pps
{
    if (!_ifSaveH464File) {
        return;
    }
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
        if (totalCount < 191) {
            self.keyFrameCount++;
        }
        log = [log stringByAppendingString:[NSString stringWithFormat:@"( key - %d )", self.keyFrameCount]];
        NSLog(@"%@", log);
    }
    
    if (self.ifSaveH464File && fileHandle != NULL)
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
    self.inputVideoFrameCount++;
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
    
    NSString *originPath=[[NSBundle mainBundle] pathForResource:@"20160112221628" ofType:@"mp4"];
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
    NSString * finalPath = [documentsDirectory stringByAppendingPathComponent:@"final.mp4"];
    NSError * error = nil;
    [[NSFileManager defaultManager] removeItemAtURL:[NSURL fileURLWithPath:finalPath] error:nil];
    
    self.assetWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:finalPath] fileType:AVFileTypeMPEG4 error:&error];
    NSParameterAssert(self.assetWriter);
    
    //如果输入源是已经编码过的，setting参数必须为nil
    NSDictionary * videoSettings = @{
                                     AVVideoCodecKey : AVVideoCodecH264,
                                     AVVideoHeightKey : @(360),
                                     AVVideoWidthKey : @(640),
                                     AVVideoCompressionPropertiesKey: @{
                                             AVVideoProfileLevelKey : AVVideoProfileLevelH264High41,
                                             AVVideoAverageBitRateKey : @(800000),
//                                             AVVideoMaxKeyFrameIntervalKey : @(60),
                                             AVVideoMaxKeyFrameIntervalDurationKey : @(2.0),
                                             }
                                     };
    self.videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    if ([self.assetWriter canAddInput:self.videoWriterInput]) {
        [self.assetWriter addInput:self.videoWriterInput];
    }else{
        return NO;
    }
    
    // Configure the channel layout as mono.
    AudioChannelLayout monoChannelLayout = {
        .mChannelLayoutTag = kAudioChannelLayoutTag_Mono,
        .mChannelBitmap = 0,
        .mNumberChannelDescriptions = 0
    };
    
    // Convert the channel layout object to an NSData object.
    NSData *channelLayoutAsData = [NSData dataWithBytes:&monoChannelLayout length:offsetof(AudioChannelLayout, mChannelDescriptions)];

    NSDictionary * audioSettings = @{
                                     AVFormatIDKey : @(kAudioFormatMPEG4AAC),
                                     AVNumberOfChannelsKey : @(1),
                                     AVSampleRateKey : @(44100),
                                     AVEncoderBitRateKey : @(48000),
                                     AVChannelLayoutKey  : channelLayoutAsData,
                                     };
    self.audioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
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
    
    NSArray *videoFormatDescriptions = [videoTrack formatDescriptions];
    
    NSString* key = (NSString*)kCVPixelBufferPixelFormatTypeKey;
    NSNumber* val = [NSNumber numberWithUnsignedInt:kCVPixelFormatType_422YpCbCr8];
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
    NSArray *audioFormatDescriptions = [audioTrack formatDescriptions];
    NSDictionary * audioSetting = @{ AVFormatIDKey : [NSNumber numberWithUnsignedInt:kAudioFormatLinearPCM] };
    self.audioTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:audioSetting];
    
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
    
    NSLog(@"================ start encode video ================");
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
            if (self.assetReader.status != AVAssetReaderStatusReading) {
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
                NSLog(@"================ end encode video ====== frame count %d ===========", sourceFileSampleCount);
            }
            break;
        }
    }
    
    WEAK_OBJ_REF(self);
    [self.assetWriter startWriting];
    [self.assetWriter startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp((__bridge CMSampleBufferRef)self.compressedVideoSamples[0])];
    [self.videoWriterInput requestMediaDataWhenReadyOnQueue:writeQueue usingBlock:^{
        while ([weak_self.videoWriterInput isReadyForMoreMediaData])
        {
            CMSampleBufferRef nextSampleBuffer = [weak_self nextVideoSampleBufferToWrite];
            if (nextSampleBuffer)
            {
                weak_self.outputVideoFrameCount++;
                [weak_self.videoWriterInput appendSampleBuffer:nextSampleBuffer];
                //CFRelease(nextSampleBuffer);
            }
            else
            {
                [weak_self.videoWriterInput markAsFinished];
                NSLog(@"======= end video (%d) =====", weak_self.outputVideoFrameCount);
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
    
    [self.audioWriterInput requestMediaDataWhenReadyOnQueue:writeQueue usingBlock:^{
        while ([weak_self.audioWriterInput isReadyForMoreMediaData])
        {
            CMSampleBufferRef nextSampleBuffer = [weak_self nextAudioSampleBufferToWrite];
            if (nextSampleBuffer)
            {
                weak_self.outputAudioFrameCount++;
                [weak_self.audioWriterInput appendSampleBuffer:nextSampleBuffer];
                CFRelease(nextSampleBuffer);
            }
            else
            {
                [weak_self.audioWriterInput markAsFinished];
                NSLog(@"======= end audio (%d)", weak_self.outputAudioFrameCount);
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
        NSString * finalPath = [documentsDirectory stringByAppendingPathComponent:@"final.mp4"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:finalPath]) {
            NSFileHandle * mp4FileHandle = [NSFileHandle fileHandleForReadingAtPath:finalPath];
            NSLog(@">>>>>>> mp4 file  size ( %lld ) >>>>>", [mp4FileHandle seekToEndOfFile]);
            NSLog(@"keyFrameCount: %d", self.keyFrameCount - 1);
            NSLog(@"keyFrameInterval: %d", self.keyFrameInterval);
            NSLog(@"encodeVideoFrame: %d", self.outputVideoFrameCount);
            NSLog(@"encodeAudioFrame: %d", self.outputAudioFrameCount);
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
    if (!_ifUseToolBox) {
        static int currVideoCount = 0;
        CMSampleBufferRef sampleBuffer = [self.videoTrackOutput copyNextSampleBuffer];
        currVideoCount++;
        if (self.ifReduceFrame && currVideoCount % 5 == 0) {
            sampleBuffer = [self.videoTrackOutput copyNextSampleBuffer];
            currVideoCount++;
        }
        CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        //NSLog(@"V - >PTS:%lld",  presentationTimeStamp.value);
        //音频总PPS：464111
//        if (currVideoCount > 100) {
//            return nil;
//        }
        if (self.if7Second && presentationTimeStamp.value > 97500) {
            return nil;
        }
        if (sampleBuffer) {
            self.lastSamplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        }
        return sampleBuffer;
    }else{
        int totalSamples = (int)self.compressedVideoSamples.count;
        static int currVideoCount = 1;
        if (self.ifReduceFrame && currVideoCount % 5 == 0) {
            currVideoCount ++;
        }
        if (currVideoCount < totalSamples) {
            CMSampleBufferRef sampleBuffer = (__bridge CMSampleBufferRef)(self.compressedVideoSamples[currVideoCount++]);
            CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            //NSLog(@"V - > PTS:%lld",  presentationTimeStamp.value);
            //视频总PPS：130048
            if (self.if7Second && presentationTimeStamp.value > 97500) {
                return nil;
            }
            return sampleBuffer;
        }
    }
    return nil;
}

- (CMSampleBufferRef)nextAudioSampleBufferToWrite
{
    static int currAudioCount = 0;
    CMSampleBufferRef sampleBuffer = [self.audioTrackOutput copyNextSampleBuffer];
    currAudioCount++;
    if (self.ifReduceFrame && currAudioCount % 5 == 0) {
        sampleBuffer = [self.audioTrackOutput copyNextSampleBuffer];
        currAudioCount++;
    }
    CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    //NSLog(@"0 - >PTS:%lld",  presentationTimeStamp.value);
    //音频总PPS：464111
//    if (currAudioCount > 48) {
//        return nil;
//    }
    if (self.if7Second && presentationTimeStamp.value > 348000) {
        return nil;
    }
    return sampleBuffer;
}

- (void)carolStartWithOutToolBox
{
    //prepare for reader and writer
    NSParameterAssert([self startAssetReader]);
    NSParameterAssert([self prepareWriter]);
    
    [self.assetWriter startWriting];
    CMSampleBufferRef firstSample = [self nextVideoSampleBufferToWrite];
    [self.assetWriter startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(firstSample)];
    
    //dispatch_group_t encodingGroup = dispatch_group_create();
    //dispatch_group_enter(encodingGroup);
    WEAK_OBJ_REF(self);
    [self.videoWriterInput requestMediaDataWhenReadyOnQueue:writeQueue usingBlock:^{
        while ([weak_self.videoWriterInput isReadyForMoreMediaData])
        {
            @try {
                static CMSampleBufferRef videoNextBuff = nil;
                static BOOL hasProcessFirstSample = NO;
                if (!hasProcessFirstSample) {
                    videoNextBuff = firstSample;
                    hasProcessFirstSample = YES;
                }else{
                    videoNextBuff = [self nextVideoSampleBufferToWrite];
                }
                if (videoNextBuff)
                {
                    [weak_self.videoWriterInput appendSampleBuffer:videoNextBuff];
                    CFRelease(videoNextBuff);
                    weak_self.outputVideoFrameCount++;
                    NSLog(@"v -> %d", weak_self.outputVideoFrameCount);
                }
                else
                {
                    [weak_self.videoWriterInput markAsFinished];
                    NSLog(@"======= end video (%d) =====", weak_self.outputVideoFrameCount);
                    if (weak_self.oneTrackHasFinishWrite) {
                        
                        [weak_self.assetWriter endSessionAtSourceTime:weak_self.lastSamplePTS];
                        [weak_self carolEndWork];
                    }else{
                        weak_self.oneTrackHasFinishWrite = YES;
                    }
                    //dispatch_group_leave(encodingGroup);
                    break;
                }
            } @catch (NSException *exception) {
                if ([exception isKindOfClass:NSInternalInconsistencyException.class]) {
                    NSLog(@" # # # # # # # #  NSInternalInconsistencyException   # # # # # # ");
                    continue;
                }
            }
        }
    }];
    
    //dispatch_group_enter(encodingGroup);
    [self.audioWriterInput requestMediaDataWhenReadyOnQueue:writeQueue usingBlock:^{
        while ([weak_self.audioWriterInput isReadyForMoreMediaData])
        {
            CMSampleBufferRef audioNextBuff = [weak_self nextAudioSampleBufferToWrite];
            if (audioNextBuff)
            {
                weak_self.outputAudioFrameCount++;
                NSLog(@"audio -> %d", weak_self.outputAudioFrameCount);
                [weak_self.audioWriterInput appendSampleBuffer:audioNextBuff];
                CFRelease(audioNextBuff);
            }
            else
            {
                [weak_self.audioWriterInput markAsFinished];
                NSLog(@"======= end audio (%d)", weak_self.outputAudioFrameCount);
                if (weak_self.oneTrackHasFinishWrite) {
                    [weak_self.assetWriter endSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp([self.videoTrackOutput copyNextSampleBuffer])];
                    [weak_self carolEndWork];
                }else{
                    weak_self.oneTrackHasFinishWrite = YES;
                }
                //dispatch_group_leave(encodingGroup);
                break;
            }
        }
    }];

    //dispatch_group_wait(encodingGroup, DISPATCH_TIME_FOREVER);
}

- (dispatch_queue_t)encodingQueue
{
    if(!_encodingQueue)
    {
        _encodingQueue = dispatch_queue_create("com.myProject.encoding", NULL);
    }
    return _encodingQueue;
}
@end
