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
    dispatch_queue_t writeQueue;
    rawH264Encoder *h264Encoder;
    NSString *sourceFilePath;
    NSString *h264FilePath;
    NSFileHandle *fileHandle;
    
    AVAssetReader *assetReader;
    AVAssetReaderTrackOutput *videoTrackOutput;
    AVAssetReaderTrackOutput *audioTrackOutput;
    
    AVAssetWriter *assetWriter;
    AVAssetWriterInput * videoWriterInput;
    AVAssetWriterInput * audioWriterInput;
    
    BOOL oneTrackHasFinishWrite;
    NSMutableArray * compressedVideoSamples;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    writeQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    self.goButton.enabled = NO;
    [self prepareFile];
    self.goButton.enabled = YES;
    oneTrackHasFinishWrite = NO;
    compressedVideoSamples = [[NSMutableArray alloc] init];
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
    static int sampleCount = 1;
    NSLog(@" = = = = = = = >> %d", sampleCount++);
    [compressedVideoSamples addObject:(__bridge id _Nonnull)(sampleBuffer)];
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
    
    assetWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:finalPath] fileType:AVFileTypeQuickTimeMovie error:&error];
    NSParameterAssert(assetWriter);
    
    //如果输入源是已经编码过的，setting参数必须为nil
    videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:nil];
    if ([assetWriter canAddInput:videoWriterInput]) {
        [assetWriter addInput:videoWriterInput];
    }else{
        return NO;
    }

    audioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil];
    if ([assetWriter canAddInput:audioWriterInput]) {
        [assetWriter addInput:audioWriterInput];
    }else{
        return NO;
    }
    NSLog(@"assetWriter output file type: %@", assetWriter.outputFileType);
    return YES;
}

- (BOOL)startAssetReader
{
    NSError * error;
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:sourceFilePath]];
    assetReader = [AVAssetReader assetReaderWithAsset:asset error:&error];
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
    videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:videoSettings];
    
    if ([assetReader canAddOutput:videoTrackOutput]) {
        [assetReader addOutput:videoTrackOutput];
    }else{
        return NO;
    }
    
    //assetReader创建音频output
    NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    AVAssetTrack *audioTrack = (AVAssetTrack *)[audioTracks firstObject];
    NSLog(@"frameRate : %f", audioTrack.nominalFrameRate);
    NSLog(@"timeScale : %d", audioTrack.naturalTimeScale);
    audioTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:nil];
    
    if ([assetReader canAddOutput:audioTrackOutput]) {
        [assetReader addOutput:audioTrackOutput];
    }else{
        return NO;
    }
    
    NSLog(@"mediaType(audio:%@, video:%@)", audioTrackOutput.mediaType, videoTrackOutput.mediaType);
    BOOL didStart = [assetReader startReading];
    return didStart;
}

- (void)carolStart
{
    //prepare for reader and writer
    NSParameterAssert([self startAssetReader]);
    NSParameterAssert([self prepareWriter]);
    h264Encoder = [[rawH264Encoder alloc] initWithWidth:480 height:640];
    h264Encoder.delegate = self;
    
    NSLog(@"================ start convert == video ================");
    CMSampleBufferRef sampleBuffer = [videoTrackOutput copyNextSampleBuffer];
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
            if (sourceFileSampleCount > 1000 || assetReader.status != AVAssetReaderStatusReading) {
                //7秒视频190帧
                sampleBuffer = nil;
                break;
            }else{
                sampleBuffer = [videoTrackOutput copyNextSampleBuffer];
            }
        }else{
            if (assetReader.status == AVAssetReaderStatusFailed){
                NSLog(@"Asset Reader failed with error: %@", [[assetReader error] description]);
            } else if (assetReader.status == AVAssetReaderStatusCompleted){
                NSLog(@"Reached the end of the video.");
                NSLog(@"================ end ====== frame count %d ===========", sourceFileSampleCount);
            } else{
                NSLog(@"================ end (%ld) ====== frame count %d ===========", (long)assetReader.status, sourceFileSampleCount);
            }
            break;
        }
    }
    
    [assetWriter startWriting];
    [assetWriter startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp((__bridge CMSampleBufferRef)compressedVideoSamples[0])];
    static int videoSampleCount = 0;
    [videoWriterInput requestMediaDataWhenReadyOnQueue:writeQueue usingBlock:^{
        while ([videoWriterInput isReadyForMoreMediaData])
        {
            CMSampleBufferRef nextSampleBuffer = [self nextVideoSampleBufferToWrite];
            if (nextSampleBuffer)
            {
                videoSampleCount++;
                [videoWriterInput appendSampleBuffer:nextSampleBuffer];
                //CFRelease(nextSampleBuffer);
            }
            else
            {
                [videoWriterInput markAsFinished];
                NSLog(@"======= end video (%d)", videoSampleCount);
                if (oneTrackHasFinishWrite) {
                    [assetWriter endSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp((__bridge CMSampleBufferRef)compressedVideoSamples[compressedVideoSamples.count - 1])];
                    [self carolEndWork];
                }else{
                    oneTrackHasFinishWrite = YES;
                }
                break;
            }
        }
    }];
    
    static int audioSampleCount = 0;
    [audioWriterInput requestMediaDataWhenReadyOnQueue:writeQueue usingBlock:^{
        while ([audioWriterInput isReadyForMoreMediaData])
        {
            CMSampleBufferRef nextSampleBuffer = [self nextAudioSampleBufferToWrite];
            if (nextSampleBuffer)
            {
                audioSampleCount++;
                [audioWriterInput appendSampleBuffer:nextSampleBuffer];
                CFRelease(nextSampleBuffer);
            }
            else
            {
                [audioWriterInput markAsFinished];
                NSLog(@"======= end audio (%d)", audioSampleCount);
                if (oneTrackHasFinishWrite) {
                    [assetWriter endSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp((__bridge CMSampleBufferRef)compressedVideoSamples[compressedVideoSamples.count - 1])];
                    [self carolEndWork];
                }else{
                    oneTrackHasFinishWrite = YES;
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
    
    [assetWriter finishWritingWithCompletionHandler:^{
        NSArray * paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString * documentsDirectory = [paths objectAtIndex:0];
        NSString * finalPath = [documentsDirectory stringByAppendingPathComponent:@"final.mov"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:finalPath]) {
            NSFileHandle * mp4FileHandle = [NSFileHandle fileHandleForReadingAtPath:finalPath];
            NSLog(@">>>>>>> mov file  size ( %lld ) >>>>>", [mp4FileHandle seekToEndOfFile]);
            [mp4FileHandle closeFile];
        }
        NSLog(@" == DONE ==");
    }];
//    for (id obj in compressedVideoSamples) {
//        CFRelease((__bridge CMSampleBufferRef)obj);
//    }
    [compressedVideoSamples removeAllObjects];
}

- (CMSampleBufferRef)nextVideoSampleBufferToWrite
{
    int totalSamples = (int)compressedVideoSamples.count;
    static int currVideoCount = 0;
    NSLog(@"+++ ask for video : %d", currVideoCount);
    if (currVideoCount < totalSamples) {
        return (__bridge CMSampleBufferRef)(compressedVideoSamples[currVideoCount++]);
    }
    return nil;
}

- (CMSampleBufferRef)nextAudioSampleBufferToWrite
{
    static int askedAudioCount = 0;
    NSLog(@"--- ask for audio : %d", askedAudioCount++);
    return [audioTrackOutput copyNextSampleBuffer];
}


@end
