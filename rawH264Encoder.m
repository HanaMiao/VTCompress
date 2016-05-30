//
//  rawH264Encoder.m
//  VTCompress
//
//  Created by 张颂 on 16/5/28.
//  Copyright © 2016年 张颂. All rights reserved.
//

#import "rawH264Encoder.h"
@import VideoToolbox;


@implementation rawH264Encoder
{
    NSString * yuvFile;
    VTCompressionSessionRef EncodingSession;
    dispatch_queue_t aQueue;
    BOOL initialized;
    int  inputFrameCount;
    NSError * error;
    NSData *sps;
    NSData *pps;
}

- (instancetype)initWithWidth:(int32_t)width height:(int32_t)height
{
    self = [super init];
    if (self) {
        EncodingSession = nil;
        initialized = true;
        aQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        inputFrameCount = 0;
        sps = NULL;
        pps = NULL;
        [self config:width height:height];
    }
    return self;
}

- (void)encode:(CMSampleBufferRef)sampleBuffer
{
    dispatch_sync(aQueue, ^{
        
        inputFrameCount++;
        // Get the CV Image buffer
        CVImageBufferRef imageBuffer = (CVImageBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);
        
        // Create properties
        CMTime decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(sampleBuffer);
        CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
        NSLog(@" %d ===> PTS:%lld, DTS:%d", inputFrameCount, presentationTimeStamp.value, presentationTimeStamp.timescale);
        VTEncodeInfoFlags flags;
        
        // Pass it to the encoder
        OSStatus statusCode = VTCompressionSessionEncodeFrame(EncodingSession,
                                                              imageBuffer,
                                                              presentationTimeStamp,
                                                              duration,
                                                              NULL, NULL, &flags);
        // Check for error
        if (statusCode != noErr) {
            // End the session
            VTCompressionSessionInvalidate(EncodingSession);
            CFRelease(EncodingSession);
            EncodingSession = NULL;
            NSAssert(statusCode != noErr, @"VTCompressionSessionEncodeFrame faild");
            return;
        }

    });
}

- (void)finish
{
    dispatch_sync(aQueue, ^{
        // Mark the completion
        NSLog(@" - - - - - - - - - - - - - - - - - - - - - - -");
        NSLog(@" - - - - - - - - session end - - - - - - - - - ");
        NSLog(@" - - - - - - - - - - - - - - - - - - - - - - -");
        VTCompressionSessionCompleteFrames(EncodingSession, kCMTimeInvalid);
        
        // End the session
        VTCompressionSessionInvalidate(EncodingSession);
        CFRelease(EncodingSession);
        EncodingSession = NULL;
    });
}

#pragma mark private
- (void)config:(int)width height:(int)height
{
    dispatch_sync(aQueue, ^{
        
        // For testing out the logic, lets read from a file and then send it to encoder to create h264 stream
        
        // Create the compression session
        NSLog(@" - - - - - - - - - - - - - - - - - - - - - - -");
        NSLog(@" - - - - - - - - session create - - - - - - - -");
        NSLog(@" - - - - - - - - - - - - - - - - - - - - - - -");
        OSStatus status = VTCompressionSessionCreate(NULL, width, height, kCMVideoCodecType_H264, NULL, NULL, NULL, didCompressH264, (__bridge void *)(self),  &EncodingSession);
        NSLog(@"H264: VTCompressionSessionCreate %d", (int)status);
        NSAssert(status == 0, @"H264: Unable to create a H264 session");
        
        // Set the properties
        VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel);
        VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_AllowTemporalCompression, kCFBooleanFalse);
        VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        
        float quality = 0.5; //not much relate to output file size
        VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_Quality, CFNumberCreate(NULL, kCFNumberFloatType, &quality));
        
        int32_t nominalFrameRate = 40; //larger value leads to less key frame and smaller output file size
        VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_ExpectedFrameRate, CFNumberCreate(NULL, kCFNumberSInt32Type, &nominalFrameRate));
        
        int maxKeyFrameInterval = nominalFrameRate*2;
        VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, CFNumberCreate(NULL, kCFNumberIntType, &maxKeyFrameInterval));
        
        int32_t bitRate = 600 * 1000; //much relate to output file size
        VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_AverageBitRate, CFNumberCreate(NULL, kCFNumberSInt32Type, &bitRate));
        
        int32_t sourceFrameCount = 255;
        VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_SourceFrameCount, CFNumberCreate(NULL, kCFNumberSInt32Type, &sourceFrameCount));
        
        int32_t expectedDuration = 12288;
        VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_ExpectedDuration, CFNumberCreate(NULL, kCFNumberSInt32Type, &expectedDuration));
        
        // Tell the encoder to start encoding
        VTCompressionSessionPrepareToEncodeFrames(EncodingSession);
    });
}

