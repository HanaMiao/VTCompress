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
@property (weak, nonatomic) IBOutlet UIButton *deleteOriginFileButton;
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

@property (strong, nonatomic)NSArray * sourceFileNames;
@property (strong, nonatomic)NSArray * lastVideoPTS;
@property (strong, nonatomic)NSArray * lastAudioPTS;
@property (strong, nonatomic)NSArray * widthAndHeight;
@property (strong, nonatomic)NSArray * reduceFrameIntervals;
@property (strong, nonatomic)NSDictionary * videoSettings;
@property (strong, nonatomic)NSDictionary * audioSettings;
@property (assign, nonatomic)NSInteger currentFileIndex;
@property (assign, nonatomic)CGAffineTransform transform;

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
    self.ifReduceFrame = YES;
    self.ifUseToolBox = NO;
    
    self.sourceFileNames = [NSArray arrayWithObjects:@"daemon", @"book", @"roadA", @"roadB", nil];
    self.lastVideoPTS = [NSArray arrayWithObjects:@(130048), @(5703), @(5463), @(5883), nil];
    self.lastAudioPTS = [NSArray arrayWithObjects:@(464111), @(413623), @(401344), @(425920), nil];
    self.reduceFrameIntervals = [NSArray arrayWithObjects:@(5), @(3), @(3), @(3), nil];
    self.widthAndHeight = @[@{@"width": @(360), @"height":@(640)},
                            @{@"width": @(640), @"height":@(360)},
                            @{@"width": @(640), @"height":@(360)},
                            @{@"width": @(640), @"height":@(360)},];
    
    // Configure the channel layout as mono.
    AudioChannelLayout monoChannelLayout = {
        .mChannelLayoutTag = kAudioChannelLayoutTag_Mono,
        .mChannelBitmap = 0,
        .mNumberChannelDescriptions = 0
    };
    
    // Convert the channel layout object to an NSData object.
    NSData *channelLayoutAsData = [NSData dataWithBytes:&monoChannelLayout length:offsetof(AudioChannelLayout, mChannelDescriptions)];
    
    self.audioSettings = @{
                           AVFormatIDKey : @(kAudioFormatMPEG4AAC),
                           AVNumberOfChannelsKey : @(1),
                           AVSampleRateKey : @(44100),
                           AVEncoderBitRateKey : @(48000),
                           AVChannelLayoutKey  : channelLayoutAsData,
                           };
}

- (NSDictionary *)videoSettings{
    return @{
             AVVideoCodecKey : AVVideoCodecH264,
             AVVideoWidthKey : [self.widthAndHeight[self.currentFileIndex] objectForKey:@"width"],
             AVVideoHeightKey : [self.widthAndHeight[self.currentFileIndex] objectForKey:@"height"],
             AVVideoCompressionPropertiesKey: @{
                     AVVideoProfileLevelKey : AVVideoProfileLevelH264Main30,
                     AVVideoAverageBitRateKey : @(800000),
                     //AVVideoMaxKeyFrameIntervalKey : @(40),
                     AVVideoMaxKeyFrameIntervalDurationKey : @(2.0),
                     }
             };
}

- (void)reset
{
    self.oneTrackHasFinishWrite = NO;
    self.keyFrameCount = 0;
    self.keyFrameInterval = 0;
    self.inputVideoFrameCount = 0;
    self.inputAudioFrameCount = 0;
    self.outputVideoFrameCount = 0;
    self.outputAudioFrameCount = 0;
}