void didCompressH264(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer )
{
    //NSLog(@"didCompressH264 called with status %d infoFlags %d", (int)status, (int)infoFlags);
    if (status != 0) return;
    
    if (!CMSampleBufferDataIsReady(sampleBuffer))
    {
        NSLog(@"didCompressH264 data is not ready ");
        return;
    }
    rawH264Encoder * encoder = (__bridge rawH264Encoder * )outputCallbackRefCon;
    
    if (encoder->_delegate)
    {
        [encoder->_delegate gotCompressedSampleBuffer:sampleBuffer];
    }

    // Check if we have got a key frame first
    bool keyframe = !CFDictionaryContainsKey( (CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true), 0)), kCMSampleAttachmentKey_NotSync);
    
    if (keyframe)
    {
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        // CFDictionaryRef extensionDict = CMFormatDescriptionGetExtensions(format);
        // Get the extensions
        // From the extensions get the dictionary with key "SampleDescriptionExtensionAtoms"
        // From the dict, get the value for the key "avcC"
        
        size_t sparameterSetSize, sparameterSetCount;
        const uint8_t *sparameterSet;
        OSStatus statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sparameterSet, &sparameterSetSize, &sparameterSetCount, 0 );
        if (statusCode == noErr)
        {
            // Found sps and now check for pps
            size_t pparameterSetSize, pparameterSetCount;
            const uint8_t *pparameterSet;
            OSStatus statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &pparameterSet, &pparameterSetSize, &pparameterSetCount, 0 );
            if (statusCode == noErr)
            {
                // Found pps
                encoder->sps = [NSData dataWithBytes:sparameterSet length:sparameterSetSize];
                encoder->pps = [NSData dataWithBytes:pparameterSet length:pparameterSetSize];
                if (encoder->_delegate)
                {
                    [encoder->_delegate gotSpsPps:encoder->sps pps:encoder->pps];
                }
            }
        }
    }
    
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length, totalLength;
    char *dataPointer;
    OSStatus statusCodeRet = CMBlockBufferGetDataPointer(dataBuffer, 0, &length, &totalLength, &dataPointer);
    if (statusCodeRet == noErr) {
        
        size_t bufferOffset = 0;
        static const int AVCCHeaderLength = 4;
        while (bufferOffset < totalLength - AVCCHeaderLength) {
            
            // Read the NAL unit length
            uint32_t NALUnitLength = 0;
            memcpy(&NALUnitLength, dataPointer + bufferOffset, AVCCHeaderLength);
            
            // Convert the length value from Big-endian to Little-endian
            NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);
            
            NSData* data = [[NSData alloc] initWithBytes:(dataPointer + bufferOffset + AVCCHeaderLength) length:NALUnitLength];
            [encoder->_delegate gotEncodedData:data isKeyFrame:keyframe];
            
            // Move to the next NAL unit in the block buffer
            bufferOffset += AVCCHeaderLength + NALUnitLength;
        }
        
    }
    
}

@end