- (NSString *)currentFileName
{
    NSString * name = self.sourceFileNames[self.currentFileIndex];
    NSDictionary * compressionSettings = [self.videoSettings objectForKey:AVVideoCompressionPropertiesKey];
    for (id key in compressionSettings) {
        NSString * value = [compressionSettings objectForKey:key];
        if (key == AVVideoProfileLevelKey) {
            name = [name stringByAppendingString:[NSString stringWithFormat:@"-L%@", value]];
        }else if (key == AVVideoAverageBitRateKey){
            name = [name stringByAppendingString:[NSString stringWithFormat:@"-B%ld", value.integerValue/1000]];
        }else if (key == AVVideoMaxKeyFrameIntervalKey){
            name = [name stringByAppendingString:[NSString stringWithFormat:@"-FI%@", value]];
        }else if (key == AVVideoMaxKeyFrameIntervalDurationKey){
            name = [name stringByAppendingString:[NSString stringWithFormat:@"-FD%@", value]];
        }
    }
    name = [name stringByAppendingString:@".mp4"];
    return name;
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

- (IBAction)clidkDeleteFile:(id)sender {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *documentsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSError * error = nil;
    for (NSString * sourceFileName in self.sourceFileNames) {
        NSString * filePath = [documentsDirectory stringByAppendingPathComponent:[sourceFileName stringByAppendingString:@".mp4"]];
        if ([fileManager fileExistsAtPath:filePath]) {
            [fileManager removeItemAtPath:filePath error:&error];
            if (error) {
                NSLog(@"remove file -%@-  error :%@", filePath, error.description);
            }
        }
    }
}

#pragma mark <rawH264EncoderDelegate>
- (void)gotSpsPps:(NSData*)sps pps:(NSData*)pps
{
    if (_ifSaveH464File && fileHandle) {
        //NSLog(@"gotSpsPps %d %d", (int)[sps length], (int)[pps length]);
        const char bytes[] = "\x00\x00\x00\x01";
        size_t length = (sizeof bytes) - 1; //string literals have implicit trailing '\0'
        NSData *ByteHeader = [NSData dataWithBytes:bytes length:length];
        [fileHandle writeData:ByteHeader];
        [fileHandle writeData:sps];
        [fileHandle writeData:ByteHeader];
        [fileHandle writeData:pps];
    }
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
    
    if (_ifSaveH464File) {
        h264FilePath = [documentsDirectory stringByAppendingPathComponent:@"result.h264"];
        [fileManager removeItemAtPath:h264FilePath error:nil];
        [fileManager createFileAtPath:h264FilePath contents:nil attributes:nil];
        fileHandle = [NSFileHandle fileHandleForWritingAtPath:h264FilePath];
    }
    
    NSString *sourceFileName = self.sourceFileNames[self.currentFileIndex];
    NSString *originPath=[[NSBundle mainBundle] pathForResource:sourceFileName ofType:@"mp4"];
    sourceFilePath = [documentsDirectory stringByAppendingPathComponent:[sourceFileName stringByAppendingString:@".mp4"]];
    if (![fileManager fileExistsAtPath:sourceFilePath]) {
        [fileManager copyItemAtURL:[NSURL fileURLWithPath:originPath] toURL:[NSURL fileURLWithPath:sourceFilePath] error:&error];
        if (error) {
            NSLog(@"copy file fail: %@", [error description]);
            return;
        }
    }else{
        NSFileHandle * documentFile = [NSFileHandle fileHandleForReadingAtPath:sourceFilePath];
        NSLog(@"Source File (file size: %lld )\n %@", [documentFile seekToEndOfFile], sourceFilePath);
        [documentFile closeFile];
    }
}

- (BOOL)prepareWriter
{
    NSArray * paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString * documentsDirectory = [paths objectAtIndex:0];
    NSString * finalPath = [documentsDirectory stringByAppendingPathComponent:[self currentFileName]];
    NSError * error = nil;
    [[NSFileManager defaultManager] removeItemAtURL:[NSURL fileURLWithPath:finalPath] error:nil];
    
    self.assetWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:finalPath] fileType:AVFileTypeMPEG4 error:&error];
    NSParameterAssert(self.assetWriter);
    
    self.videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:self.videoSettings];
    self.videoWriterInput.transform = self.transform;
    if ([self.assetWriter canAddInput:self.videoWriterInput]) {
        [self.assetWriter addInput:self.videoWriterInput];
    }else{
        return NO;
    }
    
    self.audioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:self.audioSettings];
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
    self.transform = [videoTrack preferredTransform];
    
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
    [self prepareFile];
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
                //CFRelease(nextSampleBuffer);
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
    if (_ifSaveH464File) {
        NSLog(@">>>>>>> h265 file size ( %lld ) >>>>>", [fileHandle seekToEndOfFile]);
        [fileHandle closeFile];
        fileHandle = NULL;
    }
    
    [self.assetWriter finishWritingWithCompletionHandler:^{
        NSArray * paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString * documentsDirectory = [paths objectAtIndex:0];
        NSString * finalPath = [documentsDirectory stringByAppendingPathComponent:[self currentFileName]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:finalPath]) {
            NSFileHandle * mp4FileHandle = [NSFileHandle fileHandleForReadingAtPath:finalPath];
            NSLog(@">>>>>>> mp4 file  size ( %lld ) >>>>>", [mp4FileHandle seekToEndOfFile]);
            NSLog(@"keyFrameCount: %d", self.keyFrameCount - 1);
            NSLog(@"keyFrameInterval: %d", self.keyFrameInterval);
            NSLog(@"encodeVideoFrame: %d", self.outputVideoFrameCount);
            NSLog(@"encodeAudioFrame: %d", self.outputAudioFrameCount);
            [mp4FileHandle closeFile];
        }
        NSLog(@" == DONE (%ld) ==\n\n", (long)self.currentFileIndex);
        self.currentFileIndex += 1;
        if (self.currentFileIndex < self.sourceFileNames.count) {
            [self performSelectorOnMainThread:@selector(carolStartWithOutToolBox) withObject:nil waitUntilDone:NO];
        }
    }];
    for (id obj in self.compressedVideoSamples) {
        CFRelease((__bridge CMSampleBufferRef)obj);
    }
    self.compressedVideoSamples = nil;
}

- (CMSampleBufferRef)nextVideoSampleBufferToWrite
{
    if (!_ifUseToolBox) {
        static int currVideoCount = 0;
        CMSampleBufferRef sampleBuffer = [self.videoTrackOutput copyNextSampleBuffer];
        currVideoCount++;
        if (self.ifReduceFrame && currVideoCount % ((NSString *)self.reduceFrameIntervals[self.currentFileIndex]).integerValue == 0) {
            CFRelease(sampleBuffer);
            sampleBuffer = [self.videoTrackOutput copyNextSampleBuffer];
            currVideoCount++;
        }
        CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        //NSLog(@"V - >PTS:%lld",  presentationTimeStamp.value);
        NSString * lastVideoPTS = (NSString *)self.lastVideoPTS[self.currentFileIndex];
        if (self.if7Second && presentationTimeStamp.value > lastVideoPTS.integerValue * 0.75) {
            return nil;
        }
        if (sampleBuffer) {
            self.lastSamplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        }
        return sampleBuffer;
    }else{
        int totalSamples = (int)self.compressedVideoSamples.count;
        static int currVideoCount = 1;
        if (self.ifReduceFrame && currVideoCount % ((NSString *)self.reduceFrameIntervals[self.currentFileIndex]).integerValue == 0) {
            currVideoCount ++;
        }
        if (currVideoCount < totalSamples) {
            CMSampleBufferRef sampleBuffer = (__bridge CMSampleBufferRef)(self.compressedVideoSamples[currVideoCount++]);
            CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            //NSLog(@"V - > PTS:%lld",  presentationTimeStamp.value);
            NSString * lastVideoPTS = (NSString *)self.lastVideoPTS[self.currentFileIndex];
            if (self.if7Second && presentationTimeStamp.value > lastVideoPTS.integerValue * 0.75) {
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
    if (self.ifReduceFrame && currAudioCount % ((NSString *)self.reduceFrameIntervals[self.currentFileIndex]).integerValue == 0) {
        CFRelease(sampleBuffer);
        sampleBuffer = [self.audioTrackOutput copyNextSampleBuffer];
        currAudioCount++;
    }
    CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    //NSLog(@"a - >PTS:%lld",  presentationTimeStamp.value);
    NSString * lastAudioPTS = (NSString *)self.lastAudioPTS[self.currentFileIndex];
    if (self.if7Second && presentationTimeStamp.value > lastAudioPTS.integerValue * 0.75) {
        return nil;
    }
    return sampleBuffer;
}

- (void)carolStartWithOutToolBox
{
    [self reset];
    [self prepareFile];
    //prepare for reader and writer
    NSParameterAssert([self startAssetReader]);
    NSParameterAssert([self prepareWriter]);
    
    [self.assetWriter startWriting];
    CMSampleBufferRef firstSample = [self nextVideoSampleBufferToWrite];
    [self.assetWriter startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(firstSample)];
    
    WEAK_OBJ_REF(self);
    [self.videoWriterInput requestMediaDataWhenReadyOnQueue:writeQueue usingBlock:^{
        while ([weak_self.videoWriterInput isReadyForMoreMediaData])
        {
            @try {
                CMSampleBufferRef videoNextBuff = nil;
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
                    //NSLog(@"video -> %d", weak_self.outputVideoFrameCount);
                }
                else
                {
                    hasProcessFirstSample = NO;
                    [weak_self.videoWriterInput markAsFinished];
                    NSLog(@"======= end video (%d) =====", weak_self.outputVideoFrameCount);
                    if (weak_self.oneTrackHasFinishWrite) {
                        
                        [weak_self.assetWriter endSessionAtSourceTime:weak_self.lastSamplePTS];
                        [weak_self carolEndWork];
                    }else{
                        weak_self.oneTrackHasFinishWrite = YES;
                    }
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
    
    [self.audioWriterInput requestMediaDataWhenReadyOnQueue:writeQueue usingBlock:^{
        while ([weak_self.audioWriterInput isReadyForMoreMediaData])
        {
            CMSampleBufferRef audioNextBuff = [weak_self nextAudioSampleBufferToWrite];
            if (audioNextBuff)
            {
                weak_self.outputAudioFrameCount++;
                //NSLog(@"audio -> %d", weak_self.outputAudioFrameCount);
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
                break;
            }
        }
    }];
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
